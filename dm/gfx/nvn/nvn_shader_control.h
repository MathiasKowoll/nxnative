#pragma once
#include <stdint.h>
#include <string.h>

// The caller owns a valid shader control section. NVN2 201.7/201.11's header is
// compact: length at +0x30, padded code span at +0x40. Runtime-built 201.11
// controls may clear +0x30 while retaining the same 216-byte size at +0xc4.
// Never read legacy +0x704 from either form. These fields were checked against
// BNSH descriptor spans and bounded runtime captures.
static inline int nvn_shader_control_layout(const void *control, uint32_t *nctl, uint32_t *ncode) {
    if (!control) return 0;
    const uint8_t *p = control;
    uint32_t version, minor;
    memcpy(&version, p + 4, 4); memcpy(&minor, p + 8, 4);
    if (version == 201) {
        if (minor != 7 && minor != 11) return 0;
        uint32_t magic; memcpy(&magic, p, 4);
        memcpy(nctl, p + 0x30, 4); memcpy(ncode, p + 0x40, 4);
        if (!*nctl) {
            uint32_t runtime_size; memcpy(&runtime_size, p + 0xc4, 4);
            if (runtime_size == 0xd8) *nctl = runtime_size;
        }
        return magic == 0x98761234 && *nctl >= 0xd8 && *nctl <= 0x10000 &&
               *ncode && *ncode < (1u << 24) && !(*ncode & 15);
    }
    uint32_t own; memcpy(&own, p + 0x20, 4);
    *nctl = own >= 0x760 && own < 0x880 ? own : 0x880;
    memcpy(ncode, p + 0x704, 4);
    return 1;
}

// Compact NVN2 controls carry their logical stage in the high half of the
// word at +0x54. This is independent of descriptor order: mesh programs seen
// in SDK 19 contain fragment, task/object and mesh controls (1, 6 and 7).
// Return -1 for legacy controls or an unrecognized compact stage.
static inline int nvn_shader_control_stage(const void *control) {
    if (!control) return -1;
    const uint8_t *p = control;
    uint32_t magic, version, minor, word;
    memcpy(&magic, p, 4); memcpy(&version, p + 4, 4); memcpy(&minor, p + 8, 4);
    if (magic != 0x98761234 || version != 201 || (minor != 7 && minor != 11)) return -1;
    memcpy(&word, p + 0x54, 4);
    int stage = (int)(word >> 16);
    return stage <= 7 ? stage : -1;
}
