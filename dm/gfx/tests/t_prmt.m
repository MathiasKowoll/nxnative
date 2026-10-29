// Run the actual offline-translated Maxwell programs, without rewriting their IR.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString *root = @(argv[1]); NSError *error = nil;
    NSArray *cases = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"cases.json"]] options:0 error:&error];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev || !cases.count) return 2;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    NSMutableDictionary *pipelines = [NSMutableDictionary dictionary];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> output = [dev newTextureWithDescriptor:td];
    unsigned count = 0;
    for (NSDictionary *test in cases) {
        NSString *key = test[@"key"];
        id<MTLRenderPipelineState> ps = pipelines[key];
        if (!ps) {
            NSString *src = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:[key stringByAppendingString:@".metal"]] encoding:NSUTF8StringEncoding error:&error];
            id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
            if (!lib) { fprintf(stderr,"%s: %s\n",key.UTF8String,error.description.UTF8String); return 1; }
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"test_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"main0"];
            pd.colorAttachments[0].pixelFormat = td.pixelFormat;
            ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!ps) { fprintf(stderr,"%s: %s\n",key.UTF8String,error.description.UTF8String); return 1; }
            pipelines[key] = ps;
        }
        uint32_t words[16384] = {0}; NSArray *values = test[@"values"];
        for (unsigned i=0;i<values.count;i++) words[i] = [values[i] unsignedIntValue];
        id<MTLBuffer> uniform = [dev newBufferWithBytes:words length:sizeof words options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = output; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps]; [enc setFragmentBuffer:uniform offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",cb.error.description.UTF8String); return 1; }
        uint32_t actual = 0, expected = [test[@"expected"] unsignedIntValue];
        [output getBytes:&actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        if (actual != expected) { fprintf(stderr,"%s selector=%x got %08x expected %08x\n",key.UTF8String,words[2],actual,expected); return 1; }
        count++;
    }
    printf("%u exact integer results passed\n",count); return 0;
} }
