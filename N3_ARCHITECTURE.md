# N3 — Native Four-Track Engine Architecture

**Branch:** `phase-n-native-audio`  
**Status:** N3A planning only — no production recorder replacement yet.  
**Companion:** [ORPHEUS_NATIVE_AUDIO_PLAN.md](ORPHEUS_NATIVE_AUDIO_PLAN.md), [ORPHEUS_DESIGN_MANIFESTO.md](ORPHEUS_DESIGN_MANIFESTO.md)

---

## Context (N1–N2E complete)

Validated on-device profile (engineering tests, phone speaker path):

| Parameter | Observed |
|-----------|----------|
| API | AAudio |
| Performance | LowLatency |
| Sharing | Exclusive |
| Sample rate | 48 kHz |
| `framesPerBurst` | 96 |
| `bufferSizeInFrames` | 192 |
| `xRunCount` | 0 |
| `defaultRecordLatencyOffsetSamples` (N2E) | ~2858–2994; strongest profile **2948** samples (**61.4 ms**), spread **102** samples |
| Practical default target (N3 planning) | **~2900 samples / ~60 ms** until per-route profiles exist |

N3 must reuse this timing model and callback-safety rules proven in N1/N2.

---

## 1. Native engine responsibilities (N3 end state)

Native C++ / Oboe owns everything **timing-critical** and **real-time**:

| Responsibility | Notes |
|----------------|--------|
| **Four playback tracks** | Mix up to four armed/audible sources into the output callback |
| **One record input** | Mic capture during record/overdub; ring buffer → worker WAV write |
| **Click / metronome guide** | Sample-scheduled clicks (reuse N2 click transient model); optional BPM from Flutter |
| **Transport sample clock** | Single authoritative `currentTransportSample`; advances in output callback |
| **Volume / mute / solo** | Per-track gain; solo logic (only soloed tracks audible if any solo) |
| **Track scheduling** | Each track: `effectiveTapeStartSamples`, `frameCount`, mute/solo — when to read/mix |
| **Record latency compensation** | Apply `recordLatencyOffsetSamples` so mic WAV aligns to musician’s `trackTapeStartSamples` |
| **XRun / stream diagnostics** | Struct fields via FFI (no JSON); updated atomically |
| **Recorded WAV output** | Post-record finalize on worker thread; path reported to Flutter |

Native does **not** own in N3A–N3D: project UI, tape reel drawing, export FFmpeg graphs, M4A encoding, session JSON schema (Flutter keeps metadata until N3F).

---

## 2. Flutter responsibilities (unchanged during N3 rollout)

| Keep in Flutter | Why |
|-----------------|-----|
| **UI** | Cassette metaphor, transport buttons, mixer, OLED styling |
| **Project / session browsing** | Names, dates, file lists, autosave JSON |
| **Track arm / mute / solo buttons** | User intent → FFI calls |
| **Tape reel / timeline scrub** | Display ms; convert to/from samples at FFI boundary |
| **Waveform display** | Decimated peaks from file cache (existing or WAV-derived) |
| **Export menu** | FFmpeg stays on Flutter/Android channel until N4 aligns native metadata |
| **Settings** | BPM, metronome sound, lo-fi bleed mode flags, calibration UX |
| **File paths & metadata** | `track_*.m4a` today; native paths + `trackTapeStartMs` in session JSON |

Flutter polls or receives **transport sample** for UI sync; it does not drive timing with `Timer` for audio alignment.

---

## 3. Data model (samples are source of truth)

### Global transport

| Field | Type | Description |
|-------|------|-------------|
| `tapeLengthSamples` | `int64_t` | Max cassette side (default 15 min @ 48 kHz → 43,200,000) |
| `currentTransportSample` | `int64_t` | Playhead / record head on tape (0 … tapeLength) |
| `transportState` | `int32_t` | Stopped / playing / recording (enum) |
| `engineSampleRate` | `int32_t` | Locked rate (prefer 48000) |

### Per track (index 0–3)

