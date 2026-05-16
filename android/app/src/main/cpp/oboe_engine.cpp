#include "oboe_engine.h"

#include <android/api-level.h>
#include <android/log.h>
#include <algorithm>
#include <chrono>
#include <cstring>

#define ORPHEUS_LOG_TAG "OrpheusNative"
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

const char* apiName(oboe::AudioApi api) {
    switch (api) {
        case oboe::AudioApi::AAudio:
            return "AAudio";
        case oboe::AudioApi::OpenSLES:
            return "OpenSL ES";
        case oboe::AudioApi::Unspecified:
        default:
            return "Unspecified";
    }
}

const char* sharingName(oboe::SharingMode mode) {
    switch (mode) {
        case oboe::SharingMode::Exclusive:
            return "Exclusive";
        case oboe::SharingMode::Shared:
            return "Shared";
        default:
            return "Unknown";
    }
}

}  // namespace

oboe::DataCallbackResult OutputStreamCallback::onAudioReady(oboe::AudioStream* stream,
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

oboe::DataCallbackResult InputStreamCallback::onAudioReady(oboe::AudioStream* stream,
                                                           void* audioData,
                                                           int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    engine->handleInputFrames(static_cast<const float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

bool OboeEngine::init() {
    lastError_.clear();
    const int32_t rate = kPreferredSampleRate;
    sampleRate_.store(rate, std::memory_order_relaxed);
    requestedSampleRate_.store(rate, std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * kCaptureRingSeconds));
    captureScratch_.resize(static_cast<size_t>(rate), 0.0f);

    androidSdkVersion_.store(android_get_device_api_level(),
                             std::memory_order_relaxed);
    unspecifiedAudioApi_.store(1, std::memory_order_relaxed);

    if (!workerRunning_.load(std::memory_order_acquire)) {
        workerRunning_.store(true, std::memory_order_release);
        workerFinalizePending_.store(false, std::memory_order_release);
        workerThread_ = std::thread([this]() { recordWorkerLoop(); });
    }

    ORPHEUS_LOGI(
        "OboeEngine init: ring=%zu samples @ %d Hz, Android API %d "
        "(setAudioApi NOT called — Oboe Unspecified)",
        static_cast<size_t>(rate * kCaptureRingSeconds),
        rate,
        androidSdkVersion_.load(std::memory_order_relaxed));
    return true;
}

void OboeEngine::closeStreams() {
    recording_.store(false, std::memory_order_release);
    impulseFramesLeft_.store(0, std::memory_order_relaxed);

    if (inputStream_) {
        inputStream_->stop();
        inputStream_->close();
        inputStream_.reset();
    }
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
    }

    inputOpened_.store(false, std::memory_order_relaxed);
    outputOpened_.store(false, std::memory_order_relaxed);
}

void OboeEngine::noteOpenFailure(oboe::Result result, const char* label) {
    lastOpenErrorCode_.store(static_cast<int32_t>(result), std::memory_order_relaxed);
    ORPHEUS_LOGE("%s failed: %s (code %d)", label, oboe::convertToText(result),
                 static_cast<int32_t>(result));
}

bool OboeEngine::openOutputStream(oboe::SharingMode sharing) {
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
        outputOpened_.store(false, std::memory_order_relaxed);
    }

    requestedSharingMode_.store(oboeSharingToInt(sharing), std::memory_order_relaxed);
    requestedPerformanceMode_.store(
        oboeModeToInt(oboe::PerformanceMode::LowLatency), std::memory_order_relaxed);

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(kPreferredSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);
    // Do not call setAudioApi — Oboe picks AAudio when available (API 26+).

    oboe::Result result = builder.openStream(outputStream_);
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "open output");
        lastError_ = std::string("open output failed: ") + oboe::convertToText(result);
        return false;
    }

    result = outputStream_->requestStart();
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "start output");
        lastError_ = std::string("start output failed: ") + oboe::convertToText(result);
        outputStream_->close();
        outputStream_.reset();
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    outputOpened_.store(true, std::memory_order_release);

    ORPHEUS_LOGI(
        "Output open OK: rate=%d burst=%d buf=%d api=%s(%d) sharing=%s(%d) perf=%d",
        outputStream_->getSampleRate(),
        outputStream_->getFramesPerBurst(),
        outputStream_->getBufferSizeInFrames(),
        apiName(outputStream_->getAudioApi()),
        oboeApiToInt(outputStream_->getAudioApi()),
        sharingName(outputStream_->getSharingMode()),
        oboeSharingToInt(outputStream_->getSharingMode()),
        oboeModeToInt(outputStream_->getPerformanceMode()));
    return true;
}

