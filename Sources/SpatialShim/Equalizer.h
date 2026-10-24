#ifndef SPATIAL_EQUALIZER_H
#define SPATIAL_EQUALIZER_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

enum { SpatialEQMaxFilters = 32, SpatialEQPeak = 0, SpatialEQLowShelf = 1, SpatialEQHighShelf = 2 };
enum { SpatialEQOK = 0, SpatialEQFormat = 1, SpatialEQFrequency = 2,
       SpatialEQCoefficientsInvalid = 3, SpatialEQRenderError = 4, SpatialEQBuffer = 5, SpatialEQNonFinite = 6 };
typedef struct { uint32_t type, enabled; double frequency, gain, q; } SpatialEQFilter;
typedef struct { double b0, b1, b2, a1, a2; } SpatialEQCoefficients;
typedef struct {
    uint32_t enabled, mixers, activeMixers;
    int32_t lastError;
    double sampleRate;
    uint64_t generation, processedBuffers, processedFrames;
    uint32_t minFrames, maxFrames;
} SpatialEQStatus;

// Control-thread API. Configuration is copied; the caller retains no C buffers.
bool SpatialEQSetConfiguration(const SpatialEQFilter *filters, uint32_t count, double preamp, bool enabled);
void SpatialEQSetEnabled(bool enabled);
void SpatialEQReset(void);
SpatialEQStatus SpatialEQGetStatus(void);
bool SpatialEQMakeCoefficients(SpatialEQFilter filter, double sampleRate, SpatialEQCoefficients *result);
double SpatialEQCoefficientResponse(SpatialEQCoefficients coefficients, double sampleRate, double frequency);

// Internal lifecycle API, shared by the mixer observer and native DSP tests.
typedef struct SpatialEQContext SpatialEQContext;
SpatialEQContext *SpatialEQCreate(AudioUnit unit);
SpatialEQContext *SpatialEQCreateForFormat(AudioStreamBasicDescription format, uint32_t maximumFrames);
void SpatialEQRefresh(SpatialEQContext *context, AudioUnit unit);
void SpatialEQDestroy(SpatialEQContext *context);
void SpatialEQResetContext(SpatialEQContext *context);
void SpatialEQProcess(SpatialEQContext *context, AudioUnitRenderActionFlags *flags,
                      const AudioTimeStamp *time, uint32_t frames, AudioBufferList *data);
#endif
