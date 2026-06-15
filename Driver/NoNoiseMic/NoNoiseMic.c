// NoNoiseMic.c — "NoNoise Mic" userspace CoreAudio AudioServerPlugIn (HAL plug-in).
//
// Original implementation written against the PUBLIC AudioServerPlugIn API
// (<CoreAudio/AudioServerPlugIn.h>). It is modeled on the structure of Apple's documented
// "Creating an Audio Server Driver Plug-in" sample (NullAudio) — API USAGE patterns only, not
// copied source — so it carries the project's MIT license, NOT the Apple Sample Code License,
// and is explicitly NOT derived from BlackHole (GPL-3.0; reference reading only).
//
// Topology (see the plan's shared-contract table — these constants MUST match the Swift side):
//   • Visible INPUT-only device  "NoNoise Mic"        (UID NoNoiseMic:visible:48k2ch) → apps pick this.
//   • Hidden  OUTPUT-only device "NoNoise Mic Engine" (UID NoNoiseMic:engine:48k2ch) → the app renders here.
// Both devices share ONE loopback ring (nn_ring) and a per-device zero-timestamp clock
// (nn_clock) anchored to a SINGLE host-time captured on the first StartIO, so the engine's
// write sample-time axis and the mic's read sample-time axis coincide. The visible device's
// 'srcm' (sourceMode) property selects loopback (0, A1 default) vs xpc shm (1, A2).
//
// Canonical buffer layout: ONE interleaved Float32 stereo stream [L0,R0,L1,R1,…]; ioMainBuffer
// is passed straight into nn_ring (channels=2) with no de/interleave.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "nn_ring.h"
#include "nn_clock.h"

#pragma mark - Shared contract constants

#define kPlugIn_BundleID        "com.ivalsaraj.NoNoiseMic"
#define kManufacturerName       CFSTR("ivalsaraj")

#define kDeviceName_Mic         CFSTR("NoNoise Mic")
#define kDeviceName_Engine      CFSTR("NoNoise Mic Engine")
#define kDeviceUID_Mic          CFSTR("NoNoiseMic:visible:48k2ch")
#define kDeviceUID_Engine       CFSTR("NoNoiseMic:engine:48k2ch")
#define kModelUID               CFSTR("NoNoiseMic:model:1")

// sourceMode custom property. Use the char literal so the compiler computes the FourCharCode
// (a hand-typed hex with a transposed digit fails SILENTLY and the A2 toggle never switches).
#define kSourceModeSelector     ((AudioObjectPropertySelector)'srcm')   // == 0x7372636D

static const Float64 kSampleRate          = 48000.0;
static const UInt32  kChannels            = 2;
static const UInt32  kZeroTimeStampPeriod = 8192;   // frames between zero timestamps (HAL contract)
#define kRingFrames 65536u                          // power of two, ≥ 1s headroom at 48k (macro: sizes a real array)

enum {
    kObjectID_PlugIn               = kAudioObjectPlugInObject, // 1
    kObjectID_Device_Mic           = 2,
    kObjectID_Stream_Mic_Input     = 3,
    kObjectID_Device_Engine        = 4,
    kObjectID_Stream_Engine_Output = 5
};

#pragma mark - Plug-in state

static AudioServerPlugInHostRef gHost = NULL;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64   gAnchorHostTime = 0;
static UInt32   gIOCount        = 0;       // devices currently running IO (anchors the shared clock)
static bool     gMicRunning     = false;
static bool     gEngineRunning  = false;

static nn_clock gClockMic;
static nn_clock gClockEngine;

static float    gRingStorage[kRingFrames * 2]; // interleaved stereo
static nn_ring  gRing;
static bool     gRingInit = false;

// 0 = loopback (A1 default), 1 = xpc (A2). Read on the IO thread → atomic.
static _Atomic uint32_t gSourceMode = 0;

#pragma mark - Helpers

