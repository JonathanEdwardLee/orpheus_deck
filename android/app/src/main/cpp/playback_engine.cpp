#include "playback_engine.h"

#include <android/api-level.h>
#include <android/log.h>
#include <algorithm>
#include <cstring>
#include <string>

#include "wav_reader.h"
#include "wav_test_tone.h"

#define ORPHEUS_LOG_TAG "OrpheusN3B"
#define ORPHEUS_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, ORPHEUS_LOG_TAG, __VA_ARGS__)
#define ORPHEUS_LOGI(...) __android_log_print(ANDROID_LOG_INFO, ORPHEUS_LOG_TAG, __VA_ARGS__)

namespace orpheus {

namespace {

constexpr int64_t kN3bTestWavFrames = 48000LL * 8LL;
constexpr uint32_t kN3bTestPcm16DataBytes =
    static_cast<uint32_t>(kN3bTestWavFrames * 2u);

}  // namespace

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

}  // namespace

oboe::DataCallbackResult PlaybackOutputCallback::onAudioReady(
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

bool PlaybackEngine::init() {
    lastError_.clear();
    errorCode_.store(0, std::memory_order_relaxed);
    sampleRate_.store(kN3PreferredSampleRate, std::memory_order_relaxed);
    return true;
}

bool PlaybackEngine::generateTestWav(const std::string& path) {
    if (!generateN3bTestWav(path, kN3PreferredSampleRate, 8)) {
        lastError_ = "generate N3B test WAV failed";
        errorCode_.store(1, std::memory_order_relaxed);
        return false;
    }
    ORPHEUS_LOGI("N3B test WAV generated: %s", path.c_str());
    return loadWav(path);
}

bool PlaybackEngine::loadWav(const std::string& path) {
    wavLoadSuccess_.store(0, std::memory_order_relaxed);
    pcmSamples_.clear();
    pcmData_ = nullptr;
    pcmFrameCount_ = 0;

    const WavLoadResult loaded = loadMonoWav(path, kN3PreferredSampleRate);
    if (!loaded.success) {
        lastError_ = "WAV load failed (code " + std::to_string(loaded.errorCode) + ")";
        errorCode_.store(loaded.errorCode, std::memory_order_relaxed);
        wavSampleRate_.store(loaded.sampleRate, std::memory_order_relaxed);
        return false;
    }

    pcmSamples_ = std::move(loaded.samples);
    pcmData_ = pcmSamples_.data();
    pcmFrameCount_ = pcmSamples_.size();
    loadedPath_ = path;

    wavLoadSuccess_.store(1, std::memory_order_relaxed);
    wavSampleRate_.store(loaded.sampleRate, std::memory_order_relaxed);
    wavChannels_.store(loaded.channels, std::memory_order_relaxed);
    wavTotalFrames_.store(loaded.frameCount, std::memory_order_relaxed);
    playbackStopSample_.store(loaded.frameCount, std::memory_order_relaxed);
    errorCode_.store(0, std::memory_order_relaxed);

    ORPHEUS_LOGI(
        "N3B WAV loaded: sampleRate=%d channels=%d totalFrames=%lld "
        "dataBytes=%u path=%s",
        loaded.sampleRate,
        loaded.channels,
        static_cast<long long>(loaded.frameCount),
        loaded.dataBytes,
        path.c_str());

    if (loaded.sampleRate == kN3PreferredSampleRate &&
        loaded.channels == 1 &&
        loaded.frameCount == kN3bTestWavFrames &&
        loaded.dataBytes == kN3bTestPcm16DataBytes) {
        ORPHEUS_LOGI(
            "N3B test WAV sanity OK: 8.0 s @ 48 kHz mono PCM16 (~%u file bytes "
            "with header)",
            loaded.dataBytes + 44u);
    } else if (path.find("orpheus_n3b_test") != std::string::npos) {
        ORPHEUS_LOGE(
            "N3B test WAV sanity FAIL: expected rate=%d ch=1 frames=%lld "
            "dataBytes=%u got rate=%d frames=%lld dataBytes=%u",
            kN3PreferredSampleRate,
            static_cast<long long>(kN3bTestWavFrames),
            kN3bTestPcm16DataBytes,
            loaded.sampleRate,
            static_cast<long long>(loaded.frameCount),
            loaded.dataBytes);
    }
    return true;
}

void PlaybackEngine::closeOutputStream() {
    isPlaying_.store(0, std::memory_order_release);
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
    }
    outputOpened_.store(0, std::memory_order_relaxed);
}

