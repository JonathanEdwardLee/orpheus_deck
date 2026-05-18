#include "overdub_engine.h"

#include <android/api-level.h>
#include <android/log.h>
#include <algorithm>
#include <chrono>
#include <cstring>

#include "wav_reader.h"
#include "wav_test_tone.h"

#define ORPHEUS_LOG_TAG "OrpheusN3C"
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

int32_t sumXRuns(oboe::AudioStream* out, oboe::AudioStream* in) {
    return readXRunCount(out) + readXRunCount(in);
}

}  // namespace

oboe::DataCallbackResult OverdubOutputCallback::onAudioReady(oboe::AudioStream* stream,
                                                            void* audioData,
                                                            int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    if (!engine->overdubActive_.load(std::memory_order_acquire)) {
        std::memset(audioData, 0, static_cast<size_t>(numFrames) * sizeof(float));
        return oboe::DataCallbackResult::Continue;
    }
    engine->handleOutputFrames(static_cast<float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

oboe::DataCallbackResult OverdubInputCallback::onAudioReady(oboe::AudioStream* stream,
                                                           void* audioData,
                                                           int32_t numFrames) {
    (void)stream;
    auto* engine = engine_;
    if (engine == nullptr || audioData == nullptr || numFrames <= 0) {
        return oboe::DataCallbackResult::Stop;
    }
    if (!engine->overdubActive_.load(std::memory_order_acquire)) {
        return oboe::DataCallbackResult::Continue;
    }
    engine->handleInputFrames(static_cast<const float*>(audioData), numFrames);
    return oboe::DataCallbackResult::Continue;
}

bool OverdubEngine::init() {
    lastError_.clear();
    errorCode_.store(0, std::memory_order_relaxed);
    sampleRate_.store(kN3cSampleRate, std::memory_order_relaxed);
    defaultRecordLatencyOffsetSamples_.store(kN3cDevDefaultRecordLatencyOffsetSamples,
                                             std::memory_order_relaxed);

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 12));
    captureScratch_.resize(static_cast<size_t>(rate), 0.0f);

    if (!workerRunning_.load(std::memory_order_acquire)) {
        workerRunning_.store(true, std::memory_order_release);
        workerFinalizePending_.store(false, std::memory_order_release);
        workerThread_ = std::thread([this]() { recordWorkerLoop(); });
    }

    ORPHEUS_LOGI("N3C OverdubEngine init @ %d Hz (dev default latency offset %lld)",
                 rate,
                 static_cast<long long>(defaultRecordLatencyOffsetSamples_.load(
                     std::memory_order_relaxed)));
    return true;
}

bool OverdubEngine::generateAndLoadBackingWav(const std::string& path) {
    if (!generateN3bTestWav(path, kN3cSampleRate, 8)) {
        lastError_ = "N3C generate backing WAV failed";
        errorCode_.store(1, std::memory_order_relaxed);
        return false;
    }
    return loadBackingWav(path);
}

bool OverdubEngine::loadBackingWav(const std::string& path) {
    backingWavLoadSuccess_.store(0, std::memory_order_relaxed);
    backing_.clear();
    backingData_ = nullptr;
    backingFrameCount_ = 0;

    const WavLoadResult loaded = loadMonoWav(path, kN3cSampleRate);
    if (!loaded.success) {
        lastError_ = "N3C backing WAV load failed";
        errorCode_.store(loaded.errorCode, std::memory_order_relaxed);
        return false;
    }

    backing_ = std::move(loaded.samples);
    backingData_ = backing_.data();
    backingFrameCount_ = backing_.size();
    backingPath_ = path;

    backingWavLoadSuccess_.store(1, std::memory_order_relaxed);
    backingWavTotalFrames_.store(loaded.frameCount, std::memory_order_relaxed);
    errorCode_.store(0, std::memory_order_relaxed);

    ORPHEUS_LOGI(
        "N3C backing loaded: rate=%d frames=%lld dataBytes=%u path=%s",
        loaded.sampleRate,
        static_cast<long long>(loaded.frameCount),
        loaded.dataBytes,
        path.c_str());
    return true;
}

