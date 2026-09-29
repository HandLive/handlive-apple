/*
 * Loads HandLiveSpikeMic.driver in this process the way coreaudiod does (CFPlugIn factory → driver interface) and
 * checks its objects, properties and the loopback, without installing anything. Built and run by `build.sh test`.
 *
 * Copyright 2026 Hồ Xuân Dũng and HandLive contributors. Licensed under the Apache License, Version 2.0.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <stdio.h>
#include <string.h>

static int gFailures = 0;
static int gPropertyChanges = 0;

#define CHECK(condition, message)                                                                                 \
    do {                                                                                                          \
        if (condition) {                                                                                          \
            printf("ok   %s\n", message);                                                                         \
        } else {                                                                                                  \
            printf("FAIL %s (line %d)\n", message, __LINE__);                                                    \
            gFailures++;                                                                                          \
        }                                                                                                         \
    } while (0)

static OSStatus PropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                                  const AudioObjectPropertyAddress *addresses) {
    gPropertyChanges++;
    return 0;
}
static OSStatus CopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *data) {
    *data = NULL;
    return 0;
}
static OSStatus WriteToStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) { return 0; }
static OSStatus DeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) { return 0; }
static OSStatus RequestChange(AudioServerPlugInHostRef host, AudioObjectID device, UInt64 action, void *info) {
    return 0;
}

static AudioServerPlugInHostInterface gHost = {PropertiesChanged, CopyFromStorage, WriteToStorage, DeleteFromStorage,
                                               RequestChange};

static AudioServerPlugInDriverRef gDriver;

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return address;
}

static UInt32 GetUInt32(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 value = 0xFFFFFFFF, size = 0;
    (*gDriver)->GetPropertyData(gDriver, object, 0, &address, 0, NULL, sizeof(value), &size, &value);
    return value;
}

static Boolean StringEquals(AudioObjectID object, AudioObjectPropertySelector selector, CFStringRef expected) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = 0;
    OSStatus status = (*gDriver)->GetPropertyData(gDriver, object, 0, &address, 0, NULL, sizeof(value), &size, &value);
    Boolean equal = status == 0 && value != NULL && CFStringCompare(value, expected, 0) == kCFCompareEqualTo;
    if (value != NULL) CFRelease(value);
    return equal;
}

static AudioObjectID DeviceForUID(CFStringRef uid) {
    AudioObjectPropertyAddress address = Address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, sizeof(uid), &uid, sizeof(device), &size,
                                &device);
    return device;
}

static UInt32 StreamCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    (*gDriver)->GetPropertyDataSize(gDriver, device, 0, &address, 0, NULL, &size);
    return size / sizeof(AudioObjectID);
}

static void CheckLoopback(AudioObjectID feed, AudioObjectID input) {
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    Float32 written[512], read[512];
    for (int index = 0; index < 512; index++) written[index] = (Float32)index / 512.0f - 0.5f;

    CHECK((*gDriver)->StartIO(gDriver, feed, 1) == 0 && (*gDriver)->StartIO(gDriver, input, 2) == 0, "StartIO on both devices");
    CHECK(GetUInt32(feed, kAudioDevicePropertyDeviceIsRunning) == 1, "feed reports running");

    Boolean willDo = false, inPlace = false;
    (*gDriver)->WillDoIOOperation(gDriver, feed, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
    CHECK(willDo, "feed does WriteMix");
    (*gDriver)->WillDoIOOperation(gDriver, input, 2, kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace);
    CHECK(willDo, "input does ReadInput");
    (*gDriver)->WillDoIOOperation(gDriver, input, 2, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
    CHECK(!willDo, "input does not WriteMix");

    Float64 sampleTime = -1;
    UInt64 hostTime = 0, seed = 0;
    CHECK((*gDriver)->GetZeroTimeStamp(gDriver, feed, 1, &sampleTime, &hostTime, &seed) == 0 && sampleTime >= 0 && seed == 1,
          "GetZeroTimeStamp");

    /* The feed plays frames 20000…20511 (wrapping the 16384-frame ring); the input reads the same sample times. */
    cycle.mOutputTime.mSampleTime = 20000;
    (*gDriver)->DoIOOperation(gDriver, feed, 3, 1, kAudioServerPlugInIOOperationWriteMix, 512, &cycle, written, NULL);
    cycle.mInputTime.mSampleTime = 20000;
    (*gDriver)->DoIOOperation(gDriver, input, 5, 2, kAudioServerPlugInIOOperationReadInput, 512, &cycle, read, NULL);
    CHECK(memcmp(written, read, sizeof(read)) == 0, "input hears what the feed played at the same sample time");

    /* One ring later nothing was written: the input must hear silence, not the stale frames. */
    cycle.mInputTime.mSampleTime = 20000 + 16384;
    (*gDriver)->DoIOOperation(gDriver, input, 5, 2, kAudioServerPlugInIOOperationReadInput, 512, &cycle, read, NULL);
    Boolean silent = true;
    for (int index = 0; index < 512; index++) silent = silent && read[index] == 0.0f;
    CHECK(silent, "stale ring slots read as silence");

    CHECK((*gDriver)->StopIO(gDriver, feed, 1) == 0 && (*gDriver)->StopIO(gDriver, input, 2) == 0, "StopIO on both devices");
    CHECK(GetUInt32(feed, kAudioDevicePropertyDeviceIsRunning) == 0, "feed reports stopped");
}

