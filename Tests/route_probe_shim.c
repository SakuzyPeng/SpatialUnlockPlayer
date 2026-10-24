// Research only: observe the existing AU and per-process HAL buffers without
// adding a tap or changing the render block size. Never linked into the app.
#include "route_probe.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

static OSStatus captureAddNotify(AudioUnit, AURenderCallback, void *);
static OSStatus captureRemoveNotify(AudioUnit, AURenderCallback, void *);
#define AudioUnitAddRenderNotify captureAddNotify
#define AudioUnitRemoveRenderNotify captureRemoveNotify
#include "../Sources/SpatialShim/HeadPose.c"
#undef AudioUnitAddRenderNotify
#undef AudioUnitRemoveRenderNotify

static RouteRecord records[RouteCapacity];
static _Atomic unsigned count, readers;
static _Atomic bool collecting = true;
static int hrtfOverride = -1;
static bool traceUnits;
static float headroomOverride = NAN;
void RouteSetHRTFOverride(int mode) { hrtfOverride = mode; }
void RouteSetUnitTracing(bool value) { traceUnits = value; }
void RouteSetHeadroomOverride(float decibels) { headroomOverride = decibels; }
static bool enter(void) {
    atomic_fetch_add(&readers, 1);
    if (atomic_load(&collecting)) return true;
    atomic_fetch_sub(&readers, 1); return false;
}
static void leave(void) { atomic_fetch_sub(&readers, 1); }
void RouteFreeze(void) {
    atomic_store(&collecting, false);
    while (atomic_load(&readers)) sched_yield();
}
unsigned RouteCount(void) { unsigned n = atomic_load(&count); return n < RouteCapacity ? n : RouteCapacity; }
const RouteRecord *RouteGet(unsigned i) { return i < RouteCount() ? &records[i] : NULL; }
static RouteRecord *makeRecord(const char *kind, AudioUnit unit, AudioObjectID device,
                              AudioStreamBasicDescription format) {
    unsigned i = atomic_fetch_add(&count, 1);
    if (i >= RouteCapacity) return NULL;
    RouteRecord *r = &records[i];
    r->kind = kind; r->unit = unit; r->device = device; r->format = format;
    r->samples = calloc(RouteMaxFrames * 2, sizeof(float));
    r->blocks = calloc(RouteMaxBlocks, sizeof(RouteBlock));
    // Allocate and fault pages before callbacks are registered.
    if (r->samples) for (size_t p = 0; p < RouteMaxFrames * 2; p += 1024) ((volatile float *)r->samples)[p] = 0;
    if (r->blocks) for (size_t p = 0; p < sizeof(RouteBlock) * RouteMaxBlocks; p += 4096) ((volatile char *)r->blocks)[p] = 0;
    return r;
}
static void capture(RouteRecord *r, AudioBufferList *data, UInt32 frames,
                    const AudioTimeStamp *time, UInt32 flags) {
    if (!r || !enter()) return;
    r->callbacks++;
    if (flags & kAudioUnitRenderAction_PostRenderError) { r->errors++; leave(); return; }
    if (!data || r->format.mFormatID != kAudioFormatLinearPCM ||
        !(r->format.mFormatFlags & kAudioFormatFlagIsFloat) || r->format.mBitsPerChannel != 32 ||
        r->format.mChannelsPerFrame != 2 || (r->format.mFormatFlags & kAudioFormatFlagIsBigEndian)) {
        r->unsupported++; leave(); return;
    }
    if (time && (time->mFlags & kAudioTimeStampSampleTimeValid)) {
        if (r->haveTime && time->mSampleTime == r->previousTime) { r->duplicates++; leave(); return; }
        if (r->haveTime && fabs(time->mSampleTime - r->previousTime - r->previousFrames) > .01) r->gaps++;
        r->previousTime = time->mSampleTime; r->previousFrames = frames; r->haveTime = true;
    }
    float *p[2] = {0}; UInt32 stride[2] = {0}; unsigned c = 0;
    for (unsigned b = 0; b < data->mNumberBuffers && c < 2; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        if (buffer->mDataByteSize < (uint64_t)frames * buffer->mNumberChannels * 4) break;
        for (unsigned j = 0; j < buffer->mNumberChannels && c < 2; j++, c++) {
            p[c] = buffer->mData ? (float *)buffer->mData + j : NULL;
            stride[c] = buffer->mNumberChannels;
        }
    }
    if (c != 2 || ((!p[0] || !p[1]) && !(flags & kAudioUnitRenderAction_OutputIsSilence))) {
        r->unsupported++; leave(); return;
    }
    if (!r->samples || !r->blocks || r->frames + frames > RouteMaxFrames || r->blockCount >= RouteMaxBlocks) {
        r->overflow++; leave(); return;
    }
    r->blocks[r->blockCount++] = (RouteBlock){r->frames, time ? time->mHostTime : 0,
        time ? time->mSampleTime : 0, frames, flags, time ? time->mFlags : 0};
    for (unsigned f = 0; f < frames; f++) {
        r->samples[(r->frames + f) * 2] = p[0] ? p[0][f * stride[0]] : 0;
        r->samples[(r->frames + f) * 2 + 1] = p[1] ? p[1][f * stride[1]] : 0;
    }
    r->frames += frames;
    leave();
}
static void snapshot(RouteRecord *r) {
    if (!r->unit || r->disposed || r->unitTrace) return;
    const AudioUnitPropertyID properties[5] = {3100, 3111, 3113, 3116, kAudioUnitProperty_UsesInternalReverb};
    for (unsigned i = 0; i < 5; i++) {
        UInt32 size = sizeof(UInt32);
        r->propertyErrors[i] = AudioUnitGetProperty(r->unit, properties[i], kAudioUnitScope_Global, 0, &r->propertyValues[i], &size);
    }
    UInt32 size = sizeof(r->quaternion);
    r->quaternionError = AudioUnitGetProperty(r->unit, 3102, kAudioUnitScope_Global, 0, r->quaternion, &size);
}
void RouteSnapshotProperties(void) {
    for (unsigned i = 0; i < RouteCount(); i++) snapshot(&records[i]);
}
static OSStatus captureNotify(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus;
    if (flags && (*flags & kAudioUnitRenderAction_PostRender)) capture(context, data, frames, time, *flags);
    return noErr;
}
static OSStatus captureAddNotify(AudioUnit unit, AURenderCallback callback, void *context) {
    OSStatus result = AudioUnitAddRenderNotify(unit, callback, context);
    if (result) return result;
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format);
    OSStatus err = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    RouteRecord *r = makeRecord("spatial-postrender", unit, 0, format);
    if (r) {
        r->formatError = err;
        if (hrtfOverride >= 0) {
            UInt32 mode = (UInt32)hrtfOverride;
            r->hrtfOverrideError = AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                kAudioUnitScope_Global, 0, &mode, sizeof(mode));
        }
        snapshot(r); r->notifyError = AudioUnitAddRenderNotify(unit, captureNotify, r);
    }
    return result;
}
static OSStatus captureRemoveNotify(AudioUnit unit, AURenderCallback callback, void *context) {
    for (unsigned i = 0; i < RouteCount(); i++) if (records[i].unit == unit && !records[i].disposed) {
        // Preserve the live, pre-pause snapshot once capture has been frozen.
        if (atomic_load(&collecting)) snapshot(&records[i]);
        AudioUnitRemoveRenderNotify(unit, captureNotify, &records[i]); records[i].disposed = true;
    }
    return AudioUnitRemoveRenderNotify(unit, callback, context);
}

