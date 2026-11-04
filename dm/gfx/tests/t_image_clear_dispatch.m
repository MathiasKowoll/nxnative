// A pending attachment clear must reach an image read before compute, without a target change or draw.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
typedef struct { uint8_t bytes[4096]; size_t n; } commands;
static void emit(commands *c, unsigned op, const void *data, size_t n) {
    size_t size = (8 + n + 7) & ~7ull;
    if (c->n + size > sizeof c->bytes) abort();
    op_hdr h = {op, (uint32_t)size}; memcpy(c->bytes + c->n, &h, 8);
    if (n) memcpy(c->bytes + c->n + 8, data, n);
    c->n += size;
}
int main(void) { @autoreleasepool {
    mtl_init();
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { texture2d<float, access::read> image [[id(0)]]; device float *out [[id(1)]]; };\n"
        "kernel void read_image(constant Args &a [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { a.out[p.y * 8 + p.x] = a.image.read(p).x; }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    CHECK(lib != nil, "image reader compiled");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    prog_t program = {.serial=990101}; NvProg *pr = [NvProg new]; NvShader *cs = [NvShader new]; pr->sh[5] = cs;
    cs->stage = 5; cs->fn = [lib newFunctionWithName:@"read_image"];
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0];
    cs->rf.tg[0] = cs->rf.tg[1] = cs->rf.tg[2] = 1;
    cs->rf.nb = 2;
    cs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_IMG, .reg=0, .aid=0, .dtt=MTLTextureType2D, .dpf=NVN_DPF_FLOAT};
    cs->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SBUFP, .rw=1, .reg=0, .aid=1};
    serial_put(program.serial, pr);
    void *memory = NULL; if (posix_memalign(&memory, getpagesize(), getpagesize())) abort();
    memset(memory, 0, getpagesize()); mtl_pool_add(memory, getpagesize());
    tex_t texture = {.magic=MAGIC('T','E','X',0), .serial=990102, .off=0x99000000};
    texture.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_R32F, .flags=NVN_TEXTURE_FLAGS_IMAGE,
                            .width=8, .height=8, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&texture.d, &texture.L); mtl_tex_init(&texture); mtl_reg_image(630, &texture, NULL);
    // Different consecutive clears catch both initial zero and stale prior-frame image contents.
    for (int iteration=0; iteration<2; iteration++) {
        float expected = iteration ? 0.75f : 0.25f;
        for (int i=0; i<64; i++) ((float *)memory)[i] = -1;
        state_reset(); memset(&R, 0, sizeof R);
        S.cprog = &program; S.img[5][0] = 630;
        S.ssbo[5][0] = (p_bind_buf){.addr=(uint64_t)memory, .size=64 * sizeof(float)};
        commands c = {0}; p_set_rt rt = {.n=1}; rt.color[0] = &texture;
        p_clear_color clear = {.index=0, .mask=0xf, .rgba={expected, 0, 0, 1}};
        p_dispatch compute = {.x=8, .y=8, .z=1};
        emit(&c, OP_SET_RT, &rt, sizeof rt); emit(&c, OP_CLEAR_COLOR, &clear, sizeof clear);
        emit(&c, OP_DISPATCH, &compute, sizeof compute); emit(&c, OP_END, NULL, 0);
        mtl_sub_begin(); mtl_exec(c.bytes); mtl_sub_commit(); mtl_drain();
        int same = 1; for (int i=0; i<64; i++) same &= ((float *)memory)[i] == expected;
        if (!same) fprintf(stderr, "iteration %d: first pixel %g, expected %g\n", iteration, ((float *)memory)[0], expected);
        CHECK(same, "compute image read observes the preceding clear at every pixel");
    }
    printf("clear before compute image read: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
