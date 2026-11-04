// A streaming remap must retain GPU copies into previously mapped texture pages.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static void finish(void) {
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completed");
    CHECK(!mtl_last_commit_error(), "GPU copy succeeded");
}

static void partial_page_mirror(void) {
    const size_t len = 65536;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort(); memset(mem, 0x5a, len);
    pool_t physical, sparse; pool_builder_t pb = {.mem=mem, .size=len, .flags=0x24};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&physical, (const NVNmemoryPoolBuilder *)&pb), "partial-page physical pool initialized");
    pb = (pool_builder_t){.size=DM_GAME_APP_POOL + 4 * len, .flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&sparse, (const NVNmemoryPoolBuilder *)&pb), "partial-page virtual pool initialized");
    map_req map = {.phys=(NVNmemoryPool *)&physical, .poff=0x3000, .voff=0x1000, .size=0x1000};
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "4 KiB page mapped independently of host pages");
    NVNtextureBuilder tb; NVNtexture tex, hole, plain;
    h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetSize2D(&tb, 8, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0x1000); CHECK(h_nvnTextureInitialize(&tex, &tb), "partial-page texture initialized");
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0x4000); CHECK(h_nvnTextureInitialize(&hole, &tb), "unmapped texture initialized");
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&physical, 0x8000); CHECK(h_nvnTextureInitialize(&plain, &tb), "ordinary copy destination initialized");
    NVNcopyRegion region = {0,0,0,8,4,1}; uint8_t data[128], got[128], *want = malloc(len);
    for (unsigned i = 0; i < sizeof data; i++) data[i] = (uint8_t)(i * 13 + 3);
    memcpy(want, mem, len); nvn_swizzle(&((tex_t *)&tex)->d, 0, 0, data, 32, want + 0x3000);
    CHECK(!nvn_tex_mirror_b2t((tex_t *)&tex, 0, 0, &region, data, 32, 128), "copy into a page without a host alias");
    CHECK(!memcmp(mem, want, len), "mapped physical bytes updated with all neighbors preserved");
    nvn_sparse_protect(&sparse, (uint64_t)(uintptr_t)((tex_t *)&tex)->mem, ((tex_t *)&tex)->L.size);
    uint64_t stamp = nvn_dirty_now();
    CHECK(!nvn_tex_mirror_b2t((tex_t *)&tex, 0, 0, &region, data, 32, 128), "identical sparse readback succeeds");
    CHECK(!nvn_dirty_since(mem, len, stamp), "identical readback leaves physical aliases clean");
    h_nvnTextureReadTexels(&tex, NULL, &region, got);
    CHECK(!memcmp(got, data, sizeof data), "sparse CPU read sees mirrored bytes");
    CHECK(!nvn_tex_mirror_b2t((tex_t *)&hole, 0, 0, &region, data, 32, 128), "unmapped destination bytes discarded");
    CHECK(!memcmp(mem, want, len), "unmapped writes leave physical memory unchanged");
    CHECK(!nvn_tex_mirror_t2t((tex_t *)&tex, 0, 0, &region, (tex_t *)&plain, 0, 0, &region), "sparse source can mirror into an ordinary texture");
    nvn_deswizzle(&((tex_t *)&plain)->d, 0, 0, ((tex_t *)&plain)->mem, got, 32);
    CHECK(!memcmp(got, data, sizeof data), "sparse source copied exactly");
    h_nvnTextureFinalize(&tex); h_nvnTextureFinalize(&hole); h_nvnTextureFinalize(&plain);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&sparse); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&physical);
    defer_drain(); free(want); munmap(mem, len);
}