bool OboeEngine::openInputStream(oboe::SharingMode sharing) {
    if (inputStream_) {
        inputStream_->stop();
        inputStream_->close();
        inputStream_.reset();
        inputOpened_.store(false, std::memory_order_relaxed);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(sampleRate_.load(std::memory_order_relaxed))
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&inputCallback_);

    oboe::Result result = builder.openStream(inputStream_);
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "open input");
        lastError_ = std::string("open input failed: ") + oboe::convertToText(result);
        return false;
    }

    result = inputStream_->requestStart();
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "start input");
        lastError_ = std::string("start input failed: ") + oboe::convertToText(result);
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    inputOpened_.store(true, std::memory_order_release);

    ORPHEUS_LOGI(
        "Input open OK: rate=%d burst=%d buf=%d api=%s(%d) sharing=%s(%d) perf=%d",
        inputStream_->getSampleRate(),
        inputStream_->getFramesPerBurst(),
        inputStream_->getBufferSizeInFrames(),
        apiName(inputStream_->getAudioApi()),
        oboeApiToInt(inputStream_->getAudioApi()),
        sharingName(inputStream_->getSharingMode()),
        oboeSharingToInt(inputStream_->getSharingMode()),
        oboeModeToInt(inputStream_->getPerformanceMode()));
    return true;
}

bool OboeEngine::openStreams() {
    lastError_.clear();
    closeStreams();

    wavWriteSuccess_.store(false, std::memory_order_relaxed);
    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    lastOpenErrorCode_.store(0, std::memory_order_relaxed);
    unspecifiedAudioApi_.store(1, std::memory_order_relaxed);

    const int32_t sdk = androidSdkVersion_.load(std::memory_order_relaxed);
    ORPHEUS_LOGI(
        "openStreams: Android API %d, AAudio available=%s, "
        "requesting 48 kHz LowLatency Exclusive (no setAudioApi)",
        sdk,
        sdk >= 26 ? "yes" : "no");

    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    if (!openOutputStream(oboe::SharingMode::Exclusive)) {
        sharedFallbackUsed_.store(1, std::memory_order_relaxed);
        ORPHEUS_LOGI("Retrying output with Shared sharing (last error %d)",
                     lastOpenErrorCode_.load(std::memory_order_relaxed));
        if (!openOutputStream(oboe::SharingMode::Shared)) {
            return false;
        }
    }

    const oboe::SharingMode inputSharing =
        sharedFallbackUsed_.load(std::memory_order_relaxed) != 0
            ? oboe::SharingMode::Shared
            : oboe::SharingMode::Exclusive;

    if (!openInputStream(inputSharing)) {
        if (inputSharing == oboe::SharingMode::Exclusive) {
            sharedFallbackUsed_.store(1, std::memory_order_relaxed);
            ORPHEUS_LOGI("Retrying input with Shared sharing (last error %d)",
                         lastOpenErrorCode_.load(std::memory_order_relaxed));
            if (!openInputStream(oboe::SharingMode::Shared)) {
                return false;
            }
        } else {
            return false;
        }
    }

    if (outputStream_) {
        const auto api = outputStream_->getAudioApi();
        if (api == oboe::AudioApi::OpenSLES) {
            ORPHEUS_LOGI(
                "Oboe selected OpenSL ES (not forced by Orpheus). "
                "Common on some devices for float duplex; see logcat above for "
                "Exclusive/Shared attempts. API %d supports AAudio=%s",
                sdk,
                sdk >= 26 ? "true" : "false");
        } else if (api == oboe::AudioApi::AAudio) {
            ORPHEUS_LOGI("Oboe selected AAudio");
        }
    }

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * kCaptureRingSeconds));
    return true;
}

bool OboeEngine::playImpulse() {
    if (!outputOpened_.load(std::memory_order_acquire)) {
        lastError_ = "output stream not open";
        return false;
    }
    impulseFramesLeft_.store(kImpulseBurstFrames, std::memory_order_release);
    ORPHEUS_LOGI("Scheduled %d-frame impulse burst", kImpulseBurstFrames);
    return true;
}

bool OboeEngine::startRecord(const std::string& wavPath, int32_t durationMs) {
    if (!inputOpened_.load(std::memory_order_acquire)) {
        lastError_ = "input stream not open";
        return false;
    }
    if (wavPath.empty() || durationMs <= 0) {
        lastError_ = "invalid record args";
        return false;
    }
    if (recording_.load(std::memory_order_acquire)) {
        lastError_ = "already recording";
        return false;
    }

    wavPath_ = wavPath;
    wavWriteSuccess_.store(false, std::memory_order_relaxed);
    recordedFrames_.store(0, std::memory_order_relaxed);
    workerFinalizePending_.store(false, std::memory_order_relaxed);

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    const int64_t target =
        static_cast<int64_t>(rate) * durationMs / 1000;
    recordTargetFrames_.store(target, std::memory_order_release);

    captureRing_.reset(static_cast<size_t>(rate * kCaptureRingSeconds));
    recording_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("Record start: %d ms (~%lld frames) -> %s",
                 durationMs,
                 static_cast<long long>(target),
                 wavPath.c_str());
    return true;
}

