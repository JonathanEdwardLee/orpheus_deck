#ifndef ORPHEUS_TIMING_ANALYSIS_H_
#define ORPHEUS_TIMING_ANALYSIS_H_

#include <cstdint>
#include <vector>

namespace orpheus {

/** Half-window (samples) to search around each expected click @ 48 kHz. */
constexpr int32_t kTimingSearchWindowSamples = 24000;

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