| Field | Type | Description |
|-------|------|-------------|
| `trackFilePath` | UTF-8 path | On-disk audio (N3B+: WAV; legacy M4A handled outside callback) |
| `trackSampleRate` | `int32_t` | File rate (must match engine or resample at load time) |
| `trackFrameCount` | `int64_t` | Valid samples in file (content length, not tape length) |
| `trackTapeStartSamples` | `int64_t` | Where the musician placed the take on tape (**intent**) |
| `recordLatencyOffsetSamples` | `int64_t` | Technical correction (N2E profile / per-track override later) |
| `effectiveTapeStartSamples` | `int64_t` | `trackTapeStartSamples - recordLatencyOffsetSamples` |
| `trackGain` | `float` | 0.0 … 1.0+ (match Flutter `_trackVolumes`) |
| `trackMuted` | `bool` | Mute |
| `trackSolo` | `bool` | Solo |
| `trackArmed` | `bool` | Arm for record (only one armed during record in v1) |

### Record pass (active overdub)

| Field | Type | Description |
|-------|------|-------------|
| `armedTrackIndex` | `int32_t` | 0–3 |
| `recordOutputPath` | UTF-8 | Temp/final WAV while recording |
| `recordTapeStartSamples` | `int64_t` | Tape head when record started |
| `defaultRecordLatencyOffsetSamples` | `int64_t` | From N2E profile (~2900 @ 48 kHz initial default) |

**Rules (from manifesto):**

- Never silently change `trackTapeStartSamples` after the musician sets it.
- Use `effectiveTapeStartSamples` for playback mix scheduling, monitoring alignment, and (later) export.
- Store offsets in **samples** in native; Flutter may display ms: `ms = samples * 1000 / sampleRate`.

---

## 4. FFI API (proposed C surface)

Naming follows existing `orpheus_native_*` / `orpheus_native_n2_*` pattern. All diagnostics via **structs**, `orpheus_native_last_error()` for failures.

### Lifecycle

```c
int32_t orpheus_n3_init(void);
void    orpheus_n3_shutdown(void);
```

- Opens no streams until `orpheus_n3_open_streams()` (allows load_track before audio).
- `shutdown` drains worker, closes Oboe, releases decoders.

### Stream / session config

```c
int32_t orpheus_n3_open_streams(void);
int32_t orpheus_n3_set_tape_length_samples(int64_t tape_length_samples);
int32_t orpheus_n3_set_default_record_latency_offset_samples(int64_t offset_samples);
```

### Tracks

```c
int32_t orpheus_n3_unload_track(int32_t track_index);
int32_t orpheus_n3_load_track(
    int32_t track_index,
    const char* path,
    int64_t track_tape_start_samples,
    int64_t record_latency_offset_samples);

int32_t orpheus_n3_set_track_gain(int32_t track_index, float gain);
int32_t orpheus_n3_set_track_mute(int32_t track_index, int32_t muted);
int32_t orpheus_n3_set_track_solo(int32_t track_index, int32_t solo);
int32_t orpheus_n3_set_armed_track(int32_t track_index);  // -1 = none
```

`load_track` runs **off** audio thread: open WAV, build streaming reader, set atomics for `trackFrameCount`, `effectiveTapeStartSamples`.

### Transport

```c
int32_t orpheus_n3_seek(int64_t transport_sample);
int32_t orpheus_n3_start_playback(int64_t start_sample);
int32_t orpheus_n3_start_record(
    int64_t start_sample,
    const char* output_wav_path,
    int64_t default_record_latency_offset_samples);
int32_t orpheus_n3_stop(void);

int64_t orpheus_n3_get_transport_sample(void);
int32_t orpheus_n3_get_transport_state(void);
```

- `start_playback` / `start_record` set atomic start position; output callback advances transport.
- `stop` stops Oboe streams or idles mix; worker finalizes WAV on record stop.

### Metronome (optional in N3D+)

```c
int32_t orpheus_n3_set_metronome(int32_t enabled, int32_t bpm, int32_t sound_id);
```

### Diagnostics

```c
void orpheus_n3_get_diagnostics(OrpheusN3Diagnostics* out);
```

**`OrpheusN3Diagnostics` (primitive fields only):**

