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

static int recordFD=-1,imageFD=-1,stackFD=-1;
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
        recordFD=open([prefix stringByAppendingString:@".bin"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        imageFD=open([prefix stringByAppendingString:@".images"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        stackFD=open([prefix stringByAppendingString:@".stack"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        if(recordFD<0||imageFD<0)return;
        _dyld_register_func_for_add_image(imageAdded);
        struct sigaction action={0};action.sa_sigaction=fault;action.sa_flags=SA_SIGINFO;
        const int signals[]={SIGSEGV,SIGBUS,SIGABRT,SIGILL,SIGTRAP};
        for(unsigned i=0;i<sizeof(signals)/sizeof(signals[0]);i++)sigaction(signals[i],&action,NULL);
    }
}
