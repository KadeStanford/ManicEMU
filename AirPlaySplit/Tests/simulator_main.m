// Synthetic UIKit/Metal integration. Does not claim physical AirPlay validation.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <assert.h>
#define MAS_TESTING 1
#import "../iOS/ManicAirPlaySplit.m"

static NSString *lastLayout;
static unsigned loads,stops,ends,touches,releases,storedConfigCalls;
static CGPoint touchPoint;
static MASViewport testViewport;
static BOOL useTestViewport;
bool video_driver_get_viewport_info(MASViewport *viewport) {
    if(useTestViewport)*viewport=testViewport;
    return true;
}
float cocoa_screen_get_native_scale(void){return UIScreen.mainScreen.nativeScale;}
const char *video_driver_get_ident(void){return "vulkan";}
static void check(NSString *key,BOOL passed);
@interface LibretroCore : NSObject
@property(strong) UIViewController *vc;
+ (instancetype)sharedInstance;
- (UIViewController *)startWithCustomSaveDir:(NSString *)save;
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion;
- (void)stop;
- (void)setNDSCustomLayout:(NSString *)layout;
- (void)set3DSCustomLayout:(NSString *)layout;
- (void)sendTouchEventX:(CGFloat)x y:(CGFloat)y;
- (void)releaseTouchEvent;
- (void)updateRunningCoreConfigs:(NSDictionary *)configs flush:(BOOL)flush;
- (void)updateCoreConfig:(NSString *)core configs:(NSDictionary *)configs reload:(BOOL)reload;
@end
@implementation LibretroCore
+ (instancetype)sharedInstance {static id v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (UIViewController *)startWithCustomSaveDir:(NSString *)save {
    self.vc=[UIViewController new];self.vc.view=[UIView new];
    MASSurface *render=[MASSurface new];render.translatesAutoresizingMaskIntoConstraints=NO;
    [self.vc.view addSubview:render];
    [NSLayoutConstraint activateConstraints:@[[render.topAnchor constraintEqualToAnchor:self.vc.view.topAnchor],
        [render.bottomAnchor constraintEqualToAnchor:self.vc.view.bottomAnchor],
        [render.leadingAnchor constraintEqualToAnchor:self.vc.view.leadingAnchor],
        [render.trailingAnchor constraintEqualToAnchor:self.vc.view.trailingAnchor]]];
    return self.vc;
}
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion {loads++;return YES;}
- (void)stop {stops++;}
- (void)setNDSCustomLayout:(NSString *)layout {lastLayout=[layout copy];}
- (void)set3DSCustomLayout:(NSString *)layout {lastLayout=[layout copy];}
- (void)sendTouchEventX:(CGFloat)x y:(CGFloat)y {touches++;touchPoint=CGPointMake(x,y);}
- (void)releaseTouchEvent {releases++;}
- (void)updateRunningCoreConfigs:(NSDictionary *)configs flush:(BOOL)flush {}
- (void)updateCoreConfig:(NSString *)core configs:(NSDictionary *)configs reload:(BOOL)reload {storedConfigCalls++;}
@end
@interface TestSourceDrawable : NSObject
@property(strong) id<MTLTexture> texture;
@property BOOL textureUnavailableAfterPresent;
@property unsigned forbiddenTextureReads;
@end
@implementation TestSourceDrawable
@synthesize texture=_texture;
- (id<MTLTexture>)texture {
    if(self.textureUnavailableAfterPresent){self.forbiddenTextureReads++;return nil;}
    return _texture;
}
@end
@interface Context : NSObject {
    CAMetalLayer *_layer;
    id<CAMetalDrawable> _drawable;
    id<MTLCommandBuffer> _commandBuffer;
    id<MTLRenderCommandEncoder> _rce;
    MASViewport _viewport;
}
- (void)end;
- (id)nextDrawable;
- (MASViewport *)viewport;
- (id<MTLCommandBuffer>)prepare:(CAMetalLayer *)layer;
@end
@implementation Context
- (void)end {
    check(@"existing_encoder_ended_exactly_once",_rce==nil);
    [_commandBuffer commit];[_commandBuffer waitUntilCompleted];ends++;
}
- (id)nextDrawable {return _drawable;}
- (MASViewport *)viewport {return &_viewport;}
- (id<MTLCommandBuffer>)prepare:(CAMetalLayer *)layer {
    _layer=layer;_layer.device=MTLCreateSystemDefaultDevice();
    _commandBuffer=[[_layer.device newCommandQueue] commandBuffer];
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:384 mipmapped:NO];
    desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    TestSourceDrawable *d=[TestSourceDrawable new];d.texture=[_layer.device newTextureWithDescriptor:desc];_drawable=(id)d;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
    _rce=[_commandBuffer renderCommandEncoderWithDescriptor:pass];
    _viewport=(MASViewport){0,0,256,384,256,384};return _commandBuffer;
}
@end
@interface ExternalWindow : UIWindow @end
@implementation ExternalWindow @end
@interface TestTouchInputView : UIView @end
@implementation TestTouchInputView @end
@interface GameView : UIView @end
@implementation GameView @end

