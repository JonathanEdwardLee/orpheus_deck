#include "wav_reader.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace orpheus {

namespace {

constexpr int32_t kErrOpen = 1;
constexpr int32_t kErrFormat = 2;
constexpr int32_t kErrRate = 3;
constexpr int32_t kErrChannels = 4;

uint32_t readLe32(const unsigned char* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

uint16_t readLe16(const unsigned char* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

}  // namespace

WavLoadResult loadMonoWav(const std::string& path, const int32_t requiredSampleRate) {
    WavLoadResult result;
    if (path.empty()) {
        result.errorCode = kErrOpen;
        return result;
    }

    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        result.errorCode = kErrOpen;
        return result;
    }

    unsigned char riff[12];
    if (std::fread(riff, 1, 12, f) != 12 ||
        std::memcmp(riff, "RIFF", 4) != 0 || std::memcmp(riff + 8, "WAVE", 4) != 0) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }

    uint16_t audioFormat = 0;
    uint16_t channels = 0;
    uint32_t sampleRate = 0;
    uint16_t bitsPerSample = 0;
    uint32_t dataBytes = 0;
    long dataOffset = 0;
    bool haveFmt = false;
    bool haveData = false;

    while (!haveData) {
        unsigned char chunkHdr[8];
        if (std::fread(chunkHdr, 1, 8, f) != 8) {
            break;
        }
        const uint32_t chunkSize = readLe32(chunkHdr + 4);
        if (std::memcmp(chunkHdr, "fmt ", 4) == 0) {
            if (chunkSize < 16) {
                std::fseek(f, static_cast<long>(chunkSize), SEEK_CUR);
                continue;
            }
            unsigned char fmt[16];
            if (std::fread(fmt, 1, 16, f) != 16) {
                break;
            }
            audioFormat = readLe16(fmt);
            channels = readLe16(fmt + 2);
            sampleRate = readLe32(fmt + 4);
            bitsPerSample = readLe16(fmt + 14);
            haveFmt = true;
            if (chunkSize > 16) {
                std::fseek(f, static_cast<long>(chunkSize - 16), SEEK_CUR);
            }
        } else if (std::memcmp(chunkHdr, "data", 4) == 0) {
            dataBytes = chunkSize;
            dataOffset = std::ftell(f);
            haveData = true;
        } else {
            std::fseek(f, static_cast<long>(chunkSize), SEEK_CUR);
        }
    }

    if (!haveFmt || !haveData || dataBytes == 0) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }

    if (channels != 1) {
        std::fclose(f);
        result.errorCode = kErrChannels;
        return result;
    }

    if (requiredSampleRate > 0 &&
        static_cast<int32_t>(sampleRate) != requiredSampleRate) {
        std::fclose(f);
        result.errorCode = kErrRate;
        result.sampleRate = static_cast<int32_t>(sampleRate);
        result.channels = 1;
        return result;
    }

    if (audioFormat != 1 && audioFormat != 3) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }

    if (audioFormat == 1 && bitsPerSample != 16) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }

    if (audioFormat == 3 && bitsPerSample != 32) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }

    std::fseek(f, dataOffset, SEEK_SET);
    const size_t bytesToRead = dataBytes;
    std::vector<unsigned char> raw(bytesToRead);
    if (std::fread(raw.data(), 1, bytesToRead, f) != bytesToRead) {
        std::fclose(f);
        result.errorCode = kErrFormat;
        return result;
    }
    std::fclose(f);

    const size_t frameCount =
        audioFormat == 1 ? bytesToRead / 2 : bytesToRead / 4;
    result.samples.resize(frameCount);

    if (audioFormat == 1) {
        for (size_t i = 0; i < frameCount; ++i) {
            const int16_t pcm = static_cast<int16_t>(
                readLe16(raw.data() + i * 2));
            result.samples[i] = static_cast<float>(pcm) / 32768.0f;
        }
    } else {
        for (size_t i = 0; i < frameCount; ++i) {
            const uint32_t bits = readLe32(raw.data() + i * 4);
            float sample;
            std::memcpy(&sample, &bits, sizeof(float));
            result.samples[i] = std::max(-1.0f, std::min(1.0f, sample));
        }
    }

    result.success = true;
    result.sampleRate = static_cast<int32_t>(sampleRate);
    result.channels = 1;
    result.frameCount = static_cast<int64_t>(frameCount);
    return result;
}

}  // namespace orpheus