static double host_ticks_per_second(void) {
    // mach_absolute_time() * (numer/denom) = nanoseconds → ticks/sec = 1e9 * denom/numer.
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return 1.0e9 * (double)tb.denom / (double)tb.numer;
}

static AudioStreamBasicDescription MakeASBD(void) {
    AudioStreamBasicDescription a;
    memset(&a, 0, sizeof(a));
    a.mSampleRate       = kSampleRate;
    a.mFormatID         = kAudioFormatLinearPCM;
    a.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; // interleaved (NOT NonInterleaved)
    a.mBitsPerChannel   = 32;
    a.mChannelsPerFrame = kChannels;
    a.mFramesPerPacket  = 1;
    a.mBytesPerFrame    = kChannels * (UInt32)sizeof(Float32); // 8
    a.mBytesPerPacket   = a.mBytesPerFrame;                    // 8
    return a;
}

static bool isMicDevice(AudioObjectID o)    { return o == kObjectID_Device_Mic; }
static bool isEngineDevice(AudioObjectID o) { return o == kObjectID_Device_Engine; }
static bool isDevice(AudioObjectID o)       { return isMicDevice(o) || isEngineDevice(o); }
static bool isStream(AudioObjectID o)       { return o == kObjectID_Stream_Mic_Input || o == kObjectID_Stream_Engine_Output; }

// The single stream a device owns, filtered by scope. Returns count (0 or 1), fills out[0].
static UInt32 deviceStreamList(AudioObjectID dev, AudioObjectPropertyScope scope, AudioObjectID *out) {
    if (isMicDevice(dev)) {
        if (scope == kAudioObjectPropertyScopeOutput) return 0;
        out[0] = kObjectID_Stream_Mic_Input;
        return 1;
    }
    if (scope == kAudioObjectPropertyScopeInput) return 0;
    out[0] = kObjectID_Stream_Engine_Output;
    return 1;
}

static void NotifyChanged(AudioObjectID obj, const AudioObjectPropertyAddress *addr) {
    if (gHost && gHost->PropertiesChanged) gHost->PropertiesChanged(gHost, obj, 1, addr);
}

#pragma mark - COM plumbing (forward decls)

static HRESULT  NoNoiseMic_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    NoNoiseMic_AddRef(void *inDriver);
static ULONG    NoNoiseMic_Release(void *inDriver);
static OSStatus NoNoiseMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus NoNoiseMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus NoNoiseMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus NoNoiseMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus NoNoiseMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus NoNoiseMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus NoNoiseMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean  NoNoiseMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus NoNoiseMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus NoNoiseMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus NoNoiseMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus NoNoiseMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus NoNoiseMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus NoNoiseMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus NoNoiseMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus NoNoiseMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus NoNoiseMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus NoNoiseMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus NoNoiseMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    NoNoiseMic_QueryInterface,
    NoNoiseMic_AddRef,
    NoNoiseMic_Release,
    NoNoiseMic_Initialize,
    NoNoiseMic_CreateDevice,
    NoNoiseMic_DestroyDevice,
    NoNoiseMic_AddDeviceClient,
    NoNoiseMic_RemoveDeviceClient,
    NoNoiseMic_PerformDeviceConfigurationChange,
    NoNoiseMic_AbortDeviceConfigurationChange,
    NoNoiseMic_HasProperty,
    NoNoiseMic_IsPropertySettable,
    NoNoiseMic_GetPropertyDataSize,
    NoNoiseMic_GetPropertyData,
    NoNoiseMic_SetPropertyData,
    NoNoiseMic_StartIO,
    NoNoiseMic_StopIO,
    NoNoiseMic_GetZeroTimeStamp,
    NoNoiseMic_WillDoIOOperation,
    NoNoiseMic_BeginIOOperation,
    NoNoiseMic_DoIOOperation,
    NoNoiseMic_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;

#pragma mark - Factory (referenced by Info.plist CFPlugInFactories)

