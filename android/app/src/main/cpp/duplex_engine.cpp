#include "duplex_engine.h"

#include <android/api-level.h>
#include <android/log.h>
#include <algorithm>
#include <chrono>
#include <cstring>

#include "click_backing.h"

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

}  // namespace

oboe::DataCallbackResult DuplexOutputCallback::onAudioReady(oboe::AudioStream* stream,
                                                          void* audioData,
                                                          int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    if (!engine->duplexActive_.load(std::memory_order_acquire)) {
        std::memset(audioData, 0, static_cast<size_t>(numFrames) * sizeof(float));
        return oboe::DataCallbackResult::Continue;
    }
    engine->handleOutputFrames(static_cast<float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

oboe::DataCallbackResult DuplexInputCallback::onAudioReady(oboe::AudioStream* stream,
                                                          void* audioData,
                                                          int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    if (!engine->duplexActive_.load(std::memory_order_acquire)) {
        return oboe::DataCallbackResult::Continue;
    }
    engine->handleInputFrames(static_cast<const float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

bool DuplexEngine::init() {
    lastError_.clear();
    androidSdkVersion_.store(android_get_device_api_level(),
                             std::memory_order_relaxed);
    sampleRate_.store(kDuplexSampleRate, std::memory_order_relaxed);
    prepareBacking();

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 10));
    captureScratch_.resize(static_cast<size_t>(rate), 0.0f);

    if (!workerRunning_.load(std::memory_order_acquire)) {
        workerRunning_.store(true, std::memory_order_release);
        workerFinalizePending_.store(false, std::memory_order_release);
        workerThread_ = std::thread([this]() { recordWorkerLoop(); });
    }

    ORPHEUS_LOGI(
        "DuplexEngine init: backing=%lld frames (%d clicks / %d s @ %d Hz), API %d",
        static_cast<long long>(backingFramesGenerated_.load(std::memory_order_relaxed)),
        kDuplexClickCount,
        kDuplexDurationSeconds,
        rate,
        androidSdkVersion_.load(std::memory_order_relaxed));
    return true;
}

void DuplexEngine::prepareBacking() {
    backing_ = generateClickBacking(kDuplexSampleRate,
                                    kDuplexClickCount,
                                    kDuplexDurationSeconds);
    backingFramesGenerated_.store(static_cast<int64_t>(backing_.size()),
                                std::memory_order_relaxed);
}

void DuplexEngine::closeStreams() {
    duplexActive_.store(false, std::memory_order_release);

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

void DuplexEngine::noteOpenFailure(const oboe::Result result, const char* label) {
    lastOpenErrorCode_.store(static_cast<int32_t>(result), std::memory_order_relaxed);
    ORPHEUS_LOGE("N2 %s failed: %s (%d)", label, oboe::convertToText(result),
                 static_cast<int32_t>(result));
}

bool DuplexEngine::openOutputStream(const oboe::SharingMode sharing) {
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
        outputOpened_.store(false, std::memory_order_relaxed);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(kDuplexSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);

    oboe::Result result = builder.openStream(outputStream_);
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "N2 open output");
        lastError_ = std::string("N2 open output failed: ") + oboe::convertToText(result);
        return false;
    }

    result = outputStream_->requestStart();
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "N2 start output");
        lastError_ = std::string("N2 start output failed: ") + oboe::convertToText(result);
        outputStream_->close();
        outputStream_.reset();
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    outputOpened_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("N2 output open: api=%d sharing=%d rate=%d",
                 oboeApiToInt(outputStream_->getAudioApi()),
                 oboeSharingToInt(outputStream_->getSharingMode()),
                 outputStream_->getSampleRate());
    return true;
}

bool DuplexEngine::openInputStream(const oboe::SharingMode sharing) {
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
        noteOpenFailure(result, "N2 open input");
        lastError_ = std::string("N2 open input failed: ") + oboe::convertToText(result);
        return false;
    }

    result = inputStream_->requestStart();
    if (result != oboe::Result::OK) {
        noteOpenFailure(result, "N2 start input");
        lastError_ = std::string("N2 start input failed: ") + oboe::convertToText(result);
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    inputOpened_.store(true, std::memory_order_release);
    ORPHEUS_LOGI("N2 input open: api=%d sharing=%d rate=%d",
                 oboeApiToInt(inputStream_->getAudioApi()),
                 oboeSharingToInt(inputStream_->getSharingMode()),
                 inputStream_->getSampleRate());
    return true;
}