static void sparse_region_offsets(void) {
    const size_t len = 131072;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort(); memset(mem, 0x5a, len);
    pool_t physical, sparse; pool_builder_t pb = {.mem=mem, .size=len, .flags=0x24};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&physical, (const NVNmemoryPoolBuilder *)&pb), "region physical pool initialized");
    pb = (pool_builder_t){.size=DM_GAME_APP_POOL + 4 * len, .flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&sparse, (const NVNmemoryPoolBuilder *)&pb), "region virtual pool initialized");
    map_req map = {.phys=(NVNmemoryPool *)&physical, .size=len};
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "region pages mapped");
    NVNtextureBuilder tb; NVNtexture texture;
    h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetSize2D(&tb, 257, 35); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0); CHECK(h_nvnTextureInitialize(&texture, &tb), "region texture initialized");
    tex_t *t = (tex_t *)&texture;
    uint8_t *want = malloc(len), *full = malloc(257 * 35 * 4), data[249 * 27 * 4];
    memcpy(want, mem, len); memset(full, 0x5a, 257 * 35 * 4);
    for (unsigned i = 0; i < sizeof data; i++) data[i] = (uint8_t)(i * 29 + 7);
    for (unsigned y = 0; y < 27; y++) memcpy(full + ((y + 3) * 257 + 3) * 4, data + y * 249 * 4, 249 * 4);
    nvn_swizzle(&t->d, 0, 0, full, 257 * 4, want);
    NVNcopyRegion region = {3,3,0,249,27,1};
    CHECK(!nvn_tex_mirror_b2t(t, 0, 0, &region, data, 249 * 4, sizeof data), "unaligned sparse region copied across GOBs and pages");
    CHECK(!memcmp(mem, want, len), "region bytes and all untouched neighbors match the reference layout");
    for (unsigned y = 0; y < 32; y++) for (unsigned x = 0; x < 256 * 4; x++) full[y * 257 * 4 + x] = (uint8_t)(x * 23 + y * 11);
    nvn_swizzle(&t->d, 0, 0, full, 257 * 4, want);
    region = (NVNcopyRegion){0,0,0,256,32,1};
    CHECK(!nvn_tex_mirror_b2t(t, 0, 0, &region, full, 257 * 4, 257 * 32 * 4), "whole GOB region with padded source rows copied");
    CHECK(!memcmp(mem, want, len), "whole GOB fast path preserves neighboring rows and texels");
    uint8_t roundtrip[256 * 32 * 4];
    CHECK(!copy_region_bl(t, 0, 0, &region, roundtrip, 256 * 4, 1, 1, 4, 0), "whole GOB sparse source read");
    int rows_ok = 1;
    for (unsigned y = 0; y < 32; y++) rows_ok &= !memcmp(roundtrip + y * 256 * 4, full + y * 257 * 4, 256 * 4);
    CHECK(rows_ok, "whole GOB sparse read keeps every byte in linear order");
    nvn_sparse_protect(&sparse, (uint64_t)(uintptr_t)t->mem, t->L.size);
    uint64_t stamp = nvn_dirty_now();
    CHECK(!nvn_tex_mirror_b2t(t, 0, 0, &region, full, 257 * 4, 257 * 32 * 4), "identical whole GOB copy succeeds");
    CHECK(!nvn_dirty_since(mem, len, stamp), "identical whole GOB copy does not dirty its physical storage");
    h_nvnTextureFinalize(&texture); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&sparse); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&physical);
    defer_drain(); free(want); free(full); munmap(mem, len);
}

// Mario Kart World's streamed terrain uses this exact sparse shape.  Metal's
// mip tail does not necessarily begin at the same level as NVN's; the native
// path must still preserve the complete array instead of allocating it fully.
static void mkw_streamed_terrain_shape(void) {
    enum { PAGE = 65536 };
    NVNtextureBuilder tb; NVNtexture texture;
    h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY);
    h_nvnTextureBuilderSetSize3D(&tb, 3072, 3072, 2);
    h_nvnTextureBuilderSetLevels(&tb, 4);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8SN);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_SPARSE);
    size_t storage = h_nvnTextureBuilderGetStorageSize(&tb);
    uint8_t *mem = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(mem != MAP_FAILED, "MKW terrain physical tile allocated");
    if (mem == MAP_FAILED) abort();
    for (unsigned i = 0; i < PAGE; i++) mem[i] = (uint8_t)(i * 17 + 9);
    pool_t physical, sparse;
    pool_builder_t pb = {.mem=mem, .size=PAGE, .flags=0x24};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&physical, (const NVNmemoryPoolBuilder *)&pb), "MKW terrain physical pool initialized");
    pb = (pool_builder_t){.size=DM_GAME_APP_POOL + storage + PAGE, .flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&sparse, (const NVNmemoryPoolBuilder *)&pb), "MKW terrain sparse pool initialized");
    map_req map = {.phys=(NVNmemoryPool *)&physical, .size=PAGE};
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "MKW terrain first tile mapped");
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0);
    CHECK(h_nvnTextureInitialize(&texture, &tb), "MKW terrain sparse texture initialized");

    tex_t *t = (tex_t *)&texture;
    uint32_t ntw, nth, ntd;
    int tiled = nvn_tex_sparse_tiles(&t->d, &ntw, &nth, &ntd);
    MTLTextureDescriptor *d = tex_desc(t, 1);
    MTLSize mts = [g_dev sparseTileSizeWithTextureType:d.textureType pixelFormat:d.pixelFormat
                                           sampleCount:d.sampleCount sparsePageSize:MTLSparsePageSize64];
    MTLTextureDescriptor *placement = [d copy]; placement.placementSparsePageSize = MTLSparsePageSize64;
    id<MTLTexture> shape = [g_dev newTextureWithDescriptor:placement];
    printf("MKW sparse shape: storage=%zu layer=%llu guest-tail=%d guest-tile=%ux%ux%u metal-tail=%lu metal-tail-bytes=%lu metal-tile=%lux%lux%lu\n",
           storage, (unsigned long long)t->L.layer_size, tiled, ntw, nth, ntd,
           (unsigned long)shape.firstMipmapInTail, (unsigned long)shape.tailSizeInBytes,
           (unsigned long)mts.width, (unsigned long)mts.height, (unsigned long)mts.depth);
    CHECK(shape && shape.isSparse, "MKW terrain shape is a Metal placement-sparse texture");

    mtl_sub_begin();
    id<MTLTexture> native = tex_mtl(t);
    CHECK(native && native.isSparse, "MKW terrain uses native sparse backing");
    finish();

    // Stream the adjacent NVN tile from the same physical page. The Metal
    // object must remain stable and both virtual tiles must expose the same
    // bytes; rebuilding here is the per-frame churn seen in MKW.
    map.voff = PAGE; map.poff = 0;
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map),
          "MKW terrain adjacent tile remapped");
    mtl_sub_begin();
    id<MTLTexture> after = tex_mtl(t);
    CHECK(after == native, "MKW terrain remap preserves the Metal texture");
    id<MTLBuffer> read = [g_dev newBufferWithLength:2 * PAGE options:MTLResourceStorageModeShared]; res_add(read);
    enc_b_copy_texture_buffer(blit(), after, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(128, 128, 1), read, 0, 512, PAGE);
    enc_b_copy_texture_buffer(blit(), after, 0, 0, MTLOriginMake(128, 0, 0), MTLSizeMake(128, 128, 1), read, PAGE, 512, PAGE);
    finish();
    CHECK(!memcmp(read.contents, (uint8_t *)read.contents + PAGE, PAGE),
          "MKW terrain aliased tiles keep identical texels after remap");
    res_remove(read);
    h_nvnTextureFinalize(&texture);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&sparse);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&physical);
    defer_drain(); munmap(mem, PAGE);
}

