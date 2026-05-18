#include "native_engine.h"

#include <memory>
#include <mutex>
#include <string>

#include "duplex_engine.h"
#include "oboe_engine.h"
#include "overdub_engine.h"
#include "mixer_engine.h"
#include "playback_engine.h"

namespace {

std::unique_ptr<orpheus::OboeEngine> gEngine;
std::unique_ptr<orpheus::DuplexEngine> gDuplexEngine;
std::unique_ptr<orpheus::PlaybackEngine> gPlaybackEngine;
std::unique_ptr<orpheus::OverdubEngine> gOverdubEngine;
std::unique_ptr<orpheus::MixerEngine> gMixerEngine;
std::string gLastError;
/** Only for last_error string lifetime — not used in audio callbacks. */
std::mutex gErrorMutex;

void setError(const std::string& msg) {
    std::lock_guard<std::mutex> lock(gErrorMutex);
    gLastError = msg;
}

}  // namespace

extern "C" {

static void shutdownMixerEngine() {
    if (gMixerEngine) {
        gMixerEngine->shutdown();
        gMixerEngine.reset();
    }
}

int32_t orpheus_native_init(void) {
    shutdownMixerEngine();
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
    shutdownMixerEngine();
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
    shutdownMixerEngine();
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
}

int32_t orpheus_n3_init(void) {
    shutdownMixerEngine();
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

int32_t orpheus_n3c_open_streams_record_only(void) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    if (!gOverdubEngine->openStreamsRecordOnly()) {
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

int32_t orpheus_n3c_start_record_only(const char* record_wav_path,
                                      const int64_t record_start_sample,
                                      const int64_t tape_length_samples) {
    if (!gOverdubEngine) {
        setError("N3C engine not initialized");
        return -1;
    }
    if (record_wav_path == nullptr) {
        setError("N3C null record path");
        return -1;
    }
    if (!gOverdubEngine->startRecordOnly(std::string(record_wav_path),
                                         record_start_sample,
                                         tape_length_samples)) {
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

static void shutdownAllExceptMixer() {
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
    if (gOverdubEngine) {
        gOverdubEngine->shutdown();
        gOverdubEngine.reset();
    }
}

int32_t orpheus_n3d_init(void) {
    shutdownAllExceptMixer();
    if (gMixerEngine) {
        gMixerEngine->shutdown();
        gMixerEngine.reset();
    }
    gMixerEngine = std::make_unique<orpheus::MixerEngine>();
    if (!gMixerEngine->init()) {
        setError(gMixerEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3d_generate_and_load_test_tracks(const char* cache_dir) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (cache_dir == nullptr) {
        setError("N3D null cache dir");
        return -1;
    }
    if (!gMixerEngine->generateAndLoadTestTracks(std::string(cache_dir))) {
        setError(gMixerEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_n3d_unload_all_tracks(void) {
    if (gMixerEngine) {
        gMixerEngine->unloadAllTracks();
    }
}

int32_t orpheus_n3d_load_track(const int32_t track_index,
                               const char* path,
                               const int64_t tape_start_sample,
                               const int64_t record_latency_offset_samples) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (path == nullptr) {
        setError("N3D null track path");
        return -1;
    }
    if (!gMixerEngine->loadTrack(track_index,
                                 std::string(path),
                                 tape_start_sample,
                                 record_latency_offset_samples)) {
        setError(gMixerEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_n3d_set_tape_length_samples(const int64_t tape_length_samples) {
    if (gMixerEngine) {
        gMixerEngine->setTapeLengthSamples(tape_length_samples);
    }
}

int32_t orpheus_n3d_open_streams(void) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (!gMixerEngine->openStreams()) {
        setError(gMixerEngine->lastError());
        return -1;
    }
    return 0;
}

int32_t orpheus_n3d_start_mix(const int64_t start_sample) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (!gMixerEngine->startMix(start_sample)) {
        setError(gMixerEngine->lastError());
        return -1;
    }
    return 0;
}

void orpheus_n3d_stop_mix(void) {
    if (gMixerEngine) {
        gMixerEngine->stopMix();
    }
}

void orpheus_n3d_reset_mixer(void) {
    if (gMixerEngine) {
        gMixerEngine->resetMixer();
    }
}

int32_t orpheus_n3d_set_track_gain(const int32_t track_index, const float gain) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (!gMixerEngine->setTrackGain(track_index, gain)) {
        setError("N3D invalid track index");
        return -1;
    }
    return 0;
}

int32_t orpheus_n3d_set_track_mute(const int32_t track_index, const int32_t muted) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (!gMixerEngine->setTrackMute(track_index, muted)) {
        setError("N3D invalid track index");
        return -1;
    }
    return 0;
}

int32_t orpheus_n3d_set_track_solo(const int32_t track_index, const int32_t solo) {
    if (!gMixerEngine) {
        setError("N3D engine not initialized");
        return -1;
    }
    if (!gMixerEngine->setTrackSolo(track_index, solo)) {
        setError("N3D invalid track index");
        return -1;
    }
    return 0;
}

int64_t orpheus_n3d_get_transport_sample(void) {
    if (!gMixerEngine) {
        return 0;
    }
    return gMixerEngine->getTransportSample();
}

int32_t orpheus_n3d_is_playback_complete(void) {
    if (!gMixerEngine) {
        return 0;
    }
    return gMixerEngine->isPlaybackComplete() ? 1 : 0;
}

void orpheus_n3d_get_diagnostics(OrpheusN3MixerDiagnostics* out) {
    if (out == nullptr) {
        return;
    }
    *out = OrpheusN3MixerDiagnostics{};
    if (gMixerEngine) {
        gMixerEngine->fillDiagnostics(out);
    }
}

void orpheus_n3d_shutdown(void) {
    if (gMixerEngine) {
        gMixerEngine->shutdown();
        gMixerEngine.reset();
    }
}

const char* orpheus_native_last_error(void) {
    std::lock_guard<std::mutex> lock(gErrorMutex);
    return gLastError.c_str();
}

}  // extern "C"