void *NoNoiseMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *NoNoiseMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (inRequestedTypeUUID != NULL && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

#pragma mark - COM

static HRESULT NoNoiseMic_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        *outInterface = gDriverRef;
        NoNoiseMic_AddRef(inDriver);
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

// Singleton — there is exactly one driver object for the lifetime of coreaudiod.
static ULONG NoNoiseMic_AddRef(void *inDriver)  { (void)inDriver; return 1; }
static ULONG NoNoiseMic_Release(void *inDriver) { (void)inDriver; return 1; }

#pragma mark - Lifecycle

static OSStatus NoNoiseMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    return noErr;
}

// Static topology — devices are not created/destroyed at runtime.
static OSStatus NoNoiseMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus NoNoiseMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus NoNoiseMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}
static OSStatus NoNoiseMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}
static OSStatus NoNoiseMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}
static OSStatus NoNoiseMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

#pragma mark - Property: size

static OSStatus NoNoiseMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    const AudioObjectPropertySelector sel = inAddress->mSelector;
    const AudioObjectPropertyScope    scope = inAddress->mScope;

    if (inObjectID == kObjectID_PlugIn) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:             *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:    *outDataSize = sizeof(CFStringRef);   return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:        *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isDevice(inObjectID)) {
        AudioObjectID tmp[1];
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:                          *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:                       *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:            *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate:              *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyRelatedDevices:                *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:                       *outDataSize = deviceStreamList(inObjectID, scope, tmp) * sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyControlList:                   *outDataSize = 0; return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates:  *outDataSize = sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:   *outDataSize = 2 * sizeof(UInt32); return noErr;
            default:
                if (sel == kSourceModeSelector) { *outDataSize = sizeof(UInt32); return noErr; }
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isStream(inObjectID)) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:                  *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:                *outDataSize = sizeof(UInt32); return noErr;
            case kAudioObjectPropertyOwnedObjects:           *outDataSize = 0; return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:         *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

#pragma mark - Property: get

#define CLAMP_ARRAY(elemType, count) \
    UInt32 _avail = inDataSize / (UInt32)sizeof(elemType); \
    UInt32 _n = (_avail < (count)) ? _avail : (count);