void OverdubEngine::setDefaultRecordLatencyOffsetSamples(const int64_t offsetSamples) {
    defaultRecordLatencyOffsetSamples_.store(offsetSamples, std::memory_order_relaxed);
    ORPHEUS_LOGI("N3C defaultRecordLatencyOffsetSamples=%lld (dev only)",
                 static_cast<long long>(offsetSamples));
}

void OverdubEngine::closeStreams() {
    overdubActive_.store(false, std::memory_order_release);

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

    inputOpened_.store(0, std::memory_order_relaxed);
    outputOpened_.store(0, std::memory_order_relaxed);
}

void OverdubEngine::noteOpenFailure(const oboe::Result result, const char* label) {
    lastOpenErrorCode_.store(static_cast<int32_t>(result), std::memory_order_relaxed);
    ORPHEUS_LOGE("N3C %s failed: %s", label, oboe::convertToText(result));
}

bool OverdubEngine::openOutputStream(const oboe::SharingMode sharing) {
    if (outputStream_) {
        outputStream_->stop();
        outputStream_->close();
        outputStream_.reset();
        outputOpened_.store(0, std::memory_order_relaxed);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(kN3cSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&outputCallback_);

    const oboe::Result openResult = builder.openStream(outputStream_);
    if (openResult != oboe::Result::OK) {
        noteOpenFailure(openResult, "open output");
        lastError_ = std::string("N3C open output failed: ") + oboe::convertToText(openResult);
        return false;
    }

    const oboe::Result startResult = outputStream_->requestStart();
    if (startResult != oboe::Result::OK) {
        noteOpenFailure(startResult, "start output");
        lastError_ = std::string("N3C start output failed: ") + oboe::convertToText(startResult);
        outputStream_->close();
        outputStream_.reset();
        return false;
    }

    sampleRate_.store(outputStream_->getSampleRate(), std::memory_order_relaxed);
    outputOpened_.store(1, std::memory_order_release);
    return true;
}

bool OverdubEngine::openInputStream(const oboe::SharingMode sharing) {
    if (inputStream_) {
        inputStream_->stop();
        inputStream_->close();
        inputStream_.reset();
        inputOpened_.store(0, std::memory_order_relaxed);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(sharing)
        ->setSampleRate(sampleRate_.load(std::memory_order_relaxed))
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::Float)
        ->setCallback(&inputCallback_);

    const oboe::Result openResult = builder.openStream(inputStream_);
    if (openResult != oboe::Result::OK) {
        noteOpenFailure(openResult, "open input");
        lastError_ = std::string("N3C open input failed: ") + oboe::convertToText(openResult);
        return false;
    }

    const oboe::Result startResult = inputStream_->requestStart();
    if (startResult != oboe::Result::OK) {
        noteOpenFailure(startResult, "start input");
        lastError_ = std::string("N3C start input failed: ") + oboe::convertToText(startResult);
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    inputOpened_.store(1, std::memory_order_release);
    return true;
}

bool OverdubEngine::openStreamsRecordOnly() {
    lastError_.clear();
    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    recordOnlyMode_.store(1, std::memory_order_relaxed);

    if (openOutputStream(oboe::SharingMode::Exclusive) &&
        openInputStream(oboe::SharingMode::Exclusive)) {
        ORPHEUS_LOGI("N3C record-only streams open (Exclusive)");
        return true;
    }

    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    sharedFallbackUsed_.store(1, std::memory_order_relaxed);
    closeStreams();

    if (openOutputStream(oboe::SharingMode::Shared) &&
        openInputStream(oboe::SharingMode::Shared)) {
        ORPHEUS_LOGI("N3C record-only streams open (Shared fallback)");
        return true;
    }
    return false;
}

bool OverdubEngine::openStreams() {
    lastError_.clear();
    exclusiveAttempted_.store(0, std::memory_order_relaxed);
    sharedFallbackUsed_.store(0, std::memory_order_relaxed);
    recordOnlyMode_.store(0, std::memory_order_relaxed);

    if (backingWavLoadSuccess_.load(std::memory_order_acquire) != 1) {
        lastError_ = "N3C load backing WAV before openStreams";
        return false;
    }

    if (openOutputStream(oboe::SharingMode::Exclusive) &&
        openInputStream(oboe::SharingMode::Exclusive)) {
        ORPHEUS_LOGI("N3C streams open (Exclusive)");
        return true;
    }

    exclusiveAttempted_.store(1, std::memory_order_relaxed);
    sharedFallbackUsed_.store(1, std::memory_order_relaxed);
    closeStreams();

    if (openOutputStream(oboe::SharingMode::Shared) &&
        openInputStream(oboe::SharingMode::Shared)) {
        ORPHEUS_LOGI("N3C streams open (Shared fallback)");
        return true;
    }
    return false;
}

int32_t OverdubEngine::clicksExpectedForSession() const {
    const int64_t start = backingStartSample_.load(std::memory_order_relaxed);
    const int64_t stop = transportStopSample_.load(std::memory_order_relaxed);
    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    if (rate <= 0 || stop <= start) {
        return 8;
    }
    const int64_t frames = stop - start;
    int32_t clicks = static_cast<int32_t>((frames + rate - 1) / rate);
    return std::max(1, std::min(clicks, 8));
}

bool OverdubEngine::startOverdub(const std::string& recordWavPath,
                                 const int64_t backingStartSample) {
    if (recordWavPath.empty()) {
        lastError_ = "N3C null record path";
        return false;
    }
    if (!outputOpened_.load(std::memory_order_acquire) ||
        !inputOpened_.load(std::memory_order_acquire)) {
        lastError_ = "N3C streams not open";
        return false;
    }
    if (backingWavLoadSuccess_.load(std::memory_order_acquire) != 1) {
        lastError_ = "N3C backing not loaded";
        return false;
    }

    const int64_t total = backingWavTotalFrames_.load(std::memory_order_relaxed);
    const int64_t start = std::max<int64_t>(0, std::min(backingStartSample, total));
    const int64_t latencyOffset =
        defaultRecordLatencyOffsetSamples_.load(std::memory_order_relaxed);
    const int64_t effective = start - latencyOffset;

    recordWavPath_ = recordWavPath;
    backingStartSample_.store(start, std::memory_order_relaxed);
    recordStartSample_.store(start, std::memory_order_relaxed);
    effectiveRecordStartSample_.store(effective, std::memory_order_relaxed);
    currentTransportSample_.store(start, std::memory_order_relaxed);
    transportStopSample_.store(total, std::memory_order_relaxed);

    wavWriteSuccess_.store(0, std::memory_order_relaxed);
    playbackComplete_.store(0, std::memory_order_relaxed);
    recordSuccess_.store(0, std::memory_order_relaxed);
    overdubComplete_.store(0, std::memory_order_relaxed);
    analysisComplete_.store(0, std::memory_order_relaxed);
    timingResult_ = TimingAnalysisResult{};
    workerFinalizePending_.store(0, std::memory_order_relaxed);

    recordedFramesWritten_.store(0, std::memory_order_relaxed);
    outputCallbackCount_.store(0, std::memory_order_relaxed);
    inputCallbackCount_.store(0, std::memory_order_relaxed);

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 12));

    overdubActive_.store(true, std::memory_order_release);
    recordSuccess_.store(1, std::memory_order_relaxed);

    ORPHEUS_LOGI(
        "N3C overdub start record=%s backingStart=%lld recordStart=%lld "
        "effectiveRecordStart=%lld stop=%lld latencyOffset=%lld",
        recordWavPath.c_str(),
        static_cast<long long>(start),
        static_cast<long long>(start),
        static_cast<long long>(effective),
        static_cast<long long>(total),
        static_cast<long long>(latencyOffset));
    return true;
}

