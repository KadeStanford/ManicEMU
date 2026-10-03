// SPDX-License-Identifier: AGPL-3.0-or-later
// Optional overlay for the original Manic/RetroArch Metal renderer. The emulator
// produces one frame; bounded GPU snapshots feed independent display work.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>
#import "MASRender.h"

typedef struct { int x,y; unsigned width,height,full_width,full_height; } MASViewport;
static UIViewController *(*originalStart)(id,SEL,id);
static BOOL (*originalLoad)(id,SEL,id,id,id);
static void (*originalStop)(id,SEL);
static void (*originalNDS)(id,SEL,id);
static void (*original3DS)(id,SEL,id);
static void (*originalTouch)(id,SEL,CGFloat,CGFloat);
static void (*originalConfigs)(id,SEL,id,BOOL);
static void (*originalEnd)(id,SEL);
static id (*originalDrawable)(id,SEL);
static id (*originalLayerDrawable)(id,SEL);
static bool (*driverViewport)(MASViewport *);
static const void *encodedKey=&encodedKey;
static const void *sourceKey=&sourceKey,*framesKey=&framesKey;
static __thread void *scheduledBuffer;
static void (*originalScheduled)(id,SEL,MTLCommandBufferHandler);
static void (*originalPresent)(id,SEL);
static void (*originalPresentAtTime)(id,SEL,CFTimeInterval);
static Ivar layerIvar,drawableIvar,bufferIvar,encoderIvar;
#ifdef MAS_TESTING
static unsigned masEncodedFrames;
static unsigned masPresentedFrames;
static uint32_t masPresentedPhonePixel,masPresentedTVPixel;
static unsigned masSinkAcquisitionsOnMain,masSnapshotsSkipped;
#endif

@interface MASPlan : NSObject
@property(strong) CAMetalLayer *source,*phone,*external;
@property(strong) id<MTLCommandQueue> presentationQueue;
@property(strong) dispatch_queue_t displayQueue;
@property(strong) dispatch_semaphore_t snapshotSlots;
@property(strong) NSMutableArray *freeSnapshots;
@property BOOL threeDS,swapped,originalFramebufferOnly;
@property unsigned sourceFrames,snapshots,dropped,allocations,inflight,peakInflight,presentations;
@property double sourceWaitMax,copyEncodeMax,copyCompletionMax,sinkWaitMax,lastMetricTime;
@end
@implementation MASPlan @end

#ifdef MAS_TESTING
static NSDictionary *performanceMetrics(MASPlan *p) {
    @synchronized(p){return @{@"source_frames":@(p.sourceFrames),@"snapshots":@(p.snapshots),
        @"dropped":@(p.dropped),@"allocations":@(p.allocations),@"inflight":@(p.inflight),
        @"peak_inflight":@(p.peakInflight),@"presentations":@(p.presentations),
        @"source_drawable_wait_max_ms":@(p.sourceWaitMax*1000),
        @"copy_encode_max_ms":@(p.copyEncodeMax*1000),
        @"copy_completion_max_ms":@(p.copyCompletionMax*1000),
        @"sink_drawable_wait_max_ms":@(p.sinkWaitMax*1000)};}
}
#endif
static void logPerformance(MASPlan *p) {
    if(!p||![NSBundle.mainBundle.infoDictionary[@"MASAirPlayDiagnostics"] boolValue])return;
    double now=CACurrentMediaTime();
    @synchronized(p){
        if(now-p.lastMetricTime<1)return;
        p.lastMetricTime=now;
        os_log_info(OS_LOG_DEFAULT,"ManicAirPlay source=%{public}u captured=%{public}u dropped=%{public}u allocated=%{public}u inflight=%{public}u peak=%{public}u presented=%{public}u source_wait_max_ms=%{public}.3f copy_encode_max_ms=%{public}.3f copy_complete_max_ms=%{public}.3f sink_wait_max_ms=%{public}.3f",
            p.sourceFrames,p.snapshots,p.dropped,p.allocations,p.inflight,p.peakInflight,p.presentations,
            p.sourceWaitMax*1000,p.copyEncodeMax*1000,p.copyCompletionMax*1000,p.sinkWaitMax*1000);
    }
}

@interface MASSurface : UIView
@property BOOL touchSurface;
@end

