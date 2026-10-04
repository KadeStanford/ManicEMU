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
static void (*originalStoredConfigs)(id,SEL,id,id,BOOL);
static void (*originalEnd)(id,SEL);
static id (*originalDrawable)(id,SEL);
static id (*originalLayerDrawable)(id,SEL);
static bool (*driverViewport)(MASViewport *);
static float (*driverNativeScale)(void);
static const char *(*driverIdent)(void);
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

@class MASFrame;
@interface MASSink : NSObject
@property(strong) CAMetalLayer *layer;
@property(strong) dispatch_queue_t queue;
@property(strong) id<MTLCommandQueue> commandQueue;
@property(strong) MASFrame *pending;
@property BOOL scheduled,phone;
@property unsigned presentations,superseded,lastSequence,submittedSequence;
@property double waitMax,ageLast,ageMax;
@end
@implementation MASSink @end
@interface MASPlan : NSObject
@property(strong) CAMetalLayer *source,*phone,*external;
@property(strong) id<MTLCommandQueue> presentationQueue;
@property(strong) dispatch_queue_t displayQueue;
@property(strong) dispatch_semaphore_t snapshotSlots;
@property(strong) NSMutableArray *freeSnapshots;
@property(strong) MASSink *phoneSink,*tvSink;
@property BOOL threeDS,swapped,originalFramebufferOnly;
@property BOOL directPhone;
@property unsigned directPhoneCaptures;
@property unsigned sourceFrames,snapshots,dropped,allocations,inflight,peakInflight,presentations;
@property unsigned sequence,sourceWidth,sourceHeight,viewportWidth,viewportHeight;
@property unsigned sourcePresentedCallbacks;
@property double producerVisibleArea;
@property CGSize compositeSize,externalModeSize;
@property double sourceWaitMax,copyEncodeMax,copyCompletionMax,sinkWaitMax,lastMetricTime;
@end
@implementation MASPlan @end
static void recycleSnapshot(MASPlan *,id<MTLTexture>);
@interface MASFrame : NSObject
@property(strong) MASPlan *owner;
@property(strong) id<MTLTexture> texture;
@property MASViewport viewport;
@property unsigned sequence;
@property double capturedAt;
@end
@implementation MASFrame
- (void)dealloc {recycleSnapshot(_owner,_texture);}
@end

static NSDictionary *performanceMetrics(MASPlan *p) {
    @synchronized(p){return @{@"source_frames":@(p.sourceFrames),@"snapshots":@(p.snapshots),
        @"dropped":@(p.dropped),@"allocations":@(p.allocations),@"inflight":@(p.inflight),
        @"peak_inflight":@(p.peakInflight),@"presentations":@(p.presentations),
        @"source_drawable_wait_max_ms":@(p.sourceWaitMax*1000),
        @"source_presented_callbacks":@(p.sourcePresentedCallbacks),
        @"producer_visible_area_points":@(p.producerVisibleArea),
        @"phone_displays_native_producer":@(p.directPhone),
        @"phone_direct_completed_captures":@(p.directPhoneCaptures),
        @"copy_encode_max_ms":@(p.copyEncodeMax*1000),
        @"copy_completion_max_ms":@(p.copyCompletionMax*1000),
        @"sink_drawable_wait_max_ms":@(p.sinkWaitMax*1000),
        @"source_pixels":@[@(p.sourceWidth),@(p.sourceHeight)],
        @"viewport_pixels":@[@(p.viewportWidth),@(p.viewportHeight)],
        @"requested_composite_pixels":@[@(p.compositeSize.width),@(p.compositeSize.height)],
        @"top_crop_pixels":@[@(p.viewportWidth),@(p.viewportHeight/2)],
        @"bottom_crop_pixels":@[@(p.threeDS?p.viewportWidth*0.8:p.viewportWidth),@(p.viewportHeight/2)],
        @"phone_output_pixels":@[@(p.phone.drawableSize.width),@(p.phone.drawableSize.height)],
        @"tv_output_pixels":@[@(p.external.drawableSize.width),@(p.external.drawableSize.height)],
        @"external_mode_pixels":@[@(p.externalModeSize.width),@(p.externalModeSize.height)],
        @"phone_presentations":@(p.phoneSink.presentations),@"tv_presentations":@(p.tvSink.presentations),
        @"phone_superseded":@(p.phoneSink.superseded),@"tv_superseded":@(p.tvSink.superseded),
        @"phone_last_sequence":@(p.phoneSink.lastSequence),@"tv_last_sequence":@(p.tvSink.lastSequence),
        @"phone_frame_age_last_ms":@(p.phoneSink.ageLast*1000),@"tv_frame_age_last_ms":@(p.tvSink.ageLast*1000),
        @"phone_frame_age_max_ms":@(p.phoneSink.ageMax*1000),@"tv_frame_age_max_ms":@(p.tvSink.ageMax*1000),
        @"phone_drawable_wait_max_ms":@(p.phoneSink.waitMax*1000),@"tv_drawable_wait_max_ms":@(p.tvSink.waitMax*1000)};}
}
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
    // Numeric pipeline evidence only. No images, game paths, input, or saves.
    NSString *dir=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"ManicAirPlayDiagnostics"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *metrics=[performanceMetrics(p) mutableCopy];
    metrics[@"host_time_seconds"]=@(now);metrics[@"receiver_or_network_latency_measured"]=@NO;
    [[NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil]
        writeToFile:[dir stringByAppendingPathComponent:@"metrics.json"] atomically:YES];
}

