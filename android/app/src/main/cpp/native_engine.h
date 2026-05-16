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

const char* orpheus_native_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // ORPHEUS_NATIVE_ENGINE_H_