int main(int argc, const char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s path/to/HandLiveSpikeMic.driver\n", argv[0]);
        return 2;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef plugIn = CFPlugInCreate(NULL, url);
    CHECK(plugIn != NULL, "bundle loads as a CFPlugIn");
    if (plugIn == NULL) return 1;
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugIn);
    CHECK(factories != NULL && CFArrayGetCount(factories) == 1, "one factory for kAudioServerPlugInTypeUUID");
    if (factories == NULL || CFArrayGetCount(factories) == 0) return 1;
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl **unknown = (IUnknownVTbl **)CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    CHECK(unknown != NULL, "factory returns an instance");
    if (unknown == NULL) return 1;
    CHECK((*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID *)&gDriver) == S_OK,
          "QueryInterface(driver interface)");
    CHECK((*gDriver)->Initialize(gDriver, &gHost) == 0, "Initialize");

    AudioObjectID feed = DeviceForUID(CFSTR("app.handlive.spike.mic.feed"));
    AudioObjectID input = DeviceForUID(CFSTR("app.handlive.spike.mic.input"));
    CHECK(feed != kAudioObjectUnknown && input != kAudioObjectUnknown && feed != input, "both UIDs translate to devices");
    CHECK(DeviceForUID(CFSTR("nope")) == kAudioObjectUnknown, "an unknown UID translates to nothing");
    CHECK(StringEquals(input, kAudioObjectPropertyName, CFSTR("HandLive Microphone Spike")), "input device name");
    CHECK(GetUInt32(feed, kAudioDevicePropertyIsHidden) == 1 && GetUInt32(input, kAudioDevicePropertyIsHidden) == 0,
          "feed hidden, input visible");
    CHECK(GetUInt32(feed, kAudioDevicePropertyDeviceCanBeDefaultDevice) == 0
              && GetUInt32(input, kAudioDevicePropertyDeviceCanBeDefaultDevice) == 1,
          "only the input can be a default device");
    CHECK(StreamCount(feed, kAudioObjectPropertyScopeOutput) == 1 && StreamCount(feed, kAudioObjectPropertyScopeInput) == 0,
          "feed: one output stream only");
    CHECK(StreamCount(input, kAudioObjectPropertyScopeInput) == 1 && StreamCount(input, kAudioObjectPropertyScopeOutput) == 0,
          "input: one input stream only");
    CHECK(GetUInt32(3, kAudioStreamPropertyDirection) == 0 && GetUInt32(5, kAudioStreamPropertyDirection) == 1,
          "stream directions");

    AudioObjectPropertyAddress format = Address(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription description;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, 5, 0, &format, 0, NULL, sizeof(description), &size, &description);
    CHECK(description.mSampleRate == 48000 && description.mChannelsPerFrame == 1 && description.mBitsPerChannel == 32
              && (description.mFormatFlags & kAudioFormatFlagIsFloat),
          "48 kHz mono Float32");

    AudioObjectPropertyAddress unknownAddress = Address('zzzz', kAudioObjectPropertyScopeGlobal);
    CHECK(!(*gDriver)->HasProperty(gDriver, input, 0, &unknownAddress), "unknown properties are absent");

    CheckLoopback(feed, input);

    printf("%s: %d failure(s)\n", gFailures == 0 ? "PASS" : "FAIL", gFailures);
    return gFailures == 0 ? 0 : 1;
}