@interface MASSurface : UIView
@property BOOL touchSurface;
@end

@interface MASManager : NSObject
@property(atomic,strong) MASPlan *plan;
@property(weak) UIView *coreView,*phoneParent;
@property(weak) UIView *externalSourceParent;
@property(weak) UIWindow *externalTarget;
@property(strong) UIView *producerHost;
@property CGRect externalSourceFrame;
@property CGRect originalProducerBounds,lastProducerBounds;
@property UIViewAutoresizing originalProducerAutoresizing;
@property BOOL originalProducerTranslates;
@property(copy) NSArray<NSLayoutConstraint *> *suspendedProducerConstraints;
@property CGAffineTransform originalProducerTransform;
@property(strong) MASSurface *phoneSurface,*externalSurface;
@property(strong) UIButton *swapButton;
@property(strong) id core;
@property(copy) NSString *phoneLayout,*requestedLayout;
@property(copy) NSString *appliedLayout;
@property NSUInteger resolutionFactor;
@property NSUInteger last3DSResolutionFactor,lastDSResolutionFactor;
@property CGRect phoneRegion;
@property CGSize phoneBounds;
@property BOOL dual,threeDS,swapped,disabled;
@property CGRect inputRegion;
@property CGRect liveViewport;
@property CGSize liveSourceSize;
@property(weak) CAMetalLayer *liveViewportSource;
@property unsigned liveViewportSequence;
@property(strong) NSTimer *timer;
+ (instancetype)shared;
- (void)layout:(NSString *)layout threeDS:(BOOL)threeDS;
- (void)refresh;
- (void)updateProducerGeometry;
- (void)reset;
- (void)touch:(CGPoint)p;
- (void)releaseTouch;
- (void)sceneChanged:(NSNotification *)notification;
@end

