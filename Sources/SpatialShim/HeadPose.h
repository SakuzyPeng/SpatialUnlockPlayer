#ifndef SPATIAL_HEAD_POSE_H
#define SPATIAL_HEAD_POSE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint32_t enabled;
    uint32_t mixers;
    int32_t lastError;
    uint64_t published;
    uint64_t applied;
    uint64_t restored;
    uint64_t renderCallbacks;
    uint64_t failures;
} SpatialHeadPoseStatus;

// Publish from the receiver's serial control queue, never from the audio thread.
// Coordinates are the Apple mixer's world-to-head XYZW quaternion.
bool SpatialHeadPosePublish(float x, float y, float z, float w);
void SpatialHeadPoseSetEnabled(bool enabled);
SpatialHeadPoseStatus SpatialHeadPoseGetStatus(void);
#endif
