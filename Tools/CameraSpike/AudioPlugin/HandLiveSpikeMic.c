/*
 * HandLive Microphone Spike: an AudioServerPlugIn (HAL plug-in) loopback for gate G5.
 *
 * Copyright 2026 Hồ Xuân Dũng and HandLive contributors. Licensed under the Apache License, Version 2.0.
 *
 * Written from scratch against Apple's public header CoreAudio/AudioServerPlugIn.h. It follows the *model* of
 * decision C8 (a hidden output device and a visible input device sharing a ring buffer inside the driver), not any
 * code: BlackHole is GPL-3.0 and none of its code is used here.
 *
 * Objects:
 *   1  the plug-in
 *   2  "HandLive Microphone Spike Feed", UID app.handlive.spike.mic.feed, hidden, one output stream (3)
 *   4  "HandLive Microphone Spike",      UID app.handlive.spike.mic.input, one input stream (5)
 * Format: 48 kHz, Float32, mono. Both devices share one timeline (the same anchor host time), so sample time T on
 * the feed device and sample time T on the input device are the same instant. The feed writes frame T into slot
 * T mod 16384 and tags the slot with T; the input returns the slot only when its tag is T, silence otherwise, so
 * nothing stale plays when the feed stops.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#pragma mark Constants

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectFeedDevice = 2,
    kObjectFeedStream = 3,
    kObjectInputDevice = 4,
    kObjectInputStream = 5,
};

#define kSampleRate 48000.0
#define kRingFrames 16384u
#define kPeriodFrames kRingFrames
#define kManufacturer CFSTR("HandLive")
#define kFeedName CFSTR("HandLive Microphone Spike Feed")
#define kFeedUID CFSTR("app.handlive.spike.mic.feed")
#define kInputName CFSTR("HandLive Microphone Spike")
#define kInputUID CFSTR("app.handlive.spike.mic.input")
#define kModelUID CFSTR("app.handlive.spike.mic.model")

#pragma mark State

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32 gRefCount = 0;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gIOCount[6] = {0};          /* running IO clients per device object ID */
static _Atomic UInt64 gAnchorHostTime = 0; /* shared timeline of both devices */
static Float64 gHostTicksPerFrame = 0;

static Float32 gRing[kRingFrames];
static _Atomic SInt64 gRingTags[kRingFrames];

#pragma mark Object helpers

static Boolean IsDevice(AudioObjectID object) { return object == kObjectFeedDevice || object == kObjectInputDevice; }
static Boolean IsStream(AudioObjectID object) { return object == kObjectFeedStream || object == kObjectInputStream; }
static AudioObjectID StreamOf(AudioObjectID device) {
    return device == kObjectFeedDevice ? kObjectFeedStream : kObjectInputStream;
}
static AudioObjectID DeviceOf(AudioObjectID stream) {
    return stream == kObjectFeedStream ? kObjectFeedDevice : kObjectInputDevice;
}
/* The feed device only plays (output scope); the input device only records (input scope). */
static Boolean DeviceHasStreamInScope(AudioObjectID device, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    return (device == kObjectFeedDevice) ? scope == kAudioObjectPropertyScopeOutput : scope == kAudioObjectPropertyScopeInput;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format = {
        .mSampleRate = kSampleRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32,
    };
    return format;
}

static void NotifyRunningChanged(AudioObjectID device) {
    if (gHost == NULL) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        gHost->PropertiesChanged(gHost, device, 1, &address);
    });
}

/* Writes a value of type T into outData when it fits; used by GetPropertyData. */
#define RETURN_VALUE(T, value)                                                                                   \
    do {                                                                                                         \
        if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError;                                   \
        *(T *)outData = (value);                                                                                 \
        *outDataSize = sizeof(T);                                                                                \
        return kAudioHardwareNoError;                                                                            \
    } while (0)

#define RETURN_CFSTRING(value) RETURN_VALUE(CFStringRef, (CFStringRef)CFRetain(value))

#pragma mark Property sizes

static OSStatus DataSize(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 *outSize) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
        *outSize = sizeof(AudioClassID);
        return kAudioHardwareNoError;
    case kAudioObjectPropertyOwner:
        *outSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioPlugInPropertyResourceBundle:
        *outSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    case kAudioObjectPropertyOwnedObjects:
        if (object == kObjectPlugIn) *outSize = 2 * sizeof(AudioObjectID);
        else if (IsDevice(object)) *outSize = DeviceHasStreamInScope(object, address->mScope) ? sizeof(AudioObjectID) : 0;
        else *outSize = 0;
        return kAudioHardwareNoError;
    case kAudioPlugInPropertyDeviceList:
        *outSize = 2 * sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioDevicePropertyRelatedDevices:
        *outSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    case kAudioDevicePropertyStreams:
        *outSize = DeviceHasStreamInScope(object, address->mScope) ? sizeof(AudioObjectID) : 0;
        return kAudioHardwareNoError;
    case kAudioObjectPropertyControlList:
        *outSize = 0;
        return kAudioHardwareNoError;
    case kAudioDevicePropertyNominalSampleRate:
        *outSize = sizeof(Float64);
        return kAudioHardwareNoError;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *outSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outSize = 2 * sizeof(UInt32);
        return kAudioHardwareNoError;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outSize = sizeof(AudioStreamBasicDescription);
        return kAudioHardwareNoError;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        *outSize = sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    default:
        /* Every other supported property is a UInt32. */
        *outSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
}