// Exercise the harder form of the same layout: NVN has already put the small
// levels in one guest tail while Metal still exposes two of them as tiles.
static void guest_tail_before_metal_tail(void) {
    enum { PAGE = 65536 };
    NVNtextureBuilder tb; NVNtexture texture;
    h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY);
    h_nvnTextureBuilderSetSize3D(&tb, 3072, 3072, 2);
    h_nvnTextureBuilderSetLevels(&tb, 12);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8SN);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_SPARSE);
    size_t storage = h_nvnTextureBuilderGetStorageSize(&tb);
    uint8_t *mem = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(mem != MAP_FAILED, "split-tail physical tile allocated");
    if (mem == MAP_FAILED) abort(); memset(mem, 0x39, PAGE);
    pool_t physical, sparse;
    pool_builder_t pb = {.mem=mem, .size=PAGE, .flags=0x24};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&physical, (const NVNmemoryPoolBuilder *)&pb), "split-tail physical pool initialized");
    pb = (pool_builder_t){.size=DM_GAME_APP_POOL + storage + PAGE, .flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&sparse, (const NVNmemoryPoolBuilder *)&pb), "split-tail sparse pool initialized");
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0);
    CHECK(h_nvnTextureInitialize(&texture, &tb), "split-tail sparse texture initialized");
    tex_t *t = (tex_t *)&texture;
    uint32_t ntw, nth, ntd;
    int tiled = nvn_tex_sparse_tiles(&t->d, &ntw, &nth, &ntd);
    uint64_t tail = nvn_tex_level_offset(&t->d, (unsigned)tiled);
    map_req map = {.phys=(NVNmemoryPool *)&physical, .voff=(int64_t)tail, .size=PAGE};
    CHECK(!(tail & (PAGE - 1)) && h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "guest tail page mapped");
    MTLTextureDescriptor *d = tex_desc(t, 1), *placement = [d copy];
    placement.placementSparsePageSize = MTLSparsePageSize64;
    id<MTLTexture> shape = [g_dev newTextureWithDescriptor:placement];
    CHECK(shape && MIN(shape.firstMipmapInTail, d.mipmapLevelCount) > (NSUInteger)tiled, "Metal tail starts after the guest tail");
    id<MTLTexture> native = native_sparse_upload(t, d);
    CHECK(native && native.isSparse, "guest tail maps across Metal tiled levels and mip tail");
    if (native) res_remove(native);
    h_nvnTextureFinalize(&texture);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&sparse);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&physical);
    defer_drain(); munmap(mem, PAGE);
}

