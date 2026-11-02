//     (x%64/32)·256 + (y%8/2)·64 + (x%32/16)·32 + (y%2)·16 + x%16
// Tegra X1 block-linear layout (public descriptions: deko3d / Ryujinx BlockLinearLayout):
//   GOB = 64 bytes × 8 rows = 512 bytes; offset of (x byte, y row) within a GOB =
//     (x%64/32)·256 + (y%8/2)·64 + (x%32/16)·32 + (y%2)·16 + x%16
//   block = 1 GOB wide × 2^tileH GOBs high × 2^tileD GOBs deep, ordered y first then z within a block; blocks fill the level in x → y → z row-major order.
// Level / layer start offsets and the actual block height and block depth of this level come from nvn_tex.c; here we only do intra-level addressing and copying.
#include "nvn_deswizzle.h"
#include <string.h>

static uint32_t native_gob_off(uint32_t off, int native_tiling) {
    if (native_tiling) {
        // Switch 2's native GOB order exchanges offset bits 5 and 6. This is
        // the same transform used by Eglantine's block-linear and ASTC paths.
        uint32_t difference = ((off >> 5) ^ (off >> 6)) & 1u;
        off ^= (difference << 5) | (difference << 6);
    }
    return off;
}

static uint32_t gob_off(uint32_t x, uint32_t y, int native_tiling) {
    uint32_t off = (x % 64 / 32) * 256 + (y % 8 / 2) * 64 + (x % 32 / 16) * 32 + (y % 2) * 16 + x % 16;
    return native_gob_off(off, native_tiling);
}

uint64_t nvn_bl_offset_native(uint32_t x, uint32_t y, uint32_t z, uint32_t row_bytes, uint32_t rows, unsigned th, unsigned td, int native_tiling) {
    uint32_t bh = 1u << th, bd = 1u << td;
    uint64_t gobs_x = (row_bytes + 63) / 64, blocks_y = (rows + 8 * bh - 1) / (8 * bh);
    uint64_t block = 512ull * bh * bd;                                  // bytes in one block
    return (z / bd) * gobs_x * blocks_y * block                        // which block layer (along depth)
         + (y / (8 * bh)) * gobs_x * block                             // which block row
         + (x / 64) * block                                            // which block column
         + ((z % bd) * bh + (y % (8 * bh)) / 8) * 512ull               // which GOB within the block
         + gob_off(x, y, native_tiling);
}

uint64_t nvn_bl_offset(uint32_t x, uint32_t y, uint32_t z, uint32_t row_bytes, uint32_t rows, unsigned th, unsigned td) {
    return nvn_bl_offset_native(x, y, z, row_bytes, rows, th, td, 0);
}

static uint32_t mip(uint32_t s, unsigned l) { s >>= l; return s ? s : 1; }

// Geometry of this level: width-in-blocks byte count, block row count, slice count, and where this level and layer starts in storage; returns -1 for unsupported textures
int nvn_deswizzle_geom(const nvn_texdesc *d, unsigned level, unsigned layer,
                       uint32_t *row_bytes, uint32_t *rows, uint32_t *slices, uint64_t *base, unsigned *th, unsigned *td, uint32_t *bpb) {
    if (d->target == 5 || d->target == 6 || d->target == 10 || (d->flags & 0x50) || d->samples > 1) return -1;   // MS / BUFFER / LINEAR / LINEAR_RENDER_TARGET
    int bw, bh; *bpb = (uint32_t)nvn_fmt_bpb(d->format, &bw, &bh);
    if (!*bpb || level >= (d->levels ? d->levels : 1)) return -1;
    nvn_texlayout L; nvn_tex_layout(d, &L);
    if (layer >= L.layers) return -1;
    int one_d = d->target == 0 || d->target == 3;
    uint32_t w = mip(d->width, level), h = one_d ? 1 : mip(d->height, level);
    *slices = d->target == 2 ? mip(d->depth ? d->depth : 1, level) : 1;
    *row_bytes = (w + bw - 1) / bw * *bpb; *rows = (h + bh - 1) / bh;
    *base = (uint64_t)layer * L.layer_size + nvn_tex_level_offset(d, level);
    nvn_tex_level_tiles(d, level, th, td);
    return 0;
}

