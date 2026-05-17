#ifndef ORPHEUS_WAV_TEST_TONE_H_
#define ORPHEUS_WAV_TEST_TONE_H_

#include <cstdint>
#include <string>

namespace orpheus {

/** N3B dev test WAV: 48 kHz mono, click bursts every 1 s (default 8 s). */
bool generateN3bTestWav(const std::string& path,
                       int32_t sampleRate = 48000,
                       int32_t durationSeconds = 8);

/**
 * N3D per-track test WAV: distinctive click pattern (trackIndex 0–3).
 * All tracks: click every 1 s; levels/patterns differ for identification.
 */
bool generateN3dTrackWav(const std::string& path,
                         int32_t trackIndex,
                         int32_t sampleRate = 48000,
                         int32_t durationSeconds = 10);

}  // namespace orpheus

#endif  // ORPHEUS_WAV_TEST_TONE_H_
