// Validate simulator descriptor-array capabilities using real Metal execution.
// No game, plugin, or device data is involved.
#import <Metal/Metal.h>
#include <string.h>
static NSDictionary *metalArrayDiagnostic(void) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSMutableDictionary *result=[NSMutableDictionary new];
    if(!device){result[@"device_available"]=@NO;return result;}
    result[@"device_available"]=@YES;result[@"device_name"]=device.name;
    result[@"apple3_family"]=@([device supportsFamily:MTLGPUFamilyApple3]);
    result[@"common2_family"]=@([device supportsFamily:MTLGPUFamilyCommon2]);
    result[@"mac2_family"]=@([device supportsFamily:MTLGPUFamilyMac2]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    result[@"legacy_texture_arrays"]=@([device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily3_v2]);
    result[@"legacy_sampler_arrays"]=@([device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily3_v3]);
#pragma clang diagnostic pop
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void arrays(array<texture2d<float>,2> textures [[texture(0)]], "
        "array<sampler,2> samplers [[sampler(0)]], device float4 *output [[buffer(0)]], "
        "uint index [[thread_position_in_grid]]) { "
        "output[index]=textures[index].sample(samplers[index],float2(0.5),level(0)); }";
    NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    if(!library){result[@"compile_error"]=error.localizedDescription?:@"unknown";return result;}
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"arrays"] error:&error];
    if(!pipeline){result[@"pipeline_error"]=error.localizedDescription?:@"unknown";return result;}
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> textures[2]={[device newTextureWithDescriptor:descriptor],[device newTextureWithDescriptor:descriptor]};
    if(!textures[0]||!textures[1]){result[@"texture_allocation_failed"]=@YES;return result;}
    float expected[8]={1,0,0,1,0,1,0,1};
    for(unsigned i=0;i<2;i++)[textures[i] replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:expected+i*4 bytesPerRow:16];
    MTLSamplerDescriptor *samplerDescriptor=[MTLSamplerDescriptor new];
    id<MTLSamplerState> samplers[2]={[device newSamplerStateWithDescriptor:samplerDescriptor],[device newSamplerStateWithDescriptor:samplerDescriptor]};
    id<MTLBuffer> output=[device newBufferWithLength:sizeof(expected) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];[encoder setTextures:textures withRange:NSMakeRange(0,2)];
    [encoder setSamplerStates:samplers withRange:NSMakeRange(0,2)];[encoder setBuffer:output offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(2,1,1) threadsPerThreadgroup:MTLSizeMake(2,1,1)];
    [encoder endEncoding];[command commit];[command waitUntilCompleted];
    result[@"command_completed"]=@(command.status==MTLCommandBufferStatusCompleted);
    result[@"texture_sampler_arrays_verified"]=@(command.status==MTLCommandBufferStatusCompleted && memcmp(output.contents,expected,sizeof(expected))==0);
    if(command.error)result[@"command_error"]=command.error.localizedDescription;
    return result;
}
