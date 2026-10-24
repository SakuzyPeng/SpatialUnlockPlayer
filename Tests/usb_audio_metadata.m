#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static NSDictionary *format(AudioStreamBasicDescription f) {
    return @{@"sampleRate":@(f.mSampleRate), @"formatID":@(f.mFormatID),
        @"flags":@(f.mFormatFlags), @"channels":@(f.mChannelsPerFrame),
        @"bits":@(f.mBitsPerChannel), @"bytesPerFrame":@(f.mBytesPerFrame)};
}
static NSArray *audioDevices(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, 0};
    AudioObjectID ids[128]; UInt32 size = sizeof(ids);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids)) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned i = 0; i < size / sizeof(ids[0]); i++) {
        a = (AudioObjectPropertyAddress){kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0};
        AudioStreamID streams[32]; UInt32 bytes = sizeof(streams);
        if (AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &bytes, streams) || !bytes) continue;
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@(ids[i]) forKey:@"id"];
        for (unsigned k = 0; k < 2; k++) {
            CFStringRef v = NULL; UInt32 n = sizeof(v);
            a = (AudioObjectPropertyAddress){k ? kAudioDevicePropertyDeviceUID : kAudioObjectPropertyName,
                kAudioObjectPropertyScopeGlobal, 0};
            if (!AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &n, &v) && v)
                d[k ? @"uid" : @"name"] = CFBridgingRelease(v);
        }
        NSMutableArray *volumes = [NSMutableArray array];
        for (unsigned channel = 0; channel < 3; channel++) {
            Float32 scalar = 0, db = 0; UInt32 mute = 0, n = sizeof(scalar);
            a = (AudioObjectPropertyAddress){kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, channel};
            OSStatus se = AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &n, &scalar);
            a.mSelector = kAudioDevicePropertyVolumeDecibels; n = sizeof(db);
            OSStatus de = AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &n, &db);
            a.mSelector = kAudioDevicePropertyMute; n = sizeof(mute);
            OSStatus me = AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &n, &mute);
            [volumes addObject:@{@"channel":@(channel), @"scalar":@(scalar), @"scalarError":@(se),
                @"decibels":isfinite(db) ? @(db) : (id)NSNull.null, @"decibelsError":@(de),
                @"mute":@(mute), @"muteError":@(me)}];
        }
        d[@"volumes"] = volumes;
        NSMutableArray *formats = [NSMutableArray array];
        for (unsigned j = 0; j < bytes / sizeof(streams[0]); j++) {
            NSMutableDictionary *f = [NSMutableDictionary dictionaryWithObject:@(streams[j]) forKey:@"stream"];
            for (unsigned k = 0; k < 2; k++) {
                AudioStreamBasicDescription v = {0}; UInt32 n = sizeof(v);
                a = (AudioObjectPropertyAddress){k ? kAudioStreamPropertyPhysicalFormat : kAudioStreamPropertyVirtualFormat,
                    kAudioObjectPropertyScopeGlobal, 0};
                OSStatus error = AudioObjectGetPropertyData(streams[j], &a, 0, NULL, &n, &v);
                f[k ? @"physical" : @"virtual"] = @{@"error":@(error), @"format":format(v)};
            }
            AudioStreamRangedDescription ranges[128]; UInt32 n = sizeof(ranges);
            a.mSelector = kAudioStreamPropertyAvailablePhysicalFormats;
            OSStatus error = AudioObjectGetPropertyData(streams[j], &a, 0, NULL, &n, ranges);
            NSMutableArray *available = [NSMutableArray array];
            if (!error) for (unsigned k = 0; k < n / sizeof(ranges[0]); k++)
                [available addObject:@{@"format":format(ranges[k].mFormat),
                    @"minRate":@(ranges[k].mSampleRateRange.mMinimum), @"maxRate":@(ranges[k].mSampleRateRange.mMaximum)}];
            f[@"availablePhysical"] = available;
            [formats addObject:f];
        }
        d[@"streams"] = formats; [out addObject:d];
    }
    return out;
}
static NSArray *usbDevices(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)) return @[];
    NSMutableArray *out = [NSMutableArray array]; io_service_t service;
    while ((service = IOIteratorNext(it))) {
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)) { IOObjectRelease(service); continue; }
        NSDictionary *p = CFBridgingRelease(properties);
        NSString *name = p[@"USB Product Name"] ?: @"";
        if (![name containsString:@"AirPods"] && ![name containsString:@"FIIO"]) { IOObjectRelease(service); continue; }
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"USB Product Name", @"locationID", @"USB Address", @"idVendor", @"idProduct", @"UsbLinkSpeed"])
            if (p[key]) d[key] = p[key];
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOReturn error = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score);
        IOUSBDeviceInterface **device = NULL;
        if (!error && plugin) {
            error = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
            (*plugin)->Release(plugin);
        }
        if (!error && device) {
            IOUSBConfigurationDescriptorPtr config = NULL;
            error = (*device)->GetConfigurationDescriptorPtr(device, 0, &config);
            if (!error && config) {
                const uint8_t *b = (const uint8_t *)config;
                unsigned length = b[2] | (b[3] << 8); NSMutableString *hex = [NSMutableString string];
                for (unsigned j = 0; j < length; j++) [hex appendFormat:@"%02x", b[j]];
                d[@"configurationDescriptorHex"] = hex;
            }
            (*device)->Release(device);
        }
        d[@"descriptorError"] = @(error); [out addObject:d]; IOObjectRelease(service);
    }
    IOObjectRelease(it); return out;
}
static OSStatus change(NSString *uid, NSString *operation, double value) {
    NSDictionary *target = nil;
    for (NSDictionary *d in audioDevices()) if ([d[@"uid"] isEqual:uid]) target = d;
    if (!target) return kAudioHardwareBadDeviceError;
    if ([operation isEqual:@"--volume"]) {
        if (!isfinite(value) || value < 0 || value > 1) return kAudioHardwareIllegalOperationError;
        Float32 scalar = value;
        AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0};
        return AudioObjectSetPropertyData([target[@"id"] unsignedIntValue], &a, 0, NULL, sizeof(scalar), &scalar);
    }
    if (![operation isEqual:@"--bits"]) return kAudioHardwareIllegalOperationError;
    for (NSDictionary *stream in target[@"streams"]) {
        AudioStreamID sid = [stream[@"stream"] unsignedIntValue];
        AudioObjectPropertyAddress a = {kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, 0};
        AudioStreamRangedDescription ranges[128]; UInt32 size = sizeof(ranges);
        OSStatus e = AudioObjectGetPropertyData(sid, &a, 0, NULL, &size, ranges); if (e) return e;
        double rate = [stream[@"physical"][@"format"][@"sampleRate"] doubleValue];
        BOOL found = NO;
        for (unsigned i = 0; i < size / sizeof(ranges[0]); i++) {
            AudioStreamBasicDescription f = ranges[i].mFormat;
            if (f.mChannelsPerFrame != 2 || f.mBitsPerChannel != value ||
                f.mFormatFlags & (kAudioFormatFlagIsNonMixable | kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) ||
                rate < ranges[i].mSampleRateRange.mMinimum || rate > ranges[i].mSampleRateRange.mMaximum) continue;
            f.mSampleRate = rate; a.mSelector = kAudioStreamPropertyPhysicalFormat;
            e = AudioObjectSetPropertyData(sid, &a, 0, NULL, sizeof(f), &f); if (e) return e;
            found = YES; break;
        }
        if (!found) return kAudioHardwareUnsupportedOperationError;
    }
    return noErr;
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 1) {
        if (argc != 4) { fprintf(stderr, "usage: usb-audio-metadata [--volume|--bits DEVICE_UID VALUE]\n"); return 2; }
        OSStatus error = change(@(argv[2]), @(argv[1]), atof(argv[3]));
        if (error) { fprintf(stderr, "device setting failed: %d\n", (int)error); return 1; }
        [NSThread sleepForTimeInterval:.3];
    }
    NSDictionary *result = @{@"audio":audioDevices(), @"usb":usbDevices()};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (!data) return 1;
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
} }
