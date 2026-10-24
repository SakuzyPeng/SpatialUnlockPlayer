#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "route_probe.h"
#include "../Sources/SpatialShim/SpatialShim.h"
#include <math.h>

static void pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static NSString *stringProperty(AudioObjectID device, UInt32 selector) {
    AudioObjectPropertyAddress a = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef value = NULL; UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &value) || !value) return @"";
    return CFBridgingRelease(value);
}
static NSDictionary *uintProperty(AudioObjectID device, UInt32 selector) {
    UInt32 value = 0;
    OSStatus error = SpatialShimNativeReadUInt32(device, selector, &value);
    return @{@"value":@(value), @"error":@(error)};
}
static NSArray *devices(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID ids[128]; UInt32 size = sizeof(ids);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids)) return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (unsigned i = 0; i < size / sizeof(ids[0]); i++) {
        a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeOutput;
        UInt32 bytes = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &a, 0, NULL, &bytes) || !bytes) continue;
        a.mSelector = kAudioDevicePropertyNominalSampleRate; a.mScope = kAudioObjectPropertyScopeGlobal;
        Float64 rate = 0; bytes = sizeof(rate);
        OSStatus rateError = AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &bytes, &rate);
        [items addObject:@{@"id":@(ids[i]), @"uid":stringProperty(ids[i], kAudioDevicePropertyDeviceUID),
            @"name":stringProperty(ids[i], kAudioObjectPropertyName), @"sampleRate":@(rate), @"sampleRateError":@(rateError),
            @"transport":uintProperty(ids[i], kAudioDevicePropertyTransportType),
            @"spen":uintProperty(ids[i], 'spen'), @"spmd":uintProperty(ids[i], 'spmd'),
            @"hasSpen":@(SpatialShimNativeHasProperty(ids[i], 'spen'))}];
    }
    return items;
}
static NSNumber *defaultOutput(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 value = 0, size = sizeof(value);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &value);
    return @(value);
}
static BOOL writeJSON(id object, NSString *path) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    return json && [json writeToFile:path atomically:YES];
}
static NSArray *saveRecords(NSString *prefix) {
    NSMutableArray *items = [NSMutableArray array];
    NSArray *names = @[@"outputType", @"unitHeadTracking", @"personalizedMode", @"personalizedActive", @"internalReverb"];
    for (unsigned i = 0; i < RouteCount(); i++) {
        const RouteRecord *r = RouteGet(i);
        if (!r->callbacks) continue;
        NSString *path = [prefix stringByAppendingFormat:@"-%u-%s.f32", i, r->kind];
        BOOL saved = [[NSData dataWithBytesNoCopy:r->samples length:r->frames * 2 * sizeof(float) freeWhenDone:NO] writeToFile:path atomically:YES];
        NSMutableArray *blocks = [NSMutableArray array];
        for (unsigned j = 0; j < r->blockCount; j++) {
            RouteBlock b = r->blocks[j];
            [blocks addObject:@[@(b.offset), @(b.frames), @(b.sampleTime), @(b.hostTime), @(b.flags), @(b.timeFlags)]];
        }
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        if (r->unit && !r->unitTrace) for (unsigned j = 0; j < names.count; j++)
            properties[names[j]] = @{@"value":@(r->propertyValues[j]), @"error":@(r->propertyErrors[j])};
        NSMutableArray *parameters = [NSMutableArray array];
        for (unsigned j = 0; j < r->parameterCount; j++)
            [parameters addObject:@{@"id":@(r->parameters[j].id), @"value":@(r->parameters[j].value), @"error":@(r->parameters[j].error),
                @"name":@(r->parameters[j].name), @"unit":@(r->parameters[j].unit)}];
        [items addObject:@{@"index":@(i), @"kind":@(r->kind), @"deviceID":@(r->device),
            @"sampleRate":@(r->format.mSampleRate), @"channels":@(r->format.mChannelsPerFrame),
            @"bits":@(r->format.mBitsPerChannel), @"formatID":@(r->format.mFormatID), @"formatFlags":@(r->format.mFormatFlags),
            @"formatError":@(r->formatError), @"notifyError":@(r->notifyError),
            @"frames":@(r->frames), @"callbacks":@(r->callbacks), @"errors":@(r->errors),
            @"unsupported":@(r->unsupported), @"overflow":@(r->overflow), @"duplicates":@(r->duplicates), @"gaps":@(r->gaps),
            @"properties":properties, @"quaternion":@[@(r->quaternion[0]), @(r->quaternion[1]), @(r->quaternion[2]), @(r->quaternion[3])],
            @"quaternionError":@(r->quaternionError), @"hrtfOverrideError":@(r->hrtfOverrideError), @"pcm":path, @"saved":@(saved),
            @"unitTrace":@(r->unitTrace), @"componentType":@(r->component.componentType),
            @"componentSubType":@(r->component.componentSubType),
            @"componentName":@(r->componentName),
            @"gainOverrides":@(r->gainOverrides), @"lastRequestedGain":@(r->lastRequestedGain),
            @"bypass":@{@"value":@(r->bypass), @"error":@(r->bypassError)}, @"parameters":parameters,
            @"blockColumns":@[@"offset", @"frames", @"sampleTime", @"hostTime", @"renderFlags", @"timeFlags"], @"blocks":blocks}];
    }
    return items;
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSArray *outputs = devices();
    if (argc == 2 && !strcmp(argv[1], "--devices")) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:outputs options:NSJSONWritingPrettyPrinted error:NULL];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); return 0;
    }
    if (argc != 8) {
        fprintf(stderr, "usage: route-probe MEDIA DEVICE_UID native|shim|off SEEK_SECONDS DURATION_SECONDS YAW_DEGREES OUTPUT_PREFIX\n"); return 2;
    }
    NSDictionary *device = nil;
    for (NSDictionary *d in outputs) if ([d[@"uid"] isEqual:@(argv[2])]) device = d;
    if (!device) { fprintf(stderr, "Requested device is unavailable\n"); return 2; }
    bool shim = !strcmp(argv[3], "shim"), spatial = strcmp(argv[3], "off") != 0;
    if (spatial && !shim && ![device[@"hasSpen"] boolValue]) { fprintf(stderr, "Native route lacks spatial capability\n"); return 2; }
    NSNumber *defaultBefore = defaultOutput();
    NSString *hrtf = NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_HRTF"];
    int hrtfOverride = hrtf ? hrtf.intValue : -1;
    BOOL production = [NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_PRODUCTION"] boolValue];
    RouteSetHRTFOverride(production ? -1 : hrtfOverride);
    BOOL traceUnits = [NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_TRACE_UNITS"] boolValue];
    RouteSetUnitTracing(traceUnits);
    NSString *headroom = NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_HEADROOM_DB"];
    if (headroom) RouteSetHeadroomOverride(headroom.floatValue);
    NSString *productionHeadroom = NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_PRODUCTION_HEADROOM_DB"];
    if (production) SpatialRenderConfigure((SpatialRenderConfiguration){1, [device[@"id"] unsignedIntValue], spatial,
        hrtfOverride, productionHeadroom != nil, productionHeadroom.floatValue});
    SpatialShimSetConfiguration([device[@"id"] unsignedIntValue], shim);
    double yaw = atof(argv[6]) * M_PI / 180;
    SpatialHeadPosePublish(0, 0, sin(yaw / 2), cos(yaw / 2));
    SpatialHeadPoseSetEnabled(spatial); SpatialEQSetEnabled(false);
    BOOL probeEQ = [NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_EQ"] boolValue];
    if (probeEQ) {
        SpatialEQFilter filter = {SpatialEQPeak, 1, 1800, 3, 1};
        if (!SpatialEQSetConfiguration(&filter, 1, -3, true)) return 2;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.allowedAudioSpatializationFormats = spatial ? AVAudioSpatializationFormatMonoStereoAndMultichannel : 0;
    NSString *volumeSetting = NSProcessInfo.processInfo.environment[@"ROUTE_PROBE_VOLUME"];
    float volume = volumeSetting ? volumeSetting.floatValue : .02f;
    if (!isfinite(volume) || volume < 0 || volume > 1) return 2;
    AVPlayer *player = [AVPlayer new];
    player.audioOutputDeviceUniqueID = device[@"uid"]; player.volume = volume;
    player.automaticallyWaitsToMinimizeStalling = YES;
    [player replaceCurrentItemWithPlayerItem:item];
    for (unsigned n = 0; item.status == AVPlayerItemStatusUnknown && n < 1000; n++) pump(.01);
    BOOL ready = item.status == AVPlayerItemStatusReadyToPlay;
    double seek = atof(argv[4]), duration = atof(argv[5]); __block BOOL sought = seek <= 0;
    if (ready && seek > 0) {
        [player seekToTime:CMTimeMakeWithSeconds(seek, 48000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
            completionHandler:^(BOOL finished) { sought = finished; }];
        for (unsigned n = 0; !sought && n < 500; n++) pump(.01);
    }
    double position = 0;
    if (ready && sought) {
        [player play];
        for (unsigned n = 0; n < (duration + 5) * 100; n++) {
            pump(.01); position = CMTimeGetSeconds(player.currentTime);
            if (position >= seek + duration || item.status == AVPlayerItemStatusFailed) break;
        }
    }
    NSString *error = item.error.description ?: @"";
    RouteFreeze(); RouteSnapshotProperties(); SpatialRenderRefreshStatus();
    SpatialRenderStatus render = SpatialRenderGetStatus();
    SpatialRenderNodeInfo nodeInfo[128]; unsigned nodeCount = SpatialRenderCopyNodes(nodeInfo, 128);
    NSMutableArray *nodeJSON = [NSMutableArray array];
    for (unsigned i = 0; i < nodeCount; i++) {
        SpatialRenderNodeInfo n = nodeInfo[i];
        [nodeJSON addObject:@{@"unit":@(n.unit), @"input":@(n.input), @"generation":@(n.generation),
            @"type":@(n.type), @"subtype":@(n.subtype), @"initialized":@(n.initialized),
            @"headphones":@(n.headphones), @"started":@(n.started)}];
    }
    SpatialHeadPoseStatus pose = SpatialHeadPoseGetStatus();
    SpatialEQStatus eq = SpatialEQGetStatus();
    SpatialShimStatus status = SpatialShimGetStatus();
    [player pause]; [player replaceCurrentItemWithPlayerItem:nil]; player = nil; item = nil; pump(.2);
    NSArray *records = saveRecords(@(argv[7]));
    NSDictionary *report = @{@"media":@(argv[1]), @"device":device, @"route":@(argv[3]),
        @"seek":@(seek), @"duration":@(duration), @"position":@(position), @"yaw":@(atof(argv[6])),
        @"volume":@(volume), @"eqEnabled":@NO, @"hrtfOverride":@(hrtfOverride), @"traceUnits":@(traceUnits),
        @"headroomOverrideDB":headroom ?: (id)NSNull.null, @"ready":@(ready), @"sought":@(sought), @"error":error,
        @"systemVersion":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"defaultBefore":defaultBefore, @"defaultAfter":defaultOutput(),
        @"poseApplied":@(pose.applied), @"poseErrors":@(pose.failures),
        @"shimEnabled":@(status.enabled), @"overriddenQueries":@(status.overriddenQueries),
        @"queueSpatial":@(status.lastSpatialRequest), @"queueLayout":@(status.lastChannelLayout),
        @"probeEQ":@{@"enabled":@(probeEQ), @"active":@(eq.activeMixers), @"error":@(eq.lastError),
            @"buffers":@(eq.processedBuffers), @"minFrames":@(eq.minFrames), @"maxFrames":@(eq.maxFrames)},
        @"productionRender":@{@"enabled":@(production), @"state":@(render.headroomState), @"pairs":@(render.pairCount),
            @"error":@(render.headroomError), @"rollbackFailed":@(render.rollbackFailed),
            @"preGain":@(render.actualPreGainDB), @"postGain":@(render.actualPostGainDB),
            @"actualHRTF":@(render.actualHRTF), @"hrtfError":@(render.hrtfError), @"nodes":nodeJSON},
        @"records":records};
    if (!writeJSON(report, [@(argv[7]) stringByAppendingString:@".json"])) return 3;
    printf("%s: ready=%d position=%.3f queueSpatial=%u poseErrors=%llu records=%lu\n", argv[3], ready, position,
        status.lastSpatialRequest, (unsigned long long)pose.failures, (unsigned long)records.count);
    return ready && sought && error.length == 0 ? 0 : 1;
} }
