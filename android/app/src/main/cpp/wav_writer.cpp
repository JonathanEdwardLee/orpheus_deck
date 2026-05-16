#include "wav_writer.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace orpheus {

namespace {

void writeLe32(std::FILE* f, uint32_t v) {
    const unsigned char b[4] = {
        static_cast<unsigned char>(v & 0xff),
        static_cast<unsigned char>((v >> 8) & 0xff),
        static_cast<unsigned char>((v >> 16) & 0xff),
        static_cast<unsigned char>((v >> 24) & 0xff),
    };
    std::fwrite(b, 1, 4, f);
}

void writeLe16(std::FILE* f, uint16_t v) {
    const unsigned char b[2] = {
        static_cast<unsigned char>(v & 0xff),
        static_cast<unsigned char>((v >> 8) & 0xff),
    };
    std::fwrite(b, 1, 2, f);
}

}  // namespace

bool WavWriter::writeMonoPcm16(const std::string& path,
                               const std::vector<float>& samples,
                               int32_t sampleRate) const {
    if (path.empty() || sampleRate <= 0) {
        return false;
    }

    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (f == nullptr) {
        return false;
    }

    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint32_t byteRate =
        static_cast<uint32_t>(sampleRate * channels * (bitsPerSample / 8));
    const uint16_t blockAlign = channels * (bitsPerSample / 8);
    const uint32_t dataBytes =
        static_cast<uint32_t>(samples.size() * sizeof(int16_t));
    const uint32_t riffSize = 36 + dataBytes;

    std::fwrite("RIFF", 1, 4, f);
    writeLe32(f, riffSize);
    std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f);
    writeLe32(f, 16);
    writeLe16(f, 1);  // PCM
    writeLe16(f, channels);
    writeLe32(f, static_cast<uint32_t>(sampleRate));
    writeLe32(f, byteRate);
    writeLe16(f, blockAlign);
    writeLe16(f, bitsPerSample);
    std::fwrite("data", 1, 4, f);
    writeLe32(f, dataBytes);

    for (float s : samples) {
        const float clamped = std::max(-1.0f, std::min(1.0f, s));
        const int16_t pcm =
            static_cast<int16_t>(clamped * 32767.0f);
        writeLe16(f, static_cast<uint16_t>(pcm));
    }

    const bool ok = std::fflush(f) == 0 && !std::ferror(f);
    std::fclose(f);
    return ok && dataBytes > 0;
}

}  // namespace orpheus
