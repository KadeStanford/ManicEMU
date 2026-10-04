// Optional diagnostic library; never included in the shipping R3 component.
// Records host fault registers and loaded image ranges. No games or saves read.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/thread_info.h>
#include <mach/arm/thread_status.h>
#include <dispatch/dispatch.h>

static int recordFD=-1,imageFD=-1,stackFD=-1;
static NSString *diagnosticPrefix;
static uintptr_t azaharTextBase;
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
// Native diagnostic only: follow the original direct page table without calling
// the core, taking locks, flushing rasterizer memory, or reading save data.
static BOOL guestWord(uintptr_t memory,uint32_t address,uint32_t *value) {
    uintptr_t impl=0,table=0,page=0;vm_size_t copied=0;
    if(address&3)return NO;
    if(vm_read_overwrite(mach_task_self(),memory,8,(vm_address_t)&impl,&copied)!=KERN_SUCCESS||copied!=8||!impl)return NO;
    if(vm_read_overwrite(mach_task_self(),impl+0x28,8,(vm_address_t)&table,&copied)!=KERN_SUCCESS||copied!=8||!table)return NO;
    if(vm_read_overwrite(mach_task_self(),table+8*(address>>12),8,(vm_address_t)&page,&copied)!=KERN_SUCCESS||copied!=8||!page)return NO;
    return vm_read_overwrite(mach_task_self(),page+(address&0xfff),4,(vm_address_t)value,&copied)==KERN_SUCCESS&&copied==4;
}
#endif
// Exact original ARMul_State layout, established from ARM_DynCom::Run and
// InterpreterMainLoop. Serialize only execution metadata, never guest RAM.
static NSDictionary *guestExecutionState(uintptr_t address) {
    uint8_t state[0x380];vm_size_t copied=0;
    if(!address||vm_read_overwrite(mach_task_self(),address,sizeof(state),(vm_address_t)state,&copied)!=KERN_SUCCESS||copied!=sizeof(state))return nil;
    uint32_t pc,cpsr;uint64_t budget;
    memcpy(&pc,state+0x4c,sizeof(pc));memcpy(&cpsr,state+0x320,sizeof(cpsr));
    memcpy(&budget,state+0x358,sizeof(budget));
    NSMutableArray *registers=[NSMutableArray new];
    for(unsigned i=0;i<16;i++){
        uint32_t value;memcpy(&value,state+0x10+4*i,sizeof(value));
        [registers addObject:@(value)];
    }
    NSMutableDictionary *result=[@{@"guest_pc":@(pc),@"guest_cpsr":@(cpsr),@"instruction_budget":@(budget),@"guest_registers":registers} mutableCopy];
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
    if(pc>=0x12f078&&pc<=0x12f0e0){
        uintptr_t memory;memcpy(&memory,state+8,sizeof(memory));
        uint32_t lock=[registers[4] unsignedIntValue],sp=[registers[13] unsignedIntValue];
        NSMutableArray *lockWords=[NSMutableArray new],*returns=[NSMutableArray new];
        for(unsigned i=0;i<3;i++){uint32_t value;if(!guestWord(memory,lock+4*i,&value))break;[lockWords addObject:@(value)];}
        for(unsigned i=0;i<64;i++){
            uint32_t value;if(!guestWord(memory,sp+4*i,&value))break;
            if(!(value&3)&&((value>=0x100000&&value<0x400000)||(value>=0x7000000&&value<0x8000000)))
                [returns addObject:@{@"stack_word_index":@(i),@"possible_return_pc":@(value)}];
        }
        result[@"guest_lock_address"]=@(lock);result[@"guest_lock_words"]=lockWords;
        result[@"possible_guest_return_addresses"]=returns;
    }
#endif
    return result;
}
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
static NSDictionary *activeInterpreterState(void) {
    uintptr_t base=__atomic_load_n(&azaharTextBase,__ATOMIC_ACQUIRE),cpu=0,vtable=0,run=0,state=0;
    vm_size_t copied=0;
    if(!base)return nil;
    if(vm_read_overwrite(mach_task_self(),base+0x8cf4be0+0xe0,8,(vm_address_t)&cpu,&copied)!=KERN_SUCCESS||copied!=8||!cpu)return nil;
    if(vm_read_overwrite(mach_task_self(),cpu,8,(vm_address_t)&vtable,&copied)!=KERN_SUCCESS||copied!=8||!vtable)return nil;
    if(vm_read_overwrite(mach_task_self(),vtable+0x10,8,(vm_address_t)&run,&copied)!=KERN_SUCCESS||copied!=8||run!=base+0x4ffa04)return nil;
    if(vm_read_overwrite(mach_task_self(),cpu+0x28,8,(vm_address_t)&state,&copied)!=KERN_SUCCESS||copied!=8)return nil;
    return guestExecutionState(state);
}
#endif
#ifdef MANIC_NATIVE_RECORDER_SELF_TEST
int ManicVerifyGuestStateSampler(void) {
    uint8_t state[0x380]={0};uint32_t pc=0x07001234,cpsr=0x60000010;uint64_t budget=10000;
    memcpy(state+0x4c,&pc,sizeof(pc));memcpy(state+0x320,&cpsr,sizeof(cpsr));memcpy(state+0x358,&budget,sizeof(budget));
    NSDictionary *result=guestExecutionState((uintptr_t)state);
    return [result[@"guest_pc"] unsignedIntValue]==pc&&[result[@"guest_cpsr"] unsignedIntValue]==cpsr&&[result[@"instruction_budget"] unsignedLongLongValue]==budget&&[result[@"guest_registers"] count]==16&&[result[@"guest_registers"][15] unsignedIntValue]==pc&&guestExecutionState(1)==nil;
}
#endif
_Static_assert(sizeof(vm_address_t)>=sizeof(uintptr_t),"VM sampling must preserve native pointer width");
// Own-process, read-only sampling. No thread suspension, signals or debugger.
// Four bounded snapshots distinguish stable waits from progressing CPU work.
void ManicCaptureHangSnapshot(unsigned index) {
    @autoreleasepool {
        if(!diagnosticPrefix)return;
        thread_act_array_t threads=NULL;mach_msg_type_number_t count=0;
        kern_return_t result=task_threads(mach_task_self(),&threads,&count);
        NSMutableArray *rows=[NSMutableArray new];
        if(result==KERN_SUCCESS){
            for(unsigned i=0;i<count;i++){
                thread_t thread=threads[i];
                if(i<64){
                    thread_basic_info_data_t basic={0};mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;
                    kern_return_t infoResult=thread_info(thread,THREAD_BASIC_INFO,(thread_info_t)&basic,&n);
                    thread_identifier_info_data_t ident={0};n=THREAD_IDENTIFIER_INFO_COUNT;
                    thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&ident,&n);
                    arm_thread_state64_t registers={0};n=ARM_THREAD_STATE64_COUNT;
                    kern_return_t stateResult=thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&registers,&n);
                    NSMutableDictionary *row=[@{@"thread_id":@(ident.thread_id),@"info_result":@(infoResult),
                        @"state_result":@(stateResult),@"run_state":@(basic.run_state),@"suspend_count":@(basic.suspend_count),
                        @"cpu_usage":@(basic.cpu_usage),@"user_us":@((uint64_t)basic.user_time.seconds*1000000+basic.user_time.microseconds),
                        @"system_us":@((uint64_t)basic.system_time.seconds*1000000+basic.system_time.microseconds)} mutableCopy];
                    if(stateResult==KERN_SUCCESS){
                        row[@"pc"]=@(registers.__pc);row[@"lr"]=@(registers.__lr);
                        row[@"sp"]=@(registers.__sp);row[@"fp"]=@(registers.__fp);
                        uintptr_t base=__atomic_load_n(&azaharTextBase,__ATOMIC_ACQUIRE);
                        uintptr_t pc=registers.__pc&0x0000ffffffffffffULL;
                        uintptr_t lr=registers.__lr&0x0000ffffffffffffULL;
                        // X20 holds ARMul_State throughout this interpreter,
                        // including its condition helper and memory-read calls.
                        if(base&&((pc>=base+0x501d64&&pc<base+0x50fa34)||
                            (pc>=base+0x50fe94&&pc<base+0x50ffdc)||
                            (pc>=base+0x91c874&&pc<base+0x91ca00&&lr>=base+0x501d64&&lr<base+0x50fa34))){
                            NSDictionary *guest=guestExecutionState(registers.__x[20]);
                            if(guest)row[@"guest_execution"]=guest;
                            row[@"interpreter_instruction_count"]=@(registers.__x[19]&0xffffffff);
                            row[@"interpreter_state_pointer"]=@(registers.__x[20]);
                        }
                        uint8_t memory[8192];vm_size_t copied=0;
                        kern_return_t readResult=KERN_SUCCESS;
                        while(copied<sizeof(memory)){
                            vm_size_t chunk=0;
                            readResult=vm_read_overwrite(mach_task_self(),registers.__sp+copied,256,(vm_address_t)(memory+copied),&chunk);
                            if(readResult!=KERN_SUCCESS||chunk!=256)break;
                            copied+=chunk;
                        }
                        row[@"stack_read_result"]=@(readResult);
                        if(copied>0&&copied<=sizeof(memory)){
                            row[@"stack_b64"]=[[NSData dataWithBytes:memory length:(NSUInteger)copied] base64EncodedStringWithOptions:0];
                        }
                    }
                    [rows addObject:row];
                }
                mach_port_deallocate(mach_task_self(),thread);
            }
            vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
        }
        NSMutableDictionary *sample=[@{@"format_version":@1,@"pid":@(getpid()),@"sample_index":@(index),
            @"capture_epoch":@(NSDate.date.timeIntervalSince1970),@"task_threads_result":@(result),
            @"thread_count":@(count),@"thread_limit":@64,@"thread_suspension_performed":@NO,@"threads":rows} mutableCopy];
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
        NSDictionary *active=activeInterpreterState();
        if(active)sample[@"active_guest_execution"]=active;
