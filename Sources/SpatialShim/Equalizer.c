#include "Equalizer.h"
#include <float.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t generation;
    uint32_t count;
    int32_t error;
    bool enabled;
    double preamp;
    SpatialEQCoefficients filters[SpatialEQMaxFilters];
} Snapshot;
typedef struct { Snapshot config; double history[2][SpatialEQMaxFilters][2]; } Bank;
struct SpatialEQContext {
    struct SpatialEQContext *next;
    AudioStreamBasicDescription format;
    uint32_t capacity, fadeFrames, fadePosition;
    float *cache;
    Snapshot snapshots[3];
    _Atomic unsigned published, readers[3], users;
    _Atomic bool suspended;
    _Atomic uint64_t reset, renderedGeneration, lastRender, buffers, frames;
    _Atomic uint32_t minFrames, maxFrames;
    _Atomic int32_t error;
    Bank current, target;
    uint64_t observedReset;
    bool transitioning, cacheValid, cacheSilent;
    double lastSampleTime;
    uint32_t lastFrames;
};

// Only lifecycle/configuration callers take this mutex. The render thread never does.
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static SpatialEQContext *contexts;
static SpatialEQFilter configuration[SpatialEQMaxFilters];
static uint32_t filterCount;
static double preampDB;
static bool requested;
static uint64_t generation = 1;

