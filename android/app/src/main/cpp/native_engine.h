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
const char* orpheus_native_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // ORPHEUS_NATIVE_ENGINE_H_
