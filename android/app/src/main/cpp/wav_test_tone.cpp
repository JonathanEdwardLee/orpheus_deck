#include "wav_test_tone.h"

#include <vector>

#include "wav_writer.h"

namespace orpheus {

bool generateN3bTestWav(const std::string& path,
                        const int32_t sampleRate,
                        const int32_t durationSeconds) {
    const int32_t rate = sampleRate > 0 ? sampleRate : 48000;
    const int32_t seconds = durationSeconds > 0 ? durationSeconds : 8;
    const size_t totalFrames = static_cast<size_t>(rate) * static_cast<size_t>(seconds);

    std::vector<float> samples(totalFrames, 0.0f);
    constexpr int32_t kBurstFrames = 96;  // 2 ms @ 48 kHz
    constexpr float kClickLevel = 0.45f;

    for (int32_t sec = 0; sec < seconds; ++sec) {
        const size_t clickStart =
            static_cast<size_t>(sec) * static_cast<size_t>(rate);
        for (int32_t i = 0; i < kBurstFrames; ++i) {
            const size_t idx = clickStart + static_cast<size_t>(i);
            if (idx < totalFrames) {
                samples[idx] = kClickLevel;
            }
        }
    }

    WavWriter writer;
    return writer.writeMonoPcm16(path, samples, rate);
}

}  // namespace orpheus
