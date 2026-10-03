// Capability probe only. No game/plugin execution is claimed by this program.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdarg.h>
static void logger(int level,const char *format,...) {
    va_list args;va_start(args,format);vfprintf(stderr,format,args);va_end(args);
}
static bool environment(unsigned cmd,void *data) {
    switch(cmd) {
        case 27: *(void **)data=(void *)logger;return true;
        case 9: case 30: case 31: {
            NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            static const char *root; if(!root)root=strdup(dir.fileSystemRepresentation);
            *(const char **)data=root;return true;
        }
        case 15: ((const char **)data)[1]=NULL;return false;
        case 17: *(bool *)data=false;return true;
        case 10: case 11: case 16: case 18: case 35: case 53: case 69:return true;
        default:return false;
    }
}
@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
@end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableDictionary *report=[@{@"finished_IPA_game_plugin_executed":@NO} mutableCopy];
        for(NSString *name in @[@"device-core",@"platform-probe-core"]) {
            NSString *path=[NSBundle.mainBundle pathForResource:name ofType:@"dylib"];
            void *h=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
            NSMutableDictionary *result=[@{@"loaded":@(h!=NULL)} mutableCopy];
            if(!h)result[@"error"]=@(dlerror()?:"unknown dlopen failure");
            else {
                struct {const char *name,*version,*extensions;bool fullpath,extract;} info={0};
                void (*getinfo)(void *)=dlsym(h,"retro_get_system_info");
                void (*setenv)(void *)=dlsym(h,"retro_set_environment");
                void (*init)(void)=dlsym(h,"retro_init");
                void (*deinit)(void)=dlsym(h,"retro_deinit");
                result[@"libretro_entrypoints_present"]=@(getinfo&&setenv&&init&&deinit);
                if(getinfo) {getinfo(&info);result[@"name"]=@(info.name?:"");result[@"version"]=@(info.version?:"");}
                // Persist before init as well: a crash must not erase dlopen evidence.
                report[name]=result;
                NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
                [[NSJSONSerialization dataWithJSONObject:report options:2 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"probe.json"] atomically:YES];
                if(setenv&&init&&deinit){setenv((void *)environment);init();result[@"retro_init_returned"]=@YES;deinit();result[@"retro_deinit_returned"]=@YES;}
                dlclose(h);
            }
            report[name]=result;
        }
        report[@"probe_completed"]=@YES;
        NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:report options:2 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"probe.json"] atomically:YES];
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class));}}