static int move(const nvn_texdesc *d, unsigned level, unsigned layer, uint8_t *bl, uint8_t *lin, size_t pitch, int to_linear, int at_level) {
    uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
    if (nvn_deswizzle_geom(d, level, layer, &row_bytes, &rows, &slices, &base, &th, &td, &bpb)) return -1;
    if (pitch < row_bytes) return -1;
    if (!at_level) bl += base;
    uint32_t lb = nvn_tex_level_gobs(d, level) * 64;   // the row as laid out (padded in a sparse texture's tiled levels)
    if (lb < row_bytes) lb = row_bytes;
    // Hoist nvn_bl_offset's slice and row terms out of the segment loop. The block height and depth are powers of two,
    // so their division / remainder become shifts and masks. At x = 16*j the block column is j >> 2, and the segment
    // has one of four positions inside the GOB (x%64 = 0/16/32/48 -> 0/32/256/288); the y part depends only on y%8.
    static const uint16_t kox[4] = {0, 32, 256, 288};                         // x%16 is always 0 here: segments start at multiples of 16
    static const uint16_t koy[8] = {0, 16, 64, 80, 128, 144, 192, 208};       // (y%8/2)*64 + (y%2)*16
    uint32_t bh = 1u << th, bd = 1u << td;
    uint64_t block = 512ull * bh * bd, gobs_x = (uint64_t)(lb + 63) >> 6, blocks_y = ((uint64_t)rows + 8 * bh - 1) >> (3 + th);
    for (uint32_t z = 0; z < slices; z++) {
        uint64_t zb = (uint64_t)(z >> td) * gobs_x * blocks_y * block + (uint64_t)(z & (bd - 1)) * bh * 512;
        for (uint32_t y = 0; y < rows; y++) {
            uint64_t p = (uint64_t)(y >> (3 + th)) * gobs_x * block + (uint64_t)((y & (8 * bh - 1)) >> 3) * 512;
            uint8_t *row = lin + ((size_t)z * rows + y) * pitch;
            uint64_t yb = zb + p;   // the row's segments: block column (j >> 2) at yb + j>>2 times block + ko[j & 3]
            uint16_t ko[4];
            for (unsigned k = 0; k < 4; k++) ko[k] = (uint16_t)native_gob_off(kox[k] + koy[y & 7], nvn_tex_native_tiling());
            uint32_t nfull = row_bytes >> 4, tail = row_bytes & 15;
            // The full 16-byte segments take a constant-size copy (a memcpy of a runtime length is a call per segment);
            // a row whose byte count is not divisible by 16 has a tail (e.g. R8 or RGB formats at an odd width).
            if (to_linear) {
                for (uint32_t j = 0; j < nfull; j++) memcpy(row + (j << 4), bl + yb + ((uint64_t)(j >> 2) * block) + ko[j & 3], 16);
                if (tail) memcpy(row + (nfull << 4), bl + yb + ((uint64_t)(nfull >> 2) * block) + ko[nfull & 3], tail);
            } else {
                for (uint32_t j = 0; j < nfull; j++) memcpy(bl + yb + ((uint64_t)(j >> 2) * block) + ko[j & 3], row + (j << 4), 16);
                if (tail) memcpy(bl + yb + ((uint64_t)(nfull >> 2) * block) + ko[nfull & 3], row + (nfull << 4), tail);
            }
        }
    }
    return 0;
}

int nvn_deswizzle(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, void *dst, size_t dst_pitch) {
    return move(d, level, layer, (uint8_t *)src, (uint8_t *)dst, dst_pitch, 1, 0);
}
int nvn_deswizzle_level(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, void *dst, size_t dst_pitch) {
    return move(d, level, layer, (uint8_t *)src, (uint8_t *)dst, dst_pitch, 1, 1);
}

int nvn_deswizzle_sparse_tile(const nvn_texdesc *d, unsigned level,
                              uint32_t tile_x, uint32_t tile_y, uint32_t tile_z,
                              const void *src_tile, void *dst_linear, size_t dst_pitch) {
    uint32_t tw, th, td;
    int tiled_levels = nvn_tex_sparse_tiles(d, &tw, &th, &td);
    int bw, bh; uint32_t bpb = (uint32_t)nvn_fmt_bpb(d->format, &bw, &bh);
    if (!bpb || level >= (unsigned)tiled_levels || !tw || !th || !td) return -1;

    uint32_t w = mip(d->width, level), h = (d->target == 0 || d->target == 3) ? 1 : mip(d->height, level);
    uint32_t z = d->target == 2 ? mip(d->depth ? d->depth : 1, level) : 1;
    uint64_t ox = (uint64_t)tile_x * tw, oy = (uint64_t)tile_y * th, oz = (uint64_t)tile_z * td;
    if (ox >= w || oy >= h || oz >= z) return -1;
    uint32_t valid_w = (uint32_t)((uint64_t)w - ox < tw ? (uint64_t)w - ox : tw);
    uint32_t valid_h = (uint32_t)((uint64_t)h - oy < th ? (uint64_t)h - oy : th);
    uint32_t valid_z = (uint32_t)((uint64_t)z - oz < td ? (uint64_t)z - oz : td);
    uint32_t tile_blocks_w = (tw + (uint32_t)bw - 1) / (uint32_t)bw;
    uint32_t tile_rows = (th + (uint32_t)bh - 1) / (uint32_t)bh;
    uint32_t copy_bytes = ((valid_w + (uint32_t)bw - 1) / (uint32_t)bw) * bpb;
    uint32_t copy_rows = (valid_h + (uint32_t)bh - 1) / (uint32_t)bh;
    uint32_t tile_row_bytes = tile_blocks_w * bpb;
    if (dst_pitch < copy_bytes) return -1;

    unsigned tileH, tileD; nvn_tex_level_tiles(d, level, &tileH, &tileD);
    const uint8_t *src = src_tile; uint8_t *dst = dst_linear;
    for (uint32_t iz = 0; iz < valid_z; iz++) for (uint32_t iy = 0; iy < copy_rows; iy++) {
        uint8_t *row = dst + ((size_t)iz * tile_rows + iy) * dst_pitch;
        for (uint32_t x = 0; x < copy_bytes; x += 16) {
            uint32_t n = copy_bytes - x < 16 ? copy_bytes - x : 16;
            uint64_t at = nvn_bl_offset_native(x, iy, iz, tile_row_bytes, tile_rows, tileH, tileD, nvn_tex_native_tiling());
            memcpy(row + x, src + at, n);
        }
    }
    return 0;
}
int nvn_swizzle(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, size_t src_pitch, void *dst) {
    return move(d, level, layer, (uint8_t *)dst, (uint8_t *)src, src_pitch, 0, 0);
}
