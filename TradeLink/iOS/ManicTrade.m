// SPDX-License-Identifier: AGPL-3.0-or-later
// Integrates with the app's public Objective-C Libretro bridge. No home overlay.
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "TradeCore.h"

static NSString *const TradeProtocol = @"g3-fc4afeb-mtr1";
static NSString *const Service = @"manic-trade";
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
    NSTimer *_timer;
    uint64_t _cursor;
    CFTimeInterval _heard,_lastResend;
    BOOL _ready,_peerReady,_localDone,_remoteDone,_sentDone,_ending,_fatal;
    NSString *_epoch;
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
    [self cleanup];_epoch=NSUUID.UUID.UUIDString;NSString *epoch=_epoch;
    _ending=NO;_fatal=NO;_localDone=_remoteDone=_sentDone=NO;_ready=_peerReady=NO;_cursor=0;
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
    if(_dialog.presentingViewController)[_dialog dismissViewControllerAnimated:NO completion:nil];_dialog=nil;
}
- (void)show:(UIAlertController *)dialog {
    [self dismissDialog];_dialog=dialog;UIViewController *vc=presenter();
    if(!vc){MT_cancel();[self cleanup];return;}
    dialog.popoverPresentationController.sourceView=vc.view;
    dialog.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(vc.view.bounds),CGRectGetMidY(vc.view.bounds),1,1);
    [vc presentViewController:dialog animated:YES completion:nil];
}
- (void)finder {
    if(_partner||_ending||_fatal)return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby players" message:@"Your friend also needs to start a cable trade in their game." preferredStyle:UIAlertControllerStyleActionSheet];
    for(MCPeerID *peer in _peers){NSDictionary *meta=_peers[peer];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ — %@",peer.displayName,gameTitle(meta[@"code"])] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            self->_partner=peer;self->_partnerMeta=meta;[self dismissDialog];
            NSData *context=[NSJSONSerialization dataWithJSONObject:self->_meta options:0 error:nil];
            [self->_browser invitePeer:peer toSession:self->_session withContext:context timeout:20];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){MT_cancel();[self cleanup];}]];
    [self show:a];
}
- (void)notice:(NSString *)title message:(NSString *)message {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self show:a];
}
- (void)halt:(NSString *)reason {
    if(_ending)return;
    BOOL notify=_ready;MT_suspend();_ready=_peerReady=NO;if(notify)[self control:@"PAUSE"];
    [_advertiser startAdvertisingPeer];[_browser startBrowsingForPeers];
    [self dismissDialog];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Trade paused" message:reason preferredStyle:UIAlertControllerStyleAlert];
    if(!_fatal)[a addAction:[UIAlertAction actionWithTitle:@"Reconnect" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        self->_ready=YES;self->_cursor=0;
        if([self->_session.connectedPeers containsObject:self->_partner])[self control:@"HELLO"];
        else {NSData *ctx=[NSJSONSerialization dataWithJSONObject:self->_meta options:0 error:nil];[self->_browser invitePeer:self->_partner toSession:self->_session withContext:ctx timeout:20];}
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restore before trade" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        MT_restore();[self cleanup];
    }]];[self show:a];
}
- (void)background:(NSNotification *)note { if(_partner&&!_ending)[self halt:@"Return to both games, then reconnect with the same player."]; }
- (void)tick:(NSTimer *)timer {
    if(_ending||!_partner||![_session.connectedPeers containsObject:_partner])return;
    CFTimeInterval now=CACurrentMediaTime();
    if(MT_phase()==MT_LINKED){
        if(now-_heard>5){[self halt:@"The connection timed out. Both games are paused; backups are retained."];return;}
        if(now-_lastResend>0.75){_cursor=0;_lastResend=now;}
        for(unsigned i=0;i<64;i++){
            uint8_t bytes[MT_PACKET_SIZE];if(!MT_next_packet(_cursor,bytes))break;
            uint64_t seq=0;for(unsigned j=24;j<32;j++)seq=(seq<<8)|bytes[j];
            NSError *error;if(![_session sendData:[NSData dataWithBytes:bytes length:sizeof(bytes)] toPeers:@[_partner] withMode:MCSessionSendDataReliable error:&error]){[self halt:@"The connection stopped. Your pre-trade backups are safe."];return;}_cursor=seq;
        }
    }
    if(_localDone&&!MT_pending()&&!_sentDone){_sentDone=YES;[self control:@"DONE"];}
    if(_localDone&&_remoteDone&&MT_complete()){[self cleanup];return;}
    static unsigned count=0;if(++count%40==0)[self control:@"PING"];
}
- (void)ended:(NSString *)reason {
    if([reason isEqual:@"Pre-trade checkpoint restored"]){[self notice:reason message:@"Back out of the cable club. Your automatic battery backup is also kept in ManicTradeBackups."];return;}
    if(MT_phase()==MT_OFF){[self cleanup];return;}
    _localDone=YES;[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
    if(!_partner){[self cleanup];return;}[self tick:nil];
}
- (void)cleanup {
    _ending=YES;[_timer invalidate];_timer=nil;[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
    _session.delegate=nil;_advertiser.delegate=nil;_browser.delegate=nil;[_session disconnect];
    _advertiser=nil;_browser=nil;_session=nil;_partner=nil;_partnerMeta=nil;_epoch=nil;[self dismissDialog];
}
- (void)session:(MCSession *)session peer:(MCPeerID *)peer didChangeState:(MCSessionState)state {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->_ending||session!=self->_session||![peer isEqual:self->_partner])return;
        if(state==MCSessionStateConnected){self->_heard=CACurrentMediaTime();self->_ready=YES;[self control:@"HELLO"];}
        else if(state==MCSessionStateNotConnected){
            if(MT_phase()==MT_WAITING){self->_partner=nil;self->_partnerMeta=nil;[self finder];}
            else [self halt:@"The player disconnected. Keep both apps alive and reconnect to resume, or restore the pre-trade checkpoint."];
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
            if(result<2){NSError *error;[self->_session sendData:[NSData dataWithBytes:ack length:sizeof(ack)] toPeers:@[peer] withMode:MCSessionSendDataReliable error:&error];}return;
        }
        if(data.length>1024){self->_fatal=YES;[self halt:@"Invalid trade message. Restore the pre-trade checkpoint."];return;}
        NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![self valid:meta]||![meta[@"room"] isEqual:self->_partnerMeta[@"room"]]){self->_fatal=YES;[self halt:@"Player/session identity changed. Restore the pre-trade checkpoint."];return;}
        NSString *command=meta[@"MT"];
        if([command isEqual:@"HELLO"]){
            self->_peerReady=YES;if(!self->_ready)return;
            NSData *other=unhex(meta[@"room"]);BOOL first=MT_phase()==MT_WAITING,resuming=MT_phase()==MT_SUSPENDED;
            if(first){BOOL parent=memcmp(self->_room.bytes,other.bytes,16)<0;NSData *sessionID=parent?self->_room:other;MT_connect(parent?0:1,sessionID.bytes);}
            else if(MT_phase()==MT_SUSPENDED)MT_resume();
            [self dismissDialog];[_advertiser stopAdvertisingPeer];[_browser stopBrowsingForPeers];
            self->_cursor=0;self->_lastResend=CACurrentMediaTime();
            if(first||resuming)[self control:@"HELLO"];
        }else if([command isEqual:@"PAUSE"]){MT_suspend();self->_ready=self->_peerReady=NO;[self halt:@"The other game paused. Return to both games and reconnect."];}
        else if([command isEqual:@"DONE"]){self->_remoteDone=YES;[self tick:nil];}
        else if(![command isEqual:@"PING"]){self->_fatal=YES;[self halt:@"Unknown trade message. Restore the pre-trade checkpoint."];}
    });
}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didReceiveInvitationFromPeer:(MCPeerID *)peer withContext:(NSData *)context invitationHandler:(void (^)(BOOL,MCSession *))handler {
    dispatch_async(dispatch_get_main_queue(),^{
        NSDictionary *meta=context.length<=1024?[NSJSONSerialization JSONObjectWithData:context options:0 error:nil]:nil;
        if(self->_ending||self->_fatal||![self valid:meta]||(self->_partner&&![peer isEqual:self->_partner])){handler(NO,nil);return;}
        if(self->_partner){handler(YES,self->_session);return;} // Same approved peer only.
        self->_partner=peer;self->_partnerMeta=meta;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Nearby trade" message:[NSString stringWithFormat:@"Trade with %@ playing %@?",peer.displayName,gameTitle(meta[@"code"])] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Decline" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){self->_partner=nil;self->_partnerMeta=nil;handler(NO,nil);[self finder];}]];
        [a addAction:[UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self dismissDialog];handler(YES,self->_session);}]];[self show:a];
    });
}
- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peer withDiscoveryInfo:(NSDictionary *)info {
    dispatch_async(dispatch_get_main_queue(),^{if(browser==self->_browser&&[self valid:info]){self->_peers[peer]=info;[self finder];}});
}
- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peer {
    dispatch_async(dispatch_get_main_queue(),^{[self->_peers removeObjectForKey:peer];[self finder];});
}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error {dispatch_async(dispatch_get_main_queue(),^{MT_cancel();[self cleanup];[self notice:@"Nearby trading unavailable" message:@"Allow Local Network access for Manic in iOS Settings, then enter the cable club again."];});}
- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error { [self advertiser:_advertiser didNotStartAdvertisingPeer:error]; }
- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream withName:(NSString *)name fromPeer:(MCPeerID *)peer {[stream close];}
- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer withProgress:(NSProgress *)progress {[progress cancel];}
- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer atURL:(NSURL *)url withError:(NSError *)error {}
@end