static OSStatus NoNoiseMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    const AudioObjectPropertySelector sel   = inAddress->mSelector;
    const AudioObjectPropertyScope    scope = inAddress->mScope;

    if (inObjectID == kObjectID_PlugIn) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID *)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID *)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer: *(CFStringRef *)outData = CFStringCreateCopy(NULL, kManufacturerName); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioPlugInPropertyResourceBundle: *(CFStringRef *)outData = CFStringCreateCopy(NULL, CFSTR("")); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID devs[2] = { kObjectID_Device_Mic, kObjectID_Device_Engine };
                CLAMP_ARRAY(AudioObjectID, 2);
                memcpy(outData, devs, _n * sizeof(AudioObjectID));
                *outDataSize = _n * sizeof(AudioObjectID);
                return noErr;
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareIllegalOperationError;
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                AudioObjectID match = kAudioObjectUnknown;
                if (CFEqual(uid, kDeviceUID_Mic))         match = kObjectID_Device_Mic;
                else if (CFEqual(uid, kDeviceUID_Engine)) match = kObjectID_Device_Engine;
                *(AudioObjectID *)outData = match;
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isDevice(inObjectID)) {
        const bool mic = isMicDevice(inObjectID);
        switch (sel) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID *)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID *)outData = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:      *(CFStringRef *)outData = CFStringCreateCopy(NULL, mic ? kDeviceName_Mic : kDeviceName_Engine); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyManufacturer: *(CFStringRef *)outData = CFStringCreateCopy(NULL, kManufacturerName); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyDeviceUID: *(CFStringRef *)outData = CFStringCreateCopy(NULL, mic ? kDeviceUID_Mic : kDeviceUID_Engine); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyModelUID:  *(CFStringRef *)outData = CFStringCreateCopy(NULL, kModelUID); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType: *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyClockDomain: *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning: {
                pthread_mutex_lock(&gStateMutex);
                UInt32 running = (mic ? gMicRunning : gEngineRunning) ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                *(UInt32 *)outData = running; *outDataSize = sizeof(UInt32); return noErr;
            }
            // The hidden engine must NEVER be auto-selected as a default device — only the
            // visible mic is input-eligible. (output scope for the engine returns 0.)
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:       *(UInt32 *)outData = mic ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32 *)outData = mic ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:       *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertySafetyOffset:  *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyIsHidden:      *(UInt32 *)outData = mic ? 0 : 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32 *)outData = kZeroTimeStampPeriod; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate: *(Float64 *)outData = kSampleRate; *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyRelatedDevices: {
                CLAMP_ARRAY(AudioObjectID, 1);
                if (_n >= 1) ((AudioObjectID *)outData)[0] = inObjectID;
                *outDataSize = _n * sizeof(AudioObjectID);
                return noErr;
            }
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: {
                AudioObjectID streams[1];
                UInt32 count = deviceStreamList(inObjectID, scope, streams);
                CLAMP_ARRAY(AudioObjectID, count);
                memcpy(outData, streams, _n * sizeof(AudioObjectID));
                *outDataSize = _n * sizeof(AudioObjectID);
                return noErr;
            }
            case kAudioObjectPropertyControlList: *outDataSize = 0; return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange r = { kSampleRate, kSampleRate };
                CLAMP_ARRAY(AudioValueRange, 1);
                if (_n >= 1) ((AudioValueRange *)outData)[0] = r;
                *outDataSize = _n * sizeof(AudioValueRange);
                return noErr;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 2;
                *outDataSize = 2 * sizeof(UInt32);
                return noErr;
            }
            default:
                if (sel == kSourceModeSelector) {
                    *(UInt32 *)outData = atomic_load(&gSourceMode); *outDataSize = sizeof(UInt32); return noErr;
                }
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isStream(inObjectID)) {
        const bool input = (inObjectID == kObjectID_Stream_Mic_Input);
        switch (sel) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID *)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID *)outData = input ? kObjectID_Device_Mic : kObjectID_Device_Engine; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioStreamPropertyIsActive:  *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection: *(UInt32 *)outData = input ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr; // 1=input, 0=output
            case kAudioStreamPropertyTerminalType: *(UInt32 *)outData = input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel: *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:   *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                *(AudioStreamBasicDescription *)outData = MakeASBD();
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return noErr;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription d;
                memset(&d, 0, sizeof(d));
                d.mFormat = MakeASBD();
                d.mSampleRateRange.mMinimum = kSampleRate;
                d.mSampleRateRange.mMaximum = kSampleRate;
                CLAMP_ARRAY(AudioStreamRangedDescription, 1);
                if (_n >= 1) ((AudioStreamRangedDescription *)outData)[0] = d;
                *outDataSize = _n * sizeof(AudioStreamRangedDescription);
                return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

#pragma mark - Property: has / settable / set

static Boolean NoNoiseMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    UInt32 size = 0;
    // A property exists iff we can compute its size. Size never depends on qualifier values here.
    OSStatus err = NoNoiseMic_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size);
    return err == noErr;
}

static OSStatus NoNoiseMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus err = NoNoiseMic_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size);
    if (err != noErr) return err;

    switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyIsActive:
        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = true; break;
        default:
            *outIsSettable = (inAddress->mSelector == kSourceModeSelector);
            break;
    }
    return noErr;
}

