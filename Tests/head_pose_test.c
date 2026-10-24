#include "../Sources/SpatialShim/HeadPose.h"
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

static float input[512], left[512], right[512];
static OSStatus inputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)context; (void)flags; (void)bus;
    assert(frames <= 512);
    for (UInt32 i = 0; i < frames; i++) input[i] = .1f * sinf((float)(time->mSampleTime + i) * 2 * (float)M_PI * 1800 / 48000);
    data->mBuffers[0].mData = input;
    data->mBuffers[0].mDataByteSize = frames * sizeof(float);
    return noErr;
}
static AudioUnit makeMixer(void) {
    AudioComponentDescription d = {kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer, kAudioUnitManufacturer_Apple, 0, 0};
    AudioUnit unit = NULL;
    assert(AudioComponentInstanceNew(AudioComponentFindNext(NULL, &d), &unit) == noErr);
    AudioStreamBasicDescription f = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 1, 32, 0};
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)) == noErr);
    f.mChannelsPerFrame = 2;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof(f)) == noErr);
    UInt32 outputType = kSpatialMixerOutputType_Headphones;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType, sizeof(outputType)) == noErr);
    UInt32 algorithm = kSpatializationAlgorithm_UseOutputType;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &algorithm, sizeof(algorithm)) == noErr);
    assert(AudioUnitSetParameter(unit, kSpatialMixerParam_Distance, kAudioUnitScope_Input, 0, 1, 0) == noErr);
    assert(AudioUnitSetParameter(unit, kSpatialMixerParam_Azimuth, kAudioUnitScope_Input, 0, 0, 0) == noErr);
    AURenderCallbackStruct callback = {inputRender, NULL};
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) == noErr);
    assert(AudioUnitInitialize(unit) == noErr);
    return unit;
}
static void render(AudioUnit unit, double sample) {
    struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    AudioTimeStamp time = {.mSampleTime = sample, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;
    assert(AudioUnitRender(unit, &flags, &time, 0, 512, (AudioBufferList *)&output) == noErr);
}
static void readPose(AudioUnit unit, float q[4]) {
    UInt32 size = 16;
    assert(AudioUnitGetProperty(unit, 3102, kAudioUnitScope_Global, 0, q, &size) == noErr && size == 16);
}
static double renderLevelDifference(AudioUnit unit, unsigned firstBlock) {
    double l = 0, r = 0;
    for (unsigned b = 0; b < 50; b++) {
        render(unit, (firstBlock + b) * 512);
        if (b < 30) continue; // Let spatial filter interpolation settle.
        for (unsigned i = 0; i < 512; i++) { l += left[i]*left[i]; r += right[i]*right[i]; }
    }
    assert(l > 1e-8 && r > 1e-8);
    return 10 * log10(l/r);
}
static _Atomic bool publishing;
static void *publisher(void *unused) {
    (void)unused;
    unsigned n = 0;
    while (atomic_load(&publishing)) {
        if (++n & 1) SpatialHeadPosePublish(.6f, 0, 0, .8f);
        else SpatialHeadPosePublish(0, -.6f, 0, .8f);
    }
    return NULL;
}
int main(void) {
    assert(!SpatialHeadPosePublish(NAN, 0, 0, 1));
    assert(!SpatialHeadPosePublish(0, 0, 0, 0));
    AudioUnit unit = makeMixer();
    assert(SpatialHeadPoseGetStatus().mixers == 1);
    float native[4] = {0, 0, .17364818f, .98480775f}, q[4];
    assert(AudioUnitSetProperty(unit, 3102, kAudioUnitScope_Global, 0, native, sizeof(native)) == noErr);
    assert(SpatialHeadPosePublish(0, 0, .38268343f, .92387953f));
    SpatialHeadPoseSetEnabled(true);
    render(unit, 0);
    readPose(unit, q);
    assert(fabsf(q[2] - .38268343f) < 1e-5 && fabsf(q[3] - .92387953f) < 1e-5);
    assert(SpatialHeadPoseGetStatus().renderCallbacks > 0 && SpatialHeadPoseGetStatus().applied > 0);
    // A new native update is cached but cannot overwrite the selected external pose.
    native[2] = -.17364818f;
    assert(AudioUnitSetProperty(unit, 3102, kAudioUnitScope_Global, 0, native, sizeof(native)) == noErr);
    readPose(unit, q); assert(fabsf(q[2] - .38268343f) < 1e-5);
    SpatialHeadPoseSetEnabled(false);
    render(unit, 512);
    readPose(unit, q); assert(fabsf(q[2] - native[2]) < 1e-5);
    assert(SpatialHeadPoseGetStatus().restored > 0);
    SpatialHeadPoseSetEnabled(true);
    SpatialHeadPosePublish(0, 0, .38268343f, .92387953f);
    double positive = renderLevelDifference(unit, 2);
    SpatialHeadPosePublish(0, 0, -.38268343f, .92387953f);
    double negative = renderLevelDifference(unit, 52);
    printf("Offline Apple binaural PCM at 1800 Hz: Z+45 %.2f dB, Z-45 %.2f dB\n", positive, negative);
    fflush(stdout);
    assert(positive > 2 && negative < -2);

    SpatialHeadPosePublish(.6f, 0, 0, .8f);
    SpatialHeadPoseSetEnabled(true);
    render(unit, 102 * 512);
    atomic_store(&publishing, true);
    pthread_t thread; assert(!pthread_create(&thread, NULL, publisher, NULL));
    for (unsigned i = 103; i < 503; i++) {
        // Simulate native head updates racing with the OSC publisher. Even a
        // mailbox read collision must preserve an external, coherent pose.
        assert(AudioUnitSetProperty(unit, 3102, kAudioUnitScope_Global, 0, native, sizeof(native)) == noErr);
        render(unit, i * 512);
        readPose(unit, q);
        float norm = q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3];
        assert(fabsf(norm - 1) < 1e-5);
        assert((fabsf(q[0] - .6f) < 1e-5 && fabsf(q[1]) < 1e-5) ||
               (fabsf(q[0]) < 1e-5 && fabsf(q[1] + .6f) < 1e-5));
    }
    atomic_store(&publishing, false); pthread_join(thread, NULL);
    SpatialHeadPoseSetEnabled(false);
    assert(AudioUnitUninitialize(unit) == noErr && AudioUnitInitialize(unit) == noErr);
    SpatialHeadPosePublish(0, 0, .38268343f, .92387953f); SpatialHeadPoseSetEnabled(true);
    render(unit, 0); readPose(unit, q); assert(fabsf(q[2] - .38268343f) < 1e-5);
    SpatialHeadPoseSetEnabled(false);
    assert(AudioComponentInstanceDispose(unit) == noErr);
    assert(SpatialHeadPoseGetStatus().mixers == 0);
    // More lifecycles than registry slots: disposed units must release their slot.
    for (unsigned i = 0; i < 70; i++) {
        unit = makeMixer();
        assert(SpatialHeadPoseGetStatus().mixers == 1);
        assert(AudioComponentInstanceDispose(unit) == noErr);
    }
    assert(SpatialHeadPoseGetStatus().mixers == 0 && SpatialHeadPoseGetStatus().failures == 0);
    puts("PASS: render-driven pose without native tracking, native override/restore, coherent concurrent publication, mixer lifecycle");
}
