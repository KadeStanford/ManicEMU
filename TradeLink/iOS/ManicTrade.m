// SPDX-License-Identifier: AGPL-3.0-or-later
// Integrates with the app's public Objective-C Libretro bridge. No home overlay.
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "TradeCore.h"
#include "FrontendSave.h"
#include <dlfcn.h>

static NSString *const TradeProtocol = @"g3-fc4afeb-mtr2";
static NSString *const Service = @"manic-trade";
static void resumeFrontend(void) {
    Class cls=NSClassFromString(@"LibretroCore");SEL shared=NSSelectorFromString(@"sharedInstance");
    SEL paused=NSSelectorFromString(@"isPaused"),resume=NSSelectorFromString(@"resume");
    if(![cls respondsToSelector:shared])return;
    id bridge=((id (*)(id,SEL))objc_msgSend)(cls,shared);
    if([bridge respondsToSelector:paused]&&[bridge respondsToSelector:resume]&&((BOOL (*)(id,SEL))objc_msgSend)(bridge,paused))
        ((void (*)(id,SEL))objc_msgSend)(bridge,resume);
}
static UIViewController *presenter(void) {
    UIViewController *vc=nil;
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes) if([s isKindOfClass:UIWindowScene.class])
        for(UIWindow *w in ((UIWindowScene *)s).windows) if(w.isKeyWindow)vc=w.rootViewController;
    if(!vc)vc=UIApplication.sharedApplication.delegate.window.rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    return vc;
}
static NSString *hex(NSData *data) { NSMutableString *s=[NSMutableString new];const uint8_t *p=data.bytes;for(NSUInteger i=0;i<data.length;i++)[s appendFormat:@"%02x",p[i]];return s; }
static NSData *unhex(NSString *s) {
    if(![s isKindOfClass:NSString.class]||s.length!=32)return nil;
    NSMutableData *d=[NSMutableData dataWithLength:16];uint8_t *p=d.mutableBytes;
    for(unsigned i=0;i<16;i++){unsigned n=0;NSString *v=[s substringWithRange:NSMakeRange(i*2,2)];
        if([v rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)return nil;
        if(![[NSScanner scannerWithString:v] scanHexInt:&n])return nil;p[i]=n;
    }return d;
}
static NSString *gameTitle(NSString *code) {
    NSDictionary *names=@{@"BPR":@"Pokémon FireRed",@"BPG":@"Pokémon LeafGreen",@"BPE":@"Pokémon Emerald",@"AXV":@"Pokémon Ruby",@"AXP":@"Pokémon Sapphire"};
    return code.length==4?names[[code substringToIndex:3]]:@"GBA game";
}
@interface ManicTrade : NSObject <MCSessionDelegate,MCNearbyServiceAdvertiserDelegate,MCNearbyServiceBrowserDelegate>
+ (instancetype)shared;
- (void)checkpoint:(NSData *)battery state:(NSData *)state path:(NSString *)path code:(NSString *)code;
- (void)ended:(NSString *)reason;
- (void)closed:(uint64_t)epoch;
- (void)halt:(NSString *)reason;
@end
@implementation ManicTrade {
    MCSession *_session;
    MCNearbyServiceAdvertiser *_advertiser;
    MCNearbyServiceBrowser *_browser;
    MCPeerID *_identity,*_partner;
    NSMutableDictionary<MCPeerID *,NSDictionary *> *_peers;
    NSDictionary *_meta,*_partnerMeta;
    NSData *_room;
    UIAlertController *_dialog;
    UIAlertController *_presentedDialog;
    BOOL _uiBusy;
    NSTimer *_timer;
    uint64_t _cursor;
    CFTimeInterval _heard,_lastResend;
    BOOL _ready,_peerReady,_ending,_fatal;
    enum MTPhase _lastPhase;
    NSString *_epoch;
    uint64_t _coreEpoch;
}
+ (instancetype)shared { static ManicTrade *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v; }
- (instancetype)init {
    if((self=[super init])){
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }return self;
}
- (void)control:(NSString *)command {
    if(!_partner||![_session.connectedPeers containsObject:_partner])return;
    NSMutableDictionary *obj=[_meta mutableCopy];obj[@"MT"]=command;
    NSData *d=[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    NSError *error;if(![_session sendData:d toPeers:@[_partner] withMode:MCSessionSendDataReliable error:&error]&&![command isEqual:@"PAUSE"])[self halt:@"The connection stopped. Your pre-trade backups are safe."];
}
- (BOOL)valid:(NSDictionary *)meta {
    if(![meta isKindOfClass:NSDictionary.class]||![meta[@"v"] isEqual:TradeProtocol]||!unhex(meta[@"room"]))return NO;
    NSString *code=meta[@"code"];
    if(![code isKindOfClass:NSString.class]||code.length!=4)return NO;
    NSData *a=[_meta[@"code"] dataUsingEncoding:NSASCIIStringEncoding],*b=[code dataUsingEncoding:NSASCIIStringEncoding];
    return a.length==4&&b.length==4&&MT_compatible(a.bytes,b.bytes)&&![meta[@"room"] isEqual:_meta[@"room"]];
}
- (void)checkpoint:(NSData *)battery state:(NSData *)state path:(NSString *)path code:(NSString *)code {
    [self cleanup];_epoch=NSUUID.UUID.UUIDString;NSString *epoch=_epoch;_coreEpoch=MT_epoch();
    _ending=NO;_fatal=NO;_ready=_peerReady=NO;_cursor=0;_lastPhase=MT_WAITING;
    uuid_t bytes;[NSUUID.UUID getUUIDBytes:bytes];_room=[NSData dataWithBytes:bytes length:16];
    _meta=@{@"v":TradeProtocol,@"room":hex(_room),@"code":code};
    _identity=[[MCPeerID alloc] initWithDisplayName:[NSString stringWithFormat:@"%@ · %@",UIDevice.currentDevice.model,[_epoch substringToIndex:4]]];
    // Copy only the current game's core-owned battery/checkpoint; no file scans.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[[base URLByAppendingPathComponent:@"ManicTradeBackups" isDirectory:YES] URLByAppendingPathComponent:epoch isDirectory:YES];
        NSError *error;BOOL ok=[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error];
        NSString *name=[[path lastPathComponent] stringByDeletingPathExtension];
        ok=ok&&[battery writeToURL:[dir URLByAppendingPathComponent:[name stringByAppendingString:@".sav"]] options:NSDataWritingAtomic error:&error];
        ok=ok&&[state writeToURL:[dir URLByAppendingPathComponent:@"pre-trade.gpspstate"] options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            if(![self->_epoch isEqual:epoch]||MT_phase()!=MT_WAITING)return;
            if(!ok){MT_cancel();[self notice:@"Trading stopped" message:@"The automatic backup could not be saved. No trade data was sent."];return;}
            [self discover];
        });
    });
}
- (void)discover {
    _peers=[NSMutableDictionary new];
    _session=[[MCSession alloc] initWithPeer:_identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];_session.delegate=self;
    _advertiser=[[MCNearbyServiceAdvertiser alloc] initWithPeer:_identity discoveryInfo:_meta serviceType:Service];_advertiser.delegate=self;
    _browser=[[MCNearbyServiceBrowser alloc] initWithPeer:_identity serviceType:Service];_browser.delegate=self;
    [_advertiser startAdvertisingPeer];[_browser startBrowsingForPeers];
    _timer=[NSTimer scheduledTimerWithTimeInterval:0.025 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self finder];
}
- (void)dismissDialog {
    _dialog=nil;[self publishDialog];
}
- (void)publishDialog {
    if(_uiBusy||_dialog==_presentedDialog)return;
    if(_presentedDialog.presentingViewController){
        _uiBusy=YES;
        [_presentedDialog dismissViewControllerAnimated:NO completion:^{self->_presentedDialog=nil;self->_uiBusy=NO;[self publishDialog];}];return;
    }
    _presentedDialog=nil;UIAlertController *dialog=_dialog;if(!dialog)return;
    UIViewController *vc=presenter();
    if(!vc){MT_cancel();[self cleanup];return;}
    dialog.popoverPresentationController.sourceView=vc.view;
    dialog.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(vc.view.bounds),CGRectGetMidY(vc.view.bounds),1,1);
    _presentedDialog=dialog;_uiBusy=YES;
    [vc presentViewController:dialog animated:YES completion:^{self->_uiBusy=NO;[self publishDialog];}];
}
- (void)show:(UIAlertController *)dialog {_dialog=dialog;[self publishDialog];}
- (void)finder {
    if(_partner||_ending||_fatal)return;
    NSString *epoch=_epoch;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby players" message:@"Your friend also needs to start a cable trade or battle in their game." preferredStyle:UIAlertControllerStyleActionSheet];
    for(MCPeerID *peer in _peers){NSDictionary *meta=_peers[peer];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ - %@",peer.displayName,gameTitle(meta[@"code"])] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            if(![self->_epoch isEqual:epoch])return;
            self->_partner=peer;self->_partnerMeta=meta;[self dismissDialog];
            NSData *context=[NSJSONSerialization dataWithJSONObject:self->_meta options:0 error:nil];
            [self->_browser invitePeer:peer toSession:self->_session withContext:context timeout:20];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){if(![self->_epoch isEqual:epoch])return;MT_cancel();[self cleanup];}]];
    [self show:a];
}
- (void)notice:(NSString *)title message:(NSString *)message {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self show:a];
}
- (void)halt:(NSString *)reason {
    if(_ending)return;
    if(MT_complete()||MT_phase()==MT_IDLE){[self cleanup];return;}
    // A locally closed game keeps playing. It cannot rejoin or restore an
    // already ended session, even if the final peer/ACK callbacks arrive late.
    if(MT_finishing())return;
    if(MT_phase()==MT_BROKEN)_fatal=YES;
    MT_suspend();_ready=_peerReady=NO;
    [_advertiser startAdvertisingPeer];[_browser startBrowsingForPeers];
    [self dismissDialog];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Link paused" message:reason preferredStyle:UIAlertControllerStyleAlert];
    NSString *epoch=_epoch;
    if(!_fatal)[a addAction:[UIAlertAction actionWithTitle:@"Reconnect" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        if(![self->_epoch isEqual:epoch]||MT_finishing())return;
        resumeFrontend();
        self->_ready=YES;self->_cursor=0;
        if([self->_session.connectedPeers containsObject:self->_partner]){MT_resume();[self tick:nil];}
        else {NSData *ctx=[NSJSONSerialization dataWithJSONObject:self->_meta options:0 error:nil];[self->_browser invitePeer:self->_partner toSession:self->_session withContext:ctx timeout:20];}
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restore before link" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if(![self->_epoch isEqual:epoch]||MT_finishing())return;
        MT_restore();resumeFrontend();[self cleanup];
    }]];[self show:a];
}
- (void)background:(NSNotification *)note { if(_partner&&!_ending)[self halt:@"Return to both games, then reconnect with the same player."]; }
- (void)tick:(NSTimer *)timer {
    if(_ending||!_partner||![_session.connectedPeers containsObject:_partner])return;
    CFTimeInterval now=CACurrentMediaTime();
    enum MTPhase phase=MT_phase();
    if(phase==MT_LINKED&&_lastPhase==MT_SUSPENDED){[self dismissDialog];[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];}
    _lastPhase=phase;
    if(phase==MT_LINKED||phase==MT_SUSPENDED||phase==MT_CLOSING){
        if(phase==MT_LINKED&&now-_heard>1.5){[self halt:@"The connection timed out. Both games are paused; backups are retained."];}
        if(now-_lastResend>0.75){_cursor=0;_lastResend=now;}
        for(unsigned i=0;i<64;i++){
            uint8_t bytes[MT_PACKET_SIZE];if(!MT_next_packet(_cursor,bytes))break;
            uint64_t seq=0;for(unsigned j=24;j<32;j++)seq=(seq<<8)|bytes[j];
            NSError *error;if(![_session sendData:[NSData dataWithBytes:bytes length:sizeof(bytes)] toPeers:@[_partner] withMode:MCSessionSendDataReliable error:&error]){[self halt:@"The connection stopped. Your pre-trade backups are safe."];return;}_cursor=seq;
        }
    }
    static unsigned count=0;if(++count%40==0)[self control:@"PING"];
}
- (void)ended:(NSString *)reason {
    if([reason isEqual:@"Pre-trade checkpoint restored"]){[self notice:reason message:@"Back out of the cable club. Your automatic battery backup is also kept in ManicTradeBackups."];return;}
    if(_ending&&MT_phase()!=MT_OFF)return;
    if(MT_phase()==MT_OFF||[reason isEqual:@"Link cancelled"]){[self cleanup];return;}
    if([reason isEqual:@"Link completed"]){
        [self dismissDialog];[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
        // Allow the final reliable ACK to leave MCSession before disconnecting.
        NSString *epoch=_epoch;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{if([self->_epoch isEqual:epoch])[self cleanup];});
    }
}
- (void)closed:(uint64_t)epoch {if(_coreEpoch<epoch)[self cleanup];}
- (void)cleanup {
    _ending=YES;[_timer invalidate];_timer=nil;[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
    _session.delegate=nil;_advertiser.delegate=nil;_browser.delegate=nil;[_session disconnect];
    _advertiser=nil;_browser=nil;_session=nil;_partner=nil;_partnerMeta=nil;_epoch=nil;[self dismissDialog];
}
- (void)session:(MCSession *)session peer:(MCPeerID *)peer didChangeState:(MCSessionState)state {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->_ending||session!=self->_session||![peer isEqual:self->_partner])return;
        if(state==MCSessionStateConnected){self->_heard=CACurrentMediaTime();if(MT_phase()==MT_WAITING)self->_ready=YES;[self control:@"HELLO"];if(self->_ready&&MT_phase()==MT_SUSPENDED)MT_resume();}
        else if(state==MCSessionStateNotConnected){
            if(MT_phase()==MT_WAITING){self->_partner=nil;self->_partnerMeta=nil;[self finder];}
            else if(MT_peer_disconnected()){resumeFrontend();}
            else [self halt:@"The player disconnected. Keep both apps alive and reconnect to resume, or restore the pre-link checkpoint."];
        }
    });
}
- (void)session:(MCSession *)session didReceiveData:(NSData *)data fromPeer:(MCPeerID *)peer {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->_ending||session!=self->_session||![peer isEqual:self->_partner])return;
        self->_heard=CACurrentMediaTime();
        if(data.length==MT_PACKET_SIZE&&!memcmp(data.bytes,"MTR1",4)){
            uint8_t ack[MT_PACKET_SIZE];int result=MT_receive_packet(data.bytes,data.length,ack);
            if(result<0){self->_fatal=YES;[self halt:@"An incompatible or stale packet was rejected. Restore the pre-trade checkpoint."];return;}
            if(result<2){NSError *error;[self->_session sendData:[NSData dataWithBytes:ack length:sizeof(ack)] toPeers:@[peer] withMode:MCSessionSendDataReliable error:&error];}
            if(MT_phase()==MT_SUSPENDED&&self->_lastPhase!=MT_SUSPENDED){self->_lastPhase=MT_SUSPENDED;[self halt:@"The other game paused. Return to both games and reconnect."];}
            [self tick:nil];return;
        }
        if(data.length>1024){self->_fatal=YES;[self halt:@"Invalid trade message. Restore the pre-trade checkpoint."];return;}
        NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![self valid:meta]||![meta[@"room"] isEqual:self->_partnerMeta[@"room"]]){self->_fatal=YES;[self halt:@"Player/session identity changed. Restore the pre-trade checkpoint."];return;}
        NSString *command=meta[@"MT"];
        if([command isEqual:@"HELLO"]){
            self->_peerReady=YES;if(!self->_ready)return;
            NSData *other=unhex(meta[@"room"]);BOOL first=MT_phase()==MT_WAITING;
            if(!first){if(MT_phase()==MT_SUSPENDED)MT_resume();return;}
            if(first){BOOL parent=memcmp(self->_room.bytes,other.bytes,16)<0;NSData *sessionID=parent?self->_room:other;MT_connect(parent?0:1,sessionID.bytes);}
            resumeFrontend();
            [self dismissDialog];[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
            self->_cursor=0;self->_lastResend=CACurrentMediaTime();
            if(first)[self control:@"HELLO"];
        }
        else if(![command isEqual:@"PING"]){self->_fatal=YES;[self halt:@"Unknown trade message. Restore the pre-trade checkpoint."];}
    });
}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didReceiveInvitationFromPeer:(MCPeerID *)peer withContext:(NSData *)context invitationHandler:(void (^)(BOOL,MCSession *))handler {
    dispatch_async(dispatch_get_main_queue(),^{
        NSDictionary *meta=context.length&&context.length<=1024?[NSJSONSerialization JSONObjectWithData:context options:0 error:nil]:nil;
        if(advertiser!=self->_advertiser||self->_ending||self->_fatal||MT_finishing()||![self valid:meta]||(self->_partner&&![peer isEqual:self->_partner])){handler(NO,nil);return;}
        if(self->_partner){handler(YES,self->_session);return;} // Same approved peer only.
        self->_partner=peer;self->_partnerMeta=meta;
        NSString *epoch=self->_epoch;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby player" message:[NSString stringWithFormat:@"Link with %@ playing %@?",peer.displayName,gameTitle(meta[@"code"])] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Decline" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){handler(NO,nil);if(![self->_epoch isEqual:epoch])return;self->_partner=nil;self->_partnerMeta=nil;[self finder];}]];
        [a addAction:[UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(![self->_epoch isEqual:epoch]){handler(NO,nil);return;}[self dismissDialog];handler(YES,self->_session);}]];[self show:a];
    });
}
- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peer withDiscoveryInfo:(NSDictionary *)info {
    dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser&&[self valid:info]){self->_peers[peer]=info;[self finder];}});
}
- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peer {
    dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser)return;[self->_peers removeObjectForKey:peer];[self finder];});
}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error {dispatch_async(dispatch_get_main_queue(),^{if(advertiser!=self->_advertiser)return;MT_cancel();[self cleanup];[self notice:@"Nearby trading unavailable" message:@"Allow Local Network access for Manic in iOS Settings, then enter the cable club again."];});}
- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{if(browser!=self->_browser)return;[self advertiser:self->_advertiser didNotStartAdvertisingPeer:error];}); }
- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream withName:(NSString *)name fromPeer:(MCPeerID *)peer {[stream close];}
- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer withProgress:(NSProgress *)progress {[progress cancel];}
- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer atURL:(NSURL *)url withError:(NSError *)error {}
@end