static OSStatus NoNoiseMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    // sourceMode toggle (A2 sets this from the app; A1 leaves it at 0).
    if (isDevice(inObjectID) && inAddress->mSelector == kSourceModeSelector) {
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        atomic_store(&gSourceMode, *(const UInt32 *)inData);
        AudioObjectPropertyAddress a = { kSourceModeSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        NotifyChanged(inObjectID, &a);
        return noErr;
    }

    // Single fixed format / sample rate — accept the canonical value, reject anything else
    // loudly rather than silently pretending to support an alternate rate.
    if (isDevice(inObjectID) && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return (*(const Float64 *)inData == kSampleRate) ? noErr : kAudioHardwareIllegalOperationError;
    }
    if (isStream(inObjectID) && (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription want = MakeASBD();
        bool ok = (f->mSampleRate == want.mSampleRate) && (f->mFormatID == want.mFormatID) &&
                  (f->mChannelsPerFrame == want.mChannelsPerFrame) && (f->mBitsPerChannel == want.mBitsPerChannel);
        return ok ? noErr : kAudioHardwareIllegalOperationError;
    }
    if (isStream(inObjectID) && inAddress->mSelector == kAudioStreamPropertyIsActive) {
        return noErr; // always active; accept the no-op
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus NoNoiseMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (!isDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        double tps = host_ticks_per_second();
        if (!gRingInit) { nn_ring_init(&gRing, gRingStorage, kRingFrames, kChannels); gRingInit = true; }
        nn_ring_clear(&gRing);
        nn_clock_init(&gClockMic,    gAnchorHostTime, tps, kSampleRate, kZeroTimeStampPeriod);
        nn_clock_init(&gClockEngine, gAnchorHostTime, tps, kSampleRate, kZeroTimeStampPeriod);
    }
    gIOCount++;
    if (isMicDevice(inDeviceObjectID)) gMicRunning = true; else gEngineRunning = true;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus NoNoiseMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (!isDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    if (isMicDevice(inDeviceObjectID)) gMicRunning = false; else gEngineRunning = false;
    if (gIOCount == 0) gAnchorHostTime = 0;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus NoNoiseMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inClientID;
    if (!isDevice(inDeviceObjectID) || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    uint64_t st = 0, ht = 0;
    pthread_mutex_lock(&gStateMutex);
    nn_clock *c = isMicDevice(inDeviceObjectID) ? &gClockMic : &gClockEngine;
    nn_clock_get_zero_timestamp(c, mach_absolute_time(), &st, &ht);
    pthread_mutex_unlock(&gStateMutex);

    *outSampleTime = (Float64)st;
    *outHostTime   = ht;
    *outSeed       = 1; // topology/format never changes mid-run
    return noErr;
}

static OSStatus NoNoiseMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    bool will = (inOperationID == kAudioServerPlugInIOOperationReadInput) || (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo)        *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus NoNoiseMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

// Real-time path: NO allocation / locks / syscalls. gRing/gSourceMode are lock-free; the shared
// nn_clock keeps the mic read trailing the engine write on a common sample-time axis.
static OSStatus NoNoiseMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return noErr;

    if (isEngineDevice(inDeviceObjectID) && inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        double sd = inIOCycleInfo->mOutputTime.mSampleTime;
        if (sd < 0.0) sd = 0.0;
        nn_ring_write_at(&gRing, (uint64_t)sd, (const float *)ioMainBuffer, inIOBufferFrameSize);
        return noErr;
    }

    if (isMicDevice(inDeviceObjectID) && inOperationID == kAudioServerPlugInIOOperationReadInput) {
        if (atomic_load(&gSourceMode) == 0) {
            double sd = inIOCycleInfo->mInputTime.mSampleTime;
            if (sd < 0.0) sd = 0.0;
            nn_ring_read_at(&gRing, (uint64_t)sd, (float *)ioMainBuffer, inIOBufferFrameSize);
        } else {
            // A2 (xpc) shm path lands in Task 15 — until then serve silence, never stale audio.
            memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kChannels * sizeof(float));
        }
        return noErr;
    }

    return noErr;
}

static OSStatus NoNoiseMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}