// Exercise MoltenVK's public presentation pattern without calling Context end.
static void presentWithoutContext(CAMetalLayer *layer) {
    layer.device=MTLCreateSystemDefaultDevice();
    unsigned width=(unsigned)layer.drawableSize.width,height=(unsigned)layer.drawableSize.height;
    id<CAMetalDrawable> drawable=[layer nextDrawable];
    check(@"swapchain_drawable_available",drawable!=nil);
    id<MTLCommandBuffer> buffer=[[layer.device newCommandQueue] commandBuffer];
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
    id<MTLTexture> pattern=[layer.device newTextureWithDescriptor:desc];
    NSMutableData *pixels=[NSMutableData dataWithLength:width*height*4];uint8_t *b=pixels.mutableBytes;
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
        unsigned i=(y*width+x)*4;b[i]=y<height/2?255:0;b[i+1]=y<height/2?0:255;b[i+3]=255;
    }
    [pattern replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:b bytesPerRow:width*4];
    check(@"swapchain_test_pattern_encoded",MASDrawCrop(buffer,pattern,drawable.texture,CGRectMake(0,0,1,1),CGSizeMake(width,height)));
    [buffer addScheduledHandler:^(id<MTLCommandBuffer> _) {[drawable present];}];
    [buffer commit];
}

