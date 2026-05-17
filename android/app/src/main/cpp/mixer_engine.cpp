#include "mixer_engine.h"

#include <android/log.h>
#include <algorithm>
#include <cstring>
#include <string>

#include "wav_reader.h"
#include "wav_test_tone.h"

#define ORPHEUS_LOG_TAG "OrpheusN3D"
#define ORPHEUS_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, ORPHEUS_LOG_TAG, __VA_ARGS__)
#define ORPHEUS_LOGI(...) __android_log_print(ANDROID_LOG_INFO, ORPHEUS_LOG_TAG, __VA_ARGS__)

namespace orpheus {

namespace {

int32_t oboeModeToInt(oboe::PerformanceMode mode) {
    return static_cast<int32_t>(mode);
}

int32_t oboeSharingToInt(oboe::SharingMode mode) {
    return static_cast<int32_t>(mode);
}

int32_t oboeApiToInt(oboe::AudioApi api) {
    return static_cast<int32_t>(api);
}

int32_t readXRunCount(oboe::AudioStream* stream) {
    if (stream == nullptr) {
        return 0;
    }
    const auto xruns = stream->getXRunCount();
    if (xruns) {
        return xruns.value();
    }
    return 0;
}

constexpr int64_t kN3dTapeStarts[kN3dTrackCount] = {0, 48000, 96000, 144000};
constexpr int64_t kN3dLatencyOffsets[kN3dTrackCount] = {0, 100, 200, 0};

}  // namespace

oboe::DataCallbackResult MixerOutputCallback::onAudioReady(
    oboe::AudioStream* stream,
    void* audioData,
    int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    engine->handleOutputFrames(static_cast<float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

bool MixerEngine::init() {
    lastError_.clear();
    errorCode_.store(0, std::memory_order_relaxed);
    sampleRate_.store(kN3dSampleRate, std::memory_order_relaxed);
    tapeLengthSamples_.store(kN3dTapeLengthSamples, std::memory_order_relaxed);
    transportStopSample_.store(kN3dTapeLengthSamples, std::memory_order_relaxed);
    resetMixer();
    return true;
}

void MixerEngine::resetMixer() {
    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        tracks_[i].gainTimes1000.store(800, std::memory_order_relaxed);
        tracks_[i].muted.store(0, std::memory_order_relaxed);
        tracks_[i].solo.store(0, std::memory_order_relaxed);
    }
}

bool MixerEngine::loadTrackFromPath(const int32_t trackIndex,
                                    const std::string& path,
                                    const int64_t tapeStartSample,
                                    const int64_t recordLatencyOffsetSamples) {
    if (trackIndex < 0 || trackIndex >= kN3dTrackCount) {
        lastError_ = "invalid track index";
        return false;
    }

    TrackSlot& slot = tracks_[trackIndex];
    slot.loaded.store(0, std::memory_order_relaxed);
    slot.pcm.clear();
    slot.pcmData = nullptr;
    slot.frameCount = 0;

    const WavLoadResult loaded = loadMonoWav(path, kN3dSampleRate);
    if (!loaded.success) {
        lastError_ = "WAV load failed track " + std::to_string(trackIndex);
        errorCode_.store(loaded.errorCode, std::memory_order_relaxed);
        return false;
    }

    slot.pcm = std::move(loaded.samples);
    slot.pcmData = slot.pcm.data();
    slot.frameCount = slot.pcm.size();
    slot.tapeStartSample.store(tapeStartSample, std::memory_order_relaxed);
    slot.recordLatencyOffsetSamples.store(recordLatencyOffsetSamples,
                                          std::memory_order_relaxed);
    const int64_t effective = tapeStartSample - recordLatencyOffsetSamples;
    slot.effectiveTapeStartSample.store(effective, std::memory_order_relaxed);
    slot.framesMixed.store(0, std::memory_order_relaxed);
    slot.loaded.store(1, std::memory_order_release);

    ORPHEUS_LOGI(
        "N3D track %d loaded frames=%zu tapeStart=%lld offset=%lld effective=%lld",
        trackIndex,
        slot.frameCount,
        static_cast<long long>(tapeStartSample),
        static_cast<long long>(recordLatencyOffsetSamples),
        static_cast<long long>(effective));
    return true;
}

bool MixerEngine::generateAndLoadTestTracks(const std::string& cacheDir) {
    cacheDir_ = cacheDir;
    int32_t loadedCount = 0;

    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        const std::string path =
            cacheDir + "/orpheus_n3d_trk" + std::to_string(i) + ".wav";
        if (!generateN3dTrackWav(path, i, kN3dSampleRate, kN3dTestWavSeconds)) {
            lastError_ = "generate N3D track WAV failed";
            errorCode_.store(1, std::memory_order_relaxed);
            return false;
        }
        if (!loadTrackFromPath(i, path, kN3dTapeStarts[i], kN3dLatencyOffsets[i])) {
            return false;
        }
        ++loadedCount;
    }

    ORPHEUS_LOGI("N3D test tracks loaded: %d", loadedCount);
    errorCode_.store(0, std::memory_order_relaxed);
    return loadedCount == kN3dTrackCount;
}

void MixerEngine::closeOutputStream() {
    isPlaying_.store(0, std::memory_order_release);
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
    }
    outputOpened_.store(0, std::memory_order_relaxed);
}