#pragma mark Property presence

static Boolean PlugInHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
        return true;
    default:
        return false;
    }
}

static Boolean DeviceHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyPreferredChannelsForStereo:
        return true;
    default:
        return false;
    }
}

static Boolean StreamHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    default:
        return false;
    }
}

static Boolean ObjectHas(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    if (object == kObjectPlugIn) return PlugInHas(address->mSelector);
    if (IsDevice(object)) return DeviceHas(address->mSelector);
    if (IsStream(object)) return StreamHas(address->mSelector);
    return false;
}

#pragma mark Property values

static OSStatus PlugInGet(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                          UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(kManufacturer);
    case kAudioPlugInPropertyResourceBundle: RETURN_CFSTRING(CFSTR(""));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID *ids = (AudioObjectID *)outData;
        UInt32 count = inDataSize / sizeof(AudioObjectID);
        if (count > 0) ids[0] = kObjectFeedDevice;
        if (count > 1) ids[1] = kObjectInputDevice;
        *outDataSize = (count < 2 ? count : 2) * sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef *)qualifier;
        AudioObjectID device = kAudioObjectUnknown;
        if (uid != NULL && CFStringCompare(uid, kFeedUID, 0) == kCFCompareEqualTo) device = kObjectFeedDevice;
        if (uid != NULL && CFStringCompare(uid, kInputUID, 0) == kCFCompareEqualTo) device = kObjectInputDevice;
        RETURN_VALUE(AudioObjectID, device);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceGet(AudioObjectID device, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                          UInt32 *outDataSize, void *outData) {
    Boolean isFeed = device == kObjectFeedDevice;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectPlugIn);
    case kAudioObjectPropertyName: RETURN_CFSTRING(isFeed ? kFeedName : kInputName);
    case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(kManufacturer);
    case kAudioDevicePropertyDeviceUID: RETURN_CFSTRING(isFeed ? kFeedUID : kInputUID);
    case kAudioDevicePropertyModelUID: RETURN_CFSTRING(kModelUID);
    case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, device);
    case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gStateMutex);
        UInt32 running = gIOCount[device] > 0;
        pthread_mutex_unlock(&gStateMutex);
        RETURN_VALUE(UInt32, running);
    }
    /* The feed can never become a default device; the input can be the default microphone. */
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, isFeed ? 0 : 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, isFeed ? 1 : 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kPeriodFrames);
    case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {kSampleRate, kSampleRate};
        RETURN_VALUE(AudioValueRange, range);
    }
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        if (!DeviceHasStreamInScope(device, address->mScope) || inDataSize < sizeof(AudioObjectID)) {
            *outDataSize = 0;
            return kAudioHardwareNoError;
        }
        RETURN_VALUE(AudioObjectID, StreamOf(device));
    case kAudioObjectPropertyControlList:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        ((UInt32 *)outData)[0] = 1;
        ((UInt32 *)outData)[1] = 1;
        *outDataSize = 2 * sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamGet(AudioObjectID stream, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                          UInt32 *outDataSize, void *outData) {
    Boolean isFeed = stream == kObjectFeedStream;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, DeviceOf(stream));
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
    /* 0 = output (the app plays into the feed), 1 = input (meeting apps record from the microphone). */
    case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isFeed ? 0 : 1);
    case kAudioStreamPropertyTerminalType:
        RETURN_VALUE(UInt32, isFeed ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeMicrophone);
    case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged = {StreamFormat(), {kSampleRate, kSampleRate}};
        RETURN_VALUE(AudioStreamRangedDescription, ranged);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark IUnknown

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);

