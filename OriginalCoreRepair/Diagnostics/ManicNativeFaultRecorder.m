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
#include <mach/mach_vm.h>
#include <mach/thread_info.h>
#include <mach/arm/thread_status.h>
#include <dispatch/dispatch.h>

static int recordFD=-1,imageFD=-1,stackFD=-1;
static NSString *diagnosticPrefix;
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
                        uint8_t memory[8192];mach_vm_size_t copied=0;
                        kern_return_t readResult=mach_vm_read_overwrite(mach_task_self(),registers.__sp,sizeof(memory),(mach_vm_address_t)memory,&copied);
                        row[@"stack_read_result"]=@(readResult);
                        if(readResult==KERN_SUCCESS&&copied<=sizeof(memory)){
                            row[@"stack_b64"]=[[NSData dataWithBytes:memory length:(NSUInteger)copied] base64EncodedStringWithOptions:0];
                        }
                    }
                    [rows addObject:row];
                }
                mach_port_deallocate(mach_task_self(),thread);
            }
            vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
        }
        NSDictionary *sample=@{@"format_version":@1,@"pid":@(getpid()),@"sample_index":@(index),
            @"capture_epoch":@(NSDate.date.timeIntervalSince1970),@"task_threads_result":@(result),
            @"thread_count":@(count),@"thread_limit":@64,@"thread_suspension_performed":@NO,@"threads":rows};
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
#ifdef MANIC_NATIVE_RECORDER_SELF_TEST
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
        const unsigned delays[]={2,10,25,50};
        for(unsigned i=0;i<4;i++){
            unsigned sampleIndex=i;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delays[i]*NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ManicCaptureHangSnapshot(sampleIndex);});
        }
#endif
    }
}
