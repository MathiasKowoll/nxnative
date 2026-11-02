#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../nvn/nvn_tex.h"
#include "../tex/nvn_fmt_mtl.h"

static int fail;
#define CHECK(c, ...) do { if (c) printf("ok: "); else { printf("FAIL: "); fail++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static void check_tile_geometry(id<MTLDevice> dev, int format, const char *name) {
    nvn_texdesc nd = {.target=4, .format=format, .flags=0x20, .width=8192, .height=8192, .depth=68, .levels=14};
    uint32_t nw = 0, nh = 0, nz = 0, mpf = 0;
    int tiledLevels = nvn_tex_sparse_tiles(&nd, &nw, &nh, &nz);
    CHECK(nvn_fmt_to_mtl(format, &mpf, NULL) && mpf, "%s maps to a native Metal format", name);
    if (!mpf) return;
    MTLSize mt = [dev sparseTileSizeWithTextureType:MTLTextureType2DArray pixelFormat:(MTLPixelFormat)mpf sampleCount:1 sparsePageSize:MTLSparsePageSize64];
    printf("%s tile: NVN %ux%ux%u, Metal %llux%llux%llu, NVN tiled levels %d\n", name, nw, nh, nz,
           (unsigned long long)mt.width, (unsigned long long)mt.height, (unsigned long long)mt.depth, tiledLevels);
    CHECK(nw == mt.width && nh == mt.height && nz == mt.depth, "%s uses identical 64 KB tile geometry", name);
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.pixelFormat = (MTLPixelFormat)mpf;
    td.width = nd.width; td.height = nd.height; td.arrayLength = nd.depth; td.mipmapLevelCount = nd.levels;
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead; td.placementSparsePageSize = MTLSparsePageSize64;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    CHECK(texture != nil, "%s placement sparse array created", name);
    if (texture) {
        printf("%s mip tail: NVN starts level %d, Metal starts level %llu, Metal tail %llu bytes per slice\n", name, tiledLevels,
               (unsigned long long)texture.firstMipmapInTail, (unsigned long long)texture.tailSizeInBytes);
        CHECK((NSUInteger)tiledLevels == texture.firstMipmapInTail, "%s uses the same mip-tail boundary", name);
    }
}

