// SPDX-License-Identifier: AGPL-3.0-or-later
#import "MASRender.h"
#import <simd/simd.h>

CGRect MASFit(CGSize content, CGSize bounds) {
    if(content.width<=0 || content.height<=0 || bounds.width<=0 || bounds.height<=0) return CGRectZero;
    CGFloat s=MIN(bounds.width/content.width,bounds.height/content.height);
    CGSize size=CGSizeMake(content.width*s,content.height*s);
    return CGRectMake((bounds.width-size.width)/2,(bounds.height-size.height)/2,size.width,size.height);
}

BOOL MASDrawCrop(id<MTLCommandBuffer> buffer,id<MTLTexture> source,id<MTLTexture> destination,CGRect crop,CGSize screenSize) {
    if(!buffer || !source || !destination || source==destination || CGRectIsEmpty(crop) ||
       crop.origin.x<0 || crop.origin.y<0 || CGRectGetMaxX(crop)>1.00001 || CGRectGetMaxY(crop)>1.00001 ||
       screenSize.width<=0 || screenSize.height<=0) return NO;
    static id<MTLDevice> cachedDevice;
    static id<MTLRenderPipelineState> cachedPipeline;
    static MTLPixelFormat cachedFormat;
    id<MTLRenderPipelineState> pipeline;
    @synchronized([NSObject class]) {
        if(cachedDevice!=buffer.device || cachedFormat!=destination.pixelFormat || !cachedPipeline) {
            NSError *error=nil;
            NSString *shader=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V mas_vertex(uint i [[vertex_id]]) {\n"
            "float2 p[3]={float2(-1,1),float2(3,1),float2(-1,-3)};\n"
            "float2 uv[3]={float2(0,0),float2(2,0),float2(0,2)}; return {float4(p[i],0,1),uv[i]}; }\n"
            "fragment float4 mas_fragment(V v [[stage_in]],texture2d<float> t [[texture(0)]],constant float4 &c [[buffer(0)]]) {\n"
            "constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest); return t.sample(s,c.xy+v.uv*c.zw); }";
            id<MTLLibrary> library=[buffer.device newLibraryWithSource:shader options:nil error:&error];
            MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
            desc.vertexFunction=[library newFunctionWithName:@"mas_vertex"];
            desc.fragmentFunction=[library newFunctionWithName:@"mas_fragment"];
            desc.colorAttachments[0].pixelFormat=destination.pixelFormat;
            cachedPipeline=library?[buffer.device newRenderPipelineStateWithDescriptor:desc error:&error]:nil;
            cachedDevice=buffer.device; cachedFormat=destination.pixelFormat;
            if(!cachedPipeline) NSLog(@"ManicAirPlaySplit: Metal crop pipeline failed: %@",error);
        }
        pipeline=cachedPipeline;
    }
    if(!pipeline) return NO;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=destination;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:pass];
    if(!encoder) return NO;
    // The original viewport may stretch the combined frame. Preserve the
    // console screen aspect independently of the intermediate texture shape.
    CGRect fit=MASFit(screenSize,CGSizeMake(destination.width,destination.height));
    [encoder setViewport:(MTLViewport){fit.origin.x,fit.origin.y,fit.size.width,fit.size.height,0,1}];
    vector_float4 region={(float)crop.origin.x,(float)crop.origin.y,(float)crop.size.width,(float)crop.size.height};
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentBytes:&region length:sizeof(region) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}
