// Synthetic UIKit/frontend boundary test. No game, firmware or real save input.
#include "../iOS/Nearby.mm"
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
static std::mutex peerLock;
static std::unique_ptr<manicds::Protocol> other;
static NSMutableDictionary *results;
static void check(NSString *name,bool value){results[name]=@(value);if(!value)throw std::runtime_error(name.UTF8String);}
static void waitUntil(std::function<bool()> condition){for(unsigned i=0;i<400;i++){if(condition())return;std::this_thread::sleep_for(std::chrono::milliseconds(5));}throw std::runtime_error("synthetic callback timeout");}
@interface TestSession:MCSession
@property BOOL holdAcks;
@property(strong) NSMutableArray<NSData*> *savedReplies;
@end
@implementation TestSession
-(BOOL)sendData:(NSData*)data toPeers:(NSArray<MCPeerID*>*)peers withMode:(MCSessionSendDataMode)mode error:(NSError**)error{
    (void)peers;(void)mode;(void)error;std::vector<Bytes> frames;
    std::vector<Bytes> messages;if(!unbatchWire(data.bytes,data.length,messages))return NO;
    {std::lock_guard<std::mutex> guard(peerLock);if(!other)return NO;for(const auto &message:messages)if(!other->receive(message.data(),message.size()))return NO;
        Received discard;while(other->pop(discard))peerReceived=discard.data;frames=other->takeWire();}
    for(const auto &frame:batchWire(frames)){NSData *reply=[NSData dataWithBytes:frame.data() length:frame.size()];
        if(self.holdAcks){@synchronized(self){[self.savedReplies addObject:reply];}}
        else [[MDSNearby shared] session:self didReceiveData:reply fromPeer:[MDSNearby shared].partner];}
    return YES;
}
@end
static void injectOther(TestSession *session){std::vector<Bytes> frames;{std::lock_guard<std::mutex> guard(peerLock);frames=other->takeWire();}
    for(const auto &frame:batchWire(frames))[[MDSNearby shared] session:session didReceiveData:[NSData dataWithBytes:frame.data() length:frame.size()] fromPeer:[MDSNearby shared].partner];}
