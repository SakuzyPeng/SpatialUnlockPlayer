#ifndef ROUTE_PROBE_H
#define ROUTE_PROBE_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

enum { RouteCapacity = 64, RouteMaxFrames = 960000, RouteMaxBlocks = 8192 };
enum { RouteMaxParameters = 128 };
typedef struct {
    AudioUnitParameterID id;
    AudioUnitParameterValue value;
    OSStatus error;
    char name[128];
    UInt32 unit;
} RouteParameter;
typedef struct {
    uint64_t offset, hostTime;
    double sampleTime;
    uint32_t frames, flags, timeFlags;
} RouteBlock;
typedef struct {
    const char *kind;
    AudioUnit unit;
    AudioObjectID device;
    AudioStreamBasicDescription format;
    OSStatus formatError, notifyError;
    uint64_t frames, callbacks, errors, unsupported, overflow, duplicates, gaps;
    unsigned blockCount;
    double previousTime;
    UInt32 previousFrames;
    bool haveTime, disposed;
    float *samples;
    RouteBlock *blocks;
    UInt32 propertyValues[5];
    OSStatus propertyErrors[5];
    float quaternion[4];
    OSStatus quaternionError;
    OSStatus hrtfOverrideError;
    AudioComponentDescription component;
    char kindStorage[64];
    char componentName[128];
    bool unitTrace, formatRead;
    UInt32 bypass;
    OSStatus bypassError;
    unsigned parameterCount;
    unsigned unitOrdinal;
    uint64_t gainOverrides;
    float lastRequestedGain;
    RouteParameter parameters[RouteMaxParameters];
} RouteRecord;

void RouteFreeze(void);
void RouteSnapshotProperties(void);
void RouteSetHRTFOverride(int mode);
void RouteSetUnitTracing(bool enabled);
void RouteSetHeadroomOverride(float decibels);
unsigned RouteCount(void);
const RouteRecord *RouteGet(unsigned index);
#endif
