#include "RenderConfiguration.h"
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <string.h>

enum { Capacity = 128, Inputs = 8, GainParameter = 7 };
typedef struct {
    _Atomic uintptr_t unit;
    _Atomic bool closing, gainOverride, started, mute;
    _Atomic unsigned readers;
    _Atomic uint32_t gainBits, nativeGainBits;
    _Atomic bool hasNativeGain;
    _Atomic uint64_t generation;
    AudioComponentDescription component;
    AudioUnit input[Inputs];
    AudioStreamBasicDescription format;
    bool initialized, notified;
    OSStatus notifyError;
    _Atomic bool headphones;
} Node;

static Node nodes[Capacity];
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static SpatialRenderConfiguration configuration = {.hrtfMode = SpatialHRTFSystem};
static SpatialRenderStatus status = {.requestedHRTF = SpatialHRTFSystem, .actualHRTF = -1};
static _Atomic uint64_t activeGeneration;
static _Atomic int activeHRTF = SpatialHRTFSystem;
static _Atomic bool activeAllowed;
static _Atomic bool personalizedRequested;
static Node *appliedPre, *appliedPost, *appliedSpatial;
static int32_t hrtfWriteError;
#ifdef SPATIAL_RENDER_TESTING
static unsigned failSkip, failCount;
void SpatialRenderTestFailGainWrites(unsigned skip, unsigned count) { failSkip = skip; failCount = count; }
#endif

static uint32_t bits(float value) { uint32_t b; memcpy(&b, &value, sizeof(b)); return b; }
static float number(uint32_t value) { float f; memcpy(&f, &value, sizeof(f)); return f; }
static Node *find(AudioUnit unit) {
    if (!unit) return NULL;
    for (unsigned i = 0; i < Capacity; i++)
        if (atomic_load_explicit(&nodes[i].unit, memory_order_acquire) == (uintptr_t)unit) return &nodes[i];
    return NULL;
}
#ifdef SPATIAL_RENDER_TESTING
bool SpatialRenderTestSetComponentSubtype(AudioUnit unit, UInt32 value) {
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (n) n->component.componentSubType = value;
    pthread_mutex_unlock(&control); return n != NULL;
}
#endif
static Node *borrow(AudioUnit unit) {
    Node *n = find(unit);
    if (!n || atomic_load(&n->closing)) return NULL;
    atomic_fetch_add(&n->readers, 1);
    if (atomic_load(&n->unit) == (uintptr_t)unit && !atomic_load(&n->closing)) return n;
    atomic_fetch_sub(&n->readers, 1); return NULL;
}
static void release(Node *n) { atomic_fetch_sub(&n->readers, 1); }
static bool current(Node *n) {
    return n && atomic_load(&n->unit) > 1 && !atomic_load(&n->closing) &&
        n->generation == configuration.generation;
}
static bool subtype(Node *n, UInt32 value) {
    UInt32 type = value == kAudioUnitSubType_SpatialMixer ? kAudioUnitType_Mixer : kAudioUnitType_Effect;
    return current(n) && n->component.componentSubType == value && n->component.componentType == type;
}
static Node *source(Node *n) {
    if (!current(n)) return NULL;
    // The supported effects are single-input nodes. Reject ambiguous fan-in.
    if (!n->input[0]) return NULL;
    for (unsigned i = 1; i < Inputs; i++) if (n->input[i]) return NULL;
    Node *result = find(n->input[0]);
    return current(result) ? result : NULL;
}
static OSStatus gain(Node *n, float *value) {
    return AudioUnitGetParameter((AudioUnit)atomic_load(&n->unit), GainParameter, kAudioUnitScope_Global, 0, value);
}
static OSStatus setGain(Node *n, float value) {
#ifdef SPATIAL_RENDER_TESTING
    if (failSkip) failSkip--;
    else if (failCount) { failCount--; return kAudioUnitErr_CannotDoInCurrentContext; }
#endif
    return AudioUnitSetParameter((AudioUnit)atomic_load(&n->unit), GainParameter, kAudioUnitScope_Global, 0, value, 0);
}
#ifdef SPATIAL_RENDER_TESTING
OSStatus SpatialRenderTestChangeGain(AudioUnit unit, float value) {
    return AudioUnitSetParameter(unit, GainParameter, kAudioUnitScope_Global, 0, value, 0);
}
#endif
static OSStatus checkedGain(Node *n, float value) {
    OSStatus error = setGain(n, value); float actual = NAN;
    if (!error) error = gain(n, &actual);
    if (!error && (!isfinite(actual) || fabsf(actual - value) > .0001f)) error = kAudioUnitErr_InvalidParameter;
    return error;
}
static OSStatus noteStart(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)time; (void)bus; (void)frames; (void)data;
    if (flags && (*flags & kAudioUnitRenderAction_PreRender)) atomic_store(&((Node *)context)->started, true);
    if (flags && (*flags & kAudioUnitRenderAction_PostRender) && atomic_load(&((Node *)context)->mute) && data) {
        for (UInt32 i = 0; i < data->mNumberBuffers; i++) if (data->mBuffers[i].mData)
            memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}
