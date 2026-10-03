// Native UIKit integration smoke test. This is a test frontend, not Manic itself.
#import <UIKit/UIKit.h>
#include "TradeCore.h"
#include <assert.h>
#include <string.h>
@interface LibretroCore : NSObject
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion;
@end
@implementation LibretroCore
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion {return YES;}
@end
static uint8_t battery[MT_SAVE_SIZE],state[512];
static void start(unsigned role){}static void receive(const void *p,size_t n,unsigned peer){}static void stop(void){}
static size_t size(void){return sizeof(state);}static bool save(void *p,size_t n){memcpy(p,state,n);return true;}static bool load(const void *p,size_t n){memcpy(state,p,n);return true;}
static MTGBA gba={start,receive,stop,size,save,load,battery};
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UIAlertController *picker=(UIAlertController *)root.presentedViewController;
        assert([picker isKindOfClass:UIAlertController.class]&&[picker.title isEqual:@"Nearby players"]);
        assert(MT_phase()==MT_WAITING&&root.view.subviews.count==2);assert([picker.actions.lastObject.title isEqual:@"Cancel"]);
        for(UIAlertAction *a in picker.actions)assert(![a.title containsString:@"Host"]&&![a.title containsString:@"Join"]);
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *base=[documents URLByAppendingPathComponent:@"ManicTradeBackups"];
        NSArray<NSURL *> *folders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:base includingPropertiesForKeys:nil options:0 error:nil];assert(folders.count==1);
        NSData *saved=[NSData dataWithContentsOfURL:[folders[0] URLByAppendingPathComponent:@"synthetic.sav"]];assert(saved.length==MT_SAVE_SIZE&&((const uint8_t *)saved.bytes)[0]==0x45);
        NSData *checkpoint=[NSData dataWithContentsOfURL:[folders[0] URLByAppendingPathComponent:@"pre-trade.gpspstate"]];assert(checkpoint.length==sizeof(state)&&((const uint8_t *)checkpoint.bytes)[0]==0x67);
        NSDictionary *report=@{@"no_home_overlay":@YES,@"kept_existing_game_view":@YES,@"automatic_pairing_picker":@YES,@"no_host_join_or_rom_fields":@YES,@"battery_and_state_backup_before_pairing":@YES};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];assert([json writeToURL:[documents URLByAppendingPathComponent:@"smoke.json"] atomically:YES]);
        NSLog(@"PASS: GBA in-game discovery picker and automatic backup UI smoke");
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
