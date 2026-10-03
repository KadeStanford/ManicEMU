// SPDX-License-Identifier: AGPL-3.0-or-later
// Optional overlay for the original Manic/RetroArch Metal renderer. The emulator
// produces one frame; both displays sample it on that same command buffer.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "MASRender.h"

typedef struct { int x,y; unsigned width,height,full_width,full_height; } MASViewport;
static UIViewController *(*originalStart)(id,SEL,id);
static BOOL (*originalLoad)(id,SEL,id,id,id);
static void (*originalStop)(id,SEL);
static void (*originalNDS)(id,SEL,id);
static void (*original3DS)(id,SEL,id);
static void (*originalTouch)(id,SEL,CGFloat,CGFloat);
static void (*originalEnd)(id,SEL);
static id (*originalDrawable)(id,SEL);
static Ivar layerIvar,drawableIvar,bufferIvar,encoderIvar;

@interface MASPlan : NSObject
@property(strong) CAMetalLayer *source,*phone,*external;
@property BOOL threeDS,swapped,originalFramebufferOnly;
@end
@implementation MASPlan @end

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
static NSString *canonical(BOOL threeDS) {
    return threeDS?@"0,0,400,240,40,240,320,240,400,480":@"0,0,256,192,0,192,256,192,256,384";
}

@implementation MASSurface
+ (Class)layerClass {return CAMetalLayer.class;}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *layer=(CAMetalLayer *)self.layer;
    CGFloat scale=self.window.screen.scale?:UIScreen.mainScreen.scale;
    layer.contentsScale=scale;
    layer.drawableSize=CGSizeMake(MAX(1,self.bounds.size.width*scale),MAX(1,self.bounds.size.height*scale));
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
    self.inputRegion=CGRectZero;self.liveViewport=CGRectZero;
}
- (void)layout:(NSString *)layout threeDS:(BOOL)threeDS {
    NSAssert(NSThread.isMainThread,@"Layout must run on the UI thread");
    self.threeDS=threeDS; self.dual=layout!=nil; self.requestedLayout=layout;
    NSArray *parts=[layout componentsSeparatedByString:@","];
    if(parts.count!=10) {self.dual=NO;[self removeSurfaces];return;}
    CGFloat v[10];for(int i=0;i<10;i++) {v[i]=[parts[i] doubleValue];if(!isfinite(v[i])){self.dual=NO;[self removeSurfaces];return;}}
    if(v[8]<=0||v[9]<=0) {self.dual=NO;[self removeSurfaces];return;}
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
        (self.threeDS?original3DS:originalNDS)(self.core,NSSelectorFromString(self.threeDS?@"set3DSCustomLayout:":@"setNDSCustomLayout:"),canonical(self.threeDS));
    }
    CGSize bounds=self.phoneParent.bounds.size;
    CGFloat sx=self.phoneBounds.width>0?bounds.width/self.phoneBounds.width:1;
    CGFloat sy=self.phoneBounds.height>0?bounds.height/self.phoneBounds.height:1;
    CGRect r=self.phoneRegion;r.origin.x*=sx;r.origin.y*=sy;r.size.width*=sx;r.size.height*=sy;
    self.phoneSurface.frame=CGRectIntersection(self.phoneParent.bounds,r);
    self.externalSurface.frame=external.bounds;
    self.swapButton.frame=CGRectMake(MAX(0,CGRectGetMaxX(self.phoneSurface.frame)-164),
                                     MAX(self.phoneParent.safeAreaInsets.top,CGRectGetMinY(self.phoneSurface.frame)-38),164,34);
    [self.swapButton setTitle:self.swapped?@"Swap · TV touchpad":@"Swap screens" forState:UIControlStateNormal];
    [self.phoneSurface setNeedsLayout];[self.externalSurface setNeedsLayout];
    MASPlan *old=self.plan;
    if(old.source==source&&old.swapped==self.swapped&&old.threeDS==self.threeDS)return;
    MASPlan *p=[MASPlan new];p.source=source;p.phone=(CAMetalLayer *)self.phoneSurface.layer;
    p.external=(CAMetalLayer *)self.externalSurface.layer;p.threeDS=self.threeDS;p.swapped=self.swapped;
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
    onMain(^{MASManager *m=MASManager.shared;m.core=self;[m layout:layout threeDS:threeDS];if(m.plan)effective=canonical(threeDS);});
    (threeDS?original3DS:originalNDS)(self,cmd,effective);
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
static void masEnd(id self,SEL cmd) {
    MASManager *m=MASManager.shared;MASPlan *p=m.plan;
    CAMetalLayer *layer=object_getIvar(self,layerIvar);
    id<CAMetalDrawable> drawable=object_getIvar(self,drawableIvar);
    id<MTLCommandBuffer> buffer=object_getIvar(self,bufferIvar);
    if(p.source==layer&&drawable&&buffer&&!layer.framebufferOnly) {
        MASViewport *vp=((MASViewport *(*)(id,SEL))objc_msgSend)(self,NSSelectorFromString(@"viewport"));
        id<MTLRenderCommandEncoder> encoder=object_getIvar(self,encoderIvar);
        if(encoder){[encoder endEncoding];object_setIvar(self,encoderIvar,nil);}
        CGRect normalized=CGRectMake((CGFloat)vp->x/drawable.texture.width,(CGFloat)vp->y/drawable.texture.height,
                                      (CGFloat)vp->width/drawable.texture.width,(CGFloat)vp->height/drawable.texture.height);
        CGRect top=normalized,bottom=normalized;
        top.size.height*=0.5;bottom.origin.y+=bottom.size.height*0.5;bottom.size.height*=0.5;
        if(p.threeDS){bottom.origin.x+=bottom.size.width*0.1;bottom.size.width*=0.8;}
        id<CAMetalDrawable> phone=[p.phone nextDrawable],external=[p.external nextDrawable];
        CGSize topSize=p.threeDS?CGSizeMake(400,240):CGSizeMake(256,192);
        CGSize bottomSize=p.threeDS?CGSizeMake(320,240):CGSizeMake(256,192);
        BOOL good=phone&&external&&MASDrawCrop(buffer,drawable.texture,phone.texture,p.swapped?top:bottom,p.swapped?topSize:bottomSize)&&
                                      MASDrawCrop(buffer,drawable.texture,external.texture,p.swapped?bottom:top,p.swapped?bottomSize:topSize);
        if(good) {
            CGRect live=CGRectMake(vp->x,vp->y,vp->width,vp->height);
            [buffer presentDrawable:phone];[buffer presentDrawable:external];
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished){
                dispatch_async(dispatch_get_main_queue(),^{
                    if(m.plan!=p)return;
                    if(finished.status==MTLCommandBufferStatusCompleted){m.liveViewport=live;m.phoneSurface.hidden=NO;m.externalSurface.hidden=NO;}
                    else {m.disabled=YES;[m removeSurfaces];(m.threeDS?original3DS:originalNDS)(m.core,NSSelectorFromString(m.threeDS?@"set3DSCustomLayout:":@"setNDSCustomLayout:"),m.requestedLayout);}
                });
            }];
        }
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
    originalDrawable=(void *)replace(context,@"nextDrawable",(IMP)masDrawable,2);
    originalEnd=(void *)replace(context,@"end",(IMP)masEnd,2);
    MASManager *m=MASManager.shared;
    m.timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:m selector:@selector(refresh) userInfo:nil repeats:YES];
}
__attribute__((constructor)) static void boot(void) {dispatch_async(dispatch_get_main_queue(),^{install();});}
