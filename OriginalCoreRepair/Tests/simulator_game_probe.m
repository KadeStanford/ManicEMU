// Standalone diagnostic frontend. Runs only private copies in a fresh sandbox.
#ifdef MANIC_GAME_MACOS
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif
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
#include <time.h>
#include <math.h>

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
static NSArray<NSDictionary *> *replayEvents;
static NSSet<NSNumber *> *replaySnapshots;
static unsigned replayCalls=3600;
static double replaySeconds=120;
static uint64_t audioSamples;
static double runSeconds,maximumRunSeconds;
static double monotonicSeconds(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec/1000000000.0;
}
static bool shouldSnapshot(void) {
    if(replaySnapshots)return [replaySnapshots containsObject:@(runCalls)];
    return runCalls==600||runCalls==1800||runCalls==2050||runCalls==3000||runCalls==3250;
}
static bool configureReplay(void) {
    NSString *path=NSProcessInfo.processInfo.environment[@"MANIC_PROBE_REPLAY_SCRIPT"];
    if(!path.length)return true;
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data||data.length>262144)return false;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![value isKindOfClass:NSDictionary.class])return false;
    NSDictionary *config=value;
    NSNumber *calls=config[@"max_run_calls"],*seconds=config[@"max_seconds"];
    if(![calls isKindOfClass:NSNumber.class]||! [seconds isKindOfClass:NSNumber.class]||
        calls.doubleValue!=calls.unsignedIntValue||calls.unsignedIntValue<1||calls.unsignedIntValue>20000||
        !isfinite(seconds.doubleValue)||seconds.doubleValue<1||seconds.doubleValue>600)return false;
    NSArray *events=config[@"events"],*snapshots=config[@"snapshots"];
    if(![events isKindOfClass:NSArray.class]||events.count>4096||
        ![snapshots isKindOfClass:NSArray.class]||snapshots.count>64)return false;
    for(id item in events){
        if(![item isKindOfClass:NSDictionary.class])return false;
        for(NSString *key in @[@"first_call",@"duration"])
            if(![item[key] isKindOfClass:NSNumber.class])return false;
        double first=[item[@"first_call"] doubleValue],duration=[item[@"duration"] doubleValue];
        if(!isfinite(first)||!isfinite(duration)||first!=floor(first)||duration!=floor(duration)||
            first<1||duration<1||first+duration>calls.doubleValue+1)return false;
        if(item[@"button"]){
            if(![item[@"button"] isKindOfClass:NSNumber.class])return false;
            double button=[item[@"button"] doubleValue];
            if(!isfinite(button)||button!=floor(button)||button<0||button>15)return false;
        } else {
            for(NSString *key in @[@"analog_index",@"analog_axis",@"value"])
                if(![item[key] isKindOfClass:NSNumber.class])return false;
            double stick=[item[@"analog_index"] doubleValue],axis=[item[@"analog_axis"] doubleValue],level=[item[@"value"] doubleValue];
            if(!isfinite(stick)||!isfinite(axis)||!isfinite(level)||stick!=floor(stick)||axis!=floor(axis)||level!=floor(level)||
                stick<0||stick>1||axis<0||axis>1||level<-32768||level>32767)return false;
        }
    }
    for(id item in snapshots)
        if(![item isKindOfClass:NSNumber.class]||!isfinite([item doubleValue])||[item doubleValue]!=[item unsignedIntValue]||
            [item unsignedIntValue]<1||[item unsignedIntValue]>calls.unsignedIntValue)return false;
    replayEvents=events;replaySnapshots=[NSSet setWithArray:snapshots];
    replayCalls=calls.unsignedIntValue;replaySeconds=seconds.doubleValue;return true;
}
static NSString *probeResource(NSString *name,NSString *extension) {
#ifdef MANIC_GAME_MACOS
    return [NSProcessInfo.processInfo.environment[@"MANIC_PROBE_RESOURCE_DIR"]
        stringByAppendingPathComponent:[name stringByAppendingPathExtension:extension]];
#else
    return [NSBundle.mainBundle pathForResource:name ofType:extension];
#endif
}
static NSData *probePNG(CGImageRef image) {
#ifdef MANIC_GAME_MACOS
    return [[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#else
    return UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
#endif
}
static void checkpoint(NSString *next) {
    stage=next;report[@"stage"]=next;report[@"run_calls"]=@(runCalls);
    report[@"frames"]=@(frames);report[@"nonblack_frames"]=@(nonblackFrames);
    report[@"audio_sample_frames"]=@(audioSamples);
    report[@"retro_run_seconds_total"]=@(runSeconds);
    report[@"retro_run_seconds_maximum"]=@(maximumRunSeconds);
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
#ifdef MANIC_GAME_VULKAN
#include "simulator_vulkan_frontend.h"
#endif
static bool environment(unsigned command,void *data) {
    unsigned cmd=command&~0x10000U;
#ifdef MANIC_GAME_VULKAN
    if(cmd==14||cmd==41||cmd==43||cmd==56||cmd==73)return vkEnvironment(cmd,data);
#endif
    switch(cmd) {
        case 27:*(void **)data=(void *)logger;return true;
        case 9:case 30:case 31:*(const char **)data=root.fileSystemRepresentation;return true;
        case 15:{Variable *v=data;
            if(!strcmp(v->key,"citra_graphics_api"))v->value=
#ifdef MANIC_GAME_VULKAN
                "Vulkan";
#else
                "Software";
#endif
            else if(!strcmp(v->key,"citra_use_cpu_jit"))v->value="disabled";
            else if(!strcmp(v->key,"citra_is_new_3ds"))v->value="New 3DS";
            else if(!strcmp(v->key,"citra_resolution_factor"))v->value="1";
#ifdef MANIC_GAME_MACOS
            else if(!strcmp(v->key,"citra_use_skip_duplicate_frames")){
                v->value=getenv("MANIC_PROBE_DUPLICATE_FRAMES");return v->value!=NULL;}
            else if(!strcmp(v->key,"citra_simulate_3ds_gpu_timings")){
                v->value=getenv("MANIC_PROBE_GPU_TIMINGS");return v->value!=NULL;}
#endif
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
#ifdef MANIC_GAME_VULKAN
    if(pixels==(void *)-1){vulkanVideo(width,height);return;}
#endif
    if(!pixels||pixels==(void *)-1)return;
    frames++;bool visible=false;
    for(unsigned y=0;y<height&&!visible;y+=MAX(1,height/32))
        for(unsigned x=0;x<width;x+=MAX(1,width/32))
            if((((const uint32_t *)((const uint8_t *)pixels+y*pitch))[x]&0xffffff)!=0){visible=true;break;}
    if(visible)nonblackFrames++;
    report[@"last_frame_dimensions"]=@[@(width),@(height)];
    NSString *snapshot=shouldSnapshot()?
        [NSString stringWithFormat:@"private-frame-%d.png",runCalls]:nil;
    if(snapshot){
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate((void *)pixels,width,height,8,pitch,space,
            kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
        if(context){CGImageRef image=CGBitmapContextCreateImage(context);
            [probePNG(image)
                writeToFile:[root stringByAppendingPathComponent:snapshot] atomically:YES];
            CGImageRelease(image);CGContextRelease(context);}
        CGColorSpaceRelease(space);
    }
}
static void audio(int16_t left,int16_t right){audioSamples++;}
static size_t audioBatch(const int16_t *samples,size_t count){audioSamples+=count;return count;}
static void poll(void){}
static int16_t input(unsigned port,unsigned device,unsigned index,unsigned id) {
    // A short Select press after execution has started; no save interaction.
    if(port!=0)return 0;
    if(replayEvents){
        for(NSDictionary *event in replayEvents){
            unsigned first=[event[@"first_call"] unsignedIntValue],duration=[event[@"duration"] unsignedIntValue];
            if(runCalls>=first&&runCalls-first<duration){
                if(device==1&&event[@"button"]&&id==[event[@"button"] unsignedIntValue])return 1;
                if(device==5&&!event[@"button"]&&index==[event[@"analog_index"] unsignedIntValue]&&id==[event[@"analog_axis"] unsignedIntValue])
                    return [event[@"value"] shortValue];
            }
        }
        return 0;
    }
    if(device!=1)return 0;
    // Vapecord displays its own first-run notice before entering the menu loop.
    // Acknowledge it, then open, close and reopen the menu without selecting codes.
    if(id==8)return runCalls>=1200&&runCalls<1206;
    return id==2&&((runCalls>=2000&&runCalls<2006)||
        (runCalls>=2500&&runCalls<2506)||(runCalls>=3200&&runCalls<3206));
}
static void runProbe(void) {
#ifdef MANIC_GAME_MACOS
        root=NSProcessInfo.processInfo.environment[@"MANIC_PROBE_DATA_DIR"];
        if(!root.length)abort();
#else
        root=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
#endif
        report=[@{@"actual_game_load_attempted":@NO,@"game_execution_completed":@NO,
            @"plugin_menu_verified":@NO,@"renderer":@"Software",
            @"original_inputs_and_saves_unchanged":@YES} mutableCopy];
        if(!configureReplay()){checkpoint(@"invalid_replay_configuration");return;}
        report[@"replay_enabled"]=@(replayEvents!=nil);
        report[@"Isabelle_scene_passed_verified"]=@NO;
        report[@"physical_phone_FPS_verified"]=@NO;
#ifdef MANIC_GAME_VULKAN
        report[@"host_frontend_waits_GPU_every_frame"]=@YES;
#endif
#ifdef MANIC_GAME_VULKAN
        report[@"renderer"]=@"Vulkan";
#endif
        logFD=open([root stringByAppendingPathComponent:@"core-runtime.log"].fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);
        // Keep driver assertions and C++ termination details in encrypted evidence.
        // The runner never publishes this log unencrypted.
        if(logFD>=0){dup2(logFD,STDOUT_FILENO);dup2(logFD,STDERR_FILENO);}
        signalFD=open([root stringByAppendingPathComponent:@"fatal-signal.bin"].fileSystemRepresentation,O_CREAT|O_WRONLY|O_EXCL,0600);
        struct sigaction action={0};action.sa_sigaction=fatalSignal;action.sa_flags=SA_SIGINFO;
        int signals[]={SIGABRT,SIGBUS,SIGILL,SIGSEGV,SIGTRAP};
        for(unsigned i=0;i<sizeof(signals)/sizeof(signals[0]);i++)sigaction(signals[i],&action,NULL);
        if([NSProcessInfo.processInfo.environment[@"MANIC_PROBE_SIGNAL_TEST"] isEqualToString:@"1"]){
            checkpoint(@"diagnostic_signal_self_test");raise(SIGSEGV);return;
        }
        checkpoint(@"dlopen");
        void *h=dlopen([probeResource(@"game-probe-core",@"dylib") fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
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
        checkpoint(@"retro_init");init();
        // This diagnostic core is hash-guarded by the runner. Its logging Impl
        // reads the Filter at +0x00; ParseFilterString takes a string_view in
        // x1/x2. Only verbosity changes, after initialization and before loading.
        void *logging=*(void **)(coreBase+0xff2da0);
        if(logging){
            const char *filter="*:Warning Service.PLGLDR:Debug Loader:Info";
            void (*parseFilter)(void *,const char *,size_t)=(void *)(coreBase+0x4e526c);
            parseFilter(logging,filter,strlen(filter));
            report[@"plugin_diagnostic_logging_enabled"]=@YES;
        }
        checkpoint(@"retro_load_game");
        NSString *gamePath=[root stringByAppendingPathComponent:@"input/game.cxi"];
        Game game={gamePath.fileSystemRepresentation,NULL,0,NULL};
        report[@"actual_game_load_attempted"]=@YES;bool loaded=load(&game);
        report[@"retro_load_game_returned"]=@(loaded);checkpoint(loaded?@"retro_run":@"load_rejected");
#ifdef MANIC_GAME_VULKAN
        if(loaded){
            if(!initializeVulkan()){report[@"vulkan_initialization_failed"]=@YES;checkpoint(@"vulkan_initialization_failed");return;}
            Dl_info driver={0};dladdr(vkGet,&driver);
            const struct mach_header_64 *h=driver.dli_fbase;const uint8_t *command=(const void *)(h+1);uint64_t size=0;
            for(uint32_t i=0;i<h->ncmds;i++){const struct load_command *l=(const void *)command;
                if(l->cmd==LC_SEGMENT_64){const struct segment_command_64 *s=(const void *)command;if(!strcmp(s->segname,"__TEXT"))size=s->vmsize;}command+=l->cmdsize;}
            [images addObject:@{@"name":@"moltenvk-probe.dylib",@"base":@((uintptr_t)driver.dli_fbase),@"text_size":@(size)}];report[@"loaded_images"]=images;
            checkpoint(@"vulkan_context_reset");
            if(!hardware.context_reset){checkpoint(@"missing_vulkan_context_reset");return;}
            hardware.context_reset();report[@"vulkan_context_reset_returned"]=@YES;
        }
#endif
        if(loaded){
            double start=monotonicSeconds();
            while(!shutdownRequested&&runCalls<replayCalls&&monotonicSeconds()-start<replaySeconds){
                ++runCalls;
                if(!replayEvents||runCalls==1||runCalls%120==0)checkpoint(@"retro_run");
                double callStart=monotonicSeconds();run();double elapsed=monotonicSeconds()-callStart;
                runSeconds+=elapsed;maximumRunSeconds=MAX(maximumRunSeconds,elapsed);
            }
            report[@"execution_wall_seconds"]=@(monotonicSeconds()-start);
            report[@"shutdown_requested"]=@(shutdownRequested);
            report[@"game_execution_completed"]=@(runCalls>0&&frames>0);
            checkpoint(@"retro_unload_game");unload();
        }
        checkpoint(@"retro_deinit");deinit();checkpoint(@"completed");
}
#ifdef MANIC_GAME_MACOS
int main(int argc,char **argv){@autoreleasepool{runProbe();return 0;}}
#else
@interface GameProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation GameProbeApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{runProbe();});return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(GameProbeApp.class));}}
#endif
