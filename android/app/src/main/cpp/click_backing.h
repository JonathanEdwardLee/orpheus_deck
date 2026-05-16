#ifndef ORPHEUS_CLICK_BACKING_H_
#define ORPHEUS_CLICK_BACKING_H_

#include <cstdint>
#include <vector>

namespace orpheus {

/** 2 ms click burst length at 48 kHz. */
constexpr int32_t kClickBurstFrames = 96;

/**
 * Generate mono float backing: [numClicks] bursts, one per second.
 * Total length = durationSeconds * sampleRate.
 */
std::vector<float> generateClickBacking(int32_t sampleRate,
                                        int32_t numClicks,
                                        int32_t durationSeconds);

}  // namespace orpheus

#endif  // ORPHEUS_CLICK_BACKING_H_