void MixerEngine::noteOpenFailure(oboe::Result result, const char* label) {
    lastOpenErrorCode_.store(static_cast<int32_t>(result), std::memory_order_relaxed);
    ORPHEUS_LOGE("%s failed: %s", label, oboe::convertToText(result));
}

bool MixerEngine::openOutputStream(const oboe::SharingMode sharing) {
    closeOutputStream();

    exclusiveAttempted_.store(
        sharing == oboe::SharingMode::Exclusive ? 1 : 0,
        std::memory_order_relaxed);

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(kN3dSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);

    const oboe::Result openResult = builder.openStream(outputStream_);
    if (openResult != oboe::Result::OK) {
        noteOpenFailure(openResult, "N3D open output");
        lastError_ = std::string("open output failed: ") + oboe::convertToText(openResult);
        return false;
    }

    const oboe::Result startResult = outputStream_->requestStart();
    if (startResult != oboe::Result::OK) {
        noteOpenFailure(startResult, "N3D start output");
        lastError_ = std::string("start output failed: ") + oboe::convertToText(startResult);
        outputStream_->close();
        outputStream_.reset();
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    outputOpened_.store(1, std::memory_order_release);
    ORPHEUS_LOGI(
        "N3D output open: rate=%d burst=%d buf=%d",
        outputStream_->getSampleRate(),
        outputStream_->getFramesPerBurst(),
        outputStream_->getBufferSizeInFrames());
    return true;
}

bool MixerEngine::openStreams() {
    lastError_.clear();
    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    lastOpenErrorCode_.store(0, std::memory_order_relaxed);

    if (countTracksLoaded() < kN3dTrackCount) {
        lastError_ = "load test tracks before openStreams";
        return false;
    }

    if (openOutputStream(oboe::SharingMode::Exclusive)) {
        return true;
    }
    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    sharedFallbackUsed_.store(1, std::memory_order_relaxed);
    if (openOutputStream(oboe::SharingMode::Shared)) {
        ORPHEUS_LOGI("N3D: Exclusive failed, using Shared");
        return true;
    }
    return false;
}

bool MixerEngine::startMix(const int64_t startSample) {
    if (outputOpened_.load(std::memory_order_acquire) != 1) {
        lastError_ = "output stream not open";
        return false;
    }
    if (countTracksLoaded() < kN3dTrackCount) {
        lastError_ = "not all tracks loaded";
        return false;
    }

    const int64_t tapeLen = tapeLengthSamples_.load(std::memory_order_relaxed);
    const int64_t clampedStart = std::max<int64_t>(0, std::min(startSample, tapeLen));

    transportStartSample_.store(clampedStart, std::memory_order_relaxed);
    transportStopSample_.store(tapeLen, std::memory_order_relaxed);
    currentTransportSample_.store(clampedStart, std::memory_order_relaxed);
    playbackComplete_.store(0, std::memory_order_relaxed);
    playbackCompleteLogged_.store(0, std::memory_order_relaxed);
    isPlaying_.store(1, std::memory_order_release);

    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        tracks_[i].framesMixed.store(0, std::memory_order_relaxed);
    }

    ORPHEUS_LOGI(
        "N3D mix start sample=%lld stop=%lld",
        static_cast<long long>(clampedStart),
        static_cast<long long>(tapeLen));
    return true;
}

