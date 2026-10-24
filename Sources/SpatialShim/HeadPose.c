#include "HeadPose.h"
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <string.h>

// Verified on macOS 27: AQME HeadTrackerSession writes a 16-byte quaternion here.
// It is private. Keep failure observable and never turn a property error into an
// audio render error. The registry includes only Apple's AUSpatialMixer units.
enum { HeadQuaternion = 3102, MaxMixers = 64 };
typedef struct {
    _Atomic uint64_t version;
    _Atomic uint32_t bits[4];
} QuaternionMailbox;
typedef struct {
    _Atomic uintptr_t unit; // 0 = free; 1 = reserved by initialization.
    _Atomic bool closing;
    _Atomic unsigned users;
    _Atomic bool notified;
    _Atomic bool overridden;
    _Atomic uint64_t appliedVersion;
    QuaternionMailbox nativePose;
} Mixer;

static Mixer mixers[MaxMixers];
static QuaternionMailbox target = {.bits = {0, 0, 0, 0x3f800000}};
static _Atomic bool enabled;
static _Atomic uint32_t mixerCount;
static _Atomic int32_t lastError;
static _Atomic uint64_t published, applied, restored, renderCallbacks, failures;

// All payload words are atomic: unlike a seqlock over plain floats, this is also
// valid under the C memory model. Readers are bounded and never spin for a writer.
static bool readQuaternion(QuaternionMailbox *box, float q[4], uint64_t *version) {
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        uint64_t before = atomic_load_explicit(&box->version, memory_order_seq_cst);
        if (before & 1) continue;
        uint32_t words[4];
        for (unsigned i = 0; i < 4; i++)
            words[i] = atomic_load_explicit(&box->bits[i], memory_order_seq_cst);
        if (before == atomic_load_explicit(&box->version, memory_order_seq_cst)) {
            memcpy(q, words, sizeof(words)); *version = before; return true;
        }
    }
    return false;
}
static bool writeQuaternion(QuaternionMailbox *box, const float q[4]) {
    uint64_t version = atomic_load_explicit(&box->version, memory_order_seq_cst);
    if ((version & 1) || !atomic_compare_exchange_strong_explicit(
            &box->version, &version, version + 1, memory_order_seq_cst, memory_order_seq_cst)) return false;
    uint32_t words[4]; memcpy(words, q, sizeof(words));
    for (unsigned i = 0; i < 4; i++)
        atomic_store_explicit(&box->bits[i], words[i], memory_order_seq_cst);
    atomic_store_explicit(&box->version, version + 2, memory_order_seq_cst);
    return true;
}
bool SpatialHeadPosePublish(float x, float y, float z, float w) {
    float q[4] = {x, y, z, w};
    double norm2 = 0;
    for (unsigned i = 0; i < 4; i++) {
        if (!isfinite(q[i])) return false;
        norm2 += (double)q[i] * q[i];
    }
    if (norm2 < 1e-12 || !isfinite(norm2)) return false;
    double inverse = 1 / sqrt(norm2);
    for (unsigned i = 0; i < 4; i++) q[i] *= inverse;
    if (!writeQuaternion(&target, q)) return false;
    atomic_fetch_add_explicit(&published, 1, memory_order_relaxed);
    return true;
}
void SpatialHeadPoseSetEnabled(bool value) {
    atomic_store_explicit(&enabled, value, memory_order_release);
}
SpatialHeadPoseStatus SpatialHeadPoseGetStatus(void) {
    return (SpatialHeadPoseStatus){
        atomic_load(&enabled), atomic_load(&mixerCount), atomic_load(&lastError),
        atomic_load(&published), atomic_load(&applied), atomic_load(&restored),
        atomic_load(&renderCallbacks), atomic_load(&failures)
    };
}
static void recordResult(OSStatus result) {
    atomic_store_explicit(&lastError, result, memory_order_relaxed);
    if (result) atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
}
static Mixer *acquireMixer(AudioUnit unit) {
    for (unsigned i = 0; i < MaxMixers; i++) {
        Mixer *m = &mixers[i];
        if (atomic_load_explicit(&m->unit, memory_order_acquire) != (uintptr_t)unit) continue;
        atomic_fetch_add_explicit(&m->users, 1, memory_order_acquire);
        if (atomic_load_explicit(&m->unit, memory_order_acquire) == (uintptr_t)unit &&
            !atomic_load_explicit(&m->closing, memory_order_acquire)) return m;
        atomic_fetch_sub_explicit(&m->users, 1, memory_order_release);
    }
    return NULL;
}
static void releaseMixer(Mixer *m) {
    atomic_fetch_sub_explicit(&m->users, 1, memory_order_release);
}
static OSStatus apply(AudioUnit unit, Mixer *m, const float q[4], uint64_t version) {
    // Calls originating in the interposing image bind to the original function.
    OSStatus result = AudioUnitSetProperty(unit, HeadQuaternion, kAudioUnitScope_Global, 0, q, 16);
    recordResult(result);
    if (!result) {
        atomic_store_explicit(&m->appliedVersion, version, memory_order_relaxed);
        atomic_store_explicit(&m->overridden, true, memory_order_release);
        atomic_fetch_add_explicit(&applied, 1, memory_order_relaxed);
    }
    return result;
}
static OSStatus beforeRender(void *context, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)time; (void)bus; (void)frames; (void)data;
    if (!flags || !(*flags & kAudioUnitRenderAction_PreRender)) return noErr;
    Mixer *m = context;
    AudioUnit unit = (AudioUnit)atomic_load_explicit(&m->unit, memory_order_acquire);
    if ((uintptr_t)unit <= 1 || atomic_load_explicit(&m->closing, memory_order_acquire)) return noErr;
    atomic_fetch_add_explicit(&m->users, 1, memory_order_acquire);
    if (atomic_load_explicit(&m->closing, memory_order_acquire)) { releaseMixer(m); return noErr; }
    atomic_fetch_add_explicit(&renderCallbacks, 1, memory_order_relaxed);
    float q[4]; uint64_t version;
    if (atomic_load_explicit(&enabled, memory_order_acquire)) {
        if (readQuaternion(&target, q, &version) &&
            (!atomic_load_explicit(&m->overridden, memory_order_acquire) ||
             version != atomic_load_explicit(&m->appliedVersion, memory_order_relaxed)))
            apply(unit, m, q, version);
    } else if (atomic_load_explicit(&m->overridden, memory_order_acquire) &&
               readQuaternion(&m->nativePose, q, &version)) {
        OSStatus result = AudioUnitSetProperty(unit, HeadQuaternion, kAudioUnitScope_Global, 0, q, 16);
        recordResult(result);
        if (!result) {
            atomic_store_explicit(&m->overridden, false, memory_order_release);
            atomic_fetch_add_explicit(&restored, 1, memory_order_relaxed);
        }
    }
    releaseMixer(m);
    return noErr;
}
static OSStatus poseProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                             AudioUnitElement element, const void *data, UInt32 size) {
    if (property != HeadQuaternion || scope != kAudioUnitScope_Global || element != 0 || size != 16 || !data)
        return AudioUnitSetProperty(unit, property, scope, element, data, size);
    Mixer *m = acquireMixer(unit);
    if (!m) return AudioUnitSetProperty(unit, property, scope, element, data, size);
    // Preserve Apple's most recent orientation even while replacing it, so
    // switching back to system tracking does not restore a stale identity pose.
    writeQuaternion(&m->nativePose, data);
    float q[4]; uint64_t version;
    OSStatus result;
    if (atomic_load_explicit(&enabled, memory_order_acquire)) {
        if (readQuaternion(&target, q, &version)) {
            result = apply(unit, m, q, version);
        } else if (atomic_load_explicit(&m->overridden, memory_order_acquire)) {
            // A writer briefly owning the mailbox must not let a native update
            // punch through external tracking. Keep the last applied pose.
            result = noErr;
        } else {
            result = AudioUnitSetProperty(unit, property, scope, element, data, size);
        }
    } else {
        result = AudioUnitSetProperty(unit, property, scope, element, data, size);
        if (!result) atomic_store_explicit(&m->overridden, false, memory_order_release);
    }
    releaseMixer(m);
    return result;
}
static OSStatus poseInitialize(AudioUnit unit) {
    OSStatus result = AudioUnitInitialize(unit);
    if (result) return result;
    Mixer *existing = acquireMixer(unit);
    if (existing) { releaseMixer(existing); return result; }
    AudioComponentDescription description = {0};
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component || AudioComponentGetDescription(component, &description) ||
        description.componentType != kAudioUnitType_Mixer ||
        description.componentSubType != kAudioUnitSubType_SpatialMixer ||
        description.componentManufacturer != kAudioUnitManufacturer_Apple) return result;
    for (unsigned i = 0; i < MaxMixers; i++) {
        Mixer *m = &mixers[i]; uintptr_t vacant = 0;
        if (!atomic_compare_exchange_strong_explicit(&m->unit, &vacant, 1, memory_order_acq_rel, memory_order_acquire)) continue;
        atomic_store(&m->closing, false);
        atomic_store(&m->overridden, false);
        atomic_store(&m->notified, false);
        atomic_store(&m->appliedVersion, UINT64_MAX);
        float original[4] = {0, 0, 0, 1}; UInt32 size = sizeof(original);
        if (AudioUnitGetProperty(unit, HeadQuaternion, kAudioUnitScope_Global, 0, original, &size) || size != 16) {
            original[0] = original[1] = original[2] = 0; original[3] = 1;
        }
        writeQuaternion(&m->nativePose, original);
        atomic_store_explicit(&m->unit, (uintptr_t)unit, memory_order_release);
        OSStatus notify = AudioUnitAddRenderNotify(unit, beforeRender, m);
        atomic_store_explicit(&m->notified, notify == noErr, memory_order_release);
        atomic_fetch_add_explicit(&mixerCount, 1, memory_order_relaxed);
        recordResult(notify);
        return result;
    }
    recordResult(kAudio_MemFullError);
    return result;
}
static OSStatus poseDispose(AudioComponentInstance instance) {
    Mixer *m = NULL;
    for (unsigned i = 0; i < MaxMixers; i++) {
        if (atomic_load_explicit(&mixers[i].unit, memory_order_acquire) == (uintptr_t)instance) {
            m = &mixers[i]; break;
        }
    }
    if (!m) return AudioComponentInstanceDispose(instance);
    atomic_store_explicit(&m->closing, true, memory_order_release);
    if (atomic_load_explicit(&m->notified, memory_order_acquire))
        AudioUnitRemoveRenderNotify(instance, beforeRender, m);
    // Only lifecycle teardown waits; render and property callbacks never wait.
    while (atomic_load_explicit(&m->users, memory_order_acquire)) sched_yield();
    OSStatus result = AudioComponentInstanceDispose(instance);
    if (!result) {
        atomic_fetch_sub_explicit(&mixerCount, 1, memory_order_relaxed);
        atomic_store_explicit(&m->unit, 0, memory_order_release);
    } else {
        OSStatus notify = AudioUnitAddRenderNotify(instance, beforeRender, m);
        atomic_store(&m->notified, notify == noErr);
        atomic_store_explicit(&m->closing, false, memory_order_release);
        recordResult(result);
    }
    return result;
}
#define INTERPOSE(replacement, original) \
__attribute__((used)) static struct {const void *newFunction; const void *oldFunction;} binding_##replacement \
__attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement, (const void *)&original};
INTERPOSE(poseProperty, AudioUnitSetProperty)
INTERPOSE(poseInitialize, AudioUnitInitialize)
INTERPOSE(poseDispose, AudioComponentInstanceDispose)
