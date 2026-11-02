// Parse only bounded SDK version strings; Generic_ is a build-target prefix.
#ifndef DM_SDK_VERSION_H
#define DM_SDK_VERSION_H
#include <stddef.h>
#include <string.h>
static inline int dm_sdk_version_major(const char *value, size_t length) {
    if (length >= 8 && !memcmp(value, "Generic_", 8)) { value += 8; length -= 8; }
    int major = 0;
    size_t digits = 0;
    while (digits < length && value[digits] >= '0' && value[digits] <= '9') {
        if (digits == 3) return 0;
        major = major * 10 + value[digits++] - '0';
    }
    return digits && digits < length && value[digits] == '_' ? major : 0;
}
#endif
