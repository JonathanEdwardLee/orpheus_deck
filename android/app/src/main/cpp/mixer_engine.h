#ifndef ORPHEUS_MIXER_ENGINE_H_
#define ORPHEUS_MIXER_ENGINE_H_

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <oboe/Oboe.h>

#include "audio_types.h"

namespace orpheus {

constexpr int32_t kN3dTrackCount = 4;
constexpr int32_t kN3dSampleRate = 48000;
/** 10 s @ 48 kHz — dev mixer test transport length. */
constexpr int64_t kN3dTapeLengthSamples = 48000LL * 10LL;
constexpr int32_t kN3dTestWavSeconds = 10;

class MixerEngine;

class MixerOutputCallback : public oboe::AudioStreamCallback {
public:
    explicit MixerOutputCallback(MixerEngine* engine) : engine_(engine) {}

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream,
                                          void* audioData,
                                          int32_t numFrames) override;

private:
    MixerEngine* engine_;
};

/** N3D — four-track in-memory WAV mixer, output-only Oboe stream. */
class MixerEngine {
public:
    friend class MixerOutputCallback;

    bool init();
    /** Generate 4 test WAVs under [dir]/orpheus_n3d_trk{0..3}.wav and load them. */
    bool generateAndLoadTestTracks(const std::string& cacheDir);
    void unloadAllTracks();
    bool loadTrack(int32_t trackIndex,
                   const std::string& path,
                   int64_t tapeStartSample,
                   int64_t recordLatencyOffsetSamples);
    void setTapeLengthSamples(int64_t tapeLengthSamples);
    bool openStreams();
    bool startMix(int64_t startSample);
    void stopMix();
    void resetMixer();
    bool setTrackGain(int32_t trackIndex, float gain);
    bool setTrackMute(int32_t trackIndex, int32_t muted);
    bool setTrackSolo(int32_t trackIndex, int32_t solo);
    void fillDiagnostics(OrpheusN3MixerDiagnostics* out) const;
    void shutdown();

    int64_t getTransportSample() const;
    bool isPlaybackComplete() const;

    const std::string& lastError() const { return lastError_; }

private:
    struct TrackSlot {
        std::vector<float> pcm;
        const float* pcmData = nullptr;
        size_t frameCount = 0;
        std::atomic<int32_t> loaded{0};
        std::atomic<int64_t> tapeStartSample{0};
        std::atomic<int64_t> recordLatencyOffsetSamples{0};
        std::atomic<int64_t> effectiveTapeStartSample{0};
        std::atomic<int32_t> gainTimes1000{800};
        std::atomic<int32_t> muted{0};
        std::atomic<int32_t> solo{0};
        std::atomic<int64_t> framesMixed{0};
    };

    bool loadTrackFromPath(int32_t trackIndex,
                           const std::string& path,
                           int64_t tapeStartSample,
                           int64_t recordLatencyOffsetSamples);
    void closeOutputStream();
    bool openOutputStream(oboe::SharingMode sharing);
    void noteOpenFailure(oboe::Result result, const char* label);
    void handleOutputFrames(float* data, int32_t numFrames);
    int32_t countTracksLoaded() const;
    int32_t countTracksActiveAt(int64_t transportSample) const;

    MixerOutputCallback outputCallback_{this};
    std::shared_ptr<oboe::AudioStream> outputStream_;
    TrackSlot tracks_[kN3dTrackCount];

    std::string lastError_;
    std::string cacheDir_;

    std::atomic<int32_t> sampleRate_{kN3dSampleRate};
    std::atomic<int32_t> outputOpened_{0};
    std::atomic<int32_t> isPlaying_{0};
    std::atomic<int32_t> playbackComplete_{0};
    std::atomic<int32_t> errorCode_{0};
    std::atomic<int32_t> exclusiveAttempted_{0};
    std::atomic<int32_t> sharedFallbackUsed_{0};
    std::atomic<int32_t> lastOpenErrorCode_{0};
    std::atomic<int32_t> playbackCompleteLogged_{0};

    std::atomic<int64_t> tapeLengthSamples_{kN3dTapeLengthSamples};
    std::atomic<int64_t> transportStartSample_{0};
    std::atomic<int64_t> transportStopSample_{kN3dTapeLengthSamples};
    std::atomic<int64_t> currentTransportSample_{0};
    std::atomic<int64_t> outputCallbackCount_{0};
};

}  // namespace orpheus

#endif  // ORPHEUS_MIXER_ENGINE_H_
