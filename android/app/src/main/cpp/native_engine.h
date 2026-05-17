#ifndef ORPHEUS_NATIVE_ENGINE_H_
#define ORPHEUS_NATIVE_ENGINE_H_

#include "audio_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Phase N1 FFI surface — strict C structs only. */
int32_t orpheus_native_init(void);
int32_t orpheus_native_open_streams(void);
int32_t orpheus_native_play_impulse(void);
int32_t orpheus_native_start_record(const char* wav_path, int32_t duration_ms);
int32_t orpheus_native_stop_record(void);
void orpheus_native_get_diagnostics(OrpheusStreamDiagnostics* out);
void orpheus_native_shutdown(void);

/** Phase N2 full-duplex overdub prototype (separate engine instance). */
int32_t orpheus_native_n2_init(void);
int32_t orpheus_native_n2_open_streams(void);
int32_t orpheus_native_n2_start_duplex(const char* record_wav_path);
int32_t orpheus_native_n2_is_complete(void);
void orpheus_native_n2_get_diagnostics(OrpheusDuplexDiagnostics* out);
void orpheus_native_n2_shutdown(void);

/** Phase N3B one-track WAV playback (separate engine instance). */
int32_t orpheus_n3_init(void);
int32_t orpheus_n3_generate_test_wav(const char* path);
int32_t orpheus_n3_load_wav(const char* path);
int32_t orpheus_n3_open_streams(void);
int32_t orpheus_n3_start_playback(int64_t start_sample);
void orpheus_n3_stop_playback(void);
int64_t orpheus_n3_get_transport_sample(void);
int32_t orpheus_n3_is_playback_complete(void);
void orpheus_n3_get_diagnostics(OrpheusN3PlaybackDiagnostics* out);
void orpheus_n3_shutdown(void);

/** Phase N3C WAV backing + mic overdub (separate engine instance). */
int32_t orpheus_n3c_init(void);
int32_t orpheus_n3c_generate_backing_wav(const char* backing_path);
int32_t orpheus_n3c_set_default_record_latency_offset_samples(int64_t offset_samples);
int32_t orpheus_n3c_open_streams(void);
int32_t orpheus_n3c_start_overdub(const char* record_wav_path, int64_t backing_start_sample);
void orpheus_n3c_stop_overdub(void);
int32_t orpheus_n3c_is_complete(void);
void orpheus_n3c_get_diagnostics(OrpheusN3OverdubDiagnostics* out);
void orpheus_n3c_shutdown(void);

/** Phase N3D four-track WAV mixer (separate engine instance). */
int32_t orpheus_n3d_init(void);
int32_t orpheus_n3d_generate_and_load_test_tracks(const char* cache_dir);
int32_t orpheus_n3d_open_streams(void);
int32_t orpheus_n3d_start_mix(int64_t start_sample);
void orpheus_n3d_stop_mix(void);
void orpheus_n3d_reset_mixer(void);
int32_t orpheus_n3d_set_track_gain(int32_t track_index, float gain);
int32_t orpheus_n3d_set_track_mute(int32_t track_index, int32_t muted);
int32_t orpheus_n3d_set_track_solo(int32_t track_index, int32_t solo);
int64_t orpheus_n3d_get_transport_sample(void);
int32_t orpheus_n3d_is_playback_complete(void);
void orpheus_n3d_get_diagnostics(OrpheusN3MixerDiagnostics* out);
void orpheus_n3d_shutdown(void);

const char* orpheus_native_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // ORPHEUS_NATIVE_ENGINE_H_
