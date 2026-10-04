// Optional process-lifetime diagnostic dependency, never a production core fix.
// Reads only this process. No core callbacks, guest RAM, debugger or suspension.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/task_info.h>
#include <mach/thread_info.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *prefix;
static int imagesFD=-1;
static uintptr_t coreBase;
static uint64_t imageGeneration;
#ifndef MANIC_STABILITY_SELF_TEST
static dispatch_source_t timer;
static unsigned sequence;
#endif

static void recordImage(const struct mach_header *header,BOOL added) {
    if(imagesFD<0||header->magic!=MH_MAGIC_64)return;
    const struct mach_header_64 *h=(const void *)header;
    const uint8_t *command=(const void *)(h+1);
    uint64_t textSize=0;
    for(uint32_t i=0;i<h->ncmds;i++){
        const struct load_command *load=(const void *)command;
        if(load->cmd==LC_SEGMENT_64){
            const struct segment_command_64 *segment=(const void *)command;
            if(!strcmp(segment->segname,"__TEXT"))textSize=segment->vmsize;
        }
        command+=load->cmdsize;
    }
    const char *name="unknown";
    // dyld invokes callbacks under its image lock. Do not enumerate dyld from
    // the sampler, or take a sampler lock in this callback.
    if(added){
        for(uint32_t i=0;i<_dyld_image_count();i++){
            if(_dyld_get_image_header(i)!=header)continue;
            const char *path=_dyld_get_image_name(i),*slash=strrchr(path,'/');
            name=slash?slash+1:path;break;
        }
        if(!strcmp(name,"azahar.libretro"))
            __atomic_store_n(&coreBase,(uintptr_t)header,__ATOMIC_RELEASE);
    }else if(__atomic_load_n(&coreBase,__ATOMIC_ACQUIRE)==(uintptr_t)header){
        __atomic_store_n(&coreBase,0,__ATOMIC_RELEASE);
    }
    uint64_t generation=__atomic_add_fetch(&imageGeneration,1,__ATOMIC_RELAXED);
    char line[512];
    int count=snprintf(line,sizeof(line),"%llu %s %llx %llx %s\n",
        (unsigned long long)generation,added?"add":"remove",
        (unsigned long long)(uintptr_t)header,(unsigned long long)textSize,name);
    if(count>0)write(imagesFD,line,MIN((size_t)count,sizeof(line)-1));
}
static void imageAdded(const struct mach_header *header,intptr_t slide){recordImage(header,YES);}
static void imageRemoved(const struct mach_header *header,intptr_t slide){recordImage(header,NO);}