static void resource_state_barrier(id<MTLDevice> dev, id<MTL4CommandQueue> queue) {
    MTL4CommandAllocatorDescriptor *ad = [MTL4CommandAllocatorDescriptor new];
    NSError *error = nil;
    id<MTL4CommandAllocator> allocator = [dev newCommandAllocatorWithDescriptor:ad error:&error];
    CHECK(allocator != nil, "Metal 4 command allocator%s%s", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
    if (!allocator) return;

    id<MTL4CommandBuffer> commandBuffer = [dev newCommandBuffer];
    [commandBuffer beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder barrierAfterQueueStages:MTLStageResourceState
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    [commandBuffer endCommandBuffer];

    MTL4CommitOptions *options = [MTL4CommitOptions new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *feedbackError = nil;
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        feedbackError = feedback.error;
        dispatch_semaphore_signal(done);
    }];
    [queue commit:&commandBuffer count:1 options:options];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    CHECK(feedbackError == nil, "resource-state barrier completed%s%s", feedbackError ? ": " : "", feedbackError ? feedbackError.localizedDescription.UTF8String : "");
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    CHECK(dev != nil, "Metal device available");
    if (!dev) return 1;
    printf("device: %s\n", dev.name.UTF8String);
    CHECK(dev.supportsPlacementSparse, "placement sparse resources supported");
    if (!dev.supportsPlacementSparse) return fail ? 1 : 0;

    NSError *error = nil;
    MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new];
    id<MTL4CommandQueue> queue = [dev newMTL4CommandQueueWithDescriptor:qd error:&error];
    CHECK(queue != nil, "Metal 4 command queue%s%s", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
    if (!queue) return 1;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:8192
                                                                                 height:8192
                                                                              mipmapped:YES];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    td.placementSparsePageSize = MTLSparsePageSize64;
    NSUInteger beforeTexture = dev.currentAllocatedSize;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    NSUInteger afterTexture = dev.currentAllocatedSize;
    CHECK(texture != nil, "8192x8192 placement sparse texture created");
    if (!texture) return 1;
    CHECK(texture.isSparse, "texture reports sparse storage");
    CHECK(texture.width == 8192 && texture.height == 8192 && texture.mipmapLevelCount == 14,
          "full dimensions and all 14 mip levels retained");

    MTLSize tile = [dev sparseTileSizeWithTextureType:texture.textureType
                                           pixelFormat:texture.pixelFormat
                                           sampleCount:texture.sampleCount
                                        sparsePageSize:MTLSparsePageSize64];
    NSUInteger pageBytes = [dev sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize64];
    printf("virtual texture: allocated delta %llu bytes, tile %llux%llux%llu, page %llu bytes, tail starts mip %llu, tail %llu bytes\n",
           (unsigned long long)(afterTexture - beforeTexture),
           (unsigned long long)tile.width, (unsigned long long)tile.height, (unsigned long long)tile.depth,
           (unsigned long long)pageBytes, (unsigned long long)texture.firstMipmapInTail,
           (unsigned long long)texture.tailSizeInBytes);
    CHECK(pageBytes == 64 * 1024, "Metal sparse page is 64 KB like NVN");
    check_tile_geometry(dev, 0x50, "BC6H_UF16");
    check_tile_geometry(dev, 0x8e, "ASTC_8x8_sRGB");
    {
        nvn_texdesc nd = {.target=4, .format=0x26, .flags=0x20, .width=6144, .height=6144, .depth=2, .levels=4};
        uint32_t tw, th, tz, mpf = 0; int tiled = nvn_tex_sparse_tiles(&nd, &tw, &th, &tz); nvn_fmt_to_mtl(nd.format, &mpf, NULL);
        MTLTextureDescriptor *x = [MTLTextureDescriptor new]; x.textureType = MTLTextureType2DArray; x.pixelFormat = (MTLPixelFormat)mpf;
        x.width = nd.width; x.height = nd.height; x.arrayLength = nd.depth; x.mipmapLevelCount = nd.levels;
        x.storageMode = MTLStorageModePrivate; x.usage = MTLTextureUsageShaderRead; x.placementSparsePageSize = MTLSparsePageSize64;
        id<MTLTexture> noTail = [dev newTextureWithDescriptor:x];
        printf("6144x6144 RGBA8: NVN tiled levels %d, Metal tail starts %llu, tail %llu bytes\n", tiled,
               (unsigned long long)noTail.firstMipmapInTail, (unsigned long long)noTail.tailSizeInBytes);
        CHECK(noTail != nil && tiled == (int)nd.levels && noTail.firstMipmapInTail >= nd.levels,
              "6144x6144 RGBA8 array keeps all four declared levels before Metal's theoretical tail");
    }

    MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
    hd.type = MTLHeapTypePlacement;
    hd.storageMode = MTLStorageModePrivate;
    hd.size = pageBytes * 2;
    hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
    NSUInteger beforeHeap = dev.currentAllocatedSize;
    id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
    NSUInteger afterHeap = dev.currentAllocatedSize;
    CHECK(heap != nil, "two-page placement heap created");
    if (!heap) return 1;
    printf("physical heap: requested %llu bytes, allocated delta %llu bytes\n",
           (unsigned long long)hd.size, (unsigned long long)(afterHeap - beforeHeap));
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    rd.initialCapacity = 2;
    id<MTLResidencySet> residency = [dev newResidencySetWithDescriptor:rd error:&error];
    CHECK(residency != nil, "residency set%s%s", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
    if (!residency) return 1;
    [residency addAllocation:heap];
    [residency addAllocation:texture];
    [residency commit];
    [queue addResidencySet:residency];

    MTL4UpdateSparseTextureMappingOperation map = {
        .mode = MTLSparseTextureMappingModeMap,
        .textureRegion = MTLRegionMake3D(0, 0, 0, 1, 1, 1),
        .textureLevel = 0,
        .textureSlice = 0,
        .heapOffset = 0,
    };
    int beforeMap = fail;
    [queue updateTextureMappings:texture heap:heap operations:&map count:1];
    resource_state_barrier(dev, queue);
    CHECK(fail == beforeMap, "one physical tile mapped without allocating the virtual texture in full");

    MTL4UpdateSparseTextureMappingOperation unmap = map;
    unmap.mode = MTLSparseTextureMappingModeUnmap;
    [queue updateTextureMappings:texture heap:nil operations:&unmap count:1];
    resource_state_barrier(dev, queue);
    CHECK(fail == beforeMap, "tile unmapped cleanly");
    return fail ? 1 : 0;
} }
