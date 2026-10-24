// Standalone research dylib. This file is never compiled into the application.
// Reuse the shipping head-pose implementation, adding a second render observer
// wherever that implementation registers its observer. No product source patch.
#include "eq_probe.h"
#include <stdatomic.h>
#include <math.h>
#include <string.h>

static OSStatus probeAddNotify(AudioUnit, AURenderCallback, void *);
static OSStatus probeRemoveNotify(AudioUnit, AURenderCallback, void *);
#define AudioUnitAddRenderNotify probeAddNotify
#define AudioUnitRemoveRenderNotify probeRemoveNotify
#include "../Sources/SpatialShim/HeadPose.c"
#undef AudioUnitAddRenderNotify
#undef AudioUnitRemoveRenderNotify

static EQProbeRecord records[EQProbeCapacity];
static _Atomic unsigned recordCount;
static _Atomic int processingMode, measurementPhase = -1;
static _Atomic bool tapTarget;
static bool productionTarget;
static int previousProductionMode = -1;
static SpatialEQFilter productionFilters[SpatialEQMaxFilters] = {{SpatialEQPeak, 1, 1800, -12, 1}};
static uint32_t productionFilterCount = 1;
static double productionPreamp;
static _Atomic bool collecting = true;
static _Atomic unsigned collectors;
static const double frequencies[3] = {900, 1800, 2700};

static bool beginCollection(void) {
    atomic_fetch_add(&collectors, 1);
    if (atomic_load(&collecting)) return true;
    atomic_fetch_sub(&collectors, 1); return false;
}
static void endCollection(void) { atomic_fetch_sub(&collectors, 1); }
void EQProbeFreeze(void) {
    atomic_store(&collecting, false);
    while (atomic_load(&collectors)) sched_yield(); // Control thread only.
}

