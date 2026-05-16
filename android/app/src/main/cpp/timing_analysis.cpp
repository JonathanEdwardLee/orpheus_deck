#include "timing_analysis.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace orpheus {

namespace {

constexpr int32_t kMinMatchesForSuccess = 3;
constexpr int64_t kMaxSpreadSamples = 4800;  // 100 ms @ 48 kHz

float sampleEnergy(const std::vector<float>& samples, size_t center, size_t radius) {
    const size_t start = center > radius ? center - radius : 0;
    const size_t end = std::min(samples.size(), center + radius);
    float sum = 0.0f;
    for (size_t i = start; i < end; ++i) {
        const float s = samples[i];
        sum += s * s;
    }
    return sum;
}

float medianAbsSample(const std::vector<float>& samples) {
    if (samples.empty()) {
        return 0.0f;
    }
    std::vector<float> absVals;
    absVals.reserve(std::min(samples.size(), size_t{48000}));
    const size_t step = std::max<size_t>(1, samples.size() / absVals.capacity());
    for (size_t i = 0; i < samples.size(); i += step) {
        absVals.push_back(std::fabs(samples[i]));
    }
    if (absVals.empty()) {
        return 0.0f;
    }
    const size_t mid = absVals.size() / 2;
    std::nth_element(absVals.begin(), absVals.begin() + static_cast<std::ptrdiff_t>(mid),
                     absVals.end());
    return absVals[mid];
}

int64_t medianOf(std::vector<int64_t> values) {
    if (values.empty()) {
        return 0;
    }
    const size_t mid = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(mid),
                     values.end());
    return values[mid];
}

}  // namespace

std::vector<int64_t> expectedClickSamplePositions(const int32_t sampleRate,
                                                  const int32_t numClicks) {
    std::vector<int64_t> positions;
    const int32_t rate = sampleRate > 0 ? sampleRate : 48000;
    const int32_t clicks = numClicks > 0 ? numClicks : 0;
    positions.reserve(static_cast<size_t>(clicks));
    for (int32_t c = 0; c < clicks; ++c) {
        positions.push_back(static_cast<int64_t>(c) * rate);
    }
    return positions;
}

TimingAnalysisResult analyzeRecordedClickTiming(
    const std::vector<float>& recordedSamples,
    const int32_t sampleRate,
    const int32_t numClicksExpected,
    const int32_t searchWindowSamples) {
    TimingAnalysisResult result;
    result.clicksExpected = numClicksExpected;

    if (recordedSamples.empty() || sampleRate <= 0 || numClicksExpected <= 0) {
        result.analysisFailureReason = kTimingTooFewSamples;
        return result;
    }

    const int32_t window =
        searchWindowSamples > 0 ? searchWindowSamples : kTimingSearchWindowSamples;
    const size_t energyRadius = 48;  // ~1 ms @ 48 kHz
    const float noiseFloor = medianAbsSample(recordedSamples);
    const float threshold = std::max(0.002f, noiseFloor * 8.0f);

    const auto expected = expectedClickSamplePositions(sampleRate, numClicksExpected);
    std::vector<int64_t> detected;
    std::vector<int64_t> offsets;
    detected.reserve(expected.size());
    offsets.reserve(expected.size());

    for (const int64_t expectedPos : expected) {
        if (expectedPos < 0 ||
            static_cast<size_t>(expectedPos) >= recordedSamples.size()) {
            continue;
        }
        const int64_t winStart =
            std::max<int64_t>(0, expectedPos - window);
        const int64_t winEnd = std::min<int64_t>(
            static_cast<int64_t>(recordedSamples.size()) - 1, expectedPos + window);

        float bestEnergy = 0.0f;
        int64_t bestPos = expectedPos;
        for (int64_t p = winStart; p <= winEnd; ++p) {
            const float e =
                sampleEnergy(recordedSamples, static_cast<size_t>(p), energyRadius);
            if (e > bestEnergy) {
                bestEnergy = e;
                bestPos = p;
            }
        }

        float peakAbs = 0.0f;
        const int64_t peakLo = std::max<int64_t>(0, bestPos - 8);
        const int64_t peakHi = std::min<int64_t>(
            static_cast<int64_t>(recordedSamples.size()) - 1, bestPos + 8);
        for (int64_t p = peakLo; p <= peakHi; ++p) {
            peakAbs = std::max(peakAbs, std::fabs(recordedSamples[static_cast<size_t>(p)]));
        }

        if (peakAbs >= threshold) {
            detected.push_back(bestPos);
            offsets.push_back(bestPos - expectedPos);
        }
    }

    result.clicksDetected = static_cast<int32_t>(detected.size());
    if (detected.empty()) {
        result.analysisFailureReason = kTimingNoClicksDetected;
        return result;
    }
    if (detected.size() < static_cast<size_t>(kMinMatchesForSuccess)) {
        result.analysisFailureReason = kTimingTooFewMatches;
        return result;
    }

    const int64_t med = medianOf(offsets);
    int64_t minOff = offsets[0];
    int64_t maxOff = offsets[0];
    for (const int64_t o : offsets) {
        minOff = std::min(minOff, o);
        maxOff = std::max(maxOff, o);
    }
    const int64_t spread = maxOff - minOff;

    result.medianOffsetSamples = med;
    result.minOffsetSamples = minOff;
    result.maxOffsetSamples = maxOff;
    result.spreadSamples = spread;
    result.recordLatencyOffsetSamples = med;
    result.medianOffsetMsTimes1000 = static_cast<int32_t>(
        (med * 1000000LL) / static_cast<int64_t>(sampleRate));

    if (spread > kMaxSpreadSamples) {
        result.analysisFailureReason = kTimingSpreadTooLarge;
        result.confidencePercent = std::max(
            0,
            static_cast<int32_t>(
                (100 * detected.size()) / static_cast<size_t>(numClicksExpected)) - 20);
        return result;
    }

    result.analysisSuccess = 1;
    result.analysisFailureReason = kTimingOk;
    const int32_t matchPct = static_cast<int32_t>(
        (100 * detected.size()) / static_cast<size_t>(numClicksExpected));
    const int32_t spreadPenalty = static_cast<int32_t>(
        std::min<int64_t>(40, (spread * 40) / kMaxSpreadSamples));
    result.confidencePercent =
        std::max(0, std::min(100, matchPct - spreadPenalty));
    return result;
}

}  // namespace orpheus
