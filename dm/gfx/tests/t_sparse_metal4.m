// Metal 4 placement-sparse residency and lossless tile copies. No game data.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (![dev supportsFamily:MTLGPUFamilyApple8]) { puts("SKIP: placement sparse requires Apple8"); return 0; }
    NSError *error = nil;
    id<MTL4CommandQueue> queue = [dev newMTL4CommandQueue];
    id<MTLResidencySet> residency = [dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    [queue addResidencySet:residency];
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
    hd.type = MTLHeapTypePlacement; hd.storageMode = MTLStorageModePrivate;
    hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64; hd.size = 65536;
    id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead;
    td.placementSparsePageSize = MTLSparsePageSize64;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> input = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    if (!queue || !residency || !heap || !texture || !input || !output) { fprintf(stderr, "allocation failed: %s\n", error.description.UTF8String); return 1; }
    for (size_t i = 0; i < 65536; i++) ((uint8_t *)input.contents)[i] = (uint8_t)(i * 37 + i / 512);
    memset(output.contents, 0, 65536);
    [residency addAllocation:heap]; [residency addAllocation:texture];
    [residency addAllocation:input]; [residency addAllocation:output]; [residency commit];
    MTL4UpdateSparseTextureMappingOperation op = { .mode = MTLSparseTextureMappingModeMap,
        .textureRegion = MTLRegionMake2D(0, 0, 1, 1), .textureLevel = 0, .textureSlice = 0, .heapOffset = 0 };
    [queue updateTextureMappings:texture heap:heap operations:&op count:1];
    id<MTL4CommandAllocator> allocator = [dev newCommandAllocator];
    id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc barrierAfterQueueStages:MTLStageResourceState beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [enc copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:512 sourceBytesPerImage:65536 sourceSize:MTLSizeMake(128,128,1)
             toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [enc barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [enc copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,128,1)
               toBuffer:output destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:65536];
    [enc endEncoding]; [cb endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSError *gpuError;
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { gpuError = feedback.error; dispatch_semaphore_signal(done); }];
    [queue commit:&cb count:1 options:options];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) { fputs("GPU timeout\n", stderr); return 1; }
    if (gpuError || memcmp(input.contents, output.contents, 65536)) { fprintf(stderr, "FAIL: %s\n", gpuError.description.UTF8String); return 1; }
    puts("PASS: all 65536 mapped tile bytes preserved through Metal 4 upload and readback");
    return 0;
} }