static bool settled(){std::lock_guard<std::mutex> guard(lock);return g.protocol&&g.protocol->settled();}
static bool ended(){std::lock_guard<std::mutex> guard(lock);return g.protocol&&g.protocol->phase()==Phase::Ended;}
static void tests(){@autoreleasepool{
    results=[NSMutableDictionary new];NSString *errorText=nil;
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    try{
        check(@"user nickname wins over generic device model",[boundedPlayerName(@"Kade",@"iPhone") isEqual:@"Kade"]);
        check(@"device name used when nickname absent",[boundedPlayerName(nil,@"My iPhone") isEqual:@"My iPhone"]);
        check(@"Unicode name respects peer byte limit",[boundedPlayerName([@"👾" stringByPaddingToLength:100 withString:@"👾" startingAtIndex:0],nil) lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=63);
        NSData *extras=[NSJSONSerialization dataWithJSONObject:@{@"nickname":@"Player One",@"unrelated":@"synthetic sentinel"} options:0 error:nil];
        check(@"only existing nickname selected from settings extras",[nicknameFromExtras(extras) isEqual:@"Player One"]);
        memset(testBattery,0x51,sizeof(testBattery));memset(testState,0x73,sizeof(testState));
        NSString *path=[[docs URLByAppendingPathComponent:@"synthetic.srm"] path];
        NSData *before=[NSData dataWithBytes:testBattery length:sizeof(testBattery)];[before writeToFile:path atomically:YES];
        static std::string pathStorage;pathStorage=path.UTF8String;testEntry.data=pathStorage.data();testEntry.attr.i=RETRO_MEMORY_SAVE_RAM;testFiles={&testEntry,1,1};
        MDSCore core{memory,memorySize,stateSize,serialize,wirelessIdentity};MDS_gameLoaded("ADAE",5,core);
        retro_netpacket_callback callbacks{};callbacks.start=startCore;callbacks.receive=receiveCore;callbacks.stop=stopCore;MDS_netpacket(&callbacks);
        uint8_t infra[48]{};infra[13]=1;check(@"ordinary WFC infrastructure excluded",!localFrame(infra,sizeof(infra),0));
        check(@"native Nintendo multiplayer is recognized with ToDS flags",localFrame(infra,sizeof(infra),1));
        uint8_t local[48]{};local[16]=3;local[17]=9;local[18]=191;check(@"Nintendo local destination recognized",localFrame(local,sizeof(local),0));
        {std::lock_guard<std::mutex> guard(lock);g.radio=true;g.requested=true;}
        hasPath=false;MDS_afterFrame();check(@"missing frontend save path fails preparation",g.failedPrepare&&!g.prepared);
        check(@"rejected preparation preserves original battery",[[NSData dataWithContentsOfFile:path] isEqual:before]);
        MDS_gameLoaded("ADAE",5,core);hasPath=true;{std::lock_guard<std::mutex> guard(lock);g.radio=true;g.requested=true;}MDS_afterFrame();
        check(@"checkpoint gates link readiness",g.prepared&&[g.savePath isEqual:path]);
        NSArray<NSURL*> *backups=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[docs URLByAppendingPathComponent:@"ManicDSBackups"] includingPropertiesForKeys:nil options:0 error:nil];
        bool checkpoint=false;for(NSURL *folder in backups)if([[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"before.srm"]] isEqual:before]&&[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"before.melonstate"]].length==64)checkpoint=true;
        check(@"verified local checkpoint contains independent battery and state",checkpoint);
        Nonce peerNonce=newNonce();other=std::make_unique<manicds::Protocol>(peerNonce,"CPUE",1);other->radio(true);other->bind(g.nonce,"ADAE",5);
        dispatch_sync(dispatch_get_main_queue(),^{
            MDSNearby *manager=[MDSNearby shared];[manager cleanup];[manager setValue:@(g.epoch) forKey:@"generation"];[manager setValue:@YES forKey:@"prepared"];
            [manager setValue:@{@"code":@"ADAE",@"mac":g.wirelessMAC} forKey:@"meta"];
            NSDictionary *same=@{@"v":WireVersion,@"ready":@"1",@"code":@"CPUE",@"nonce":hexNonce(peerNonce),@"runtime":@"synthetic-B",@"mac":g.wirelessMAC};
            [manager invite:[[MCPeerID alloc]initWithDisplayName:@"Duplicate console"] info:same];
            check(@"duplicate firmware identity allows invitation without mutation",manager.partner!=nil&&[manager valueForKey:@"notice"]==nil&&[g.wirelessMAC isEqual:@"0009bf010203"]);
            [manager resetPendingInvitation];check(@"failed prelink invitation clears pending peer",manager.partner==nil&&![[manager valueForKey:@"inviting"] boolValue]);
        });
        __block TestSession *session;dispatch_sync(dispatch_get_main_queue(),^{
            MDSNearby *manager=[MDSNearby shared];[manager cleanup];[manager setValue:@(g.epoch) forKey:@"generation"];
            MCPeerID *identity=[[MCPeerID alloc]initWithDisplayName:@"Synthetic console A"],*peer=[[MCPeerID alloc]initWithDisplayName:@"Synthetic console B"];
            session=[[TestSession alloc]initWithPeer:identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];session.savedReplies=[NSMutableArray new];session.holdAcks=YES;manager.session=session;manager.partner=peer;
            NSDictionary *info=@{@"code":@"CPUE",@"rev":@"1",@"nonce":hexNonce(peerNonce),@"runtime":@"synthetic-B",@"mac":g.wirelessMAC};[manager setValue:info forKey:@"partnerMeta"];
            injectOther(session);check(@"early reliable Ready retained before connected callback",!g.earlyWire.empty());
            [manager session:session peer:peer didChangeState:MCSessionStateConnected];
        });
        TestSession *pairingSession=session;waitUntil([pairingSession]{@synchronized(pairingSession){return pairingSession.savedReplies.count>0;}});
        check(@"game waits for bilateral Ready acknowledgment",!MDS_beforeFrame()&&starts==0);
        session.holdAcks=NO;@synchronized(session){for(NSData *reply in session.savedReplies)[[MDSNearby shared] session:session didReceiveData:reply fromPeer:[MDSNearby shared].partner];[session.savedReplies removeAllObjects];}
        waitUntil([]{std::lock_guard<std::mutex> guard(lock);return g.protocol&&g.protocol->paired();});
        check(@"core callback starts between frames",MDS_beforeFrame()&&starts==1);
        check(@"linked state restore blocked",!MDS_allowRestore());
        dispatch_semaphore_t burstGate=dispatch_semaphore_create(0);dispatch_queue_t sendQueue=[[MDSNearby shared] valueForKey:@"sendQueue"];
        dispatch_async(sendQueue,^{dispatch_semaphore_wait(burstGate,DISPATCH_TIME_FOREVER);});
        uint8_t packet[14]{};packet[9]=0;packet[10]=42;for(unsigned i=0;i<100;i++)sendPacket(0,packet,sizeof(packet),65535);
        dispatch_semaphore_signal(burstGate);
        waitUntil(settled);check(@"serialized submission and acknowledgments settle burst",settled());
        check(@"native packet burst coalesces transport messages",g.transportMessages<100);
        {std::lock_guard<std::mutex> guard(peerLock);other->send(packet,sizeof(packet));}injectOther(session);
        check(@"network delegate does not invoke emulator receive",received==0);MDS_beforeFrame();check(@"receive invoked only on core thread",received==1&&!wrongThread);
        check(@"paired duplicate identity enables transport-only address mapping",g.addresses.enabled()&&[g.wirelessMAC isEqual:@"0009bf010203"]);
        MAC native{0,9,191,1,2,3};Bytes localPacket(100,0);localPacket[22]=0x80;
        std::copy(native.begin(),native.end(),localPacket.begin()+32);std::copy(native.begin(),native.end(),localPacket.begin()+38);std::copy(native.begin(),native.end(),localPacket.begin()+70);
        sendPacket(0,localPacket.data(),localPacket.size(),65535);waitUntil(settled);
        Bytes outbound;{std::lock_guard<std::mutex> guard(peerLock);outbound=peerReceived;}
        check(@"bridge translates headers while preserving original buffer and game payload",outbound.size()==100&&!std::equal(native.begin(),native.end(),outbound.begin()+32)&&std::equal(localPacket.begin()+44,localPacket.end(),outbound.begin()+44)&&std::equal(native.begin(),native.end(),localPacket.begin()+32));
        FrameAddressMap peerAddresses;peerAddresses.configure(native,native,1-g.protocol->id());Bytes reply=localPacket;peerAddresses.outgoing(reply);std::copy_n(outbound.begin()+32,6,reply.begin()+26);
        {std::lock_guard<std::mutex> guard(peerLock);other->send(reply.data(),reply.size());}injectOther(session);MDS_beforeFrame();
        uint8_t nativeAfter[6]{};wirelessIdentity(nativeAfter);
        check(@"bridge restores local destination without mutating firmware or battery",coreReceived.size()==100&&std::equal(native.begin(),native.end(),coreReceived.begin()+26)&&!std::equal(native.begin(),native.end(),coreReceived.begin()+32)&&std::equal(native.begin(),native.end(),nativeAfter)&&[battery() isEqual:before]);
        LibretroCore *frontend=[LibretroCore new];dispatch_sync(dispatch_get_main_queue(),^{installPauseHooks();});[frontend pause];waitUntil(settled);
        check(@"existing frontend pause chained and peer holds",pauseCalls==1&&!MDS_beforeFrame());
        session.holdAcks=YES;[frontend resume];check(@"release waits for peer acknowledgment",resumeCalls==1&&!MDS_beforeFrame());
        TestSession *activeSession=session;waitUntil([activeSession]{@synchronized(activeSession){return activeSession.savedReplies.count>0;}});session.holdAcks=NO;
        @synchronized(session){for(NSData *reply in session.savedReplies)[[MDSNearby shared] session:session didReceiveData:reply fromPeer:[MDSNearby shared].partner];[session.savedReplies removeAllObjects];}
        waitUntil(settled);check(@"acknowledged resume allows core",MDS_beforeFrame());
        testBattery[0]=0x92;for(unsigned i=0;i<60;i++)MDS_afterFrame();check(@"current synthetic battery atomically persists",[NSData dataWithContentsOfFile:path].length==512&&((const uint8_t*)[NSData dataWithContentsOfFile:path].bytes)[0]==0x92);
        Nonce oldRoomNonce=g.nonce;MDS_signal(2,nullptr);{std::lock_guard<std::mutex> guard(peerLock);other->radio(false);}injectOther(session);waitUntil(settled);
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *manager=[MDSNearby shared];[manager setValue:@(CACurrentMediaTime()-6) forKey:@"parkedAt"];[manager tick:nil];});
        waitUntil([]{std::lock_guard<std::mutex> guard(peerLock);return other&&other->receivedCount()>0;});
        {std::lock_guard<std::mutex> guard(peerLock);other->close();}injectOther(session);waitUntil(ended);MDS_beforeFrame();
        check(@"clean stop flushes save before lifecycle reset",stops==1&&g.finishSaved);
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *manager=[MDSNearby shared];[manager setValue:[NSMutableDictionary dictionaryWithObject:@{@"nonce":hexNonce(peerNonce)} forKey:manager.partner] forKey:@"peers"];[manager tick:nil];});check(@"bounded bilateral room exit clears transport",!g.protocol);
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *manager=[MDSNearby shared];check(@"fresh session discards stale peer nonce while retaining same-runtime consent",[[manager valueForKey:@"peers"] count]==0&&[[manager valueForKey:@"approvedRuntime"] isEqual:@"synthetic-B"]);});
        check(@"exit checkpoint kept original prelink battery",[[NSData dataWithContentsOfURL:[backups.firstObject URLByAppendingPathComponent:@"before.srm"]] isEqual:before]);
        check(@"fresh radio creates new room nonce",g.nonce!=oldRoomNonce);
        MDS_gameUnloading();check(@"game close clears transport and gates",!g.loaded&&!g.prepared&&!g.protocol);
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
