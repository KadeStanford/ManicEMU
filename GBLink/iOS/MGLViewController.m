// SPDX-License-Identifier: AGPL-3.0-or-later
// Standalone, public-API iOS frontend; it does not hook Manic's binary core.
#import <UIKit/UIKit.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#include "MGLCore.h"
#include "dmg_boot.h"

@interface MGLViewController : UIViewController
    <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
     MCNearbyServiceBrowserDelegate, UIDocumentPickerDelegate>
@property(nonatomic) NSURL *romURL;
@property(nonatomic) NSURL *saveURL;
@end

@implementation MGLViewController {
    dispatch_queue_t _work;
    MGLPair *_pair;
    MCSession *_session;
    MCNearbyServiceAdvertiser *_advertiser;
    MCNearbyServiceBrowser *_browser;
    MCPeerID *_identity, *_partner;
    NSMutableArray<MCPeerID *> *_found;
    NSData *_rom, *_originalSave, *_guestOriginal, *_hash, *_latestSave;
    BOOL _host, _started, _connected, _fatal, _outstanding, _exportRequested;
    BOOL _pickingSave;
    uint8_t _keys;
    uint64_t _sequence;
    CFTimeInterval _lastReceive, _nextFrame;
    NSString *_code;
    UIImageView *_screen;
    UILabel *_status;
    UITextField *_codeField;
    UIStackView *_stack, *_hosts;
    dispatch_source_t _watchdog;
    id _backgroundObserver;
}
- (void)loadView {
    _work = dispatch_queue_create("org.manicemu.gblink", DISPATCH_QUEUE_SERIAL);
    _found = [NSMutableArray new];
    self.view = [UIView new]; self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    _stack = [UIStackView new]; _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10; _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [_stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [_stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    UILabel *title = [UILabel new]; title.text = @"Game Boy Link (experimental)";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; [_stack addArrangedSubview:title];
    UILabel *help = [UILabel new]; help.numberOfLines = 0;
    help.text = @"Both phones need the same legally obtained original GB ROM. Only MBC3 / 32 KB battery saves without RTC are supported (Red/Blue). Exit regular gameplay first. Connecting shares your battery save with the host over an encrypted local connection. Original saves are never changed. This first version has no audio.";
    help.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; [_stack addArrangedSubview:help];
    [self addButton:@"Select GB ROM" action:@selector(pickROM) stack:_stack];
    [self addButton:@"Select battery save (.sav/.srm), or start fresh" action:@selector(pickSave) stack:_stack];
    _codeField = [UITextField new]; _codeField.borderStyle = UITextBorderStyleRoundedRect;
    _codeField.placeholder = @"Friend's 6-digit code (for Join)";
    _codeField.keyboardType = UIKeyboardTypeNumberPad; [_stack addArrangedSubview:_codeField];
    UIStackView *row = [self row];
    [self addButton:@"Host" action:@selector(host) stack:row];
    [self addButton:@"Find / Reconnect" action:@selector(join) stack:row];
    _hosts = [self row];
    _status = [UILabel new]; _status.numberOfLines = 0;
    _status.text = self.romURL ? @"Ready to read this game's ROM and battery save." : @"Select your own ROM and battery save.";
    [_stack addArrangedSubview:_status];
    _screen = [UIImageView new]; _screen.backgroundColor = UIColor.blackColor;
    _screen.contentMode = UIViewContentModeScaleAspectFit;
    _screen.layer.magnificationFilter = kCAFilterNearest;
    [_screen.heightAnchor constraintEqualToConstant:240].active = YES; [_stack addArrangedSubview:_screen];
    NSArray *labels = @[@"Up", @"Left", @"Down", @"Right", @"B", @"A", @"Select", @"Start"];
    const uint8_t masks[] = {4, 2, 8, 1, 32, 16, 64, 128};
    for (unsigned i = 0; i < labels.count; i++) {
        if (i % 4 == 0) row = [self row];
        UIButton *button = [self addButton:labels[i] action:nil stack:row]; button.tag = masks[i];
        [button addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    }
    [self addButton:@"Export my new battery save" action:@selector(exportSave) stack:_stack];
    [self addButton:@"Close session" action:@selector(close) stack:_stack];
    __weak MGLViewController *weakSelf = self;
    _backgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            MGLViewController *s = weakSelf; if (!s) return;
            dispatch_async(s->_work, ^{ [s pause:@"Paused in background. Return and reconnect to the same host."]; });
        }];
}
- (UIStackView *)row {
    UIStackView *row = [UIStackView new]; row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually; row.spacing = 8;
    [_stack addArrangedSubview:row]; return row;
}
- (UIButton *)addButton:(NSString *)title action:(SEL)action stack:(UIStackView *)stack {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.numberOfLines = 2; b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    b.layer.cornerRadius = 8; [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:b]; return b;
}
- (void)status:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_status.text = text; });
}
- (void)pickROM { [self pick:NO]; }
- (void)pickSave { [self pick:YES]; }
- (void)pick:(BOOL)save {
    if (_started) { [self status:@"Close this session before changing files."]; return; }
    _pickingSave = save;
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    if (_pickingSave) self.saveURL = urls.firstObject; else self.romURL = urls.firstObject;
    _status.text = [NSString stringWithFormat:@"ROM: %@\nSave: %@", self.romURL.lastPathComponent ?: @"select ROM", self.saveURL.lastPathComponent ?: @"fresh game"];
}
- (NSData *)readURL:(NSURL *)url error:(NSError **)error {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (scoped) [url stopAccessingSecurityScopedResource]; return data;
}
- (BOOL)prepare:(BOOL)host {
    if (_started) return NO;
    NSError *error; NSData *rom = self.romURL ? [self readURL:self.romURL error:&error] : nil;
    if (!mgl_validate_rom(rom.bytes, rom.length)) {
        [self status:@"Select an original GB MBC3 ROM with a valid header and 32 KB battery RAM (Red/Blue). GBA games are unsupported."]; return NO;
    }
    NSData *save = self.saveURL ? [self readURL:self.saveURL error:&error] : nil;
    if (self.saveURL && save.length != MGL_SAVE_SIZE) {
        [self status:@"Battery save must be exactly 32 KB. Save states and wrapped/RTC saves cannot be imported."]; return NO;
    }
    if (!save) { NSMutableData *empty = [NSMutableData dataWithLength:MGL_SAVE_SIZE]; memset(empty.mutableBytes, 0xff, empty.length); save = empty; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(rom.bytes, (CC_LONG)rom.length, digest);
    NSString *code = host ? [NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)] : _codeField.text;
    if (code.length != 6 || [code rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
        [self status:@"Enter the host's six-digit code."]; return NO;
    }
    _started = YES;
    _rom = rom; _originalSave = save; _hash = [NSData dataWithBytes:digest length:sizeof(digest)];
    _code = [code copy]; _host = host;
    dispatch_async(_work, ^{
        self->_identity = [[MCPeerID alloc] initWithDisplayName:[@"GB-" stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]]];
        self->_session = [[MCSession alloc] initWithPeer:self->_identity securityIdentity:nil encryptionPreference:MCEncryptionRequired];
        self->_session.delegate = self;
        if (host) {
            self->_advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:self->_identity discoveryInfo:@{@"version": @"1"} serviceType:@"manic-gblink"];
            self->_advertiser.delegate = self; [self->_advertiser startAdvertisingPeer];
            [self status:[NSString stringWithFormat:@"Host %@ — code %@. Keep this screen open.", self->_identity.displayName, self->_code]];
        } else {
            self->_browser = [[MCNearbyServiceBrowser alloc] initWithPeer:self->_identity serviceType:@"manic-gblink"];
            self->_browser.delegate = self; [self->_browser startBrowsingForPeers];
            [self status:@"Select your friend's host below. Both phones must allow Local Network access."];
        }
        self->_watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_work);
        dispatch_source_set_timer(self->_watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak MGLViewController *weakSelf = self;
        dispatch_source_set_event_handler(self->_watchdog, ^{
            MGLViewController *s = weakSelf; if (s && s->_connected && CACurrentMediaTime() - s->_lastReceive > 10)
                [s pause:@"Connection timed out. Games are frozen; reconnect to the same peer."];
        });
        dispatch_resume(self->_watchdog);
    }); return YES;
}
- (void)host { [self.view endEditing:YES]; [self prepare:YES]; }
- (void)join {
    [self.view endEditing:YES];
    if (!_started) { [self prepare:NO]; return; }
    dispatch_async(_work, ^{
        if (!self->_host && !self->_fatal) {
            [self->_browser stopBrowsingForPeers]; [self->_browser startBrowsingForPeers];
            [self status:@"Select the same host to resume. Do not restart either app."];
        }
    });
}
- (void)connect:(UIButton *)button {
    MCPeerID *peer = button.tag >= 0 && (NSUInteger)button.tag < _found.count ? _found[button.tag] : nil;
    if (!peer) return;
    dispatch_async(_work, ^{
        if (self->_connected || self->_fatal) return;
        if (self->_partner && ![peer isEqual:self->_partner]) { [self status:@"Resume requires the same host. Close to start a new session."]; return; }
        self->_partner = peer;
        [self->_browser invitePeer:peer toSession:self->_session withContext:[self->_code dataUsingEncoding:NSUTF8StringEncoding] timeout:15];
    });
}
- (void)keyDown:(UIButton *)button { uint8_t mask = button.tag; dispatch_async(_work, ^{ self->_keys |= mask; }); }
- (void)keyUp:(UIButton *)button { uint8_t mask = button.tag; dispatch_async(_work, ^{ self->_keys &= ~mask; }); }
- (void)pause:(NSString *)reason {
    _connected = NO; _outstanding = NO; _keys = 0;
    mgl_set_connected(_pair, 0);
    [_session disconnect]; [self status:reason]; // Preserve pair, sequence, original files.
}
- (void)fail:(NSString *)reason { _fatal = YES; [self pause:reason]; }
- (BOOL)send:(uint8_t)type sequence:(uint64_t)sequence payload:(NSData *)payload {
    if (!_partner || !_session) return NO;
    NSMutableData *out = [NSMutableData dataWithLength:16 + payload.length];
    if (!mgl_encode(out.mutableBytes, out.length, type, sequence, payload.bytes, payload.length)) return NO;
    NSError *error;
    if (![_session sendData:out toPeers:@[_partner] withMode:MCSessionSendDataReliable error:&error]) {
        [self pause:@"Send failed. Games are frozen; reconnect to the same peer."]; return NO;
    } return YES;
}
- (void)requestFrame {
    if (!_connected || _host || _outstanding || _fatal) return;
    if (_exportRequested) { _outstanding = YES; [self send:MGL_EXPORT sequence:_sequence payload:nil]; return; }
    _outstanding = YES;
    [self send:MGL_INPUT sequence:_sequence payload:[NSData dataWithBytes:&_keys length:1]];
}
- (NSData *)battery:(unsigned)player {
    NSMutableData *data = [NSMutableData dataWithLength:MGL_SAVE_SIZE];
    return mgl_battery(_pair, player, data.mutableBytes) ? data : nil;
}
- (void)display:(NSData *)rgba {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(MGL_WIDTH, MGL_HEIGHT, 8, 32, MGL_WIDTH * 4, colors,
            kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, NO, kCGRenderingIntentDefault);
        self->_screen.image = [UIImage imageWithCGImage:image];
        CGImageRelease(image); CGColorSpaceRelease(colors); CGDataProviderRelease(provider);
    });
}
- (void)hostFrame:(uint8_t)keys {
    if (!mgl_advance(_pair, _sequence, _keys, keys)) { [self fail:@"Core stopped advancing. Close this session; original saves are safe."]; return; }
    _sequence++;
    [self display:[NSData dataWithBytes:mgl_pixels(_pair, 0) length:MGL_PIXELS * 4]];
    NSMutableData *wire = [NSMutableData dataWithLength:MGL_PIXELS * 2];
    const uint32_t *pixels = mgl_pixels(_pair, 1); uint8_t *bytes = wire.mutableBytes;
    for (unsigned i = 0; i < MGL_PIXELS; i++) {
        uint32_t c = pixels[i]; uint16_t rgb = ((c & 0xf8) << 8) | ((c >> 5) & 0x7e0) | ((c >> 19) & 0x1f);
        bytes[i * 2] = rgb & 255; bytes[i * 2 + 1] = rgb >> 8;
    }
    if (_sequence % 120 == 0) [self send:MGL_SAVE sequence:_sequence payload:[self battery:1]];
    [self send:MGL_FRAME sequence:_sequence payload:wire];
}
- (void)receive:(NSData *)data peer:(MCPeerID *)peer {
    if (_fatal || ![peer isEqual:_partner]) return;
    MGLPacket packet;
    if (!mgl_decode(data.bytes, data.length, &packet)) { [self fail:@"Invalid or incompatible link packet. Close this session."]; return; }
    _lastReceive = CACurrentMediaTime();
    if (_host && packet.type == MGL_HELLO) {
        if (_connected || (!_pair && packet.sequence) ||
            (_pair && packet.sequence != _sequence && packet.sequence + 1 != _sequence)) {
            [self fail:@"Unexpected handshake sequence."]; return;
        }
        if (memcmp(packet.payload, _hash.bytes, 32)) { [self fail:@"ROMs differ. Both phones must load the exact same GB ROM."]; return; }
        NSData *guestSave = [NSData dataWithBytes:packet.payload + 32 length:MGL_SAVE_SIZE];
        if (!_pair) {
            _guestOriginal = guestSave;
            _pair = mgl_create(_rom.bytes, _rom.length, _originalSave.bytes, _originalSave.length,
                guestSave.bytes, guestSave.length, mgl_dmg_boot, sizeof(mgl_dmg_boot));
            if (!_pair) { [self fail:@"Unable to initialize the GB cable core."]; return; }
        } else if (![_guestOriginal isEqual:guestSave]) { [self fail:@"Reconnect save changed. Close and start a new session."]; return; }
        _connected = YES;
        mgl_set_connected(_pair, 1);
        [self send:MGL_SAVE sequence:_sequence payload:[self battery:1]];
        [self send:MGL_READY sequence:_sequence payload:nil];
        [self status:@"Linked. Both games restart from battery saves. Save inside both games before exporting."]; return;
    }
    if (!_host && packet.type == MGL_READY) {
        if (_connected || packet.sequence < _sequence || packet.sequence > _sequence + 1) {
            [self fail:@"Unexpected resume sequence."]; return;
        }
        _sequence = packet.sequence; _connected = YES; _outstanding = NO; _nextFrame = CACurrentMediaTime();
        [self status:@"Linked. Save inside both games before exporting your new battery save."];
        [self requestFrame]; return;
    }
    if (!_host && packet.type == MGL_SAVE) {
        // The host owns the cable engine. Guest receives only player 1's SRAM.
        if (packet.sequence < _sequence || packet.sequence > _sequence + 1) { [self fail:@"Save sequence mismatch."]; return; }
        _latestSave = [NSData dataWithBytes:packet.payload length:packet.size];
        if (_exportRequested && _connected && packet.sequence == _sequence) {
            _exportRequested = NO; _outstanding = NO; [self shareSave:_latestSave]; [self requestFrame];
        } return;
    }
    if (!_connected) return;
    if (_host && packet.type == MGL_INPUT && packet.sequence == _sequence) {
        [self hostFrame:packet.payload[0]]; return;
    }
    if (_host && packet.type == MGL_EXPORT && packet.sequence == _sequence) {
        [self send:MGL_SAVE sequence:_sequence payload:[self battery:1]]; return;
    }
    if (!_host && packet.type == MGL_FRAME && _outstanding && packet.sequence == _sequence + 1) {
        _sequence = packet.sequence; _outstanding = NO;
        NSMutableData *rgba = [NSMutableData dataWithLength:MGL_PIXELS * 4]; uint32_t *pixels = rgba.mutableBytes;
        for (unsigned i = 0; i < MGL_PIXELS; i++) {
            uint16_t c = packet.payload[i * 2] | (uint16_t)packet.payload[i * 2 + 1] << 8;
            uint8_t r = (c >> 11) * 255 / 31, g = ((c >> 5) & 63) * 255 / 63, b = (c & 31) * 255 / 31;
            pixels[i] = r | (uint32_t)g << 8 | (uint32_t)b << 16 | 0xff000000;
        }
        [self display:rgba];
        _nextFrame = MAX(_nextFrame + 70224.0 / 4194304.0, CACurrentMediaTime());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, _nextFrame - CACurrentMediaTime()) * NSEC_PER_SEC)), _work, ^{ [self requestFrame]; });
        return;
    }
    [self fail:@"Unexpected or stale packet. Games are frozen; close this session."];
}
- (void)exportSave {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save in both games first"
        message:@"Export creates a new battery save for your player. It never overwrites Manic's save. Wait until both in-game saves finish after trading. A disconnect recovery file may represent an unfinished trade; keep your original backup." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Export" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(self->_work, ^{
            if (self->_host && self->_pair) [self shareSave:[self battery:0]];
            else if (self->_connected) { self->_exportRequested = YES; [self requestFrame]; }
            else if (self->_latestSave) [self shareSave:self->_latestSave];
            else [self status:@"No new battery snapshot yet. Your original save remains safe."];
        });
    }]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)shareSave:(NSData *)save {
    if (save.length != MGL_SAVE_SIZE) { [self status:@"Invalid battery snapshot; export cancelled."]; return; }
    NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    dir = [dir URLByAppendingPathComponent:@"GBLinkExports" isDirectory:YES]; NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]) { [self status:@"Cannot create export directory."]; return; }
    NSString *filename = [NSString stringWithFormat:@"GBLink-%@-%@.sav", _host ? @"host" : @"guest", NSUUID.UUID.UUIDString];
    NSURL *url = [dir URLByAppendingPathComponent:filename];
    if (![save writeToURL:url options:NSDataWritingAtomic error:&error]) { [self status:@"Cannot write the new save. Original save unchanged."]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = self.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:share animated:YES completion:nil];
    });
}
- (void)close {
    dispatch_async(_work, ^{
        self->_fatal = YES; self->_connected = NO;
        [self->_advertiser stopAdvertisingPeer]; [self->_browser stopBrowsingForPeers]; [self->_session disconnect];
        self->_session.delegate = nil; self->_advertiser.delegate = nil; self->_browser.delegate = nil;
        if (self->_watchdog) { dispatch_source_cancel(self->_watchdog); self->_watchdog = nil; }
        mgl_destroy(self->_pair); self->_pair = NULL;
    });
    if (_backgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:_backgroundObserver];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didReceiveInvitationFromPeer:(MCPeerID *)peer
        withContext:(NSData *)context invitationHandler:(void (^)(BOOL, MCSession *))handler {
    dispatch_async(_work, ^{
        BOOL accept = !self->_fatal && !self->_connected &&
            [context isEqual:[self->_code dataUsingEncoding:NSUTF8StringEncoding]] &&
            (!self->_partner || [peer isEqual:self->_partner]);
        if (accept) self->_partner = peer;
        handler(accept, accept ? self->_session : nil);
    });
}
- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peer withDiscoveryInfo:(NSDictionary<NSString *,NSString *> *)info {
    if (![info[@"version"] isEqualToString:@"1"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_found containsObject:peer]) {
            NSUInteger index = [self->_found indexOfObject:peer];
            for (UIButton *b in self->_hosts.arrangedSubviews) if ((NSUInteger)b.tag == index) b.enabled = YES;
            return;
        }
        [self->_found addObject:peer];
        UIButton *button = [self addButton:peer.displayName action:@selector(connect:) stack:self->_hosts]; button.tag = self->_found.count - 1;
    });
}
- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peer {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger i = [self->_found indexOfObject:peer]; if (i == NSNotFound) return;
        for (UIButton *b in self->_hosts.arrangedSubviews) if ((NSUInteger)b.tag == i) b.enabled = NO;
    });
}
- (void)session:(MCSession *)session peer:(MCPeerID *)peer didChangeState:(MCSessionState)state {
    dispatch_async(_work, ^{
        if (![peer isEqual:self->_partner] || self->_fatal) return;
        if (state == MCSessionStateConnected && !self->_host) {
            NSMutableData *hello = [NSMutableData dataWithData:self->_hash]; [hello appendData:self->_originalSave];
            [self send:MGL_HELLO sequence:self->_sequence payload:hello];
        } else if (state == MCSessionStateNotConnected) {
            self->_connected = NO; self->_outstanding = NO; self->_keys = 0;
            mgl_set_connected(self->_pair, 0);
            [self status:@"Disconnected. Games are frozen. Reconnect to the same peer without restarting either app."];
        }
    });
}
- (void)session:(MCSession *)session didReceiveData:(NSData *)data fromPeer:(MCPeerID *)peer {
    dispatch_async(_work, ^{ [self receive:data peer:peer]; });
}
- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream withName:(NSString *)name fromPeer:(MCPeerID *)peer { [stream close]; }
- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer withProgress:(NSProgress *)progress { [progress cancel]; }
- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)name fromPeer:(MCPeerID *)peer atURL:(NSURL *)url withError:(NSError *)error {}
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error { [self status:@"Advertising failed. Allow Local Network access and retry with a new session."]; }
- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error { [self status:@"Discovery failed. Allow Local Network access and retry."]; }
@end

