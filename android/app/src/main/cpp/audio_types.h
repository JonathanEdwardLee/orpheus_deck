#ifndef ORPHEUS_AUDIO_TYPES_H_
#define ORPHEUS_AUDIO_TYPES_H_

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/** Mirrors Dart @Packed(4) OrpheusStreamDiagnostics — no JSON over FFI. */
typedef struct OrpheusStreamDiagnostics {
    /** Actual output stream (legacy field = actualSampleRate). */
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t apiUsed;
    int32_t inputStreamOpened;
    int32_t outputStreamOpened;
    int32_t wavWriteSuccess;

    int32_t requestedSampleRate;
    int32_t actualSampleRate;
    int32_t requestedSharingMode;
    int32_t actualSharingMode;
    int32_t requestedPerformanceMode;
    int32_t actualPerformanceMode;

    /** 1 if Exclusive was tried before any Shared fallback. */
    int32_t exclusiveAttempted;
    /** 1 if Shared mode was used after Exclusive failed. */
    int32_t sharedFallbackUsed;
    /** 1 if setAudioApi was not called (Oboe Unspecified / default selection). */
    int32_t unspecifiedAudioApi;
    /** Oboe Result as int when a fallback open failed; 0 if none recorded. */
    int32_t lastOpenErrorCode;
    int32_t androidSdkVersion;
} OrpheusStreamDiagnostics;

/** Phase N2 full-duplex overdub diagnostics — strict C struct for FFI. */
typedef struct OrpheusDuplexDiagnostics {
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t apiUsed;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t outputStreamOpened;
    int32_t inputStreamOpened;
    int32_t wavWriteSuccess;
    int32_t backingPlaySuccess;
    int32_t recordSuccess;
    int32_t exclusiveAttempted;
    int32_t sharedFallbackUsed;
    int32_t lastOpenErrorCode;
    int32_t androidSdkVersion;
    int32_t _paddingForInt64Align;

    int64_t backingFramesGenerated;
    int64_t recordedFramesWritten;
    int64_t transportStartSample;
    int64_t transportStopSample;
    int64_t outputCallbackCount;
    int64_t inputCallbackCount;
    int64_t firstOutputFrameSample;
    int64_t firstInputFrameSample;
    int64_t estimatedInputOutputDeltaSamples;

    /** N2B timing analysis (worker thread, post-record). */
    int32_t clicksExpected;
    int32_t clicksDetected;
    int32_t analysisSuccess;
    int32_t analysisFailureReason;
    int32_t confidencePercent;
    int32_t medianOffsetMsTimes1000;
    int32_t _timingPadding;
    int64_t medianOffsetSamples;
    int64_t minOffsetSamples;
    int64_t maxOffsetSamples;
    int64_t spreadSamples;
    int64_t recordLatencyOffsetSamples;
} OrpheusDuplexDiagnostics;

#ifdef __cplusplus
}
#endif

#endif  // ORPHEUS_AUDIO_TYPES_H_
