#include "SpatialShim.h"
#include <stdatomic.h>
#include <string.h>
#ifdef SPATIAL_DIAGNOSTICS
#include <AudioToolbox/AudioToolbox.h>
#endif

// One atomic snapshot prevents a device change from combining an old ID with a
// new enabled flag. No allocation, logging, locks or DSP in these callbacks.
static _Atomic uint64_t configuration;
static _Atomic uint64_t queryCount;
static _Atomic uint32_t lastSpatial = UINT32_MAX;
static _Atomic uint32_t lastLayout;
static _Atomic uint64_t spatialRequests;

void SpatialShimSetConfiguration(uint32_t deviceID, bool enabled) {
    uint64_t next = deviceID | ((uint64_t)(enabled && deviceID != 0) << 32);
    uint64_t previous = atomic_exchange_explicit(&configuration, next, memory_order_acq_rel);
    if (next != previous) {
        atomic_store(&queryCount, 0);
        atomic_store(&lastSpatial, UINT32_MAX);
        atomic_store(&lastLayout, 0);
        atomic_store(&spatialRequests, 0);
    }
}
static AudioObjectPropertyAddress address(uint32_t selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
// dyld leaves calls originating in the interposing image bound to the original
// implementations. Device discovery must use these functions, not its own spoof.
bool SpatialShimNativeHasProperty(uint32_t deviceID, uint32_t selector) {
    AudioObjectPropertyAddress a = address(selector);
    return AudioObjectHasProperty(deviceID, &a);
}
int32_t SpatialShimNativeReadUInt32(uint32_t deviceID, uint32_t selector, uint32_t *value) {
    if (!value) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertyAddress a = address(selector);
    UInt32 size = sizeof(*value);
    OSStatus result = AudioObjectGetPropertyData(deviceID, &a, 0, NULL, &size, value);
    return !result && size != sizeof(*value) ? kAudioHardwareBadPropertySizeError : result;
}
SpatialShimStatus SpatialShimGetStatus(void) {
    uint64_t c = atomic_load_explicit(&configuration, memory_order_acquire);
    return (SpatialShimStatus){(uint32_t)c, (uint32_t)(c >> 32), atomic_load(&queryCount), atomic_load(&lastSpatial), atomic_load(&lastLayout), atomic_load(&spatialRequests)};
}
static bool overrides(AudioObjectID device, const AudioObjectPropertyAddress *a) {
    uint64_t c = atomic_load_explicit(&configuration, memory_order_acquire);
    bool match = a && (c >> 32) && device == (uint32_t)c && (a->mSelector == 'spen' || a->mSelector == 'spmd');
    if (match) atomic_fetch_add_explicit(&queryCount, 1, memory_order_relaxed);
    return match;
}
static Boolean shimHas(AudioObjectID device, const AudioObjectPropertyAddress *a) {
    return overrides(device, a) ? true : AudioObjectHasProperty(device, a);
}
static OSStatus shimSize(AudioObjectID device, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *size) {
    if (overrides(device, a)) {
        if (!size) return kAudioHardwareIllegalOperationError;
        *size = sizeof(UInt32); return noErr;
    }
    return AudioObjectGetPropertyDataSize(device, a, qSize, q, size);
}
static OSStatus shimGet(AudioObjectID device, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *size, void *data) {
    if (overrides(device, a)) {
        if (!size || !data) return kAudioHardwareIllegalOperationError;
        if (*size < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 value = 1; memcpy(data, &value, sizeof(value)); *size = sizeof(value); return noErr;
    }
    return AudioObjectGetPropertyData(device, a, qSize, q, size, data);
}
#define INTERPOSE(replacement, original) \
__attribute__((used)) static struct {const void *newFunction; const void *oldFunction;} binding_##original \
__attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement, (const void *)&original};
INTERPOSE(shimHas, AudioObjectHasProperty)
INTERPOSE(shimSize, AudioObjectGetPropertyDataSize)
INTERPOSE(shimGet, AudioObjectGetPropertyData)

#ifdef SPATIAL_DIAGNOSTICS
// Read-only instrumentation in the diagnostic build. It never changes a queue
// property or audio samples; the release build contains only the three hooks above.
static OSStatus diagnosticQueueSet(AudioQueueRef queue, AudioQueuePropertyID property, const void *data, UInt32 size) {
    OSStatus result = AudioQueueSetProperty(queue, property, data, size);
    if (!result && data) {
        UInt32 value;
        if (property == 'q_sp' && size == sizeof(value)) {
            memcpy(&value, data, sizeof(value)); atomic_store(&lastSpatial, value); atomic_fetch_add(&spatialRequests, 1);
        } else if (property == 'aqcl' && size >= 12) {
            memcpy(&value, data, sizeof(value)); atomic_store(&lastLayout, value);
        }
    }
    return result;
}
INTERPOSE(diagnosticQueueSet, AudioQueueSetProperty)
#endif
