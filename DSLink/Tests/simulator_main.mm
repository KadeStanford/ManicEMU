// Synthetic UIKit/frontend boundary test. No game, firmware or real save input.
#include "../iOS/Nearby.mm"
#include "../iOS/GeneratedConsole.h"
#include <stdexcept>
#include <thread>
#include <chrono>
#include <functional>
static unsigned pauseCalls=0,resumeCalls=0,starts=0,stops=0,received=0;
static bool wrongThread=false,hasPath=true;
static Bytes coreReceived,peerReceived;
static uint8_t testBattery[512],testState[64];
static MTSaveEntry testEntry{};static MTSaveList testFiles{};
extern "C" void *savefile_ptr_get(){return hasPath?&testFiles:nullptr;}
@interface LibretroCore:NSObject
-(void)pause;-(void)resume;
@end
@implementation LibretroCore
-(void)pause{pauseCalls++;}-(void)resume{resumeCalls++;}
@end
static void *memory(unsigned n){return n==RETRO_MEMORY_SAVE_RAM?testBattery:nullptr;}
static size_t memorySize(unsigned n){return n==RETRO_MEMORY_SAVE_RAM?sizeof(testBattery):0;}
static size_t stateSize(){return sizeof(testState);}
static bool serialize(void *p,size_t n){if(n!=sizeof(testState))return false;memcpy(p,testState,n);return true;}
static bool wirelessIdentity(uint8_t *out){const uint8_t mac[]{0,9,191,1,2,3};memcpy(out,mac,6);return true;}
static void startCore(uint16_t id,retro_netpacket_send_t send,retro_netpacket_poll_receive_t poll){(void)id;(void)send;(void)poll;starts++;wrongThread|=NSThread.isMainThread;}
static void receiveCore(const void *p,size_t n,uint16_t id){(void)id;coreReceived.assign(static_cast<const uint8_t*>(p),static_cast<const uint8_t*>(p)+n);received++;wrongThread|=NSThread.isMainThread;}
static void stopCore(){stops++;wrongThread|=NSThread.isMainThread;}
static NSMutableDictionary *results;
// Model the already-open main-thread Realm boundary. An attempted second open
// fails, as a differently configured read-only Realm does in the real SDK.
static unsigned realmOpens=0;
static NSURL *cachedPath;
@interface RLMRealmConfiguration:NSObject
@property(strong) NSURL *fileURL;
+(id)defaultConfiguration;
@end
@implementation RLMRealmConfiguration
+(id)defaultConfiguration{return [self new];}
@end
@interface RLMScheduler:NSObject
+(id)dispatchQueue:(dispatch_queue_t)queue;
@end
@implementation RLMScheduler
+(id)dispatchQueue:(dispatch_queue_t)queue{(void)queue;return @"main scheduler";}
@end
@interface RLMRealm:NSObject
+(id)realmWithConfiguration:(id)configuration error:(NSError**)error;
-(id)objectWithClassName:(NSString*)name forPrimaryKey:(id)key;
@end
@implementation RLMRealm
+(id)realmWithConfiguration:(id)configuration error:(NSError**)error{(void)configuration;(void)error;realmOpens++;return nil;}
-(id)objectWithClassName:(NSString*)name forPrimaryKey:(id)key{
    if(!NSThread.isMainThread||![name isEqual:@"Settings"]||![key isEqual:@"SettingsDefault"])return nil;
    return @{@"extras":[NSJSONSerialization dataWithJSONObject:@{@"nickname":@"Existing Manic Player"} options:0 error:nil]};
}
@end
static id testCachedRealm(id config,id scheduler){cachedPath=[config fileURL];return NSThread.isMainThread&&[scheduler isEqual:@"main scheduler"]?[RLMRealm new]:nil;}
static void check(NSString *name,bool value){results[name]=@(value);if(!value)throw std::runtime_error(name.UTF8String);}
static void waitUntil(std::function<bool()> condition){for(unsigned i=0;i<400;i++){if(condition())return;std::this_thread::sleep_for(std::chrono::milliseconds(5));}throw std::runtime_error("synthetic callback timeout");}

