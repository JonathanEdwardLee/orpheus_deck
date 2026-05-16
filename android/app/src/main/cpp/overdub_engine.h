#ifndef ORPHEUS_OVERDUB_ENGINE_H_
#define ORPHEUS_OVERDUB_ENGINE_H_

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <oboe/Oboe.h>

#include "audio_types.h"
#include "ring_buffer.h"
#include "timing_analysis.h"
#include "wav_writer.h"

namespace orpheus {

constexpr int32_t kN3cSampleRate = 48000;
/** Dev default only — not production settings (N2E target ~2900 @ 48 kHz). */
constexpr int64_t kN3cDevDefaultRecordLatencyOffsetSamples = 2900;

class OverdubEngine;

class OverdubOutputCallback : public oboe::AudioStreamCallback {
public:
    explicit OverdubOutputCallback(OverdubEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    OverdubEngine* engine_;
};

class OverdubInputCallback : public oboe::AudioStreamCallback {
public:
    explicit OverdubInputCallback(OverdubEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    OverdubEngine* engine_;
};

/** N3C — WAV backing playback + mic record, single transport clock. */
class OverdubEngine {
public:
    friend class OverdubOutputCallback;
    friend class OverdubInputCallback;

    bool init();
    bool generateAndLoadBackingWav(const std::string& path);
    bool loadBackingWav(const std::string& path);
    void setDefaultRecordLatencyOffsetSamples(int64_t offsetSamples);
    bool openStreams();
    bool startOverdub(const std::string& recordWavPath, int64_t backingStartSample);
    void stopOverdub();
    bool isComplete() const;
    void fillDiagnostics(OrpheusN3OverdubDiagnostics* out) const;
    void shutdown();

    const std::string& lastError() const { return lastError_; }

private:
    void closeStreams();
    bool openOutputStream(oboe::SharingMode sharing);
    bool openInputStream(oboe::SharingMode sharing);
    void noteOpenFailure(oboe::Result result, const char* label);
    void handleOutputFrames(float* data, int32_t numFrames);
    void handleInputFrames(const float* data, int32_t numFrames);
    void recordWorkerLoop();
    void finalizeWavFromRing();
    void runTimingAnalysis(const std::vector<float>& recordedSamples);
    void markOverdubComplete();
    int32_t clicksExpectedForSession() const;

    OverdubOutputCallback outputCallback_{this};
    OverdubInputCallback inputCallback_{this};

    std::shared_ptr<oboe::AudioStream> outputStream_;
    std::shared_ptr<oboe::AudioStream> inputStream_;

    std::vector<float> backing_;
    const float* backingData_ = nullptr;
    size_t backingFrameCount_ = 0;

    RingBuffer captureRing_;
    WavWriter wavWriter_;
    std::vector<float> captureScratch_;

    std::thread workerThread_;
    std::atomic<bool> workerRunning_{false};
    std::atomic<bool> workerFinalizePending_{false};

    std::string recordWavPath_;
    std::string backingPath_;

    std::atomic<bool> overdubActive_{false};
    std::atomic<bool> overdubComplete_{false};
    std::atomic<bool> analysisComplete_{false};

    TimingAnalysisResult timingResult_;

    std::string lastError_;

    std::atomic<int32_t> sampleRate_{kN3cSampleRate};
    std::atomic<int32_t> backingWavLoadSuccess_{0};
    std::atomic<int32_t> inputOpened_{0};
    std::atomic<int32_t> outputOpened_{0};
    std::atomic<int32_t> wavWriteSuccess_{0};
    std::atomic<int32_t> playbackComplete_{0};
    std::atomic<int32_t> recordSuccess_{0};
    std::atomic<int32_t> errorCode_{0};
    std::atomic<int32_t> exclusiveAttempted_{0};
    std::atomic<int32_t> sharedFallbackUsed_{0};
    std::atomic<int32_t> lastOpenErrorCode_{0};

    std::atomic<int64_t> backingWavTotalFrames_{0};
    std::atomic<int64_t> backingStartSample_{0};
    std::atomic<int64_t> recordStartSample_{0};
    std::atomic<int64_t> defaultRecordLatencyOffsetSamples_{
        kN3cDevDefaultRecordLatencyOffsetSamples};
    std::atomic<int64_t> effectiveRecordStartSample_{0};
    std::atomic<int64_t> recordedFramesWritten_{0};
    std::atomic<int64_t> currentTransportSample_{0};
    std::atomic<int64_t> transportStopSample_{0};
    std::atomic<int64_t> outputCallbackCount_{0};
    std::atomic<int64_t> inputCallbackCount_{0};
};

}  // namespace orpheus

#endif  // ORPHEUS_OVERDUB_ENGINE_H_