static void snapshot(const uint8_t *battery,const uint8_t *state,size_t size) {
    NSData *b=[NSData dataWithBytes:battery length:MT_SAVE_SIZE],*s=[NSData dataWithBytes:state length:size];
    NSString *path=[NSString stringWithUTF8String:MT_path()];NSString *code=[[NSString alloc] initWithBytes:MT_code() length:4 encoding:NSASCIIStringEncoding];
    uint64_t epoch=MT_epoch();dispatch_async(dispatch_get_main_queue(),^{if(epoch==MT_epoch())[[ManicTrade shared] checkpoint:b state:s path:path code:code];});
}
static void stopped(const char *reason) {NSString *s=[NSString stringWithUTF8String:reason];uint64_t epoch=MT_epoch();dispatch_async(dispatch_get_main_queue(),^{
    if([s isEqual:@"Game closed"])[[ManicTrade shared] closed:epoch];
    else if(epoch==MT_epoch())[[ManicTrade shared] ended:s];
});}
static void failure(const char *reason) {NSString *s=[NSString stringWithUTF8String:reason];uint64_t epoch=MT_epoch();dispatch_async(dispatch_get_main_queue(),^{
    if(epoch!=MT_epoch())return;
    if(MT_local_closed()){[[ManicTrade shared] cleanup];[[ManicTrade shared] notice:@"Save needs attention" message:s];return;}
    if(MT_phase()==MT_CANCELLED){[[ManicTrade shared] cleanup];[[ManicTrade shared] notice:@"Trading stopped" message:s];}
    else [[ManicTrade shared] halt:s];
});}
static int persist(const uint8_t *battery,const uint8_t *state,size_t size) {
    @autoreleasepool {
        // Called from retro_run on the existing core thread. Obtain the actual
        // active battery path from the frontend, not from a guessed ROM name.
        struct MTSaveList *(*files)(void)=(void *)dlsym(RTLD_DEFAULT,"savefile_ptr_get");
        struct MTSaveList *list=files?files():NULL;NSString *path=nil;
        if(list&&list->elems&&list->size<=16&&list->size<=list->cap)
            for(size_t i=0;i<list->size;i++)if(list->elems[i].attr.i==0&&list->elems[i].data){
                if(path)return 0;path=[NSString stringWithUTF8String:list->elems[i].data];
            }
        NSData *data=[NSData dataWithBytes:battery length:MT_SAVE_SIZE];
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[[documents URLByAppendingPathComponent:@"ManicTradeBackups" isDirectory:YES] URLByAppendingPathComponent:[@"completed-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error;BOOL backup=[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error];
        backup=backup&&[data writeToURL:[dir URLByAppendingPathComponent:@"current.sav"] options:NSDataWritingAtomic error:&error];
        backup=backup&&[[NSData dataWithBytes:state length:size] writeToURL:[dir URLByAppendingPathComponent:@"post-link.gpspstate"] options:NSDataWritingAtomic error:&error];
        // Preserve a post-link copy even if the frontend ABI/path is unavailable.
        if(!path.isAbsolutePath||![path.pathExtension.lowercaseString isEqual:@"sav"])return 0;
        BOOL saved=[data writeToFile:path options:NSDataWritingAtomic error:&error];
        saved=saved&&[[NSData dataWithContentsOfFile:path] isEqualToData:data];
        return backup&&saved;
    }
}
static void (*originalPause)(id,SEL);
static void tradePause(id bridge,SEL selector) {
    BOOL linked=MT_phase()==MT_LINKED;
    if(linked)MT_suspend(); // Suspend before the frontend stops issuing frames.
    originalPause(bridge,selector);
    uint64_t epoch=MT_epoch();if(linked)dispatch_async(dispatch_get_main_queue(),^{if(epoch==MT_epoch())[[ManicTrade shared] halt:@"The game paused. Return to both games, then reconnect to continue."];});
}
__attribute__((constructor)) static void install_trade(void) {
    if(![NSBundle.mainBundle.infoDictionary[@"MGLInjectTrade"] boolValue])return;
    Class cls=NSClassFromString(@"LibretroCore");SEL sel=NSSelectorFromString(@"loadGame:corePath:completion:");
    Method method=cls?class_getInstanceMethod(cls,sel):NULL;
    if(!method||method_getNumberOfArguments(method)!=5)return;
    Method pause=class_getInstanceMethod(cls,NSSelectorFromString(@"pause"));
    if(pause&&method_getNumberOfArguments(pause)==2){originalPause=(void *)method_getImplementation(pause);method_setImplementation(pause,(IMP)tradePause);}
    // Use Manic's existing gpSP selection. Changing only the loaded dylib would
    // mislabel new save states as mGBA in the frontend's persisted metadata.
    // Core selection happens once at launch; pairing never swaps/restarts cores.
    MT_install(snapshot,stopped,failure);MT_set_persist(persist);MT_enable(1);
}
