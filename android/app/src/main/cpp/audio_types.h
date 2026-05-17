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

    /** N2D compensation proof (effectiveTapeStart = trackTapeStart - recordLatencyOffset). */
    int32_t compensatedAlignmentSuccess;
    int32_t compensatedQualityPercent;
    int32_t compensatedMedianResidualMsTimes1000;
    int32_t perClickOffsetCount;
    int64_t appliedCompensationSamples;
    int64_t compensatedMedianResidualSamples;
    int64_t compensatedResidualMinSamples;
    int64_t compensatedResidualMaxSamples;
    int64_t compensatedResidualSpreadSamples;
    int64_t perClickOffset0;
    int64_t perClickOffset1;
    int64_t perClickOffset2;
    int64_t perClickOffset3;
    int64_t perClickOffset4;
    int64_t perClickOffset5;
    int64_t perClickResidual0;
    int64_t perClickResidual1;
    int64_t perClickResidual2;
    int64_t perClickResidual3;
    int64_t perClickResidual4;
    int64_t perClickResidual5;
} OrpheusDuplexDiagnostics;

/**
 * Phase N3B one-track WAV playback diagnostics — strict C struct for FFI.
 * Dart mirror MUST use @Packed(8) (int64_t aligns to 8 after int32 block).
 */
typedef struct OrpheusN3PlaybackDiagnostics {
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t apiUsed;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t outputStreamOpened;
    int32_t wavLoadSuccess;
    int32_t wavSampleRate;
    int32_t wavChannels;
    int32_t playbackComplete;
    int32_t isPlaying;
    int32_t errorCode;
    int32_t exclusiveAttempted;
    int32_t sharedFallbackUsed;
    int32_t _paddingForInt64Align;

    int64_t wavTotalFrames;
    int64_t playbackStartSample;
    int64_t playbackStopSample;
    int64_t currentTransportSample;
    int64_t outputCallbackCount;
} OrpheusN3PlaybackDiagnostics;

/**
 * Phase N3C one-track overdub diagnostics — Dart mirror MUST use @Packed(8).
 */
typedef struct OrpheusN3OverdubDiagnostics {
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t apiUsed;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t inputStreamOpened;
    int32_t outputStreamOpened;
    int32_t backingWavLoadSuccess;
    int32_t wavWriteSuccess;
    int32_t playbackComplete;
    int32_t recordSuccess;
    int32_t errorCode;
    int32_t exclusiveAttempted;
    int32_t sharedFallbackUsed;
    int32_t analysisSuccess;
    int32_t compensatedAlignmentSuccess;
    int32_t clicksDetected;
    int32_t clicksExpected;
    int32_t confidencePercent;
    int32_t medianOffsetMsTimes1000;
    int32_t compensatedQualityPercent;
    /** profileResidualSamples * 1_000_000 / sampleRate (Dart / 1000 for ms). */
    int32_t profileResidualMsTimes1000;
    /** 0 = UNSTABLE, 1 = OK, 2 = PASS (vs stored profile offset). */
    int32_t profileCompensationResult;
    /** 1 if |recorded - expected| within sanity window. */
    int32_t recordedFramesSanity;
    int32_t _paddingForInt64Align;

    int64_t backingWavTotalFrames;
    int64_t backingStartSample;
    int64_t recordStartSample;
    int64_t defaultRecordLatencyOffsetSamples;
    int64_t effectiveRecordStartSample;
    int64_t recordedFramesWritten;
    int64_t currentTransportSample;
    int64_t transportStopSample;
    int64_t outputCallbackCount;
    int64_t inputCallbackCount;
    /** Measured from recorded mic WAV (N2B). */
    int64_t measuredMedianOffsetSamples;
    /** N2D self-check: median - appliedMedian (applied = measured median). */
    int64_t measuredSelfResidualSamples;
    /** measuredMedianOffsetSamples - defaultRecordLatencyOffsetSamples. */
    int64_t profileResidualSamples;
    int64_t expectedRecordedFrames;
} OrpheusN3OverdubDiagnostics;

#ifdef __cplusplus
}
static_assert(sizeof(OrpheusN3PlaybackDiagnostics) == 112,
              "OrpheusN3PlaybackDiagnostics size must match Dart @Packed(8)");
static_assert(sizeof(OrpheusN3OverdubDiagnostics) == 224,
              "OrpheusN3OverdubDiagnostics size must match Dart @Packed(8)");
#endif

#endif  // ORPHEUS_AUDIO_TYPES_H_
