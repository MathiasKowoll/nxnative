// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
// f: filter (0 bilinear, 1 Catmull-Rom bicubic, 2 Lanczos-3, 3 sharp pixels),
// sharpening amount (0 off, up to 1), and the source texture size.
struct Crop { float4 rect; float4 edge; float4 f; };
// Every tap is clamped to the valid rectangle's texel centres: no filter reads
// the black texels outside the game's crop.
static float4 tap(texture2d<float> t, sampler s, constant Crop& c, float2 uv) {
    return t.sample(s, clamp(uv, c.edge.xy, c.edge.zw));
}
static float4 bicubic(texture2d<float> t, sampler s, constant Crop& c, float2 uv) {
    float2 sz = c.f.zw, p = uv * sz - 0.5, b = floor(p), f = p - b;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2, t0 = (b - 0.5) / sz, t3 = (b + 2.5) / sz;
    float2 t12 = (b + 0.5 + w2 / w12) / sz;
    float2 xs[3] = {float2(t0.x, w0.x), float2(t12.x, w12.x), float2(t3.x, w3.x)};
    float2 ys[3] = {float2(t0.y, w0.y), float2(t12.y, w12.y), float2(t3.y, w3.y)};
    float4 r = 0;
    for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++)
        r += tap(t, s, c, float2(xs[i].x, ys[j].x)) * (xs[i].y * ys[j].y);
    return r;
}
static float lz(float x) {
    x = abs(x); if (x < 1e-5) return 1.0; if (x >= 3.0) return 0.0;
    float px = M_PI_F * x; return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
}
static float4 lanczos(texture2d<float> t, sampler s, constant Crop& c, float2 uv) {
    float2 sz = c.f.zw, p = uv * sz - 0.5, b = floor(p), f = p - b;
    float wx[6], wy[6]; float sx = 0, sy = 0;
    for (int i = 0; i < 6; i++) { wx[i] = lz(f.x - (i - 2)); wy[i] = lz(f.y - (i - 2)); sx += wx[i]; sy += wy[i]; }
    float4 r = 0;
    for (int j = 0; j < 6; j++) {
        float4 row = 0;
        for (int i = 0; i < 6; i++) row += tap(t, s, c, (b + float2(i - 2, j - 2) + 0.5) / sz) * wx[i];
        r += row * wy[j];
    }
    return r / (sx * sy);
}
static float4 sharp_pixels(texture2d<float> t, sampler s, constant Crop& c, float2 uv) {
    float2 sz = c.f.zw, tx = uv * sz, scale = max(1.0 / max(fwidth(tx), 1e-6), 1.0);
    float2 fl = floor(tx), d = fract(tx) - 0.5, region = 0.5 - 0.5 / scale;
    return tap(t, s, c, (fl + (d - clamp(d, -region, region)) * scale + 0.5) / sz);
}
// Contrast-adaptive sharpening (AMD FidelityFX CAS weighting): sharpen
// against four neighbours, less where the neighbourhood is near black/white.
static float4 cas(texture2d<float> t, sampler s, constant Crop& c, float2 uv, float4 m) {
    float2 d = 1.0 / c.f.zw;
    float3 n = tap(t, s, c, uv - float2(0, d.y)).rgb;
    float3 so = tap(t, s, c, uv + float2(0, d.y)).rgb;
    float3 w = tap(t, s, c, uv - float2(d.x, 0)).rgb;
    float3 e = tap(t, s, c, uv + float2(d.x, 0)).rgb;
    float3 mn = min(m.rgb, min(min(n, so), min(w, e)));
    float3 mx = max(m.rgb, max(max(n, so), max(w, e)));
    float3 wt = -sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4))) / mix(8.0, 5.0, c.f.y);
    return float4(saturate((m.rgb + (n + so + w + e) * wt) / (1.0 + 4.0 * wt)), m.a);
}
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float2 uv = in.uv * c.rect.zw + c.rect.xy; int mode = int(c.f.x); float4 m;
    if (mode == 1) m = bicubic(t, s, c, uv);
    else if (mode == 2) m = lanczos(t, s, c, uv);
    else if (mode == 3) m = sharp_pixels(t, s, c, uv);
    else m = tap(t, s, c, uv);
    if (mode == 1 || mode == 2) m = float4(saturate(m.rgb), m.a);
    return c.f.y > 0 ? cas(t, s, c, uv, m) : m;
}