static CAMetalLayer *findLayer(CALayer *layer) {
    if([layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)layer;
    for(CALayer *child in layer.sublayers) {CAMetalLayer *found=findLayer(child); if(found) return found;}
    return nil;
}
static NSArray<NSLayoutConstraint *> *producerSizeConstraints(UIView *view) {
    NSMutableArray *constraints=[NSMutableArray new];
    for(NSLayoutConstraint *constraint in view.constraints) {
        // Removing a view drops constraints to its former parent, but its own
        // width/height/aspect constraints survive. Keep child renderer anchors.
        if(constraint.active&&constraint.firstItem==view&&
           (constraint.firstAttribute==NSLayoutAttributeWidth||constraint.firstAttribute==NSLayoutAttributeHeight)&&
           (!constraint.secondItem||constraint.secondItem==view)) [constraints addObject:constraint];
    }
    return constraints;
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
static NSArray<UIWindow *> *displayWindows(void) {
    NSMutableOrderedSet *windows=[NSMutableOrderedSet orderedSetWithArray:UIApplication.sharedApplication.windows];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    return windows.array;
}
static UIView *phoneGameRoot(UIViewController *controller) {
    if(!controller)return nil;
    UIView *presented=phoneGameRoot(controller.presentedViewController);if(presented)return presented;
    for(UIViewController *child in controller.childViewControllers) {
        UIView *found=phoneGameRoot(child);if(found)return found;
    }
    if([NSStringFromClass(controller.class) hasSuffix:@"PlayViewController"] &&
       controller.isViewLoaded && !controller.view.hidden && !externalWindow(controller.view.window))return controller.view;
#ifdef MAS_TESTING
    // Synthetic frontend has a plain root controller with a real skin touch area.
    if(controller.isViewLoaded&&findTouchArea(controller.view)&&!externalWindow(controller.view.window))return controller.view;
#endif
    return nil;
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
    self.liveViewport=CGRectZero;self.liveSourceSize=CGSizeZero;
    self.liveViewportSource=nil;self.liveViewportSequence=0;
    UIView *source=self.coreView;
    BOOL owned=source.superview==self.producerHost;
    if(old)source.transform=self.originalProducerTransform;
    if(source.superview==self.producerHost&&self.externalSourceParent) {
        [self.externalSourceParent addSubview:source];source.frame=self.externalSourceFrame;
    } else if(old&&CGRectEqualToRect(source.bounds,self.lastProducerBounds)) {
        CGRect frame=source.frame;frame.size=self.originalProducerBounds.size;source.frame=frame;
    }
    if(old){source.autoresizingMask=self.originalProducerAutoresizing;
        source.translatesAutoresizingMaskIntoConstraints=self.originalProducerTranslates;
        // A frontend which already took the view back may have remade its skin
        // constraints. Do not reactivate old constraints over that new layout.
        if(owned&&self.suspendedProducerConstraints.count)[NSLayoutConstraint activateConstraints:self.suspendedProducerConstraints];}
    self.suspendedProducerConstraints=nil;
    [self.producerHost removeFromSuperview];self.producerHost=nil;
    self.externalSourceParent=nil;self.externalTarget=nil;
    if(hadSurfaces)[self releaseTouch];
    [self.phoneSurface removeFromSuperview]; [self.externalSurface removeFromSuperview]; [self.swapButton removeFromSuperview];
    self.phoneSurface=nil;self.externalSurface=nil;self.swapButton=nil;
}
- (void)reset {
    [self removeSurfaces]; self.dual=NO;self.disabled=NO;self.swapped=NO;
    self.phoneParent=nil;self.phoneLayout=nil;self.requestedLayout=nil;self.coreView=nil;
    self.inputRegion=CGRectZero;self.liveViewport=CGRectZero;self.liveSourceSize=CGSizeZero;
    self.liveViewportSource=nil;self.liveViewportSequence=0;self.appliedLayout=nil;self.resolutionFactor=1;
}
- (void)layout:(NSString *)layout threeDS:(BOOL)threeDS {
    NSAssert(NSThread.isMainThread,@"Layout must run on the UI thread");
    NSString *previous=self.requestedLayout;
    self.threeDS=threeDS; self.dual=layout!=nil; self.requestedLayout=layout;
    self.resolutionFactor=MAX(1,threeDS?self.last3DSResolutionFactor:self.lastDSResolutionFactor);
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
    if(view.superview && view.superview!=self.producerHost && view.window && !externalWindow(view.window)) {
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
- (void)sceneChanged:(NSNotification *)notification {
    // Reconcile after frontend scene delegates finish their current main-thread
    // reparenting work. No rendering thread waits for this notification handler.
    dispatch_async(dispatch_get_main_queue(),^{[self refresh];});
}
- (void)updateProducerGeometry {
    NSAssert(NSThread.isMainThread,@"Producer geometry must run on the UI thread");
    UIView *view=self.coreView;CAMetalLayer *source=findLayer(view.layer);
    if(!source||view.superview!=self.producerHost||CGRectIsEmpty(self.phoneSurface.frame))return;
    CGSize pixels=source.drawableSize;CGRect viewport=(CGRect){CGPointZero,pixels};
    if(self.liveViewportSource==source && self.liveSourceSize.width>0 && self.liveSourceSize.height>0 &&
       !CGRectIsEmpty(self.liveViewport)) {pixels=self.liveSourceSize;viewport=self.liveViewport;}
    if(pixels.width<=0||pixels.height<=0||CGRectIsEmpty(source.bounds))return;
    // Use the same completed-frame viewport as the TV sink. RetroArch can put
    // the composite inside an offset/letterboxed drawable; the root view's full
    // bounds are not necessarily the rendered composite. Convert the selected
    // pixel rectangle through the actual Metal layer, including nested views.
    CGRect crop=viewport;crop.size.height*=0.5;
    if(!self.swapped){crop.origin.y+=crop.size.height;
        if(self.threeDS){crop.origin.x+=crop.size.width*0.1;crop.size.width*=0.8;}}
    CGRect layerCrop=CGRectMake(source.bounds.origin.x+crop.origin.x/pixels.width*source.bounds.size.width,
        source.bounds.origin.y+crop.origin.y/pixels.height*source.bounds.size.height,
        crop.size.width/pixels.width*source.bounds.size.width,crop.size.height/pixels.height*source.bounds.size.height);
    CGRect localCrop=[source convertRect:layerCrop toLayer:view.layer];
    if(CGRectIsEmpty(localCrop)||!isfinite(localCrop.origin.x)||!isfinite(localCrop.origin.y))return;
    CGSize aspect=self.threeDS?CGSizeMake(self.swapped?400:320,240):CGSizeMake(256,192);
    CGRect fit=MASFit(aspect,self.phoneSurface.bounds.size);
    // Clip exactly at the fitted screen, not at the larger skin slot. Otherwise
    // the other half of the composite can appear in the letterbox margins.
    self.producerHost.frame=CGRectOffset(fit,self.phoneSurface.frame.origin.x,self.phoneSurface.frame.origin.y);
    CGFloat sx=fit.size.width/localCrop.size.width,sy=fit.size.height/localCrop.size.height;
    if(!isfinite(sx)||!isfinite(sy)||sx<=0||sy<=0)return;
    view.transform=CGAffineTransformMakeScale(sx,sy);
    view.center=CGPointMake((CGRectGetMidX(view.bounds)-localCrop.origin.x)*sx,
                            (CGRectGetMidY(view.bounds)-localCrop.origin.y)*sy);
    CGRect visible=[self.producerHost convertRect:self.producerHost.bounds toView:self.phoneParent.window];
    visible=CGRectIntersection(visible,self.phoneParent.window.bounds);
    self.plan.producerVisibleArea=CGRectIsNull(visible)?0:visible.size.width*visible.size.height;
}
- (void)refresh {
    logPerformance(self.plan);
    UIView *view=self.coreView;
    UIWindow *external=externalWindow(view.window)?view.window:
        (view.superview==self.producerHost?self.externalTarget:nil);
    if(!external&&self.dual&&!self.disabled)for(UIWindow *candidate in displayWindows())
        if(externalWindow(candidate)&&!candidate.hidden){external=candidate;break;}
    if(self.dual&&!self.phoneParent.window)for(UIWindow *candidate in displayWindows()) {
        if(externalWindow(candidate)||candidate.hidden)continue;
        UIView *parent=phoneGameRoot(candidate.rootViewController);
        UIView *touchArea=parent?findTouchArea(parent):nil;
        if(!touchArea)continue;
        self.phoneParent=parent;self.phoneBounds=parent.bounds.size;
        self.phoneRegion=[touchArea convertRect:touchArea.bounds toView:parent];
        self.phoneLayout=canonicalScaled(self.threeDS,self.resolutionFactor);
        break;
    }
    BOOL connected=externalWindow(external)&&!external.hidden;
#ifndef MAS_TESTING
    connected=connected&&[UIScreen.screens containsObject:external.screen];
#endif
    BOOL active=self.dual&&!self.disabled&&connected&&self.phoneParent.window&&!CGRectIsEmpty(self.phoneRegion);
    if(!active) {
        BOOL wasActive=self.plan!=nil;
        [self removeSurfaces];
        if(wasActive && !externalWindow(external) && self.phoneLayout) {
            (self.threeDS?original3DS:originalNDS)(self.core,NSSelectorFromString(self.threeDS?@"set3DSCustomLayout:":@"setNDSCustomLayout:"),self.phoneLayout);
        }
        return;
    }
    CAMetalLayer *source=findLayer(view.layer);if(!source)return;
    if(view.superview!=self.producerHost) {
        // The original frontend moved this source onto the AirPlay screen. Its
        // nextDrawable/presentation pacing therefore still throttles emulation,
        // even when the snapshot queue drops frames. Keep the producer on the
        // phone screen; only our independent crop sink remains on AirPlay.
        self.externalSourceParent=view.superview;self.externalSourceFrame=view.frame;
        if(self.plan.source!=source) {
            self.originalProducerBounds=view.bounds;self.originalProducerAutoresizing=view.autoresizingMask;
            self.originalProducerTransform=view.transform;
            self.originalProducerTranslates=view.translatesAutoresizingMaskIntoConstraints;
        }
        self.externalTarget=external;
        [self.producerHost removeFromSuperview];self.producerHost=[UIView new];
        self.producerHost.userInteractionEnabled=NO;self.producerHost.clipsToBounds=YES;
        [self.phoneParent addSubview:self.producerHost];
        CGSize sourceSize=view.bounds.size;
        view.transform=CGAffineTransformIdentity;
        [self.producerHost addSubview:view];view.frame=(CGRect){CGPointZero,sourceSize};
        view.autoresizingMask=UIViewAutoresizingNone;
    }
    // The original frontend uses SnapKit with explicit phone width/height and
    // translatesAutoresizingMaskIntoConstraints=NO. Those self constraints can
    // remain active after reparenting, and a later host layout would replace
    // our native composite bounds/center after the crop was calculated.
    // Temporarily own only the producer root's outer geometry; its internal
    // render-view constraints remain active. Restore frontend ownership on exit.
    NSArray *activeSizes=producerSizeConstraints(view);
    if(activeSizes.count) {
        NSMutableArray *suspended=[self.suspendedProducerConstraints mutableCopy]?:[NSMutableArray new];
        for(NSLayoutConstraint *constraint in activeSizes)if(![suspended containsObject:constraint])[suspended addObject:constraint];
        self.suspendedProducerConstraints=suspended;
        [NSLayoutConstraint deactivateConstraints:activeSizes];
    }
    view.translatesAutoresizingMaskIntoConstraints=YES;
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
    NSArray *dimensions=[effective componentsSeparatedByString:@","];
    CGSize composite=CGSizeMake([dimensions[8] doubleValue],[dimensions[9] doubleValue]);
    // Both original drivers derive their final viewport from this view's bounds.
    // Vulkan uses the cached cocoa native scale; Metal uses main-screen scale.
    // Set the producer's geometry to the real composite pixels, before
    // either driver rasterizes. Upscaling its already-rendered snapshot is too late.
    const char *ident=driverIdent?driverIdent():NULL;
    CGFloat renderScale=(ident&&!strcmp(ident,"metal"))?UIScreen.mainScreen.scale:
        (driverNativeScale?driverNativeScale():UIScreen.mainScreen.nativeScale);
    if(!isfinite(renderScale)||renderScale<=0)renderScale=UIScreen.mainScreen.scale?:1;
    CGSize producerSize=CGSizeMake(composite.width/renderScale,composite.height/renderScale);
    if(!CGSizeEqualToSize(view.bounds.size,producerSize)){
        view.bounds=(CGRect){CGPointZero,producerSize};[view setNeedsLayout];
    }
    [view layoutIfNeeded];
    self.lastProducerBounds=view.bounds;
    if(!CGSizeEqualToSize(source.drawableSize,composite))source.drawableSize=composite;
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
    // iPhone MoltenVK makes swapchain images reusable from the source drawable's
    // presented callback; Simulator does not take that path. A clipped/occluded
    // 1x1 producer can exhaust native presentation while audio and UI continue.
    // Keep the real producer visible as the intended phone crop. Render bounds
    // retain native pixels; only UIKit display geometry scales and crops them.
    // The phone surface only supplies touch/letterboxing beneath the live source.
    [self updateProducerGeometry];
    [self.phoneParent bringSubviewToFront:self.producerHost];
    self.externalSurface.frame=external.bounds;
    self.swapButton.frame=CGRectMake(MAX(0,CGRectGetMaxX(self.phoneSurface.frame)-164),
                                     MAX(self.phoneParent.safeAreaInsets.top,CGRectGetMinY(self.phoneSurface.frame)-38),164,34);
    [self.swapButton setTitle:self.swapped?@"Swap Â· TV touchpad":@"Swap screens" forState:UIControlStateNormal];
    [self.phoneSurface setNeedsLayout];[self.externalSurface setNeedsLayout];
    [self.phoneParent bringSubviewToFront:self.swapButton];
    MASPlan *old=self.plan;
    CGRect visible=[self.producerHost convertRect:self.producerHost.bounds toView:self.phoneParent.window];
    visible=CGRectIntersection(visible,self.phoneParent.window.bounds);
    double visibleArea=CGRectIsNull(visible)?0:visible.size.width*visible.size.height;
    if(old.source==source&&old.swapped==self.swapped&&old.threeDS==self.threeDS){old.compositeSize=composite;old.producerVisibleArea=visibleArea;return;}
    MASPlan *p=[MASPlan new];p.source=source;p.phone=(CAMetalLayer *)self.phoneSurface.layer;
    p.external=(CAMetalLayer *)self.externalSurface.layer;p.threeDS=self.threeDS;p.swapped=self.swapped;
    p.directPhone=YES;
    p.phoneSink=[MASSink new];p.phoneSink.phone=YES;p.phoneSink.layer=p.phone;
    p.phoneSink.queue=dispatch_queue_create("org.manicemu.airplay.phone",DISPATCH_QUEUE_SERIAL);
    p.tvSink=[MASSink new];p.tvSink.layer=p.external;
    p.tvSink.queue=dispatch_queue_create("org.manicemu.airplay.tv",DISPATCH_QUEUE_SERIAL);
    p.displayQueue=p.tvSink.queue;p.compositeSize=composite;p.externalModeSize=external.screen.currentMode.size;
    p.producerVisibleArea=visibleArea;
    p.snapshotSlots=dispatch_semaphore_create(3);p.freeSnapshots=[NSMutableArray new];
    p.originalFramebufferOnly=old.source==source?old.originalFramebufferOnly:source.framebufferOnly;
    self.plan=p;self.liveViewportSequence=0;
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
static void observeResolution(NSDictionary *configs) {
    NSString *value=configs[@"citra_resolution_factor"];
    BOOL threeDS=value!=nil;
    if(!value&&configs[@"desmume_internal_resolution"]){
        NSArray *size=[configs[@"desmume_internal_resolution"] componentsSeparatedByString:@"x"];
        if(size.count==2)value=[NSString stringWithFormat:@"%ld",MAX(1,[size[0] integerValue]/256)];
    }
    if(value)onMain(^{MASManager *m=MASManager.shared;NSUInteger factor=MAX(1,MIN(10,value.integerValue));
        if(threeDS)m.last3DSResolutionFactor=factor;else m.lastDSResolutionFactor=factor;
        if(m.threeDS==threeDS){m.resolutionFactor=factor;[m refresh];}
    });
}
static void masConfigs(id self,SEL cmd,NSDictionary *configs,BOOL flush) {
    originalConfigs(self,cmd,configs,flush);observeResolution(configs);
}
static void masStoredConfigs(id self,SEL cmd,id coreName,NSDictionary *configs,BOOL reload) {
    originalStoredConfigs(self,cmd,coreName,configs,reload);observeResolution(configs);
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
static void presentSnapshot(MASFrame *frame,MASSink *sink) {
            MASPlan *live=frame.owner;
            MASManager *m=MASManager.shared;
            if(m.plan!=live)return;
            double sinkStart=CACurrentMediaTime();
            id<CAMetalDrawable> drawable=[sink.layer nextDrawable];
            @synchronized(live){sink.waitMax=MAX(sink.waitMax,CACurrentMediaTime()-sinkStart);live.sinkWaitMax=MAX(live.sinkWaitMax,sink.waitMax);}
            if(!drawable||m.plan!=live)return;
            // nextDrawable can wait for a slow display. Replace the selected
            // frame with the newest completed capture before encoding any crop.
            MASFrame *newest;
            @synchronized(sink){newest=sink.pending;sink.pending=nil;
                if(newest)sink.submittedSequence=newest.sequence;}
            if(newest){@synchronized(live){sink.superseded++;}frame=newest;}
            id<MTLTexture> texture=frame.texture;MASViewport vp=frame.viewport;
            CGRect region=CGRectMake((CGFloat)vp.x/texture.width,(CGFloat)vp.y/texture.height,
                                     (CGFloat)vp.width/texture.width,(CGFloat)vp.height/texture.height);
            CGRect top=region,bottom=region;
            top.size.height*=0.5;bottom.origin.y+=bottom.size.height*0.5;bottom.size.height*=0.5;
            if(live.threeDS){bottom.origin.x+=bottom.size.width*0.1;bottom.size.width*=0.8;}
            if(!sink.commandQueue)sink.commandQueue=[texture.device newCommandQueue];
            id<MTLCommandBuffer> buffer=[sink.commandQueue commandBuffer];
            CGSize topSize=live.threeDS?CGSizeMake(400,240):CGSizeMake(256,192);
            CGSize bottomSize=live.threeDS?CGSizeMake(320,240):CGSizeMake(256,192);
            BOOL showTop=sink.phone?live.swapped:!live.swapped;
            if(!MASDrawCrop(buffer,texture,drawable.texture,showTop?top:bottom,showTop?topSize:bottomSize))return;
#ifdef MAS_TESTING
            id<MTLBuffer> readbackPixel=[texture.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> readback=[buffer blitCommandEncoder];
            [readback copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(drawable.texture.width/2,drawable.texture.height/2,0)
                           sourceSize:MTLSizeMake(1,1,1) toBuffer:readbackPixel destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
            [readback endEncoding];
#endif
            [buffer presentDrawable:drawable];
            double age=CACurrentMediaTime()-frame.capturedAt;
            @synchronized(live){sink.ageLast=age;sink.ageMax=MAX(sink.ageMax,age);}
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
                // Retain the shared snapshot until this sink's GPU use ends.
                // Its final reader returns the texture to the bounded pool.
                @synchronized(live){if(finished.status==MTLCommandBufferStatusCompleted){
                    live.presentations++;sink.presentations++;sink.lastSequence=MAX(sink.lastSequence,frame.sequence);}}
                dispatch_async(dispatch_get_main_queue(),^{
                    if(m.plan!=live||finished.status!=MTLCommandBufferStatusCompleted)return;
                    if(sink.phone){m.liveViewport=CGRectMake(vp.x,vp.y,vp.width,vp.height);m.phoneSurface.hidden=NO;}
                    else m.externalSurface.hidden=NO;
#ifdef MAS_TESTING
                    masPresentedFrames++;
                    if(sink.phone)masPresentedPhonePixel=*(uint32_t *)readbackPixel.contents;
                    else masPresentedTVPixel=*(uint32_t *)readbackPixel.contents;
#endif
                });
            }];
            [buffer commit];
}
static void publishFrame(MASFrame *frame,MASSink *sink) {
    MASFrame *replaced;BOOL start=NO;
    @synchronized(sink){
        if(frame.sequence<=sink.submittedSequence||frame.sequence<=sink.pending.sequence){
            @synchronized(frame.owner){sink.superseded++;}return;
        }
        replaced=sink.pending;sink.pending=frame;
        if(!sink.scheduled){sink.scheduled=YES;start=YES;}
    }
    if(replaced){@synchronized(frame.owner){sink.superseded++;}replaced=nil;}
    if(start)dispatch_async(sink.queue,^{
        for(;;){@autoreleasepool {
            MASFrame *ready;
            @synchronized(sink){ready=sink.pending;sink.pending=nil;
                if(!ready){sink.scheduled=NO;return;}
                sink.submittedSequence=ready.sequence;}
            presentSnapshot(ready,sink);
        }}
    });
}
static void captureFrameTexture(id<CAMetalDrawable> drawable,CAMetalLayer *layer,id<MTLCommandBuffer> producer,id<MTLTexture> acquiredTexture) {
    MASPlan *plan=MASManager.shared.plan;
    if(plan.source!=layer)return;
    id<MTLTexture> source=acquiredTexture?:drawable.texture;
    // A connection can arrive while a drawable acquired with the previous
    // framebuffer-only setting is still in flight. It may present normally,
    // but cannot be sampled or copied. Capture the next readable drawable.
    if(!source||source.framebufferOnly){@synchronized(plan){plan.dropped++;}return;}
    if(dispatch_semaphore_wait(plan.snapshotSlots,DISPATCH_TIME_NOW)!=0) {
        @synchronized(plan){plan.dropped++;}
#ifdef MAS_TESTING
        masSnapshotsSkipped++;
#endif
        return;
    }
    double copyStart=CACurrentMediaTime();
    @synchronized(plan){plan.snapshots++;plan.inflight++;plan.peakInflight=MAX(plan.peakInflight,plan.inflight);}
    id<MTLTexture> snapshot=nil;
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
    __block unsigned sequence;
    @synchronized(plan){plan.sourceWidth=(unsigned)source.width;plan.sourceHeight=(unsigned)source.height;
        plan.viewportWidth=vp.width;plan.viewportHeight=vp.height;sequence=++plan.sequence;
        // Also support the isolated blocked-queue test plan.
        if(!plan.phoneSink){plan.phoneSink=[MASSink new];plan.phoneSink.phone=YES;plan.phoneSink.layer=plan.phone;
            plan.phoneSink.queue=dispatch_queue_create("org.manicemu.airplay.phone",DISPATCH_QUEUE_SERIAL);}
        if(!plan.tvSink){plan.tvSink=[MASSink new];plan.tvSink.layer=plan.external;plan.tvSink.queue=plan.displayQueue;}}
    @synchronized(plan){if(!plan.presentationQueue)plan.presentationQueue=[source.device newCommandQueue];}
    id<MTLCommandBuffer> buffer=producer?:[plan.presentationQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[buffer blitCommandEncoder];
    if(!blit){recycleSnapshot(plan,snapshot);return;}
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:snapshot destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
#ifdef MAS_TESTING
    // The phone now displays the native drawable itself. Read its selected crop
    // center to validate source pixels together with the UIKit crop geometry.
    id<MTLBuffer> nativePhonePixel=nil;
    if(plan.directPhone) {
        nativePhonePixel=[source.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(vp.x+vp.width/2,vp.y+vp.height*(plan.swapped?1:3)/4,0)
            sourceSize:MTLSizeMake(1,1,1) toBuffer:nativePhonePixel destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    }
#endif
    [blit endEncoding];
    @synchronized(plan){plan.copyEncodeMax=MAX(plan.copyEncodeMax,CACurrentMediaTime()-copyStart);}
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        @synchronized(plan){plan.copyCompletionMax=MAX(plan.copyCompletionMax,CACurrentMediaTime()-copyStart);}
        // Retain the source only through this GPU copy, never through sink waits.
        (void)drawable;
        if(finished.status!=MTLCommandBufferStatusCompleted){recycleSnapshot(plan,snapshot);return;}
        MASFrame *frame=[MASFrame new];frame.owner=plan;frame.texture=snapshot;
        frame.viewport=vp;frame.sequence=sequence;frame.capturedAt=copyStart;
        if(plan.directPhone) {
            @synchronized(plan){plan.directPhoneCaptures++;}
            dispatch_async(dispatch_get_main_queue(),^{
                MASManager *manager=MASManager.shared;
                if(manager.plan!=plan||sequence<manager.liveViewportSequence)return;
                CGRect viewport=CGRectMake(vp.x,vp.y,vp.width,vp.height);
                CGSize sourceSize=CGSizeMake(snapshot.width,snapshot.height);
                BOOL changed=manager.liveViewportSource!=layer||!CGRectEqualToRect(manager.liveViewport,viewport)||
                    !CGSizeEqualToSize(manager.liveSourceSize,sourceSize);
                manager.liveViewportSequence=sequence;
                manager.liveViewport=viewport;manager.liveSourceSize=sourceSize;manager.liveViewportSource=layer;
                if(changed)[manager updateProducerGeometry];
                manager.phoneSurface.hidden=NO;
#ifdef MAS_TESTING
                masPresentedPhonePixel=*(uint32_t *)nativePhonePixel.contents;
#endif
            });
        } else publishFrame(frame,plan.phoneSink);
        publishFrame(frame,plan.tvSink);
    }];
    if(!producer)[buffer commit];
}
static void captureFrame(id<CAMetalDrawable> drawable,CAMetalLayer *layer,id<MTLCommandBuffer> producer) {
    captureFrameTexture(drawable,layer,producer,nil);
}
static void recordScheduledPresentation(id<CAMetalDrawable> drawable) {
    CAMetalLayer *layer=objc_getAssociatedObject(drawable,sourceKey);
    if(!layer||!MASManager.shared.plan)return;
    id<MTLCommandBuffer> buffer=(__bridge id)scheduledBuffer;
    NSMutableArray *frames=buffer?objc_getAssociatedObject(buffer,framesKey):nil;
    if(!frames||layer!=MASManager.shared.plan.source||[objc_getAssociatedObject(drawable,encodedKey) boolValue])return;
    objc_setAssociatedObject(drawable,encodedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Read the texture before present. iOS forbids retrieving drawable.texture
    // after presentation; the saved texture remains retained through GPU copy.
    @synchronized(frames){[frames addObject:@{@"drawable":drawable,@"source":layer,@"texture":drawable.texture}];}
}
static void masPresent(id self,SEL cmd) {recordScheduledPresentation(self);originalPresent(self,cmd);}
static void masPresentAtTime(id self,SEL cmd,CFTimeInterval t) {recordScheduledPresentation(self);originalPresentAtTime(self,cmd,t);}
static void masScheduled(id self,SEL cmd,MTLCommandBufferHandler action) {
    if(!MASManager.shared.plan){originalScheduled(self,cmd,action);return;}
    if(!objc_getAssociatedObject(self,framesKey)&&MASManager.shared.plan) {
        NSMutableArray *frames=[NSMutableArray new];objc_setAssociatedObject(self,framesKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            NSArray *pending=objc_getAssociatedObject(finished,framesKey);
            if(finished.status==MTLCommandBufferStatusCompleted)for(NSDictionary *frame in pending)
                captureFrameTexture(frame[@"drawable"],frame[@"source"],nil,frame[@"texture"]);
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
        id<MTLTexture> acquiredTexture=drawable.texture;
        if([drawable respondsToSelector:selector])((void(*)(id,SEL,void(^)(id<MTLDrawable>)))objc_msgSend)(drawable,selector,^(id<MTLDrawable> value) {
            @synchronized(p){p.sourcePresentedCallbacks++;}
            if([objc_getAssociatedObject(value,encodedKey) boolValue])return;
            objc_setAssociatedObject(value,encodedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            captureFrameTexture((id)value,layer,nil,acquiredTexture);
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
static void prepareExistingPluginFolders(void) {
    // The original core scans uppercase title IDs. Keep every user's original
    // folder and file; provide a missing uppercase copy without overwriting it.
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *root=[documents stringByAppendingPathComponent:@"3DS/sdmc/luma/plugins"];
    NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for(NSString *name in [files contentsOfDirectoryAtPath:root error:nil]) {
        if(name.length!=16||[name rangeOfCharacterFromSet:hex.invertedSet].location!=NSNotFound)continue;
        NSString *upper=name.uppercaseString;if([upper isEqualToString:name])continue;
        NSString *source=[root stringByAppendingPathComponent:name],*target=[root stringByAppendingPathComponent:upper];
        NSDictionary *attributes=[files attributesOfItemAtPath:source error:nil];
        if(![attributes[NSFileType] isEqual:NSFileTypeDirectory]||[files fileExistsAtPath:target])continue;
        BOOL plugin=NO;
        for(NSString *entry in [files contentsOfDirectoryAtPath:source error:nil])
            if([entry.pathExtension isEqualToString:@"3gx"]) {plugin=YES;break;}
        if(plugin)[files copyItemAtPath:source toPath:target error:nil];
    }
}
static void install(void) {
    if(![NSBundle.mainBundle.infoDictionary[@"MASInjectAirPlaySplit"] boolValue])return;
    prepareExistingPluginFolders();
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
    originalStoredConfigs=(void *)replace(core,@"updateCoreConfig:configs:reload:",(IMP)masStoredConfigs,5);
    originalDrawable=(void *)replace(context,@"nextDrawable",(IMP)masDrawable,2);
    originalEnd=(void *)replace(context,@"end",(IMP)masEnd,2);
    originalLayerDrawable=(void *)replace(CAMetalLayer.class,@"nextDrawable",(IMP)masLayerDrawable,2);
    driverViewport=(void *)dlsym(RTLD_DEFAULT,"video_driver_get_viewport_info");
    driverNativeScale=(void *)dlsym(RTLD_DEFAULT,"cocoa_screen_get_native_scale");
    driverIdent=(void *)dlsym(RTLD_DEFAULT,"video_driver_get_ident");
    MASManager *m=MASManager.shared;
    m.timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:m selector:@selector(refresh) userInfo:nil repeats:YES];
    for(NSString *name in @[UIApplicationDidBecomeActiveNotification,UISceneDidActivateNotification,
                           UISceneWillConnectNotification,UISceneDidDisconnectNotification])
        [NSNotificationCenter.defaultCenter addObserver:m selector:@selector(sceneChanged:) name:name object:nil];
}
__attribute__((constructor)) static void boot(void) {dispatch_async(dispatch_get_main_queue(),^{install();});}
