// Validate the Metal object -> payload -> mesh path used to model NVN2 task and
// mesh shaders. This deliberately compiles at run time so the test exercises the
// SDK and GPU installed on the machine, not a checked-in precompiled fixture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

static NSString *source(void) {
    return @R"(
#include <metal_stdlib>
using namespace metal;

struct Payload { float4 color; };
struct Vertex { float4 position [[position]]; };
struct Primitive { float4 color; };

[[object, max_total_threads_per_threadgroup(1), max_total_threadgroups_per_mesh_grid(1)]]
void task_object(object_data Payload& payload [[payload]],
                 mesh_grid_properties grid,
                 uint lane [[thread_index_in_threadgroup]]) {
    if (lane == 0) {
        payload.color = float4(0.125, 0.75, 0.25, 1.0);
        grid.set_threadgroups_per_grid(uint3(1, 1, 1));
    }
}

[[mesh, max_total_threads_per_threadgroup(1)]]
void mesh_main(mesh<Vertex, Primitive, 3, 1, topology::triangle> out,
               const object_data Payload& payload [[payload]],
               uint lane [[thread_index_in_threadgroup]]) {
    if (lane == 0) {
        out.set_vertex(0, Vertex{float4(-1.0, -1.0, 0.0, 1.0)});
        out.set_vertex(1, Vertex{float4( 3.0, -1.0, 0.0, 1.0)});
        out.set_vertex(2, Vertex{float4(-1.0,  3.0, 0.0, 1.0)});
        out.set_primitive(0, Primitive{payload.color});
        out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2);
        out.set_primitive_count(1);
    }
}

fragment float4 fragment_main(Primitive p [[stage_in]]) { return p.color; }
)";
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 77;
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> library = [device newLibraryWithSource:source() options:options error:&error];
    if (!library) { fprintf(stderr, "object/mesh compile: %s\n", error.description.UTF8String); return 1; }

    MTLMeshRenderPipelineDescriptor *pd = [MTLMeshRenderPipelineDescriptor new];
    pd.objectFunction = [library newFunctionWithName:@"task_object"];
    pd.meshFunction = [library newFunctionWithName:@"mesh_main"];
    pd.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    pd.payloadMemoryLength = 16;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithMeshDescriptor:pd options:0 reflection:nil error:&error];
    if (!pipeline) { fprintf(stderr, "object/mesh pipeline: %s\n", error.description.UTF8String); return 1; }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder drawMeshThreadgroups:MTLSizeMake(1, 1, 1)
       threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1)
         threadsPerMeshThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    if (command.error) { fprintf(stderr, "object/mesh execution: %s\n", command.error.description.UTF8String); return 1; }

    uint8_t pixels[4][4][4];
    [target getBytes:pixels bytesPerRow:sizeof pixels[0] fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
        const uint8_t *p = pixels[y][x];
        if (p[0] < 30 || p[0] > 34 || p[1] < 190 || p[1] > 193 || p[2] < 63 || p[2] > 65 || p[3] != 255) {
            fprintf(stderr, "object/mesh payload pixel %u,%u = %u,%u,%u,%u\n", x, y, p[0], p[1], p[2], p[3]); return 1;
        }
    }
    puts("object/mesh payload: 16 pixels passed");
    return 0;
} }
