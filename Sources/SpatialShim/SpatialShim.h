#ifndef SPATIAL_SHIM_H
#define SPATIAL_SHIM_H
#include <stdbool.h>
#include <stdint.h>
#include <CoreAudio/CoreAudio.h>
#include "HeadPose.h"

typedef struct {
    uint32_t deviceID;
    uint32_t enabled;
    uint64_t overriddenQueries;
    uint32_t lastSpatialRequest;
    uint32_t lastChannelLayout;
    uint64_t queueSpatialRequests;
} SpatialShimStatus;

void SpatialShimSetConfiguration(uint32_t deviceID, bool enabled);
bool SpatialShimNativeHasProperty(uint32_t deviceID, uint32_t selector);
int32_t SpatialShimNativeReadUInt32(uint32_t deviceID, uint32_t selector, uint32_t *value);
SpatialShimStatus SpatialShimGetStatus(void);
#endif