#endif
        NSData *data=[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil];
        NSString *path=[diagnosticPrefix stringByAppendingFormat:@".hang-%u.json",index];
        [data writeToFile:path options:NSDataWritingWithoutOverwriting error:nil];
    }
}
static void imageAdded(const struct mach_header *header,intptr_t slide) {
    if(imageFD<0||header->magic!=MH_MAGIC_64)return;
    const struct mach_header_64 *h=(const void *)header;
    const uint8_t *command=(const void *)(h+1);uint64_t textSize=0;
    for(uint32_t i=0;i<h->ncmds;i++){
        const struct load_command *load=(const void *)command;
        if(load->cmd==LC_SEGMENT_64){const struct segment_command_64 *seg=(const void *)command;
            if(!strcmp(seg->segname,"__TEXT"))textSize=seg->vmsize;}
        command+=load->cmdsize;
    }
    const char *name="unknown";
    for(uint32_t i=0;i<_dyld_image_count();i++)if(_dyld_get_image_header(i)==header){
        const char *path=_dyld_get_image_name(i),*slash=strrchr(path,'/');name=slash?slash+1:path;break;
    }
    if(!strcmp(name,"azahar.libretro")
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
        ||!strcmp(name,"game-probe-core.dylib")
#endif
        )__atomic_store_n(&azaharTextBase,(uintptr_t)header,__ATOMIC_RELEASE);
    char line[512];int n=snprintf(line,sizeof(line),"%llx %llx %s\n",
        (unsigned long long)(uintptr_t)header,(unsigned long long)textSize,name);
    if(n>0){write(imageFD,line,MIN((size_t)n,sizeof(line)-1));fsync(imageFD);}
}
static void fault(int sig,siginfo_t *info,void *raw) {
    ucontext_t *c=raw;
    uint64_t values[39]={0x4d414e4943464c54,1,(uint64_t)sig,(uint64_t)info->si_code,
        (uintptr_t)info->si_addr,c->uc_mcontext->__ss.__pc,c->uc_mcontext->__ss.__lr,
        c->uc_mcontext->__ss.__sp,c->uc_mcontext->__ss.__fp,c->uc_mcontext->__ss.__cpsr};
    for(unsigned i=0;i<29;i++)values[10+i]=c->uc_mcontext->__ss.__x[i];
    if(recordFD>=0){write(recordFD,values,sizeof(values));fsync(recordFD);}
    // Preserve a bounded window from this faulting native thread only.
    // write() copies through the kernel; no unchecked stack dereference or
    // allocator/unwinder is invoked from the signal handler. Stop at EFAULT.
    if(stackFD>=0){
        uint64_t header[]={values[7],values[8]};write(stackFD,header,sizeof(header));
        uintptr_t start=(uintptr_t)values[7];
        for(unsigned offset=0;offset<16384;offset+=512){
            if(write(stackFD,(const void *)(start+offset),512)!=512)break;
        }
        fsync(stackFD);
    }
    _exit(128+sig);
}
__attribute__((constructor)) static void enableDiagnostic(void) {
    @autoreleasepool {
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *directory=[docs stringByAppendingPathComponent:@"ManicNativeDiagnostics"];
#if defined(MANIC_NATIVE_RECORDER_SELF_TEST) || defined(MANIC_NATIVE_RECORDER_HOST_PROBE)
        directory=@(getenv("MANIC_NATIVE_RECORDER_DIRECTORY"));
#endif
        if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])return;
        NSString *prefix=[directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"fault-%d-%.0f",getpid(),NSDate.date.timeIntervalSince1970]];
        diagnosticPrefix=prefix;
        recordFD=open([prefix stringByAppendingString:@".bin"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        imageFD=open([prefix stringByAppendingString:@".images"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        stackFD=open([prefix stringByAppendingString:@".stack"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        if(recordFD<0||imageFD<0)return;
        _dyld_register_func_for_add_image(imageAdded);
        struct sigaction action={0};action.sa_sigaction=fault;action.sa_flags=SA_SIGINFO;
        const int signals[]={SIGSEGV,SIGBUS,SIGABRT,SIGILL,SIGTRAP};
        for(unsigned i=0;i<sizeof(signals)/sizeof(signals[0]);i++)sigaction(signals[i],&action,NULL);
#ifndef MANIC_NATIVE_RECORDER_SELF_TEST
#ifdef MANIC_NATIVE_RECORDER_HOST_PROBE
        const unsigned delays[]={2,5,10,15,20,25,30,35,40,45,50,60};
#else
        const unsigned delays[]={2,10,25,50};
#endif
        for(unsigned i=0;i<sizeof(delays)/sizeof(delays[0]);i++){
            unsigned sampleIndex=i;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delays[i]*NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ManicCaptureHangSnapshot(sampleIndex);});
        }
#endif
    }
}
