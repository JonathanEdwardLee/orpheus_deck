#include "native_engine.h"

#include <memory>
#include <mutex>
#include <string>

#include "duplex_engine.h"
#include "oboe_engine.h"
#include "overdub_engine.h"
#include "playback_engine.h"

namespace {

std::unique_ptr<orpheus::OboeEngine> gEngine;
std::unique_ptr<orpheus::DuplexEngine> gDuplexEngine;
std::unique_ptr<orpheus::PlaybackEngine> gPlaybackEngine;
std::unique_ptr<orpheus::OverdubEngine> gOverdubEngine;
std::string gLastError;
/** Only for last_error string lifetime — not used in audio callbacks. */
std::mutex gErrorMutex;

void setError(const std::string& msg) {
    std::lock_guard<std::mutex> lock(gErrorMutex);
    gLastError = msg;
}

}  // namespace

extern "C" {

int32_t orpheus_native_init(void) {
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
    if (gPlaybackEngine) {
        gPlaybackEngine->shutdown();
        gPlaybackEngine.reset();
    }
    if (gEngine) {
        gEngine->shutdown();
        gEngine.reset();
    }
    gEngine = std::make_unique<orpheus::OboeEngine>();
    if (!gEngine->init()) {
        setError(gEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_open_streams(void) {
    if (!gEngine) {
        setError("engine not initialized");
        return -1;
    }
    if (!gEngine->openStreams()) {
        setError(gEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_play_impulse(void) {
    if (!gEngine) {
        setError("engine not initialized");
        return -1;
    }
    if (!gEngine->playImpulse()) {
        setError(gEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_start_record(const char* wav_path, int32_t duration_ms) {
    if (!gEngine) {
        setError("engine not initialized");
        return -1;
    }
    if (wav_path == nullptr) {
        setError("null wav path");
        return -1;
    }
    if (!gEngine->startRecord(std::string(wav_path), duration_ms)) {
        setError(gEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_stop_record(void) {
    if (!gEngine) {
        setError("engine not initialized");
        return -1;
    }
    if (!gEngine->stopRecord()) {
        setError(gEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_native_get_diagnostics(OrpheusStreamDiagnostics* out) {
    if (gEngine && out != nullptr) {
        gEngine->fillDiagnostics(out);
    }
}

void orpheus_native_shutdown(void) {
    if (gEngine) {
        gEngine->shutdown();
        gEngine.reset();
    }
}

int32_t orpheus_native_n2_init(void) {
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
    if (gPlaybackEngine) {
        gPlaybackEngine->shutdown();
        gPlaybackEngine.reset();
    }
    if (gDuplexEngine) {
        gDuplexEngine->shutdown();
        gDuplexEngine.reset();
    }
    if (gEngine) {
        gEngine->shutdown();
        gEngine.reset();
    }
    gDuplexEngine = std::make_unique<orpheus::DuplexEngine>();
    if (!gDuplexEngine->init()) {
        setError(gDuplexEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_n2_open_streams(void) {
    if (!gDuplexEngine) {
        setError("N2 engine not initialized");
        return -1;
    }
    if (!gDuplexEngine->openStreams()) {
        setError(gDuplexEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_n2_start_duplex(const char* record_wav_path) {
    if (!gDuplexEngine) {
        setError("N2 engine not initialized");
        return -1;
    }
    if (record_wav_path == nullptr) {
        setError("N2 null record path");
        return -1;
    }
    if (!gDuplexEngine->startDuplex(std::string(record_wav_path))) {
        setError(gDuplexEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_native_n2_is_complete(void) {
    if (!gDuplexEngine) {
        return 0;
    }
    return gDuplexEngine->isComplete() ? 1 : 0;
}

void orpheus_native_n2_get_diagnostics(OrpheusDuplexDiagnostics* out) {
    if (gDuplexEngine && out != nullptr) {
        gDuplexEngine->fillDiagnostics(out);
    }
}

void orpheus_native_n2_shutdown(void) {
    if (gDuplexEngine) {
        gDuplexEngine->shutdown();
        gDuplexEngine.reset();
    }
}

static void shutdownAllExceptOverdub() {
    if (gEngine) {
        gEngine->shutdown();
        gEngine.reset();
    }
    if (gDuplexEngine) {
        gDuplexEngine->shutdown();
        gDuplexEngine.reset();
    }
    if (gPlaybackEngine) {
        gPlaybackEngine->shutdown();
        gPlaybackEngine.reset();
    }
}

static void shutdownOtherEnginesForN3() {
    shutdownAllExceptOverdub();
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
}

int32_t orpheus_n3_init(void) {
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
    if (gDuplexEngine) {
        gDuplexEngine->shutdown();
        gDuplexEngine.reset();
    }
    if (gEngine) {
        gEngine->shutdown();
        gEngine.reset();
    }
    if (gPlaybackEngine) {
        gPlaybackEngine->shutdown();
        gPlaybackEngine.reset();
    }
    gPlaybackEngine = std::make_unique<orpheus::PlaybackEngine>();
    if (!gPlaybackEngine->init()) {
        setError(gPlaybackEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3_generate_test_wav(const char* path) {
    if (!gPlaybackEngine) {
        setError("N3 engine not initialized");
        return -1;
    }
    if (path == nullptr) {
        setError("N3 null wav path");
        return -1;
    }
    if (!gPlaybackEngine->generateTestWav(std::string(path))) {
        setError(gPlaybackEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3_load_wav(const char* path) {
    if (!gPlaybackEngine) {
        setError("N3 engine not initialized");
        return -1;
    }
    if (path == nullptr) {
        setError("N3 null wav path");
        return -1;
    }
    if (!gPlaybackEngine->loadWav(std::string(path))) {
        setError(gPlaybackEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3_open_streams(void) {
    if (!gPlaybackEngine) {
        setError("N3 engine not initialized");
        return -1;
    }
    if (!gPlaybackEngine->openStreams()) {
        setError(gPlaybackEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3_start_playback(const int64_t start_sample) {
    if (!gPlaybackEngine) {
        setError("N3 engine not initialized");
        return -1;
    }
    if (!gPlaybackEngine->startPlayback(start_sample)) {
        setError(gPlaybackEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_n3_stop_playback(void) {
    if (gPlaybackEngine) {
        gPlaybackEngine->stopPlayback();
    }
}

int64_t orpheus_n3_get_transport_sample(void) {
    if (!gPlaybackEngine) {
        return 0;
    }
    return gPlaybackEngine->getTransportSample();
}

int32_t orpheus_n3_is_playback_complete(void) {
    if (!gPlaybackEngine) {
        return 0;
    }
    return gPlaybackEngine->isPlaybackComplete() ? 1 : 0;
}

void orpheus_n3_get_diagnostics(OrpheusN3PlaybackDiagnostics* out) {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3PlaybackDiagnostics{};
    if (gPlaybackEngine) {
        gPlaybackEngine->fillDiagnostics(out);
    }
}

void orpheus_n3_shutdown(void) {
    if (gPlaybackEngine) {
        gPlaybackEngine->shutdown();
        gPlaybackEngine.reset();
    }
}

int32_t orpheus_n3c_init(void) {
    shutdownOtherEnginesForN3();
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
    gOverdubEngine = std::make_unique<orpheus::OverdubEngine>();
    if (!gOverdubEngine->init()) {
        setError(gOverdubEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3c_generate_backing_wav(const char* backing_path) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    if (backing_path == nullptr) {
        setError("N3C null backing path");
        return -1;
    }
    if (!gOverdubEngine->generateAndLoadBackingWav(std::string(backing_path))) {
        setError(gOverdubEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3c_set_default_record_latency_offset_samples(
    const int64_t offset_samples) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    gOverdubEngine->setDefaultRecordLatencyOffsetSamples(offset_samples);
    return 0;
}

int32_t orpheus_n3c_open_streams(void) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    if (!gOverdubEngine->openStreams()) {
        setError(gOverdubEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3c_start_overdub(const char* record_wav_path,
                                  const int64_t backing_start_sample) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    if (record_wav_path == nullptr) {
        setError("N3C null record path");
        return -1;
    }
    if (!gOverdubEngine->startOverdub(std::string(record_wav_path),
                                      backing_start_sample)) {
        setError(gOverdubEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_n3c_stop_overdub(void) {
    if (gOverdubEngine) {
        gOverdubEngine->stopOverdub();
    }
}

int32_t orpheus_n3c_is_complete(void) {
    if (!gOverdubEngine) {
        return 0;
    }
    return gOverdubEngine->isComplete() ? 1 : 0;
}

void orpheus_n3c_get_diagnostics(OrpheusN3OverdubDiagnostics* out) {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3OverdubDiagnostics{};
    if (gOverdubEngine) {
        gOverdubEngine->fillDiagnostics(out);
    }
}

void orpheus_n3c_shutdown(void) {
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
}

const char* orpheus_native_last_error(void) {
    std::lock_guard<std::mutex> lock(gErrorMutex);
    return gLastError.c_str();
}

}  // extern "C"
