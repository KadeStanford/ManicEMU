#import <UIKit/UIKit.h>
#include <stdint.h>
#include <string.h>

extern unsigned ManicOriginalFrameSkip(void *state,uint64_t now,unsigned target);
extern unsigned ManicCorrectedFrameSkip(void *state,uint64_t now,unsigned target);
typedef unsigned (*Gate)(void *,uint64_t,unsigned);
static int32_t counter(void *state){int32_t v;memcpy(&v,(char *)state+0xd10,4);return v;}
static int8_t tracking(void *state){int8_t v;memcpy(&v,(char *)state+0xd14,1);return v;}
static void setup(void *state,uint64_t previous,int32_t count,int8_t phase){
    memset(state,0,4096);memcpy((char *)state+0xcf0,&previous,8);
    memcpy((char *)state+0xd10,&count,4);memcpy((char *)state+0xd14,&phase,1);
}
static NSArray *call(Gate gate,uint64_t elapsed,unsigned target,int32_t count,int8_t phase,uint64_t previous){
    uint8_t state[4096] __attribute__((aligned(16)));setup(state,previous,count,phase);
    unsigned render=gate(state,previous+elapsed,target);
    uint64_t recorded;memcpy(&recorded,state+0xcf0,8);
    NSCAssert(recorded==previous+elapsed,@"Timestamp update preserved");
    return @[@(render),@(counter(state)),@(tracking(state))];
}
@interface Delegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation Delegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(),^{
        unsigned cases=0,shortMatches=0,longRendered=0;BOOL passed=YES;
        for(unsigned targetIndex=0;targetIndex<4;targetIndex++){
            unsigned target=((unsigned[]){8333,16666,33333,65535})[targetIndex];
            uint64_t delays[]={0,1,target/2,target-1,target,target+1,65535,65536,65537,131072,1000000,3600000000ULL};
            for(unsigned d=0;d<12;d++)for(int phase=-1;phase<=1;phase++)for(unsigned c=0;c<3;c++){
                int32_t count=((int32_t[]){0,target/2,target-1})[c];
                NSArray *original=call(ManicOriginalFrameSkip,delays[d],target,count,phase,1000000);
                NSArray *corrected=call(ManicCorrectedFrameSkip,delays[d],target,count,phase,1000000);
                if(delays[d]<=65535){passed&=[original isEqual:corrected];shortMatches++;}
                else if(phase){passed&=[corrected[0] boolValue];longRendered++;}
                passed&=[corrected[1] intValue]>=0&&[corrected[1] unsignedIntValue]<=target;
                cases+=2;
            }
        }
        uint8_t oldState[4096] __attribute__((aligned(16))),newState[4096] __attribute__((aligned(16)));
        setup(oldState,1000000,0,1);setup(newState,1000000,0,1);
        unsigned oldRendered=0,newRendered=0;
        for(unsigned frame=1;frame<=12;frame++){
            oldRendered+=ManicOriginalFrameSkip(oldState,1000000+frame*65536ULL,16666);
            newRendered+=ManicCorrectedFrameSkip(newState,1000000+frame*65536ULL,16666);cases+=2;
        }
        passed&=oldRendered==0&&newRendered==12;
        for(unsigned t=0;t<3;t++)for(unsigned d=0;d<4;d++){
            uint64_t previous=((uint64_t[]){0xffffffffULL-1000,0x100000000ULL,UINT64_MAX-1000})[t];
            uint64_t elapsed=((uint64_t[]){2000,65536,131072,3600000000ULL})[d];
            NSArray *corrected=call(ManicCorrectedFrameSkip,elapsed,16666,0,1,previous);
            passed&=[corrected[0] boolValue]==(elapsed>=16666);cases++;
        }
        NSDictionary *report=@{@"passed":@(passed),@"native_ARM64_gate_calls":@(cases),
            @"short_interval_equivalent_cases":@(shortMatches),@"long_interval_rendered_cases":@(longRendered),
            @"repeated_65536us_original_rendered":@(oldRendered),@"repeated_65536us_corrected_rendered":@(newRendered),
            @"actual_game_or_MoltenVK_executed":@NO,@"physical_freeze_recovery_proven":@NO};
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[documents stringByAppendingPathComponent:@"frame-skip-simulator.json"] atomically:YES];
        NSLog(@"Frontend frame-skip regression: %@",report);
    });
    return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(Delegate.class));}}