bool OboeEngine::stopRecord() {
    if (!recording_.load(std::memory_order_acquire)) {
        return true;
    }
    recording_.store(false, std::memory_order_release);
    workerFinalizePending_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("Record stop requested");
    return true;
}

void OboeEngine::handleOutputFrames(float* data, int32_t numFrames) {
    std::memset(data, 0, static_cast<size_t>(numFrames) * sizeof(float));
    int32_t left = impulseFramesLeft_.load(std::memory_order_acquire);
    if (left <= 0) {
        return;
    }
    const int32_t burst = std::min(left, numFrames);
    for (int32_t i = 0; i < burst; ++i) {
        data[i] = 0.85f;
    }
    impulseFramesLeft_.store(left - burst, std::memory_order_release);
}

void OboeEngine::handleInputFrames(const float* data, int32_t numFrames) {
    if (!recording_.load(std::memory_order_acquire)) {
        return;
    }

    captureRing_.write(data, static_cast<size_t>(numFrames));

    const int64_t prev = recordedFrames_.fetch_add(numFrames, std::memory_order_relaxed);
    const int64_t target = recordTargetFrames_.load(std::memory_order_relaxed);
    if (prev + numFrames >= target) {
        recording_.store(false, std::memory_order_release);
        workerFinalizePending_.store(true, std::memory_order_release);
    }
}

void OboeEngine::finalizeWavFromRing() {
    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    std::vector<float> samples;
    samples.reserve(static_cast<size_t>(rate * 3));

    size_t chunk = 0;
    do {
        chunk = captureRing_.read(captureScratch_.data(), captureScratch_.size());
        if (chunk > 0) {
            samples.insert(samples.end(),
                           captureScratch_.begin(),
                           captureScratch_.begin() + static_cast<std::ptrdiff_t>(chunk));
        }
    } while (chunk > 0);

    const bool ok = wavWriter_.writeMonoPcm16(wavPath_, samples, rate);
    wavWriteSuccess_.store(ok, std::memory_order_release);
    ORPHEUS_LOGI("WAV finalize: %s (%zu samples) success=%d",
                 wavPath_.c_str(),
                 samples.size(),
                 ok ? 1 : 0);
    if (!ok) {
        lastError_ = "wav write failed";
    }
}

void OboeEngine::recordWorkerLoop() {
    while (workerRunning_.load(std::memory_order_acquire)) {
        if (workerFinalizePending_.exchange(false, std::memory_order_acq_rel)) {
            finalizeWavFromRing();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (workerFinalizePending_.load(std::memory_order_acquire)) {
        finalizeWavFromRing();
    }
}

void OboeEngine::fillDiagnostics(OrpheusStreamDiagnostics* out) const {
    if (out == nullptr) {
        return;
    }
    std::memset(out, 0, sizeof(OrpheusStreamDiagnostics));

    out->requestedSampleRate =
        requestedSampleRate_.load(std::memory_order_relaxed);
    out->requestedSharingMode =
        requestedSharingMode_.load(std::memory_order_relaxed);
    out->requestedPerformanceMode =
        requestedPerformanceMode_.load(std::memory_order_relaxed);
    out->exclusiveAttempted =
        exclusiveAttempted_.load(std::memory_order_relaxed);
    out->sharedFallbackUsed =
        sharedFallbackUsed_.load(std::memory_order_relaxed);
    out->unspecifiedAudioApi =
        unspecifiedAudioApi_.load(std::memory_order_relaxed);
    out->lastOpenErrorCode =
        lastOpenErrorCode_.load(std::memory_order_relaxed);
    out->androidSdkVersion =
        androidSdkVersion_.load(std::memory_order_relaxed);

    out->inputStreamOpened =
        inputOpened_.load(std::memory_order_relaxed) ? 1 : 0;
    out->outputStreamOpened =
        outputOpened_.load(std::memory_order_relaxed) ? 1 : 0;
    out->wavWriteSuccess =
        wavWriteSuccess_.load(std::memory_order_relaxed) ? 1 : 0;

    if (outputStream_) {
        out->actualSampleRate = outputStream_->getSampleRate();
        out->sampleRate = out->actualSampleRate;
        out->framesPerBurst = outputStream_->getFramesPerBurst();
        out->bufferSizeInFrames = outputStream_->getBufferSizeInFrames();
        out->xRunCount = readXRunCount(outputStream_.get());
        out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
        out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
        out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
        out->actualPerformanceMode = out->performanceMode;
        out->actualSharingMode = out->sharingMode;
    } else {
        out->actualSampleRate = sampleRate_.load(std::memory_order_relaxed);
        out->sampleRate = out->actualSampleRate;
    }
}

void OboeEngine::shutdown() {
    recording_.store(false, std::memory_order_release);
    workerFinalizePending_.store(false, std::memory_order_release);
    workerRunning_.store(false, std::memory_order_release);
    if (workerThread_.joinable()) {
        workerThread_.join();
    }

    closeStreams();
    ORPHEUS_LOGI("OboeEngine shutdown");
}

}  // namespace orpheus
