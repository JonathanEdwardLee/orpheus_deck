#include "click_backing.h"

#include <algorithm>
#include <cstring>

namespace orpheus {

std::vector<float> generateClickBacking(const int32_t sampleRate,
                                        const int32_t numClicks,
                                        const int32_t durationSeconds) {
    const int32_t rate = sampleRate > 0 ? sampleRate : 48000;
    const int32_t seconds = durationSeconds > 0 ? durationSeconds : 6;
    const int32_t clicks = numClicks > 0 ? numClicks : 6;
    const size_t totalFrames =
        static_cast<size_t>(rate) * static_cast<size_t>(seconds);

    std::vector<float> backing(totalFrames, 0.0f);
    for (int32_t c = 0; c < clicks; ++c) {
        const size_t start =
            static_cast<size_t>(c) * static_cast<size_t>(rate);
        if (start >= totalFrames) {
            break;
        }
        const size_t burst =
            std::min(static_cast<size_t>(kClickBurstFrames), totalFrames - start);
        for (size_t i = 0; i < burst; ++i) {
            backing[start + i] = 0.85f;
        }
    }
    return backing;
}

}  // namespace orpheus
