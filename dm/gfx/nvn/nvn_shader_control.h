#pragma once
#include <stdint.h>
#include <string.h>

// Bounded layouts shared by the runtime and the offline splitter. Classic NVN
// uses the large GLSLC control, current NVN2 uses version 0xc9 and compact
// SDK-19 controls identify themselves as 201.7/201.11.
static inline int nvn_shader_control_layout(const void *control, uint32_t *nctl, uint32_t *ncode) {
    if (!control) return 0;
    const uint8_t *p = control;
    uint32_t magic, version, minor = 0;
    memcpy(&magic, p, 4); memcpy(&version, p + 4, 4); memcpy(&minor, p + 8, 4);
    if (magic != 0x98761234u) return 0;
    if (version == 201) {
        if (minor != 7 && minor != 11) return 0;
        memcpy(nctl, p + 0x30, 4); memcpy(ncode, p + 0x44, 4);
        if (!*nctl) {
            uint32_t runtime_size; memcpy(&runtime_size, p + 0xc4, 4);
            if (runtime_size == 0xd8) *nctl = runtime_size;
        }
        return *nctl >= 0xd8 && *nctl <= 0x10000 && *ncode && *ncode < (1u << 24) && !(*ncode & 15);
    }
    if (version == 0xc9) {
        *nctl = 0x48; memcpy(ncode, p + 0x44, 4);
        return *ncode && *ncode < (1u << 24);
    }
    uint32_t own; memcpy(&own, p + 0x20, 4);
    *nctl = own >= 0x760 && own < 0x880 ? own : 0x880;
    memcpy(ncode, p + 0x704, 4);
    return 1;
}

// Compact controls carry the logical descriptor stage in the high half of
// +0x54: 0 vertex, 1 fragment, 2 geometry, 3 hull, 4 domain, 5 compute,
// 6 task/object and 7 mesh. Other control layouts return -1.
static inline int nvn_shader_control_stage(const void *control) {
    if (!control) return -1;
    const uint8_t *p = control;
    uint32_t magic, version, minor, word;
    memcpy(&magic, p, 4); memcpy(&version, p + 4, 4); memcpy(&minor, p + 8, 4);
    if (magic != 0x98761234u || version != 201 || (minor != 7 && minor != 11)) return -1;
    memcpy(&word, p + 0x54, 4);
    int stage = (int)(word >> 16);
    return stage <= 7 ? stage : -1;
}
