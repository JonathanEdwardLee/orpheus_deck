#include "native_engine.h"

#include <memory>
#include <mutex>
#include <string>

#include "duplex_engine.h"
#include "oboe_engine.h"

namespace {

std::unique_ptr<orpheus::OboeEngine> gEngine;
std::unique_ptr<orpheus::DuplexEngine> gDuplexEngine;
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

const char* orpheus_native_last_error(void) {
    std::lock_guard<std::mutex> lock(gErrorMutex);
    return gLastError.c_str();
}

}  // extern "C"
