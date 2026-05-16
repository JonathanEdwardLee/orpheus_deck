#include "oboe_engine.h"

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

void cacheStreamProperties(oboe::AudioStream* stream,
                           std::atomic<int32_t>* framesPerBurst,
                           std::atomic<int32_t>* bufferSize,
                           std::atomic<int32_t>* performanceMode,
                           std::atomic<int32_t>* sharingMode,
                           std::atomic<int32_t>* apiUsed,
                           std::atomic<int32_t>* xRunCount) {
    if (stream == nullptr) {
        return;
    }
    framesPerBurst->store(stream->getFramesPerBurst(), std::memory_order_relaxed);
    bufferSize->store(stream->getBufferSizeInFrames(), std::memory_order_relaxed);
    performanceMode->store(oboeModeToInt(stream->getPerformanceMode()),
                           std::memory_order_relaxed);
    sharingMode->store(oboeSharingToInt(stream->getSharingMode()),
                       std::memory_order_relaxed);
    apiUsed->store(oboeApiToInt(stream->getAudioApi()), std::memory_order_relaxed);
    xRunCount->store(readXRunCount(stream), std::memory_order_relaxed);
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
    engine->outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);
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
    engine->inputCallbackCount_.fetch_add(1, std::memory_order_relaxed);
    return oboe::DataCallbackResult::Continue;
}

bool OboeEngine::init() {
    lastError_.clear();
  const int32_t rate = kPreferredSampleRate;
    sampleRate_.store(rate, std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * kCaptureRingSeconds));
    captureScratch_.resize(static_cast<size_t>(rate), 0.0f);

    workerRunning_.store(true, std::memory_order_release);
    workerStopRequested_.store(false, std::memory_order_release);
    workerFinalizePending_.store(false, std::memory_order_release);
    workerThread_ = std::thread([this]() { recordWorkerLoop(); });

    ORPHEUS_LOGI("OboeEngine init (ring %zu samples @ %d Hz)",
                 captureRing_.available() + static_cast<size_t>(rate * kCaptureRingSeconds),
                 rate);
    return true;
}

bool OboeEngine::openOutputStream(bool exclusive) {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(exclusive ? oboe::SharingMode::Exclusive
                                   : oboe::SharingMode::Shared)
        ->setSampleRate(kPreferredSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);

    oboe::Result result = builder.openStream(outputStream_);
    if (result != oboe::Result::OK) {
        lastError_ = std::string("open output failed: ") + oboe::convertToText(result);
        ORPHEUS_LOGE("%s", lastError_.c_str());
        return false;
    }

    result = outputStream_->requestStart();
    if (result != oboe::Result::OK) {
        lastError_ = std::string("start output failed: ") + oboe::convertToText(result);
        ORPHEUS_LOGE("%s", lastError_.c_str());
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    cacheStreamProperties(outputStream_.get(),
                          &cachedFramesPerBurst_,
                          &cachedBufferSize_,
                          &cachedPerformanceMode_,
                          &cachedSharingMode_,
                          &cachedApiUsed_,
                          &cachedXRunCount_);
    outputOpened_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("Output stream open: rate=%d burst=%d buf=%d api=%d sharing=%d",
                 outputStream_->getSampleRate(),
                 outputStream_->getFramesPerBurst(),
                 outputStream_->getBufferSizeInFrames(),
                 oboeApiToInt(outputStream_->getAudioApi()),
                 oboeSharingToInt(outputStream_->getSharingMode()));
    return true;
}

bool OboeEngine::openInputStream(bool exclusive) {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(exclusive ? oboe::SharingMode::Exclusive
                                   : oboe::SharingMode::Shared)
        ->setSampleRate(sampleRate_.load(std::memory_order_relaxed))
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&inputCallback_);

    oboe::Result result = builder.openStream(inputStream_);
    if (result != oboe::Result::OK) {
        lastError_ = std::string("open input failed: ") + oboe::convertToText(result);
        ORPHEUS_LOGE("%s", lastError_.c_str());
        return false;
    }

    result = inputStream_->requestStart();
    if (result != oboe::Result::OK) {
        lastError_ = std::string("start input failed: ") + oboe::convertToText(result);
        ORPHEUS_LOGE("%s", lastError_.c_str());
        return false;
    }

    cacheStreamProperties(inputStream_.get(),
                          &cachedFramesPerBurst_,
                          &cachedBufferSize_,
                          &cachedPerformanceMode_,
                          &cachedSharingMode_,
                          &cachedApiUsed_,
                          &cachedXRunCount_);
    inputOpened_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("Input stream open: rate=%d burst=%d buf=%d api=%d sharing=%d",
                 inputStream_->getSampleRate(),
                 inputStream_->getFramesPerBurst(),
                 inputStream_->getBufferSizeInFrames(),
                 oboeApiToInt(inputStream_->getAudioApi()),
                 oboeSharingToInt(inputStream_->getSharingMode()));
    return true;
}

bool OboeEngine::openStreams() {
    lastError_.clear();
    wavWriteSuccess_.store(false, std::memory_order_relaxed);
    usedExclusiveSharing_.store(true, std::memory_order_relaxed);

    if (!openOutputStream(true)) {
        ORPHEUS_LOGI("Retrying output with Shared sharing mode");
        usedExclusiveSharing_.store(false, std::memory_order_relaxed);
        if (!openOutputStream(false)) {
            return false;
        }
    }

    if (!openInputStream(usedExclusiveSharing_.load(std::memory_order_relaxed))) {
        ORPHEUS_LOGI("Retrying input with Shared sharing mode");
        if (inputStream_) {
            inputStream_->stop();
            inputStream_->close();
            inputStream_.reset();
        }
        inputOpened_.store(false, std::memory_order_relaxed);
        if (!openInputStream(false)) {
            return false;
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

    out->sampleRate = sampleRate_.load(std::memory_order_relaxed);
    out->framesPerBurst = cachedFramesPerBurst_.load(std::memory_order_relaxed);
    out->bufferSizeInFrames = cachedBufferSize_.load(std::memory_order_relaxed);
    out->xRunCount = cachedXRunCount_.load(std::memory_order_relaxed);
    out->performanceMode = cachedPerformanceMode_.load(std::memory_order_relaxed);
    out->sharingMode = cachedSharingMode_.load(std::memory_order_relaxed);
    out->apiUsed = cachedApiUsed_.load(std::memory_order_relaxed);
    out->inputStreamOpened =
        inputOpened_.load(std::memory_order_relaxed) ? 1 : 0;
    out->outputStreamOpened =
        outputOpened_.load(std::memory_order_relaxed) ? 1 : 0;
    out->wavWriteSuccess =
        wavWriteSuccess_.load(std::memory_order_relaxed) ? 1 : 0;

    if (outputStream_) {
        out->xRunCount = readXRunCount(outputStream_.get());
        out->framesPerBurst = outputStream_->getFramesPerBurst();
        out->bufferSizeInFrames = outputStream_->getBufferSizeInFrames();
        out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
        out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
        out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
        out->sampleRate = outputStream_->getSampleRate();
    }
}

void OboeEngine::shutdown() {
    recording_.store(false, std::memory_order_release);
    workerStopRequested_.store(true, std::memory_order_release);
    workerRunning_.store(false, std::memory_order_release);
    if (workerThread_.joinable()) {
        workerThread_.join();
    }

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
    impulseFramesLeft_.store(0, std::memory_order_relaxed);
    ORPHEUS_LOGI("OboeEngine shutdown");
}

}  // namespace orpheus
