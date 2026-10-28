// Present filter and sharpening (DM_PRESENT_FILTER, DM_PRESENT_SHARPEN): real Metal rendering through present_encode_m4, no game.
// A synthetic scene (zone plate, thin diagonals, text-like blocks, gradients) is drawn at the output size as the reference and box-filtered to a third as
// the "game" picture; each filter scales that third back up, and the result is compared with the reference (PSNR) and with itself (gradient energy, the
// sharpness). Closed-form checks: the defaults are the bilinear present byte for byte, a flat picture stays flat, a 1:1 present is the picture itself,
// sharp pixels at an integer scale is exactly nearest. Then the GPU time of each filter, 1280x720 to 3840x2160, through the classic present (same shader).
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

static int failed, cases;
#define CHECK(name, ok, ...) do { cases++; int k_ = (ok); printf("%s %s ", k_ ? "✓" : "✗", name); printf(__VA_ARGS__); printf("\n"); failed += !k_; } while (0)

static id<MTLTexture> tex(int w, int h, MTLTextureUsage u) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = u; id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); res_commit(); return t;
}
static void upload(id<MTLTexture> t, const uint8_t *px) { [t replaceRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0 withBytes:px bytesPerRow:4 * t.width]; }
static uint8_t *readback(id<MTLTexture> t) {
    uint8_t *px = malloc(4 * t.width * t.height);
    [t getBytes:px bytesPerRow:4 * t.width fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0]; return px;
}
// One present of src into a new w x h texture with the given filter and sharpening, through the Metal 4 present
static uint8_t *present(id<MTLTexture> src, int w, int h, int mode, float sharpen) {
    g_pf_mode = mode; g_pf_sharpen = sharpen;
    id<MTLTexture> out = tex(w, h, MTLTextureUsageRenderTarget);
    id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; id<MTLSharedEvent> ev = [g_dev newSharedEvent];
    [cb beginCommandBufferWithAllocator:al]; int kind = present_encode_m4(cb, src, out, NULL, g_present_uv[0], NULL); [cb endCommandBuffer];
    [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
    if (!kind || ![ev waitUntilSignaledValue:1 timeoutMS:10000]) { printf("✗ present did not complete\n"); exit(1); }
    uint8_t *px = readback(out); res_remove(out); return px;
}

// The reference scene at (w, h): a zone plate (rings whose frequency rises to the edge), thin diagonal lines, text-like blocks, two gradients
static uint8_t *scene(int w, int h) {
    uint8_t *px = malloc(4 * w * h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float u = (float)x / w, v = (float)y / h, r, g, b;
        if (u < 0.5f && v < 0.5f) { float dx = x - w / 4.0f, dy = y - h / 4.0f; r = g = b = 0.5f + 0.5f * cosf((dx * dx + dy * dy) * 3.14159f / (w * 0.9f)); }
        else if (u >= 0.5f && v < 0.5f) { int d = (x + y) % 9; r = g = b = d < 2 ? 0.95f : 0.08f; g = d == 4 ? 0.8f : g; }
        else if (u < 0.5f) { int cx = (x / 6) % 7, cy = (y / 9) % 4; r = g = b = (cx < 5 && cy < 3 && ((x / 2 + y / 3) % 3)) ? 0.05f : 0.92f; }
        else { r = u * 2 - 1; g = v * 2 - 1; b = 0.3f + 0.4f * ((x / 32 + y / 32) & 1); }
        uint8_t *p = px + 4 * (y * w + x); p[0] = r * 255 + 0.5f; p[1] = g * 255 + 0.5f; p[2] = b * 255 + 0.5f; p[3] = 255;
    }
    return px;
}
static uint8_t *box_down(const uint8_t *src, int w, int h, int k) {   // the "game" picture: each k x k block averaged
    int ow = w / k, oh = h / k; uint8_t *px = malloc(4 * ow * oh);
    for (int y = 0; y < oh; y++) for (int x = 0; x < ow; x++) for (int c = 0; c < 4; c++) {
        int s = 0; for (int j = 0; j < k; j++) for (int i = 0; i < k; i++) s += src[4 * ((y * k + j) * w + x * k + i) + c];
        px[4 * (y * ow + x) + c] = (s + k * k / 2) / (k * k);
    }
    return px;
}
static double psnr(const uint8_t *a, const uint8_t *b, int n) {
    double se = 0; for (int i = 0; i < n; i++) if (i % 4 != 3) { double d = (double)a[i] - b[i]; se += d * d; }
    double mse = se / (n / 4 * 3); return mse == 0 ? 99 : 10 * log10(255.0 * 255.0 / mse);
}
static double sharpness(const uint8_t *a, int w, int h) {   // mean absolute horizontal + vertical difference of the luma
    double s = 0;
    for (int y = 0; y < h - 1; y++) for (int x = 0; x < w - 1; x++) {
        const uint8_t *p = a + 4 * (y * w + x), *r = p + 4, *d = p + 4 * w;
        double l = p[0] * 0.3 + p[1] * 0.59 + p[2] * 0.11, lr = r[0] * 0.3 + r[1] * 0.59 + r[2] * 0.11, ld = d[0] * 0.3 + d[1] * 0.59 + d[2] * 0.11;
        s += fabs(l - lr) + fabs(l - ld);
    }
    return s / ((w - 1) * (h - 1));
}
static int max_diff(const uint8_t *a, const uint8_t *b, int n) { int m = 0; for (int i = 0; i < n; i++) { int d = abs(a[i] - b[i]); if (d > m) m = d; } return m; }

int main(void) { @autoreleasepool {
    mtl_init();
    const char *names[4] = {"bilinear", "bicubic", "lanczos", "sharp pixels"};

    // 1. Defaults are the bilinear present byte for byte: f = 0, sharpen 0 takes the same expression the shader always had (t_present_crop checks its values)
    {   uint8_t px[16 * 16 * 4]; for (int i = 0; i < 16 * 16; i++) { px[4 * i] = i * 7; px[4 * i + 1] = 255 - i; px[4 * i + 2] = (i * 13) & 255; px[4 * i + 3] = 255; }
        id<MTLTexture> s = tex(16, 16, MTLTextureUsageShaderRead); upload(s, px);
        g_pf_mode = -1; setenv("DM_PRESENT_FILTER", "", 1); setenv("DM_PRESENT_SHARPEN", "", 1);
        int mode; float sh; present_filter(&mode, &sh);
        CHECK("defaults: bilinear, no sharpening", mode == 0 && sh == 0, "(mode %d, sharpen %.2f)", mode, sh);
        g_pf_mode = -1; setenv("DM_PRESENT_FILTER", "lanczos", 1); setenv("DM_PRESENT_SHARPEN", "0.6", 1); present_filter(&mode, &sh);
        CHECK("DM_PRESENT_FILTER=lanczos DM_PRESENT_SHARPEN=0.6 are read", mode == 2 && fabsf(sh - 0.6f) < 1e-6, "(mode %d, sharpen %.2f)", mode, sh);
        g_pf_mode = -1; setenv("DM_PRESENT_FILTER", "magic", 1); setenv("DM_PRESENT_SHARPEN", "7", 1); present_filter(&mode, &sh);
        CHECK("an unknown filter keeps bilinear, sharpening is clamped to 1", mode == 0 && sh == 1, "(mode %d, sharpen %.2f)", mode, sh);
        unsetenv("DM_PRESENT_FILTER"); unsetenv("DM_PRESENT_SHARPEN");
        res_remove(s);
    }

    // 2. A flat picture stays flat, scaled up 3x, with every filter and with sharpening
    {   uint8_t px[20 * 12 * 4]; for (int i = 0; i < 20 * 12; i++) { px[4 * i] = 120; px[4 * i + 1] = 60; px[4 * i + 2] = 200; px[4 * i + 3] = 255; }
        id<MTLTexture> s = tex(20, 12, MTLTextureUsageShaderRead); upload(s, px);
        for (int m = 0; m < 4; m++) for (int k = 0; k < 2; k++) {
            uint8_t *o = present(s, 60, 36, m, k ? 1.0f : 0); int worst = 0;
            for (int i = 0; i < 60 * 36; i++) { int d = abs(o[4 * i] - 120) + abs(o[4 * i + 1] - 60) + abs(o[4 * i + 2] - 200); if (d > worst) worst = d; }
            char n[96]; snprintf(n, sizeof n, "flat stays flat: %s%s", names[m], k ? " + sharpening 1" : "");
            CHECK(n, worst <= 1, "(largest difference %d)", worst); free(o);
        }
        res_remove(s);
    }

    // 3. 1:1: the interpolating filters return each texel itself (no sharpening)
    {   int w = 64, h = 36; uint8_t *ref = scene(w, h); id<MTLTexture> s = tex(w, h, MTLTextureUsageShaderRead); upload(s, ref);
        for (int m = 0; m < 4; m++) {
            uint8_t *o = present(s, w, h, m, 0); int d = max_diff(o, ref, 4 * w * h);
            char n[64]; snprintf(n, sizeof n, "1:1 is the picture itself: %s", names[m]); CHECK(n, d <= 1, "(largest difference %d)", d); free(o);
        }
        // 4. Sharp pixels at an integer scale (3x) is exactly nearest
        uint8_t *o = present(s, 3 * w, 3 * h, 3, 0); int d = 0;
        for (int y = 0; y < 3 * h; y++) for (int x = 0; x < 3 * w; x++) for (int c = 0; c < 3; c++) { int e = abs(o[4 * (y * 3 * w + x) + c] - ref[4 * ((y / 3) * w + x / 3) + c]); if (e > d) d = e; }
        CHECK("sharp pixels at 3x is nearest", d <= 1, "(largest difference %d)", d); free(o); free(ref); res_remove(s);
    }

    // 5. Quality: scale a third of the scene back up 3x and compare with the scene drawn at full size
    {   int W = 960, H = 540, k = 3; uint8_t *ref = scene(W, H), *small = box_down(ref, W, H, k);
        id<MTLTexture> s = tex(W / k, H / k, MTLTextureUsageShaderRead); upload(s, small);
        double ps[4][3], sh[4][3], ref_sharp = sharpness(ref, W, H); float amounts[3] = {0, 0.5f, 1};
        printf("\n%-14s %-10s %8s %10s\n", "filter", "sharpen", "PSNR dB", "sharpness");
        printf("%-14s %-10s %8s %10.2f\n", "(reference)", "", "", ref_sharp);
        for (int m = 0; m < 4; m++) for (int a = 0; a < 3; a++) {
            uint8_t *o = present(s, W, H, m, amounts[a]); ps[m][a] = psnr(o, ref, 4 * W * H); sh[m][a] = sharpness(o, W, H);
            printf("%-14s %-10.1f %8.2f %10.2f\n", names[m], amounts[a], ps[m][a], sh[m][a]);
            const char *dump = getenv("PRESENT_FILTER_DUMP");   // a folder: each result as a raw RGBA file, to look at
            if (dump) { char p[512]; snprintf(p, sizeof p, "%s/%d_%d.rgba", dump, m, a); FILE *f = fopen(p, "wb"); if (f) { fwrite(o, 1, 4 * W * H, f); fclose(f); } }
            free(o);
        }
        // MetalFX's spatial scaler (DM_PRESENT_UPSCALE=metalfx), alone and with sharpening, for comparison: the picture comes back drawn 1:1
        if (g_q4 && [MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {
            g_fx_mode = 1;
            for (int a = 0; a < 3; a++) {
                static fx_state fx; g_pf_mode = 0; g_pf_sharpen = amounts[a];
                id<MTLTexture> out = tex(W, H, MTLTextureUsageRenderTarget);
                id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; id<MTLSharedEvent> ev = [g_dev newSharedEvent];
                [cb beginCommandBufferWithAllocator:al]; int kind = present_encode_m4(cb, s, out, NULL, g_present_uv[0], &fx); [cb endCommandBuffer];
                [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1]; [ev waitUntilSignaledValue:1 timeoutMS:10000];
                uint8_t *o = readback(out); res_remove(out);
                printf("%-14s %-10.1f %8.2f %10.2f%s\n", "MetalFX", amounts[a], psnr(o, ref, 4 * W * H), sharpness(o, W, H), kind == PRESENT_METALFX ? "" : " (bilinear: no scaler)");
                free(o);
            }
            g_fx_mode = 0;
        }
        printf("\n");
        CHECK("bicubic is sharper than bilinear", sh[1][0] > sh[0][0] * 1.03, "(%.2f against %.2f)", sh[1][0], sh[0][0]);
        CHECK("Lanczos is sharper than bicubic", sh[2][0] > sh[1][0], "(%.2f against %.2f)", sh[2][0], sh[1][0]);
        CHECK("bicubic is closer to the full-size scene than bilinear", ps[1][0] > ps[0][0], "(%.2f against %.2f dB)", ps[1][0], ps[0][0]);
        CHECK("Lanczos is closer to the full-size scene than bilinear", ps[2][0] > ps[0][0], "(%.2f against %.2f dB)", ps[2][0], ps[0][0]);
        for (int m = 0; m < 3; m++) {
            char n[64]; snprintf(n, sizeof n, "sharpening rises with the amount: %s", names[m]);
            CHECK(n, sh[m][2] > sh[m][1] && sh[m][1] > sh[m][0], "(%.2f, %.2f, %.2f)", sh[m][0], sh[m][1], sh[m][2]);
        }
        free(ref); free(small); res_remove(s);
    }

    // 6. GPU time per present, 1280x720 to 3840x2160, through the classic present (the same shader); the median of 30
    {   int w = 1280, h = 720; uint8_t *ref = scene(w, h); id<MTLTexture> s = tex(w, h, MTLTextureUsageShaderRead); upload(s, ref);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:3840 height:2160 mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget; id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
        // The GPU clock rises under sustained load: one filter after another would favour the last ones. Warm up first, then take the filters in turn every round
        printf("GPU time per present, 1280x720 to 3840x2160 (median of 40 rounds, filters in turn, after a warm-up):\n");
        enum { NV = 5, ROUNDS = 40 }; int modes[NV] = {0, 1, 2, 3, 0}; float shs[NV] = {0, 0, 0, 0, 0.5f}; double t[NV][ROUNDS];
        for (int r = -60; r < ROUNDS; r++) for (int i = 0; i < NV; i++) {
            g_pf_mode = modes[i]; g_pf_sharpen = shs[i];
            id<MTLCommandBuffer> cb = [g_q commandBuffer]; present_encode(cb, s, out, NULL); [cb commit]; [cb waitUntilCompleted];
            if (r >= 0) t[i][r] = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
        }
        for (int i = 0; i < NV; i++) {
            double *v = t[i]; for (int a = 1; a < ROUNDS; a++) { double x = v[a]; int b = a - 1; while (b >= 0 && v[b] > x) { v[b + 1] = v[b]; b--; } v[b + 1] = x; }
            printf("  %-14s%s %.3f ms\n", names[modes[i]], shs[i] > 0 ? " + CAS 0.5" : "          ", v[ROUNDS / 2]);
        }
        free(ref); res_remove(s);
    }
    printf("== %d checks, %d failed ==\n", cases, failed);
    return failed != 0;
} }