void PlaybackEngine::noteOpenFailure(oboe::Result result, const char* label) {
    lastOpenErrorCode_.store(static_cast<int32_t>(result), std::memory_order_relaxed);
    ORPHEUS_LOGE("%s failed: %s", label, oboe::convertToText(result));
}

bool PlaybackEngine::openOutputStream(const oboe::SharingMode sharing) {
    closeOutputStream();

    exclusiveAttempted_.store(
        sharing == oboe::SharingMode::Exclusive ? 1 : 0,
        std::memory_order_relaxed);

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(kN3PreferredSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);

    const oboe::Result openResult = builder.openStream(outputStream_);
    if (openResult != oboe::Result::OK) {
        noteOpenFailure(openResult, "N3B open output");
        lastError_ = std::string("open output failed: ") + oboe::convertToText(openResult);
        return false;
    }

    const oboe::Result startResult = outputStream_->requestStart();
    if (startResult != oboe::Result::OK) {
        noteOpenFailure(startResult, "N3B start output");
        lastError_ = std::string("start output failed: ") + oboe::convertToText(startResult);
        outputStream_->close();
        outputStream_.reset();
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    outputOpened_.store(1, std::memory_order_release);
    ORPHEUS_LOGI(
        "N3B output open: rate=%d burst=%d buf=%d api=%d sharing=%d",
        outputStream_->getSampleRate(),
        outputStream_->getFramesPerBurst(),
        outputStream_->getBufferSizeInFrames(),
        oboeApiToInt(outputStream_->getAudioApi()),
        oboeSharingToInt(outputStream_->getSharingMode()));
    return true;
}

bool PlaybackEngine::openStreams() {
    lastError_.clear();
    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    lastOpenErrorCode_.store(0, std::memory_order_relaxed);

    if (wavLoadSuccess_.load(std::memory_order_acquire) != 1) {
        lastError_ = "load WAV before openStreams";
        return false;
    }

    if (openOutputStream(oboe::SharingMode::Exclusive)) {
        return true;
    }
    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    sharedFallbackUsed_.store(1, std::memory_order_relaxed);
    if (openOutputStream(oboe::SharingMode::Shared)) {
        ORPHEUS_LOGI("N3B: Exclusive failed, using Shared");
        return true;
    }
    return false;
}

bool PlaybackEngine::startPlayback(const int64_t startSample) {
    if (wavLoadSuccess_.load(std::memory_order_acquire) != 1) {
        lastError_ = "no WAV loaded";
        return false;
    }
    if (outputOpened_.load(std::memory_order_acquire) != 1) {
        lastError_ = "output stream not open";
        return false;
    }

    const int64_t total = wavTotalFrames_.load(std::memory_order_relaxed);
    const int64_t clampedStart = std::max<int64_t>(0, std::min(startSample, total));

    playbackStartSample_.store(clampedStart, std::memory_order_relaxed);
    playbackStopSample_.store(total, std::memory_order_relaxed);
    currentTransportSample_.store(clampedStart, std::memory_order_relaxed);
    playbackComplete_.store(0, std::memory_order_relaxed);
    playbackCompleteLogged_.store(0, std::memory_order_relaxed);
    isPlaying_.store(1, std::memory_order_release);

    ORPHEUS_LOGI(
        "N3B playback start sample=%lld (total=%lld)",
        static_cast<long long>(clampedStart),
        static_cast<long long>(total));
    return true;
}

void PlaybackEngine::stopPlayback() {
    isPlaying_.store(0, std::memory_order_release);
    playbackComplete_.store(0, std::memory_order_relaxed);
    ORPHEUS_LOGI("N3B playback stopped at sample=%lld",
                 static_cast<long long>(
                     currentTransportSample_.load(std::memory_order_relaxed)));
}

void PlaybackEngine::handleOutputFrames(float* data, const int32_t numFrames) {
    outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    const bool playing = isPlaying_.load(std::memory_order_acquire) == 1;
    const float* pcm = pcmData_;
    const size_t total = pcmFrameCount_;
    int64_t pos = currentTransportSample_.load(std::memory_order_relaxed);
    const int64_t stop = playbackStopSample_.load(std::memory_order_relaxed);

    if (!playing || pcm == nullptr || total == 0) {
        std::memset(data, 0, static_cast<size_t>(numFrames) * sizeof(float));
        return;
    }

    for (int32_t i = 0; i < numFrames; ++i) {
        if (pos < stop && static_cast<size_t>(pos) < total) {
            data[i] = pcm[static_cast<size_t>(pos)];
            ++pos;
        } else {
            data[i] = 0.0f;
            if (playing) {
                isPlaying_.store(0, std::memory_order_release);
                playbackComplete_.store(1, std::memory_order_release);
                if (playbackCompleteLogged_.exchange(1, std::memory_order_acq_rel) ==
                    0) {
                    ORPHEUS_LOGI(
                        "N3B complete: startSample=%lld stopSample=%lld "
                        "currentTransportSample=%lld outputCallbackCount=%lld",
                        static_cast<long long>(playbackStartSample_.load(
                            std::memory_order_relaxed)),
                        static_cast<long long>(stop),
                        static_cast<long long>(pos),
                        static_cast<long long>(outputCallbackCount_.load(
                            std::memory_order_relaxed)));
                }
            }
        }
    }

    currentTransportSample_.store(pos, std::memory_order_release);
}

int64_t PlaybackEngine::getTransportSample() const {
    return currentTransportSample_.load(std::memory_order_acquire);
}

bool PlaybackEngine::isPlaybackComplete() const {
    return playbackComplete_.load(std::memory_order_acquire) == 1;
}

void PlaybackEngine::fillDiagnostics(OrpheusN3PlaybackDiagnostics* out) const {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3PlaybackDiagnostics{};

    out->sampleRate = sampleRate_.load(std::memory_order_relaxed);
    out->wavLoadSuccess = wavLoadSuccess_.load(std::memory_order_relaxed);
    out->wavSampleRate = wavSampleRate_.load(std::memory_order_relaxed);
    out->wavChannels = wavChannels_.load(std::memory_order_relaxed);
    out->playbackComplete = playbackComplete_.load(std::memory_order_relaxed);
    out->isPlaying = isPlaying_.load(std::memory_order_relaxed);
    out->errorCode = errorCode_.load(std::memory_order_relaxed);
    out->exclusiveAttempted = exclusiveAttempted_.load(std::memory_order_relaxed);
    out->sharedFallbackUsed = sharedFallbackUsed_.load(std::memory_order_relaxed);
    out->outputStreamOpened = outputOpened_.load(std::memory_order_relaxed);

    out->wavTotalFrames = wavTotalFrames_.load(std::memory_order_relaxed);
    out->playbackStartSample = playbackStartSample_.load(std::memory_order_relaxed);
    out->playbackStopSample = playbackStopSample_.load(std::memory_order_relaxed);
    out->currentTransportSample = currentTransportSample_.load(std::memory_order_relaxed);
    out->outputCallbackCount = outputCallbackCount_.load(std::memory_order_relaxed);

    if (outputStream_) {
        out->framesPerBurst = outputStream_->getFramesPerBurst();
        out->bufferSizeInFrames = outputStream_->getBufferSizeInFrames();
        out->xRunCount = readXRunCount(outputStream_.get());
        out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
        out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
        out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
    }
}

void PlaybackEngine::shutdown() {
    stopPlayback();
    closeOutputStream();
    pcmSamples_.clear();
    pcmData_ = nullptr;
    pcmFrameCount_ = 0;
    loadedPath_.clear();
    wavLoadSuccess_.store(0, std::memory_order_relaxed);
    wavTotalFrames_.store(0, std::memory_order_relaxed);
    currentTransportSample_.store(0, std::memory_order_relaxed);
    outputCallbackCount_.store(0, std::memory_order_relaxed);
    playbackCompleteLogged_.store(0, std::memory_order_relaxed);
}

}  // namespace orpheus
