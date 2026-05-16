#ifndef ORPHEUS_WAV_WRITER_H_
#define ORPHEUS_WAV_WRITER_H_

#include <cstdint>
#include <string>
#include <vector>

namespace orpheus {

/** PCM16 mono WAV — file I/O only on worker thread, never in Oboe callbacks. */
class WavWriter {
public:
    bool writeMonoPcm16(const std::string& path,
                        const std::vector<float>& samples,
                        int32_t sampleRate) const;
};

}  // namespace orpheus

#endif  // ORPHEUS_WAV_WRITER_H_