@interface MASManager : NSObject
@property(atomic,strong) MASPlan *plan;
@property(weak) UIView *coreView,*phoneParent;
@property(strong) MASSurface *phoneSurface,*externalSurface;
@property(strong) UIButton *swapButton;
@property(strong) id core;
@property(copy) NSString *phoneLayout,*requestedLayout;
@property(copy) NSString *appliedLayout;
@property NSUInteger resolutionFactor;
@property CGRect phoneRegion;
@property CGSize phoneBounds;
@property BOOL dual,threeDS,swapped,disabled;
@property CGRect inputRegion;
@property CGRect liveViewport;
@property(strong) NSTimer *timer;
+ (instancetype)shared;
- (void)layout:(NSString *)layout threeDS:(BOOL)threeDS;
- (void)refresh;
- (void)reset;
- (void)touch:(CGPoint)p;
- (void)releaseTouch;
@end

static CAMetalLayer *findLayer(CALayer *layer) {
    if([layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)layer;
    for(CALayer *child in layer.sublayers) {CAMetalLayer *found=findLayer(child); if(found) return found;}
    return nil;
}
static UIView *findTouchArea(UIView *view) {
    if(view.hidden||view.alpha==0)return nil;
    // DeltaCore's skin updates this existing view for rotations and skin changes.
    // Reading its UIKit geometry avoids assumptions about private Swift storage.
    if([NSStringFromClass(view.class) hasSuffix:@"TouchInputView"] && !CGRectIsEmpty(view.bounds))return view;
    for(UIView *child in view.subviews){UIView *found=findTouchArea(child);if(found)return found;}
    return nil;
}
static void findScreenSlots(UIView *view,UIView *parent,CGRect *largest) {
    // DeltaCore keeps a GameView for each skin outputFrame, including the empty
    // main slot when the libretro view has moved to the external window.
    if([NSStringFromClass(view.class) hasSuffix:@".GameView"] ||
       [NSStringFromClass(view.class) isEqualToString:@"GameView"]) {
        CGRect r=[view convertRect:view.bounds toView:parent];
        if(r.size.width*r.size.height>largest->size.width*largest->size.height)*largest=r;
    }
    for(UIView *child in view.subviews)findScreenSlots(child,parent,largest);
}
static BOOL externalWindow(UIWindow *w) {
    if(!w)return NO;
#ifdef MAS_TESTING
    // Simulator lifecycle tests use a second window on the same physical screen.
    if([w isKindOfClass:NSClassFromString(@"ExternalWindow")])return YES;
#endif
    if(w.screen!=UIScreen.mainScreen ||
       [w.windowScene.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplay])return YES;
    if(@available(iOS 16.0,*))return [w.windowScene.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
    return NO;
}
static NSString *canonicalScaled(BOOL threeDS,NSUInteger factor) {
    factor=MAX(1,MIN(10,factor));
    NSUInteger w=threeDS?400:256,h=threeDS?240:192,b=threeDS?320:256,x=threeDS?40:0;
    return [NSString stringWithFormat:@"0,0,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu",
            w*factor,h*factor,x*factor,h*factor,b*factor,h*factor,w*factor,h*2*factor];
}
#ifdef MAS_TESTING
static NSString *canonical(BOOL threeDS) {return canonicalScaled(threeDS,1);}
#endif
static NSString *effectiveLayout(MASManager *m) {
    NSArray *parts=[m.requestedLayout componentsSeparatedByString:@","];
    double scale=MAX(1,m.resolutionFactor);
    if(parts.count==10) {
        // Preserve the host's requested native output dimensions as well as the
        // core's internal factor. Single-screen TV layouts have no bottom rect.
        double w=m.threeDS?400:256,h=m.threeDS?240:192,b=m.threeDS?320:256;
        scale=MAX(scale,MAX([parts[2] doubleValue]/w,[parts[3] doubleValue]/h));
        scale=MAX(scale,MAX([parts[6] doubleValue]/b,[parts[7] doubleValue]/h));
    }
    return canonicalScaled(m.threeDS,(NSUInteger)ceil(MIN(10,scale)));
}

@implementation MASSurface
+ (Class)layerClass {return CAMetalLayer.class;}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *layer=(CAMetalLayer *)self.layer;
    CGFloat scale=self.window.screen.scale?:UIScreen.mainScreen.scale;
    layer.contentsScale=scale;
    CGSize size=CGSizeMake(MAX(1,self.bounds.size.width*scale),MAX(1,self.bounds.size.height*scale));
    if(!CGSizeEqualToSize(layer.drawableSize,size))layer.drawableSize=size;
}
- (void)sendTouches:(NSSet<UITouch *> *)touches {
    if(!self.touchSurface) return;
    MASManager *m=MASManager.shared;
    CGSize size=m.threeDS?CGSizeMake(m.swapped?400:320,240):CGSizeMake(256,192);
    CGRect fit=MASFit(size,self.bounds.size);
    CGPoint p=[touches.anyObject locationInView:self];
    if(!CGRectContainsPoint(fit,p)) {[m releaseTouch]; return;}
    [m touch:CGPointMake((p.x-fit.origin.x)/fit.size.width,(p.y-fit.origin.y)/fit.size.height)];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {[self sendTouches:touches];}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {[self sendTouches:touches];}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {[MASManager.shared releaseTouch];}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {[MASManager.shared releaseTouch];}
@end

@implementation MASManager
+ (instancetype)shared {static MASManager *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (void)removeSurfaces {
    MASPlan *old=self.plan;
    if(old)old.source.framebufferOnly=old.originalFramebufferOnly;
    BOOL hadSurfaces=self.phoneSurface!=nil;
    self.plan=nil;
    if(hadSurfaces)[self releaseTouch];
    [self.phoneSurface removeFromSuperview]; [self.externalSurface removeFromSuperview]; [self.swapButton removeFromSuperview];
    self.phoneSurface=nil;self.externalSurface=nil;self.swapButton=nil;
}
- (void)reset {
    [self removeSurfaces]; self.dual=NO;self.disabled=NO;self.swapped=NO;
    self.phoneParent=nil;self.phoneLayout=nil;self.requestedLayout=nil;self.coreView=nil;
    self.inputRegion=CGRectZero;self.liveViewport=CGRectZero;self.appliedLayout=nil;self.resolutionFactor=1;
}
- (void)layout:(NSString *)layout threeDS:(BOOL)threeDS {
    NSAssert(NSThread.isMainThread,@"Layout must run on the UI thread");
    NSString *previous=self.requestedLayout;
    self.threeDS=threeDS; self.dual=layout!=nil; self.requestedLayout=layout;
    NSArray *parts=[layout componentsSeparatedByString:@","];
    if(parts.count!=10) {self.dual=NO;[self removeSurfaces];return;}
    CGFloat v[10];for(int i=0;i<10;i++) {v[i]=[parts[i] doubleValue];if(!isfinite(v[i])){self.dual=NO;[self removeSurfaces];return;}}
    if(v[8]<=0||v[9]<=0) {self.dual=NO;[self removeSurfaces];return;}
    // The original app's Swap Screen action exchanges the two layout rectangles.
    // Keep that existing control connected to the same display assignment.
    NSArray *old=[previous componentsSeparatedByString:@","];
    if(self.plan && old.count==10) {
        BOOL exchanged=YES,different=NO;
        for(int i=0;i<4;i++) {
            exchanged&=fabs(v[i]-[old[i+4] doubleValue])<0.001 && fabs(v[i+4]-[old[i] doubleValue])<0.001;
            different|=fabs(v[i]-[old[i] doubleValue])>0.001;
        }
        if(exchanged&&different&&fabs(v[8]-[old[8] doubleValue])<0.001&&fabs(v[9]-[old[9] doubleValue])<0.001)self.swapped=!self.swapped;
    }
    self.inputRegion=CGRectMake(v[4]/UIScreen.mainScreen.scale,v[5]/UIScreen.mainScreen.scale,
                               v[6]/UIScreen.mainScreen.scale,v[7]/UIScreen.mainScreen.scale);
    UIView *view=self.coreView;
    if(view.superview && view.window && !externalWindow(view.window)) {
        self.phoneParent=view.superview;self.phoneLayout=layout;self.phoneBounds=view.superview.bounds.size;
        CGRect r=CGRectMake(v[4]/v[8]*view.bounds.size.width,v[5]/v[9]*view.bounds.size.height,
                            v[6]/v[8]*view.bounds.size.width,v[7]/v[9]*view.bounds.size.height);
        if(CGRectIsEmpty(r)) r=view.bounds;
        self.phoneRegion=[view convertRect:r toView:view.superview];
    }
    [self refresh];
}
- (MASSurface *)surface {
    MASSurface *s=[MASSurface new];s.backgroundColor=UIColor.blackColor;s.hidden=YES;
    CAMetalLayer *layer=(CAMetalLayer *)s.layer;layer.device=MTLCreateSystemDefaultDevice();
    layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;
    layer.maximumDrawableCount=2;layer.allowsNextDrawableTimeout=YES;
    return s;
}
- (void)swap {
    [self releaseTouch];self.swapped=!self.swapped;[self refresh];
}
- (void)refresh {
    logPerformance(self.plan);
    UIView *view=self.coreView;UIWindow *external=view.window;
    BOOL active=self.dual&&!self.disabled&&externalWindow(external)&&self.phoneParent.window&&!CGRectIsEmpty(self.phoneRegion);
    if(!active) {
        BOOL wasActive=self.plan!=nil;
        [self removeSurfaces];
        if(wasActive && !externalWindow(external) && self.phoneLayout) {
            (self.threeDS?original3DS:originalNDS)(self.core,NSSelectorFromString(self.threeDS?@"set3DSCustomLayout:":@"setNDSCustomLayout:"),self.phoneLayout);
        }
        return;
    }
    CAMetalLayer *source=findLayer(view.layer);if(!source)return;
    if(!self.phoneSurface) {
        self.phoneSurface=[self surface];self.phoneSurface.touchSurface=YES;
        [self.phoneParent addSubview:self.phoneSurface];
        self.externalSurface=[self surface];self.externalSurface.userInteractionEnabled=NO;
        [external addSubview:self.externalSurface];
        self.swapButton=[UIButton buttonWithType:UIButtonTypeSystem];
        self.swapButton.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.75];
        self.swapButton.tintColor=UIColor.whiteColor;self.swapButton.layer.cornerRadius=8;
        self.swapButton.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [self.swapButton addTarget:self action:@selector(swap) forControlEvents:UIControlEventTouchUpInside];
        [self.phoneParent addSubview:self.swapButton];
    }
    NSString *effective=effectiveLayout(self);
    if(![effective isEqual:self.appliedLayout]) {
        self.appliedLayout=effective;
        (self.threeDS?original3DS:originalNDS)(self.core,NSSelectorFromString(self.threeDS?@"set3DSCustomLayout:":@"setNDSCustomLayout:"),effective);
    }
    CGSize bounds=self.phoneParent.bounds.size;
    CGFloat sx=self.phoneBounds.width>0?bounds.width/self.phoneBounds.width:1;
    CGFloat sy=self.phoneBounds.height>0?bounds.height/self.phoneBounds.height:1;
    CGRect r=self.phoneRegion;r.origin.x*=sx;r.origin.y*=sy;r.size.width*=sx;r.size.height*=sy;
    UIView *touchArea=findTouchArea(self.phoneParent);
    if(touchArea)r=[touchArea convertRect:touchArea.bounds toView:self.phoneParent];
    if(bounds.width>bounds.height) {
        CGRect large=CGRectZero;findScreenSlots(self.phoneParent,self.phoneParent,&large);
        if(!CGRectIsEmpty(large))r=large;
    }
    self.phoneSurface.frame=CGRectIntersection(self.phoneParent.bounds,r);
    self.externalSurface.frame=external.bounds;
    self.swapButton.frame=CGRectMake(MAX(0,CGRectGetMaxX(self.phoneSurface.frame)-164),
                                     MAX(self.phoneParent.safeAreaInsets.top,CGRectGetMinY(self.phoneSurface.frame)-38),164,34);
    [self.swapButton setTitle:self.swapped?@"Swap Â· TV touchpad":@"Swap screens" forState:UIControlStateNormal];
    [self.phoneSurface setNeedsLayout];[self.externalSurface setNeedsLayout];
    MASPlan *old=self.plan;
    if(old.source==source&&old.swapped==self.swapped&&old.threeDS==self.threeDS)return;
    MASPlan *p=[MASPlan new];p.source=source;p.phone=(CAMetalLayer *)self.phoneSurface.layer;
    p.external=(CAMetalLayer *)self.externalSurface.layer;p.threeDS=self.threeDS;p.swapped=self.swapped;
    p.displayQueue=dispatch_queue_create("org.manicemu.airplay.display",DISPATCH_QUEUE_SERIAL);
    p.snapshotSlots=dispatch_semaphore_create(3);p.freeSnapshots=[NSMutableArray new];
    p.originalFramebufferOnly=old.source==source?old.originalFramebufferOnly:source.framebufferOnly;
    self.plan=p;
}
- (void)touch:(CGPoint)p {
    if(!self.plan||CGRectIsEmpty(self.liveViewport)||!originalTouch)return;
    CGRect vp=self.liveViewport;
    CGFloat x=self.threeDS?0.1+0.8*p.x:p.x;
    CGFloat y=0.5+0.5*p.y;
    originalTouch(self.core,NSSelectorFromString(@"sendTouchEventX:y:"),
                   (vp.origin.x+vp.size.width*x)/UIScreen.mainScreen.nativeScale,
                   (vp.origin.y+vp.size.height*y)/UIScreen.mainScreen.nativeScale);
}
- (void)releaseTouch {
    if(self.core&&[self.core respondsToSelector:NSSelectorFromString(@"releaseTouchEvent")])
        ((void(*)(id,SEL))objc_msgSend)(self.core,NSSelectorFromString(@"releaseTouchEvent"));
}
@end

static void onMain(dispatch_block_t action) {if(NSThread.isMainThread)action();else dispatch_sync(dispatch_get_main_queue(),action);}
static UIViewController *masStart(id self,SEL cmd,id save) {
    UIViewController *vc=originalStart(self,cmd,save);
    onMain(^{MASManager *m=MASManager.shared;[m reset];m.core=self;m.coreView=vc.view;});return vc;
}
static BOOL masLoad(id self,SEL cmd,id path,id core,id completion) {
    onMain(^{MASManager *m=MASManager.shared;[m removeSurfaces];m.dual=NO;m.disabled=NO;m.swapped=NO;});
    return originalLoad(self,cmd,path,core,completion);
}
static void masStop(id self,SEL cmd) {onMain(^{[MASManager.shared reset];});originalStop(self,cmd);}
static void masLayout(id self,SEL cmd,id layout) {
    BOOL threeDS=[NSStringFromSelector(cmd) isEqualToString:@"set3DSCustomLayout:"];
    __block NSString *effective=layout;
    onMain(^{MASManager *m=MASManager.shared;m.core=self;[m layout:layout threeDS:threeDS];if(m.plan)effective=effectiveLayout(m);});
    (threeDS?original3DS:originalNDS)(self,cmd,effective);
}
static void masConfigs(id self,SEL cmd,NSDictionary *configs,BOOL flush) {
    originalConfigs(self,cmd,configs,flush);
    NSString *value=configs[@"citra_resolution_factor"];
    if(value)onMain(^{MASManager *m=MASManager.shared;m.resolutionFactor=MAX(1,MIN(10,value.integerValue));[m refresh];});
}
static void masTouch(id self,SEL cmd,CGFloat x,CGFloat y) {
    MASManager *m=MASManager.shared;
    if(!m.plan||CGRectIsEmpty(m.inputRegion)){originalTouch(self,cmd,x,y);return;}
    CGRect r=m.inputRegion;
    [m touch:CGPointMake(MAX(0,MIN(1,(x-r.origin.x)/r.size.width)),MAX(0,MIN(1,(y-r.origin.y)/r.size.height)))];
}
static id masDrawable(id self,SEL cmd) {
    MASPlan *plan=MASManager.shared.plan;
    CAMetalLayer *layer=object_getIvar(self,layerIvar);
    if(plan.source==layer)layer.framebufferOnly=NO;
    return originalDrawable(self,cmd);
}
// Vulkan uses MetalLayerView/MoltenVK and never calls the Metal Context end hook.
// Observe its actual swapchain drawable and copy after the producing command
// buffer completes, independently of whether the source layer is occluded.
// Bound capture memory and discard stale display frames without waiting on the
// emulation thread. Reusable private textures detach source drawables from the
// phone/TV presentation queues, so a slow AirPlay sink cannot exhaust the core's
// swapchain or block a Metal completion callback.
static void recycleSnapshot(MASPlan *plan,id<MTLTexture> texture) {
    @synchronized(plan.freeSnapshots){[plan.freeSnapshots addObject:texture];}
    @synchronized(plan){if(plan.inflight)plan.inflight--;}
    dispatch_semaphore_signal(plan.snapshotSlots);
}
static void presentSnapshot(id<MTLTexture> texture,MASPlan *live,MASViewport vp) {
            MASManager *m=MASManager.shared;
            if(m.plan!=live){recycleSnapshot(live,texture);return;}
            CGRect region=CGRectMake((CGFloat)vp.x/texture.width,(CGFloat)vp.y/texture.height,
                                     (CGFloat)vp.width/texture.width,(CGFloat)vp.height/texture.height);
            CGRect top=region,bottom=region;
            top.size.height*=0.5;bottom.origin.y+=bottom.size.height*0.5;bottom.size.height*=0.5;
            if(live.threeDS){bottom.origin.x+=bottom.size.width*0.1;bottom.size.width*=0.8;}
            double sinkStart=CACurrentMediaTime();
            id<CAMetalDrawable> phone=[live.phone nextDrawable],tv=[live.external nextDrawable];
            @synchronized(live){live.sinkWaitMax=MAX(live.sinkWaitMax,CACurrentMediaTime()-sinkStart);}
            @synchronized(live){if(!live.presentationQueue)live.presentationQueue=[texture.device newCommandQueue];}
            id<MTLCommandBuffer> buffer=[live.presentationQueue commandBuffer];
            CGSize topSize=live.threeDS?CGSizeMake(400,240):CGSizeMake(256,192);
            CGSize bottomSize=live.threeDS?CGSizeMake(320,240):CGSizeMake(256,192);
            if(!phone||!tv||!MASDrawCrop(buffer,texture,phone.texture,live.swapped?top:bottom,live.swapped?topSize:bottomSize)||
               !MASDrawCrop(buffer,texture,tv.texture,live.swapped?bottom:top,live.swapped?bottomSize:topSize)){recycleSnapshot(live,texture);return;}
#ifdef MAS_TESTING
            id<MTLBuffer> phoneReadback=[texture.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
            id<MTLBuffer> tvReadback=[texture.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> readback=[buffer blitCommandEncoder];
            [readback copyFromTexture:phone.texture sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(phone.texture.width/2,phone.texture.height/2,0)
                           sourceSize:MTLSizeMake(1,1,1) toBuffer:phoneReadback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
            [readback copyFromTexture:tv.texture sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(tv.texture.width/2,tv.texture.height/2,0)
                           sourceSize:MTLSizeMake(1,1,1) toBuffer:tvReadback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
            [readback endEncoding];
#endif
            [buffer presentDrawable:phone];[buffer presentDrawable:tv];
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
                recycleSnapshot(live,texture);
                @synchronized(live){if(finished.status==MTLCommandBufferStatusCompleted)live.presentations++;}
                dispatch_async(dispatch_get_main_queue(),^{
                    if(m.plan!=live||finished.status!=MTLCommandBufferStatusCompleted)return;
                    m.liveViewport=CGRectMake(vp.x,vp.y,vp.width,vp.height);
                    if(m.phoneSurface.hidden)m.phoneSurface.hidden=NO;
                    if(m.externalSurface.hidden)m.externalSurface.hidden=NO;
#ifdef MAS_TESTING
                    masPresentedFrames++;
                    masPresentedPhonePixel=*(uint32_t *)phoneReadback.contents;
                    masPresentedTVPixel=*(uint32_t *)tvReadback.contents;
#endif
                });
            }];
            [buffer commit];
}
static void captureFrame(id<CAMetalDrawable> drawable,CAMetalLayer *layer,id<MTLCommandBuffer> producer) {
    MASPlan *plan=MASManager.shared.plan;
    if(plan.source!=layer)return;
    if(dispatch_semaphore_wait(plan.snapshotSlots,DISPATCH_TIME_NOW)!=0) {
        @synchronized(plan){plan.dropped++;}
#ifdef MAS_TESTING
        masSnapshotsSkipped++;
#endif
        return;
    }
    double copyStart=CACurrentMediaTime();
    @synchronized(plan){plan.snapshots++;plan.inflight++;plan.peakInflight=MAX(plan.peakInflight,plan.inflight);}
    id<MTLTexture> source=drawable.texture,snapshot=nil;
    @synchronized(plan.freeSnapshots){snapshot=plan.freeSnapshots.lastObject;if(snapshot)[plan.freeSnapshots removeLastObject];}
    if(snapshot.width!=source.width||snapshot.height!=source.height||snapshot.pixelFormat!=source.pixelFormat) {
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat width:source.width height:source.height mipmapped:NO];
        desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead;
        snapshot=[source.device newTextureWithDescriptor:desc];
        @synchronized(plan){plan.allocations++;}
    }
    if(!snapshot){@synchronized(plan){plan.inflight--;}dispatch_semaphore_signal(plan.snapshotSlots);return;}
    MASViewport vp={0,0,(unsigned)source.width,(unsigned)source.height,(unsigned)source.width,(unsigned)source.height};
    if(driverViewport)driverViewport(&vp);
    @synchronized(plan){if(!plan.presentationQueue)plan.presentationQueue=[source.device newCommandQueue];}
    id<MTLCommandBuffer> buffer=producer?:[plan.presentationQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[buffer blitCommandEncoder];
    if(!blit){recycleSnapshot(plan,snapshot);return;}
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:snapshot destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    @synchronized(plan){plan.copyEncodeMax=MAX(plan.copyEncodeMax,CACurrentMediaTime()-copyStart);}
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        @synchronized(plan){plan.copyCompletionMax=MAX(plan.copyCompletionMax,CACurrentMediaTime()-copyStart);}
        // Retain the source only through this GPU copy, never through sink waits.
        (void)drawable;
        if(finished.status!=MTLCommandBufferStatusCompleted){recycleSnapshot(plan,snapshot);return;}
        dispatch_async(plan.displayQueue,^{presentSnapshot(snapshot,plan,vp);});
    }];
    if(!producer)[buffer commit];
}
static void copyPresentedFrame(id<CAMetalDrawable> drawable,CAMetalLayer *layer) {captureFrame(drawable,layer,nil);}
static void recordScheduledPresentation(id<CAMetalDrawable> drawable) {
    CAMetalLayer *layer=objc_getAssociatedObject(drawable,sourceKey);
    if(!layer||!MASManager.shared.plan)return;
    id<MTLCommandBuffer> buffer=(__bridge id)scheduledBuffer;
    NSMutableArray *frames=buffer?objc_getAssociatedObject(buffer,framesKey):nil;
    if(!frames||layer!=MASManager.shared.plan.source||[objc_getAssociatedObject(drawable,encodedKey) boolValue])return;
    objc_setAssociatedObject(drawable,encodedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(frames){[frames addObject:@{@"drawable":drawable,@"source":layer}];}
}
static void masPresent(id self,SEL cmd) {recordScheduledPresentation(self);originalPresent(self,cmd);}
static void masPresentAtTime(id self,SEL cmd,CFTimeInterval t) {recordScheduledPresentation(self);originalPresentAtTime(self,cmd,t);}
static void masScheduled(id self,SEL cmd,MTLCommandBufferHandler action) {
    if(!MASManager.shared.plan){originalScheduled(self,cmd,action);return;}
    if(!objc_getAssociatedObject(self,framesKey)&&MASManager.shared.plan) {
        NSMutableArray *frames=[NSMutableArray new];objc_setAssociatedObject(self,framesKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            NSArray *pending=objc_getAssociatedObject(finished,framesKey);
            if(finished.status==MTLCommandBufferStatusCompleted)for(NSDictionary *frame in pending)copyPresentedFrame(frame[@"drawable"],frame[@"source"]);
            objc_setAssociatedObject(finished,framesKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }];
    }
    originalScheduled(self,cmd,^(id<MTLCommandBuffer> buffer) {
        void *previous=scheduledBuffer;scheduledBuffer=(__bridge void *)buffer;
        action(buffer);scheduledBuffer=previous;
    });
}
static void hookPresentation(id<CAMetalDrawable> drawable) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Class cls=object_getClass(drawable);Method method=class_getInstanceMethod(cls,@selector(present));
        originalPresent=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(present),(IMP)masPresent,method_getTypeEncoding(method));
        method=class_getInstanceMethod(cls,@selector(presentAtTime:));
        if(method){originalPresentAtTime=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(presentAtTime:),(IMP)masPresentAtTime,method_getTypeEncoding(method));}
        id<MTLCommandBuffer> probe=[[drawable.texture.device newCommandQueue] commandBuffer];
        Class cb=object_getClass(probe);method=class_getInstanceMethod(cb,@selector(addScheduledHandler:));
        if(method){originalScheduled=(void *)method_getImplementation(method);class_replaceMethod(cb,@selector(addScheduledHandler:),(IMP)masScheduled,method_getTypeEncoding(method));}
    });
}
static id masLayerDrawable(CAMetalLayer *layer,SEL cmd) {
    MASPlan *p=MASManager.shared.plan;
#ifdef MAS_TESTING
    if((layer==p.phone||layer==p.external)&&NSThread.isMainThread)masSinkAcquisitionsOnMain++;
#endif
    if(p.source==layer)layer.framebufferOnly=NO;
    double acquireStart=CACurrentMediaTime();
    id<CAMetalDrawable> drawable=originalLayerDrawable(layer,cmd);
    if(p.source==layer)@synchronized(p){p.sourceFrames++;p.sourceWaitMax=MAX(p.sourceWaitMax,CACurrentMediaTime()-acquireStart);}
    if(p.source==layer&&drawable) {
        objc_setAssociatedObject(drawable,encodedKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(drawable,sourceKey,layer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hookPresentation(drawable);
        // Native presented callbacks cover renderers that present without a
        // scheduled command-buffer callback. This API is absent in Simulator.
        SEL selector=NSSelectorFromString(@"addPresentedHandler:");
        if([drawable respondsToSelector:selector])((void(*)(id,SEL,void(^)(id<MTLDrawable>)))objc_msgSend)(drawable,selector,^(id<MTLDrawable> value) {
            if([objc_getAssociatedObject(value,encodedKey) boolValue])return;
            objc_setAssociatedObject(value,encodedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            copyPresentedFrame((id)value,layer);
        });
    }
    return drawable;
}
static void masEnd(id self,SEL cmd) {
    MASManager *m=MASManager.shared;MASPlan *p=m.plan;
    CAMetalLayer *layer=object_getIvar(self,layerIvar);
    id<CAMetalDrawable> drawable=object_getIvar(self,drawableIvar);
    id<MTLCommandBuffer> buffer=object_getIvar(self,bufferIvar);
    if(p.source==layer&&drawable&&buffer&&!layer.framebufferOnly) {
        id<MTLRenderCommandEncoder> encoder=object_getIvar(self,encoderIvar);
        if(encoder){[encoder endEncoding];object_setIvar(self,encoderIvar,nil);}
        captureFrame(drawable,layer,buffer);
        objc_setAssociatedObject(drawable,encodedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#ifdef MAS_TESTING
        masEncodedFrames++;
#endif
    }
    originalEnd(self,cmd);
}
static IMP replace(Class cls,NSString *name,IMP replacement,unsigned arguments) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    if(!method||method_getNumberOfArguments(method)!=arguments)return NULL;
    return method_setImplementation(method,replacement);
}
static void install(void) {
    if(![NSBundle.mainBundle.infoDictionary[@"MASInjectAirPlaySplit"] boolValue])return;
    Class core=NSClassFromString(@"LibretroCore"),context=NSClassFromString(@"Context");
    layerIvar=class_getInstanceVariable(context,"_layer");drawableIvar=class_getInstanceVariable(context,"_drawable");
    bufferIvar=class_getInstanceVariable(context,"_commandBuffer");encoderIvar=class_getInstanceVariable(context,"_rce");
    // Refuse a mismatched renderer ABI before changing any implementation.
    NSArray *selectors=@[@"startWithCustomSaveDir:",@"loadGame:corePath:completion:",@"stop",@"setNDSCustomLayout:",@"set3DSCustomLayout:",@"sendTouchEventX:y:",@"releaseTouchEvent"];
    unsigned counts[]={3,5,2,3,3,4,2};
    for(NSUInteger i=0;i<selectors.count;i++) {
        Method method=class_getInstanceMethod(core,NSSelectorFromString(selectors[i]));
        if(!method||method_getNumberOfArguments(method)!=counts[i])return;
    }
    if(!layerIvar||!drawableIvar||!bufferIvar||!encoderIvar||
       !class_getInstanceMethod(context,@selector(end))||!class_getInstanceMethod(context,@selector(nextDrawable))||
       !class_getInstanceMethod(context,NSSelectorFromString(@"viewport")))return;
    for(NSValue *value in @[[NSValue valueWithPointer:layerIvar],[NSValue valueWithPointer:drawableIvar],
                           [NSValue valueWithPointer:bufferIvar],[NSValue valueWithPointer:encoderIvar]])
        if(ivar_getTypeEncoding(value.pointerValue)[0]!='@')return;
    originalStart=(void *)replace(core,@"startWithCustomSaveDir:",(IMP)masStart,3);
    originalLoad=(void *)replace(core,@"loadGame:corePath:completion:",(IMP)masLoad,5);
    originalStop=(void *)replace(core,@"stop",(IMP)masStop,2);
    originalNDS=(void *)replace(core,@"setNDSCustomLayout:",(IMP)masLayout,3);
    original3DS=(void *)replace(core,@"set3DSCustomLayout:",(IMP)masLayout,3);
    originalTouch=(void *)replace(core,@"sendTouchEventX:y:",(IMP)masTouch,4);
    originalConfigs=(void *)replace(core,@"updateRunningCoreConfigs:flush:",(IMP)masConfigs,4);
    originalDrawable=(void *)replace(context,@"nextDrawable",(IMP)masDrawable,2);
    originalEnd=(void *)replace(context,@"end",(IMP)masEnd,2);
    originalLayerDrawable=(void *)replace(CAMetalLayer.class,@"nextDrawable",(IMP)masLayerDrawable,2);
    driverViewport=(void *)dlsym(RTLD_DEFAULT,"video_driver_get_viewport_info");
    MASManager *m=MASManager.shared;
    m.timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:m selector:@selector(refresh) userInfo:nil repeats:YES];
}
__attribute__((constructor)) static void boot(void) {dispatch_async(dispatch_get_main_queue(),^{install();});}