bool DuplexEngine::openStreams() {
    lastError_.clear();
    closeStreams();

    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    lastOpenErrorCode_.store(0, std::memory_order_relaxed);
    duplexComplete_.store(false, std::memory_order_relaxed);

    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    if (!openOutputStream(oboe::SharingMode::Exclusive)) {
        sharedFallbackUsed_.store(1, std::memory_order_relaxed);
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
            if (!openInputStream(oboe::SharingMode::Shared)) {
                return false;
            }
        } else {
            return false;
        }
    }

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 10));
    return true;
}

bool DuplexEngine::startDuplex(const std::string& recordWavPath) {
    if (recordWavPath.empty()) {
        lastError_ = "N2 null record path";
        return false;
    }
    if (!outputOpened_.load(std::memory_order_acquire) ||
        !inputOpened_.load(std::memory_order_acquire)) {
        lastError_ = "N2 streams not open";
        return false;
    }
    if (duplexActive_.load(std::memory_order_acquire)) {
        lastError_ = "N2 duplex already running";
        return false;
    }

    recordWavPath_ = recordWavPath;
    prepareBacking();

    wavWriteSuccess_.store(false, std::memory_order_relaxed);
    backingPlaySuccess_.store(false, std::memory_order_relaxed);
    recordSuccess_.store(false, std::memory_order_relaxed);
    duplexComplete_.store(false, std::memory_order_relaxed);
    workerFinalizePending_.store(false, std::memory_order_release);

    recordedFramesWritten_.store(0, std::memory_order_relaxed);
    outputCallbackCount_.store(0, std::memory_order_relaxed);
    inputCallbackCount_.store(0, std::memory_order_relaxed);
    firstOutputFrameSample_.store(-1, std::memory_order_relaxed);
    firstInputFrameSample_.store(-1, std::memory_order_relaxed);

    transportFrame_.store(0, std::memory_order_relaxed);
    transportStartSample_.store(0, std::memory_order_relaxed);
    transportStopSample_.store(0, std::memory_order_relaxed);

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 10));

    duplexActive_.store(true, std::memory_order_release);
    backingPlaySuccess_.store(true, std::memory_order_relaxed);
    recordSuccess_.store(true, std::memory_order_relaxed);

    ORPHEUS_LOGI("N2 duplex start -> %s (backing %lld samples)",
                 recordWavPath.c_str(),
                 static_cast<long long>(backingFramesGenerated_.load(
                     std::memory_order_relaxed)));
    return true;
}

bool DuplexEngine::isComplete() const {
    return duplexComplete_.load(std::memory_order_acquire) &&
           wavWriteSuccess_.load(std::memory_order_acquire);
}

