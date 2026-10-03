// Standalone diagnostic frontend. Runs only private copies in a fresh sandbox.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/ucontext.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <unistd.h>
#import <stdarg.h>
#include <stdbool.h>
#include <stdint.h>

typedef bool (*Environment)(unsigned,void *);
typedef struct { const char *key,*value; } Variable;
typedef struct { const char *path;const void *data;size_t size;const char *meta; } Game;
static NSString *root;
static NSMutableDictionary *report;
static int logFD=-1,signalFD=-1;
static uintptr_t coreBase;
static volatile sig_atomic_t runCalls;
static unsigned frames,nonblackFrames;
static bool shutdownRequested;
static NSString *stage;
static void checkpoint(NSString *next) {
    stage=next;report[@"stage"]=next;report[@"run_calls"]=@(runCalls);
    report[@"frames"]=@(frames);report[@"nonblack_frames"]=@(nonblackFrames);
    [[NSJSONSerialization dataWithJSONObject:report options:2 error:nil]
        writeToFile:[root stringByAppendingPathComponent:@"game-probe.json"] atomically:YES];
}
static void fatalSignal(int sig,siginfo_t *info,void *rawContext) {
    // Only async-signal-safe I/O. Interpret this small binary record off-device.
    ucontext_t *context=rawContext;
    uint64_t record[]={0x4d414e4943505242,(uint64_t)sig,
        (uint64_t)(uintptr_t)info->si_addr,coreBase,
        context->uc_mcontext->__ss.__pc,context->uc_mcontext->__ss.__lr,
        context->uc_mcontext->__ss.__sp,(uint64_t)runCalls};
    if(signalFD>=0){write(signalFD,record,sizeof(record));fsync(signalFD);}
    _exit(128+sig);
}
static void logger(int level,const char *format,...) {
    char line[4096];va_list args;va_start(args,format);
    int n=vsnprintf(line,sizeof(line),format,args);va_end(args);
    if(n>0&&logFD>=0){write(logFD,line,MIN((size_t)n,sizeof(line)-1));fsync(logFD);}
}
static bool environment(unsigned command,void *data) {
    unsigned cmd=command&~0x10000U;
    switch(cmd) {
        case 27:*(void **)data=(void *)logger;return true;
        case 9:case 30:case 31:*(const char **)data=root.fileSystemRepresentation;return true;
        case 15:{Variable *v=data;
            if(!strcmp(v->key,"citra_graphics_api"))v->value="Software";
            else if(!strcmp(v->key,"citra_use_cpu_jit"))v->value="disabled";
            else if(!strcmp(v->key,"citra_is_new_3ds"))v->value="New 3DS";
            else if(!strcmp(v->key,"citra_resolution_factor"))v->value="1";
            else {v->value=NULL;return false;}return true;}
        case 17:*(bool *)data=false;return true;
        case 7:shutdownRequested=true;return true;
        case 3:case 6:logger(2,"Frontend message/shutdown command %u\n",cmd);return true;
        case 10:case 11:case 16:case 18:case 35:case 53:case 69:return true;
        // Return false for hardware context requests: this probe uses software.
        default:return false;
    }
}
static void video(const void *pixels,unsigned width,unsigned height,size_t pitch) {
    if(!pixels||pixels==(void *)-1)return;
    frames++;bool visible=false;
    for(unsigned y=0;y<height&&!visible;y+=MAX(1,height/32))
        for(unsigned x=0;x<width;x+=MAX(1,width/32))
            if((((const uint32_t *)((const uint8_t *)pixels+y*pitch))[x]&0xffffff)!=0){visible=true;break;}
    if(visible)nonblackFrames++;
    report[@"last_frame_dimensions"]=@[@(width),@(height)];
    NSString *snapshot=runCalls==179?@"private-frame-before-select.png":
        runCalls==240?@"private-frame-after-select.png":nil;
    if(snapshot){
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate((void *)pixels,width,height,8,pitch,space,
            kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
        if(context){CGImageRef image=CGBitmapContextCreateImage(context);
            [UIImagePNGRepresentation([UIImage imageWithCGImage:image])
                writeToFile:[root stringByAppendingPathComponent:snapshot] atomically:YES];
            CGImageRelease(image);CGContextRelease(context);}
        CGColorSpaceRelease(space);
    }
}
static void audio(int16_t left,int16_t right){}
static size_t audioBatch(const int16_t *samples,size_t count){return count;}
static void poll(void){}
static int16_t input(unsigned port,unsigned device,unsigned index,unsigned id) {
    // A short Select press after execution has started; no save interaction.
    return port==0&&device==1&&id==2&&runCalls>=180&&runCalls<183;
}
@interface GameProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation GameProbeApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        root=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        report=[@{@"actual_game_load_attempted":@NO,@"game_execution_completed":@NO,
            @"plugin_menu_verified":@NO,@"renderer":@"Software",
            @"original_inputs_and_saves_unchanged":@YES} mutableCopy];
        logFD=open([root stringByAppendingPathComponent:@"core-runtime.log"].fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);
        signalFD=open([root stringByAppendingPathComponent:@"fatal-signal.bin"].fileSystemRepresentation,O_CREAT|O_WRONLY|O_EXCL,0600);
        struct sigaction action={0};action.sa_sigaction=fatalSignal;action.sa_flags=SA_SIGINFO;
        int signals[]={SIGABRT,SIGBUS,SIGILL,SIGSEGV,SIGTRAP};
        for(unsigned i=0;i<sizeof(signals)/sizeof(signals[0]);i++)sigaction(signals[i],&action,NULL);
        if([NSProcessInfo.processInfo.environment[@"MANIC_PROBE_SIGNAL_TEST"] isEqualToString:@"1"]){
            checkpoint(@"diagnostic_signal_self_test");raise(SIGSEGV);return;
        }
        checkpoint(@"dlopen");
        void *h=dlopen([[NSBundle.mainBundle pathForResource:@"game-probe-core" ofType:@"dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
        if(!h){report[@"error"]=@(dlerror()?:"dlopen failed");checkpoint(@"dlopen_failed");return;}
        void (*init)(void)=dlsym(h,"retro_init");void (*run)(void)=dlsym(h,"retro_run");
        bool (*load)(const Game *)=dlsym(h,"retro_load_game");
        void (*deinit)(void)=dlsym(h,"retro_deinit");void (*unload)(void)=dlsym(h,"retro_unload_game");
        void (*setenv)(Environment)=dlsym(h,"retro_set_environment");
        void (*setvideo)(void *)=dlsym(h,"retro_set_video_refresh");
        void (*setaudio)(void *)=dlsym(h,"retro_set_audio_sample");
        void (*setbatch)(void *)=dlsym(h,"retro_set_audio_sample_batch");
        void (*setpoll)(void *)=dlsym(h,"retro_set_input_poll");
        void (*setinput)(void *)=dlsym(h,"retro_set_input_state");
        if(!init||!run||!load||!deinit||!unload||!setenv||!setvideo||!setaudio||!setbatch||!setpoll||!setinput){checkpoint(@"missing_entrypoint");return;}
        Dl_info location={0};dladdr(init,&location);coreBase=(uintptr_t)location.dli_fbase;
        NSMutableArray *images=[NSMutableArray new];
        for(uint32_t i=0;i<_dyld_image_count();i++){
            const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
            if(header->magic!=MH_MAGIC_64)continue;
            const uint8_t *command=(const uint8_t *)(header+1);uint64_t textSize=0;
            for(uint32_t j=0;j<header->ncmds;j++){
                const struct load_command *load=(const void *)command;
                if(load->cmd==LC_SEGMENT_64){const struct segment_command_64 *seg=(const void *)command;
                    if(!strcmp(seg->segname,"__TEXT"))textSize=seg->vmsize;}
                command+=load->cmdsize;
            }
            [images addObject:@{@"name":@(_dyld_get_image_name(i)).lastPathComponent,
                @"base":@((uintptr_t)header),@"text_size":@(textSize)}];
        }
        report[@"loaded_images"]=images;
        setenv(environment);setvideo(video);setaudio(audio);setbatch(audioBatch);setpoll(poll);setinput(input);
        checkpoint(@"retro_init");init();checkpoint(@"retro_load_game");
        NSString *gamePath=[root stringByAppendingPathComponent:@"input/game.cxi"];
        Game game={gamePath.fileSystemRepresentation,NULL,0,NULL};
        report[@"actual_game_load_attempted"]=@YES;bool loaded=load(&game);
        report[@"retro_load_game_returned"]=@(loaded);checkpoint(loaded?@"retro_run":@"load_rejected");
        if(loaded){
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:120];
            while(!shutdownRequested&&runCalls<600&&deadline.timeIntervalSinceNow>0){
                ++runCalls;checkpoint(@"retro_run");run();
            }
            report[@"shutdown_requested"]=@(shutdownRequested);
            report[@"game_execution_completed"]=@(runCalls>0&&frames>0);
            checkpoint(@"retro_unload_game");unload();
        }
        checkpoint(@"retro_deinit");deinit();checkpoint(@"completed");
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(GameProbeApp.class));}}