static BOOL capture(unsigned number) {
    @autoreleasepool {
        if(!prefix)return NO;
        uint64_t started=mach_absolute_time();
        task_vm_info_data_t memory={0};mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
        kern_return_t memoryResult=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&memory,&n);
        NSMutableDictionary *metrics=[@{@"result":@(memoryResult)} mutableCopy];
        if(memoryResult==KERN_SUCCESS){
            metrics[@"resident_bytes"]=@(memory.resident_size);
            metrics[@"resident_peak_bytes"]=@(memory.resident_size_peak);
            metrics[@"virtual_bytes"]=@(memory.virtual_size);
            if(n>=TASK_VM_INFO_REV1_COUNT)metrics[@"physical_footprint_bytes"]=@(memory.phys_footprint);
        }
        thread_act_array_t threads=NULL;mach_msg_type_number_t count=0;
        kern_return_t result=task_threads(mach_task_self(),&threads,&count);
        NSMutableArray *rows=[NSMutableArray new];
        if(result==KERN_SUCCESS){
            for(unsigned i=0;i<count;i++){
                thread_t thread=threads[i];
                if(i<64){
                    thread_basic_info_data_t basic={0};n=THREAD_BASIC_INFO_COUNT;
                    kern_return_t basicResult=thread_info(thread,THREAD_BASIC_INFO,(thread_info_t)&basic,&n);
                    thread_identifier_info_data_t identity={0};n=THREAD_IDENTIFIER_INFO_COUNT;
                    kern_return_t identityResult=thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&identity,&n);
                    arm_thread_state64_t state={0};n=ARM_THREAD_STATE64_COUNT;
                    kern_return_t stateResult=thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&state,&n);
                    NSMutableDictionary *row=[@{@"thread_id":@(identity.thread_id),
                        @"identity_result":@(identityResult),@"info_result":@(basicResult),
                        @"state_result":@(stateResult),@"run_state":@(basic.run_state),
                        @"suspend_count":@(basic.suspend_count),@"cpu_usage":@(basic.cpu_usage),
                        @"user_us":@((uint64_t)basic.user_time.seconds*1000000+basic.user_time.microseconds),
                        @"system_us":@((uint64_t)basic.system_time.seconds*1000000+basic.system_time.microseconds)} mutableCopy];
                    if(stateResult==KERN_SUCCESS){
                        row[@"pc"]=@(state.__pc);row[@"lr"]=@(state.__lr);
                        row[@"sp"]=@(state.__sp);row[@"fp"]=@(state.__fp);
                        uint8_t stack[4096];vm_size_t copied=0;
                        while(copied<sizeof(stack)){
                            vm_size_t bytes=0;
                            kern_return_t readResult=vm_read_overwrite(mach_task_self(),state.__sp+copied,256,
                                (vm_address_t)(stack+copied),&bytes);
                            if(readResult!=KERN_SUCCESS||bytes!=256)break;
                            copied+=bytes;
                        }
                        if(copied)row[@"stack_b64"]=[[NSData dataWithBytes:stack length:copied] base64EncodedStringWithOptions:0];
                    }
                    [rows addObject:row];
                }
                mach_port_deallocate(mach_task_self(),thread);
            }
            vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
        }
        mach_timebase_info_data_t scale={0};mach_timebase_info(&scale);
        double elapsed=(double)(mach_absolute_time()-started)*scale.numer/scale.denom/1e6;
        NSDictionary *snapshot=@{@"format_version":@1,@"sequence":@(number),
            @"pid":@(getpid()),@"capture_epoch":@(NSDate.date.timeIntervalSince1970),
            @"capture_duration_ms":@(elapsed),@"image_generation":@(__atomic_load_n(&imageGeneration,__ATOMIC_ACQUIRE)),
            @"core_base":@(__atomic_load_n(&coreBase,__ATOMIC_ACQUIRE)),
            @"task_threads_result":@(result),@"thread_count":@(count),@"thread_limit":@64,
            @"stack_limit_bytes":@4096,@"ring_slots":@8,@"thread_suspension_performed":@NO,
            @"guest_ram_read":@NO,@"thermal_state":@(NSProcessInfo.processInfo.thermalState),
            @"memory":metrics,@"threads":rows};
        NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        // Only this new session's eight slots are replaced. Existing diagnostics,
        // app configuration, core code, private inputs and saves are untouched.
        NSString *path=[prefix stringByAppendingFormat:@".stability-%u.json",number%8];
        return [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
}
#ifdef MANIC_STABILITY_SELF_TEST
int ManicStabilityCaptureForTest(unsigned number){return capture(number)?0:1;}
#endif

__attribute__((constructor)) static void enableRecorder(void) {
    @autoreleasepool {
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *directory=[docs stringByAppendingPathComponent:@"ManicAzaharStabilityDiagnostics"];
#ifdef MANIC_STABILITY_SELF_TEST
        directory=@(getenv("MANIC_STABILITY_DIRECTORY"));
#endif
        if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])return;
        prefix=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"azahar-%d-%@",getpid(),NSUUID.UUID.UUIDString]];
        imagesFD=open([prefix stringByAppendingString:@".images"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_APPEND,0600);
        if(imagesFD<0)return;
        _dyld_register_func_for_add_image(imageAdded);
        _dyld_register_func_for_remove_image(imageRemoved);
#ifndef MANIC_STABILITY_SELF_TEST
        dispatch_queue_t queue=dispatch_queue_create("org.manicemu.azahar-stability",DISPATCH_QUEUE_SERIAL);
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
        dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),15*NSEC_PER_SEC,NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer,^{
            // Four hours maximum, eight rolling snapshots. No work when the
            // Azahar core is unloaded. No signal handlers alter Apple reports.
            if(++sequence>960){dispatch_source_cancel(timer);return;}
            if(__atomic_load_n(&coreBase,__ATOMIC_ACQUIRE))capture(sequence);
        });
        dispatch_resume(timer);
#endif
    }
}
