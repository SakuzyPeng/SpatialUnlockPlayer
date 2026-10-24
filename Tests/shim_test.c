#include "../Sources/SpatialShim/SpatialShim.h"
#include <CoreAudio/CoreAudio.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    AudioDeviceID device = (AudioDeviceID)strtoul(argv[1], NULL, 10);
    AudioObjectPropertyAddress a = {'spmd', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Boolean original = AudioObjectHasProperty(device, &a);
    assert(original == SpatialShimNativeHasProperty(device, 'spmd'));
    SpatialShimSetConfiguration(device, true);
    assert(AudioObjectHasProperty(device, &a));
    assert(SpatialShimNativeHasProperty(device, 'spmd') == original);
    UInt32 size = 0;
    assert(!AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) && size == 4);
    struct { UInt32 value; UInt32 guard; } result = {0, 0xf00d1234};
    assert(!AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &result.value));
    assert(result.value == 1 && result.guard == 0xf00d1234);
    size = 3; result.value = 0x12345678;
    assert(AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &result.value) == kAudioHardwareBadPropertySizeError);
    assert(result.value == 0x12345678 && result.guard == 0xf00d1234);
    UInt32 native = 0;
    OSStatus nativeStatus = SpatialShimNativeReadUInt32(device, 'spmd', &native);
    if (!original) assert(nativeStatus != noErr);
    assert(SpatialShimGetStatus().overriddenQueries >= 4);
    SpatialShimSetConfiguration(0, false);
    assert(AudioObjectHasProperty(device, &a) == original);
    assert(!SpatialShimGetStatus().enabled);
    printf("PASS: normally linked dylib, native-query bypass, UInt32 ABI/bounds and disable; device=%u\n", device);
    return 0;
}