void MixerEngine::stopMix() {
    isPlaying_.store(0, std::memory_order_release);
    playbackComplete_.store(0, std::memory_order_relaxed);
    ORPHEUS_LOGI(
        "N3D mix stopped transport=%lld",
        static_cast<long long>(
            currentTransportSample_.load(std::memory_order_relaxed)));
}

bool MixerEngine::setTrackGain(const int32_t trackIndex, const float gain) {
    if (trackIndex < 0 || trackIndex >= kN3dTrackCount) {
        return false;
    }
    const float clamped = std::max(0.0f, std::min(gain, 2.0f));
    tracks_[trackIndex].gainTimes1000.store(
        static_cast<int32_t>(clamped * 1000.0f), std::memory_order_relaxed);
    return true;
}

bool MixerEngine::setTrackMute(const int32_t trackIndex, const int32_t muted) {
    if (trackIndex < 0 || trackIndex >= kN3dTrackCount) {
        return false;
    }
    tracks_[trackIndex].muted.store(muted != 0 ? 1 : 0, std::memory_order_relaxed);
    return true;
}

bool MixerEngine::setTrackSolo(const int32_t trackIndex, const int32_t solo) {
    if (trackIndex < 0 || trackIndex >= kN3dTrackCount) {
        return false;
    }
    tracks_[trackIndex].solo.store(solo != 0 ? 1 : 0, std::memory_order_relaxed);
    return true;
}

int32_t MixerEngine::countTracksLoaded() const {
    int32_t count = 0;
    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        if (tracks_[i].loaded.load(std::memory_order_acquire) == 1) {
            ++count;
        }
    }
    return count;
}

int32_t MixerEngine::countTracksActiveAt(const int64_t transportSample) const {
    int32_t count = 0;
    const bool anySolo = tracks_[0].solo.load(std::memory_order_relaxed) == 1 ||
                         tracks_[1].solo.load(std::memory_order_relaxed) == 1 ||
                         tracks_[2].solo.load(std::memory_order_relaxed) == 1 ||
                         tracks_[3].solo.load(std::memory_order_relaxed) == 1;

    for (int32_t t = 0; t < kN3dTrackCount; ++t) {
        if (tracks_[t].loaded.load(std::memory_order_relaxed) != 1) {
            continue;
        }
        if (tracks_[t].muted.load(std::memory_order_relaxed) == 1) {
            continue;
        }
        if (anySolo && tracks_[t].solo.load(std::memory_order_relaxed) != 1) {
            continue;
        }
        const int64_t eff =
            tracks_[t].effectiveTapeStartSample.load(std::memory_order_relaxed);
        if (transportSample < eff) {
            continue;
        }
        const int64_t pos = transportSample - eff;
        if (pos < static_cast<int64_t>(tracks_[t].frameCount)) {
            ++count;
        }
    }
    return count;
}

