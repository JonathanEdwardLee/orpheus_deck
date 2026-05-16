#ifndef ORPHEUS_AUDIO_TYPES_H_
#define ORPHEUS_AUDIO_TYPES_H_

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/** Mirrors Dart @Packed(4) OrpheusStreamDiagnostics — no JSON over FFI. */
typedef struct OrpheusStreamDiagnostics {
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t apiUsed;
    int32_t inputStreamOpened;
    int32_t outputStreamOpened;
    int32_t wavWriteSuccess;
} OrpheusStreamDiagnostics;

#ifdef __cplusplus
}
#endif

#endif  // ORPHEUS_AUDIO_TYPES_H_