- Stream: `sampleRate`, `framesPerBurst`, `bufferSizeInFrames`, `xRunCount`, `apiUsed`, `performanceMode`, `sharingMode`
- Transport: `currentTransportSample`, `transportState`, `tapeLengthSamples`
- Record: `armedTrackIndex`, `recordFramesWritten`, `recordWavFinalizeSuccess`
- Per-track summary: `trackLoaded[4]`, `trackFrameCount[4]`, `effectiveTapeStartSamples[4]`
- Timing: `defaultRecordLatencyOffsetSamples`, `lastRecordLatencyOffsetSamples`

No JSON. Dart mirrors struct with `@Packed` FFI.

---

## 5. File format strategy (N3 prototype)

**Recommendation: WAV-first on the native path.**

| Choice | Rationale |
|--------|-----------|
| **Container** | WAV (PCM float32 or int16) — already implemented in N1/N2 (`wav_writer`) |
| **Rate** | 48 kHz mono for record; stereo playback optional later |
| **Avoid M4A in native callbacks** | No AAC decode in real-time thread; keeps N3B–D small |
| **Legacy M4A projects** | See migration (§6) |

**Internal processing:** float32 mix bus in callback; convert at write boundary if using int16 WAV.

**New native recordings (N3C+):** write `track_{i}_{timestamp}.wav` beside or instead of `.m4a` while legacy path remains for main UI.

**Waveform UI:** Flutter can keep peak cache keyed by path; generate from WAV on worker (existing pattern) or reuse file size + decode pass off UI thread.

---

## 6. Migration strategy (bridge existing app)

Current production path (`lib/main.dart`):

- Tracks stored as **`.m4a`** (AAC via `record` package).
- Session JSON: `trackTapeStartMs`, offsets, mutes, solos, volumes.
- Playback: **just_audio** per track.
- Export: **FFmpeg** with `adelay` from `trackTapeStartMs`.

**Options (recommended hybrid for N3E–F):**

| Option | Pros | Cons |
|--------|------|------|
| **A. Convert M4A → WAV before native load** | Single native decoder path | One-time latency/disk; FFmpeg on worker |
| **B. Legacy Flutter audio for old projects** | Zero migration risk | Two engines to maintain |
| **C. Native-only for new projects** | Cleanest split | User confusion if toggles wrong |
| **D. On-the-fly transcode cache** | Lazy migration | Cache invalidation complexity |

**Recommended path:**

1. **N3B–D:** Dev-only native test UI; WAV files only.
2. **N3E:** Hidden “native recorder mode” records **WAV**; optional flag in session `audioEngine: native|legacy`.
3. **N3F:** On first native open of legacy project, **background FFmpeg** converts each `track_*.m4a` → `track_*.wav` in project dir (worker, not callback); store `nativeWavPath` in session metadata; keep M4A for export compatibility until N4.
4. **Main UI default** stays legacy until native passes acceptance checklist (xRun=0, offset stability, 15‑min soak).

Do **not** delete M4A or change export until N4 proves sample-aligned export from native metadata.

---

## 7. Implementation stages

| Phase | Scope | Main recorder | Deliverable |
|-------|--------|---------------|-------------|
| **N3A** | Architecture & FFI spec (this doc) | Untouched | Plan + structs sketched in headers optional |
| **N3B** | One-track **WAV playback** from disk into Oboe output | Untouched | Hidden dev: load WAV, play, transport sample, xruns |
| **N3C** | One-track playback + **mic overdub** to WAV (N2 duplex + file reader) | Untouched | Hidden dev: overdub with `defaultRecordLatencyOffsetSamples` |
| **N3D** | **Four-track WAV mixer** + mute/solo/gain + click | Untouched | Hidden dev: 4 loaded WAVs, mix, transport to tape end |
| **N3E** | Connect **hidden native recorder mode** to real transport/arm UI (feature flag) | Parallel path | User-opt-in; still no legacy removal — **see [N3E_INTEGRATION_PLAN.md](N3E_INTEGRATION_PLAN.md)** |
| **N3F** | Session metadata: samples in JSON, M4A→WAV migration helper | Dual engine | `trackTapeStartSamples`, `recordLatencyOffsetSamples` persisted |

**N3B technical notes:**