static std::mutex peerLock;
static NSMutableDictionary<MCPeerID*,NSValue*> *mockRooms;
static std::vector<std::unique_ptr<Room>> owned;
static std::vector<Nonce> identities;
static MCPeerID *peers[3];
@interface TestBrowser:MCNearbyServiceBrowser
@property unsigned invitations;
@end
@implementation TestBrowser
-(void)invitePeer:(MCPeerID*)peer toSession:(MCSession*)session withContext:(NSData*)context timeout:(NSTimeInterval)timeout{(void)peer;(void)session;(void)context;(void)timeout;self.invitations++;}
@end
@interface TestSession:MCSession
@property(strong) NSArray<MCPeerID*> *mockPeers;
@end
@implementation TestSession
-(NSArray<MCPeerID*>*)connectedPeers{return self.mockPeers?:@[];}
-(BOOL)sendData:(NSData*)data toPeers:(NSArray<MCPeerID*>*)targets withMode:(MCSessionSendDataMode)mode error:(NSError**)error{
    (void)mode;(void)error;if(data.length>=4&&!memcmp(data.bytes,"MDH5",4))return YES;
    for(MCPeerID *peer in targets){std::vector<Bytes> frames,reply;
        {std::lock_guard<std::mutex> guard(peerLock);auto room=static_cast<Room*>([mockRooms[peer] pointerValue]);if(!room||!unbatchWire(data.bytes,data.length,frames))return NO;
            for(const auto &f:frames)if(!room->receive(g.nonce,f.data(),f.size()))return NO;
            Received packet;while(room->pop(packet))peerReceived=packet.data;reply=room->takeWire(g.nonce);}
        for(const auto &b:batchWire(reply))[[MDSNearby shared] session:self didReceiveData:[NSData dataWithBytes:b.data() length:b.size()] fromPeer:peer];
    }return YES;
}
@end
static void inject(TestSession *session,unsigned index){std::vector<Bytes> frames;
    {std::lock_guard<std::mutex> guard(peerLock);frames=owned[index]->takeWire(g.nonce);}
    for(const auto &b:batchWire(frames))[[MDSNearby shared] session:session didReceiveData:[NSData dataWithBytes:b.data() length:b.size()] fromPeer:peers[index]];
}
static bool settled(){std::lock_guard<std::mutex> guard(lock);return g.room&&g.room->pendingCount()==0;}
static NSDictionary *metadata(unsigned i,NSString *runtime){MAC alias=Room::address(identities[i]);NSMutableString *text=[NSMutableString new];for(auto b:alias)[text appendFormat:@"%02x",b];
    return @{@"v":WireVersion,@"ready":@"1",@"local":@"1",@"code":@"CPUE",@"rev":@"1",@"nonce":hexNonce(identities[i]),@"runtime":runtime,@"mac":@"0009bf010203",@"alias":text};
}
static void tests(){@autoreleasepool{
    results=[NSMutableDictionary new];NSString *errorText=nil;NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    try{
        MDSGeneratedConsole first{1,{},{}},second{1,{},{}};
        check(@"generated console identity provided",generatedConsole(&first));
        check(@"generated console identity stable across calls",generatedConsole(&second)&&!memcmp(first.mac,second.mac,6));
        check(@"generated console uses native unicast identity",first.mac[0]==0&&first.mac[1]==9&&first.mac[2]==191&&memcmp(first.mac,"\x00\x09\xbf\x11\x22\x33",6));
        MDSGeneratedConsole invalid{2,{},{}};check(@"unsupported identity request rejected",!generatedConsole(&invalid));
        invalid.version=1;invalid.reserved[0]=1;check(@"reserved identity request rejected",!generatedConsole(&invalid));
        check(@"Manic nickname preferred",[boundedPlayerName(@"Kade",@"iPhone") isEqual:@"Kade"]);
        check(@"device name fallback",[boundedPlayerName(nil,@"My iPhone") isEqual:@"My iPhone"]);
        check(@"name byte limit",[boundedPlayerName([@"abcdefgh" stringByPaddingToLength:100 withString:@"abcdefgh" startingAtIndex:0],nil) lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=63);
        dispatch_sync(dispatch_get_main_queue(),^{NSURL *url=[NSURL fileURLWithPath:@"/synthetic/Library/Realm/default.realm"];
            check(@"cached nickname without reopening Realm",[nicknameFromCachedRealm(url,testCachedRealm) isEqual:@"Existing Manic Player"]&&realmOpens==0);
            check(@"absent cached nickname fallback",nicknameFromCachedRealm(url,nullptr)==nil&&realmOpens==0);});
        check(@"Realm refused on emulation thread",configuredNickname()==nil);
        auto begin=std::chrono::steady_clock::now();MDS_waitForPackets(1000);check(@"idle wait yields",std::chrono::steady_clock::now()-begin>=std::chrono::microseconds(500));
        memset(testBattery,0x51,sizeof(testBattery));memset(testState,0x73,sizeof(testState));
        NSString *path=[[docs URLByAppendingPathComponent:@"synthetic.srm"] path];NSData *before=[NSData dataWithBytes:testBattery length:sizeof(testBattery)];[before writeToFile:path atomically:YES];
        static std::string storage;storage=path.UTF8String;testEntry.data=storage.data();testEntry.attr.i=RETRO_MEMORY_SAVE_RAM;testFiles={&testEntry,1,1};
        MDSCore core{memory,memorySize,stateSize,serialize,wirelessIdentity,nullptr};MDS_gameLoaded("ADAE",5,core);retro_netpacket_callback callbacks{};callbacks.start=startCore;callbacks.receive=receiveCore;callbacks.stop=stopCore;MDS_netpacket(&callbacks);
        uint8_t infra[48]{};infra[13]=1;check(@"WFC excluded",!localFrame(infra,sizeof(infra),0));
        uint8_t local[48]{};local[16]=3;local[17]=9;local[18]=191;check(@"Nintendo local radio recognized",localFrame(local,sizeof(local),0));
        {std::lock_guard<std::mutex> guard(lock);g.radio=true;g.requested=true;}hasPath=false;MDS_afterFrame();check(@"save path verification blocks preparation",g.failedPrepare&&!g.prepared);check(@"failed preparation leaves battery intact",[[NSData dataWithContentsOfFile:path] isEqual:before]);
        MDS_gameLoaded("ADAE",5,core);hasPath=true;{std::lock_guard<std::mutex> guard(lock);g.radio=true;g.intent=true;g.requested=true;}MDS_afterFrame();check(@"independent save checkpoint prepared",g.prepared&&[g.savePath isEqual:path]);
        MAC native{0,9,191,1,2,3};for(unsigned i=0;i<3;i++){Nonce n{};n[0]=uint8_t(i+10);n[15]=uint8_t(i+20);identities.push_back(n);owned.push_back(std::make_unique<Room>(n,"CPUE",1,native));owned.back()->radio(true);check(@"independent peer accepts local room",owned.back()->add(g.nonce,"ADAE",5,Room::address(g.nonce)));}
        __block TestSession *session;__block TestBrowser *browser;__block MCNearbyServiceAdvertiser *advertiser;
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *m=[MDSNearby shared];[m cleanup];[m setValue:@(g.epoch) forKey:@"generation"];[m setValue:@YES forKey:@"prepared"];[m setValue:@"A" forKey:@"runtime"];
            MCPeerID *identity=[[MCPeerID alloc]initWithDisplayName:@"Kade"];session=[[TestSession alloc]initWithPeer:identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];m.session=session;
            browser=[[TestBrowser alloc]initWithPeer:identity serviceType:Service];advertiser=[[MCNearbyServiceAdvertiser alloc]initWithPeer:identity discoveryInfo:nil serviceType:Service];[m setValue:browser forKey:@"browser"];[m setValue:advertiser forKey:@"advertiser"];
            [m setValue:@{@"code":@"ADAE"} forKey:@"meta"];[m setValue:[NSMutableDictionary new] forKey:@"peers"];[m setValue:[NSMutableDictionary new] forKey:@"attempts"];[m setValue:[NSMutableDictionary new] forKey:@"retryAt"];
            {std::lock_guard<std::mutex> guard(lock);g.room=std::make_unique<Room>(g.nonce,g.code,g.revision,native);g.room->radio(true);[m setValue:[NSMutableDictionary new] forKey:@"wirePeers"];[m setValue:[NSMutableDictionary new] forKey:@"early"];}
            mockRooms=[NSMutableDictionary new];for(unsigned i=0;i<3;i++){peers[i]=[[MCPeerID alloc]initWithDisplayName:[NSString stringWithFormat:@"Player %u",i]];mockRooms[peers[i]]=[NSValue valueWithPointer:owned[i].get()];}
            NSMutableDictionary *known=[m valueForKey:@"peers"];known[peers[0]]=metadata(0,@"B");[m connectReadyPeers];[m connectReadyPeers];check(@"discovered peer invited automatically once",browser.invitations==1);
            NSDictionary *info=metadata(1,@"0");NSData *context=[NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            [m advertiser:advertiser didReceiveInvitationFromPeer:peers[1] withContext:context invitationHandler:^(BOOL accept,MCSession *target){check(@"automatic incoming acceptance uses existing session",accept&&target==session&&[m valueForKey:@"notice"]==nil);}];
        });
        dispatch_sync(dispatch_get_main_queue(),^{});check(@"unconnected discovery does not pause game",MDS_beforeFrame()&&starts==0);
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *m=[MDSNearby shared];session.mockPeers=@[peers[0],peers[1]];
            NSMutableDictionary *known=[m valueForKey:@"peers"];known[peers[0]]=metadata(0,@"B");known[peers[1]]=metadata(1,@"C");
            inject(session,0);check(@"early Ready buffered by peer",[[m valueForKey:@"early"] count]==1);
            [m session:session peer:peers[0] didChangeState:MCSessionStateConnected];[m session:session peer:peers[1] didChangeState:MCSessionStateConnected];});
        waitUntil([]{std::lock_guard<std::mutex> guard(lock);return g.room&&g.room->size()==2&&g.room->active();});waitUntil(settled);
        check(@"two peers join shared radio without prompts",MDS_beforeFrame()&&starts==1&&g.room->size()==2);
        check(@"active radio blocks state restoration",!MDS_allowRestore());
        uint8_t packet[100]{};packet[22]=0x80;std::copy(native.begin(),native.end(),packet+32);std::copy(native.begin(),native.end(),packet+38);std::copy(native.begin(),native.end(),packet+70);
        for(unsigned i=0;i<100;i++)sendPacket(0,packet,sizeof(packet),65535);waitUntil(settled);check(@"reliable shared burst drains ACKs",g.room->pendingCount()==0);
        {std::lock_guard<std::mutex> guard(peerLock);owned[0]->send(packet,sizeof(packet));}inject(session,0);check(@"SDK delegate never invokes core receive",received==0);MDS_beforeFrame();check(@"native receive stays on core thread",received==1&&!wrongThread);
        uint16_t oldSlot=g.room->slot(identities[0]);dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *m=[MDSNearby shared];session.mockPeers=@[peers[0],peers[1],peers[2]];NSMutableDictionary *known=[m valueForKey:@"peers"];known[peers[2]]=metadata(2,@"D");[m session:session peer:peers[2] didChangeState:MCSessionStateConnected];});
        waitUntil([]{std::lock_guard<std::mutex> guard(lock);return g.room->size()==3&&g.room->pendingCount()==0;});check(@"third arrival preserves established routing",g.room->slot(identities[0])==oldSlot&&starts==1);
        dispatch_sync(dispatch_get_main_queue(),^{[[MDSNearby shared] remove:peers[1]];session.mockPeers=@[peers[0],peers[2]];});check(@"one departed peer leaves other consoles active",g.room->size()==2&&g.room->active()&&MDS_beforeFrame()&&starts==1);
        LibretroCore *front=[LibretroCore new];dispatch_sync(dispatch_get_main_queue(),^{installPauseHooks();});[front pause];check(@"local frontend pause chained",pauseCalls==1&&!MDS_beforeFrame());[front resume];waitUntil(settled);check(@"local resume has no chooser",resumeCalls==1&&MDS_beforeFrame());
        testBattery[0]=0x92;for(unsigned i=0;i<60;i++)MDS_afterFrame();check(@"current battery persists independently",((const uint8_t*)[NSData dataWithContentsOfFile:path].bytes)[0]==0x92);
        MDS_signal(2,nullptr);MDS_beforeFrame();check(@"normal native radio shutdown stops core",stops==1&&!g.started);check(@"room exit retains current save",((const uint8_t*)[NSData dataWithContentsOfFile:path].bytes)[0]==0x92);
        MDS_signal(1,nullptr);MDS_beforeFrame();check(@"native reentry starts existing room without pairing dialog",starts==2&&g.started);
        uint8_t original[6]{};wirelessIdentity(original);check(@"firmware identity untouched",std::equal(native.begin(),native.end(),original));
        MDS_gameUnloading();check(@"game unload clears all room state",!g.room&&!g.loaded&&!g.prepared);check(@"native callbacks stay on emulator thread",!wrongThread);
    }catch(const std::exception &e){errorText=[NSString stringWithUTF8String:e.what()];}
    NSDictionary *report=@{@"checks":results,@"error":errorText?:NSNull.null,@"synthetic_save_only":@YES,@"actual_game_trade_verified":@NO,@"physical_iPhone_verified":@NO};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[docs URLByAppendingPathComponent:@"smoke.json"] atomically:YES];
}}
@interface TestScene:NSObject<UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation TestScene
-(void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options{
    (void)session;(void)options;self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene*)scene];self.window.rootViewController=[UIViewController new];self.window.rootViewController.view.backgroundColor=UIColor.systemBackgroundColor;[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{tests();});
}
@end
@interface TestApp:UIResponder<UIApplicationDelegate>@end
@implementation TestApp
-(BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{(void)app;(void)options;return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
