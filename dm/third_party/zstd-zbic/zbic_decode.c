#include <stddef.h>
#include <stdint.h>
#include "core/zstd.h"

/* Return zero on a decode error; callers know the expected segment size. */
size_t nxnative_zbic_decompress(uint8_t *dst, size_t dst_size,
                                const uint8_t *src, size_t src_size) {
    size_t out = ZSTD_decompress(dst, dst_size, src, src_size);
    return ZSTD_isError(out) ? 0 : out;
}