- `WavStreamReader`: preload header on worker; **ring or chunked read** ahead of playhead (e.g. 48–96 ms per callback chunk).
- Callback: sum active tracks at `transportSample - effectiveTapeStartSamples` into output buffer.
- No full 15‑min buffer in RAM.

**N3C technical notes:**

- Reuse `DuplexEngine` pattern: output = mix(backing) + click; input → ring → worker WAV.
- On stop: set armed track metadata (`trackFrameCount`, paths) for Flutter.

**N3D technical notes:**

- Four readers; solo/mute matrix in callback (branchless preferred: precompute `audibleMask` on FFI thread).
- Stop at `tapeLengthSamples`.

---

## 8. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Audio file decoding in callback** | Glitches, xruns | WAV only; pre-buffered chunks; decode only on worker |
| **Sample-rate mismatch** | Pitch/timing wrong | Reject load if rate ≠ engine rate in N3B; later offline resample |
| **WAV vs M4A compatibility** | Old projects won’t load native | Lazy FFmpeg convert; legacy engine fallback |
| **15‑min track memory** | OOM if fully loaded | Stream from disk; bounded read-ahead cache per track |
| **Disk I/O in callback** | Xruns | Lock-free queues; worker fills float buffers; callback only memcpy/add |
| **Buffer underruns** | Clicks/silence | Read-ahead ≥ 2× burst; report underrun counter in diagnostics |
| **UI / FFI desync** | Reel vs audio drift | Poll `get_transport_sample` at 30–60 Hz; don’t use Dart Timer for audio clock |
| **Export timing consistency** | Export misaligned vs playback | N4: export reads same `effectiveTapeStartSamples` from session/native |
| **Latency profile drift** | Wrong overdub placement | N2E profile per route; store offset in session; lo-fi bleed mode may disable comp |
| **Exclusive mode failure** | Higher latency | Same N1 fallback: Shared + log `actualSharingMode` |
| **Concurrent just_audio + native** | Audio focus fights | N3E flag ensures only one engine active |

---

## 9. Recommendation — smallest next step

**Implement N3B only:** native **one-track WAV playback** with sample transport.

Why:

- Proves disk streaming + Oboe output mix without record complexity.
- Reuses N1 stream open / diagnostics patterns.
- No M4A, no four-track matrix, no main UI change.
- Directly de-risks the highest unknown (long-file streaming under xRun=0).

**N3B acceptance sketch:**

- Load 48 kHz mono WAV (≥30 s test file).
- `start_playback(start_sample)`; `get_transport_sample` advances smoothly.
- `xRunCount == 0` for full play.
- Stop at end of file or tape length.
- Dev screen only (extend Native Audio Test or sibling `N3` dev page).

**Do not start N3C** until N3B playback is stable on the same device profile (AAudio / LowLatency / Exclusive / 48 kHz / burst 96).

**Initial constants for N3 code (when N3B starts):**

```c
#define ORPHEUS_N3_DEFAULT_SAMPLE_RATE 48000
#define ORPHEUS_N3_DEFAULT_RECORD_LATENCY_OFFSET_SAMPLES 2900  // ~60.4 ms @ 48 kHz
#define ORPHEUS_N3_DEFAULT_TAPE_LENGTH_SAMPLES (15LL * 60 * 48000)
```

---

## Appendix: Mapping from current Flutter session

| Flutter today | Native N3 |
|---------------|-----------|
| `_trackTapeStartMs[i]` | `trackTapeStartSamples` (× sampleRate/1000 at boundary) |
| `_trackOffsets[i]` / calibration | `recordLatencyOffsetSamples` |
| `_trackFiles[i]` `.m4a` | `trackFilePath` (`.wav` on native path) |
| `_trackVolumes[i]` | `trackGain` |
| `_trackMutes[i]` / `_trackSolos[i]` | `trackMuted` / `trackSolo` |
| `_armedTracks[i]` | `armedTrackIndex` |
| `_playbackMs` / tape head | `currentTransportSample` |
| `tapeLengthMs` (15 min) | `tapeLengthSamples` |

---

*Document version: N3A — planning only. No production behavior change.*