void EQProbeControl(int mode, int phase) {
    atomic_store(&measurementPhase, -1);
    if (productionTarget && mode != previousProductionMode) {
        if (mode == 0) SpatialEQSetEnabled(false);
        else if (mode == 1) SpatialEQSetConfiguration(NULL, 0, -6.020599913279624, true);
        else SpatialEQSetConfiguration(productionFilters, productionFilterCount, productionPreamp, true);
        previousProductionMode = mode;
    }
    atomic_store(&processingMode, mode);
    atomic_store(&measurementPhase, phase);
}
void EQProbeUseTap(bool value) { atomic_store(&tapTarget, value); }
void EQProbeUseProduction(bool value) { productionTarget = value; }
void EQProbeProductionPreset(const SpatialEQFilter *filters, uint32_t count, double preamp) {
    if (count <= SpatialEQMaxFilters) {
        memcpy(productionFilters, filters, count * sizeof(*filters)); productionFilterCount = count; productionPreamp = preamp;
    }
}
unsigned EQProbeCount(void) { unsigned n = atomic_load(&recordCount); return n < EQProbeCapacity ? n : EQProbeCapacity; }
const EQProbeRecord *EQProbeGet(unsigned index) { return index < EQProbeCount() ? &records[index] : NULL; }
EQProbeRecord *EQProbeNew(const char *kind, AudioUnit unit, const AudioStreamBasicDescription *format) {
    unsigned i = atomic_fetch_add(&recordCount, 1);
    if (i >= EQProbeCapacity) return NULL;
    EQProbeRecord *r = &records[i];
    r->kind = kind; r->unit = unit; r->format = *format; r->previousMode = -1;
    r->lastSampleTime = -INFINITY;
    // RBJ peaking EQ: 1800 Hz, Q=1, -12 dB. Compute off the render thread.
    double a = pow(10, -12.0 / 40), w = 2 * M_PI * 1800 / fmax(format->mSampleRate, 1);
    double alpha = sin(w) / 2, a0 = 1 + alpha / a;
    r->coefficients[0] = (1 + alpha * a) / a0;
    r->coefficients[1] = -2 * cos(w) / a0;
    r->coefficients[2] = (1 - alpha * a) / a0;
    r->coefficients[3] = -2 * cos(w) / a0;
    r->coefficients[4] = (1 - alpha / a) / a0;
    return r;
}
static bool samples(EQProbeRecord *r, AudioBufferList *data, UInt32 frames, float *channels[2], UInt32 stride[2]) {
    if (!data || r->format.mFormatID != kAudioFormatLinearPCM ||
        !(r->format.mFormatFlags & kAudioFormatFlagIsFloat) || r->format.mBitsPerChannel != 32 ||
        r->format.mChannelsPerFrame != 2 || (r->format.mFormatFlags & kAudioFormatFlagIsBigEndian)) return false;
    r->buffers = data->mNumberBuffers;
    unsigned ch = 0;
    for (unsigned b = 0; b < data->mNumberBuffers && ch < 2; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        if (b < 8) r->channels[b] = buffer->mNumberChannels;
        if (!buffer->mData || buffer->mDataByteSize < (uint64_t)frames * buffer->mNumberChannels * 4) return false;
        for (unsigned c = 0; c < buffer->mNumberChannels && ch < 2; c++, ch++) {
            channels[ch] = (float *)buffer->mData + c; stride[ch] = buffer->mNumberChannels;
        }
    }
    return ch == 2;
}
static void spectrum(EQProbeSpectrum *s, float *channels[2], UInt32 stride[2], UInt32 frames, double sampleRate) {
    double rotationR[3], rotationI[3];
    for (unsigned k = 0; k < 3; k++) {
        rotationR[k] = cos(2 * M_PI * frequencies[k] / sampleRate);
        rotationI[k] = sin(2 * M_PI * frequencies[k] / sampleRate);
        if (!s->frames) s->oscillatorReal[k] = 1;
    }
    for (unsigned f = 0; f < frames; f++) {
        for (unsigned c = 0; c < 2; c++) {
            double x = channels[c][f * stride[c]];
            s->energy[c] += x * x;
            for (unsigned k = 0; k < 3; k++) {
                s->real[c][k] += x * s->oscillatorReal[k];
                s->imaginary[c][k] += x * s->oscillatorImaginary[k];
            }
        }
        for (unsigned k = 0; k < 3; k++) {
            double old = s->oscillatorReal[k];
            s->oscillatorReal[k] = old * rotationR[k] - s->oscillatorImaginary[k] * rotationI[k];
            s->oscillatorImaginary[k] = old * rotationI[k] + s->oscillatorImaginary[k] * rotationR[k];
        }
    }
    s->frames += frames;
}
static uint64_t hashAudio(AudioBufferList *data) {
    uint64_t h = 1469598103934665603ULL;
    if (data) for (unsigned b = 0; b < data->mNumberBuffers; b++) {
        const unsigned char *p = data->mBuffers[b].mData;
        if (p) for (unsigned i = 0; i < data->mBuffers[b].mDataByteSize; i++) h = (h ^ p[i]) * 1099511628211ULL;
    }
    return h;
}
void EQProbeProcess(EQProbeRecord *r, AudioBufferList *data, UInt32 frames, bool modify) {
    if (!r || !beginCollection()) return;
    r->callbacks++;
    if (r->callbacks == 1 || frames < r->minFrames) r->minFrames = frames;
    if (frames > r->maxFrames) r->maxFrames = frames;
    float *channels[2]; UInt32 stride[2];
    if (!samples(r, data, frames, channels, stride)) { r->unsupported++; endCollection(); return; }
    int phase = atomic_load(&measurementPhase), mode = atomic_load(&processingMode);
    bool measuring = phase >= 0 && phase < EQProbePhases;
    if (measuring) spectrum(&r->spectra[phase][0], channels, stride, frames, r->format.mSampleRate);
    if (modify) {
        if (mode != r->previousMode) { memset(r->history, 0, sizeof(r->history)); r->previousMode = mode; }
        for (unsigned c = 0; c < 2; c++) for (unsigned f = 0; f < frames; f++) {
            float *p = &channels[c][f * stride[c]];
            if (mode == 1) *p *= .5f;
            else if (mode == 2) {
                double x = *p, y = r->coefficients[0] * x + r->history[c][0];
                r->history[c][0] = r->coefficients[1] * x - r->coefficients[3] * y + r->history[c][1];
                r->history[c][1] = r->coefficients[2] * x - r->coefficients[4] * y;
                *p = (float)y;
            }
        }
        if (measuring) spectrum(&r->spectra[phase][1], channels, stride, frames, r->format.mSampleRate);
        r->lastHash = hashAudio(data); r->lastFrames = frames;
    }
    endCollection();
}
static OSStatus eqNotify(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                         UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus;
    if (!flags || !(*flags & kAudioUnitRenderAction_PostRender) || !beginCollection()) return noErr;
    EQProbeRecord *r = context;
    if (*flags & kAudioUnitRenderAction_PostRenderError) { r->errors++; endCollection(); return noErr; }
    if (time && (time->mFlags & kAudioTimeStampSampleTimeValid)) {
        if (time->mSampleTime == r->lastSampleTime) r->duplicateTimes++;
        r->lastSampleTime = time->mSampleTime;
    }
    EQProbeProcess(r, data, frames, !atomic_load(&tapTarget) && !productionTarget);
    endCollection();
    return noErr;
}
static OSStatus probeAddNotify(AudioUnit unit, AURenderCallback callback, void *context) {
    OSStatus result = AudioUnitAddRenderNotify(unit, callback, context);
    if (result) return result;
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format);
    OSStatus e = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    EQProbeRecord *r = EQProbeNew("spatial-postrender", unit, &format);
    if (r) { r->formatError = e; r->notifyError = AudioUnitAddRenderNotify(unit, eqNotify, r); }
    return result;
}
static OSStatus probeRemoveNotify(AudioUnit unit, AURenderCallback callback, void *context) {
    for (unsigned i = 0; i < EQProbeCount(); i++) if (records[i].unit == unit)
        AudioUnitRemoveRenderNotify(unit, eqNotify, &records[i]);
    return AudioUnitRemoveRenderNotify(unit, callback, context);
}
static OSStatus probeRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OSStatus result = AudioUnitRender(unit, flags, time, bus, frames, data);
    if (!result && beginCollection()) {
        for (unsigned i = 0; i < EQProbeCount(); i++) if (records[i].unit == unit) {
            EQProbeRecord *r = &records[i]; r->returned++;
            if (r->lastFrames == frames && hashAudio(data) == r->lastHash) r->matchingReturns++;
        }
        endCollection();
    }
    return result;
}
INTERPOSE(probeRender, AudioUnitRender)

