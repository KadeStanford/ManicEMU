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
static void command(unsigned cmd,unsigned arg){uint8_t p[24]={'M','P','K','1',0x80,0,0,2};p[8]=cmd>>8;p[9]=cmd;p[10]=arg>>8;p[11]=arg;MT_send(0xffff,p,24);loopback();MT_poll_receive();}
static id manager(void){return ((id (*)(id,SEL))objc_msgSend)(NSClassFromString(@"ManicTrade"),NSSelectorFromString(@"shared"));}
static void halt(NSString *reason){((void (*)(id,SEL,id))objc_msgSend)(manager(),NSSelectorFromString(@"halt:"),reason);}
static void call(NSString *method){((void (*)(id,SEL))objc_msgSend)(manager(),NSSelectorFromString(method));}
static unsigned recovery_presentations,exit_presentations;
static NSMutableDictionary *report;
@interface TestRoot : UIViewController @end
@implementation TestRoot
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if([vc isKindOfClass:UIAlertController.class]&&[((UIAlertController *)vc).title isEqual:@"Link paused"])recovery_presentations++;
    [super presentViewController:vc animated:animated completion:completion];
}
@end
@interface TestApp : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation TestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];UIViewController *root=[TestRoot new];root.view.backgroundColor=UIColor.systemBackgroundColor;
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
        NSDictionary *one=@{@"v":@"g3-fc4afeb-mtr4",@"room":@"00000000000000000000000000000001",@"code":@"BPRE"};
        NSDictionary *two=@{@"v":@"g3-fc4afeb-mtr4",@"room":@"00000000000000000000000000000002",@"code":@"BPGE"};
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
        // A frontend pause/resume around normal result/save processing must
        // round-trip without requesting explicit Reconnect.
        [[LibretroCore sharedInstance] pause];assert([[LibretroCore sharedInstance] isPaused]);
        [[LibretroCore sharedInstance] resume];loopback();assert(MT_frame(&gba)&&MT_phase()==MT_LINKED);
        [[LibretroCore sharedInstance] pause];assert(MT_phase()==MT_SUSPENDED&&[[LibretroCore sharedInstance] isPaused]);
        Class cls=NSClassFromString(@"ManicTrade");id manager=((id (*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
        SEL halt=NSSelectorFromString(@"halt:");((void (*)(id,SEL,id))objc_msgSend)(manager,halt,@"Synthetic unexpected drop");
        Ivar desired=class_getInstanceVariable(cls,"_dialog");id first=object_getIvar(manager,desired);
        ((void (*)(id,SEL,id))objc_msgSend)(manager,halt,@"Repeated disconnected callback");
        assert(first==object_getIvar(manager,desired)); // One interruption owns ONE recovery alert.
        report=[@{@"no_home_overlay":@YES,@"kept_existing_game_view":@YES,@"automatic_pairing_picker":@YES,@"rapid_discovery_updates_show_both_players":@YES,@"no_host_join_or_rom_fields":@YES,@"battery_and_state_backup_before_pairing":@YES,@"frontend_pause_suspends_link":@YES} mutableCopy];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(recovery_presentations==1); // Real pause + two repeated halt notifications own one presentation.
        report[@"unexpected_drop_has_one_recovery_presentation"]=@YES;
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        entry.data=strdup([[documents URLByAppendingPathComponent:@"active.sav"].path UTF8String]);entry.attr.i=0;
        files.elems=&entry;files.size=files.cap=1;
        loopback();MT_resume();loopback();assert(MT_frame(&gba));[[LibretroCore sharedInstance] resume];
        ((void (*)(id,SEL,id))objc_msgSend)(manager(),NSSelectorFromString(@"tick:"),nil);
        MT_serial_state(1);loopback();MT_serial_state(0);loopback();assert(MT_frame(&gba)&&MT_phase()==MT_LINKED);
        MT_serial_state(1);loopback();assert(MT_frame(&gba)&&save_calls==0);
        command(0x2222,0x1111);
        // Queue recovery behind a UI transition, then accept both exit-room keys.
        // Neither stale animation completions nor later disconnects may show it.
        [manager() setValue:@YES forKey:@"_uiBusy"];halt(@"Queued stale pause");
        loopback();MT_resume();loopback();assert(MT_frame(&gba));
        command(0xcafe,0x17);MT_serial_state(0);loopback();assert(MT_terminal_exit());
        exit_presentations=recovery_presentations;halt(@"Late terminal disconnect");
        assert(![manager() valueForKey:@"_dialog"]&&![manager() valueForKey:@"_recoveryDialog"]);
        battery[0]=0x99;state[0]=0xaa;assert(MT_frame(&gba)&&MT_finishing());loopback();assert(MT_frame(&gba)&&MT_complete());
        [manager() setValue:@NO forKey:@"_uiBusy"];call(@"publishDialog");halt(@"Repeated completed callback");halt(@"Another completed callback");
        assert(save_calls==1&&![[LibretroCore sharedInstance] isPaused]);
        NSData *saved=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:entry.data]];assert(saved.length==MT_SAVE_SIZE&&((const uint8_t *)saved.bytes)[0]==0x99);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,7*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(MT_phase()==MT_IDLE&&!root.presentedViewController&&root.view.subviews.count==2);
        assert(recovery_presentations==exit_presentations);
        report[@"queued_stale_recovery_cancelled_on_terminal_exit"]=@YES;
        report[@"ordinary_exit_and_repeated_callbacks_have_zero_recovery_presentations"]=@YES;
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
        NSData *diagnostics=[NSData dataWithContentsOfURL:[[documents URLByAppendingPathComponent:@"ManicTradeDiagnostics"] URLByAppendingPathComponent:@"latest.txt"]];
        assert(diagnostics.length>0&&diagnostics.length<24576);NSString *trace=[[NSString alloc] initWithData:diagnostics encoding:NSUTF8StringEncoding];
        assert([trace containsString:@"serial-off"]&&[trace containsString:@"complete"]);
        report[@"temporary_hardware_close_keeps_frontend_and_save"]=@YES;report[@"bounded_metadata_diagnostics_written"]=@YES;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        // Real gpSP fresh-handshake detection is checked in gba_peer. Here the
        // frontend receives its checkpoint and must show discovery anew.
        MT_request();assert(MT_phase()==MT_WAITING);assert(!MT_frame(&gba));
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(MT_phase()==MT_WAITING&&[root.presentedViewController isKindOfClass:UIAlertController.class]);
        assert([((UIAlertController *)root.presentedViewController).title isEqual:@"Nearby players"]);
        report[@"colosseum_reentry_gets_fresh_discovery_picker"]=@YES;
        uint8_t session[16]={2};MT_connect(0,session);assert(MT_frame(&gba));MT_serial_state(1);loopback();command(0x2222,0x2233);
        assert(MT_mode()==MT_MODE_SINGLE_BATTLE);halt(@"New battle interruption");id first=[manager() valueForKey:@"_dialog"];
        halt(@"Repeated new interruption");assert(first==[manager() valueForKey:@"_dialog"]);
        MT_failure("Synthetic fatal packet loss");halt(@"Fatal packet loss");id fatal=[manager() valueForKey:@"_dialog"];
        assert(fatal!=first&&[fatal isKindOfClass:UIAlertController.class]);
        for(UIAlertAction *action in ((UIAlertController *)fatal).actions)assert(![action.title isEqual:@"Reconnect"]);
        halt(@"Repeated fatal callback");assert(fatal==[manager() valueForKey:@"_dialog"]);
        report[@"new_interruptions_can_recover_and_fatal_errors_escalate"]=@YES;
        call(@"cleanup");MT_unloaded();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(!root.presentedViewController&&root.view.subviews.count==2);
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];assert([json writeToURL:[documents URLByAppendingPathComponent:@"smoke.json"] atomically:YES]);
        NSLog(@"PASS: terminal exit, single recovery UI, stale alert cancellation and fresh Colosseum discovery");
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
