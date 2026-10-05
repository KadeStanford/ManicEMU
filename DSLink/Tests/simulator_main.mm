// Synthetic UIKit/frontend boundary test. No game, firmware or real save input.
#define MDS_RF_TESTING 1
#include "../iOS/Nearby.mm"
#include "../iOS/GeneratedConsole.h"
#include <stdexcept>
#include <thread>
#include <chrono>
#include <functional>
static unsigned pauseCalls=0,resumeCalls=0,starts=0,stops=0,received=0;
static bool wrongThread=false,hasPath=true;
static unsigned nativeDatagrams=0,reliableMessages=0;
static bool wrongDeliveryMode=false;
static unsigned forwardedVideo=0,forwardedAudio=0;
static const void *forwardedVideoData;
static void testVideo(const void *data,unsigned width,unsigned height,size_t pitch){forwardedVideo++;forwardedVideoData=data;wrongDeliveryMode|=width!=10||height!=4||pitch!=20;}
static size_t testAudio(const int16_t *data,size_t frames){forwardedAudio++;wrongDeliveryMode|=!data||frames!=32;return 17;}
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
static bool identityValid=true;
static bool identityMatches(){return identityValid;}
static retro_environment_t engineEnvironment;
static uint8_t mockBootIdentity[6]{};
static void mockSetEnvironment(retro_environment_t value){engineEnvironment=value;}
static bool mockLoad(const retro_game_info *info){
    (void)info;MDSGeneratedConsole request{1,{},{}};
    if(engineEnvironment&&engineEnvironment(0x4d445303,&request))memcpy(mockBootIdentity,request.mac,6);
    else memset(mockBootIdentity,0,6);
    return true;
}
static bool mockIdentity(uint8_t *out){memcpy(out,mockBootIdentity,6);return true;}
static bool mockMatches(){return true;}
static unsigned mockRevision(){return 8;}
static void mockUnload(){}
static bool mockFrontend(unsigned command,void *data){(void)command;(void)data;return false;}
static void *MDS_testEngineSymbol(const char *name){
    if(!strcmp(name,"retro_set_environment"))return reinterpret_cast<void*>(mockSetEnvironment);
    if(!strcmp(name,"retro_load_game"))return reinterpret_cast<void*>(mockLoad);
    if(!strcmp(name,"retro_get_memory_data"))return reinterpret_cast<void*>(memory);
    if(!strcmp(name,"retro_get_memory_size"))return reinterpret_cast<void*>(memorySize);
    if(!strcmp(name,"retro_serialize_size"))return reinterpret_cast<void*>(stateSize);
    if(!strcmp(name,"retro_serialize"))return reinterpret_cast<void*>(serialize);
    if(!strcmp(name,"manic_ds_wireless_identity"))return reinterpret_cast<void*>(mockIdentity);
    if(!strcmp(name,"manic_ds_firmware_identity_matches"))return reinterpret_cast<void*>(mockMatches);
    if(!strcmp(name,"manic_ds_protocol_revision"))return reinterpret_cast<void*>(mockRevision);
    if(!strcmp(name,"retro_unload_game"))return reinterpret_cast<void*>(mockUnload);
    return nullptr;
}
#define MDS_TESTING 1
#include "../iOS/CoreShim.mm"
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
@property unsigned starts,stops;
@end
@implementation TestBrowser
-(void)invitePeer:(MCPeerID*)peer toSession:(MCSession*)session withContext:(NSData*)context timeout:(NSTimeInterval)timeout{(void)peer;(void)session;(void)context;(void)timeout;self.invitations++;}
-(void)startBrowsingForPeers{self.starts++;}
-(void)stopBrowsingForPeers{self.stops++;}
@end
@interface TestAdvertiser:MCNearbyServiceAdvertiser
@property unsigned starts,stops;
@end
@implementation TestAdvertiser
-(void)startAdvertisingPeer{self.starts++;}
-(void)stopAdvertisingPeer{self.stops++;}
@end
@interface TestNearby:MDSNearby
@property unsigned advertised;
@property(strong) NSDictionary *published;
@end
@implementation TestNearby
-(MCNearbyServiceBrowser*)newBrowser{
    return [[TestBrowser alloc]initWithPeer:[self valueForKey:@"identity"] serviceType:Service];
}
-(MCNearbyServiceAdvertiser*)newAdvertiser{
    NSDictionary *meta=[self valueForKey:@"meta"];self.published=meta;self.advertised++;
    return [[TestAdvertiser alloc]initWithPeer:[self valueForKey:@"identity"] discoveryInfo:meta serviceType:Service];
}
@end
@interface TestSession:MCSession
@property(strong) NSArray<MCPeerID*> *mockPeers;
@end
@implementation TestSession
-(NSArray<MCPeerID*>*)connectedPeers{return self.mockPeers?:@[];}
-(BOOL)sendData:(NSData*)data toPeers:(NSArray<MCPeerID*>*)targets withMode:(MCSessionSendDataMode)mode error:(NSError**)error{
    (void)error;if(data.length>=4&&!memcmp(data.bytes,"MDH5",4))return YES;
    const bool radio=data.length>=4&&!memcmp(data.bytes,"MDR1",4);
    wrongDeliveryMode|=radio?(mode!=MCSessionSendDataUnreliable||data.length>1000):(mode!=MCSessionSendDataReliable);
    if(radio)nativeDatagrams++;else reliableMessages++;
    for(MCPeerID *peer in targets){std::vector<Bytes> frames,reply;
        {std::lock_guard<std::mutex> guard(peerLock);auto room=static_cast<Room*>([mockRooms[peer] pointerValue]);if(!room)return NO;
            if(radio){if(!room->receiveRadio(g.nonce,data.bytes,data.length))return NO;}
            else {if(!unbatchWire(data.bytes,data.length,frames))return NO;for(const auto &f:frames)if(!room->receive(g.nonce,f.data(),f.size()))return NO;}
            Received packet;while(room->pop(packet))peerReceived=packet.data;reply=room->takeWire(g.nonce);}
        for(const auto &b:batchWire(reply))[[MDSNearby shared] session:self didReceiveData:[NSData dataWithBytes:b.data() length:b.size()] fromPeer:peer];
    }return YES;
}
@end
static void inject(TestSession *session,unsigned index){std::vector<Bytes> frames,radio;
    {std::lock_guard<std::mutex> guard(peerLock);frames=owned[index]->takeWire(g.nonce);radio=owned[index]->takeRadioWire(g.nonce);}
    for(const auto &b:batchWire(frames))[[MDSNearby shared] session:session didReceiveData:[NSData dataWithBytes:b.data() length:b.size()] fromPeer:peers[index]];
    for(const auto &b:radio)[[MDSNearby shared] session:session didReceiveData:[NSData dataWithBytes:b.data() length:b.size()] fromPeer:peers[index]];
}
static bool settled(){std::lock_guard<std::mutex> guard(lock);return g.room&&g.room->pendingCount()==0;}
static MAC peerMAC(unsigned i){return MAC{0,9,191,1,2,uint8_t(i+4)};}
static NSDictionary *metadata(unsigned i,NSString *runtime){MAC alias=peerMAC(i);NSMutableString *text=[NSMutableString new];for(auto b:alias)[text appendFormat:@"%02x",b];
    return @{@"v":WireVersion,@"ready":@"1",@"local":@"1",@"code":@"CPUE",@"rev":@"1",@"nonce":hexNonce(identities[i]),@"runtime":runtime,@"mac":text,@"alias":text};
}
static void tests(){@autoreleasepool{
    results=[NSMutableDictionary new];NSString *errorText=nil;NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    try{
        // Exercise Network.framework DTLS itself, not a mocked sendData call.
        NSData *policyKey=[NSMutableData dataWithLength:32];nw_parameters_t policy=rfParameters(policyKey);
        check(@"DS RF parameters request responsive data service",policy&&nw_parameters_get_service_class(policy)==nw_service_class_responsive_data);
        std::mutex rfMutex;unsigned rfArrivals=0,rfKernelTimes=0;bool rfWrong=false;
        MDSLocalRF *rfA=nil,*rfB=nil;NSDictionary *setupA=nil,*setupB=nil;
        auto setup=[&](bool side,NSString *nonce,NSDictionary *metadata){
            (void)nonce;std::lock_guard<std::mutex> guard(rfMutex);if(side)setupA=metadata;else setupB=metadata;
        };
        auto rfReceive=[&](NSString *nonce,NSData *data,uint64_t received,uint64_t callback){std::lock_guard<std::mutex> guard(rfMutex);
            rfWrong|=data.length!=73||((const uint8_t*)data.bytes)[72]!=0x51||(![nonce isEqual:@"A"]&&![nonce isEqual:@"B"]);rfArrivals++;
            rfKernelTimes+=received&&callback>=received;
        };
        rfA=[[MDSLocalRF alloc]initWithSetup:^(NSString *nonce,NSDictionary *metadata){setup(true,nonce,metadata);} receive:^(NSString *nonce,NSData *data,uint64_t received,uint64_t callback){rfReceive(nonce,data,received,callback);}];
        rfB=[[MDSLocalRF alloc]initWithSetup:^(NSString *nonce,NSDictionary *metadata){setup(false,nonce,metadata);} receive:^(NSString *nonce,NSData *data,uint64_t received,uint64_t callback){rfReceive(nonce,data,received,callback);}];
        [rfA add:@"B"];[rfB add:@"A"];
        waitUntil([&]{std::lock_guard<std::mutex> guard(rfMutex);return setupA&&setupB;});
        check(@"DTLS peer setup uses independent ephemeral keys",![setupA[@"key"] isEqual:setupB[@"key"]]);
        check(@"DTLS setup refuses public and multicast routes",!rfLocalAddress(@"8.8.8.8",rfInterfaces())&&!rfLocalAddress(@"224.0.0.1",rfInterfaces()));
        [rfA connect:@"B" metadata:setupB];[rfB connect:@"A" metadata:setupA];
        waitUntil([&]{return [[rfA metrics][@"ready_peers"] unsignedIntValue]==1&&[[rfB metrics][@"ready_peers"] unsignedIntValue]==1;});
        uint8_t rfBytes[73]{};memcpy(rfBytes,"MDR1",4);rfBytes[72]=0x51;NSData *rfPacket=[NSData dataWithBytes:rfBytes length:sizeof(rfBytes)];
        check(@"real encrypted UDP bilateral sends admitted",[rfA send:rfPacket peer:@"B"]&&[rfB send:rfPacket peer:@"A"]);
        waitUntil([&]{std::lock_guard<std::mutex> guard(rfMutex);return rfArrivals==2;});
        check(@"real DTLS preserves bilateral datagrams",!rfWrong&&[[rfA metrics][@"received"] unsignedIntValue]==1&&[[rfB metrics][@"received"] unsignedIntValue]==1);
        std::this_thread::sleep_for(std::chrono::milliseconds(9100));
        check(@"established DTLS survives handshake timers",[rfA send:rfPacket peer:@"B"]&&[rfB send:rfPacket peer:@"A"]);
        waitUntil([&]{std::lock_guard<std::mutex> guard(rfMutex);return rfArrivals==4;});
        check(@"real bilateral RF continues beyond handshake deadline",!rfWrong&&[[rfA metrics][@"received"] unsignedIntValue]==2&&[[rfB metrics][@"received"] unsignedIntValue]==2);
        {std::lock_guard<std::mutex> guard(rfMutex);check(@"DTLS IP receive clocks precede actual callback clocks",rfKernelTimes==4);}
        waitUntil([&]{return [[rfA metrics][@"send_completion_samples"] unsignedIntValue]==2&&[[rfB metrics][@"send_completion_samples"] unsignedIntValue]==2;});
        bool timingBounded=true;
        for(MDSLocalRF *endpoint in @[rfA,rfB]){NSDictionary *metrics=[endpoint metrics];
            uint64_t receiveBins=0,sendBins=0;for(NSNumber *n in metrics[@"ip_to_callback_bins"])receiveBins+=n.unsignedLongLongValue;
            for(NSNumber *n in metrics[@"send_completion_bins"])sendBins+=n.unsignedLongLongValue;
            timingBounded&=[metrics[@"timing_clock"] isEqual:@"CLOCK_MONOTONIC_RAW"]&&[metrics[@"ip_to_callback_bins"] count]==8&&
                [metrics[@"send_completion_bins"] count]==8&&receiveBins==2&&sendBins==2&&
                [metrics[@"kernel_receive_missing"] unsignedIntValue]==0&&[metrics[@"kernel_receive_invalid"] unsignedIntValue]==0&&
                [metrics[@"pending_max"] unsignedIntValue]<=32;
        }
        check(@"actual RF timing counters and histograms account for datagrams",timingBounded);
        check(@"unknown direct RF peer falls back",![rfA send:rfPacket peer:@"C"]);
        [rfA remove:@"B"];[rfB remove:@"A"];
        check(@"direct RF removal prevents old-session sends",![rfA send:rfPacket peer:@"B"]&&![rfB send:rfPacket peer:@"A"]);
        [rfA stop];[rfB stop];
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
        MDSCore core{memory,memorySize,stateSize,serialize,wirelessIdentity,identityMatches,identityMatches,nullptr};MDS_gameLoaded("ADAE",5,core);retro_netpacket_callback callbacks{};callbacks.start=startCore;callbacks.receive=receiveCore;callbacks.stop=stopCore;MDS_netpacket(&callbacks);
        uint8_t infra[48]{};infra[13]=1;check(@"WFC excluded",!localFrame(infra,sizeof(infra),0));
        uint8_t local[48]{};local[16]=3;local[17]=9;local[18]=191;check(@"Nintendo local radio recognized",localFrame(local,sizeof(local),0));
        {std::lock_guard<std::mutex> guard(lock);g.radio=true;g.requested=true;}hasPath=false;MDS_afterFrame();check(@"save path verification blocks preparation",g.failedPrepare&&!g.prepared);check(@"failed preparation leaves battery intact",[[NSData dataWithContentsOfFile:path] isEqual:before]);
        MDS_gameLoaded("ADAE",5,core);hasPath=true;{std::lock_guard<std::mutex> guard(lock);g.radio=true;g.intent=true;g.requested=true;}MDS_afterFrame();check(@"independent save checkpoint prepared",g.prepared&&[g.savePath isEqual:path]);
        MAC native{0,9,191,1,2,3};for(unsigned i=0;i<3;i++){Nonce n{};n[0]=uint8_t(i+10);n[15]=uint8_t(i+20);identities.push_back(n);owned.push_back(std::make_unique<Room>(n,"CPUE",1,peerMAC(i)));owned.back()->radio(true);check(@"independent peer accepts local room",owned.back()->add(g.nonce,"ADAE",5,native));}
        __block TestNearby *discovery;__block TestBrowser *pendingBrowser;__block MCPeerID *earlyPeer;
        dispatch_sync(dispatch_get_main_queue(),^{
            discovery=[TestNearby new];[discovery radio:YES generation:g.epoch];
            check(@"preparing console never publishes unready Bonjour metadata",discovery.advertised==0&&[discovery valueForKey:@"browser"]==nil);
            [discovery setValue:@"A" forKey:@"runtime"];
            pendingBrowser=[[TestBrowser alloc]initWithPeer:[discovery valueForKey:@"identity"] serviceType:Service];
            [discovery setValue:pendingBrowser forKey:@"browser"];
            earlyPeer=[[MCPeerID alloc]initWithDisplayName:@"Already ready player"];
            NSDictionary *info=metadata(0,@"B");
            check(@"ready candidate accepted while local MAC is not prepared",[discovery candidate:info]&&![discovery valid:info]);
            [discovery browser:pendingBrowser foundPeer:earlyPeer withDiscoveryInfo:info];
        });
        dispatch_sync(dispatch_get_main_queue(),^{
            check(@"early ready discovery retained until local preparation",[[discovery valueForKey:@"peers"] count]==1&&pendingBrowser.invitations==0);
            [discovery prepared:g.epoch];
            check(@"prepared discovery starts immediately without rediscovery",pendingBrowser.starts==1&&pendingBrowser.invitations==1);
            check(@"first advertisement already contains native ready identity",discovery.advertised==1&&[discovery.published[@"ready"] isEqual:@"1"]&&[discovery.published[@"local"] isEqual:@"1"]&&[discovery.published[@"mac"] isEqual:@"0009bf010203"]);
            [discovery connectReadyPeers];check(@"simultaneous discovery keeps one invitation attempt",pendingBrowser.invitations==1);
            [discovery radio:NO generation:g.epoch];
            unsigned advertisements=discovery.advertised;{std::lock_guard<std::mutex> guard(lock);g.radio=false;}
            [discovery prepared:g.epoch];
            check(@"late preparation after native exit cannot restart discovery",discovery.advertised==advertisements&&pendingBrowser.starts==1);
            {std::lock_guard<std::mutex> guard(lock);g.radio=true;}
            [discovery radio:YES generation:g.epoch];
            check(@"ready native reentry restarts discovery with same identity",pendingBrowser.starts==2&&[discovery.published[@"mac"] isEqual:@"0009bf010203"]);
            [discovery cleanup];discovery=nil;
        });
        __block TestSession *session;__block TestBrowser *browser;__block MCNearbyServiceAdvertiser *advertiser;
        dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *m=[MDSNearby shared];[m cleanup];[m setValue:@(g.epoch) forKey:@"generation"];[m setValue:@YES forKey:@"prepared"];[m setValue:@"A" forKey:@"runtime"];
            MCPeerID *identity=[[MCPeerID alloc]initWithDisplayName:@"Kade"];session=[[TestSession alloc]initWithPeer:identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];m.session=session;
            browser=[[TestBrowser alloc]initWithPeer:identity serviceType:Service];advertiser=[[MCNearbyServiceAdvertiser alloc]initWithPeer:identity discoveryInfo:nil serviceType:Service];[m setValue:browser forKey:@"browser"];[m setValue:advertiser forKey:@"advertiser"];
            [m setValue:@{@"code":@"ADAE",@"mac":@"0009bf010203"} forKey:@"meta"];[m setValue:[NSMutableDictionary new] forKey:@"peers"];[m setValue:[NSMutableDictionary new] forKey:@"attempts"];[m setValue:[NSMutableDictionary new] forKey:@"retryAt"];
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
        for(unsigned i=0;i<100;i++)sendPacket(0,packet,sizeof(packet),65535);
        waitUntil([]{std::lock_guard<std::mutex> guard(lock);return !g.sendScheduled;});waitUntil(settled);
        check(@"native shared burst uses datagrams without RF ACKs",g.room->pendingCount()==0&&nativeDatagrams==200&&!wrongDeliveryMode&&g.room->radioSentCount()==200);
        unsigned controls=reliableMessages;sendPacket(RETRO_NETPACKET_RELIABLE,packet,sizeof(packet),g.room->slot(identities[0]));waitUntil(settled);
        check(@"explicit reliable request preserves reliable delivery",reliableMessages>controls&&!wrongDeliveryMode);
        {std::lock_guard<std::mutex> guard(peerLock);owned[0]->sendRadio(packet,sizeof(packet));}inject(session,0);check(@"SDK delegate never invokes core receive",received==0);MDS_beforeFrame();check(@"native receive stays on core thread",received==1&&!wrongThread);
        uint16_t oldSlot=g.room->slot(identities[0]);dispatch_sync(dispatch_get_main_queue(),^{MDSNearby *m=[MDSNearby shared];session.mockPeers=@[peers[0],peers[1],peers[2]];NSMutableDictionary *known=[m valueForKey:@"peers"];known[peers[2]]=metadata(2,@"D");[m session:session peer:peers[2] didChangeState:MCSessionStateConnected];});
        waitUntil([]{std::lock_guard<std::mutex> guard(lock);return g.room->size()==3&&g.room->pendingCount()==0;});check(@"third arrival preserves established routing",g.room->slot(identities[0])==oldSlot&&starts==1);
        dispatch_sync(dispatch_get_main_queue(),^{[[MDSNearby shared] remove:peers[1]];session.mockPeers=@[peers[0],peers[2]];});check(@"one departed peer leaves other consoles active",g.room->size()==2&&g.room->active()&&MDS_beforeFrame()&&starts==1);
        LibretroCore *front=[LibretroCore new];dispatch_sync(dispatch_get_main_queue(),^{installPauseHooks();});[front pause];check(@"local frontend pause chained",pauseCalls==1&&!MDS_beforeFrame());[front resume];waitUntil(settled);check(@"local resume has no chooser",resumeCalls==1&&MDS_beforeFrame());
        testBattery[0]=0x92;for(unsigned i=0;i<60;i++)MDS_afterFrame();check(@"current battery persists independently",((const uint8_t*)[NSData dataWithContentsOfFile:path].bytes)[0]==0x92);
        MDS_signal(2,nullptr);MDS_beforeFrame();check(@"normal native radio shutdown stops core",stops==1&&!g.started);check(@"room exit retains current save",((const uint8_t*)[NSData dataWithContentsOfFile:path].bytes)[0]==0x92);
        MDS_signal(1,nullptr);MDS_beforeFrame();check(@"native reentry starts existing room without pairing dialog",starts==2&&g.started);
        uint8_t original[6]{};wirelessIdentity(original);check(@"firmware identity untouched",std::equal(native.begin(),native.end(),original));
        MDS_gameUnloading();check(@"game unload clears all room state",!g.room&&!g.loaded&&!g.prepared);check(@"native callbacks stay on emulator thread",!wrongThread);
        identityValid=false;MDS_gameLoaded("IPKE",0,core);
        {std::lock_guard<std::mutex> guard(lock);g.radio=g.requested=true;}
        MDS_afterFrame();check(@"legacy Gen4 state identity mismatch prevents nearby without discarding game",g.failedPrepare&&!g.prepared&&MDS_beforeFrame());
        MDS_afterFrame();check(@"legacy mismatch stays bounded across repeated frames",g.failedPrepare&&!g.preparing);identityValid=true;MDS_gameUnloading();
        retro_set_environment(mockFrontend);
        for(const char *code:{"ADAE","APAE","CPUE","IPKE","IPGE","IRBO","IRAO","IREO","IRDO"}){
            uint8_t header[32]{};memcpy(header+12,code,4);retro_game_info info{};info.data=header;info.size=sizeof(header);
            check([NSString stringWithFormat:@"iOS shim identity before engine load %.4s",code],retro_load_game(&info)&&requests()==1&&localMatches());
            if(!memcmp(code,"IRBO",4)){
                Event e{20,0,nullptr};engineEnvironment(0x4d445301,&e);
                uint32_t wait[2]{1000,0};engineEnvironment(0x4d445302,wait);
                e.number=4;engineEnvironment(0x4d445301,&e);
                check(@"host receive diagnostics separate waits and timeouts",g.receive.scope==1&&g.receive.hostCalls==1&&g.receive.hostWaits==1&&g.receive.hostTimeouts==1&&g.receive.hostWaitMilliseconds>0);
                e.number=22;engineEnvironment(0x4d445301,&e);e.number=21;engineEnvironment(0x4d445301,&e);
                check(@"host receive scope ends after no native bytes",g.receive.scope==0&&g.receive.hostEmpty==1);
                e.number=30;engineEnvironment(0x4d445301,&e);engineEnvironment(0x4d445302,wait);
                e.number=4;engineEnvironment(0x4d445301,&e);
                check(@"reply waits and timeouts remain independent",g.receive.scope==2&&g.receive.replyCalls==1&&g.receive.replyWaits==1&&g.receive.replyTimeouts==1&&g.receive.hostWaits==1&&g.receive.replyWaitMilliseconds>0);
                for(unsigned i=40;i<=46;i++){e.number=i;engineEnvironment(0x4d445301,&e);}
                check(@"numeric reply outcomes count without packet input",std::all_of(std::begin(g.receive.replyResults),std::end(g.receive.replyResults),[](uint64_t value){return value==1;}));
                e.number=32;engineEnvironment(0x4d445301,&e);e.number=33;engineEnvironment(0x4d445301,&e);e.number=31;engineEnvironment(0x4d445301,&e);
                check(@"batch completion and timeout scopes close",g.receive.scope==0&&g.receive.replyComplete==1&&g.receive.replyIncomplete==1);
                e.number=40;e.packet=header;engineEnvironment(0x4d445301,&e);e.packet=nullptr;e.reserved=1;engineEnvironment(0x4d445301,&e);
                check(@"diagnostic events reject packet pointers and reserved fields",g.receive.replyResults[0]==1);
                uint8_t synthetic[40];memset(synthetic,0x61,sizeof(synthetic));NativeDiagnostic trace;
                trace.event=2;trace.length=sizeof(synthetic);trace.payload=synthetic;trace.sourceAid=2;trace.aid=2;trace.timestamp=1000;
                check(@"native trace callback copies payload immediately",engineEnvironment(DiagnosticEnvironment,&trace)&&g.traces->size()==1);
                synthetic[0]=0x72;check(@"capture owns bytes after source changes",g.traces->at(0).payload[0]==0x61&&g.traces->at(0).native.payload==nullptr);
                trace.length=2049;trace.payload=reinterpret_cast<const void*>(uintptr_t(1));
                check(@"trace rejects excessive length before reading pointer",!engineEnvironment(DiagnosticEnvironment,&trace)&&g.traces->size()==1);
                trace.length=0;trace.payload=nullptr;trace.event=5;trace.reason=33;trace.aidmask=4;
                waitUntil([]{return diagnosticJobs.load()==0;});engineEnvironment(DiagnosticEnvironment,&trace);MDS_afterFrame(60);
                waitUntil([]{return diagnosticJobs.load()==0;});
                NSURL *capture=[docs URLByAppendingPathComponent:@"ManicDSDiagnostics/current.json"];
                NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:capture] options:0 error:nil];
                check(@"private diagnostic snapshot writes bounded versioned trace",[record[@"format"] unsignedIntValue]==6&&[record[@"candidate"] isEqual:@"DS-v0.10-R3"]&&[record[@"trace"] count]==2);
                NSString *pinned=[NSString stringWithFormat:@"ManicDSDiagnostics/capture-%02u-incomplete.json",g.diagnosticSession];
                check(@"incomplete exchange remains pinned after room recovery",[NSData dataWithContentsOfURL:[docs URLByAppendingPathComponent:pinned]]!=nil&&g.lastIncomplete->size()==2);
                check(@"slow frame snapshot and recorder cost recorded",g.lastSlow->size()==2&&g.frameOver50==1&&g.writerFailures==0);
                MDS_coreOption("melonds_jit_enable","enabled");MDS_coreOption("private_rom_path","not-recorded");
                check(@"diagnostics record selected runtime options only",[g.options[@"melonds_jit_enable"] isEqual:@"enabled"]&&g.options[@"private_rom_path"]==nil);
                retro_set_video_refresh(testVideo);videoBridge(synthetic,10,4,20);int16_t samples[64]{};
                retro_set_audio_sample_batch(testAudio);size_t consumed=audioBatchBridge(samples,32);
                check(@"AV diagnostics forward original frame pointer and audio return",forwardedVideo==1&&forwardedVideoData==synthetic&&forwardedAudio==1&&consumed==17&&!wrongDeliveryMode);
                check(@"AV stutter diagnostics retain truthful counters",g.videoCallbacks==1&&g.videoWidth==10&&g.videoHeight==4&&g.audioFrames==32&&g.audioConsumed==17);
                retro_set_video_refresh(nullptr);retro_set_audio_sample_batch(nullptr);
            }
            retro_unload_game();
        }
        uint8_t header[32]{};memcpy(header+12,"IPGE",4);
        NSString *headerPath=[[docs URLByAppendingPathComponent:@"synthetic-header.nds"] path];
        [[NSData dataWithBytes:header length:sizeof(header)] writeToFile:headerPath atomically:YES];
        retro_game_info pathInfo{};pathInfo.path=headerPath.fileSystemRepresentation;
        check(@"iOS shim path loading also installs native identity before load",retro_load_game(&pathInfo)&&requests()==1&&localMatches());
        check(@"fresh game load clears scoped diagnostics",g.receive.scope==0&&g.receive.hostCalls==0&&g.receive.replyCalls==0&&g.receive.replyResults[0]==0);retro_unload_game();
        memcpy(header+12,"TEST",4);retro_game_info other{};other.data=header;other.size=sizeof(header);
        check(@"iOS shim leaves unrecognized games on original identity path",retro_load_game(&other)&&requests()==0&&!g.loaded);retro_unload_game();
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
