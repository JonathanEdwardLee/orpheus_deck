#ifndef ORPHEUS_OBOE_ENGINE_H_
#define ORPHEUS_OBOE_ENGINE_H_

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

constexpr int32_t kPreferredSampleRate = 48000;
/** 2 ms square burst at 48 kHz (ORPHEUS_NATIVE_AUDIO_PLAN.md). */
constexpr int32_t kImpulseBurstFrames = 96;
constexpr size_t kCaptureRingSeconds = 5;

class OboeEngine;

class OutputStreamCallback : public oboe::AudioStreamCallback {
public:
    explicit OutputStreamCallback(OboeEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    OboeEngine* engine_;
};

class InputStreamCallback : public oboe::AudioStreamCallback {
public:
    explicit InputStreamCallback(OboeEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    OboeEngine* engine_;
};

class OboeEngine {
public:
    friend class OutputStreamCallback;
    friend class InputStreamCallback;

    bool init();
    bool openStreams();
    bool playImpulse();
    bool startRecord(const std::string& wavPath, int32_t durationMs);
    bool stopRecord();
    void fillDiagnostics(OrpheusStreamDiagnostics* out) const;
    void shutdown();

    const std::string& lastError() const { return lastError_; }

private:
    bool openOutputStream(bool exclusive);
    bool openInputStream(bool exclusive);
    void handleOutputFrames(float* data, int32_t numFrames);
    void handleInputFrames(const float* data, int32_t numFrames);
    void recordWorkerLoop();
    void finalizeWavFromRing();

    OutputStreamCallback outputCallback_{this};
    InputStreamCallback inputCallback_{this};

    std::shared_ptr<oboe::AudioStream> outputStream_;
    std::shared_ptr<oboe::AudioStream> inputStream_;

    RingBuffer captureRing_;
    WavWriter wavWriter_;

    std::thread workerThread_;
    std::atomic<bool> workerRunning_{false};
    std::atomic<bool> workerStopRequested_{false};
    std::atomic<bool> workerFinalizePending_{false};

    std::string wavPath_;
    std::vector<float> captureScratch_;

    std::atomic<int32_t> sampleRate_{kPreferredSampleRate};
    std::atomic<int32_t> impulseFramesLeft_{0};
    std::atomic<bool> recording_{false};
    std::atomic<int64_t> recordedFrames_{0};
    std::atomic<int64_t> recordTargetFrames_{0};
    std::atomic<int64_t> outputCallbackCount_{0};
    std::atomic<int64_t> inputCallbackCount_{0};

    std::atomic<bool> inputOpened_{false};
    std::atomic<bool> outputOpened_{false};
    std::atomic<bool> wavWriteSuccess_{false};
    std::atomic<bool> usedExclusiveSharing_{true};

    std::atomic<int32_t> cachedFramesPerBurst_{0};
    std::atomic<int32_t> cachedBufferSize_{0};
    std::atomic<int32_t> cachedPerformanceMode_{0};
    std::atomic<int32_t> cachedSharingMode_{0};
    std::atomic<int32_t> cachedApiUsed_{0};
    std::atomic<int32_t> cachedXRunCount_{0};

    std::string lastError_;
};

}  // namespace orpheus

#endif  // ORPHEUS_OBOE_ENGINE_H_
