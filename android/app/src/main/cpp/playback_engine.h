#ifndef ORPHEUS_PLAYBACK_ENGINE_H_
#define ORPHEUS_PLAYBACK_ENGINE_H_

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <oboe/Oboe.h>

#include "audio_types.h"

namespace orpheus {

constexpr int32_t kN3PreferredSampleRate = 48000;

class PlaybackEngine;

class PlaybackOutputCallback : public oboe::AudioStreamCallback {
public:
    explicit PlaybackOutputCallback(PlaybackEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    PlaybackEngine* engine_;
};

/** N3B — one-track WAV playback, output-only Oboe stream. */
class PlaybackEngine {
public:
    friend class PlaybackOutputCallback;

    bool init();
    bool generateTestWav(const std::string& path);
    bool loadWav(const std::string& path);
    bool openStreams();
    bool startPlayback(int64_t startSample);
    void stopPlayback();
    void fillDiagnostics(OrpheusN3PlaybackDiagnostics* out) const;
    void shutdown();

    int64_t getTransportSample() const;
    bool isPlaybackComplete() const;

    const std::string& lastError() const { return lastError_; }

private:
    void closeOutputStream();
    bool openOutputStream(oboe::SharingMode sharing);
    void noteOpenFailure(oboe::Result result, const char* label);
    void handleOutputFrames(float* data, int32_t numFrames);

    PlaybackOutputCallback outputCallback_{this};
    std::shared_ptr<oboe::AudioStream> outputStream_;

    std::vector<float> pcmSamples_;
    const float* pcmData_ = nullptr;
    size_t pcmFrameCount_ = 0;

    std::string lastError_;
    std::string loadedPath_;

    std::atomic<int32_t> sampleRate_{kN3PreferredSampleRate};
    std::atomic<int32_t> wavSampleRate_{0};
    std::atomic<int32_t> wavChannels_{0};
    std::atomic<int32_t> wavLoadSuccess_{0};
    std::atomic<int32_t> outputOpened_{0};
    std::atomic<int32_t> isPlaying_{0};
    std::atomic<int32_t> playbackComplete_{0};
    std::atomic<int32_t> errorCode_{0};
    std::atomic<int32_t> exclusiveAttempted_{0};
    std::atomic<int32_t> sharedFallbackUsed_{0};
    std::atomic<int32_t> lastOpenErrorCode_{0};

    std::atomic<int64_t> wavTotalFrames_{0};
    std::atomic<int64_t> playbackStartSample_{0};
    std::atomic<int64_t> playbackStopSample_{0};
    std::atomic<int64_t> currentTransportSample_{0};
    std::atomic<int64_t> outputCallbackCount_{0};
    std::atomic<int32_t> playbackCompleteLogged_{0};
};

}  // namespace orpheus

#endif  // ORPHEUS_PLAYBACK_ENGINE_H_