// Observe only this process's HAL contribution, after its existing IOProc fills
// the output buffer. Never capture input, change device settings, or alter HAL data.
typedef struct { AudioDeviceIOProc callback; void *context; EQProbeRecord *record; } ProbeIO;
static ProbeIO ioContexts[16];
static _Atomic unsigned ioCount;
static EQProbeRecord *makeOutputRecord(AudioObjectID device) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    AudioStreamID streams[32]; UInt32 size = sizeof(streams);
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, streams) || size < sizeof(AudioStreamID)) return NULL;
    a.mSelector = kAudioStreamPropertyVirtualFormat; a.mScope = kAudioObjectPropertyScopeGlobal;
    AudioStreamBasicDescription format = {0}; size = sizeof(format);
    if (AudioObjectGetPropertyData(streams[0], &a, 0, NULL, &size, &format)) return NULL;
    return EQProbeNew("hal-output", NULL, &format);
}
static void observeOutput(EQProbeRecord *r, AudioBufferList *data) {
    if (!r || !data || !data->mNumberBuffers || !data->mBuffers[0].mNumberChannels) return;
    UInt32 frames = data->mBuffers[0].mDataByteSize / (4 * data->mBuffers[0].mNumberChannels);
    EQProbeProcess(r, data, frames, false);
}
static OSStatus outputProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    ProbeIO *io = context;
    OSStatus result = io->callback(device, now, input, inputTime, output, outputTime, io->context);
    observeOutput(io->record, output);
    return result;
}
static OSStatus probeCreateIO(AudioObjectID device, AudioDeviceIOProc proc, void *context, AudioDeviceIOProcID *out) {
    unsigned i = atomic_fetch_add(&ioCount, 1);
    if (i >= 16) return AudioDeviceCreateIOProcID(device, proc, context, out);
    ProbeIO *io = &ioContexts[i]; io->callback = proc; io->context = context; io->record = makeOutputRecord(device);
    return AudioDeviceCreateIOProcID(device, outputProc, io, out);
}
static OSStatus probeCreateBlock(AudioDeviceIOProcID *out, AudioObjectID device, dispatch_queue_t queue, AudioDeviceIOBlock block) {
    EQProbeRecord *r = makeOutputRecord(device);
    return AudioDeviceCreateIOProcIDWithBlock(out, device, queue,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
          AudioBufferList *output, const AudioTimeStamp *outputTime) {
            block(now, input, inputTime, output, outputTime); observeOutput(r, output);
        });
}
INTERPOSE(probeCreateIO, AudioDeviceCreateIOProcID)
INTERPOSE(probeCreateBlock, AudioDeviceCreateIOProcIDWithBlock)