#pragma mark Driver interface

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    for (UInt32 slot = 0; slot < kRingFrames; slot++) atomic_store(&gRingTags[slot], -1);
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c,
                             AudioObjectID *outID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) {
    return IsDevice(device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                   const AudioServerPlugInClientInfo *c) {
    return IsDevice(device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus PerformConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action,
                                           void *info) {
    return kAudioHardwareNoError;
}

static OSStatus AbortConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                           const AudioObjectPropertyAddress *address) {
    return address != NULL && ObjectHas(object, address);
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                   const AudioObjectPropertyAddress *address, Boolean *outIsSettable) {
    if (address == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectHas(object, address)) return kAudioHardwareUnknownPropertyError;
    /* Accepted but fixed: clients may "set" the only sample rate and the only format. */
    AudioObjectPropertySelector selector = address->mSelector;
    *outIsSettable = selector == kAudioDevicePropertyNominalSampleRate || selector == kAudioStreamPropertyVirtualFormat
                     || selector == kAudioStreamPropertyPhysicalFormat;
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                                    const void *qualifier, UInt32 *outDataSize) {
    if (address == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectHas(object, address)) return kAudioHardwareUnknownPropertyError;
    return DataSize(object, address, outDataSize);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                                UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (address == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (object == kObjectPlugIn) return PlugInGet(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
    if (IsDevice(object)) return DeviceGet(object, address, inDataSize, outDataSize, outData);
    if (IsStream(object)) return StreamGet(object, address, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                                UInt32 inDataSize, const void *inData) {
    if (address == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    switch (address->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)inData == kSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *format = (const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription ours = StreamFormat();
        Boolean same = format->mSampleRate == ours.mSampleRate && format->mFormatID == ours.mFormatID
                       && format->mChannelsPerFrame == ours.mChannelsPerFrame
                       && format->mBitsPerChannel == ours.mBitsPerChannel;
        return same ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    default:
        return kAudioHardwareUnsupportedOperationError;
    }
}

#pragma mark IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (!IsDevice(device)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    Boolean nothingRunning = gIOCount[kObjectFeedDevice] == 0 && gIOCount[kObjectInputDevice] == 0;
    if (nothingRunning) atomic_store(&gAnchorHostTime, mach_absolute_time());
    Boolean first = gIOCount[device]++ == 0;
    pthread_mutex_unlock(&gStateMutex);
    if (first) NotifyRunningChanged(device);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (!IsDevice(device)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    Boolean last = gIOCount[device] > 0 && --gIOCount[device] == 0;
    pthread_mutex_unlock(&gStateMutex);
    if (last) NotifyRunningChanged(device);
    return kAudioHardwareNoError;
}

/* The latest period boundary of the shared timeline: sample time n * 16384 at anchor + n * 16384 frames of ticks. */
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    UInt64 anchor = atomic_load(&gAnchorHostTime);
    Float64 ticksPerPeriod = gHostTicksPerFrame * kPeriodFrames;
    UInt64 now = mach_absolute_time();
    UInt64 periods = now > anchor ? (UInt64)((Float64)(now - anchor) / ticksPerPeriod) : 0;
    *outSampleTime = (Float64)(periods * kPeriodFrames);
    *outHostTime = anchor + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                                  Boolean *outWillDo, Boolean *outWillDoInPlace) {
    Boolean willDo = (device == kObjectFeedDevice && operation == kAudioServerPlugInIOOperationWriteMix)
                     || (device == kObjectInputDevice && operation == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return kAudioHardwareNoError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 client,
                              UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                              void *mainBuffer, void *secondaryBuffer) {
    Float32 *samples = (Float32 *)mainBuffer;
    if (samples == NULL || cycle == NULL) return kAudioHardwareNoError;
    if (device == kObjectFeedDevice && operation == kAudioServerPlugInIOOperationWriteMix) {
        SInt64 start = (SInt64)cycle->mOutputTime.mSampleTime;
        for (UInt32 index = 0; index < frames; index++) {
            SInt64 time = start + index;
            UInt32 slot = (UInt32)(time % kRingFrames);
            gRing[slot] = samples[index];
            atomic_store_explicit(&gRingTags[slot], time, memory_order_release);
        }
    } else if (device == kObjectInputDevice && operation == kAudioServerPlugInIOOperationReadInput) {
        SInt64 start = (SInt64)cycle->mInputTime.mSampleTime;
        for (UInt32 index = 0; index < frames; index++) {
            SInt64 time = start + index;
            UInt32 slot = (UInt32)(time % kRingFrames);
            Boolean fresh = atomic_load_explicit(&gRingTags[slot], memory_order_acquire) == time;
            samples[index] = fresh ? gRing[slot] : 0.0f;
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                               UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return kAudioHardwareNoError;
}

#pragma mark Interface table and factory

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient,
    RemoveDeviceClient, PerformConfigurationChange, AbortConfigurationChange, HasProperty, IsPropertySettable,
    GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation,
    BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriver || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    Boolean known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }
    atomic_fetch_add(&gRefCount, 1);
    *outInterface = gDriver;
    return S_OK;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriver) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriver) return 0;
    UInt32 count = atomic_load(&gRefCount);
    if (count == 0) return 0;
    return atomic_fetch_sub(&gRefCount, 1) - 1;
}

/* Named in Info.plist under CFPlugInFactories. */
void *HandLiveSpikeMicCreate(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void *HandLiveSpikeMicCreate(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    return CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}