bool OverdubEngine::startRecordOnly(const std::string& recordWavPath,
                                    const int64_t recordStartSample,
                                    const int64_t tapeLengthSamples) {
    if (recordWavPath.empty()) {
        lastError_ = "N3C null record path";
        return false;
    }
    if (!outputOpened_.load(std::memory_order_acquire) ||
        !inputOpened_.load(std::memory_order_acquire)) {
        lastError_ = "N3C streams not open";
        return false;
    }
    if (recordOnlyMode_.load(std::memory_order_acquire) != 1) {
        lastError_ = "N3C not in record-only mode";
        return false;
    }

    const int64_t tapeLen =
        tapeLengthSamples > 0 ? tapeLengthSamples : kN3cSampleRate * 60 * 15;
    const int64_t start = std::max<int64_t>(0, std::min(recordStartSample, tapeLen));
    const int64_t latencyOffset =
        defaultRecordLatencyOffsetSamples_.load(std::memory_order_relaxed);
    const int64_t effective = start - latencyOffset;

    recordWavPath_ = recordWavPath;
    backingStartSample_.store(start, std::memory_order_relaxed);
    recordStartSample_.store(start, std::memory_order_relaxed);
    effectiveRecordStartSample_.store(effective, std::memory_order_relaxed);
    currentTransportSample_.store(start, std::memory_order_relaxed);
    transportStopSample_.store(tapeLen, std::memory_order_relaxed);
    backingWavTotalFrames_.store(0, std::memory_order_relaxed);

    wavWriteSuccess_.store(0, std::memory_order_relaxed);
    playbackComplete_.store(0, std::memory_order_relaxed);
    recordSuccess_.store(0, std::memory_order_relaxed);
    overdubComplete_.store(0, std::memory_order_relaxed);
    analysisComplete_.store(0, std::memory_order_relaxed);
    timingResult_ = TimingAnalysisResult{};
    workerFinalizePending_.store(0, std::memory_order_relaxed);

    recordedFramesWritten_.store(0, std::memory_order_relaxed);
    outputCallbackCount_.store(0, std::memory_order_relaxed);
    inputCallbackCount_.store(0, std::memory_order_relaxed);

    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    captureRing_.reset(static_cast<size_t>(rate * 12));

    overdubActive_.store(true, std::memory_order_release);
    recordSuccess_.store(1, std::memory_order_relaxed);

    ORPHEUS_LOGI(
        "N3C record-only start record=%s start=%lld effective=%lld stop=%lld "
        "latencyOffset=%lld",
        recordWavPath.c_str(),
        static_cast<long long>(start),
        static_cast<long long>(effective),
        static_cast<long long>(tapeLen),
        static_cast<long long>(latencyOffset));
    return true;
}

