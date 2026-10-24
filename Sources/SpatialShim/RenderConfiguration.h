#ifndef SPATIAL_RENDER_CONFIGURATION_H
#define SPATIAL_RENDER_CONFIGURATION_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

enum { SpatialHRTFSystem = -1, SpatialHRTFGeneric = 0, SpatialHRTFPersonalized = 1 };
enum {
    SpatialRenderSystem = 0, SpatialRenderWaiting = 1, SpatialRenderApplied = 2,
    SpatialRenderUnavailable = 3, SpatialRenderFailed = 4, SpatialRenderInactive = 5
};
typedef struct {
    uint64_t generation;
    uint32_t deviceID;
    uint32_t allowed;
    int32_t hrtfMode;
    uint32_t customHeadroom;
    float headroomDB;
} SpatialRenderConfiguration;
typedef struct {
    uint64_t generation;
    uint32_t deviceID, allowed, mixers, headphoneMixers;
    int32_t requestedHRTF, actualHRTF, hrtfError;
    uint32_t customHeadroom, headroomState;
    float requestedHeadroomDB, actualPreGainDB, actualPostGainDB;
    int32_t headroomError;
    uint32_t pairCount, rollbackFailed, needsRebuild;
} SpatialRenderStatus;

// Control-thread APIs. Configuration is published before constructing AVPlayer.
void SpatialRenderConfigure(SpatialRenderConfiguration configuration);
void SpatialRenderRefreshStatus(void);
SpatialRenderStatus SpatialRenderGetStatus(void);
// Lock-free policy for the existing CoreAudio capability hooks. This requests
// access to the system's real profile; it never substitutes actual AU status.
bool SpatialRenderRequestsPersonalizedHRTF(void);

// Shared lifecycle hooks; also used by research probes with external interposers.
void SpatialRenderUnitCreated(AudioComponentInstance unit);
void SpatialRenderUnitInitialized(AudioUnit unit, OSStatus result);
void SpatialRenderUnitUninitialized(AudioUnit unit, OSStatus result);
void SpatialRenderWillDispose(AudioUnit unit);
void SpatialRenderDidDispose(AudioUnit unit, OSStatus result);
void SpatialRenderObservedProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, const void *requested, UInt32 size, OSStatus result);
bool SpatialRenderHRTFOverride(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 size, UInt32 *replacement);
AudioUnitParameterValue SpatialRenderParameterValue(AudioUnit unit, AudioUnitParameterID parameter,
    AudioUnitScope scope, AudioUnitElement element, AudioUnitParameterValue requested);
void SpatialRenderParameterResult(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue requested, OSStatus result);

#ifdef SPATIAL_DIAGNOSTICS
typedef struct {
    uintptr_t unit, input;
    uint64_t generation;
    uint32_t type, subtype, initialized, headphones, started;
} SpatialRenderNodeInfo;
unsigned SpatialRenderCopyNodes(SpatialRenderNodeInfo *nodes, unsigned capacity);
#endif
#ifdef SPATIAL_RENDER_TESTING
void SpatialRenderTestFailGainWrites(unsigned skip, unsigned count);
bool SpatialRenderTestSetComponentSubtype(AudioUnit unit, UInt32 subtype);
OSStatus SpatialRenderTestChangeGain(AudioUnit unit, float value);
#endif
#endif
