#include "../Sources/SpatialShim/RenderConfiguration.h"
#include "../Sources/SpatialShim/SpatialShim.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>

typedef struct { AudioUnit units[5]; } Chain;
static float input[512], left[512], right[512];
static OSStatus inputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)context; (void)flags; (void)bus;
    assert(frames <= 512);
    for (unsigned i = 0; i < frames; i++) input[i] = .4f * sinf((float)(time->mSampleTime + i) * .12f);
    data->mBuffers[0].mData = input; data->mBuffers[0].mDataByteSize = frames * 4; return noErr;
}
static AudioUnit create(UInt32 type, UInt32 subtype) {
    // Public Apple EQs provide real lifecycle, connections and read/write gain
    // parameters for control/fault tests. Private DSP is verified separately
    // with real AVPlayer captures, where those components are instantiated.
    UInt32 actualSubtype = type == kAudioUnitType_Effect ? 'greq' : subtype;
    AudioComponentDescription d = {type, actualSubtype, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &d); assert(component);
    AudioUnit unit = NULL; assert(!AudioComponentInstanceNew(component, &unit));
    if (actualSubtype != subtype) assert(SpatialRenderTestSetComponentSubtype(unit, subtype));
    return unit;
}
static float gain(AudioUnit unit) {
    float result = NAN; assert(!AudioUnitGetParameter(unit, 7, kAudioUnitScope_Global, 0, &result)); return result;
}
static void configure(uint64_t generation, float db, bool custom) {
    SpatialRenderConfigure((SpatialRenderConfiguration){generation, 123, 1, SpatialHRTFGeneric, custom, db});
}
static Chain makeChain(bool connect) {
    Chain c = {0};
    // Creation order deliberately differs from signal order.
    c.units[4] = create(kAudioUnitType_Effect, 'vrq2');
    c.units[2] = create(kAudioUnitType_Effect, 'ldnm');
    c.units[0] = create(kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer);
    c.units[3] = create(kAudioUnitType_Effect, 'cfrk');
    c.units[1] = create(kAudioUnitType_Effect, 'vrq2');
    AudioStreamBasicDescription f = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    for (unsigned i = 0; i < 5; i++) {
        assert(!AudioUnitSetProperty(c.units[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof(f)));
        AudioStreamBasicDescription in = f; if (!i) in.mChannelsPerFrame = 1;
        assert(!AudioUnitSetProperty(c.units[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &in, sizeof(in)));
    }
    UInt32 output = kSpatialMixerOutputType_Headphones, algorithm = kSpatializationAlgorithm_UseOutputType;
    assert(!AudioUnitSetProperty(c.units[0], kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &output, 4));
    assert(!AudioUnitSetProperty(c.units[0], kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &algorithm, 4));
    assert(!AudioUnitSetParameter(c.units[0], kSpatialMixerParam_Distance, kAudioUnitScope_Input, 0, 1, 0));
    AURenderCallbackStruct callback = {inputRender, NULL};
    assert(!AudioUnitSetProperty(c.units[0], kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)));
    assert(!AudioUnitSetParameter(c.units[1], 7, kAudioUnitScope_Global, 0, -3, 0));
    assert(!AudioUnitSetParameter(c.units[4], 7, kAudioUnitScope_Global, 0, 3, 0));
    if (connect) for (unsigned i = 1; i < 5; i++) {
        AudioUnitConnection connection = {c.units[i - 1], 0, 0};
        assert(!AudioUnitSetProperty(c.units[i], kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &connection, sizeof(connection)));
    }
    for (int i = 4; i >= 0; i--) assert(!AudioUnitInitialize(c.units[i]));
    return c;
}
static void destroy(Chain c) {
    for (int i = 4; i >= 0; i--) assert(!AudioComponentInstanceDispose(c.units[i]));
}
static float render(Chain c, unsigned block) {
    struct { UInt32 count; AudioBuffer buffer[2]; } output = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    AudioTimeStamp t = {.mSampleTime = block * 512.0, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;
    assert(!AudioUnitRender(c.units[4], &flags, &t, 0, 512, (AudioBufferList *)&output));
    float peak = 0; for (unsigned i = 0; i < 512; i++) peak = fmaxf(peak, fmaxf(fabsf(left[i]), fabsf(right[i])));
    return peak;
}
static _Atomic bool writing;
static void *writer(void *context) {
    AudioUnit unit = context;
    while (atomic_load(&writing)) assert(!AudioUnitSetParameter(unit, 7, kAudioUnitScope_Global, 0, -4, 0));
    return NULL;
}
int main(void) {
    // Personalized IR availability is opt-in, independent of capability spoofing
    // for the selected output. Native discovery must still see the real device.
    AudioObjectID probeDevice = 123;
    AudioObjectPropertyAddress availability = {'hrfa', kAudioObjectPropertyScopeGlobal, 0};
    Boolean nativeAvailability = SpatialShimNativeHasProperty(probeDevice, 'hrfa');
    assert(!SpatialRenderRequestsPersonalizedHRTF());
    SpatialShimSetConfiguration(0, false);
    SpatialRenderConfigure((SpatialRenderConfiguration){1, probeDevice, 1, SpatialHRTFPersonalized, 0, 20});
    assert(SpatialRenderRequestsPersonalizedHRTF());
    assert(AudioObjectHasProperty(probeDevice, &availability));
    assert(SpatialShimNativeHasProperty(probeDevice, 'hrfa') == nativeAvailability);
    UInt32 bytes = 0;
    assert(!AudioObjectGetPropertyDataSize(probeDevice, &availability, 0, NULL, &bytes) && bytes == 4);
    struct { UInt32 value, guard; } result = {0, 0xcafef00d};
    assert(!AudioObjectGetPropertyData(probeDevice, &availability, 0, NULL, &bytes, &result.value));
    assert(result.value == 1 && result.guard == 0xcafef00d);
    bytes = 3; result.value = 42;
    assert(AudioObjectGetPropertyData(probeDevice, &availability, 0, NULL, &bytes, &result.value) == kAudioHardwareBadPropertySizeError);
    assert(result.value == 42 && result.guard == 0xcafef00d);
    const SpatialRenderConfiguration inactive[] = {
        {2, probeDevice, 1, SpatialHRTFGeneric, 0, 20},
        {3, probeDevice, 1, SpatialHRTFSystem, 0, 20},
        {4, probeDevice, 0, SpatialHRTFPersonalized, 0, 20},
        {5, 0, 1, SpatialHRTFPersonalized, 0, 20}
    };
    for (unsigned i = 0; i < sizeof(inactive) / sizeof(*inactive); i++) {
        SpatialRenderConfigure(inactive[i]);
        assert(!SpatialRenderRequestsPersonalizedHRTF());
        assert(AudioObjectHasProperty(probeDevice, &availability) == nativeAvailability);
    }
    configure(1, 20, false); Chain c = makeChain(true);
    assert(gain(c.units[1]) == -3 && gain(c.units[4]) == 3);
    float peak = 0; for (unsigned b = 0; b < 30; b++) peak = fmaxf(peak, render(c, b));
    assert(peak > .001); destroy(c);
    const float values[] = {0, 5, 10, 15, 20, 7.3f};
    for (unsigned i = 0; i < sizeof(values) / sizeof(*values); i++) {
        configure(2 + i, values[i], true); c = makeChain(true);
        SpatialRenderRefreshStatus(); SpatialRenderStatus s = SpatialRenderGetStatus();
        assert(s.headroomState == SpatialRenderApplied && s.pairCount == 1 && s.headphoneMixers == 1);
        assert(fabsf(gain(c.units[1]) + values[i]) < .0001 && fabsf(gain(c.units[4]) - values[i]) < .0001);
        assert(!AudioUnitUninitialize(c.units[0])); assert(!AudioUnitInitialize(c.units[0]));
        assert(fabsf(gain(c.units[1]) + values[i]) < .0001);
        destroy(c);
    }
    configure(10, 20, true); c = makeChain(false);
    assert(SpatialRenderGetStatus().headroomState != SpatialRenderApplied);
    assert(gain(c.units[1]) == -3 && gain(c.units[4]) == 3); destroy(c);

    configure(11, 20, true); c = makeChain(true); Chain second = makeChain(true);
    assert(SpatialRenderGetStatus().headroomState == SpatialRenderUnavailable);
    assert(gain(c.units[1]) == -3 && gain(c.units[4]) == 3);
    assert(gain(second.units[1]) == -3 && gain(second.units[4]) == 3); destroy(second); destroy(c);

    configure(12, 20, true); c = makeChain(true);
    configure(13, 7.3f, true); second = makeChain(true);
    assert(gain(c.units[1]) == -20 && gain(c.units[4]) == 20);
    assert(fabsf(gain(second.units[1]) + 7.3f) < .0001); destroy(c);
    assert(SpatialRenderGetStatus().headroomState == SpatialRenderApplied); destroy(second);

    configure(14, 20, true); SpatialRenderTestFailGainWrites(1, 1); c = makeChain(true);
    assert(SpatialRenderGetStatus().headroomState == SpatialRenderFailed && !SpatialRenderGetStatus().rollbackFailed);
    assert(gain(c.units[1]) == -3 && gain(c.units[4]) == 3); destroy(c);
    configure(15, 20, true); SpatialRenderTestFailGainWrites(1, 3); c = makeChain(true);
    assert(SpatialRenderGetStatus().rollbackFailed);
    for (unsigned b = 0; b < 30; b++) assert(render(c, b) == 0); destroy(c);

    configure(16, 7.3f, true); c = makeChain(true);
    atomic_store(&writing, true); pthread_t thread; assert(!pthread_create(&thread, NULL, writer, c.units[1]));
    for (unsigned i = 0; i < 100; i++) { render(c, i); assert(fabsf(gain(c.units[1]) + 7.3f) < .0001); }
    atomic_store(&writing, false); pthread_join(thread, NULL); destroy(c);
    configure(17, 20, true); c = makeChain(true); render(c, 0);
    assert(!SpatialRenderTestChangeGain(c.units[1], 0));
    SpatialRenderRefreshStatus();
    assert(SpatialRenderGetStatus().needsRebuild && SpatialRenderGetStatus().headroomState == SpatialRenderFailed);
    assert(gain(c.units[1]) == -3 && gain(c.units[4]) == 3);
    for (unsigned b = 1; b < 10; b++) assert(render(c, b) == 0);
    destroy(c);
    for (unsigned i = 0; i < 30; i++) { configure(20 + i, 5, true); c = makeChain(true); destroy(c); }
    puts("PASS: topology, continuous values, default preservation, incomplete/ambiguous graphs, generations, rollback/mute, concurrent native writes, lifecycle reuse");
}
