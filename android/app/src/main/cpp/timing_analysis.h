#ifndef ORPHEUS_TIMING_ANALYSIS_H_
#define ORPHEUS_TIMING_ANALYSIS_H_

#include <cstdint>
#include <vector>

namespace orpheus {

/** Half-window (samples) to search around each expected click @ 48 kHz. */
constexpr int32_t kTimingSearchWindowSamples = 24000;

/** Max per-click offset slots in FFI (matches duplex click count). */
constexpr int32_t kMaxPerClickOffsets = 6;

/** N2D pass: |median residual| <= 256 samples (~5.3 ms @ 48 kHz). */
constexpr int64_t kN2DMaxMedianResidualAbsSamples = 256;
/** N2D pass: residual spread <= 1000 samples (~20.8 ms @ 48 kHz). */
constexpr int64_t kN2DMaxResidualSpreadSamples = 1000;
constexpr int32_t kN2DMinClicksForPass = 5;

/** N2B analysis failure codes (analysisFailureReason). */
enum TimingAnalysisFailure : int32_t {
    kTimingOk = 0,
    kTimingTooFewSamples = 1,
    kTimingNoClicksDetected = 2,
    kTimingTooFewMatches = 3,
    kTimingSpreadTooLarge = 4,
};

struct TimingAnalysisResult {
    int32_t clicksExpected = 0;
    int32_t clicksDetected = 0;
    int32_t analysisSuccess = 0;
    int32_t analysisFailureReason = 0;
    int32_t confidencePercent = 0;
    /** (medianOffsetSamples * 1_000_000) / sampleRate — Dart divides by 1000 for ms. */
    int32_t medianOffsetMsTimes1000 = 0;
    int64_t medianOffsetSamples = 0;
    int64_t minOffsetSamples = 0;
    int64_t maxOffsetSamples = 0;
    int64_t spreadSamples = 0;
    /** Proposed recordLatencyOffsetSamples (median click offset in recording). */
    int64_t recordLatencyOffsetSamples = 0;

    /** N2D compensation proof (worker thread only). */
    int64_t appliedCompensationSamples = 0;
    int64_t compensatedMedianResidualSamples = 0;
    int32_t compensatedMedianResidualMsTimes1000 = 0;
    int64_t compensatedResidualMinSamples = 0;
    int64_t compensatedResidualMaxSamples = 0;
    int64_t compensatedResidualSpreadSamples = 0;
    int32_t compensatedAlignmentSuccess = 0;
    int32_t compensatedQualityPercent = 0;
    int32_t perClickOffsetCount = 0;
    int64_t perClickOffsetSamples[kMaxPerClickOffsets]{};
    int64_t perClickResidualSamples[kMaxPerClickOffsets]{};
};

std::vector<int64_t> expectedClickSamplePositions(int32_t sampleRate,
                                                  int32_t numClicks);

/**
 * Detect backing click positions in recorded mono float PCM (worker thread only).
 * Searches ±searchWindowSamples around each expected click.
 */
TimingAnalysisResult analyzeRecordedClickTiming(
    const std::vector<float>& recordedSamples,
    int32_t sampleRate,
    int32_t numClicksExpected,
    int32_t searchWindowSamples);

}  // namespace orpheus

#endif  // ORPHEUS_TIMING_ANALYSIS_H_
