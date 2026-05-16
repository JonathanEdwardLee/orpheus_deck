#ifndef ORPHEUS_DUPLEX_ENGINE_H_
#define ORPHEUS_DUPLEX_ENGINE_H_

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <oboe/Oboe.h>

#include "audio_types.h"
#include "ring_buffer.h"
#include "wav_writer.h"

namespace orpheus {

constexpr int32_t kDuplexSampleRate = 48000;
constexpr int32_t kDuplexClickCount = 6;
constexpr int32_t kDuplexDurationSeconds = 6;

class DuplexEngine;

class DuplexOutputCallback : public oboe::AudioStreamCallback {
public:
    explicit DuplexOutputCallback(DuplexEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    DuplexEngine* engine_;
};

class DuplexInputCallback : public oboe::AudioStreamCallback {
public:
    explicit DuplexInputCallback(DuplexEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    DuplexEngine* engine_;
};

/** Phase N2 — full-duplex backing playback + mic capture (separate from N1). */
class DuplexEngine {
public:
    friend class DuplexOutputCallback;
    friend class DuplexInputCallback;

    bool init();
    bool openStreams();
    bool startDuplex(const std::string& recordWavPath);
    bool isComplete() const;
    void fillDiagnostics(OrpheusDuplexDiagnostics* out) const;
    void shutdown();

    const std::string& lastError() const { return lastError_; }

private:
    void closeStreams();
    bool openOutputStream(oboe::SharingMode sharing);
    bool openInputStream(oboe::SharingMode sharing);
    void noteOpenFailure(oboe::Result result, const char* label);
    void prepareBacking();
    void handleOutputFrames(float* data, int32_t numFrames);
    void handleInputFrames(const float* data, int32_t numFrames);
    void recordWorkerLoop();
    void finalizeWavFromRing();
    void markDuplexComplete();

    DuplexOutputCallback outputCallback_{this};
    DuplexInputCallback inputCallback_{this};

    std::shared_ptr<oboe::AudioStream> outputStream_;
    std::shared_ptr<oboe::AudioStream> inputStream_;

    std::vector<float> backing_;
    RingBuffer captureRing_;
    WavWriter wavWriter_;
    std::vector<float> captureScratch_;

    std::thread workerThread_;
    std::atomic<bool> workerRunning_{false};
    std::atomic<bool> workerFinalizePending_{false};

    std::string recordWavPath_;

    std::atomic<bool> duplexActive_{false};
    std::atomic<bool> duplexComplete_{false};

    std::atomic<int32_t> sampleRate_{kDuplexSampleRate};

    std::atomic<int64_t> transportFrame_{0};
    std::atomic<int64_t> transportStartSample_{0};
    std::atomic<int64_t> transportStopSample_{0};
    std::atomic<int64_t> backingFramesGenerated_{0};
    std::atomic<int64_t> recordedFramesWritten_{0};
    std::atomic<int64_t> outputCallbackCount_{0};
    std::atomic<int64_t> inputCallbackCount_{0};
    std::atomic<int64_t> firstOutputFrameSample_{-1};
    std::atomic<int64_t> firstInputFrameSample_{-1};

    std::atomic<bool> inputOpened_{false};
    std::atomic<bool> outputOpened_{false};
    std::atomic<bool> wavWriteSuccess_{false};
    std::atomic<bool> backingPlaySuccess_{false};
    std::atomic<bool> recordSuccess_{false};

    std::atomic<int32_t> exclusiveAttempted_{0};
    std::atomic<int32_t> sharedFallbackUsed_{0};
    std::atomic<int32_t> lastOpenErrorCode_{0};
    std::atomic<int32_t> androidSdkVersion_{0};

    std::string lastError_;
};

}  // namespace orpheus

#endif  // ORPHEUS_DUPLEX_ENGINE_H_