static void describeFormat(Node *n) {
    UInt32 size = sizeof(n->format); memset(&n->format, 0, size);
    AudioUnitGetProperty((AudioUnit)atomic_load(&n->unit), kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, 0, &n->format, &size);
}
static bool stereo(Node *n, double sampleRate) {
    return n->format.mChannelsPerFrame == 2 && n->format.mFormatID == kAudioFormatLinearPCM &&
        (n->format.mFormatFlags & kAudioFormatFlagIsFloat) && n->format.mBitsPerChannel == 32 &&
        sampleRate > 0 && n->format.mSampleRate == sampleRate;
}
static void silencePair(Node *a, Node *b, Node *mixer) {
    if (a) atomic_store(&a->mute, true);
    if (b) atomic_store(&b->mute, true);
    if (mixer) atomic_store(&mixer->mute, true);
}
static void restorePair(bool requireFreshChain) {
    Node *a = appliedPre, *b = appliedPost, *mixer = appliedSpatial;
    appliedPre = appliedPost = appliedSpatial = NULL;
    if (requireFreshChain) { silencePair(a, b, mixer); status.needsRebuild = 1; }
    if (a) atomic_store(&a->gainOverride, false);
    if (b) atomic_store(&b->gainOverride, false);
    OSStatus errorA = 0, errorB = 0;
    if (current(a) && atomic_load(&a->hasNativeGain)) errorA = checkedGain(a, number(atomic_load(&a->nativeGainBits)));
    if (current(b) && atomic_load(&b->hasNativeGain)) errorB = checkedGain(b, number(atomic_load(&b->nativeGainBits)));
    if (errorA || errorB) {
        status.rollbackFailed = 1; status.headroomError = errorA ? errorA : errorB;
        status.headroomState = SpatialRenderFailed; silencePair(a, b, mixer);
    }
}
static void describeMixer(Node *n) {
    UInt32 output = 0, size = sizeof(output);
    AudioStreamBasicDescription format = {0}; UInt32 formatSize = sizeof(format);
    AudioUnit unit = (AudioUnit)atomic_load(&n->unit);
    n->headphones = !AudioUnitGetProperty(unit, kAudioUnitProperty_SpatialMixerOutputType,
        kAudioUnitScope_Global, 0, &output, &size) && output == kSpatialMixerOutputType_Headphones &&
        !AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &formatSize) &&
        format.mChannelsPerFrame == 2;
}
static void updateLocked(bool mayApply) {
    status.mixers = status.headphoneMixers = status.pairCount = 0;
    Node *pre = NULL, *post = NULL, *spatial = NULL;
    for (unsigned i = 0; i < Capacity; i++) {
        Node *n = &nodes[i];
        if (subtype(n, kAudioUnitSubType_SpatialMixer) && n->initialized) {
            status.mixers++; if (n->headphones) status.headphoneMixers++;
        }
        if (!subtype(n, 'vrq2') || !n->initialized) continue;
        Node *limiter = source(n), *normalizer = source(limiter), *first = source(normalizer), *mixer = source(first);
        if (!subtype(limiter, 'cfrk') || !subtype(normalizer, 'ldnm') || !subtype(first, 'vrq2') ||
            !subtype(mixer, kAudioUnitSubType_SpatialMixer) || !mixer->initialized || !mixer->headphones ||
            !first->initialized || !normalizer->initialized || !limiter->initialized) continue;
        double rate = mixer->format.mSampleRate;
        if (!stereo(first, rate) || !stereo(normalizer, rate) || !stereo(limiter, rate) || !stereo(n, rate) ||
            !first->notified || !n->notified || !mixer->notified) continue;
        status.pairCount++; pre = first; post = n; spatial = mixer;
    }
    if (!configuration.allowed) { status.headroomState = SpatialRenderInactive; return; }
    if (!configuration.customHeadroom) { status.headroomState = SpatialRenderSystem; return; }
    if (status.rollbackFailed || status.headroomState == SpatialRenderFailed) return;
    if (appliedPre && (status.pairCount != 1 || status.headphoneMixers != 1 || appliedPre != pre || appliedPost != post)) {
        bool started = atomic_load(&appliedPre->started) || atomic_load(&appliedPost->started);
        restorePair(started);
        if (status.rollbackFailed || status.needsRebuild) { status.headroomState = SpatialRenderFailed; return; }
    }
    if (status.pairCount != 1 || status.headphoneMixers != 1) {
        status.headroomState = status.pairCount > 1 || status.headphoneMixers > 1 ? SpatialRenderUnavailable : SpatialRenderWaiting;
        for (unsigned i = 0; i < Capacity; i++) if (current(&nodes[i]) && nodes[i].notifyError) {
            status.headroomState = SpatialRenderUnavailable; status.headroomError = nodes[i].notifyError; break;
        }
        return;
    }
    if (atomic_load(&pre->gainOverride) && atomic_load(&post->gainOverride)) {
        float a = NAN, b = NAN;
        OSStatus error = gain(pre, &a); if (!error) error = gain(post, &b);
        status.actualPreGainDB = a; status.actualPostGainDB = b;
        status.headroomError = error;
        bool verified = !error && isfinite(a) && isfinite(b) && fabsf(a + configuration.headroomDB) < .0001f &&
            fabsf(b - configuration.headroomDB) < .0001f;
        if (!verified) {
            restorePair(atomic_load(&pre->started) || atomic_load(&post->started));
            if (!status.headroomError) status.headroomError = error ? error : kAudioUnitErr_InvalidParameter;
        }
        status.headroomState = verified ? SpatialRenderApplied : SpatialRenderFailed;
        return;
    }
    if (!mayApply) return;
    if (atomic_load(&spatial->started) || atomic_load(&pre->started) || atomic_load(&post->started)) {
        status.headroomState = SpatialRenderUnavailable; return;
    }
    float originalPre = NAN, originalPost = NAN;
    OSStatus error = gain(pre, &originalPre); if (!error) error = gain(post, &originalPost);
    if (error || !isfinite(originalPre) || !isfinite(originalPost)) {
        status.headroomError = error ? error : kAudioUnitErr_InvalidParameter;
        status.headroomState = SpatialRenderFailed; return;
    }
    atomic_store(&pre->nativeGainBits, bits(originalPre)); atomic_store(&pre->hasNativeGain, true);
    atomic_store(&post->nativeGainBits, bits(originalPost)); atomic_store(&post->hasNativeGain, true);
    atomic_store(&pre->gainBits, bits(-configuration.headroomDB));
    atomic_store(&post->gainBits, bits(configuration.headroomDB));
    atomic_store(&pre->gainOverride, true); atomic_store(&post->gainOverride, true);
    error = checkedGain(pre, -configuration.headroomDB);
    if (!error) error = checkedGain(post, configuration.headroomDB);
    if (error) {
        atomic_store(&pre->gainOverride, false); atomic_store(&post->gainOverride, false);
        OSStatus restoreA = checkedGain(pre, originalPre), restoreB = checkedGain(post, originalPost);
        status.rollbackFailed = restoreA || restoreB;
        if (status.rollbackFailed) silencePair(pre, post, spatial);
        status.headroomError = error; status.headroomState = SpatialRenderFailed; return;
    }
    appliedPre = pre; appliedPost = post; appliedSpatial = spatial;
    status.actualPreGainDB = -configuration.headroomDB; status.actualPostGainDB = configuration.headroomDB;
    status.headroomError = 0; status.headroomState = SpatialRenderApplied;
}
void SpatialRenderConfigure(SpatialRenderConfiguration next) {
    if (next.hrtfMode < SpatialHRTFSystem || next.hrtfMode > SpatialHRTFPersonalized) next.hrtfMode = SpatialHRTFSystem;
    if (!isfinite(next.headroomDB) || next.headroomDB < 0 || next.headroomDB > 20) {
        next.customHeadroom = false; next.headroomDB = 20;
    }
    pthread_mutex_lock(&control);
    configuration = next;
    appliedPre = appliedPost = appliedSpatial = NULL; hrtfWriteError = 0;
    atomic_store(&activeAllowed, next.allowed != 0); atomic_store(&activeHRTF, next.hrtfMode);
    atomic_store(&personalizedRequested, next.allowed && next.deviceID && next.hrtfMode == SpatialHRTFPersonalized);
    atomic_store(&activeGeneration, next.generation);
    status = (SpatialRenderStatus){.generation = next.generation, .deviceID = next.deviceID,
        .allowed = next.allowed, .requestedHRTF = next.hrtfMode, .actualHRTF = -1,
        .customHeadroom = next.customHeadroom, .requestedHeadroomDB = next.headroomDB,
        .headroomState = next.allowed ? (next.customHeadroom ? SpatialRenderWaiting : SpatialRenderSystem) : SpatialRenderInactive};
    pthread_mutex_unlock(&control);
}
bool SpatialRenderRequestsPersonalizedHRTF(void) {
    return atomic_load(&personalizedRequested);
}
void SpatialRenderUnitCreated(AudioComponentInstance unit) {
    AudioComponentDescription description = {0}; AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component || AudioComponentGetDescription(component, &description) ||
        description.componentManufacturer != kAudioUnitManufacturer_Apple) return;
    pthread_mutex_lock(&control);
    if (find(unit)) { pthread_mutex_unlock(&control); return; }
    for (unsigned i = 0; i < Capacity; i++) {
        Node *n = &nodes[i]; if (atomic_load(&n->unit)) continue;
        n->generation = configuration.generation; n->component = description;
        memset(n->input, 0, sizeof(n->input)); n->initialized = n->headphones = n->notified = false;
        n->notifyError = noErr;
        atomic_store(&n->closing, false); atomic_store(&n->gainOverride, false); atomic_store(&n->started, false);
        atomic_store(&n->mute, false);
        // Keep the reader counter balanced across slot reuse: a borrower that
        // lost the disposal race may still be validating the old unit address.
        atomic_store(&n->hasNativeGain, false);
        atomic_store_explicit(&n->unit, (uintptr_t)unit, memory_order_release); break;
    }
    pthread_mutex_unlock(&control);
}
void SpatialRenderUnitInitialized(AudioUnit unit, OSStatus result) {
    if (result) return;
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (current(n)) {
        n->initialized = true;
        describeFormat(n);
        if (subtype(n, kAudioUnitSubType_SpatialMixer)) {
            describeMixer(n);
            if (n->headphones && configuration.allowed && configuration.hrtfMode != SpatialHRTFSystem) {
                UInt32 mode = (UInt32)configuration.hrtfMode;
                status.hrtfError = hrtfWriteError = AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                    kAudioUnitScope_Global, 0, &mode, sizeof(mode));
            }
        }
        if (!n->notified && (subtype(n, 'vrq2') || subtype(n, kAudioUnitSubType_SpatialMixer))) {
            n->notifyError = AudioUnitAddRenderNotify(unit, noteStart, n);
            n->notified = n->notifyError == noErr;
        }
        updateLocked(true);
    }
    pthread_mutex_unlock(&control);
}
void SpatialRenderUnitUninitialized(AudioUnit unit, OSStatus result) {
    if (result) return;
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (n) {
        if (n == appliedPre || n == appliedPost || n == appliedSpatial) restorePair(false);
        n->initialized = false; atomic_store(&n->started, false);
        if (n->notified) { AudioUnitRemoveRenderNotify(unit, noteStart, n); n->notified = false; }
        updateLocked(false);
    }
    pthread_mutex_unlock(&control);
}
void SpatialRenderObservedProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, const void *requested, UInt32 size, OSStatus result) {
    if (result) return;
    bool connectionProperty = property == kAudioUnitProperty_MakeConnection && scope == kAudioUnitScope_Input &&
        requested && size == sizeof(AudioUnitConnection) && element < Inputs;
    bool formatProperty = property == kAudioUnitProperty_StreamFormat || property == kAudioUnitProperty_SpatialMixerOutputType;
    if (!connectionProperty && !formatProperty) return;
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (current(n)) {
        if (connectionProperty) {
            AudioUnitConnection connection; memcpy(&connection, requested, sizeof(connection));
            n->input[element] = !connection.sourceAudioUnit ? NULL :
                (connection.sourceOutputNumber == 0 && connection.destInputNumber == element ? connection.sourceAudioUnit : (AudioUnit)(uintptr_t)1);
        }
        if (formatProperty && n->initialized) {
            describeFormat(n); if (subtype(n, kAudioUnitSubType_SpatialMixer)) describeMixer(n);
        }
        updateLocked(true);
    }
    pthread_mutex_unlock(&control);
}
bool SpatialRenderHRTFOverride(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 size, UInt32 *replacement) {
    if (property != kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode || scope != kAudioUnitScope_Global ||
        element || !data || size != sizeof(UInt32) || !atomic_load(&activeAllowed)) return false;
    int mode = atomic_load(&activeHRTF); if (mode == SpatialHRTFSystem) return false;
    Node *n = borrow(unit); if (!n) return false;
    bool match = n->generation == atomic_load(&activeGeneration) && n->headphones;
    release(n); if (match) *replacement = (UInt32)mode; return match;
}
AudioUnitParameterValue SpatialRenderParameterValue(AudioUnit unit, AudioUnitParameterID parameter,
    AudioUnitScope scope, AudioUnitElement element, AudioUnitParameterValue requested) {
    if (parameter != GainParameter || scope != kAudioUnitScope_Global || element) return requested;
    Node *n = borrow(unit); if (!n) return requested;
    float result = atomic_load(&n->gainOverride) ? number(atomic_load(&n->gainBits)) : requested;
    release(n); return result;
}
void SpatialRenderParameterResult(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue requested, OSStatus result) {
    if (result || parameter != GainParameter || scope != kAudioUnitScope_Global || element) return;
    Node *n = borrow(unit); if (!n) return;
    atomic_store(&n->nativeGainBits, bits(requested)); atomic_store(&n->hasNativeGain, true); release(n);
}
void SpatialRenderWillDispose(AudioUnit unit) {
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (n) {
        if (n == appliedPre || n == appliedPost || n == appliedSpatial) restorePair(false);
        atomic_store(&n->closing, true);
        if (n->notified) { AudioUnitRemoveRenderNotify(unit, noteStart, n); n->notified = false; }
    }
    pthread_mutex_unlock(&control);
    if (n) while (atomic_load(&n->readers)) sched_yield();
}
void SpatialRenderDidDispose(AudioUnit unit, OSStatus result) {
    pthread_mutex_lock(&control); Node *n = find(unit);
    if (n) {
        if (!result) {
            for (unsigned i = 0; i < Capacity; i++) for (unsigned b = 0; b < Inputs; b++)
                if (nodes[i].input[b] == unit) nodes[i].input[b] = NULL;
            atomic_store(&n->gainOverride, false); atomic_store(&n->unit, 0);
        } else {
            atomic_store(&n->closing, false);
            if (n->initialized && !n->notified && (subtype(n, 'vrq2') || subtype(n, kAudioUnitSubType_SpatialMixer)))
                n->notified = AudioUnitAddRenderNotify(unit, noteStart, n) == noErr;
        }
        updateLocked(false);
    }
    pthread_mutex_unlock(&control);
}
void SpatialRenderRefreshStatus(void) {
    pthread_mutex_lock(&control); updateLocked(false); status.actualHRTF = -1;
    if (configuration.allowed) for (unsigned i = 0; i < Capacity; i++) {
        Node *n = &nodes[i];
        if (!current(n) || !n->initialized || !n->headphones) continue;
        UInt32 active = 0, size = sizeof(active);
        OSStatus error = AudioUnitGetProperty((AudioUnit)atomic_load(&n->unit),
            kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &active, &size);
        status.hrtfError = hrtfWriteError ? hrtfWriteError : error;
        status.actualHRTF = error ? -1 : (active != 0); break;
    }
    if (status.headroomState == SpatialRenderWaiting && status.headphoneMixers) {
        bool started = false;
        for (unsigned i = 0; i < Capacity; i++) if (current(&nodes[i]) && nodes[i].headphones)
            started |= atomic_load(&nodes[i].started);
        if (started) status.headroomState = SpatialRenderUnavailable;
    }
    pthread_mutex_unlock(&control);
}
SpatialRenderStatus SpatialRenderGetStatus(void) {
    pthread_mutex_lock(&control); SpatialRenderStatus result = status; pthread_mutex_unlock(&control); return result;
}
#ifdef SPATIAL_DIAGNOSTICS
unsigned SpatialRenderCopyNodes(SpatialRenderNodeInfo *out, unsigned capacity) {
    pthread_mutex_lock(&control); unsigned count = 0;
    for (unsigned i = 0; i < Capacity && count < capacity; i++) {
        Node *n = &nodes[i]; if (!atomic_load(&n->unit)) continue;
        out[count++] = (SpatialRenderNodeInfo){atomic_load(&n->unit), (uintptr_t)n->input[0], n->generation,
            n->component.componentType, n->component.componentSubType, n->initialized, n->headphones, atomic_load(&n->started)};
    }
    pthread_mutex_unlock(&control); return count;
}
#endif
#ifndef SPATIAL_RENDER_EXTERNAL_INTERPOSE
static OSStatus configuredNew(AudioComponent component, AudioComponentInstance *out) {
    OSStatus result = AudioComponentInstanceNew(component, out);
    if (!result && out && *out) SpatialRenderUnitCreated(*out); return result;
}
static OSStatus configuredParameter(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue value, UInt32 offset) {
    float actual = SpatialRenderParameterValue(unit, parameter, scope, element, value);
    OSStatus result = AudioUnitSetParameter(unit, parameter, scope, element, actual, offset);
    SpatialRenderParameterResult(unit, parameter, scope, element, value, result); return result;
}
#define INTERPOSE(replacement, original) \
__attribute__((used)) static struct {const void *replacement; const void *original;} binding_##original \
__attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement, (const void *)&original};
INTERPOSE(configuredNew, AudioComponentInstanceNew)
INTERPOSE(configuredParameter, AudioUnitSetParameter)
#endif
