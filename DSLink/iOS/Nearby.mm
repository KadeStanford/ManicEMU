// SPDX-License-Identifier: AGPL-3.0-or-later
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <cstring>
#include <dlfcn.h>
#include <atomic>
#include <algorithm>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include "Bridge.h"
#include "Protocol.hpp"
#include "Room.hpp"
#include "Batch.hpp"
#include "PlayerName.h"
#include "../../TradeLink/iOS/FrontendSave.h"
using namespace manicds;
static NSString *const Service=@"manic-ds";
static NSString *const WireVersion=@"ds131-room6";
static std::mutex lock;
static std::condition_variable packetsReady;
static struct {
    std::unique_ptr<manicds::Room> room;
    MDSCore core{};
    retro_netpacket_callback net{};
    char code[4]{};
    uint8_t revision=0;
    bool loaded=false,radio=false,intent=false,requested=false,prepared=false,preparing=false;
    bool failedPrepare=false,started=false,held=false,warned=false,finishSaved=false;
    bool sendScheduled=false;
    uint64_t epoch=0,frames=0;
    bool finishPending=false;
    double nativeMilliseconds=0,waitMilliseconds=0,lastMetrics=0;
    uint64_t measuredFrames=0,waits=0,transportMessages=0;
    Nonce nonce{};
    NSData *lastBattery=nil;
    NSString *savePath=nil;
    NSString *wirelessMAC=nil;
} g;
static std::atomic<uint64_t> epoch{0};
static void (*originalPause)(id,SEL),(*originalResume)(id,SEL);
static NSString *hexNonce(Nonce value){NSMutableString *s=[NSMutableString new];for(auto b:value)[s appendFormat:@"%02x",b];return s;}
static bool readNonce(NSString *s,Nonce &n){
    if(![s isKindOfClass:NSString.class]||s.length!=32)return false;
    const char *p=s.UTF8String;static const char digits[]="0123456789abcdef";
    for(unsigned i=0;i<16;i++){char a=p[2*i],b=p[2*i+1];const char *x=strchr(digits,a),*y=strchr(digits,b);if(!x||!y||!a||!b)return false;n[i]=uint8_t((x-digits)*16+(y-digits));}return true;
}
static bool readMAC(NSString *s,MAC &m){
    if(![s isKindOfClass:NSString.class]||s.length!=12)return false;
    const char *p=s.UTF8String;static const char digits[]="0123456789abcdef";
    for(unsigned i=0;i<6;i++){char a=p[2*i],b=p[2*i+1];const char *x=strchr(digits,a),*y=strchr(digits,b);if(!x||!y||!a||!b)return false;m[i]=uint8_t((x-digits)*16+(y-digits));}
    return !(m[0]&1)&&std::any_of(m.begin(),m.end(),[](uint8_t b){return b!=0;});
}
static Nonce newNonce(){Nonce n;[NSUUID.UUID getUUIDBytes:n.data()];return n;}
static UIViewController *presenter(){
    UIViewController *v=nil;
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])
        for(UIWindow *w in ((UIWindowScene*)s).windows)if(w.isKeyWindow)v=w.rootViewController;
    while(v.presentedViewController)v=v.presentedViewController;return v;
}
@interface MDSNearby:NSObject<MCSessionDelegate,MCNearbyServiceAdvertiserDelegate,MCNearbyServiceBrowserDelegate>
@property(atomic,strong) MCSession *session;
+(instancetype)shared;
-(void)radio:(BOOL)on generation:(uint64_t)generation;
-(void)prepared:(uint64_t)generation;
-(void)drain;
-(void)cleanup;
-(void)warning:(NSString*)message generation:(uint64_t)generation;
@end
static void frontendHold(bool on){
    {std::lock_guard<std::mutex> guard(lock);if(g.room)g.room->hold(on);}
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
    uint8_t mac[6]{};bool identity=g.core.wirelessIdentity&&g.core.wirelessIdentity(mac)&&!(mac[0]&1);bool nonzero=false;for(auto b:mac)nonzero|=b!=0;
    // Do not alter an existing firmware/WFC identity to make a pair appear to
    // work. Games using MAC-dependent save checks must retain that identity.
    if(!identity||!nonzero){std::lock_guard<std::mutex> guard(lock);g.preparing=false;return;}
    NSMutableString *macText=[NSMutableString new];for(auto b:mac)[macText appendFormat:@"%02x",b];
    NSMutableData *state=size&&size<=128*1024*1024?[NSMutableData dataWithLength:size]:nil;
    bool ok=data&&path&&state&&g.core.serialize&&g.core.serialize(state.mutableBytes,size);
    if(ok){
        NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[[docs URLByAppendingPathComponent:@"ManicDSBackups" isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];NSError *error=nil;
        ok=[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]&&
           [data writeToURL:[dir URLByAppendingPathComponent:@"before.srm"] options:NSDataWritingAtomic error:&error]&&
           [state writeToURL:[dir URLByAppendingPathComponent:@"before.melonstate"] options:NSDataWritingAtomic error:&error];
    }
    {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;g.preparing=false;g.prepared=ok;g.failedPrepare=!ok;if(ok){g.savePath=path;g.lastBattery=data;g.wirelessMAC=macText;}}
    if(ok)dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] prepared:generation];});
    else warning(@"Nearby play stopped because the current save path or automatic checkpoint could not be verified. Keep your current game open and save normally.",generation);
}
static void sendPacket(int flags,const void *data,size_t size,uint16_t target){
    (void)flags;if(!size)return; // A flush hint has no game payload.
    if(!validPacket(data,size))return;
    Bytes copy(static_cast<const uint8_t*>(data),static_cast<const uint8_t*>(data)+size);
    {std::lock_guard<std::mutex> guard(lock);if(g.room){g.room->send(copy.data(),copy.size(),target);}}
    [[MDSNearby shared] drain];
}
static void pollPackets(){
    // Called synchronously by the real core's 25ms receive loop. Network
    // delegates enqueue only; all melonDS receive callbacks run on this thread.
    for(size_t i=0;i<MaxQueue;i++){
        Received p;retro_netpacket_receive_t receive=nullptr;
        {std::lock_guard<std::mutex> guard(lock);if(!g.room||!g.room->pop(p))break;if(g.started)receive=g.net.receive;}
        if(receive)receive(p.data.data(),p.data.size(),p.source);
    }
}
void MDS_waitForPackets(uint32_t microseconds){
    if(!microseconds||microseconds>1000)return;
    auto begin=std::chrono::steady_clock::now();std::unique_lock<std::mutex> guard(lock);const auto generation=g.epoch;
    packetsReady.wait_for(guard,std::chrono::microseconds(microseconds),[generation]{return g.epoch!=generation||(g.room&&g.room->hasIncoming());});
    g.waits++;g.waitMilliseconds+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
}
void MDS_netpacket(const retro_netpacket_callback *cb){if(cb){std::lock_guard<std::mutex> guard(lock);g.net=*cb;}}
void MDS_gameLoaded(const char code[4],uint8_t revision,MDSCore core){
    MDS_gameUnloading();
    {std::lock_guard<std::mutex> guard(lock);g.core=core;std::memcpy(g.code,code,4);g.revision=revision;g.loaded=title(code)!=0;g.epoch=++epoch;g.nonce=newNonce();g.frames=0;g.nativeMilliseconds=g.waitMilliseconds=g.lastMetrics=0;g.measuredFrames=g.waits=g.transportMessages=0;}
    dispatch_async(dispatch_get_main_queue(),^{installPauseHooks();});
}
void MDS_signal(unsigned event,const void *packet){
    uint64_t generation;bool on=false,changed=false;
    {std::lock_guard<std::mutex> guard(lock);if(!g.loaded)return;generation=g.epoch;
        if(event==1||event==2){on=event==1;changed=g.radio!=on;g.radio=on;if(g.room)g.room->radio(on);if(changed&&!on&&g.prepared)g.finishPending=true;}
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
    bool start=false,stop=false,finish=false,allow=true;retro_netpacket_callback cb;uint64_t generation;
    {std::lock_guard<std::mutex> guard(lock);cb=g.net;generation=g.epoch;
        bool active=g.room&&g.room->active();start=active&&g.radio&&!g.started;stop=g.started&&(!active||!g.radio);
        finish=g.finishPending;g.finishPending=false;allow=!g.room||!g.room->paused();
        if(start)g.started=true;if(stop)g.started=false;
    }
    if(stop&&cb.stop)cb.stop();
    if(start&&cb.start)cb.start(0,sendPacket,pollPackets);
    if(finish&&!persist(true))warning(@"The current DS battery save could not be verified at room exit. Keep the game open and save normally; your pre-link checkpoint was retained.",generation);
    pollPackets();[[MDSNearby shared] drain];return allow;
}
void MDS_afterFrame(double nativeMilliseconds){
    prepare();bool save=false;uint64_t generation;
    NSDictionary *metrics=nil;
    {std::lock_guard<std::mutex> guard(lock);generation=g.epoch;save=g.prepared&&g.room&&((++g.frames%60)==0);
        if(g.room&&nativeMilliseconds>0){g.nativeMilliseconds+=nativeMilliseconds;g.measuredFrames++;}
        if(g.room&&CACurrentMediaTime()-g.lastMetrics>=5){g.lastMetrics=CACurrentMediaTime();
            metrics=@{@"format":@1,@"candidate":@"DS-v0.5",@"phase":@(g.radio?(g.room->active()?2:1):3),@"native_frames":@(g.measuredFrames),@"native_ms":@(g.nativeMilliseconds),@"receive_wait_calls":@(g.waits),@"receive_wait_ms":@(g.waitMilliseconds),@"sent":@(g.room->sentCount()),@"received":@(g.room->receivedCount()),@"acknowledged":@(g.room->acknowledged()),@"pending":@(g.room->pendingCount()),@"duplicates":@(g.room->duplicateCount()),@"rejected":@(g.room->rejectedCount()),@"transport_messages":@(g.transportMessages),@"unix_time":@(NSDate.date.timeIntervalSince1970)};
        }
    }
    if(metrics){dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        if(generation!=epoch.load())return;NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[docs URLByAppendingPathComponent:@"ManicDSDiagnostics" isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil] writeToURL:[dir URLByAppendingPathComponent:@"current.json"] options:NSDataWritingAtomic error:nil];
    });}
    if(save&&!persist(false))warning(@"The current DS battery save could not be written and verified. Keep the game open and save normally; the pre-link checkpoint remains untouched.",generation);
}
bool MDS_allowRestore(){std::lock_guard<std::mutex> guard(lock);return !g.room||(!g.radio&&!g.room->active());}
void MDS_gameUnloading(){
    bool flush=false;retro_netpacket_callback cb;
    {std::lock_guard<std::mutex> guard(lock);flush=g.loaded&&g.prepared;cb=g.net;}
    if(flush&&!persist(true))warning(@"The current DS battery save was not verified at game close. Your pre-link backup was retained.",epoch.load());
    if(g.started&&cb.stop)cb.stop();
    {std::lock_guard<std::mutex> guard(lock);g.room.reset();g.finishPending=false;g.sendScheduled=false;g.loaded=g.radio=g.intent=g.requested=g.prepared=g.preparing=g.failedPrepare=g.started=g.held=false;g.warned=false;g.lastBattery=nil;g.savePath=nil;g.wirelessMAC=nil;g.epoch=++epoch;}packetsReady.notify_all();
    uint64_t generation=epoch.load();dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load())[[MDSNearby shared] cleanup];});
}
@implementation MDSNearby {
    MCNearbyServiceAdvertiser *_advertiser;MCNearbyServiceBrowser *_browser;MCPeerID *_identity;
    NSMutableDictionary<MCPeerID*,NSDictionary*> *_peers;
    NSMutableDictionary<MCPeerID*,NSNumber*> *_attempts,*_retryAt;
    // Access these only while holding the same mutex as the native room.
    NSMutableDictionary<MCPeerID*,NSString*> *_wirePeers;
    NSMutableDictionary<MCPeerID*,NSMutableArray<NSData*>*> *_early;
    NSDictionary *_meta;NSString *_runtime;UIAlertController *_notice;
    NSTimer *_timer;uint64_t _generation;BOOL _prepared;
    dispatch_queue_t _sendQueue;
}
+(instancetype)shared{static MDSNearby *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
-(instancetype)init{if((self=[super init])){_sendQueue=dispatch_queue_create("org.manicemu.ds.room",DISPATCH_QUEUE_SERIAL);[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];}return self;}
-(BOOL)valid:(NSDictionary*)info{
    Nonce n;MAC mac,alias;
    if(![info isKindOfClass:NSDictionary.class]||![info[@"v"] isEqual:WireVersion]||![info[@"ready"] isEqual:@"1"]||![info[@"local"] isEqual:@"1"]||!readNonce(info[@"nonce"],n)||![info[@"code"] isKindOfClass:NSString.class]||![info[@"runtime"] isKindOfClass:NSString.class]||!readMAC(info[@"mac"],mac)||!readMAC(info[@"alias"],alias)||alias!=Room::address(n))return NO;
    NSData *a=[_meta[@"code"] dataUsingEncoding:NSASCIIStringEncoding],*b=[info[@"code"] dataUsingEncoding:NSASCIIStringEncoding];
    return a.length==4&&b.length==4&&compatible((const char*)a.bytes,(const char*)b.bytes)&&![info[@"runtime"] isEqual:_runtime];
}
-(void)advertise{
    [_advertiser stopAdvertisingPeer];if(!_identity||!_meta)return;
    _advertiser=[[MCNearbyServiceAdvertiser alloc]initWithPeer:_identity discoveryInfo:_meta serviceType:Service];_advertiser.delegate=self;[_advertiser startAdvertisingPeer];
}
-(void)radio:(BOOL)on generation:(uint64_t)generation{
    if(!on){[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];return;}
    if(generation!=_generation){[self cleanup];_generation=generation;_runtime=NSUUID.UUID.UUIDString;_identity=[[MCPeerID alloc]initWithDisplayName:localPlayerName()];_peers=[NSMutableDictionary new];_attempts=[NSMutableDictionary new];_retryAt=[NSMutableDictionary new];
        std::lock_guard<std::mutex> guard(lock);_wirePeers=[NSMutableDictionary new];_early=[NSMutableDictionary new];}
    if(!_meta){char code[4];uint8_t rev;Nonce n;{std::lock_guard<std::mutex> guard(lock);std::memcpy(code,g.code,4);rev=g.revision;n=g.nonce;}
        _meta=@{@"v":WireVersion,@"code":[[NSString alloc]initWithBytes:code length:4 encoding:NSASCIIStringEncoding],@"rev":[NSString stringWithFormat:@"%u",rev],@"nonce":hexNonce(n),@"runtime":_runtime,@"ready":@"0",@"local":@"0"};}
    if(!_timer)_timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    if(!self.session){self.session=[[MCSession alloc]initWithPeer:_identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];self.session.delegate=self;}
    if(!_browser){_browser=[[MCNearbyServiceBrowser alloc]initWithPeer:_identity serviceType:Service];_browser.delegate=self;}
    [_browser startBrowsingForPeers];[self advertise];[self connectReadyPeers];
}
-(void)prepared:(uint64_t)generation{
    if(generation!=_generation)return;_prepared=YES;NSMutableDictionary *m=[_meta mutableCopy];m[@"ready"]=@"1";
    {std::lock_guard<std::mutex> guard(lock);m[@"local"]=g.intent?@"1":@"0";m[@"mac"]=g.wirelessMAC;MAC native;if(!readMAC(g.wirelessMAC,native))return;
        if(!g.room){g.room=std::make_unique<Room>(g.nonce,g.code,g.revision,native);g.room->radio(g.radio);}
        NSMutableString *alias=[NSMutableString new];for(auto b:g.room->alias())[alias appendFormat:@"%02x",b];m[@"alias"]=alias;}
    _meta=m;[self advertise];[self connectReadyPeers];
}
-(void)connectReadyPeers{
    bool radio;{std::lock_guard<std::mutex> guard(lock);radio=g.radio;}if(!_prepared||!radio)return;
    for(MCPeerID *peer in _peers){NSDictionary *info=_peers[peer];
        if(![self valid:info]||[self.session.connectedPeers containsObject:peer]||_attempts[peer]||[_retryAt[peer] doubleValue]>CACurrentMediaTime())continue;
        // Exactly one side invites, regardless of simultaneous room arrivals.
        if([_runtime compare:info[@"runtime"]]!=NSOrderedAscending)continue;
        if(self.session.connectedPeers.count+_attempts.count>=Room::MaxPeers)break;
        _attempts[peer]=@(CACurrentMediaTime());NSData *context=[NSJSONSerialization dataWithJSONObject:_meta options:0 error:nil];
        [_browser invitePeer:peer toSession:self.session withContext:context timeout:8];
    }
}
-(void)hello:(MCPeerID*)peer{
    if(!_meta)return;NSMutableData *data=[NSMutableData dataWithBytes:"MDH5" length:4];[data appendData:[NSJSONSerialization dataWithJSONObject:_meta options:0 error:nil]];
    MCSession *session=self.session;dispatch_async(_sendQueue,^{[session sendData:data toPeers:@[peer] withMode:MCSessionSendDataReliable error:nil];});
}
-(void)attach:(MCPeerID*)peer info:(NSDictionary*)info{
    if(![self valid:info]||![self.session.connectedPeers containsObject:peer])return;
    Nonce other;MAC alias;NSData *code=[info[@"code"] dataUsingEncoding:NSASCIIStringEncoding];if(!readNonce(info[@"nonce"],other)||!readMAC(info[@"alias"],alias))return;
    {std::lock_guard<std::mutex> guard(lock);if(!g.room)return;
        if(!_wirePeers[peer]&&!g.room->add(other,(const char*)code.bytes,uint8_t([info[@"rev"] intValue]),alias))return;
        if(_wirePeers[peer]&&![_wirePeers[peer] isEqual:info[@"nonce"]])return;
        _wirePeers[peer]=info[@"nonce"];
        for(NSData *data in _early[peer]){std::vector<Bytes> frames;if(unbatchWire(data.bytes,data.length,frames))for(const auto &frame:frames)g.room->receive(other,frame.data(),frame.size());}
        [_early removeObjectForKey:peer];}
    packetsReady.notify_all();[self drain];
}
-(void)drain{
    MCSession *session=self.session;if(!session)return;uint64_t generation=epoch.load();
    {std::lock_guard<std::mutex> guard(lock);if(!g.room||g.sendScheduled)return;g.sendScheduled=true;}
    dispatch_async(_sendQueue,^{for(;;){NSMutableArray *out=[NSMutableArray new];
        {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;if(!g.room||session!=self.session){g.sendScheduled=false;return;}
            for(MCPeerID *peer in self->_wirePeers){Nonce n;if(!readNonce(self->_wirePeers[peer],n))continue;
                for(const auto &batch:batchWire(g.room->takeWire(n)))[out addObject:@[peer,[NSData dataWithBytes:batch.data() length:batch.size()]]];}
            if(!out.count){g.sendScheduled=false;return;}}
        for(NSArray *entry in out){NSError *error=nil;BOOL sent=[session sendData:entry[1] toPeers:@[entry[0]] withMode:MCSessionSendDataReliable error:&error];
            {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;g.transportMessages++;}
            if(!sent)dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load()&&session==self.session){[self remove:entry[0]];[session cancelConnectPeer:entry[0]];}});}
    }});
}
-(void)remove:(MCPeerID*)peer{
    {std::lock_guard<std::mutex> guard(lock);Nonce n;if(readNonce(_wirePeers[peer],n)&&g.room)g.room->remove(n);[_wirePeers removeObjectForKey:peer];[_early removeObjectForKey:peer];}
    [_attempts removeObjectForKey:peer];_retryAt[peer]=@(CACurrentMediaTime()+2);packetsReady.notify_all();
}
-(void)tick:(NSTimer*)timer{
    (void)timer;for(MCPeerID *peer in [_attempts.allKeys copy])if(CACurrentMediaTime()-[_attempts[peer] doubleValue]>9){
        [_attempts removeObjectForKey:peer];_retryAt[peer]=@(CACurrentMediaTime()+2);[self.session cancelConnectPeer:peer];}
    [self connectReadyPeers];[self drain];
}
-(void)warning:(NSString*)message generation:(uint64_t)generation{
    if(generation!=epoch.load()||_notice)return;_notice=[UIAlertController alertControllerWithTitle:@"DS nearby play" message:message preferredStyle:UIAlertControllerStyleAlert];
    [_notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){}]];[presenter() presentViewController:_notice animated:YES completion:nil];
}
-(void)cleanup{
    [_timer invalidate];_timer=nil;[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];_advertiser=nil;_browser=nil;
    [self.session disconnect];self.session=nil;_meta=nil;_peers=nil;_attempts=nil;_retryAt=nil;_prepared=NO;
    {std::lock_guard<std::mutex> guard(lock);_wirePeers=nil;_early=nil;}
    if(_notice.presentingViewController)[_notice dismissViewControllerAnimated:NO completion:nil];_notice=nil;
}
-(void)background:(NSNotification*)notification{
    (void)notification;for(MCPeerID *peer in self.session.connectedPeers)[self remove:peer];[self.session disconnect];
}
-(void)browser:(MCNearbyServiceBrowser*)browser foundPeer:(MCPeerID*)peer withDiscoveryInfo:(NSDictionary*)info{
    dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser||![self valid:info])return;self->_peers[peer]=info;[self connectReadyPeers];});
}
-(void)browser:(MCNearbyServiceBrowser*)browser lostPeer:(MCPeerID*)peer{
    dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser)[self->_peers removeObjectForKey:peer];});
}
-(void)advertiser:(MCNearbyServiceAdvertiser*)advertiser didReceiveInvitationFromPeer:(MCPeerID*)peer withContext:(NSData*)context invitationHandler:(void(^)(BOOL,MCSession*))handler{
    dispatch_async(dispatch_get_main_queue(),^{NSDictionary *info=context.length<=1024?[NSJSONSerialization JSONObjectWithData:context options:0 error:nil]:nil;
        bool radio;{std::lock_guard<std::mutex> guard(lock);radio=g.radio;}
        if(advertiser!=self->_advertiser||!self->_prepared||!radio||![self valid:info]||self.session.connectedPeers.count>=Room::MaxPeers){handler(NO,nil);return;}
        if([self->_runtime compare:info[@"runtime"]]==NSOrderedAscending){handler(NO,nil);return;}
        self->_peers[peer]=info;self->_attempts[peer]=@(CACurrentMediaTime());handler(YES,self.session);
    });
}
-(void)session:(MCSession*)session peer:(MCPeerID*)peer didChangeState:(MCSessionState)state{
    dispatch_async(dispatch_get_main_queue(),^{if(session!=self.session)return;
        if(state==MCSessionStateConnected){[self->_attempts removeObjectForKey:peer];[self->_retryAt removeObjectForKey:peer];[self hello:peer];[self attach:peer info:self->_peers[peer]];}
        else if(state==MCSessionStateNotConnected){[self remove:peer];[self connectReadyPeers];}
    });
}
-(void)session:(MCSession*)session didReceiveData:(NSData*)data fromPeer:(MCPeerID*)peer{
    if(session!=self.session)return;
    if(data.length>=4&&!memcmp(data.bytes,"MDH5",4)){
        if(data.length>1028)return;NSDictionary *info=[NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(4,data.length-4)] options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(),^{if(session==self.session){[self attach:peer info:info];}});return;
    }
    std::vector<Bytes> frames;if(!unbatchWire(data.bytes,data.length,frames))return;
    {std::lock_guard<std::mutex> guard(lock);if(!g.room)return;Nonce n;
        if(readNonce(_wirePeers[peer],n)){for(const auto &frame:frames)g.room->receive(n,frame.data(),frame.size());}
        else if(_early.count<Room::MaxPeers||_early[peer]){if(!_early[peer])_early[peer]=[NSMutableArray new];if(_early[peer].count<16)[_early[peer] addObject:data];}}
    packetsReady.notify_all();[self drain];
}
-(void)session:(MCSession*)session didReceiveStream:(NSInputStream*)stream withName:(NSString*)name fromPeer:(MCPeerID*)peer{(void)session;(void)name;(void)peer;[stream close];}
-(void)session:(MCSession*)session didStartReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer withProgress:(NSProgress*)progress{(void)session;(void)name;(void)peer;[progress cancel];}
-(void)session:(MCSession*)session didFinishReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer atURL:(NSURL*)url withError:(NSError*)error{(void)session;(void)name;(void)peer;(void)url;(void)error;}
-(void)advertiser:(MCNearbyServiceAdvertiser*)advertiser didNotStartAdvertisingPeer:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(advertiser==self->_advertiser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on the devices." generation:self->_generation];});}
-(void)browser:(MCNearbyServiceBrowser*)browser didNotStartBrowsingForPeers:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on the devices." generation:self->_generation];});}
@end