static bool validFilter(SpatialEQFilter f) {
    double a = pow(10, f.gain / 40);
    return f.type <= SpatialEQHighShelf && f.enabled <= 1 && isfinite(f.frequency) && f.frequency > 0 &&
        isfinite(f.gain) && isfinite(f.q) && f.q > 0 && isfinite(a) && a > 0;
}
bool SpatialEQMakeCoefficients(SpatialEQFilter f, double rate, SpatialEQCoefficients *out) {
    if (!out || !validFilter(f) || !isfinite(rate) || rate <= 0 || f.frequency >= rate / 2) return false;
    double a = pow(10, f.gain / 40), w = 2 * M_PI * f.frequency / rate;
    double c = cos(w), alpha = sin(w) / (2 * f.q), root = 2 * sqrt(a) * alpha;
    double a0, a1, a2, b0, b1, b2;
    if (f.type == SpatialEQPeak) {
        a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a;
        b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a;
    } else if (f.type == SpatialEQLowShelf) {
        a0 = (a + 1) + (a - 1) * c + root;
        a1 = -2 * ((a - 1) + (a + 1) * c);
        a2 = (a + 1) + (a - 1) * c - root;
        b0 = a * ((a + 1) - (a - 1) * c + root);
        b1 = 2 * a * ((a - 1) - (a + 1) * c);
        b2 = a * ((a + 1) - (a - 1) * c - root);
    } else {
        a0 = (a + 1) - (a - 1) * c + root;
        a1 = 2 * ((a - 1) - (a + 1) * c);
        a2 = (a + 1) - (a - 1) * c - root;
        b0 = a * ((a + 1) + (a - 1) * c + root);
        b1 = -2 * a * ((a - 1) + (a + 1) * c);
        b2 = a * ((a + 1) + (a - 1) * c - root);
    }
    SpatialEQCoefficients result = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    if (!isfinite(result.b0) || !isfinite(result.b1) || !isfinite(result.b2) ||
        !isfinite(result.a1) || !isfinite(result.a2) || fabs(result.a2) >= 1 ||
        1 + result.a1 + result.a2 <= 0 || 1 - result.a1 + result.a2 <= 0) return false;
    *out = result; return true;
}
double SpatialEQCoefficientResponse(SpatialEQCoefficients c, double rate, double frequency) {
    if (!isfinite(rate) || rate <= 0 || !isfinite(frequency) || frequency < 0 || frequency >= rate / 2) return NAN;
    double w = 2 * M_PI * frequency / rate;
    double nr = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w), ni = -c.b1 * sin(w) - c.b2 * sin(2 * w);
    double dr = 1 + c.a1 * cos(w) + c.a2 * cos(2 * w), di = -c.a1 * sin(w) - c.a2 * sin(2 * w);
    return 20 * log10(hypot(nr, ni) / hypot(dr, di));
}
static bool supported(AudioStreamBasicDescription f) {
    return f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(f.mFormatFlags & kAudioFormatFlagIsBigEndian) && f.mBitsPerChannel == 32 &&
        f.mChannelsPerFrame == 2 && isfinite(f.mSampleRate) && f.mSampleRate >= 1000 && f.mSampleRate <= 768000 &&
        f.mBytesPerFrame == ((f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8);
}
static Snapshot compile(AudioStreamBasicDescription format) {
    Snapshot s = {.generation = generation, .enabled = requested, .preamp = pow(10, preampDB / 20)};
    if (!supported(format)) { s.error = SpatialEQFormat; return s; }
    for (uint32_t i = 0; i < filterCount; i++) {
        if (!configuration[i].enabled) continue;
        if (configuration[i].frequency >= format.mSampleRate / 2) { s.error = SpatialEQFrequency; return s; }
        if (!SpatialEQMakeCoefficients(configuration[i], format.mSampleRate, &s.filters[s.count])) {
            s.error = SpatialEQCoefficientsInvalid; return s;
        }
        s.count++;
    }
    return s;
}
static void publish(SpatialEQContext *ctx) {
    unsigned current = atomic_load(&ctx->published), slot;
    // Writers may wait; render readers only perform bounded atomic operations.
    for (;;) {
        for (slot = 0; slot < 3; slot++)
            if (slot != current && atomic_load(&ctx->readers[slot]) == 0) break;
        if (slot < 3) break;
        sched_yield();
    }
    ctx->snapshots[slot] = compile(ctx->format);
    atomic_store(&ctx->published, slot);
}
static bool snapshot(SpatialEQContext *ctx, Snapshot *out) {
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        unsigned slot = atomic_load(&ctx->published);
        atomic_fetch_add(&ctx->readers[slot], 1);
        if (slot == atomic_load(&ctx->published)) {
            *out = ctx->snapshots[slot];
            atomic_fetch_sub(&ctx->readers[slot], 1); return true;
        }
        atomic_fetch_sub(&ctx->readers[slot], 1);
    }
    return false;
}
bool SpatialEQSetConfiguration(const SpatialEQFilter *filters, uint32_t count, double preamp, bool enabled) {
    double linear = pow(10, preamp / 20);
    if (count > SpatialEQMaxFilters || (count && !filters) || !isfinite(preamp) || !isfinite(linear) || linear <= 0) return false;
    for (uint32_t i = 0; i < count; i++) if (!validFilter(filters[i])) return false;
    pthread_mutex_lock(&control);
    if (count) memcpy(configuration, filters, count * sizeof(*filters));
    filterCount = count; preampDB = preamp; requested = enabled; generation++;
    for (SpatialEQContext *ctx = contexts; ctx; ctx = ctx->next) publish(ctx);
    pthread_mutex_unlock(&control); return true;
}
void SpatialEQSetEnabled(bool value) {
    pthread_mutex_lock(&control);
    if (requested != value) {
        requested = value; generation++;
        for (SpatialEQContext *ctx = contexts; ctx; ctx = ctx->next) publish(ctx);
    }
    pthread_mutex_unlock(&control);
}
void SpatialEQResetContext(SpatialEQContext *ctx) { if (ctx) atomic_fetch_add(&ctx->reset, 1); }
void SpatialEQReset(void) {
    pthread_mutex_lock(&control);
    for (SpatialEQContext *ctx = contexts; ctx; ctx = ctx->next) SpatialEQResetContext(ctx);
    pthread_mutex_unlock(&control);
}
static void prepare(SpatialEQContext *ctx, AudioStreamBasicDescription format, uint32_t maximum) {
    atomic_store(&ctx->suspended, true);
    while (atomic_load(&ctx->users)) sched_yield();
    free(ctx->cache); ctx->cache = NULL;
    ctx->format = format; ctx->capacity = 0;
    if (supported(format) && maximum > 0 && maximum <= 65536) {
        ctx->cache = calloc((size_t)maximum * 2, sizeof(float));
        if (ctx->cache) ctx->capacity = maximum;
    }
    ctx->fadeFrames = supported(format) ? (uint32_t)ceil(format.mSampleRate * .020) : 960;
    memset(&ctx->current, 0, sizeof(ctx->current)); memset(&ctx->target, 0, sizeof(ctx->target));
    ctx->cacheValid = ctx->transitioning = false; ctx->fadePosition = 0;
    publish(ctx); atomic_store(&ctx->renderedGeneration, 0);
    atomic_store(&ctx->error, supported(format) && !ctx->cache ? SpatialEQBuffer : SpatialEQOK);
    atomic_store(&ctx->suspended, false);
}
SpatialEQContext *SpatialEQCreateForFormat(AudioStreamBasicDescription format, uint32_t maximum) {
    SpatialEQContext *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    pthread_mutex_lock(&control);
    prepare(ctx, format, maximum); ctx->next = contexts; contexts = ctx;
    pthread_mutex_unlock(&control); return ctx;
}
void SpatialEQRefresh(SpatialEQContext *ctx, AudioUnit unit) {
    if (!ctx) return;
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format), maximum = 0;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size)) memset(&format, 0, sizeof(format));
    size = sizeof(maximum);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &size)) maximum = 4096;
    pthread_mutex_lock(&control); prepare(ctx, format, maximum); pthread_mutex_unlock(&control);
}
SpatialEQContext *SpatialEQCreate(AudioUnit unit) {
    SpatialEQContext *ctx = SpatialEQCreateForFormat((AudioStreamBasicDescription){0}, 0);
    SpatialEQRefresh(ctx, unit); return ctx;
}
void SpatialEQDestroy(SpatialEQContext *ctx) {
    if (!ctx) return;
    pthread_mutex_lock(&control);
    atomic_store(&ctx->suspended, true);
    while (atomic_load(&ctx->users)) sched_yield();
    SpatialEQContext **link = &contexts;
    while (*link && *link != ctx) link = &(*link)->next;
    if (*link) *link = ctx->next;
    free(ctx->cache); free(ctx);
    pthread_mutex_unlock(&control);
}
static double processBank(Bank *bank, unsigned channel, double x) {
    if (!bank->config.enabled || bank->config.error) return x;
    x *= bank->config.preamp;
    for (unsigned i = 0; i < bank->config.count; i++) {
        SpatialEQCoefficients c = bank->config.filters[i];
        double *z = bank->history[channel][i], y = c.b0 * x + z[0];
        z[0] = c.b1 * x - c.a1 * y + z[1]; z[1] = c.b2 * x - c.a2 * y;
        // Flush only inaudibly small state, including long silence tails.
        if (fabs(z[0]) < 1e-30) z[0] = 0;
        if (fabs(z[1]) < 1e-30) z[1] = 0;
        x = y;
    }
    return x;
}
static void clearHistory(SpatialEQContext *ctx) {
    memset(ctx->current.history, 0, sizeof(ctx->current.history));
    memset(ctx->target.history, 0, sizeof(ctx->target.history)); ctx->cacheValid = false;
}
void SpatialEQProcess(SpatialEQContext *ctx, AudioUnitRenderActionFlags *flags,
                      const AudioTimeStamp *time, uint32_t frames, AudioBufferList *data) {
    if (!ctx || !flags || atomic_load(&ctx->suspended)) return;
    atomic_fetch_add(&ctx->users, 1);
    if (atomic_load(&ctx->suspended)) { atomic_fetch_sub(&ctx->users, 1); return; }
    if (*flags & kAudioUnitRenderAction_PostRenderError) {
        clearHistory(ctx); atomic_store(&ctx->error, SpatialEQRenderError); goto done;
    }
    Snapshot latest;
    if (!snapshot(ctx, &latest)) goto done;
    if (latest.error || !supported(ctx->format)) {
        clearHistory(ctx); atomic_store(&ctx->error, latest.error ?: SpatialEQFormat); goto done;
    }
    float *channels[2] = {0}; uint32_t stride[2] = {0};
    if (!data || !frames || !ctx->cache || frames > ctx->capacity) { atomic_store(&ctx->error, SpatialEQBuffer); goto done; }
    unsigned channel = 0;
    for (unsigned b = 0; b < data->mNumberBuffers; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels ||
            buffer->mDataByteSize < (uint64_t)frames * buffer->mNumberChannels * sizeof(float) ||
            channel + buffer->mNumberChannels > 2) { atomic_store(&ctx->error, SpatialEQBuffer); goto done; }
        for (unsigned c = 0; c < buffer->mNumberChannels; c++, channel++) {
            channels[channel] = (float *)buffer->mData + c; stride[channel] = buffer->mNumberChannels;
        }
    }
    if (channel != 2) { atomic_store(&ctx->error, SpatialEQBuffer); goto done; }
    uint64_t reset = atomic_load(&ctx->reset);
    if (reset != ctx->observedReset) { clearHistory(ctx); ctx->observedReset = reset; }
    bool timestamp = time && (time->mFlags & kAudioTimeStampSampleTimeValid);
    if (timestamp && ctx->cacheValid && time->mSampleTime == ctx->lastSampleTime && frames == ctx->lastFrames) {
        for (unsigned c = 0; c < 2; c++) for (unsigned f = 0; f < frames; f++)
            channels[c][f * stride[c]] = ctx->cache[f * 2 + c];
        if (ctx->cacheSilent) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        goto done;
    }
    if (timestamp && ctx->cacheValid && fabs(time->mSampleTime - ctx->lastSampleTime - ctx->lastFrames) > .5) clearHistory(ctx);
    if (!ctx->transitioning && latest.generation != ctx->current.config.generation) {
        memset(&ctx->target, 0, sizeof(ctx->target)); ctx->target.config = latest;
        ctx->transitioning = true; ctx->fadePosition = 0;
    }
    bool inputSilent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0, outputSilent = true, failed = false;
    for (unsigned f = 0; f < frames; f++) {
        double weight = ctx->transitioning ? (double)(ctx->fadePosition + 1) / ctx->fadeFrames : 0;
        for (unsigned c = 0; c < 2; c++) {
            double input = inputSilent ? 0 : channels[c][f * stride[c]];
            double y = processBank(&ctx->current, c, input);
            if (ctx->transitioning) y += (processBank(&ctx->target, c, input) - y) * weight;
            if (!isfinite(y) || fabs(y) > FLT_MAX) { y = isfinite(input) ? input : 0; failed = true; }
            float value = (float)y;
            channels[c][f * stride[c]] = value; ctx->cache[f * 2 + c] = value;
            if (value != 0) outputSilent = false;
        }
        if (ctx->transitioning && ++ctx->fadePosition >= ctx->fadeFrames) {
            ctx->current = ctx->target; ctx->transitioning = false;
        }
    }
    if (failed) { clearHistory(ctx); atomic_store(&ctx->error, SpatialEQNonFinite); }
    else {
        atomic_store(&ctx->error, SpatialEQOK); ctx->cacheValid = timestamp;
        ctx->cacheSilent = outputSilent; ctx->lastFrames = frames;
        if (timestamp) ctx->lastSampleTime = time->mSampleTime;
        atomic_store(&ctx->renderedGeneration, ctx->transitioning ? ctx->target.config.generation : ctx->current.config.generation);
        atomic_store(&ctx->lastRender, mach_absolute_time());
        atomic_fetch_add(&ctx->buffers, 1); atomic_fetch_add(&ctx->frames, frames);
        uint32_t minimum = atomic_load(&ctx->minFrames);
        if (!minimum || frames < minimum) atomic_store(&ctx->minFrames, frames);
        if (frames > atomic_load(&ctx->maxFrames)) atomic_store(&ctx->maxFrames, frames);
    }
    if (outputSilent) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