typedef struct { AudioDeviceIOProc callback; void *context; RouteRecord *record; } RouteIO;
static RouteIO ioContexts[RouteCapacity];
static _Atomic unsigned ioCount;
static RouteRecord *makeHAL(AudioObjectID device) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    AudioStreamID streams[32]; UInt32 size = sizeof(streams);
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, streams) || size < sizeof(AudioStreamID)) return NULL;
    a.mSelector = kAudioStreamPropertyVirtualFormat; a.mScope = kAudioObjectPropertyScopeGlobal;
    AudioStreamBasicDescription format = {0}; size = sizeof(format);
    if (AudioObjectGetPropertyData(streams[0], &a, 0, NULL, &size, &format)) return NULL;
    return makeRecord("hal-output", NULL, device, format);
}
static void captureHAL(RouteRecord *r, AudioBufferList *data, const AudioTimeStamp *time) {
    if (!r || !data || !data->mNumberBuffers || !data->mBuffers[0].mNumberChannels) return;
    UInt32 frames = data->mBuffers[0].mDataByteSize / (4 * data->mBuffers[0].mNumberChannels);
    capture(r, data, frames, time, 0);
}
static OSStatus routeOutput(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    RouteIO *io = context;
    OSStatus result = io->callback(device, now, input, inputTime, output, outputTime, io->context);
    if (!result) captureHAL(io->record, output, outputTime);
    return result;
}
static OSStatus routeCreateIO(AudioObjectID device, AudioDeviceIOProc proc, void *context, AudioDeviceIOProcID *out) {
    unsigned i = atomic_fetch_add(&ioCount, 1);
    if (i >= RouteCapacity) return AudioDeviceCreateIOProcID(device, proc, context, out);
    RouteIO *io = &ioContexts[i]; io->callback = proc; io->context = context; io->record = makeHAL(device);
    return AudioDeviceCreateIOProcID(device, routeOutput, io, out);
}
static OSStatus routeCreateBlock(AudioDeviceIOProcID *out, AudioObjectID device, dispatch_queue_t queue, AudioDeviceIOBlock block) {
    RouteRecord *r = makeHAL(device);
    return AudioDeviceCreateIOProcIDWithBlock(out, device, queue,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
          AudioBufferList *output, const AudioTimeStamp *outputTime) {
            block(now, input, inputTime, output, outputTime); captureHAL(r, output, outputTime);
        });
}
INTERPOSE(routeCreateIO, AudioDeviceCreateIOProcID)
INTERPOSE(routeCreateBlock, AudioDeviceCreateIOProcIDWithBlock)