__attribute__((visibility("default")))
void MGLPresent(void *presenter, void *rom, void *save) {
    // Retain borrowed bridge arguments before the asynchronous presentation.
    UIViewController *retainedPresenter = (__bridge UIViewController *)presenter;
    NSURL *retainedROM = (__bridge NSURL *)rom;
    NSURL *retainedSave = (__bridge NSURL *)save;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = retainedPresenter;
        if (!controller) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class])
                for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) controller = window.rootViewController;
            while (controller.presentedViewController) controller = controller.presentedViewController;
        }
        if (!controller || [controller isKindOfClass:MGLViewController.class]) return;
        MGLViewController *link = [MGLViewController new]; link.romURL = retainedROM; link.saveURL = retainedSave;
        link.modalPresentationStyle = UIModalPresentationFullScreen;
        [controller presentViewController:link animated:YES completion:nil];
    });
}

// Optional entry point for an unencrypted, normally re-signable sideload IPA.
// The repackager opts in through Info.plist; no private APIs or jailbreak hooks.
@interface MGLLauncher : NSObject
+ (void)open;
@end
@implementation MGLLauncher
+ (void)open { MGLPresent(NULL, NULL, NULL); }
@end
__attribute__((constructor)) static void mgl_install_entry(void) {
    if (![NSBundle.mainBundle.infoDictionary[@"MGLInjectGBLink"] boolValue]) return;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow && ![window viewWithTag:0x4d474c]) {
                UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.tag = 0x4d474c;
                [button setTitle:@"GB Link" forState:UIControlStateNormal]; button.backgroundColor = UIColor.secondarySystemBackgroundColor;
                button.layer.cornerRadius = 10; button.translatesAutoresizingMaskIntoConstraints = NO;
                [button addTarget:MGLLauncher.class action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
                [window addSubview:button];
                [NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],
                    [button.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8],
                    [button.widthAnchor constraintEqualToConstant:80], [button.heightAnchor constraintEqualToConstant:44]]];
            }
        }
    }];
}