done:
    atomic_fetch_sub(&ctx->users, 1);
}
SpatialEQStatus SpatialEQGetStatus(void) {
    SpatialEQStatus result = {0};
    mach_timebase_info_data_t scale; mach_timebase_info(&scale);
    uint64_t now = mach_absolute_time(), newest = 0;
    pthread_mutex_lock(&control);
    result.enabled = requested; result.generation = generation;
    for (SpatialEQContext *ctx = contexts; ctx; ctx = ctx->next) {
        result.mixers++;
        uint64_t tick = atomic_load(&ctx->lastRender);
        if (tick >= newest) { newest = tick; result.sampleRate = ctx->format.mSampleRate; result.lastError = atomic_load(&ctx->error); }
        double age = now >= tick ? (double)(now - tick) * scale.numer / scale.denom / 1e9 : 0;
        if (requested && tick && age < .5 && atomic_load(&ctx->renderedGeneration) == generation && !atomic_load(&ctx->error)) result.activeMixers++;
        result.processedBuffers += atomic_load(&ctx->buffers); result.processedFrames += atomic_load(&ctx->frames);
        uint32_t minimum = atomic_load(&ctx->minFrames), maximum = atomic_load(&ctx->maxFrames);
        if (minimum && (!result.minFrames || minimum < result.minFrames)) result.minFrames = minimum;
        if (maximum > result.maxFrames) result.maxFrames = maximum;
    }
    pthread_mutex_unlock(&control); return result;
}
