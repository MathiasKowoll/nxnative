# Zstandard with ZBIC support

`source/core/zstd.c`, `include/core/zstd.h`, and `include/core/zstd_errors.h`
are the single-file Zstandard 1.5.7 build with ZBIC support used by
nxdumptool (DarkMatterCore, commit `1cafac8`). ZBIC replaces the normal frame
magic with `ZBIC` and changes FSE normalization-header decoding; firmware 22 and
later can use it for NSO segments. The upstream source keeps Zstandard's
dual BSD-3-Clause / GPL-2-or-later license.

`zbic_decode.c` is a tiny nxnative wrapper that exposes one C function for
Python through `dm/tools/zbic.py`. Build products are written only to the cache
directory selected by the NSP build script, never to this source tree.
