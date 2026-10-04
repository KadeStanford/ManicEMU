// SPDX-License-Identifier: AGPL-3.0-or-later
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <cstring>
#include <dlfcn.h>
#include <atomic>
#include <memory>
#include <mutex>
#include "Bridge.h"
#include "Protocol.hpp"
#include "../../TradeLink/iOS/FrontendSave.h"
using namespace manicds;
static NSString *const Service=@"manic-ds";
static NSString *const WireVersion=@"ds131-mds1";
static std::mutex lock;
static struct {
    std::unique_ptr<manicds::Protocol> protocol;
    MDSCore core{};
    retro_netpacket_callback net{};
    char code[4]{};
    uint8_t revision=0;
    bool loaded=false,radio=false,intent=false,requested=false,prepared=false,preparing=false;
    bool failedPrepare=false,started=false,held=false,warned=false,finishSaved=false;
    uint64_t epoch=0,frames=0;
    Nonce nonce{};
    NSData *lastBattery=nil;
    NSString *savePath=nil;
} g;
static std::atomic<uint64_t> epoch{0};
static void (*originalPause)(id,SEL),(*originalResume)(id,SEL);
static NSString *hexNonce(Nonce value){NSMutableString *s=[NSMutableString new];for(auto b:value)[s appendFormat:@"%02x",b];return s;}
static bool readNonce(NSString *s,Nonce &n){
    if(![s isKindOfClass:NSString.class]||s.length!=32)return false;
    const char *p=s.UTF8String;static const char digits[]="0123456789abcdef";
    for(unsigned i=0;i<16;i++){char a=p[2*i],b=p[2*i+1];const char *x=strchr(digits,a),*y=strchr(digits,b);if(!x||!y||!a||!b)return false;n[i]=uint8_t((x-digits)*16+(y-digits));}return true;
}
static Nonce newNonce(){Nonce n;[NSUUID.UUID getUUIDBytes:n.data()];return n;}
static UIViewController *presenter(){
    UIViewController *v=nil;
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])
        for(UIWindow *w in ((UIWindowScene*)s).windows)if(w.isKeyWindow)v=w.rootViewController;
    while(v.presentedViewController)v=v.presentedViewController;return v;
}
static NSString *titleName(NSString *code){
    NSArray *titles=@[@"Diamond",@"Pearl",@"Platinum",@"HeartGold",@"SoulSilver",@"Black",@"White",@"Black 2",@"White 2"];
    NSData *b=[code dataUsingEncoding:NSASCIIStringEncoding];int index=b.length==4?title((const char*)b.bytes):0;
    return index?titles[NSUInteger(index-1)]:@"DS game";
}
@interface MDSNearby:NSObject<MCSessionDelegate,MCNearbyServiceAdvertiserDelegate,MCNearbyServiceBrowserDelegate>
@property(atomic,strong) MCSession *session;
@property(atomic,strong) MCPeerID *partner;
+(instancetype)shared;
-(void)radio:(BOOL)on generation:(uint64_t)generation;
-(void)prepared:(uint64_t)generation;
-(void)drain;
-(void)drainWithRetransmit:(BOOL)repeat;
-(void)cleanup;
-(void)warning:(NSString*)message generation:(uint64_t)generation;
@end
static void frontendHold(bool on){
    {std::lock_guard<std::mutex> guard(lock);if(g.protocol)g.protocol->hold(on);}
    [[MDSNearby shared] drain];
}
static void pauseBridge(id bridge,SEL selector){frontendHold(true);originalPause(bridge,selector);}
static void resumeBridge(id bridge,SEL selector){frontendHold(false);originalResume(bridge,selector);}
static void installPauseHooks(){
    static dispatch_once_t once;dispatch_once(&once,^{
        Class cls=NSClassFromString(@"LibretroCore");Method pause=cls?class_getInstanceMethod(cls,NSSelectorFromString(@"pause")):nullptr;
        Method resume=cls?class_getInstanceMethod(cls,NSSelectorFromString(@"resume")):nullptr;
        if(pause&&resume&&method_getNumberOfArguments(pause)==2&&method_getNumberOfArguments(resume)==2){
            originalPause=reinterpret_cast<void(*)(id,SEL)>(method_getImplementation(pause));originalResume=reinterpret_cast<void(*)(id,SEL)>(method_getImplementation(resume));
            method_setImplementation(pause,reinterpret_cast<IMP>(pauseBridge));method_setImplementation(resume,reinterpret_cast<IMP>(resumeBridge));
        }
    });
}
static void warning(NSString *text,uint64_t generation){dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] warning:text generation:generation];});}
static NSString *activePath(){
    auto files=reinterpret_cast<MTSaveList*(*)()>(dlsym(RTLD_DEFAULT,"savefile_ptr_get"));auto list=files?files():nullptr;NSString *path=nil;
    if(!list||!list->elems||list->size>16||list->size>list->cap)return nil;
    for(size_t i=0;i<list->size;i++)if(list->elems[i].attr.i==RETRO_MEMORY_SAVE_RAM&&list->elems[i].data){
        if(path)return nil;path=[NSString stringWithUTF8String:list->elems[i].data];
    }
    return path.isAbsolutePath&&[path.pathExtension.lowercaseString isEqual:@"srm"]?path:nil;
}
static NSData *battery(){
    if(!g.core.memory||!g.core.memorySize)return nil;
    size_t size=g.core.memorySize(RETRO_MEMORY_SAVE_RAM);void *data=g.core.memory(RETRO_MEMORY_SAVE_RAM);
    return data&&size&&size<=8*1024*1024?[NSData dataWithBytes:data length:size]:nil;
}
static bool persist(bool backup){
    // Core thread only. No network packet or other player's save reaches disk.
    NSData *data=battery();NSString *path=activePath();
    if(!data||!path||![path isEqual:g.savePath])return false;
    if([data isEqual:g.lastBattery]&&!backup)return true;
    NSError *error=nil;
    if(backup){
        NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[[docs URLByAppendingPathComponent:@"ManicDSBackups" isDirectory:YES] URLByAppendingPathComponent:[@"completed-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        if(![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]||![data writeToURL:[dir URLByAppendingPathComponent:@"current.srm"] options:NSDataWritingAtomic error:&error])return false;
    }
    if(![data writeToFile:path options:NSDataWritingAtomic error:&error]||![[NSData dataWithContentsOfFile:path] isEqual:data])return false;
    g.lastBattery=data;return true;
}
static void prepare(){
    uint64_t generation;
    {std::lock_guard<std::mutex> guard(lock);if(!g.requested||g.preparing||g.prepared||g.failedPrepare||!g.loaded||!g.radio)return;g.preparing=true;generation=g.epoch;}
    // Original serialization functions execute here, between original frames.
    NSData *data=battery();NSString *path=activePath();size_t size=g.core.stateSize?g.core.stateSize():0;
    NSMutableData *state=size&&size<=128*1024*1024?[NSMutableData dataWithLength:size]:nil;
    bool ok=data&&path&&state&&g.core.serialize&&g.core.serialize(state.mutableBytes,size);
    if(ok){
        NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[[docs URLByAppendingPathComponent:@"ManicDSBackups" isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];NSError *error=nil;
        ok=[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]&&
           [data writeToURL:[dir URLByAppendingPathComponent:@"before.srm"] options:NSDataWritingAtomic error:&error]&&
           [state writeToURL:[dir URLByAppendingPathComponent:@"before.melonstate"] options:NSDataWritingAtomic error:&error];
    }
    {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;g.preparing=false;g.prepared=ok;g.failedPrepare=!ok;if(ok){g.savePath=path;g.lastBattery=data;}}
    if(ok)dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] prepared:generation];});
    else warning(@"Nearby play stopped because the current save path or automatic checkpoint could not be verified. Keep your current game open and save normally.",generation);
}
static void sendPacket(int flags,const void *data,size_t size,uint16_t target){
    (void)flags;if(!size)return; // A flush hint has no game payload.
    {std::lock_guard<std::mutex> guard(lock);if(g.protocol)g.protocol->send(data,size,target);}
    [[MDSNearby shared] drain];
}
static void pollPackets(){
    // Called synchronously by the real core's 25ms receive loop. Network
    // delegates enqueue only; all melonDS receive callbacks run on this thread.
    for(size_t i=0;i<MaxQueue;i++){
        Received p;retro_netpacket_receive_t receive=nullptr;
        {std::lock_guard<std::mutex> guard(lock);if(!g.started||!g.protocol||!g.protocol->pop(p))break;receive=g.net.receive;}
        if(receive)receive(p.data.data(),p.data.size(),p.source);
    }
}
void MDS_netpacket(const retro_netpacket_callback *cb){if(cb){std::lock_guard<std::mutex> guard(lock);g.net=*cb;}}
void MDS_gameLoaded(const char code[4],uint8_t revision,MDSCore core){
    MDS_gameUnloading();
    {std::lock_guard<std::mutex> guard(lock);g.core=core;std::memcpy(g.code,code,4);g.revision=revision;g.loaded=title(code)!=0;g.epoch=++epoch;g.nonce=newNonce();g.frames=0;}
    dispatch_async(dispatch_get_main_queue(),^{installPauseHooks();});
}
void MDS_signal(unsigned event,const void *packet){
    uint64_t generation;bool on=false,changed=false;
    {std::lock_guard<std::mutex> guard(lock);if(!g.loaded)return;generation=g.epoch;
        if(event==1||event==2){on=event==1;changed=g.radio!=on;g.radio=on;if(g.protocol)g.protocol->radio(on);}
        if(event==3&&packet){
            // Exact 1.3.1 Packet ABI verified from the bundled ARM64 engine:
            // timestamp@0, aid@8, enum@12, vector begin@16/end@24/capacity@32.
            uint32_t type;const uint8_t *begin,*end;std::memcpy(&type,static_cast<const uint8_t*>(packet)+12,4);
            std::memcpy(&begin,static_cast<const uint8_t*>(packet)+16,8);std::memcpy(&end,static_cast<const uint8_t*>(packet)+24,8);
            uintptr_t a=reinterpret_cast<uintptr_t>(begin),b=reinterpret_cast<uintptr_t>(end);
            unsigned wireType=type==0?1:type==1?2:0;
            if(type<=2&&begin&&b>=a&&b-a<=2048&&localFrame(begin,b-a,wireType)){g.intent=true;g.requested=true;}
        }
    }
    if(changed)dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] radio:on generation:generation];});
    [[MDSNearby shared] drain];
}
bool MDS_beforeFrame(){
    bool start=false,stop=false,finish=false,allow=true;retro_netpacket_callback cb;uint16_t id=0;uint64_t generation;
    {std::lock_guard<std::mutex> guard(lock);cb=g.net;generation=g.epoch;
        if(g.protocol){auto phase=g.protocol->phase();start=g.protocol->paired()&&!g.started&&phase!=Phase::Interrupted;stop=g.started&&(phase==Phase::Ended||phase==Phase::Failed||phase==Phase::Interrupted);finish=phase==Phase::Ended&&!g.finishSaved;id=g.protocol->id();allow=!g.protocol->paused()||phase==Phase::Interrupted||phase==Phase::Failed;}
        if(start)g.started=true;
    }
    if(stop&&cb.stop)cb.stop();
    if(stop){std::lock_guard<std::mutex> guard(lock);g.started=false;}
    if(start&&cb.start)cb.start(id,sendPacket,pollPackets);
    if(finish){bool saved=persist(true);{std::lock_guard<std::mutex> guard(lock);if(generation==g.epoch)g.finishSaved=true;}
        if(!saved)warning(@"The current DS battery save could not be verified at room exit. Keep the game open and save normally; your pre-link checkpoint was retained.",generation);}
    pollPackets();[[MDSNearby shared] drain];return allow;
}
void MDS_afterFrame(){
    prepare();bool save=false;uint64_t generation;
    {std::lock_guard<std::mutex> guard(lock);generation=g.epoch;save=g.prepared&&g.protocol&&((++g.frames%60)==0);}
    if(save&&!persist(false))warning(@"The current DS battery save could not be written and verified. Keep the game open and save normally; the pre-link checkpoint remains untouched.",generation);
}
bool MDS_allowRestore(){std::lock_guard<std::mutex> guard(lock);return !g.protocol||g.protocol->phase()==Phase::Ended;}
void MDS_gameUnloading(){
    bool flush=false;retro_netpacket_callback cb;
    {std::lock_guard<std::mutex> guard(lock);flush=g.loaded&&g.prepared;cb=g.net;}
    if(flush&&!persist(true))warning(@"The current DS battery save was not verified at game close. Your pre-link backup was retained.",epoch.load());
    if(g.started&&cb.stop)cb.stop();
    {std::lock_guard<std::mutex> guard(lock);g.protocol.reset();g.loaded=g.radio=g.intent=g.requested=g.prepared=g.preparing=g.failedPrepare=g.started=g.held=false;g.warned=false;g.lastBattery=nil;g.savePath=nil;g.epoch=++epoch;}
    uint64_t generation=epoch.load();dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] cleanup];});
}
@implementation MDSNearby {
    MCNearbyServiceAdvertiser *_advertiser;MCNearbyServiceBrowser *_browser;MCPeerID *_identity;
    NSMutableDictionary<MCPeerID*,NSDictionary*> *_peers;
    NSDictionary *_meta,*_partnerMeta;NSString *_runtime,*_approvedRuntime;MCPeerID *_approvedPeer;
    UIAlertController *_dialog,*_notice;NSTimer *_timer;uint64_t _generation;
    BOOL _inviting,_prepared;CFTimeInterval _parkedAt,_offAt,_lastResend;
    dispatch_queue_t _sendQueue;
}
+(instancetype)shared{static MDSNearby *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
-(instancetype)init{if((self=[super init])){_sendQueue=dispatch_queue_create("org.manicemu.ds.packets",DISPATCH_QUEUE_SERIAL);[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];}return self;}
-(BOOL)valid:(NSDictionary*)info{
    Nonce parsed;
    if(![info isKindOfClass:NSDictionary.class]||![info[@"v"] isEqual:WireVersion]||![info[@"ready"] isEqual:@"1"]||!readNonce(info[@"nonce"],parsed)||![info[@"code"] isKindOfClass:NSString.class]||![info[@"runtime"] isKindOfClass:NSString.class])return NO;
    NSData *a=[_meta[@"code"] dataUsingEncoding:NSASCIIStringEncoding],*b=[info[@"code"] dataUsingEncoding:NSASCIIStringEncoding];
    return a.length==4&&b.length==4&&compatible((const char*)a.bytes,(const char*)b.bytes)&&![info[@"runtime"] isEqual:_runtime];
}
-(void)advertise{
    [_advertiser stopAdvertisingPeer];
    if(!_identity||!_meta)return;
    _advertiser=[[MCNearbyServiceAdvertiser alloc]initWithPeer:_identity discoveryInfo:_meta serviceType:Service];_advertiser.delegate=self;[_advertiser startAdvertisingPeer];
}
-(void)radio:(BOOL)on generation:(uint64_t)generation{
    if(!on){if(!self.partner){[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];[self dismiss];}return;}
    if(generation!=_generation){[self cleanup];_generation=generation;_runtime=NSUUID.UUID.UUIDString;_identity=[[MCPeerID alloc]initWithDisplayName:[NSString stringWithFormat:@"%@ · DS",UIDevice.currentDevice.model]];_peers=[NSMutableDictionary new];}
    if(!_meta){char code[4];uint8_t rev;Nonce n;{std::lock_guard<std::mutex> guard(lock);std::memcpy(code,g.code,4);rev=g.revision;n=g.nonce;}
        _meta=@{@"v":WireVersion,@"code":[[NSString alloc]initWithBytes:code length:4 encoding:NSASCIIStringEncoding],@"rev":[NSString stringWithFormat:@"%u",rev],@"nonce":hexNonce(n),@"runtime":_runtime,@"ready":@"0",@"local":@"0"};}
    if(!_timer){_timer=[NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];}
    if(!self.session){self.session=[[MCSession alloc]initWithPeer:_identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];self.session.delegate=self;}
    if(!_browser){_browser=[[MCNearbyServiceBrowser alloc]initWithPeer:_identity serviceType:Service];_browser.delegate=self;}
    [_browser startBrowsingForPeers];[self advertise];
}
-(void)prepared:(uint64_t)generation{
    if(generation!=_generation)return;_prepared=YES;NSMutableDictionary *m=[_meta mutableCopy];m[@"ready"]=@"1";
    {std::lock_guard<std::mutex> guard(lock);m[@"local"]=g.intent?@"1":@"0";}_meta=m;[self advertise];
    NSDictionary *approved=_approvedPeer?_peers[_approvedPeer]:nil;
    if(approved&&[approved[@"runtime"] isEqual:_approvedRuntime])[self invite:_approvedPeer info:approved];else [self finder];
}
-(void)dismiss{if(_dialog.presentingViewController)[_dialog dismissViewControllerAnimated:NO completion:nil];_dialog=nil;}
-(void)finder{
    if(!_prepared||self.partner||_inviting)return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby players" message:@"Both games must use their local wireless room. Each player keeps their own game and save." preferredStyle:UIAlertControllerStyleAlert];
    uint64_t generation=_generation;
    for(MCPeerID *peer in _peers){NSDictionary *info=_peers[peer];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ · %@",peer.displayName,titleName(info[@"code"])] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(generation!=epoch.load())return;[self invite:peer info:info];}]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Keep waiting" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){self->_dialog=nil;}]];
    [self dismiss];_dialog=a;[presenter() presentViewController:a animated:YES completion:nil];
}
-(void)invite:(MCPeerID*)peer info:(NSDictionary*)info{
    if(!_prepared||![self valid:info])return;_inviting=YES;self.partner=peer;_partnerMeta=info;
    NSData *context=[NSJSONSerialization dataWithJSONObject:_meta options:0 error:nil];[_browser invitePeer:peer toSession:self.session withContext:context timeout:20];
}
-(void)drain{
    [self drainWithRetransmit:NO];
}
-(void)drainWithRetransmit:(BOOL)repeat{
    MCSession *session=self.session;MCPeerID *peer=self.partner;if(!session||!peer)return;
    uint64_t generation=epoch.load();
    dispatch_async(_sendQueue,^{
        if(generation!=epoch.load()||session!=self.session)return;
        std::vector<Bytes> frames;
        // Both dequeue and submission run on this one queue. Core, delegate and
        // timer callers cannot submit a later sequence ahead of an earlier one.
        {std::lock_guard<std::mutex> guard(lock);if(!g.protocol||generation!=g.epoch)return;
            frames=g.protocol->takeWire();if(repeat){auto retries=g.protocol->retransmit();frames.insert(frames.end(),retries.begin(),retries.end());}}
        for(const auto &frame:frames){NSData *data=[NSData dataWithBytes:frame.data() length:frame.size()];NSError *error=nil;
            if(![session sendData:data toPeers:@[peer] withMode:MCSessionSendDataReliable error:&error]){std::lock_guard<std::mutex> guard(lock);if(generation==g.epoch&&g.protocol)g.protocol->disconnect();break;}
        }
    });
}
-(void)tick:(NSTimer*)timer{
    (void)timer;Phase phase=Phase::Ready;bool settled=false,endedReady=false,repeat=false;
    {std::lock_guard<std::mutex> guard(lock);if(g.protocol){phase=g.protocol->phase();settled=g.protocol->settled();endedReady=phase==Phase::Ended&&!g.started&&g.finishSaved;
        if((phase==Phase::Interrupted||phase==Phase::Failed)&&!g.radio)g.protocol->abandonAfterRadioOff();
        if(phase==Phase::Parked&&settled){if(!_parkedAt)_parkedAt=CACurrentMediaTime();if(CACurrentMediaTime()-_parkedAt>=5)g.protocol->close();}else _parkedAt=0;
        // A missing peer fence cannot retain an exited room indefinitely.
        if(!g.radio){if(!_offAt)_offAt=CACurrentMediaTime();if(CACurrentMediaTime()-_offAt>=20&&phase!=Phase::Ended){g.protocol->disconnect();g.protocol->abandonAfterRadioOff();}}else _offAt=0;
        if(CACurrentMediaTime()-_lastResend>=0.5&&phase!=Phase::Interrupted&&phase!=Phase::Failed&&phase!=Phase::Ended){repeat=true;_lastResend=CACurrentMediaTime();}}}
    [self drainWithRetransmit:repeat];
    if(endedReady){
        // A bounded radio-off park ends with bilateral CLOSE/ACK fences. The
        // next radio start creates a fresh room nonce; only the same approved
        // runtime may silently rejoin. Discovery resumes for other peers.
        [self.session disconnect];self.session=nil;self.partner=nil;_partnerMeta=nil;_inviting=NO;_parkedAt=_offAt=0;_prepared=NO;_meta=nil;
        {std::lock_guard<std::mutex> guard(lock);g.protocol.reset();g.prepared=g.requested=g.failedPrepare=g.intent=g.finishSaved=false;g.nonce=newNonce();}
        [_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
    }
    if(phase==Phase::Interrupted||phase==Phase::Failed)[self warning:@"Local wireless was interrupted. The current game remains in memory; no checkpoint was restored. Leave the room in both games and save normally before starting another session." generation:_generation];
}
-(void)warning:(NSString*)message generation:(uint64_t)generation{
    if(generation!=epoch.load()||_notice)return;
    _notice=[UIAlertController alertControllerWithTitle:@"DS nearby play" message:message preferredStyle:UIAlertControllerStyleAlert];
    [_notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){}]];[self dismiss];[presenter() presentViewController:_notice animated:YES completion:nil];
}
-(void)cleanup{
    [_timer invalidate];_timer=nil;[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];_advertiser=nil;_browser=nil;
    [self.session disconnect];self.session=nil;self.partner=nil;_partnerMeta=nil;_meta=nil;_peers=nil;_prepared=_inviting=NO;_parkedAt=_offAt=0;
    [self dismiss];if(_notice.presentingViewController)[_notice dismissViewControllerAnimated:NO completion:nil];_notice=nil;_approvedPeer=nil;_approvedRuntime=nil;
}
-(void)background:(NSNotification*)notification{
    (void)notification;{std::lock_guard<std::mutex> guard(lock);if(g.protocol)g.protocol->disconnect();}[self tick:nil];
}
-(void)browser:(MCNearbyServiceBrowser*)browser foundPeer:(MCPeerID*)peer withDiscoveryInfo:(NSDictionary*)info{
    dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser||![self valid:info])return;
        self->_peers[peer]=info;bool radio;{std::lock_guard<std::mutex> guard(lock);radio=g.radio;if(radio&&[info[@"local"] isEqual:@"1"])g.requested=true;}
        if(self->_prepared&&[peer isEqual:self->_approvedPeer]&&[info[@"runtime"] isEqual:self->_approvedRuntime])[self invite:peer info:info];else [self finder];
    });
}
-(void)browser:(MCNearbyServiceBrowser*)browser lostPeer:(MCPeerID*)peer{dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser)return;[self->_peers removeObjectForKey:peer];if(self->_dialog)[self finder];});}
-(void)advertiser:(MCNearbyServiceAdvertiser*)advertiser didReceiveInvitationFromPeer:(MCPeerID*)peer withContext:(NSData*)context invitationHandler:(void(^)(BOOL,MCSession*))handler{
    dispatch_async(dispatch_get_main_queue(),^{NSDictionary *info=context.length<=1024?[NSJSONSerialization JSONObjectWithData:context options:0 error:nil]:nil;
        if(advertiser!=self->_advertiser||!self->_prepared||![self valid:info]||(self.partner&&![self.partner isEqual:peer])){handler(NO,nil);return;}
        auto accept=^{self.partner=peer;self->_partnerMeta=info;self->_approvedPeer=peer;self->_approvedRuntime=info[@"runtime"];[self dismiss];handler(YES,self.session);};
        if([peer isEqual:self->_approvedPeer]&&[info[@"runtime"] isEqual:self->_approvedRuntime]){accept();return;}
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby player" message:[NSString stringWithFormat:@"Connect to %@ playing %@?",peer.displayName,titleName(info[@"code"])] preferredStyle:UIAlertControllerStyleAlert];
        uint64_t generation=self->_generation;
        [a addAction:[UIAlertAction actionWithTitle:@"Decline" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){handler(NO,nil);}]];
        [a addAction:[UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(generation!=epoch.load()){handler(NO,nil);return;}accept();}]];
        [self dismiss];self->_dialog=a;[presenter() presentViewController:a animated:YES completion:nil];
    });
}
-(void)session:(MCSession*)session peer:(MCPeerID*)peer didChangeState:(MCSessionState)state{
    dispatch_async(dispatch_get_main_queue(),^{if(session!=self.session||![peer isEqual:self.partner])return;
        if(state==MCSessionStateConnected){Nonce other;NSData *code=[self->_partnerMeta[@"code"] dataUsingEncoding:NSASCIIStringEncoding];
            if(!readNonce(self->_partnerMeta[@"nonce"],other)||code.length!=4)return;
            {std::lock_guard<std::mutex> guard(lock);if(!g.prepared||g.protocol)return;g.finishSaved=false;g.protocol=std::make_unique<manicds::Protocol>(g.nonce,g.code,g.revision);g.protocol->radio(g.radio);if(!g.protocol->bind(other,(const char*)code.bytes,uint8_t([self->_partnerMeta[@"rev"] intValue]))){g.protocol.reset();return;}}
            self->_approvedPeer=peer;self->_approvedRuntime=self->_partnerMeta[@"runtime"];self->_inviting=NO;[self dismiss];[self->_advertiser stopAdvertisingPeer];[self->_browser stopBrowsingForPeers];[self drain];
        }else if(state==MCSessionStateNotConnected){
            {std::lock_guard<std::mutex> guard(lock);if(g.protocol)g.protocol->disconnect();}
            self->_inviting=NO;[self tick:nil];
        }
    });
}
-(void)session:(MCSession*)session didReceiveData:(NSData*)data fromPeer:(MCPeerID*)peer{
    if(session!=self.session||![peer isEqual:self.partner]||data.length>WireHeader+MaxPacket)return;
    {std::lock_guard<std::mutex> guard(lock);if(g.protocol)g.protocol->receive(data.bytes,data.length);}[self drain];
}
-(void)session:(MCSession*)session didReceiveStream:(NSInputStream*)stream withName:(NSString*)name fromPeer:(MCPeerID*)peer{(void)session;(void)name;(void)peer;[stream close];}
-(void)session:(MCSession*)session didStartReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer withProgress:(NSProgress*)progress{(void)session;(void)name;(void)peer;[progress cancel];}
-(void)session:(MCSession*)session didFinishReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer atURL:(NSURL*)url withError:(NSError*)error{(void)session;(void)name;(void)peer;(void)url;(void)error;}
-(void)advertiser:(MCNearbyServiceAdvertiser*)advertiser didNotStartAdvertisingPeer:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(advertiser==self->_advertiser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on both devices." generation:self->_generation];});}
-(void)browser:(MCNearbyServiceBrowser*)browser didNotStartBrowsingForPeers:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on both devices." generation:self->_generation];});}
@end