void OverdubEngine::stopOverdub() {
    if (!overdubActive_.load(std::memory_order_acquire)) {
        return;
    }
    markOverdubComplete();
}

bool OverdubEngine::isComplete() const {
    return overdubComplete_.load(std::memory_order_acquire) &&
           wavWriteSuccess_.load(std::memory_order_acquire) &&
           analysisComplete_.load(std::memory_order_acquire);
}

void OverdubEngine::markOverdubComplete() {
    if (overdubComplete_.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    overdubActive_.store(false, std::memory_order_release);
    playbackComplete_.store(1, std::memory_order_release);
    transportStopSample_.store(
        currentTransportSample_.load(std::memory_order_relaxed),
        std::memory_order_relaxed);
    workerFinalizePending_.store(true, std::memory_order_release);

    ORPHEUS_LOGI(
        "N3C overdub complete: transport %lld..%lld recorded=%lld outCb=%lld inCb=%lld",
        static_cast<long long>(backingStartSample_.load(std::memory_order_relaxed)),
        static_cast<long long>(transportStopSample_.load(std::memory_order_relaxed)),
        static_cast<long long>(recordedFramesWritten_.load(std::memory_order_relaxed)),
        static_cast<long long>(outputCallbackCount_.load(std::memory_order_relaxed)),
        static_cast<long long>(inputCallbackCount_.load(std::memory_order_relaxed)));
}

void OverdubEngine::handleOutputFrames(float* data, const int32_t numFrames) {
    outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    int64_t pos = currentTransportSample_.load(std::memory_order_relaxed);
    const int64_t stop = transportStopSample_.load(std::memory_order_relaxed);

    if (recordOnlyMode_.load(std::memory_order_relaxed) == 1) {
        for (int32_t i = 0; i < numFrames; ++i) {
            data[i] = 0.0f;
            ++pos;
        }
    } else {
        const float* pcm = backingData_;
        const size_t total = backingFrameCount_;
        for (int32_t i = 0; i < numFrames; ++i) {
            if (pos < stop && static_cast<size_t>(pos) < total) {
                data[i] = pcm[static_cast<size_t>(pos)];
            } else {
                data[i] = 0.0f;
            }
            ++pos;
        }
    }

    currentTransportSample_.store(pos, std::memory_order_release);

    if (pos >= stop) {
        markOverdubComplete();
    }
}

void OverdubEngine::handleInputFrames(const float* data, const int32_t numFrames) {
    inputCallbackCount_.fetch_add(1, std::memory_order_relaxed);
    const size_t written = captureRing_.write(data, static_cast<size_t>(numFrames));
    recordedFramesWritten_.fetch_add(static_cast<int64_t>(written),
                                     std::memory_order_relaxed);
}

void OverdubEngine::finalizeWavFromRing() {
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
    wavWriteSuccess_.store(ok ? 1 : 0, std::memory_order_release);
    ORPHEUS_LOGI("N3C record WAV finalize: %s (%zu samples) ok=%d",
                 recordWavPath_.c_str(),
                 samples.size(),
                 ok ? 1 : 0);
    if (!ok) {
        lastError_ = "N3C wav write failed";
        errorCode_.store(2, std::memory_order_relaxed);
    }

    runTimingAnalysis(samples);
    analysisComplete_.store(true, std::memory_order_release);
}

void OverdubEngine::runTimingAnalysis(const std::vector<float>& recordedSamples) {
    const int32_t rate = sampleRate_.load(std::memory_order_relaxed);
    const int32_t clicksExpected = clicksExpectedForSession();
    timingResult_ = analyzeRecordedClickTiming(recordedSamples,
                                               rate,
                                               clicksExpected,
                                               kTimingSearchWindowSamples);

    const int64_t profileOffset =
        defaultRecordLatencyOffsetSamples_.load(std::memory_order_relaxed);
    const int64_t profileResidual = timingResult_.medianOffsetSamples - profileOffset;

    ORPHEUS_LOGI(
        "N3C timing: expected=%d detected=%d measured=%lld profile=%lld "
        "profileResidual=%lld selfResidual=%lld",
        timingResult_.clicksExpected,
        timingResult_.clicksDetected,
        static_cast<long long>(timingResult_.medianOffsetSamples),
        static_cast<long long>(profileOffset),
        static_cast<long long>(profileResidual),
        static_cast<long long>(timingResult_.compensatedMedianResidualSamples));
}

void OverdubEngine::recordWorkerLoop() {
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

void OverdubEngine::fillDiagnostics(OrpheusN3OverdubDiagnostics* out) const {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3OverdubDiagnostics{};

    out->sampleRate = sampleRate_.load(std::memory_order_relaxed);
    out->backingWavLoadSuccess = backingWavLoadSuccess_.load(std::memory_order_relaxed);
    out->inputStreamOpened = inputOpened_.load(std::memory_order_relaxed);
    out->outputStreamOpened = outputOpened_.load(std::memory_order_relaxed);
    out->wavWriteSuccess = wavWriteSuccess_.load(std::memory_order_relaxed);
    out->playbackComplete = playbackComplete_.load(std::memory_order_relaxed);
    out->recordSuccess = recordSuccess_.load(std::memory_order_relaxed);
    out->errorCode = errorCode_.load(std::memory_order_relaxed);
    out->exclusiveAttempted = exclusiveAttempted_.load(std::memory_order_relaxed);
    out->sharedFallbackUsed = sharedFallbackUsed_.load(std::memory_order_relaxed);

    out->analysisSuccess = timingResult_.analysisSuccess;
    out->compensatedAlignmentSuccess = timingResult_.compensatedAlignmentSuccess;
    out->clicksDetected = timingResult_.clicksDetected;
    out->clicksExpected = timingResult_.clicksExpected;
    out->confidencePercent = timingResult_.confidencePercent;
    out->medianOffsetMsTimes1000 = timingResult_.medianOffsetMsTimes1000;
    out->compensatedQualityPercent = timingResult_.compensatedQualityPercent;

    out->backingWavTotalFrames = backingWavTotalFrames_.load(std::memory_order_relaxed);
    out->backingStartSample = backingStartSample_.load(std::memory_order_relaxed);
    out->recordStartSample = recordStartSample_.load(std::memory_order_relaxed);
    out->defaultRecordLatencyOffsetSamples =
        defaultRecordLatencyOffsetSamples_.load(std::memory_order_relaxed);
    out->effectiveRecordStartSample =
        effectiveRecordStartSample_.load(std::memory_order_relaxed);
    out->recordedFramesWritten =
        recordedFramesWritten_.load(std::memory_order_relaxed);
    out->currentTransportSample =
        currentTransportSample_.load(std::memory_order_relaxed);
    out->transportStopSample = transportStopSample_.load(std::memory_order_relaxed);
    out->outputCallbackCount = outputCallbackCount_.load(std::memory_order_relaxed);
    out->inputCallbackCount = inputCallbackCount_.load(std::memory_order_relaxed);

    const int32_t rate = out->sampleRate > 0 ? out->sampleRate : kN3cSampleRate;
    const int64_t measuredMedian = timingResult_.medianOffsetSamples;
    const int64_t profileOffset = out->defaultRecordLatencyOffsetSamples;
    const int64_t profileResidual = measuredMedian - profileOffset;

    out->measuredMedianOffsetSamples = measuredMedian;
    out->measuredSelfResidualSamples =
        timingResult_.compensatedMedianResidualSamples;
    out->profileResidualSamples = profileResidual;
    out->profileResidualMsTimes1000 = static_cast<int32_t>(
        (profileResidual * 1000000LL) / static_cast<int64_t>(rate));

    const int64_t expectedRecorded =
        out->transportStopSample - out->recordStartSample;
    out->expectedRecordedFrames = expectedRecorded > 0 ? expectedRecorded : 0;
    const int64_t frameDelta =
        std::llabs(out->recordedFramesWritten - out->expectedRecordedFrames);
    out->recordedFramesSanity =
        frameDelta <= kN3cRecordedFramesSanitySamples ? 1 : 0;

    if (outputStream_ || inputStream_) {
        out->framesPerBurst = outputStream_
                                  ? outputStream_->getFramesPerBurst()
                                  : (inputStream_ ? inputStream_->getFramesPerBurst() : 0);
        out->bufferSizeInFrames = outputStream_
                                      ? outputStream_->getBufferSizeInFrames()
                                      : (inputStream_ ? inputStream_->getBufferSizeInFrames()
                                                       : 0);
        out->xRunCount = sumXRuns(outputStream_.get(), inputStream_.get());
        if (outputStream_) {
            out->apiUsed = oboeApiToInt(outputStream_->getAudioApi());
            out->performanceMode = oboeModeToInt(outputStream_->getPerformanceMode());
            out->sharingMode = oboeSharingToInt(outputStream_->getSharingMode());
        } else if (inputStream_) {
            out->apiUsed = oboeApiToInt(inputStream_->getAudioApi());
            out->performanceMode = oboeModeToInt(inputStream_->getPerformanceMode());
            out->sharingMode = oboeSharingToInt(inputStream_->getSharingMode());
        }
    }

    int32_t profileResult = 0;
    const int32_t minClicks =
        std::max(0, timingResult_.clicksExpected - 1);
    if (out->xRunCount == 0 && out->recordSuccess == 1 && out->wavWriteSuccess == 1 &&
        timingResult_.analysisSuccess == 1 &&
        timingResult_.clicksDetected >= minClicks) {
        const int64_t absResidual = std::llabs(profileResidual);
        if (absResidual <= kN3cProfilePassMaxResidualSamples) {
            profileResult = 2;
        } else if (absResidual <= kN3cProfileOkMaxResidualSamples) {
            profileResult = 1;
        }
    }
    out->profileCompensationResult = profileResult;
}

void OverdubEngine::shutdown() {
    stopOverdub();
    closeStreams();
    recordOnlyMode_.store(0, std::memory_order_relaxed);
    backing_.clear();
    backingData_ = nullptr;
    backingFrameCount_ = 0;
    backingWavLoadSuccess_.store(0, std::memory_order_relaxed);

    workerRunning_.store(false, std::memory_order_release);
    if (workerThread_.joinable()) {
        workerThread_.join();
    }
}

}  // namespace orpheus