void MixerEngine::handleOutputFrames(float* data, const int32_t numFrames) {
    outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    const bool playing = isPlaying_.load(std::memory_order_acquire) == 1;
    int64_t pos = currentTransportSample_.load(std::memory_order_relaxed);
    const int64_t stop = transportStopSample_.load(std::memory_order_relaxed);

    if (!playing) {
        std::memset(data, 0, static_cast<size_t>(numFrames) * sizeof(float));
        return;
    }

    const bool anySolo =
        tracks_[0].solo.load(std::memory_order_relaxed) == 1 ||
        tracks_[1].solo.load(std::memory_order_relaxed) == 1 ||
        tracks_[2].solo.load(std::memory_order_relaxed) == 1 ||
        tracks_[3].solo.load(std::memory_order_relaxed) == 1;

    for (int32_t i = 0; i < numFrames; ++i) {
        float mix = 0.0f;

        if (pos < stop) {
            for (int32_t t = 0; t < kN3dTrackCount; ++t) {
                TrackSlot& slot = tracks_[t];
                if (slot.loaded.load(std::memory_order_relaxed) != 1) {
                    continue;
                }
                if (slot.muted.load(std::memory_order_relaxed) == 1) {
                    continue;
                }
                if (anySolo && slot.solo.load(std::memory_order_relaxed) != 1) {
                    continue;
                }

                const int64_t eff =
                    slot.effectiveTapeStartSample.load(std::memory_order_relaxed);
                if (pos < eff) {
                    continue;
                }

                const int64_t trackPos = pos - eff;
                const size_t frameCount = slot.frameCount;
                if (trackPos < 0 ||
                    static_cast<size_t>(trackPos) >= frameCount) {
                    continue;
                }

                const float* pcm = slot.pcmData;
                if (pcm == nullptr) {
                    continue;
                }

                const float gain =
                    slot.gainTimes1000.load(std::memory_order_relaxed) / 1000.0f;
                mix += pcm[static_cast<size_t>(trackPos)] * gain;
                slot.framesMixed.fetch_add(1, std::memory_order_relaxed);
            }
        }

        if (mix > 1.0f) {
            mix = 1.0f;
        } else if (mix < -1.0f) {
            mix = -1.0f;
        }

        data[i] = mix;

        ++pos;
        if (pos >= stop && playing) {
            isPlaying_.store(0, std::memory_order_release);
            playbackComplete_.store(1, std::memory_order_release);
            if (playbackCompleteLogged_.exchange(1, std::memory_order_acq_rel) == 0) {
                ORPHEUS_LOGI(
                    "N3D complete: transport=%lld callbacks=%lld xruns pending",
                    static_cast<long long>(pos),
                    static_cast<long long>(outputCallbackCount_.load(
                        std::memory_order_relaxed)));
            }
        }
    }

    currentTransportSample_.store(pos, std::memory_order_release);
}

int64_t MixerEngine::getTransportSample() const {
    return currentTransportSample_.load(std::memory_order_acquire);
}

bool MixerEngine::isPlaybackComplete() const {
    return playbackComplete_.load(std::memory_order_acquire) == 1;
}

