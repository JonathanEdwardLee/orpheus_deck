#ifndef ORPHEUS_WAV_READER_H_
#define ORPHEUS_WAV_READER_H_

#include <cstdint>
#include <string>
#include <vector>

namespace orpheus {

/** Loaded mono PCM as float [-1, 1]. File I/O only — never in Oboe callbacks. */
struct WavLoadResult {
    bool success = false;
    int32_t errorCode = 0;
    int32_t sampleRate = 0;
    int32_t channels = 0;
    int64_t frameCount = 0;
    std::vector<float> samples;
};

/** N3B: PCM16 or IEEE float mono WAV. Prefers 48 kHz (rejects other rates). */
WavLoadResult loadMonoWav(const std::string& path, int32_t requiredSampleRate);

}  // namespace orpheus

#endif  // ORPHEUS_WAV_READER_H_