// Optional research inventory: install notifications during instance creation,
// before initialization. The first notification reads the negotiated format and
// small parameter values. Buffers were allocated before notification registration;
// there is no file I/O or PCM modification in these observations.
static OSStatus unitNotify(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                           UInt32 bus, UInt32 frames, AudioBufferList *data) {
    RouteRecord *r = context;
    if (!flags || bus || !enter()) return noErr;
    if (!r->formatRead) {
        UInt32 size = sizeof(r->format);
        r->formatError = AudioUnitGetProperty(r->unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, bus, &r->format, &size);
        size = sizeof(r->bypass);
        r->bypassError = AudioUnitGetProperty(r->unit, kAudioUnitProperty_BypassEffect,
            kAudioUnitScope_Global, 0, &r->bypass, &size);
        for (unsigned i = 0; i < r->parameterCount; i++)
            r->parameters[i].error = AudioUnitGetParameter(r->unit, r->parameters[i].id, kAudioUnitScope_Global, 0,
                &r->parameters[i].value);
        r->formatRead = true;
    }
    if (*flags & kAudioUnitRenderAction_PostRender) capture(r, data, frames, time, *flags);
    leave(); return noErr;
}
static OSStatus traceComponentNew(AudioComponent component, AudioComponentInstance *out) {
    OSStatus result = AudioComponentInstanceNew(component, out);
    if (!result && out && *out) SpatialRenderUnitCreated(*out);
    if (result || !traceUnits || !out || !*out) return result;
    AudioComponentDescription description = {0};
    if (AudioComponentGetDescription(component, &description) ||
        description.componentManufacturer != kAudioUnitManufacturer_Apple ||
        description.componentSubType == kAudioUnitSubType_SpatialMixer) return result;
    RouteRecord *r = makeRecord("unit", *out, 0, (AudioStreamBasicDescription){0});
    if (!r) return result;
    r->unitTrace = true; r->component = description;
    CFStringRef name = NULL;
    if (!AudioComponentCopyName(component, &name) && name) {
        CFStringGetCString(name, r->componentName, sizeof(r->componentName), kCFStringEncodingUTF8);
        CFRelease(name);
    }
    UInt32 t = description.componentType, s = description.componentSubType;
    unsigned ordinal = 0;
    for (unsigned i = 0; i < RouteCount(); i++) if (&records[i] != r && records[i].unitTrace &&
        records[i].component.componentType == t && records[i].component.componentSubType == s) ordinal++;
    r->unitOrdinal = ordinal;
    AudioUnitParameterID ids[RouteMaxParameters]; UInt32 bytes = sizeof(ids);
    if (!AudioUnitGetProperty(r->unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids, &bytes)) {
        r->parameterCount = bytes / sizeof(ids[0]);
        if (r->parameterCount > RouteMaxParameters) r->parameterCount = RouteMaxParameters;
        for (unsigned i = 0; i < r->parameterCount; i++) {
            RouteParameter *p = &r->parameters[i]; p->id = ids[i];
            AudioUnitParameterInfo info = {0}; bytes = sizeof(info);
            if (!AudioUnitGetProperty(r->unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, ids[i], &info, &bytes)) {
                p->unit = info.unit;
                if ((info.flags & kAudioUnitParameterFlag_HasCFNameString) && info.cfNameString) {
                    CFStringGetCString(info.cfNameString, p->name, sizeof(p->name), kCFStringEncodingUTF8);
                    if (info.flags & kAudioUnitParameterFlag_CFNameRelease) CFRelease(info.cfNameString);
                } else snprintf(p->name, sizeof(p->name), "%s", info.name);
            }
        }
    }
    snprintf(r->kindStorage, sizeof(r->kindStorage), "au-%c%c%c%c-%c%c%c%c-%u-post",
        (int)(t >> 24), (int)((t >> 16) & 255), (int)((t >> 8) & 255), (int)(t & 255),
        (int)(s >> 24), (int)((s >> 16) & 255), (int)((s >> 8) & 255), (int)(s & 255), ordinal);
    r->kind = r->kindStorage;
    r->notifyError = AudioUnitAddRenderNotify(*out, unitNotify, r);
    return result;
}
INTERPOSE(traceComponentNew, AudioComponentInstanceNew)

// Causal control for this test process only. Match the two observed gain stages
// while preserving all other unit parameters and the system/global settings.
static OSStatus traceParameter(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitScope scope,
                               AudioUnitElement element, AudioUnitParameterValue value, UInt32 offset) {
    if (isfinite(headroomOverride) && parameter == 7 && scope == kAudioUnitScope_Global && element == 0) {
        for (unsigned i = 0; i < RouteCount(); i++) {
            RouteRecord *r = &records[i];
            if (r->unit == unit && r->unitTrace && r->component.componentSubType == 'vrq2' && r->unitOrdinal < 2) {
                r->lastRequestedGain = value; r->gainOverrides++;
                value = r->unitOrdinal ? headroomOverride : -headroomOverride;
                break;
            }
        }
    }
    float actual = SpatialRenderParameterValue(unit, parameter, scope, element, value);
    OSStatus result = AudioUnitSetParameter(unit, parameter, scope, element, actual, offset);
    SpatialRenderParameterResult(unit, parameter, scope, element, value, result); return result;
}
INTERPOSE(traceParameter, AudioUnitSetParameter)