void MixerEngine::fillDiagnostics(OrpheusN3MixerDiagnostics* out) const {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3MixerDiagnostics{};

    out->sampleRate = sampleRate_.load(std::memory_order_relaxed);
    out->outputStreamOpened = outputOpened_.load(std::memory_order_relaxed);
    out->tracksLoaded = countTracksLoaded();
    out->playbackComplete = playbackComplete_.load(std::memory_order_relaxed);
    out->isPlaying = isPlaying_.load(std::memory_order_relaxed);
    out->errorCode = errorCode_.load(std::memory_order_relaxed);
    out->exclusiveAttempted = exclusiveAttempted_.load(std::memory_order_relaxed);
    out->sharedFallbackUsed = sharedFallbackUsed_.load(std::memory_order_relaxed);

    const int64_t transport =
        currentTransportSample_.load(std::memory_order_relaxed);
    out->currentTransportSample = transport;
    out->transportStartSample =
        transportStartSample_.load(std::memory_order_relaxed);
    out->transportStopSample = transportStopSample_.load(std::memory_order_relaxed);
    out->outputCallbackCount = outputCallbackCount_.load(std::memory_order_relaxed);
    out->tracksActive = countTracksActiveAt(transport);

    int32_t soloActive = 0;
    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        if (tracks_[i].solo.load(std::memory_order_relaxed) == 1) {
            soloActive = 1;
            break;
        }
    }
    out->soloActive = soloActive;

    out->track0GainTimes1000 = tracks_[0].gainTimes1000.load(std::memory_order_relaxed);
    out->track1GainTimes1000 = tracks_[1].gainTimes1000.load(std::memory_order_relaxed);
    out->track2GainTimes1000 = tracks_[2].gainTimes1000.load(std::memory_order_relaxed);
    out->track3GainTimes1000 = tracks_[3].gainTimes1000.load(std::memory_order_relaxed);
    out->track0Muted = tracks_[0].muted.load(std::memory_order_relaxed);
    out->track1Muted = tracks_[1].muted.load(std::memory_order_relaxed);
    out->track2Muted = tracks_[2].muted.load(std::memory_order_relaxed);
    out->track3Muted = tracks_[3].muted.load(std::memory_order_relaxed);
    out->track0Solo = tracks_[0].solo.load(std::memory_order_relaxed);
    out->track1Solo = tracks_[1].solo.load(std::memory_order_relaxed);
    out->track2Solo = tracks_[2].solo.load(std::memory_order_relaxed);
    out->track3Solo = tracks_[3].solo.load(std::memory_order_relaxed);

    out->track0StartSample = tracks_[0].tapeStartSample.load(std::memory_order_relaxed);
    out->track1StartSample = tracks_[1].tapeStartSample.load(std::memory_order_relaxed);
    out->track2StartSample = tracks_[2].tapeStartSample.load(std::memory_order_relaxed);
    out->track3StartSample = tracks_[3].tapeStartSample.load(std::memory_order_relaxed);
    out->track0EffectiveStartSample =
        tracks_[0].effectiveTapeStartSample.load(std::memory_order_relaxed);
    out->track1EffectiveStartSample =
        tracks_[1].effectiveTapeStartSample.load(std::memory_order_relaxed);
    out->track2EffectiveStartSample =
        tracks_[2].effectiveTapeStartSample.load(std::memory_order_relaxed);
    out->track3EffectiveStartSample =
        tracks_[3].effectiveTapeStartSample.load(std::memory_order_relaxed);
    out->track0FramesMixed = tracks_[0].framesMixed.load(std::memory_order_relaxed);
    out->track1FramesMixed = tracks_[1].framesMixed.load(std::memory_order_relaxed);
    out->track2FramesMixed = tracks_[2].framesMixed.load(std::memory_order_relaxed);
    out->track3FramesMixed = tracks_[3].framesMixed.load(std::memory_order_relaxed);

    if (outputStream_) {
        out->framesPerBurst = outputStream_->getFramesPerBurst();
        out->bufferSizeInFrames = outputStream_->getBufferSizeInFrames();
        out->xRunCount = readXRunCount(outputStream_.get());
        out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
        out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
        out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
    }
}

void MixerEngine::shutdown() {
    stopMix();
    closeOutputStream();
    for (int32_t i = 0; i < kN3dTrackCount; ++i) {
        tracks_[i].pcm.clear();
        tracks_[i].pcmData = nullptr;
        tracks_[i].frameCount = 0;
        tracks_[i].loaded.store(0, std::memory_order_relaxed);
        tracks_[i].framesMixed.store(0, std::memory_order_relaxed);
    }
    cacheDir_.clear();
    currentTransportSample_.store(0, std::memory_order_relaxed);
    outputCallbackCount_.store(0, std::memory_order_relaxed);
    playbackCompleteLogged_.store(0, std::memory_order_relaxed);
}

}  // namespace orpheus