void DuplexEngine::markDuplexComplete() {
    if (duplexComplete_.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    duplexActive_.store(false, std::memory_order_release);
    transportStopSample_.store(transportFrame_.load(std::memory_order_relaxed),
                               std::memory_order_relaxed);
    workerFinalizePending_.store(true, std::memory_order_release);

    ORPHEUS_LOGI(
        "N2 duplex complete: transport %lld..%lld, recorded %lld, outCb=%lld inCb=%lld",
        static_cast<long long>(transportStartSample_.load(std::memory_order_relaxed)),
        static_cast<long long>(transportStopSample_.load(std::memory_order_relaxed)),
        static_cast<long long>(recordedFramesWritten_.load(std::memory_order_relaxed)),
        static_cast<long long>(outputCallbackCount_.load(std::memory_order_relaxed)),
        static_cast<long long>(inputCallbackCount_.load(std::memory_order_relaxed)));
}

void DuplexEngine::handleOutputFrames(float* data, const int32_t numFrames) {
    outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    const int64_t transportAtStart = transportFrame_.load(std::memory_order_relaxed);
    if (firstOutputFrameSample_.load(std::memory_order_relaxed) < 0) {
        firstOutputFrameSample_.store(transportAtStart, std::memory_order_relaxed);
    }

    const int64_t backingLen = backingFramesGenerated_.load(std::memory_order_relaxed);
    const int64_t pos = transportAtStart;

    for (int32_t i = 0; i < numFrames; ++i) {
        const int64_t frameIndex = pos + i;
        data[i] = (frameIndex >= 0 && static_cast<size_t>(frameIndex) < backing_.size())
                      ? backing_[static_cast<size_t>(frameIndex)]
                      : 0.0f;
    }

    const int64_t newTransport = pos + numFrames;
    transportFrame_.store(newTransport, std::memory_order_release);

    if (newTransport >= backingLen) {
        markDuplexComplete();
    }
}

void DuplexEngine::handleInputFrames(const float* data, const int32_t numFrames) {
    inputCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    const int64_t transportNow = transportFrame_.load(std::memory_order_relaxed);
    if (firstInputFrameSample_.load(std::memory_order_relaxed) < 0) {
        firstInputFrameSample_.store(transportNow, std::memory_order_relaxed);
    }

    const size_t written = captureRing_.write(data, static_cast<size_t>(numFrames));
    recordedFramesWritten_.fetch_add(static_cast<int64_t>(written),
                                   std::memory_order_relaxed);
}

void DuplexEngine::finalizeWavFromRing() {
    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    std::vector<float> samples;
    samples.reserve(static_cast<size_t>(rate * 10));

    size_t chunk = 0;
    do {
        chunk = captureRing_.read(captureScratch_.data(), captureScratch_.size());
        if (chunk > 0) {
            samples.insert(samples.end(),
                           captureScratch_.begin(),
                           captureScratch_.begin() + static_cast<std::ptrdiff_t>(chunk));
        }
    } while (chunk > 0);

    const bool ok = wavWriter_.writeMonoPcm16(recordWavPath_, samples, rate);
    wavWriteSuccess_.store(ok, std::memory_order_release);
    ORPHEUS_LOGI("N2 WAV finalize: %s (%zu samples) ok=%d",
                 recordWavPath_.c_str(),
                 samples.size(),
                 ok ? 1 : 0);
    if (!ok) {
        lastError_ = "N2 wav write failed";
    }
}

void DuplexEngine::recordWorkerLoop() {
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

void DuplexEngine::fillDiagnostics(OrpheusDuplexDiagnostics* out) const {
    if (out == nullptr) {
        return;
    }
    std::memset(out, 0, sizeof(OrpheusDuplexDiagnostics));

    out->sampleRate = sampleRate_.load(std::memory_order_relaxed);
    out->backingFramesGenerated =
        backingFramesGenerated_.load(std::memory_order_relaxed);
    out->recordedFramesWritten =
        recordedFramesWritten_.load(std::memory_order_relaxed);
    out->transportStartSample =
        transportStartSample_.load(std::memory_order_relaxed);
    out->transportStopSample =
        transportStopSample_.load(std::memory_order_relaxed);
    out->outputCallbackCount =
        outputCallbackCount_.load(std::memory_order_relaxed);
    out->inputCallbackCount =
        inputCallbackCount_.load(std::memory_order_relaxed);
    out->firstOutputFrameSample =
        firstOutputFrameSample_.load(std::memory_order_relaxed);
    out->firstInputFrameSample =
        firstInputFrameSample_.load(std::memory_order_relaxed);

    const int64_t outFirst = out->firstOutputFrameSample;
    const int64_t inFirst = out->firstInputFrameSample;
    if (outFirst >= 0 && inFirst >= 0) {
        out->estimatedInputOutputDeltaSamples = inFirst - outFirst;
    } else {
        out->estimatedInputOutputDeltaSamples = -1;
    }

    out->exclusiveAttempted =
        exclusiveAttempted_.load(std::memory_order_relaxed);
    out->sharedFallbackUsed =
        sharedFallbackUsed_.load(std::memory_order_relaxed);
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
    out->backingPlaySuccess =
        backingPlaySuccess_.load(std::memory_order_relaxed) ? 1 : 0;
    out->recordSuccess =
        recordSuccess_.load(std::memory_order_relaxed) ? 1 : 0;

    if (outputStream_) {
        out->framesPerBurst = outputStream_->getFramesPerBurst();
        out->bufferSizeInFrames = outputStream_->getBufferSizeInFrames();
        out->xRunCount = readXRunCount(outputStream_.get());
        out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
        out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
        out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
        out->sampleRate = outputStream_->getSampleRate();
    }
}

void DuplexEngine::shutdown() {
    duplexActive_.store(false, std::memory_order_release);
    workerFinalizePending_.store(false, std::memory_order_release);
    workerRunning_.store(false, std::memory_order_release);
    if (workerThread_.joinable()) {
        workerThread_.join();
    }
    closeStreams();
    ORPHEUS_LOGI("DuplexEngine shutdown");
}

}  // namespace orpheus
