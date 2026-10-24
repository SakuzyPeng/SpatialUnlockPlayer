#ifndef EQ_PROBE_H
#define EQ_PROBE_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdbool.h>
#include "../Sources/SpatialShim/Equalizer.h"

enum { EQProbePhases = 4, EQProbeFrequencies = 3, EQProbeCapacity = 32 };
typedef struct {
    uint64_t frames;
    double energy[2], real[2][3], imaginary[2][3], oscillatorReal[3], oscillatorImaginary[3];
} EQProbeSpectrum;
typedef struct {
    const char *kind;
    AudioUnit unit;
    AudioStreamBasicDescription format;
    OSStatus formatError, notifyError;
    uint64_t callbacks, errors, unsupported, duplicateTimes, returned, matchingReturns;
    double lastSampleTime;
    uint64_t lastHash;
    UInt32 lastFrames, minFrames, maxFrames, buffers, channels[8];
    EQProbeSpectrum spectra[EQProbePhases][2];
    double coefficients[5], history[2][2];
    int previousMode;
} EQProbeRecord;

// Test process only. Read records after playback and callbacks have stopped.
void EQProbeControl(int mode, int phase);
void EQProbeUseTap(bool enabled);
void EQProbeUseProduction(bool enabled);
void EQProbeProductionPreset(const SpatialEQFilter *filters, uint32_t count, double preamp);
void EQProbeFreeze(void);
unsigned EQProbeCount(void);
const EQProbeRecord *EQProbeGet(unsigned index);
EQProbeRecord *EQProbeNew(const char *kind, AudioUnit unit, const AudioStreamBasicDescription *format);
void EQProbeProcess(EQProbeRecord *record, AudioBufferList *data, UInt32 frames, bool modify);
#endif