static NSMutableDictionary *report;
static void check(NSString *key,BOOL passed){report[key]=@(passed);NSLog(@"%@ = %d",key,passed);}
static BOOL closeRect(CGRect a,CGRect b) {
    return fabs(a.origin.x-b.origin.x)<0.001&&fabs(a.origin.y-b.origin.y)<0.001&&
        fabs(a.size.width-b.size.width)<0.001&&fabs(a.size.height-b.size.height)<0.001;
}
static void constrainedRootControl(void) {
    UIView *parent=[[UIView alloc] initWithFrame:CGRectMake(0,0,500,600)];
    UIView *producer=[[UIView alloc] initWithFrame:CGRectMake(0,0,320,480)];
    producer.translatesAutoresizingMaskIntoConstraints=NO;[parent addSubview:producer];
    NSArray *sizes=@[[producer.widthAnchor constraintEqualToConstant:320],[producer.heightAnchor constraintEqualToConstant:480]];
    [NSLayoutConstraint activateConstraints:sizes];
    producer.bounds=CGRectMake(0,0,400.0/3,480.0/3);producer.center=CGPointMake(120,0);
    [parent setNeedsLayout];[parent layoutIfNeeded];
    check(@"control_active_root_size_constraints_replace_manual_composite_bounds",CGSizeEqualToSize(producer.bounds.size,CGSizeMake(320,480)));
    [producer removeFromSuperview];
    check(@"control_reparent_keeps_root_self_size_constraints_active",((NSLayoutConstraint *)sizes[0]).active&&((NSLayoutConstraint *)sizes[1]).active);
}
static void checkViewportGeometry(MASManager *m,NSString *prefix) {
    CAMetalLayer *layer=m.plan.source;CGSize pixels=m.liveSourceSize;CGRect vp=m.liveViewport;
    CGRect selected=vp;selected.size.height*=0.5;
    if(!m.swapped){selected.origin.y+=selected.size.height;
        if(m.threeDS){selected.origin.x+=selected.size.width*0.1;selected.size.width*=0.8;}}
    CGRect local=CGRectMake(layer.bounds.origin.x+selected.origin.x/pixels.width*layer.bounds.size.width,
        layer.bounds.origin.y+selected.origin.y/pixels.height*layer.bounds.size.height,
        selected.size.width/pixels.width*layer.bounds.size.width,selected.size.height/pixels.height*layer.bounds.size.height);
    CGRect displayed=[layer convertRect:local toLayer:m.producerHost.layer];
    check([prefix stringByAppendingString:@"_selected_actual_layer_crop_fills_phone_host"],closeRect(displayed,m.producerHost.bounds));
    CGSize aspect=m.threeDS?CGSizeMake(m.swapped?400:320,240):CGSizeMake(256,192);
    CGRect fit=MASFit(aspect,m.phoneSurface.bounds.size);
    check([prefix stringByAppendingString:@"_host_clips_at_fitted_crop_not_skin_letterbox"],
        m.producerHost.clipsToBounds&&closeRect(m.producerHost.frame,CGRectOffset(fit,m.phoneSurface.frame.origin.x,m.phoneSurface.frame.origin.y)));
    check([prefix stringByAppendingString:@"_producer_remains_native_visible"],
        m.producerHost.window==m.phoneParent.window&&m.plan.producerVisibleArea>10000&&m.plan.directPhone);
}
static void viewportCaptureCheck(MASManager *m,dispatch_block_t completion) {
    // Model the reported phone symptom: the rendered composite is inset in a
    // larger source texture, and the Metal layer itself is nested/offset. The
    // actual completed texture dimensions differ from requested drawableSize.
    [LibretroCore.sharedInstance set3DSCustomLayout:canonicalScaled(YES,1)];
    if(m.swapped)[m swap];
    CAMetalLayer *layer=m.plan.source;layer.device=MTLCreateSystemDefaultDevice();
    CGRect savedBounds=layer.bounds;CGPoint savedPosition=layer.position;
    layer.bounds=CGRectMake(7,11,150,220);layer.position=CGPointMake(95,130);
    unsigned width=800,height=1000;MASViewport vp={80,180,600,720,800,1000};
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;desc.storageMode=MTLStorageModeShared;
    TestSourceDrawable *drawable=[TestSourceDrawable new];drawable.texture=[layer.device newTextureWithDescriptor:desc];
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4];uint8_t *p=data.mutableBytes;
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
        unsigned i=(y*width+x)*4;p[i+3]=255;
        if(x>=(unsigned)vp.x&&x<(unsigned)vp.x+vp.width&&y>=(unsigned)vp.y&&y<(unsigned)vp.y+vp.height)
            p[i+(y<(unsigned)vp.y+vp.height/2?2:1)]=255;
    }
    [drawable.texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:p bytesPerRow:width*4];
    testViewport=vp;useTestViewport=YES;
    id<MTLCommandBuffer> buffer=[[layer.device newCommandQueue] commandBuffer];
    captureFrameTexture((id)drawable,layer,buffer,drawable.texture);
    useTestViewport=NO;
    // The production completion handler queues geometry on main before this
    // sentinel. No driver viewport is injected into manager state directly.
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        dispatch_async(dispatch_get_main_queue(),^{
            check(@"completed_frame_records_offset_viewport_and_actual_source_dimensions",
                finished.status==MTLCommandBufferStatusCompleted&&closeRect(m.liveViewport,CGRectMake(80,180,600,720))&&
                CGSizeEqualToSize(m.liveSourceSize,CGSizeMake(800,1000)));
            checkViewportGeometry(m,@"offset_nested_bottom");
            CGRect bottomShown=[layer convertRect:CGRectMake(layer.bounds.origin.x+0.175*layer.bounds.size.width,
                layer.bounds.origin.y+0.54*layer.bounds.size.height,0.6*layer.bounds.size.width,0.36*layer.bounds.size.height) toLayer:m.producerHost.layer];
            check(@"completed_frame_uses_viewport_before_timer_refresh",closeRect(bottomShown,m.producerHost.bounds));
            CGRect topShown=[layer convertRect:CGRectMake(layer.bounds.origin.x+0.1*layer.bounds.size.width,
                layer.bounds.origin.y+0.18*layer.bounds.size.height,0.75*layer.bounds.size.width,0.36*layer.bounds.size.height) toLayer:m.producerHost.layer];
            check(@"phone_bottom_crop_excludes_other_screen_even_in_letterbox",CGRectIsEmpty(CGRectIntersection(topShown,m.producerHost.bounds)));
            [m touch:CGPointMake(0.25,0.75)];
            check(@"offset_completed_viewport_preserves_native_bottom_touch_coordinates",
                fabs(touchPoint.x*UIScreen.mainScreen.nativeScale-260)<0.001&&fabs(touchPoint.y*UIScreen.mainScreen.nativeScale-810)<0.001);
            [m swap];checkViewportGeometry(m,@"offset_nested_swapped_top");
            [m swap];checkViewportGeometry(m,@"offset_nested_repeated_bottom");
            layer.bounds=savedBounds;layer.position=savedPosition;
            // Reconcile the same remembered viewport against current UIKit
            // geometry after a foreground/skin refresh.
            [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
            [m refresh];checkViewportGeometry(m,@"offset_viewport_foreground");
            CGRect parentBounds=m.phoneParent.bounds;
            UIView *touchArea=findTouchArea(m.phoneParent);CGRect touchFrame=touchArea.frame;
            m.phoneParent.bounds=CGRectMake(0,0,900,400);
            GameView *large=[[GameView alloc] initWithFrame:CGRectMake(180,10,500,380)];
            [m.phoneParent addSubview:large];[m refresh];
            checkViewportGeometry(m,@"offset_viewport_landscape");
            check(@"offset_viewport_rotation_uses_existing_large_skin_slot",closeRect(m.phoneSurface.frame,large.frame));
            [large removeFromSuperview];m.phoneParent.bounds=parentBounds;
            touchArea.frame=CGRectMake(40,CGRectGetHeight(parentBounds)-200,260,180);[m refresh];
            checkViewportGeometry(m,@"offset_viewport_lower_portrait");
            touchArea.frame=touchFrame;
            m.liveViewport=CGRectZero;m.liveSourceSize=CGSizeZero;m.liveViewportSource=nil;[m refresh];
            [LibretroCore.sharedInstance setNDSCustomLayout:canonicalScaled(NO,1)];
            completion();
        });
    }];
    [buffer commit];
}
static void slowTVCheck(MASManager *manager,dispatch_block_t completion) {
    MASPlan *plan=manager.plan;unsigned phoneBefore=plan.directPhoneCaptures,tvBefore=plan.tvSink.presentations;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0);
    dispatch_async(plan.tvSink.queue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(resume,DISPATCH_TIME_FOREVER);});
    dispatch_semaphore_wait(entered,DISPATCH_TIME_FOREVER);
    for(unsigned i=0;i<3;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/10),dispatch_get_main_queue(),^{presentWithoutContext(plan.source);});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
        check(@"blocked_tv_does_not_stall_native_phone_crop",plan.directPhoneCaptures>=phoneBefore+2&&plan.tvSink.presentations==tvBefore);
        check(@"direct_phone_does_not_acquire_redundant_occluded_sink",plan.phoneSink.presentations==0&&plan.phoneSink.commandQueue==nil);
        check(@"blocked_tv_keeps_newest_completed_capture_only",plan.tvSink.pending.sequence==plan.sequence&&plan.tvSink.superseded>=2);
        check(@"independent_sinks_keep_shared_capture_pool_bounded",plan.peakInflight<=3&&plan.inflight<=3);
        dispatch_semaphore_signal(resume);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
            check(@"tv_resumes_with_latest_sequence_without_replaying_old_frames",plan.tvSink.lastSequence==plan.sequence&&plan.tvSink.presentations==tvBefore+1);
            completion();
        });
    });
}
static NSDictionary *pressureProfile(MASManager *manager,BOOL threeDS,NSUInteger factor) {
    MASPlan *previous=manager.plan,*plan=[MASPlan new];plan.source=previous.source;
    plan.displayQueue=dispatch_queue_create("org.manicemu.airplay.pressure-test",DISPATCH_QUEUE_SERIAL);
    plan.snapshotSlots=dispatch_semaphore_create(3);plan.freeSnapshots=[NSMutableArray new];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0);
    dispatch_async(plan.displayQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(resume,DISPATCH_TIME_FOREVER);});
    dispatch_semaphore_wait(entered,DISPATCH_TIME_FOREVER);
    id<MTLDevice> device=previous.source.device;
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:(threeDS?400:256)*factor height:(threeDS?480:384)*factor mipmapped:NO];
    desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    TestSourceDrawable *source=[TestSourceDrawable new];source.texture=[device newTextureWithDescriptor:desc];
    id<MTLCommandQueue> queue=[device newCommandQueue];double times[2];
    for(unsigned enabled=0;enabled<2;enabled++) {
        manager.plan=enabled?plan:nil;double start=CACurrentMediaTime();
        for(unsigned frame=0;frame<120;frame++) {
            @autoreleasepool {
                id<MTLCommandBuffer> producer=[queue commandBuffer];
                MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture=source.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
                pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                id<MTLRenderCommandEncoder> encoder=[producer renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
                captureFrame((id)source,plan.source,producer);[producer commit];[producer waitUntilCompleted];
            }
        }
        times[enabled]=CACurrentMediaTime()-start;
    }
    NSString *label=[NSString stringWithFormat:@"%@_%lux_120_frames",threeDS?@"3ds":@"ds",factor];
    check([label stringByAppendingString:@"_producer_completes_under_blocked_sink"],times[1]<MAX(3.0,times[0]*5));
    check([label stringByAppendingString:@"_capture_memory_bounded"],plan.peakInflight<=3&&plan.allocations<=3&&plan.snapshots+plan.dropped==120);
    check([label stringByAppendingString:@"_tv_mailbox_retains_latest_capture"],plan.tvSink.pending.sequence==plan.sequence);
    NSMutableDictionary *metrics=[performanceMetrics(plan) mutableCopy];metrics[@"system"]=threeDS?@"3ds":@"ds";
    metrics[@"factor"]=@(factor);metrics[@"producer_frames"]=@120;
    metrics[@"casting_off_ms"]=@(times[0]*1000);metrics[@"blocked_sink_ms"]=@(times[1]*1000);
    manager.plan=previous;dispatch_semaphore_signal(resume);
    return metrics;
}
static void gpu(void) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    check(@"metal_device_available",device!=nil);if(!device)return;
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:400 height:480 mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
    id<MTLTexture> source=[device newTextureWithDescriptor:desc];
    NSMutableData *pixels=[NSMutableData dataWithLength:400*480*4];uint8_t *b=pixels.mutableBytes;
    for(unsigned y=0;y<480;y++)for(unsigned x=0;x<400;x++) {
        unsigned i=(y*400+x)*4;b[i]=y<240?255:0;b[i+1]=y>=240&&x>=40&&x<360?255:0;b[i+3]=255;
    }
    [source replaceRegion:MTLRegionMake2D(0,0,400,480) mipmapLevel:0 withBytes:b bytesPerRow:1600];
    desc.usage=MTLTextureUsageRenderTarget;desc.width=400;desc.height=240;
    id<MTLTexture> top=[device newTextureWithDescriptor:desc];desc.width=320;
    id<MTLTexture> bottom=[device newTextureWithDescriptor:desc];
    id<MTLCommandBuffer> cb=[[device newCommandQueue] commandBuffer];
    check(@"both_crops_encoded_on_one_frame",MASDrawCrop(cb,source,top,CGRectMake(0,0,1,0.5),CGSizeMake(400,240))&&MASDrawCrop(cb,source,bottom,CGRectMake(0.1,0.5,0.8,0.5),CGSizeMake(320,240)));
    [cb commit];[cb waitUntilCompleted];check(@"gpu_command_completed",cb.status==MTLCommandBufferStatusCompleted);
    uint8_t a[4],c[4];[top getBytes:a bytesPerRow:4 fromRegion:MTLRegionMake2D(200,120,1,1) mipmapLevel:0];
    [bottom getBytes:c bytesPerRow:4 fromRegion:MTLRegionMake2D(160,120,1,1) mipmapLevel:0];
    check(@"top_is_red_bottom_is_green",a[0]==255&&a[1]==0&&c[0]==0&&c[1]==255);
    NSMutableData *unchanged=[NSMutableData dataWithLength:pixels.length];[source getBytes:unchanged.mutableBytes bytesPerRow:1600 fromRegion:MTLRegionMake2D(0,0,400,480) mipmapLevel:0];
    check(@"source_texture_preserved",[pixels isEqual:unchanged]);
    // Repeat with crops reversed to validate the actual swap rendering path.
    desc.width=400;desc.height=240;id<MTLTexture> swapped=[device newTextureWithDescriptor:desc];
    cb=[[device newCommandQueue] commandBuffer];MASDrawCrop(cb,source,swapped,CGRectMake(0.1,0.5,0.8,0.5),CGSizeMake(320,240));[cb commit];[cb waitUntilCompleted];
    [swapped getBytes:a bytesPerRow:4 fromRegion:MTLRegionMake2D(200,120,1,1) mipmapLevel:0];
    check(@"swap_renders_other_live_screen",a[0]==0&&a[1]==255);
    [swapped getBytes:a bytesPerRow:4 fromRegion:MTLRegionMake2D(0,120,1,1) mipmapLevel:0];
    check(@"aspect_fit_has_black_bars",a[0]==0&&a[1]==0);
    // Source can be distorted by an existing frontend viewport. Console aspect
    // must still be restored when presenting either crop.
    cb=[[device newCommandQueue] commandBuffer];MASDrawCrop(cb,source,swapped,CGRectMake(0.1,0.5,0.8,0.25),CGSizeMake(320,240));[cb commit];[cb waitUntilCompleted];
    [swapped getBytes:a bytesPerRow:4 fromRegion:MTLRegionMake2D(0,120,1,1) mipmapLevel:0];
    check(@"intermediate_viewport_cannot_distort_screen_aspect",a[0]==0&&a[1]==0);
    for(NSUInteger factor=1;factor<=4;factor*=2) {
        unsigned width=400*factor,height=480*factor;
        desc.width=width;desc.height=height;desc.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> detailed=[device newTextureWithDescriptor:desc];
        NSMutableData *pattern=[NSMutableData dataWithLength:width*height*4];uint8_t *bytes=pattern.mutableBytes;
        for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
            unsigned i=(y*width+x)*4;bytes[i]=(x&1)?255:0;bytes[i+1]=(y&1)?255:0;bytes[i+3]=255;
        }
        [detailed replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:bytes bytesPerRow:width*4];
        desc.height=240*factor;desc.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> output=[device newTextureWithDescriptor:desc];
        cb=[[device newCommandQueue] commandBuffer];
        BOOL encoded=MASDrawCrop(cb,detailed,output,CGRectMake(0,0,1,0.5),CGSizeMake(400,240));
        [cb commit];[cb waitUntilCompleted];
        NSMutableData *row=[NSMutableData dataWithLength:width*4];
        [output getBytes:row.mutableBytes bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,100*factor,width,1) mipmapLevel:0];
        BOOL exact=encoded&&cb.status==MTLCommandBufferStatusCompleted;
        uint8_t *actual=row.mutableBytes;
        for(unsigned x=0;x<width;x++)exact&=actual[x*4]==((x&1)?255:0)&&actual[x*4+3]==255;
        check([NSString stringWithFormat:@"%lux_source_detail_preserved_without_1x_downsample",factor],exact);
    }
}
@interface TestApp : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window,*external;
@end
@implementation TestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    report=[NSMutableDictionary new];self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root=[UIViewController new];self.window.rootViewController=root;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        constrainedRootControl();
        LibretroCore *core=LibretroCore.sharedInstance;UIViewController *vc=[core startWithCustomSaveDir:nil];
        vc.view.frame=CGRectMake(20,100,320,480);[root.view addSubview:vc.view];
        // Match the shipped SnapKit frontend root, not just its nested renderer.
        vc.view.translatesAutoresizingMaskIntoConstraints=NO;
        NSArray *rootSizes=@[[vc.view.widthAnchor constraintEqualToConstant:320],[vc.view.heightAnchor constraintEqualToConstant:480]];
        [NSLayoutConstraint activateConstraints:rootSizes];
        check(@"load_return_and_original_call_preserved",[core loadGame:@"synthetic.nds" corePath:@"melonds" completion:nil]&&loads==1);
        [core setNDSCustomLayout:@"0,0,256,192,0,192,256,192,256,384"];
        check(@"phone_only_has_no_overlay",MASManager.shared.plan==nil&&root.view.subviews.count==1);
        self.external=[[ExternalWindow alloc] initWithFrame:CGRectMake(0,0,1280,720)];
        self.external.rootViewController=[UIViewController new];self.external.hidden=NO;
        [self.external.rootViewController.view addSubview:vc.view];
        [core setNDSCustomLayout:@"0,0,800,600,0,0,0,0,800,600"];
        MASManager *m=MASManager.shared;
        check(@"external_connection_creates_two_live_targets",m.plan&&m.phoneSurface&&m.externalSurface&&loads==1);
        check(@"host_temporarily_owns_root_layout_without_self_size_constraints",
            vc.view.translatesAutoresizingMaskIntoConstraints&& !((NSLayoutConstraint *)rootSizes[0]).active&& !((NSLayoutConstraint *)rootSizes[1]).active);
        check(@"producer_stays_on_phone_screen_while_tv_sink_is_external",vc.view.window==self.window&&m.externalSurface.window==self.external&&vc.view.superview==m.producerHost);
        check(@"native_producer_has_visible_phone_crop_not_clipped_1x1_host",m.producerHost.bounds.size.width>100&&m.producerHost.bounds.size.height>100&&m.plan.producerVisibleArea>10000);
        check(@"native_producer_stays_above_snapshot_surface_for_presented_callbacks",
            [root.view.subviews indexOfObject:m.producerHost]>[root.view.subviews indexOfObject:m.phoneSurface]);
        check(@"producer_geometry_preserves_requested_composite_pixels",CGSizeEqualToSize(findLayer(vc.view.layer).drawableSize,CGSizeMake(1024,1536))&&
            fabs(vc.view.bounds.size.width*cocoa_screen_get_native_scale()-1024)<0.001&&fabs(vc.view.bounds.size.height*cocoa_screen_get_native_scale()-1536)<0.001);
        check(@"single_screen_setting_keeps_both_core_screens",[lastLayout isEqual:canonicalScaled(NO,4)]);
        [core updateCoreConfig:@"Azahar" configs:@{@"citra_resolution_factor":@"3"} reload:NO];
        [core set3DSCustomLayout:@"0,0,400,240,0,0,0,0,400,240"];
        check(@"startup_resolution_dict_preserves_original_call",storedConfigCalls==1);
        check(@"stored_resolution_reaches_producer_before_live_setting_change",CGSizeEqualToSize(m.plan.source.drawableSize,CGSizeMake(1200,1440)));
        [core updateCoreConfig:@"DeSmuME" configs:@{@"desmume_internal_resolution":@"512x384"} reload:NO];
        [core setNDSCustomLayout:@"0,0,256,192,0,0,0,0,256,192"];
        check(@"stored_ds_resolution_keeps_independent_factor",CGSizeEqualToSize(m.plan.source.drawableSize,CGSizeMake(512,768))&&m.last3DSResolutionFactor==3);
        for(NSUInteger factor=1;factor<=4;factor*=2) {
            [core set3DSCustomLayout:@"0,0,400,240,0,0,0,0,400,240"];
            [core updateRunningCoreConfigs:@{@"citra_resolution_factor":@(factor).stringValue} flush:NO];
            check([NSString stringWithFormat:@"%lux_option_reaches_composite_dimensions",factor],[lastLayout isEqual:canonicalScaled(YES,factor)]);
            check([NSString stringWithFormat:@"%lux_reaches_actual_producer_drawable_pixels",factor],CGSizeEqualToSize(m.plan.source.drawableSize,CGSizeMake(400*factor,480*factor)));
            check([NSString stringWithFormat:@"%lux_nested_render_view_matches_vulkan_viewport",factor],
                fabs(vc.view.subviews.firstObject.bounds.size.width*cocoa_screen_get_native_scale()-400*factor)<0.001&&
                fabs(vc.view.subviews.firstObject.bounds.size.height*cocoa_screen_get_native_scale()-480*factor)<0.001);
        }
        [core updateRunningCoreConfigs:@{@"citra_resolution_factor":@"1"} flush:NO];
        [core updateRunningCoreConfigs:@{@"desmume_internal_resolution":@"256x192"} flush:NO];
        [core setNDSCustomLayout:@"0,0,800,600,0,0,0,0,800,600"];
        UIView *touchArea=[[TestTouchInputView alloc] initWithFrame:CGRectMake(30,350,300,180)];
        [root.view addSubview:touchArea];[m refresh];
        touchArea.frame=CGRectMake(50,200,250,180);[m refresh];
        check(@"skin_and_rotation_changes_follow_live_touch_region",CGRectEqualToRect(m.phoneSurface.frame,touchArea.frame));
        touchArea.frame=CGRectMake(40,CGRectGetHeight(root.view.bounds)-200,260,180);[m refresh];
        CGRect nativeBottom=CGRectMake(0,vc.view.bounds.size.height/2,vc.view.bounds.size.width,vc.view.bounds.size.height/2);
        CGRect shown=[vc.view convertRect:nativeBottom toView:m.producerHost];
        CGRect fitted=MASFit(CGSizeMake(256,192),m.producerHost.bounds.size);
        CGSize nativeBounds=vc.view.bounds.size;CGPoint cropCenter=vc.view.center;
        [m.producerHost setNeedsLayout];[m.producerHost layoutIfNeeded];
        [root.view setNeedsLayout];[root.view layoutIfNeeded];
        check(@"constrained_frontend_layout_cannot_replace_native_bounds_or_crop_center",
            CGSizeEqualToSize(vc.view.bounds.size,nativeBounds)&&CGPointEqualToPoint(vc.view.center,cropCenter));
        check(@"lower_portrait_slot_keeps_native_producer_visible",m.plan.producerVisibleArea>10000&&
            closeRect(m.producerHost.frame,CGRectOffset(MASFit(CGSizeMake(256,192),m.phoneSurface.bounds.size),m.phoneSurface.frame.origin.x,m.phoneSurface.frame.origin.y)));
        check(@"phone_display_crops_native_bottom_without_changing_render_bounds",
            fabs(shown.origin.x-fitted.origin.x)<0.001&&fabs(shown.origin.y-fitted.origin.y)<0.001&&
            fabs(shown.size.width-fitted.size.width)<0.001&&fabs(shown.size.height-fitted.size.height)<0.001);
        CGRect portraitBounds=root.view.bounds;
        root.view.bounds=CGRectMake(0,0,900,400);
        UIView *mainSlot=[[GameView alloc] initWithFrame:CGRectMake(180,10,500,380)];
        [root.view addSubview:mainSlot];touchArea.frame=CGRectMake(740,240,140,105);[m refresh];
        check(@"landscape_uses_larger_skin_slot",CGRectEqualToRect(m.phoneSurface.frame,mainSlot.frame));
        m.liveViewport=CGRectMake(0,0,256,384);[m touch:CGPointMake(0.2,0.8)];
        check(@"landscape_touch_maps_into_bottom_screen",fabs(touchPoint.x*UIScreen.mainScreen.nativeScale-51.2)<0.001&&fabs(touchPoint.y*UIScreen.mainScreen.nativeScale-345.6)<0.001);
        root.view.bounds=portraitBounds;[mainSlot removeFromSuperview];touchArea.frame=CGRectMake(50,200,250,180);[m refresh];
        check(@"return_to_portrait_restores_touch_slot",CGRectEqualToRect(m.phoneSurface.frame,touchArea.frame));
        viewportCaptureCheck(m,^{
        [m.phoneSurface layoutIfNeeded];[m.externalSurface layoutIfNeeded];
        Context *context=[Context new];id<MTLCommandBuffer> frame=[context prepare:m.plan.source];
        [context nextDrawable];[context end];
        check(@"renderer_hook_presents_both_live_drawables",masEncodedFrames==1&&frame.status==MTLCommandBufferStatusCompleted&&ends==1);
        // The real-device fallback runs after presentation; Metal disallows a
        // new drawable.texture lookup then. Model that restriction explicitly.
        TestSourceDrawable *presented=[TestSourceDrawable new];
        MTLTextureDescriptor *retainedDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:384 mipmapped:NO];
        retainedDesc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        presented.texture=[m.plan.source.device newTextureWithDescriptor:retainedDesc];
        id<MTLTexture> acquiredTexture=presented.texture;
        presented.textureUnavailableAfterPresent=YES;
        id<MTLCommandBuffer> nativeFallback=[[m.plan.source.device newCommandQueue] commandBuffer];
        captureFrameTexture((id)presented,m.plan.source,nativeFallback,acquiredTexture);
        [nativeFallback commit];[nativeFallback waitUntilCompleted];
        check(@"device_presented_fallback_uses_texture_retained_before_present",
            presented.forbiddenTextureReads==0&&nativeFallback.status==MTLCommandBufferStatusCompleted);
        CAMetalLayer *transitionLayer=m.plan.source;
        transitionLayer.framebufferOnly=YES;
        id<CAMetalDrawable> transition=originalLayerDrawable(transitionLayer,@selector(nextDrawable));
        unsigned capturesBefore=m.plan.snapshots,dropsBefore=m.plan.dropped;
        if(transition)captureFrame(transition,transitionLayer,nil);
        check(@"connection_skips_existing_framebuffer_only_drawable_without_copying",
            transition&&transition.texture.framebufferOnly&&m.plan.snapshots==capturesBefore&&m.plan.dropped==dropsBefore+1);
        if(transition) {
            id<MTLCommandBuffer> transitionPresent=[[transitionLayer.device newCommandQueue] commandBuffer];
            [transitionPresent presentDrawable:transition];[transitionPresent commit];[transitionPresent waitUntilCompleted];
        }
        transitionLayer.framebufferOnly=NO;
        m.liveViewport=CGRectMake(20,30,400,480);[m touch:CGPointMake(0.25,0.75)];
        check(@"touch_maps_to_ds_bottom",fabs(touchPoint.x*UIScreen.mainScreen.nativeScale-120)<0.001&&fabs(touchPoint.y*UIScreen.mainScreen.nativeScale-450)<0.001);
        [m swap];check(@"swap_does_not_reload_or_stop",m.plan.swapped&&loads==1&&stops==0);
        [core set3DSCustomLayout:@"0,0,800,480,0,0,0,0,800,480"];
        [m touch:CGPointMake(0.25,0.75)];
        check(@"touch_maps_to_3ds_centered_bottom",fabs(touchPoint.x*UIScreen.mainScreen.nativeScale-140)<0.001);
        [core setNDSCustomLayout:@"0,0,800,600,0,0,0,0,800,600"];
        BOOL previousSwap=m.swapped;
        [core setNDSCustomLayout:@"0,0,0,0,0,0,800,600,800,600"];
        check(@"original_app_swap_action_updates_display_assignment",m.swapped!=previousSwap);
        presentWithoutContext(m.plan.source);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        check(@"vulkan_style_presentation_reaches_both_outputs_without_context",masPresentedFrames>0&&ends==1&&!m.phoneSurface.hidden&&!m.externalSurface.hidden);
        check(@"vulkan_native_phone_crop_and_tv_sink_have_separate_screen_pixels",masPresentedPhonePixel==0xFF00FF00&&masPresentedTVPixel==0xFFFF0000);
        unsigned firstPresent=masPresentedFrames;
        [m swap];presentWithoutContext(m.plan.source);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        check(@"vulkan_style_swap_keeps_presenting_without_context",masPresentedFrames>firstPresent&&ends==1&&loads==1&&stops==0);
        check(@"vulkan_native_phone_crop_swap_reverses_actual_output_pixels",masPresentedPhonePixel==0xFFFF0000&&masPresentedTVPixel==0xFF00FF00);
        check(@"sink_drawable_acquisition_runs_off_emulation_thread",masSinkAcquisitionsOnMain==0);
        slowTVCheck(m,^{
        // Simulate a blocked external presentation queue. Matched producer
        // buffers continue to complete; the three-slot pool bounds capture work.
        MASPlan *perfPlan=m.plan;
        dispatch_semaphore_t entered=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0);
        dispatch_async(perfPlan.displayQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(resume,DISPATCH_TIME_FOREVER);});
        dispatch_semaphore_wait(entered,DISPATCH_TIME_FOREVER);
        id<MTLDevice> perfDevice=perfPlan.source.device;
        MTLTextureDescriptor *perfDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:384 mipmapped:NO];
        perfDesc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        TestSourceDrawable *perfSource=[TestSourceDrawable new];perfSource.texture=[perfDevice newTextureWithDescriptor:perfDesc];
        id<MTLCommandQueue> perfQueue=[perfDevice newCommandQueue];
        CFTimeInterval timings[2];
        for(unsigned enabled=0;enabled<2;enabled++) {
            m.plan=enabled?perfPlan:nil;
            CFTimeInterval start=CACurrentMediaTime();
            for(unsigned i=0;i<20;i++) {
                id<MTLCommandBuffer> producer=[perfQueue commandBuffer];
                MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture=perfSource.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                id<MTLRenderCommandEncoder> encoder=[producer renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
                captureFrame((id)perfSource,perfPlan.source,producer);
                [producer commit];[producer waitUntilCompleted];
            }
            timings[enabled]=CACurrentMediaTime()-start;
        }
        m.plan=perfPlan;
        NSLog(@"Matched synthetic producer GPU timings: AirPlay off %.3f ms; blocked AirPlay on %.3f ms (20 frames)",timings[0]*1000,timings[1]*1000);
        check(@"blocked_sink_cannot_block_producer_gpu_completion",timings[1]<1.0);
        check(@"capture_pool_bounded_under_sink_backpressure",perfPlan.peakInflight<=3);
        check(@"capture_accounting_retains_latest_instead_of_oldest_frames",perfPlan.tvSink.pending.sequence==perfPlan.sequence);
        NSDictionary *metrics=performanceMetrics(perfPlan);
        NSString *metricsDir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSMutableDictionary *timed=[metrics mutableCopy];
        timed[@"synthetic_20_frames_casting_off_ms"]=@(timings[0]*1000);
        timed[@"synthetic_20_frames_blocked_sink_ms"]=@(timings[1]*1000);
        timed[@"physical_airplay_measured"]=@NO;
        NSMutableArray *scaled=[NSMutableArray new];
        for(unsigned system=0;system<2;system++)for(NSUInteger factor=1;factor<=4;factor*=2)
            [scaled addObject:pressureProfile(m,system!=0,factor)];
        timed[@"scaled_pressure_profiles"]=scaled;
        [[NSJSONSerialization dataWithJSONObject:timed options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[metricsDir stringByAppendingPathComponent:@"performance.json"] atomically:YES];
        dispatch_semaphore_signal(resume);
        self.external.hidden=YES;[root.view addSubview:vc.view];[m refresh];
        check(@"disconnect_restores_phone_layout_and_removes_overlays",!m.plan&&!m.phoneSurface&&!m.externalSurface&&[lastLayout isEqual:m.phoneLayout]&&loads==1);
        check(@"disconnect_removes_producer_host_without_reparenting_host_phone_view",!m.producerHost&&vc.view.superview==root.view);
        check(@"disconnect_discards_completed_viewport_before_new_session",CGRectIsEmpty(m.liveViewport)&&CGSizeEqualToSize(m.liveSourceSize,CGSizeZero)&&!m.liveViewportSource);
        check(@"disconnect_restores_original_producer_dimensions",CGSizeEqualToSize(vc.view.bounds.size,CGSizeMake(320,480)));
        check(@"disconnect_restores_original_framebuffer_mode",findLayer(vc.view.layer).framebufferOnly);
        check(@"disconnect_restores_source_transform",CGAffineTransformIsIdentity(vc.view.transform));
        check(@"disconnect_restores_frontend_auto_layout_flag",!vc.view.translatesAutoresizingMaskIntoConstraints);
        self.external.hidden=NO;
        [self.external.rootViewController.view addSubview:vc.view];[m refresh];
        check(@"reconnect_recreates_split_without_reload",m.plan&&m.phoneSurface&&m.externalSurface&&loads==1&&stops==0);
        check(@"reconnect_keeps_producer_on_phone_again",vc.view.window==self.window&&m.externalTarget==self.external);
        NSArray *newRootSizes=@[[vc.view.widthAnchor constraintEqualToConstant:320],[vc.view.heightAnchor constraintEqualToConstant:480]];
        [NSLayoutConstraint activateConstraints:newRootSizes];[m refresh];
        check(@"repeated_session_suspends_new_frontend_self_size_constraints",
            !((NSLayoutConstraint *)newRootSizes[0]).active&&!((NSLayoutConstraint *)newRootSizes[1]).active);
        // Overlay-owned release must restore precisely the constraints it
        // suspended, before the original frontend takes ownership again.
        [m removeSurfaces];
        check(@"owned_release_restores_suspended_frontend_size_constraints",
            !vc.view.translatesAutoresizingMaskIntoConstraints&&((NSLayoutConstraint *)newRootSizes[0]).active&&((NSLayoutConstraint *)newRootSizes[1]).active);
        [NSLayoutConstraint deactivateConstraints:newRootSizes];[m refresh];
        self.external.hidden=YES;[root.view addSubview:vc.view];[m refresh];
        [core stop];check(@"stop_cleans_up_without_save_or_core_reload",stops==1&&loads==1&&!m.dual);
        // Cast remains connected while a new game starts directly on external
        // output. There was no prior phone-layout call in this session.
        self.external.hidden=NO;
        UIViewController *next=[core startWithCustomSaveDir:nil];
        next.view.frame=CGRectMake(0,0,320,480);
        [self.external.rootViewController.view addSubview:next.view];
        [core setNDSCustomLayout:canonical(NO)];
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
        [m refresh];
        check(@"game_start_while_cast_remains_connected_recovers_phone_skin",m.plan&&m.phoneParent==root.view&&next.view.window==self.window);
        check(@"foreground_restoration_keeps_native_producer_visible",m.plan.producerVisibleArea>10000&&m.externalTarget==self.external);
        [core stop];self.external.hidden=YES;
        gpu();
        NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[dir stringByAppendingPathComponent:@"smoke.json"] atomically:YES];
        });
        });
        });
        });
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
