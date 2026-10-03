// Synthetic UIKit/Metal integration. Does not claim physical AirPlay validation.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <assert.h>
#define MAS_TESTING 1
#import "../iOS/ManicAirPlaySplit.m"

static NSString *lastLayout;
static unsigned loads,stops,ends,touches,releases;
static CGPoint touchPoint;
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
@end
@implementation LibretroCore
+ (instancetype)sharedInstance {static id v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (UIViewController *)startWithCustomSaveDir:(NSString *)save {self.vc=[UIViewController new];self.vc.view=[MASSurface new];return self.vc;}
- (BOOL)loadGame:(NSString *)path corePath:(NSString *)core completion:(id)completion {loads++;return YES;}
- (void)stop {stops++;}
- (void)setNDSCustomLayout:(NSString *)layout {lastLayout=[layout copy];}
- (void)set3DSCustomLayout:(NSString *)layout {lastLayout=[layout copy];}
- (void)sendTouchEventX:(CGFloat)x y:(CGFloat)y {touches++;touchPoint=CGPointMake(x,y);}
- (void)releaseTouchEvent {releases++;}
@end
@interface TestSourceDrawable : NSObject
@property(strong) id<MTLTexture> texture;
@end
@implementation TestSourceDrawable @end
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

// Exercise MoltenVK's public presentation pattern without calling Context end.
static void presentWithoutContext(CAMetalLayer *layer) {
    layer.device=MTLCreateSystemDefaultDevice();layer.drawableSize=CGSizeMake(256,384);
    id<CAMetalDrawable> drawable=[layer nextDrawable];
    check(@"swapchain_drawable_available",drawable!=nil);
    id<MTLCommandBuffer> buffer=[[layer.device newCommandQueue] commandBuffer];
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:384 mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
    id<MTLTexture> pattern=[layer.device newTextureWithDescriptor:desc];
    NSMutableData *pixels=[NSMutableData dataWithLength:256*384*4];uint8_t *b=pixels.mutableBytes;
    for(unsigned y=0;y<384;y++)for(unsigned x=0;x<256;x++) {
        unsigned i=(y*256+x)*4;b[i]=y<192?255:0;b[i+1]=y<192?0:255;b[i+3]=255;
    }
    [pattern replaceRegion:MTLRegionMake2D(0,0,256,384) mipmapLevel:0 withBytes:b bytesPerRow:1024];
    check(@"swapchain_test_pattern_encoded",MASDrawCrop(buffer,pattern,drawable.texture,CGRectMake(0,0,1,1),CGSizeMake(256,384)));
    [buffer addScheduledHandler:^(id<MTLCommandBuffer> _) {[drawable present];}];
    [buffer commit];
}

static NSMutableDictionary *report;
static void check(NSString *key,BOOL passed){report[key]=@(passed);NSLog(@"%@ = %d",key,passed);}
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
}
@interface TestApp : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window,*external;
@end
@implementation TestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    report=[NSMutableDictionary new];self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root=[UIViewController new];self.window.rootViewController=root;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        LibretroCore *core=LibretroCore.sharedInstance;UIViewController *vc=[core startWithCustomSaveDir:nil];
        vc.view.frame=CGRectMake(20,100,320,480);[root.view addSubview:vc.view];
        check(@"load_return_and_original_call_preserved",[core loadGame:@"synthetic.nds" corePath:@"melonds" completion:nil]&&loads==1);
        [core setNDSCustomLayout:@"0,0,256,192,0,192,256,192,256,384"];
        check(@"phone_only_has_no_overlay",MASManager.shared.plan==nil&&root.view.subviews.count==1);
        self.external=[[ExternalWindow alloc] initWithFrame:CGRectMake(0,0,1280,720)];
        self.external.rootViewController=[UIViewController new];self.external.hidden=NO;
        [self.external.rootViewController.view addSubview:vc.view];
        [core setNDSCustomLayout:@"0,0,800,600,0,0,0,0,800,600"];
        MASManager *m=MASManager.shared;
        check(@"external_connection_creates_two_live_targets",m.plan&&m.phoneSurface&&m.externalSurface&&loads==1);
        check(@"single_screen_setting_keeps_both_core_screens",[lastLayout isEqual:canonical(NO)]);
        UIView *touchArea=[[TestTouchInputView alloc] initWithFrame:CGRectMake(30,350,300,180)];
        [root.view addSubview:touchArea];[m refresh];
        touchArea.frame=CGRectMake(50,200,250,180);[m refresh];
        check(@"skin_and_rotation_changes_follow_live_touch_region",CGRectEqualToRect(m.phoneSurface.frame,touchArea.frame));
        [m.phoneSurface layoutIfNeeded];[m.externalSurface layoutIfNeeded];
        Context *context=[Context new];id<MTLCommandBuffer> frame=[context prepare:m.plan.source];
        [context nextDrawable];[context end];
        check(@"renderer_hook_presents_both_live_drawables",masEncodedFrames==1&&frame.status==MTLCommandBufferStatusCompleted&&ends==1);
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
        check(@"vulkan_style_outputs_have_separate_screen_pixels",masPresentedPhonePixel==0xFF00FF00&&masPresentedTVPixel==0xFFFF0000);
        unsigned firstPresent=masPresentedFrames;
        [m swap];presentWithoutContext(m.plan.source);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        check(@"vulkan_style_swap_keeps_presenting_without_context",masPresentedFrames>firstPresent&&ends==1&&loads==1&&stops==0);
        check(@"vulkan_style_swap_reverses_actual_output_pixels",masPresentedPhonePixel==0xFFFF0000&&masPresentedTVPixel==0xFF00FF00);
        [root.view addSubview:vc.view];[m refresh];
        check(@"disconnect_restores_phone_layout_and_removes_overlays",!m.plan&&!m.phoneSurface&&!m.externalSurface&&[lastLayout isEqual:m.phoneLayout]&&loads==1);
        check(@"disconnect_restores_original_framebuffer_mode",((CAMetalLayer *)vc.view.layer).framebufferOnly);
        [core stop];check(@"stop_cleans_up_without_save_or_core_reload",stops==1&&loads==1&&!m.dual);
        gpu();
        NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[dir stringByAppendingPathComponent:@"smoke.json"] atomically:YES];
        });
        });
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestApp.class));}}