static void streaming_copy(void) {
    NVNtextureBuilder tb; NVNtexture src, dst;
    h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY);
    h_nvnTextureBuilderSetSize3D(&tb, 1024, 1024, 2);
    h_nvnTextureBuilderSetLevels(&tb, 11);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA_ASTC_8x8_SRGB);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_SPARSE);
    size_t layer = h_nvnTextureBuilderGetStorageSize(&tb) / 2, len = layer * 3;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(mem != MAP_FAILED && layer % 65536 == 0, "physical sparse tiles allocated");
    if (mem == MAP_FAILED) abort();
    pool_t physical, sparse;
    pool_builder_t pb = {.mem=mem, .size=len, .flags=0x24};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&physical, (const NVNmemoryPoolBuilder *)&pb), "physical pool initialized");
    pb = (pool_builder_t){.size=DM_GAME_APP_POOL + 4 * len, .flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&sparse, (const NVNmemoryPoolBuilder *)&pb), "sparse pool initialized");
    map_req map = {.phys=(NVNmemoryPool *)&physical, .poff=layer, .voff=layer, .size=layer};
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "only array slice one mapped");
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&sparse, 0);
    CHECK(h_nvnTextureInitialize(&dst, &tb), "sparse texture initialized");
    h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetSize2D(&tb, 64, 32);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA_ASTC_8x8_SRGB);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&physical, 2 * layer);
    CHECK(h_nvnTextureInitialize(&src, &tb), "source texture initialized");
    uint8_t pattern[512], cpu[512];
    for (unsigned i = 0; i < sizeof pattern; i++) pattern[i] = (uint8_t)(i * 37 + 19);
    NVNcopyRegion region = {0, 0, 0, 64, 32, 1};
    h_nvnTextureWriteTexels(&src, NULL, &region, pattern);

    mtl_sub_begin();
    id<MTLTexture> before = tex_mtl((tex_t *)&dst);
    CHECK(before.isSparse, "placement sparse upload selected");
    uint64_t uploads = g_pkg_reuploads;
    for (int level = 0; level < 2; level++) {
        if (level) {
            map_req unrelated = {.phys=(NVNmemoryPool *)&physical, .voff=3 * layer, .size=65536};
            CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&unrelated), "unrelated mapping changed the global generation");
        }
        p_copy_t2t c = {.src=(tex_t *)&src, .dst=(tex_t *)&dst, .sr=region, .dr=region, .has_dv=1};
        c.dv = (view_t){.set_levels=1, .base_level=level, .set_layers=1, .min_layer=1};
        copy_t2t(&c);
        CHECK(tex_mtl((tex_t *)&dst) == before, "copy mirror keeps the texture already updated by the GPU");
    }
    finish();
    CHECK(g_pkg_reuploads == uploads, "mirrored writes do not trigger redundant uploads");
    h_nvnTextureReadTexels(&dst, (NVNtextureView *)&(view_t){.set_layers=1, .min_layer=1}, &region, cpu);
    CHECK(!memcmp(cpu, pattern, sizeof cpu), "sparse physical pages contain the copied compressed blocks");

    // Mapping a different layer recreates the native sparse texture. Earlier
    // copies must survive in both the physical pages and the new Metal object.
    map.poff = map.voff = 0;
    CHECK(h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)&sparse, 1, (const NVNmappingRequest *)&map), "another array slice mapped");
    mtl_sub_begin();
    id<MTLTexture> after = tex_mtl((tex_t *)&dst);
    CHECK(after && after != before && after.isSparse, "mapping change rebuilt sparse backing");
    id<MTLBuffer> read = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; res_add(read);
    for (int level = 0; level < 2; level++)
        enc_b_copy_texture_buffer(blit(), after, 1, level, MTLOriginMake(0,0,0), MTLSizeMake(64,32,1), read, level * 512, 128, 512);
    finish();
    CHECK(!memcmp(read.contents, pattern, 512), "base level survived remapping byte for byte");
    CHECK(!memcmp((uint8_t *)read.contents + 512, pattern, 512), "nonzero mip survived remapping byte for byte");

    // A later CPU change still invalidates the absorbed copy stamp.
    pattern[0] ^= 0x44;
    CHECK(!nvn_tex_mirror_b2t((tex_t *)&dst, 0, 1, &region, pattern, 128, 512), "later physical write prepared");
    CHECK(tex_mtl((tex_t *)&dst) != after, "later physical writes are not swallowed by copy absorption");
    res_remove(read); h_nvnTextureFinalize(&src); h_nvnTextureFinalize(&dst);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&sparse); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&physical);
    defer_drain(); munmap(mem, len);
}
int main(void) { @autoreleasepool {
    alarm(60); setenv("DM_NVN_NATIVE_SPARSE", "1", 1);
    mtl_init();
    for (int gob = 0; gob < 2; gob++) { nvn_gob_switch2 = gob; partial_page_mirror(); sparse_region_offsets(); }
    mkw_streamed_terrain_shape();
    guest_tail_before_metal_tail();
    streaming_copy();
    printf("t_sparse_texture_mirror: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