static void snapshot(const uint8_t *battery,const uint8_t *state,size_t size) {
    NSData *b=[NSData dataWithBytes:battery length:MT_SAVE_SIZE],*s=[NSData dataWithBytes:state length:size];
    NSString *path=[NSString stringWithUTF8String:MT_path()];NSString *code=[[NSString alloc] initWithBytes:MT_code() length:4 encoding:NSASCIIStringEncoding];
    dispatch_async(dispatch_get_main_queue(),^{[[ManicTrade shared] checkpoint:b state:s path:path code:code];});
}
static void stopped(const char *reason) {NSString *s=[NSString stringWithUTF8String:reason];dispatch_async(dispatch_get_main_queue(),^{[[ManicTrade shared] ended:s];});}
static void failure(const char *reason) {NSString *s=[NSString stringWithUTF8String:reason];dispatch_async(dispatch_get_main_queue(),^{
    if(MT_phase()==MT_CANCELLED){[[ManicTrade shared] cleanup];[[ManicTrade shared] notice:@"Trading stopped" message:s];}
    else [[ManicTrade shared] halt:s];
});}
__attribute__((constructor)) static void install_trade(void) {
    if(![NSBundle.mainBundle.infoDictionary[@"MGLInjectTrade"] boolValue])return;
    Class cls=NSClassFromString(@"LibretroCore");SEL sel=NSSelectorFromString(@"loadGame:corePath:completion:");
    Method method=cls?class_getInstanceMethod(cls,sel):NULL;
    if(!method||method_getNumberOfArguments(method)!=5)return;
    // Use Manic's existing gpSP selection. Changing only the loaded dylib would
    // mislabel new save states as mGBA in the frontend's persisted metadata.
    // Core selection happens once at launch; pairing never swaps/restarts cores.
    MT_install(snapshot,stopped,failure);MT_enable(1);
}
