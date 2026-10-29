// Dense reflection IDs must match Metal's physical argument-buffer layout.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2)return 2;
    id<MTLDevice>d=MTLCreateSystemDefaultDevice(); NSError *err=nil;
    NSString *src=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
    id<MTLLibrary>l=[d newLibraryWithSource:src options:nil error:&err];
    if(!l){fprintf(stderr,"%s\n",err.description.UTF8String);return 1;}
    id<MTLFunction>f=[l newFunctionWithName:@"f"];id<MTLArgumentEncoder>ae=[f newArgumentEncoderWithBufferIndex:0];
    if(ae.encodedLength!=24){fprintf(stderr,"expected 3 dense fields, got %lu bytes\n",ae.encodedLength);return 1;}
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[l newFunctionWithName:@"v"];pd.fragmentFunction=f;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithDescriptor:pd error:&err];if(!ps){fprintf(stderr,"%s\n",err.description.UTF8String);return 1;}
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture>in=[d newTextureWithDescriptor:td],out=[d newTextureWithDescriptor:td];
    uint8_t green[]={0,255,0,255};[in replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:green bytesPerRow:4];
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];sd.supportArgumentBuffers=YES;id<MTLSamplerState>s=[d newSamplerStateWithDescriptor:sd];
    float gain=.5;id<MTLBuffer>u=[d newBufferWithBytes:&gain length:4 options:MTLResourceStorageModeShared];
    uint64_t slots[]={in.gpuResourceID._impl,u.gpuAddress,s.gpuResourceID._impl};
    id<MTLBuffer>a=[d newBufferWithBytes:slots length:sizeof slots options:MTLResourceStorageModeShared];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];rp.colorAttachments[0].texture=out;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandQueue>q=[d newCommandQueue];id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];[e setFragmentBuffer:a offset:0 atIndex:0];[e useResource:in usage:MTLResourceUsageRead];[e useResource:u usage:MTLResourceUsageRead];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];
    if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.description.UTF8String);return 1;}
    uint8_t actual[4];[out getBytes:actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    if(memcmp(actual,green,4)){fprintf(stderr,"wrong dense argument binding: %u,%u,%u,%u\n",actual[0],actual[1],actual[2],actual[3]);return 1;}
    puts("pruned sampler: dense IDs, live sampler, direct texture read and GPU output passed");return 0;
} }
