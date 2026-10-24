#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#include "eq_probe.h"
#include "../Sources/SpatialShim/SpatialShim.h"
#include <math.h>

static void pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static NSArray *devices(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID ids[128]; UInt32 size = sizeof(ids);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids)) return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (unsigned i = 0; i < size / sizeof(ids[0]); i++) {
        a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeOutput;
        UInt32 streams = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &a, 0, NULL, &streams) || !streams) continue;
        a.mSelector = kAudioDevicePropertyDeviceUID; a.mScope = kAudioObjectPropertyScopeGlobal;
        CFStringRef uid = NULL; UInt32 bytes = sizeof(uid);
        if (AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &bytes, &uid) || !uid) continue;
        [items addObject:@{@"id":@(ids[i]), @"uid":(__bridge NSString *)uid}]; CFRelease(uid);
    }
    return items;
}
static NSDictionary *spectrumJSON(const EQProbeSpectrum *s) {
    NSMutableArray *rms = [NSMutableArray array], *tones = [NSMutableArray array];
    for (unsigned c = 0; c < 2; c++) {
        [rms addObject:@(s->frames ? sqrt(s->energy[c] / s->frames) : 0)];
        NSMutableArray *amplitudes = [NSMutableArray array];
        for (unsigned k = 0; k < 3; k++)
            [amplitudes addObject:@(s->frames ? 2 * hypot(s->real[c][k], s->imaginary[c][k]) / s->frames : 0)];
        [tones addObject:amplitudes];
    }
    return @{@"frames":@(s->frames), @"rms":rms, @"toneAmplitudes":tones};
}
static NSArray *probeJSON(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (unsigned i = 0; i < EQProbeCount(); i++) {
        const EQProbeRecord *r = EQProbeGet(i);
        NSMutableArray *phases = [NSMutableArray array], *channels = [NSMutableArray array];
        for (unsigned p = 0; p < EQProbePhases; p++)
            [phases addObject:@{@"before":spectrumJSON(&r->spectra[p][0]), @"after":spectrumJSON(&r->spectra[p][1])}];
        for (unsigned b = 0; b < MIN(r->buffers, 8); b++) [channels addObject:@(r->channels[b])];
        [all addObject:@{@"kind":@(r->kind), @"sampleRate":@(r->format.mSampleRate),
            @"formatID":@(r->format.mFormatID), @"formatFlags":@(r->format.mFormatFlags),
            @"bits":@(r->format.mBitsPerChannel), @"channels":@(r->format.mChannelsPerFrame),
            @"bufferChannels":channels, @"formatError":@(r->formatError), @"notifyError":@(r->notifyError),
            @"callbacks":@(r->callbacks), @"errors":@(r->errors), @"unsupported":@(r->unsupported),
            @"minFrames":@(r->minFrames), @"maxFrames":@(r->maxFrames),
            @"duplicateTimes":@(r->duplicateTimes), @"renderReturns":@(r->returned),
            @"matchingReturns":@(r->matchingReturns), @"phases":phases}];
    }
    return all;
}
typedef struct { EQProbeRecord *record; uint64_t calls; OSStatus error; } TapState;
static void tapInit(MTAudioProcessingTapRef tap, void *client, void **storage) { (void)tap; *storage = client; }
static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount frames, const AudioStreamBasicDescription *format) {
    (void)frames;
    TapState *s = MTAudioProcessingTapGetStorage(tap);
    s->record = EQProbeNew("avplayer-tap", NULL, format);
}
static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                       AudioBufferList *buffers, CMItemCount *outFrames, MTAudioProcessingTapFlags *outFlags) {
    (void)flags;
    TapState *s = MTAudioProcessingTapGetStorage(tap);
    s->calls++;
    OSStatus result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, outFlags, NULL, outFrames);
    if (result) { s->error = result; *outFrames = 0; return; }
    EQProbeProcess(s->record, buffers, (UInt32)*outFrames, true);
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSArray *outputs = devices();
    if (argc == 2 && !strcmp(argv[1], "--devices")) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:outputs options:NSJSONWritingPrettyPrinted error:NULL];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); return 0;
    }
    if (argc != 7) { fprintf(stderr, "usage: eq-probe MEDIA DEVICE_UID on|off notify|tap-pre|tap-post|tap-mix SEEK_SECONDS REPORT.json\n"); return 2; }
    NSString *uid = @(argv[2]); AudioObjectID device = 0;
    for (NSDictionary *output in outputs) if ([output[@"uid"] isEqual:uid]) device = [output[@"id"] unsignedIntValue];
    if (!device) { fprintf(stderr, "Requested output device unavailable\n"); return 2; }
    bool production = !strncmp(argv[4], "production", 10);
    bool spatial = !strcmp(argv[3], "on"), tapping = strcmp(argv[4], "notify") != 0 && !production;
    EQProbeUseProduction(production);
    if (!strcmp(argv[4], "production-sony")) {
        NSString *path = NSProcessInfo.processInfo.environment[@"SPATIALEQ_PROBE_PRESET"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *values = json[@"filters"];
        if (!values || values.count > SpatialEQMaxFilters) { fprintf(stderr, "Missing normalized Sony preset\n"); return 2; }
        SpatialEQFilter filters[SpatialEQMaxFilters];
        for (unsigned i = 0; i < values.count; i++) {
            NSDictionary *f = values[i]; NSString *kind = f[@"type"];
            filters[i] = (SpatialEQFilter){[kind isEqual:@"PK"] ? SpatialEQPeak : [kind isEqual:@"LSC"] ? SpatialEQLowShelf : SpatialEQHighShelf,
                [f[@"enabled"] boolValue], [f[@"frequency"] doubleValue], [f[@"gain"] doubleValue], [f[@"q"] doubleValue]};
        }
        EQProbeProductionPreset(filters, (uint32_t)values.count, [json[@"preamp"] doubleValue]);
    }
    SpatialShimSetConfiguration(device, spatial);
    SpatialHeadPosePublish(0, 0, 0, 1); SpatialHeadPoseSetEnabled(spatial);
    EQProbeUseTap(tapping); EQProbeControl(0, -1);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.allowedAudioSpatializationFormats = spatial ? AVAudioSpatializationFormatMonoStereoAndMultichannel : 0;
    TapState tapState = {0}; MTAudioProcessingTapRef tap = NULL;
    if (tapping) {
        __block NSArray<AVAssetTrack *> *tracks = nil; __block BOOL loaded = NO;
        [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *value, NSError *error) {
            (void)error;
            dispatch_async(dispatch_get_main_queue(), ^{ tracks = value; loaded = YES; });
        }];
        for (unsigned n = 0; !loaded && n < 1000; n++) pump(.01);
        if (!loaded || !tracks.count) { fprintf(stderr, "Could not load audio track\n"); return 2; }
        MTAudioProcessingTapCallbacks callbacks = {kMTAudioProcessingTapCallbacksVersion_0, &tapState,
            tapInit, NULL, tapPrepare, NULL, tapProcess};
        MTAudioProcessingTapCreationFlags flags = !strcmp(argv[4], "tap-pre") ?
            kMTAudioProcessingTapCreationFlag_PreEffects : kMTAudioProcessingTapCreationFlag_PostEffects;
        OSStatus result;
        AVMutableAudioMixInputParameters *parameters;
        if (!strcmp(argv[4], "tap-mix")) {
            AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM,
                kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
            CMAudioFormatDescriptionRef description = NULL;
            CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description);
            result = MTAudioProcessingTapCreateWithPreferredFormat(NULL, &callbacks, flags, description, &tap);
            if (description) CFRelease(description);
            parameters = [AVMutableAudioMixInputParameters audioMixInputParameters];
            parameters.trackID = AVAudioMixInputParametersTrackMixID;
        } else {
            result = MTAudioProcessingTapCreate(NULL, &callbacks, flags, &tap);
            parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
        }
        if (result) { fprintf(stderr, "Tap create failed: %d\n", (int)result); return 2; }
        parameters.audioTapProcessor = tap;
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix]; mix.inputParameters = @[parameters]; item.audioMix = mix;
    }
    AVPlayer *player = [AVPlayer new];
    player.audioOutputDeviceUniqueID = uid; player.volume = .02;
    player.automaticallyWaitsToMinimizeStalling = YES; [player replaceCurrentItemWithPlayerItem:item];
    for (unsigned n = 0; item.status == AVPlayerItemStatusUnknown && n < 1000; n++) pump(.01);
    BOOL ready = item.status == AVPlayerItemStatusReadyToPlay;
    double seek = atof(argv[5]); __block BOOL sought = seek <= 0;
    if (ready && seek > 0) {
        [player seekToTime:CMTimeMakeWithSeconds(seek, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
            completionHandler:^(BOOL finished) { sought = finished; }];
        for (unsigned n = 0; !sought && n < 500; n++) pump(.01);
    }
    double elapsed = 0;
    if (ready && sought) {
        [player play]; pump(.5);
        for (int phase = 0; phase < EQProbePhases; phase++) {
            int mode = phase == 0 ? 0 : phase == 1 ? 1 : 2;
            EQProbeControl(mode, -1);
            if (phase == 3) SpatialHeadPosePublish(0, 0, .38268343f, .92387953f);
            pump(.5); EQProbeControl(mode, phase); pump(.8); EQProbeControl(mode, -1);
        }
        elapsed = CMTimeGetSeconds(player.currentTime);
    }
    NSString *error = item.error.description ?: @"";
    SpatialHeadPoseStatus pose = SpatialHeadPoseGetStatus();
    SpatialEQStatus eq = SpatialEQGetStatus();
    [player pause]; EQProbeControl(0, -1); [player replaceCurrentItemWithPlayerItem:nil];
    player = nil; item = nil; if (tap) CFRelease(tap); pump(.4);
    EQProbeFreeze();
    NSDictionary *report = @{@"media":@(argv[1]), @"device":uid, @"spatial":@(spatial), @"method":@(argv[4]),
        @"ready":@(ready), @"sought":@(sought), @"position":@(elapsed), @"error":error,
        @"tapCalls":@(tapState.calls), @"tapError":@(tapState.error), @"poseApplied":@(pose.applied),
        @"poseErrors":@(pose.failures), @"mixers":@(pose.mixers),
        @"productionEQ":@{@"active":@(eq.activeMixers), @"error":@(eq.lastError), @"buffers":@(eq.processedBuffers),
            @"minFrames":@(eq.minFrames), @"maxFrames":@(eq.maxFrames)}, @"records":probeJSON()};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (!json || ![json writeToFile:@(argv[6]) atomically:YES]) return 3;
    printf("%s %s ready=%d position=%.3f mixers=%u records=%u error=%s\n", argv[3], argv[4], ready, elapsed, pose.mixers, EQProbeCount(), error.UTF8String);
    return ready && sought ? 0 : 1;
} }
