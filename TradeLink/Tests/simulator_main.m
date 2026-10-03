// Native UIKit integration smoke test. This is a test frontend, not Manic itself.
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "TradeCore.h"
#include "../iOS/FrontendSave.h"
#include <assert.h>
#include <string.h>
@interface LibretroCore : NSObject
+ (instancetype)sharedInstance;
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion;
- (void)pause;
- (void)resume;
- (BOOL)isPaused;
@end
@implementation LibretroCore {BOOL _paused;}
+ (instancetype)sharedInstance {static LibretroCore *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion {return YES;}
- (void)pause {_paused=YES;}
- (void)resume {_paused=NO;}
- (BOOL)isPaused {return _paused;}
@end
static uint8_t battery[MT_SAVE_SIZE],state[512];
static void start(unsigned role){}static void receive(const void *p,size_t n,unsigned peer){}static void stop(void){}
static size_t size(void){return sizeof(state);}static bool save(void *p,size_t n){memcpy(p,state,n);return true;}static bool load(const void *p,size_t n){memcpy(state,p,n);return true;}
static MTGBA gba={start,receive,stop,size,save,load,battery,NULL};
static struct MTSaveList files;static struct MTSaveEntry entry;static unsigned save_calls;
void *savefile_ptr_get(void){save_calls++;return &files;}
static void loopback(void){uint8_t p[56],ack[56];while(MT_next_packet(0,p)){assert(MT_receive_packet(p,56,ack)>=0);assert(MT_receive_packet(ack,56,p)==2);}}
static NSMutableDictionary *report;
@interface TestApp : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation TestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];UIViewController *root=[UIViewController new];root.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(30,150,320,80)];label.text=@"Running game: normal screen";label.accessibilityIdentifier=@"normal-game-screen";[root.view addSubview:label];
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.frame=CGRectMake(70,400,200,60);[button setTitle:@"Original game controls" forState:UIControlStateNormal];[root.view addSubview:button];
    self.window.rootViewController=root;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(!root.presentedViewController&&root.view.subviews.count==2); // No home overlay or setup UI.
        battery[0]=0x45;state[0]=0x67;MT_loaded("/legal/synthetic.gba",(const uint8_t *)"BPRE");assert(MT_active());MT_request();assert(!MT_frame(&gba));
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        // Rapid discovery changes must rebuild the visible list without stacking
        // new alerts on an alert that is still being dismissed.
        Class cls=NSClassFromString(@"ManicTrade");id<MCNearbyServiceBrowserDelegate> manager=((id (*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
        MCNearbyServiceBrowser *browser=object_getIvar(manager,class_getInstanceVariable(cls,"_browser"));
        NSDictionary *one=@{@"v":@"g3-fc4afeb-mtr2",@"room":@"00000000000000000000000000000001",@"code":@"BPRE"};
        NSDictionary *two=@{@"v":@"g3-fc4afeb-mtr2",@"room":@"00000000000000000000000000000002",@"code":@"BPGE"};
        [manager browser:browser foundPeer:[[MCPeerID alloc] initWithDisplayName:@"Player One"] withDiscoveryInfo:one];
        [manager browser:browser foundPeer:[[MCPeerID alloc] initWithDisplayName:@"Player Two"] withDiscoveryInfo:two];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UIAlertController *picker=(UIAlertController *)root.presentedViewController;
        assert([picker isKindOfClass:UIAlertController.class]&&[picker.title isEqual:@"Nearby players"]);
        assert(MT_phase()==MT_WAITING&&root.view.subviews.count==2);assert([picker.actions.lastObject.title isEqual:@"Cancel"]);
        assert(picker.actions.count==3); // Both nearby players are visible.
        for(UIAlertAction *a in picker.actions)assert(![a.title containsString:@"Host"]&&![a.title containsString:@"Join"]);
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *base=[documents URLByAppendingPathComponent:@"ManicTradeBackups"];
        NSArray<NSURL *> *folders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:base includingPropertiesForKeys:nil options:0 error:nil];assert(folders.count==1);
        NSData *saved=[NSData dataWithContentsOfURL:[folders[0] URLByAppendingPathComponent:@"synthetic.sav"]];assert(saved.length==MT_SAVE_SIZE&&((const uint8_t *)saved.bytes)[0]==0x45);
        NSData *checkpoint=[NSData dataWithContentsOfURL:[folders[0] URLByAppendingPathComponent:@"pre-trade.gpspstate"]];assert(checkpoint.length==sizeof(state)&&((const uint8_t *)checkpoint.bytes)[0]==0x67);
        uint8_t session[16]={1};MT_connect(0,session);assert(MT_frame(&gba));
        [[LibretroCore sharedInstance] pause];assert(MT_phase()==MT_SUSPENDED&&[[LibretroCore sharedInstance] isPaused]);
        report=[@{@"no_home_overlay":@YES,@"kept_existing_game_view":@YES,@"automatic_pairing_picker":@YES,@"rapid_discovery_updates_show_both_players":@YES,@"no_host_join_or_rom_fields":@YES,@"battery_and_state_backup_before_pairing":@YES,@"frontend_pause_suspends_link":@YES} mutableCopy];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        entry.data=strdup([[documents URLByAppendingPathComponent:@"active.sav"].path UTF8String]);entry.attr.i=0;
        files.elems=&entry;files.size=files.cap=1;
        loopback();MT_resume();loopback();assert(MT_frame(&gba));[[LibretroCore sharedInstance] resume];
        battery[0]=0x99;state[0]=0xaa;MT_leave();loopback();assert(!MT_complete());assert(MT_frame(&gba)&&MT_complete());
        assert(save_calls==1&&![[LibretroCore sharedInstance] isPaused]);
        NSData *saved=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:entry.data]];assert(saved.length==MT_SAVE_SIZE&&((const uint8_t *)saved.bytes)[0]==0x99);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,7*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(MT_phase()==MT_IDLE&&!root.presentedViewController&&root.view.subviews.count==2);
        assert(battery[0]==0x99&&state[0]==0xaa);MT_restore();MT_resume();assert(MT_phase()==MT_IDLE);
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSArray<NSURL *> *dirs=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[documents URLByAppendingPathComponent:@"ManicTradeBackups"] includingPropertiesForKeys:nil options:0 error:nil];assert(dirs.count==2);
        BOOL pre=NO,post=NO;
        for(NSURL *dir in dirs){
            NSData *old=[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"synthetic.sav"]];if(old)pre=((const uint8_t *)old.bytes)[0]==0x45;
            NSData *new=[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"current.sav"]];if(new)post=((const uint8_t *)new.bytes)[0]==0x99;
        }assert(pre&&post);
        report[@"normal_ending_has_no_reconnect_restore_dialog"]=@YES;report[@"active_frontend_save_path_flushed_and_verified"]=@YES;
        report[@"post_link_save_and_state_preserve_pre_link_backup"]=@YES;report[@"completed_session_cannot_restore_or_resume"]=@YES;
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];assert([json writeToURL:[documents URLByAppendingPathComponent:@"smoke.json"] atomically:YES]);
        NSLog(@"PASS: GBA discovery, frontend save persistence and ordinary ending UI smoke");
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
