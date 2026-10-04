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
#include "DiagnosticRecorder.h"
#include <sys/resource.h>
#include <unistd.h>
#include "../../TradeLink/iOS/FrontendSave.h"
using namespace manicds;
static NSString *const Service=@"manic-ds";
static NSString *const WireVersion=@"ds131-room9";
static std::mutex lock;
static std::condition_variable packetsReady;
struct ReceiveDiagnostics {
    unsigned scope=0;
    uint64_t hostCalls=0,replyCalls=0,hostWaits=0,replyWaits=0;
    uint64_t hostTimeouts=0,replyTimeouts=0,hostEmpty=0,replyComplete=0,replyIncomplete=0;
    uint64_t replyResults[7]{};
    double hostWaitMilliseconds=0,replyWaitMilliseconds=0;
};
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
    uint64_t nativeTimeouts=0,nativeCmd=0,nativeReply=0,nativeOther=0,filterBSSID=0,filterDestination=0;
    uint64_t unreliableSendFailures=0;
    ReceiveDiagnostics receive{};
    std::unique_ptr<DiagnosticRing> traces;
    std::unique_ptr<DiagnosticRing> lastIncomplete,lastSlow;
    double diagnosticStart=0,traceCopyMax=0,writerMilliseconds=0,frameMax=0,lastSlowSnapshot=0;
    uint64_t writerFailures=0,frameOver50=0,snapshot=0;
    unsigned diagnosticSession=0;
    bool incompleteSinceSnapshot=false,slowSinceSnapshot=false;
    double lastIncompleteFreeze=0,lastSlowFreeze=0,snapshotBuildMax=0;
    NSMutableDictionary *options=nil;
    uint64_t videoCallbacks=0,videoDuplicates=0,audioFrames=0,audioConsumed=0;
    unsigned videoWidth=0,videoHeight=0;
    double sendQueueDelayMax=0,sendCallMax=0;
    Nonce nonce{};
    NSData *lastBattery=nil;
    NSString *savePath=nil;
    NSString *wirelessMAC=nil;
} g;
static std::atomic<uint64_t> epoch{0};
void MDS_coreOption(const char *key,const char *value){
    if(!key||!value)return;static const char *allowed[]={"melonds_console_mode","melonds_render_mode","melonds_threaded_renderer","melonds_jit_enable","melonds_jit_block_size","melonds_jit_branch_optimisations","melonds_jit_literal_optimisations","melonds_jit_fast_memory"};
    if(!std::any_of(std::begin(allowed),std::end(allowed),[key](const char *name){return !strcmp(key,name);})||strnlen(value,65)>64)return;
    std::lock_guard<std::mutex> guard(lock);if(!g.options)g.options=[NSMutableDictionary new];
    NSString *text=[NSString stringWithUTF8String:value];if(text)g.options[[NSString stringWithUTF8String:key]]=text;
}
void MDS_video(unsigned width,unsigned height,bool duplicate){std::lock_guard<std::mutex> guard(lock);if(!g.loaded)return;g.videoCallbacks++;g.videoDuplicates+=duplicate;g.videoWidth=width;g.videoHeight=height;}
void MDS_audio(size_t frames,size_t consumed){std::lock_guard<std::mutex> guard(lock);if(!g.loaded)return;g.audioFrames+=frames;g.audioConsumed+=consumed;}
static void traceLocked(const NativeDiagnostic& trace){
    if(!g.loaded||!g.traces)return;double now=CACurrentMediaTime();
    g.traces->record(trace,uint64_t(std::max(0.0,now-g.diagnosticStart)*1000000));
    if(trace.event==5&&trace.reason==33&&now-g.lastIncompleteFreeze>=1){
        *g.lastIncomplete=*g.traces;g.incompleteSinceSnapshot=true;g.lastIncompleteFreeze=now;
    }
}
void MDS_trace(const NativeDiagnostic& trace){
    double begin=CACurrentMediaTime();std::lock_guard<std::mutex> guard(lock);
    traceLocked(trace);g.traceCopyMax=std::max(g.traceCopyMax,(CACurrentMediaTime()-begin)*1000);
}
static dispatch_queue_t diagnosticQueue(){
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("manic.ds.diagnostics",DISPATCH_QUEUE_SERIAL);});return queue;
}
static std::atomic<unsigned> diagnosticJobs{0};
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
-(BOOL)candidate:(NSDictionary*)info;
-(MCNearbyServiceBrowser*)newBrowser;
-(MCNearbyServiceAdvertiser*)newAdvertiser;
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
    if((g.core.firmwareIdentityMatches&&!g.core.firmwareIdentityMatches())||
       (g.core.localIdentityMatches&&!g.core.localIdentityMatches())){
        {std::lock_guard<std::mutex> guard(lock);g.preparing=false;g.failedPrepare=true;}
        warning(@"This DS state has an older console identity. Save in the game, then restart from the game's normal save before nearby play. Your state and save files have been kept.",generation);return;
    }
    // Original serialization functions execute here, between original frames.
    NSData *data=battery();NSString *path=activePath();size_t size=g.core.stateSize?g.core.stateSize():0;
    uint8_t mac[6]{};bool identity=g.core.wirelessIdentity&&g.core.wirelessIdentity(mac)&&!(mac[0]&1);bool nonzero=false;for(auto b:mac)nonzero|=b!=0;
    // This is the console's actual identity, including a restored state's
    // registers. Real firmware and explicitly configured identities stay native.
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
    if(!size){if(flags&RETRO_NETPACKET_FLUSH_HINT)[[MDSNearby shared] drain];return;}
    if(!validPacket(data,size))return;
    Bytes copy(static_cast<const uint8_t*>(data),static_cast<const uint8_t*>(data)+size);
    {std::lock_guard<std::mutex> guard(lock);if(g.room){
        if(flags&RETRO_NETPACKET_RELIABLE)g.room->send(copy.data(),copy.size(),target);
        else g.room->sendRadio(copy.data(),copy.size(),target);
    }}
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
    double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
    g.waits++;g.waitMilliseconds+=elapsed;
    if(g.receive.scope==1){g.receive.hostWaits++;g.receive.hostWaitMilliseconds+=elapsed;}
    if(g.receive.scope==2){g.receive.replyWaits++;g.receive.replyWaitMilliseconds+=elapsed;}
    if(elapsed*1000>double(microseconds)+2000){NativeDiagnostic t;t.event=102;t.timestamp=microseconds;
        t.referenceTimestamp=uint64_t(elapsed*1000);t.aidmask=g.receive.scope;t.reason=g.room&&g.room->hasIncoming()?1:0;traceLocked(t);}
}
void MDS_netpacket(const retro_netpacket_callback *cb){if(cb){std::lock_guard<std::mutex> guard(lock);g.net=*cb;}}
void MDS_gameLoaded(const char code[4],uint8_t revision,MDSCore core){
    MDS_gameUnloading();
    {std::lock_guard<std::mutex> guard(lock);g.core=core;std::memcpy(g.code,code,4);g.revision=revision;g.loaded=title(code)!=0;g.epoch=++epoch;g.nonce=newNonce();g.frames=0;g.nativeMilliseconds=g.waitMilliseconds=g.lastMetrics=0;g.measuredFrames=g.waits=g.transportMessages=0;g.nativeTimeouts=g.nativeCmd=g.nativeReply=g.nativeOther=g.filterBSSID=g.filterDestination=g.unreliableSendFailures=0;g.sendQueueDelayMax=g.sendCallMax=0;g.receive={};}
    dispatch_async(dispatch_get_main_queue(),^{installPauseHooks();});
    {std::lock_guard<std::mutex> guard(lock);if(g.loaded){
        NSInteger next=[NSUserDefaults.standardUserDefaults integerForKey:@"ManicDSDiagnosticNextSlot"];
        g.diagnosticSession=unsigned(next)&15;[NSUserDefaults.standardUserDefaults setInteger:NSInteger((g.diagnosticSession+1)&15) forKey:@"ManicDSDiagnosticNextSlot"];
        g.traces=std::make_unique<DiagnosticRing>();g.lastIncomplete=std::make_unique<DiagnosticRing>();g.lastSlow=std::make_unique<DiagnosticRing>();
        g.diagnosticStart=CACurrentMediaTime();g.traceCopyMax=g.writerMilliseconds=g.frameMax=g.lastIncompleteFreeze=g.lastSlowFreeze=g.snapshotBuildMax=0;
        g.writerFailures=g.frameOver50=g.snapshot=0;g.incompleteSinceSnapshot=g.slowSinceSnapshot=false;
        g.videoCallbacks=g.videoDuplicates=g.audioFrames=g.audioConsumed=0;g.videoWidth=g.videoHeight=0;
    }}
}
void MDS_signal(unsigned event,const void *packet){
    uint64_t generation;bool on=false,changed=false;
    {std::lock_guard<std::mutex> guard(lock);if(!g.loaded)return;generation=g.epoch;
        if(event==20){g.receive.scope=1;g.receive.hostCalls++;}
        if(event==30){g.receive.scope=2;g.receive.replyCalls++;}
        if(event==21||event==31)g.receive.scope=0;
        if(event==22)g.receive.hostEmpty++;
        if(event==32)g.receive.replyComplete++;
        if(event==33)g.receive.replyIncomplete++;
        if(event>=40&&event<=46)g.receive.replyResults[event-40]++;
        if(event==4){g.nativeTimeouts++;if(g.receive.scope==1)g.receive.hostTimeouts++;if(g.receive.scope==2)g.receive.replyTimeouts++;}
        if(event==5)g.nativeCmd++;if(event==6)g.nativeReply++;
        if(event==7)g.nativeOther++;if(event==8)g.filterBSSID++;if(event==9)g.filterDestination++;
        if(event>=4)return;
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
void MDS_afterFrame(double nativeMilliseconds,bool finalSnapshot){
    if(!finalSnapshot)prepare();bool save=false;uint64_t generation;
    NSDictionary *metrics=nil,*incomplete=nil,*slow=nil;unsigned slot=0;uint64_t snapshot=0;
    double buildBegin=CACurrentMediaTime();
    {std::lock_guard<std::mutex> guard(lock);generation=g.epoch;save=!finalSnapshot&&g.prepared&&g.room&&((++g.frames%60)==0);
        if(g.loaded&&nativeMilliseconds>0){g.nativeMilliseconds+=nativeMilliseconds;g.measuredFrames++;g.frameMax=std::max(g.frameMax,nativeMilliseconds);
            if(nativeMilliseconds>50){g.frameOver50++;if(g.traces&&CACurrentMediaTime()-g.lastSlowFreeze>=1){*g.lastSlow=*g.traces;g.lastSlowFreeze=CACurrentMediaTime();g.slowSinceSnapshot=true;}}}
        if(g.loaded&&(finalSnapshot||CACurrentMediaTime()-g.lastMetrics>=5)){g.lastMetrics=CACurrentMediaTime();
            metrics=@{@"format":@5,@"candidate":@"DS-v0.9",@"phase":@(g.room?(g.radio?(g.room->active()?2:1):3):0),@"native_frames":@(g.measuredFrames),@"native_ms":@(g.nativeMilliseconds),@"receive_wait_calls":@(g.waits),@"receive_wait_ms":@(g.waitMilliseconds),@"sent":@(g.room?g.room->sentCount():0),@"received":@(g.room?g.room->receivedCount():0),@"acknowledged":@(g.room?g.room->acknowledged():0),@"pending":@(g.room?g.room->pendingCount():0),@"duplicates":@(g.room?g.room->duplicateCount():0),@"rejected":@(g.room?g.room->rejectedCount():0),@"native_radio_sent":@(g.room?g.room->radioSentCount():0),@"native_radio_received":@(g.room?g.room->radioReceivedCount():0),@"native_radio_dropped":@(g.room?g.room->radioDroppedCount():0),@"fragment_dropped":@(g.room?g.room->fragmentDroppedCount():0),@"unreliable_send_failures":@(g.unreliableSendFailures),@"transport_messages":@(g.transportMessages),@"unix_time":@(NSDate.date.timeIntervalSince1970),@"receive_scope":@(g.receive.scope),@"host_receive_calls":@(g.receive.hostCalls),@"reply_receive_calls":@(g.receive.replyCalls),@"host_wait_calls":@(g.receive.hostWaits),@"reply_wait_calls":@(g.receive.replyWaits),@"host_wait_ms":@(g.receive.hostWaitMilliseconds),@"reply_wait_ms":@(g.receive.replyWaitMilliseconds),@"host_timeouts":@(g.receive.hostTimeouts),@"reply_timeouts":@(g.receive.replyTimeouts),@"host_empty":@(g.receive.hostEmpty),@"reply_complete":@(g.receive.replyComplete),@"reply_incomplete":@(g.receive.replyIncomplete),@"reply_payload":@(g.receive.replyResults[0]),@"reply_empty":@(g.receive.replyResults[1]),@"reply_stale":@(g.receive.replyResults[2]),@"reply_unknown_aid":@(g.receive.replyResults[3]),@"reply_unexpected_aid":@(g.receive.replyResults[4]),@"reply_duplicate_aid":@(g.receive.replyResults[5]),@"reply_malformed":@(g.receive.replyResults[6]),@"native_timeouts":@(g.nativeTimeouts),@"native_cmd":@(g.nativeCmd),@"native_reply":@(g.nativeReply),@"native_other":@(g.nativeOther),@"filter_bssid":@(g.filterBSSID),@"filter_destination":@(g.filterDestination),@"send_queue_delay_max_ms":@(g.sendQueueDelayMax),@"send_call_max_ms":@(g.sendCallMax),@"room_peers":@(g.room?g.room->size():0),@"identity_requests":@(g.core.identityRequests?g.core.identityRequests():0),@"local_identity_matches":@(g.core.localIdentityMatches&&g.core.localIdentityMatches()),@"firmware_identity_matches":@(g.core.firmwareIdentityMatches&&g.core.firmwareIdentityMatches()),@"prepare_failed":@(g.failedPrepare)};
            NSMutableDictionary *detail=[metrics mutableCopy];
            detail[@"code"]=[[NSString alloc]initWithBytes:g.code length:4 encoding:NSASCIIStringEncoding];detail[@"revision"]=@(g.revision);
            detail[@"session"]=[NSString stringWithFormat:@"%d-%llu",getpid(),(unsigned long long)g.epoch];
            detail[@"thermal_state"]=@(NSProcessInfo.processInfo.thermalState);detail[@"low_power_mode"]=@(NSProcessInfo.processInfo.lowPowerModeEnabled);
            detail[@"os_version"]=UIDevice.currentDevice.systemVersion;detail[@"device_model"]=UIDevice.currentDevice.model;
            detail[@"core_options"]=g.options?[g.options copy]:@{};detail[@"video_callbacks"]=@(g.videoCallbacks);detail[@"video_duplicates"]=@(g.videoDuplicates);
            detail[@"video_width"]=@(g.videoWidth);detail[@"video_height"]=@(g.videoHeight);detail[@"audio_frames"]=@(g.audioFrames);detail[@"audio_consumed"]=@(g.audioConsumed);
            struct rusage usage{};getrusage(RUSAGE_SELF,&usage);
            detail[@"process_cpu_ms"]=@(double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1000+double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1000);
            detail[@"process_max_rss_bytes"]=@(usage.ru_maxrss);detail[@"frame_max_ms"]=@(g.frameMax);detail[@"frames_over_50_ms"]=@(g.frameOver50);
            detail[@"diagnostic_copy_max_ms"]=@(g.traceCopyMax);detail[@"diagnostic_build_max_ms"]=@(g.snapshotBuildMax);
            detail[@"diagnostic_write_max_ms"]=@(g.writerMilliseconds);detail[@"diagnostic_write_failures"]=@(g.writerFailures);
            detail[@"trace_count"]=@(g.traces?g.traces->count():0);detail[@"trace_overwritten"]=@(g.traces?g.traces->overwritten():0);
            detail[@"trace_rejected"]=@(g.traces?g.traces->rejected():0);detail[@"trace"]=g.traces?diagnosticRecords(*g.traces):@[];
            detail[@"final_snapshot"]=@(finalSnapshot);slot=g.diagnosticSession;snapshot=g.snapshot++;
            if(g.incompleteSinceSnapshot&&g.lastIncomplete){NSMutableDictionary *pin=[detail mutableCopy];pin[@"trace"]=diagnosticRecords(*g.lastIncomplete);pin[@"snapshot_kind"]=@"last-incomplete";incomplete=pin;g.incompleteSinceSnapshot=false;}
            if(g.slowSinceSnapshot&&g.lastSlow){NSMutableDictionary *pin=[detail mutableCopy];pin[@"trace"]=diagnosticRecords(*g.lastSlow);pin[@"snapshot_kind"]=@"last-slow";slow=pin;g.slowSinceSnapshot=false;}
            detail[@"snapshot_kind"]=finalSnapshot?@"final":@"periodic";metrics=detail;
            g.snapshotBuildMax=std::max(g.snapshotBuildMax,(CACurrentMediaTime()-buildBegin)*1000);
        }
    }
    if(metrics&&diagnosticJobs.load()<2){diagnosticJobs++;dispatch_async(diagnosticQueue(),^{@autoreleasepool{
        double begin=CACurrentMediaTime();NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[docs URLByAppendingPathComponent:@"ManicDSDiagnostics" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        uint64_t failures=0;
        auto write=[&](NSDictionary *value,NSString *name){if(!value)return;
            NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            if(!data||data.length>524288||![data writeToURL:[dir URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil])failures++;
        };
        write(metrics,[NSString stringWithFormat:@"capture-%02u-%u.json",slot,unsigned(snapshot%8)]);
        write(incomplete,[NSString stringWithFormat:@"capture-%02u-incomplete.json",slot]);
        write(slow,[NSString stringWithFormat:@"capture-%02u-slow.json",slot]);
        if(generation==epoch.load())write(metrics,@"current.json");
        {std::lock_guard<std::mutex> guard(lock);if(generation==g.epoch){g.writerMilliseconds=std::max(g.writerMilliseconds,(CACurrentMediaTime()-begin)*1000);g.writerFailures+=failures;}}
        diagnosticJobs--;
    }});}
    if(save&&!persist(false))warning(@"The current DS battery save could not be written and verified. Keep the game open and save normally; the pre-link checkpoint remains untouched.",generation);
}
bool MDS_allowRestore(){std::lock_guard<std::mutex> guard(lock);return !g.room||(!g.radio&&!g.room->active());}
void MDS_gameUnloading(){
    bool flush=false;retro_netpacket_callback cb;
    bool snapshot=false;{std::lock_guard<std::mutex> guard(lock);snapshot=g.loaded&&bool(g.traces);}
    if(snapshot)MDS_afterFrame(0,true);
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
    NSTimer *_timer;uint64_t _generation;BOOL _prepared,_browsing;
    dispatch_queue_t _sendQueue;
}
+(instancetype)shared{static MDSNearby *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
-(instancetype)init{if((self=[super init])){_sendQueue=dispatch_queue_create("org.manicemu.ds.room",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];}return self;}
-(BOOL)candidate:(NSDictionary*)info{
    Nonce n;MAC mac,alias;
    if(![info isKindOfClass:NSDictionary.class]||![info[@"v"] isEqual:WireVersion]||![info[@"ready"] isEqual:@"1"]||![info[@"local"] isEqual:@"1"]||!readNonce(info[@"nonce"],n)||![info[@"code"] isKindOfClass:NSString.class]||![info[@"runtime"] isKindOfClass:NSString.class]||!readMAC(info[@"mac"],mac)||!readMAC(info[@"alias"],alias))return NO;
    NSData *a=[_meta[@"code"] dataUsingEncoding:NSASCIIStringEncoding],*b=[info[@"code"] dataUsingEncoding:NSASCIIStringEncoding];
    if(a.length!=4||b.length!=4||!compatible((const char*)a.bytes,(const char*)b.bytes)||[info[@"runtime"] isEqual:_runtime])return NO;
    return alias==mac;
}
-(BOOL)valid:(NSDictionary*)info{
    MAC local,remote;
    return [self candidate:info]&&readMAC(_meta[@"mac"],local)&&readMAC(info[@"mac"],remote)&&local!=remote;
}
-(MCNearbyServiceBrowser*)newBrowser{
    return [[MCNearbyServiceBrowser alloc]initWithPeer:_identity serviceType:Service];
}
-(MCNearbyServiceAdvertiser*)newAdvertiser{
    return [[MCNearbyServiceAdvertiser alloc]initWithPeer:_identity discoveryInfo:_meta serviceType:Service];
}
-(void)advertise{
    // Bonjour may cache an initial discoveryInfo for this MCPeerID. Never
    // publish the temporary ready=0 record while the core checkpoints.
    if(!_prepared||!_identity||![_meta[@"ready"] isEqual:@"1"]||![_meta[@"local"] isEqual:@"1"])return;
    [_advertiser stopAdvertisingPeer];_advertiser=[self newAdvertiser];_advertiser.delegate=self;[_advertiser startAdvertisingPeer];
}
-(void)startDiscovery{
    if(!_prepared)return;
    if(!_browser){_browser=[self newBrowser];_browser.delegate=self;}
    if(!_browsing){[_browser startBrowsingForPeers];_browsing=YES;}
    [self advertise];[self connectReadyPeers];
}
-(void)radio:(BOOL)on generation:(uint64_t)generation{
    if(!on){[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];_browsing=NO;return;}
    if(generation!=_generation){[self cleanup];_generation=generation;_runtime=NSUUID.UUID.UUIDString;_identity=[[MCPeerID alloc]initWithDisplayName:localPlayerName()];_peers=[NSMutableDictionary new];_attempts=[NSMutableDictionary new];_retryAt=[NSMutableDictionary new];
        std::lock_guard<std::mutex> guard(lock);_wirePeers=[NSMutableDictionary new];_early=[NSMutableDictionary new];}
    if(!_meta){char code[4];uint8_t rev;Nonce n;{std::lock_guard<std::mutex> guard(lock);std::memcpy(code,g.code,4);rev=g.revision;n=g.nonce;}
        _meta=@{@"v":WireVersion,@"code":[[NSString alloc]initWithBytes:code length:4 encoding:NSASCIIStringEncoding],@"rev":[NSString stringWithFormat:@"%u",rev],@"nonce":hexNonce(n),@"runtime":_runtime,@"ready":@"0",@"local":@"0"};}
    if(!_timer)_timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    if(!self.session){self.session=[[MCSession alloc]initWithPeer:_identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];self.session.delegate=self;}
    if(_prepared)[self startDiscovery];
}
-(void)prepared:(uint64_t)generation{
    if(generation!=_generation)return;_prepared=YES;NSMutableDictionary *m=[_meta mutableCopy];m[@"ready"]=@"1";
    {std::lock_guard<std::mutex> guard(lock);m[@"local"]=g.intent?@"1":@"0";m[@"mac"]=g.wirelessMAC;MAC native;if(!readMAC(g.wirelessMAC,native))return;
        if(!g.room){g.room=std::make_unique<Room>(g.nonce,g.code,g.revision,native);g.room->radio(g.radio);}
        NSMutableString *alias=[NSMutableString new];for(auto b:g.room->alias())[alias appendFormat:@"%02x",b];m[@"alias"]=alias;}
    _meta=m;bool radio;{std::lock_guard<std::mutex> guard(lock);radio=g.radio;}
    if(radio)[self startDiscovery];
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
        for(NSData *data in _early[peer]){
            if(data.length>=4&&!memcmp(data.bytes,"MDR1",4))g.room->receiveRadio(other,data.bytes,data.length);
            else {std::vector<Bytes> frames;if(unbatchWire(data.bytes,data.length,frames))for(const auto &frame:frames)g.room->receive(other,frame.data(),frame.size());}
        }
        [_early removeObjectForKey:peer];}
    packetsReady.notify_all();[self drain];
}
-(void)drain{
    MCSession *session=self.session;if(!session)return;uint64_t generation=epoch.load();
    {std::lock_guard<std::mutex> guard(lock);if(!g.room||g.sendScheduled)return;g.sendScheduled=true;}
    double queuedAt=CACurrentMediaTime();
    dispatch_async(_sendQueue,^{
      {std::lock_guard<std::mutex> guard(lock);if(generation==g.epoch)g.sendQueueDelayMax=std::max(g.sendQueueDelayMax,(CACurrentMediaTime()-queuedAt)*1000);}
      for(;;){NSMutableArray *out=[NSMutableArray new];
        {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;if(!g.room||session!=self.session){g.sendScheduled=false;return;}
            for(MCPeerID *peer in self->_wirePeers){Nonce n;if(!readNonce(self->_wirePeers[peer],n))continue;
                for(const auto &batch:batchWire(g.room->takeWire(n)))[out addObject:@[peer,[NSData dataWithBytes:batch.data() length:batch.size()],@YES]];
            }
            // Control fences remain reliable. Native RF honors the core's
            // unsequenced/unreliable request; no application RF ACK stream.
            for(MCPeerID *peer in self->_wirePeers){Nonce n;if(!readNonce(self->_wirePeers[peer],n))continue;
                for(const auto &fragment:g.room->takeRadioWire(n))[out addObject:@[peer,[NSData dataWithBytes:fragment.data() length:fragment.size()],@NO]];
            }
            if(!out.count){g.sendScheduled=false;return;}}
        for(NSArray *entry in out){NSError *error=nil;BOOL reliable=[entry[2] boolValue];double sendAt=CACurrentMediaTime();BOOL sent=[session sendData:entry[1] toPeers:@[entry[0]] withMode:reliable?MCSessionSendDataReliable:MCSessionSendDataUnreliable error:&error];
            {std::lock_guard<std::mutex> guard(lock);if(generation!=g.epoch)return;g.transportMessages++;if(!reliable){NSData *bytes=entry[1];Nonce peer;NativeDiagnostic trace;trace.event=101;
                trace.sourceSlot=readNonce(self->_wirePeers[entry[0]],peer)&&g.room?g.room->slot(peer):65535;trace.reason=sent?1:0;
                trace.length=uint32_t(std::min(bytes.length,NSUInteger(2048)));trace.payload=bytes.bytes;traceLocked(trace);}g.sendCallMax=std::max(g.sendCallMax,(CACurrentMediaTime()-sendAt)*1000);if(!sent&&!reliable)g.unreliableSendFailures++;}
            // Losing an RF datagram must not tear down reliable room control.
            // The game decides whether to retry or report communication failure.
            if(!sent&&reliable)dispatch_async(dispatch_get_main_queue(),^{if(generation==epoch.load()&&session==self.session){[self remove:entry[0]];[session cancelConnectPeer:entry[0]];}});}
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
    [self.session disconnect];self.session=nil;_meta=nil;_peers=nil;_attempts=nil;_retryAt=nil;_prepared=_browsing=NO;
    {std::lock_guard<std::mutex> guard(lock);_wirePeers=nil;_early=nil;}
    if(_notice.presentingViewController)[_notice dismissViewControllerAnimated:NO completion:nil];_notice=nil;
}
-(void)background:(NSNotification*)notification{
    (void)notification;for(MCPeerID *peer in self.session.connectedPeers)[self remove:peer];[self.session disconnect];
}
-(void)browser:(MCNearbyServiceBrowser*)browser foundPeer:(MCPeerID*)peer withDiscoveryInfo:(NSDictionary*)info{
    // Retain a ready remote candidate even if this phone is still preparing.
    // Local-MAC collision validation occurs when the local record is ready.
    dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser||![self candidate:info])return;self->_peers[peer]=info;[self connectReadyPeers];});
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
    bool radio=data.length>=4&&!memcmp(data.bytes,"MDR1",4);
    std::vector<Bytes> frames;if(!radio&&!unbatchWire(data.bytes,data.length,frames))return;
    if(radio&&data.length>RadioFragments::MaxMessage)return;
    {std::lock_guard<std::mutex> guard(lock);if(!g.room)return;Nonce n;
        if(readNonce(_wirePeers[peer],n)){
            if(radio){bool accepted=g.room->receiveRadio(n,data.bytes,data.length);
                NativeDiagnostic trace;trace.event=100;trace.sourceSlot=g.room->slot(n);trace.reason=accepted?1:0;
                trace.length=uint32_t(data.length);trace.payload=data.bytes;traceLocked(trace);}
            else for(const auto &frame:frames)g.room->receive(n,frame.data(),frame.size());
        }
        else if(_early.count<Room::MaxPeers||_early[peer]){if(!_early[peer])_early[peer]=[NSMutableArray new];if(_early[peer].count<16)[_early[peer] addObject:data];}}
    packetsReady.notify_all();[self drain];
}
-(void)session:(MCSession*)session didReceiveStream:(NSInputStream*)stream withName:(NSString*)name fromPeer:(MCPeerID*)peer{(void)session;(void)name;(void)peer;[stream close];}
-(void)session:(MCSession*)session didStartReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer withProgress:(NSProgress*)progress{(void)session;(void)name;(void)peer;[progress cancel];}
-(void)session:(MCSession*)session didFinishReceivingResourceWithName:(NSString*)name fromPeer:(MCPeerID*)peer atURL:(NSURL*)url withError:(NSError*)error{(void)session;(void)name;(void)peer;(void)url;(void)error;}
-(void)advertiser:(MCNearbyServiceAdvertiser*)advertiser didNotStartAdvertisingPeer:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(advertiser==self->_advertiser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on the devices." generation:self->_generation];});}
-(void)browser:(MCNearbyServiceBrowser*)browser didNotStartBrowsingForPeers:(NSError*)error{(void)error;dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser)[self warning:@"Nearby discovery could not start. Allow Manic Local Network access and use the same local network on the devices." generation:self->_generation];});}
@end
