# N3E — Hidden Native Recorder Mode Integration Plan

**Branch:** `phase-n-native-audio`  
**Status:** N3E-F complete — dev native test projects + session metadata; recorder audio unchanged  
**Prerequisites (complete):** N1, N2 (N2B/N2D/N2E), N3B, N3C, N3C2, N3D  
**Companion:** [N3_ARCHITECTURE.md](N3_ARCHITECTURE.md), [ORPHEUS_NATIVE_AUDIO_PLAN.md](ORPHEUS_NATIVE_AUDIO_PLAN.md), [ORPHEUS_DESIGN_MANIFESTO.md](ORPHEUS_DESIGN_MANIFESTO.md)

---

## Context

N3D validated on device:

| Signal | Result |
|--------|--------|
| `tracksLoaded` | 4 / 4 |
| Transport | Reaches 480000 (10 s dev test; production tape = 15 min @ 48 kHz) |
| `playbackComplete` | YES |
| `xRunCount` | 0 |
| Stream | AAudio / LowLatency / Exclusive |
| Scheduling | Staggered `tapeStart` + `effectiveTapeStart` works |
| Mixer | Mute / solo / gain works |
| Regression | N3C and N2 still pass after N3D |

N3E connects the **real cassette UI** (`RecorderScreen` in `lib/main.dart`) to the native engine **in parallel** with the existing legacy path. Legacy remains default; native is opt-in and hidden.

---

## 1. Integration boundary

### Where audio lives today

Almost all timing-critical behavior is inside **`_RecorderScreenState`** (`lib/main.dart`, ~6k lines). The UI widgets (`TrackStrip`, `TapeReelTransport`) are mostly display + callbacks; they do not own audio.

| Concern | Primary symbols | Notes |
|---------|-----------------|--------|
| **Play** | `_play()`, `_maybeStartPendingTracks()`, `_attachCompletionListenerFor()` | Four `just_audio` `AudioPlayer`s; tape-start scheduling via `_pendingPlaybackIndices` + 50 ms `_startTicker` |
| **Stop** | `_stop()`, `_resetTimerAfterStop()` | Stops recorder, all track players, click; cancels ticker |
| **Record** | `_record()`, `finishRecordLaunch()` | `AudioRecorder` → `track_{i}_{ts}.m4a`; overdub backs via same players as play |
| **Click / metronome** | `_clickPlayer`, `_metronomeOn`, `_resyncClickPlayerToTransport()`, click WAV build | Separate `just_audio` bus; not an armed track |
| **Arm track** | `_toggleArmTrack()` (via `TrackStrip.onArmToggled`) | `_armedTracks[4]` — exactly one armed for record |
| **Mute / solo / volume** | `_toggleMute`, `_toggleSolo`, `_setVolume`, `_updateMixerState`, `_isTrackAudible` | Immediate `setVolume` on players |
| **Tape position** | `_playbackMs`, `_setTapeHeadMs`, `_applyTapeHeadClamped`, `TapeReelTransport` | **Dart Timer** advances head during play/record (+50 ms/tick) |
| **Clear track** | `_clearTrack()` | Deletes file, resets paths/offsets/tape start |
| **Undo** | `_lastUndo`, `_saveMixerUndo()` | Mixer + clear actions; not full transport undo |
| **Project load/save** | `_loadSession()`, `_saveSession()`, `OrpheusSession` | `session.json` under `OrpheusDeck/{project}/` |
| **Export** | `_exportMix()`, `_testExportAlignment()`, `MethodChannel` `com.junkfeathers.orpheusdeck/export` | FFmpeg `adelay` from `_trackTapeStartMs`; inputs are `_trackFiles` paths (M4A today) |
| **Permissions / session** | `_initAudioSession()`, `Permission.microphone` | Android audio focus shared across players + recorder |
| **Latency UI settings** | `OrpheusSettings.latencyCompensationEnabled`, `_trackOffsets`, `_playbackSeekMsForTrack`, `_exportAdelayMsFromTapeStart` | Affects **legacy** seek/export only today |

### Dev-only native entry (unchanged by N3E plan)

- **Native Audio Test:** `openOrpheusNativeTestScreen()` — long-press **Settings → ABOUT** when `kDebugMode && Platform.isAndroid` (`lib/main.dart` ~670).
- **Orchestration:** `OrpheusNativeAudio` + FFI (`lib/native/*`) — separate from recorder; N3B/N3C/N3D engines are mutually exclusive in `native_engine.cpp`.

### Safest seam for `NativeAudioController` / engine abstraction

**Do not rewrite `main.dart` in one pass.** Introduce a thin **recorder engine layer** under `lib/recorder/` (new), and change `_RecorderScreenState` to delegate transport/mixer calls through a single `OrpheusRecorderEngine` instance.

```
┌─────────────────────────────────────────────────────────┐
│  RecorderScreen UI (TrackStrip, TapeReel, transport)   │
│  State: _playbackMs, _armedTracks, session fields        │
└──────────────────────────┬──────────────────────────────┘
                           │ delegates when transport/mixer/audio
                           ▼
┌─────────────────────────────────────────────────────────┐
│  OrpheusRecorderEngine (abstract)                        │
│  LegacyFlutterRecorderEngine | NativeOboeRecorderEngine  │
└──────────────────────────┬──────────────────────────────┘
                           │
           ┌───────────────┴───────────────┐
           ▼                               ▼
   just_audio + record package      OrpheusNativeAudio / FFI
   (current path)                   (N3B–D; future unified N3E native)
```

**First touch points (ordered):**

1. **Transport facade** — `_play` / `_stop` / `_record` call `_engine.startPlayback` / `stop` / `startRecording` instead of inlining players.
2. **Mixer facade** — `_updateMixerState` → `_engine.setTrackGain/Mute/Solo`.
3. **Transport clock** — While native is active, **poll** `getTransportSample()` at 20–50 Hz and map to `_playbackMs` for reel/header (do not drive audio from Dart timer).
4. **Session I/O** — unchanged at UI layer; engine receives paths + sample timing on `loadProjectTracks`.

**Keep in UI (not in engine):** waveform cache, export menu, project browser, OLED layout, undo presentation, snackbars.

**Native prerequisite (before behavior-changing N3E):** Consolidate N3C (duplex record) + N3D (four-track mix) into one **production-shaped** native API (see [N3_ARCHITECTURE.md](N3_ARCHITECTURE.md) §4 `orpheus_n3_*`). N3E Dart should not juggle `n3c_init` + `n3d_init` from the recorder screen.

---

## 2. Engine abstraction

### Proposed interface

```dart
/// Sample-accurate transport + four-track cassette operations.
/// Implementations must not be used concurrently.
abstract class OrpheusRecorderEngine {
  /// Engine kind for logging / session metadata.
  String get engineId; // 'legacy' | 'native'

  /// Load or refresh track assets after session load or clear.
  Future<void> loadProjectTracks({
    required List<String?> filePaths,
    required List<int> trackTapeStartMs,
    required List<int> recordLatencyOffsetMs, // per-track; 0 if unknown
    required int sampleRate, // 48000 for native
  });

  Future<void> openAudio(); // streams / players — idempotent
  Future<void> closeAudio();

  Future<void> startPlayback({required int tapeStartSample});
  Future<void> startRecording({
    required int armedTrackIndex,
    required int tapeStartSample,
    required String outputPath,
    required int defaultRecordLatencyOffsetSamples,
  });
  Future<void> stop();

  void setTrackGain(int index, double gain);
  void setTrackMute(int index, bool muted);
  void setTrackSolo(int index, bool solo);

  /// Authoritative transport during play/record (native); legacy may mirror _playbackMs.
  int getTransportSample();
  int get sampleRate;

  /// Optional dev/diagnostic surface (native structs); legacy may return minimal map.
  OrpheusRecorderDiagnostics getDiagnostics();

  Future<void> dispose();
}
```

Supporting types (separate file):

- `OrpheusRecorderDiagnostics` — Dart-only summary (xruns, api, transport, per-track mixed frames) mapped from native struct or legacy zeros.
- `OrpheusProjectTrack` — path, `trackTapeStartSamples`, `recordLatencyOffsetSamples`, gain, mute, solo.

### Implementations

| Class | Role |
|-------|------|
| **`LegacyFlutterRecorderEngine`** | Wraps existing `AudioRecorder`, four `ja.AudioPlayer`, `_clickPlayer` behavior. Initial version can use **delegates** into `_RecorderScreenState` methods (Option C) before extracting code out of `main.dart`. |
| **`NativeOboeRecorderEngine`** | Android-only; owns FFI lifecycle; maps ms↔samples at boundary; calls unified native `orpheus_n3e_*` (to be built). Uses WAV paths only in first releases. |

### Factory

```dart
OrpheusRecorderEngine createRecorderEngine(OrpheusEngineMode mode) {
  switch (mode) {
    case OrpheusEngineMode.legacy:
      return LegacyFlutterRecorderEngine(...);
    case OrpheusEngineMode.nativeExperimental:
      return NativeOboeRecorderEngine(...);
  }
}
```

`OrpheusSettings` (or new `OrpheusEngineSettings`) holds `engineMode`, default `legacy`.

---

## 3. Hidden setting

### UI placement

| Rule | Detail |
|------|--------|
| Label | **USE NATIVE AUDIO ENGINE (EXPERIMENTAL)** |
| Default | **OFF** (`legacy`) |
| Visibility | `kDebugMode` **or** long-press **Settings → ABOUT** (same gate family as Native Audio Test) |
| Persistence | `SharedPreferences` key e.g. `orpheus_engine_mode` — **not** written to `session.json` until N3F |

### Switching rules

1. **Transport must be stopped** — `_isPlaying == false && _isRecording == false`.
2. On toggle: `await _engine.dispose()` → swap implementation → `loadProjectTracks` from current UI state.
3. If current project is **legacy M4A** and user enables native: **block** with snackbar (“Native mode only for new native test projects”) until N3F migration exists.
4. Show persistent banner on recorder when native mode on: `EXPERIMENTAL NATIVE ENGINE`.

### Beta safety

- Release builds: setting hidden unless explicit internal flag (recommend **debug-only** for first N3E code drops).
- Never auto-enable native for existing users.
- Crash fallback: if native `openAudio` fails, revert to legacy and clear flag for session.

---

## 4. Session / file strategy (N3E initial)

| Topic | N3E decision |
|-------|----------------|
| **Existing projects** | **Legacy only.** Do not open M4A projects in native mode. |
| **New native projects** | Created only when user starts project **with native flag on** (or “New native test project” dev action). |
| **Record format** | **48 kHz mono PCM WAV** — `track_{i}_{timestamp}.wav` beside `session.json`. |
| **session.json** | **No schema break in N3E planning phase.** When coding starts, add optional fields only: `audioEngine: "native"`, `engineSampleRate: 48000`. Keep `trackTapeStartMs` for Flutter UI compatibility. |
| **M4A** | Legacy path unchanged; native does **not** decode AAC in callback or on load. |
| **Migration** | **Deferred to N3F** (background FFmpeg M4A→WAV, `nativeWavPath` metadata). |

### Path layout (native test project)

```
OrpheusDeck/{projectName}/
  session.json
  track_0_1234567.wav
  track_1_2345678.wav
  exports/   (unchanged — FFmpeg output)
```

---

## 5. Timing model

### Constants

| Field | Value |
|-------|--------|
| `engineSampleRate` | **48000** (native); legacy may still record 48 kHz M4A via `record` package |
| `tapeLengthSamples` | `15 * 60 * 48000` = **43_200_000** (production); dev tests may use shorter native tape for soak |
| N2E default offset | `defaultRecordLatencyOffsetSamples` ≈ **2900** (dev memory until per-route profiles) |

### Conversions (single place: `OrpheusSampleClock`)

```text
tapeStartSamples     = round(trackTapeStartMs * sampleRate / 1000)
playbackMs displayed = round(currentTransportSample * 1000 / sampleRate)
```

### Semantics (manifesto-aligned)

| Field | Owner | Rule |
|-------|--------|------|
| `trackTapeStartMs` / `trackTapeStartSamples` | Musician intent | Set at record stop from tape head; **never silently rewritten** for compensation |
| `recordLatencyOffsetSamples` | Technical | From N2E profile or per-take measurement (`_trackOffsets` ms legacy); stored in session when known |
| `effectiveTapeStartSamples` | Native mix/scheduling | `trackTapeStartSamples - recordLatencyOffsetSamples` |
| Profile vs self-check | N3C2 lesson | **Profile residual** = measured − stored offset; self-check residual is analysis-only |

### UI transport sync (native mode)

- **While playing/recording:** poll `getTransportSample()` every **20–50 ms** → update `_playbackMs` + `setState`.
- **While idle:** scrubbing reel sets both `_playbackMs` and native `seek(sample)` when implemented.
- **Disable** using `_startTicker` to advance time during native play (legacy ticker can remain for legacy-only).

### Click / metronome (N3E scope)

- **N3E-v1:** Legacy click (`_clickPlayer`) **OR** native metronome — **not both**. Prefer native click only when `NativeOboeRecorderEngine` exposes `setMetronome` (post–N3D); otherwise legacy click with native tracks risks dual output APIs.
- Document as follow-up if first slice is playback-only (Option A).

---

## 6. Minimum N3E implementation (recommended sequence)

### Recommendation: **Option C first** (safest)

| Option | Description | Risk | Verdict |
|--------|-------------|------|---------|
| **A** | Real recorder screen plays four **generated** test WAVs via native | Medium — touches real UI transport; no session/files | **Second** slice |
| **B** | Real UI records one armed track to WAV in **new native-only project** | High — mic, duplex, session write, failure modes | **Third** slice |
| **C** | Engine interface + `LegacyFlutterRecorderEngine` only; **no behavior change** | Minimal — shims/delegates | **First** slice ✓ |

**Rationale:** Option C proves the seam, CI, and settings gate without changing audio behavior. Reviewers can verify zero regression by diffing transport logs. Options A and B then add native code behind the same interface.

### Suggested coding milestones (after this plan is approved)

1. **N3E-C** — `lib/recorder/orpheus_recorder_engine.dart` + legacy adapter; `_RecorderScreenState` delegates; tests/analyze green.
2. **N3E-native-0** — C++ unified engine skeleton (`orpheus_n3e_*`) merging mix + overdub paths; dev screen smoke test.
3. **N3E-A** — Hidden flag on → recorder **PLAY** uses native engine with **cached N3D test WAVs** (no project files).
4. **N3E-B** — New project type `audioEngine: native`; record one track WAV; play back; save session paths.
5. **N3E-click** — Native metronome OR documented legacy-click exclusion.
6. **N3F** — Session sample fields + M4A migration (out of N3E scope).

---

## 7. Export strategy (N3E — no N4 rewrite)

**Keep existing FFmpeg export** (`_exportMix`) for both modes in N3E.

| Input | N3E native project |
|-------|---------------------|
| File path | `track_*.wav` instead of `track_*.m4a` |
| FFmpeg | Already path-agnostic (`-i` per file) |
| Delay | Continue `_exportAdelayMsFromTapeStart(tapeStartMs)` — same ms timeline as UI |
| Latency compensation | When enabled, same subtraction rules as legacy (`OrpheusSettings.latencyCompensationEnabled`) |
| Master vs raw | Unchanged |

**N4 (later):** Export from `effectiveTapeStartSamples` and sample-accurate `adelay` in samples (`adelay={samples}|{samples}` per channel) to match native playback exactly; optional `asetpts` alignment. N3E only needs export to **accept WAV inputs** and preserve `trackTapeStartMs` metadata.

**Alignment test:** Existing `_testExportAlignment()` remains valid for native WAV once paths point to `.wav`.

---

## 8. Risk list

| Risk | Impact | Mitigation |
|------|--------|------------|
| **`main.dart` monolith** | Any edit breaks unrelated features | Engine facade; extract incrementally; no big-bang |
| **Session migration** | Corrupt or unloadable projects | No `session.json` break in N3E; native-only new projects; explicit `audioEngine` field in N3F |
| **WAV vs M4A** | Native cannot load legacy projects | Hard gate: native mode refuses non-WAV / legacy projects |
| **Native engine lifecycle** | Leaks, crashes on rotate | Single engine instance; `dispose` on mode switch and `RecorderScreen.dispose`; mutual exclusion in C++ |
| **Dual engine running** | Xruns, silence, focus fights | Never init just_audio players and Oboe simultaneously; factory enforces one backend |
| **Permission / audio session** | Record fails on overdub | Reuse `_initAudioSession` rules; native path uses same mic permission flow |
| **Bluetooth / route change** | Latency profile invalid | Warn in native banner; fall back to legacy; N2E profile per route is N5 |
| **UI transport vs sample clock** | Reel drifts from audio | Native: poll `getTransportSample`; do not advance `_playbackMs` via Timer during native play |
| **Accidental beta exposure** | Support burden | Debug-only toggle; experimental banner; default OFF |
| **Click dual path** | Double metronome or focus steal | One click source per mode; document limitation in v1 |
| **15 min tape / memory** | OOM if N3D-style full preload | N3E native must stream WAV (N3B note); do not load 43M samples × 4 in RAM |
| **Profile residual confusion** | Wrong overdub placement | Store `recordLatencyOffsetSamples` in session; UI shows musician `trackTapeStartMs` only |
| **Export vs playback mismatch** | User trusts export over headphones | N3E: same `trackTapeStartMs` for both; N4 for sample-perfect export |
| **Incomplete native API** | Dart calls N3C + N3D separately | Block N3E behavior until unified `orpheus_n3e_*` exists |

---

## 9. N3E acceptance checklist (before widening beta)

Use this before removing “experimental” or touching default engine:

- [ ] Hidden flag default OFF; not visible in release without debug
- [ ] Engine switch only when transport stopped
- [ ] Legacy projects unchanged on disk and behavior
- [ ] Native test project: record WAV, play, mute/solo/gain, stop at tape end
- [ ] `xRunCount == 0` on 5+ min play/record soak (device profile: AAudio / LowLatency / Exclusive)
- [ ] Transport display tracks native `getTransportSample` within ±1 frame (~0.02 ms @ 48 kHz) visually (~50 ms UI tolerance)
- [ ] `effectiveTapeStartSamples` matches N3D scheduling logs
- [ ] Export WAV master mix sounds aligned with headphone playback (ear test + alignment test)
- [ ] N3C/N3D dev tests still pass after native recorder integration
- [ ] No regression: main recorder legacy path bit-identical behavior when flag OFF

---

## 10. Deliverables map

| Phase | Doc / code | Status |
|-------|------------|--------|
| N3A–D | [N3_ARCHITECTURE.md](N3_ARCHITECTURE.md) | Done |
| **N3E plan** | **This file** | **This document** |
| N3E-C code | `lib/recorder/*` abstraction + legacy placeholder | **Done** — no UI delegation yet |
| N3E-D code | `experimentalNativeAudioEngineEnabled` in `settings.json` | **Done** — toggle only, no routing |
| N3E-E code | `recorder_engine_selector.dart` eligibility guard | **Done** — selection only, no routing |
| N3E-F code | `native_test` projects + `session.json` metadata | **Done** — eligibility only, no routing |
| N3E-G+ code | native playback bridge for `native_test` projects | **Not started** |
| N3F | Session samples + M4A migration | Planned |
| N4 | Sample-accurate export | Planned |

---

## 11. N3E-C implemented

**Scope:** Recorder engine abstraction only — **no behavior change** in the main four-track recorder.

| Deliverable | Location |
|-------------|----------|
| `OrpheusRecorderEngine` abstract API | `lib/recorder/orpheus_recorder_engine.dart` |
| `OrpheusRecorderDiagnostics` + constants | `lib/recorder/recorder_engine_types.dart` |
| `LegacyFlutterRecorderEngine` placeholder | `lib/recorder/legacy_flutter_recorder_engine.dart` |
| `createLegacyRecorderEngine()` factory | `orpheus_recorder_engine.dart` |

**`LegacyFlutterRecorderEngine` today:**

- Mirrors transport/mixer state in memory for future diagnostics.
- `startPlayback` / `startRecording` / `stop` are **no-ops** with `TODO(N3E)` — `lib/main.dart` still owns `_play`, `_record`, `_stop`, and `just_audio`.
- Debug-only `debugPrint` on initialize/dispose and stub transport calls.

**`RecorderScreen`:** Comment-only note for future `late OrpheusRecorderEngine _engine`; no import or delegation.

**Next recommended steps (pick one when implementing):**

1. **N3E-D** — Hidden “USE NATIVE AUDIO ENGINE (EXPERIMENTAL)” toggle scaffolding (default OFF, no native wiring).
2. **N3E-A** — Delegate PLAY only when flag on, using N3D test WAVs (after unified native API exists).

---

## 12. N3E-D implemented

**Scope:** Hidden experimental native engine **toggle scaffolding** only — **no recorder routing**.

| Item | Detail |
|------|--------|
| Setting key | `experimentalNativeAudioEngineEnabled` in `Documents/OrpheusDeck/settings.json` |
| Default | `false` (missing/invalid JSON → false) |
| Not in | `session.json` (per-project) |
| UI | Settings dialog → **EXPERIMENTAL (DEBUG)** section, visible when `kDebugMode` only |
| Label | **USE NATIVE AUDIO ENGINE (EXPERIMENTAL)** |
| Transport guard | Uses existing `isTransportBusy` callback; toast **STOP PLAY/REC FIRST** |
| On enable toast | **EXPERIMENTAL. NOT USED BY MAIN RECORDER YET.** |
| On disable toast | **LEGACY ENGINE ACTIVE** |
| Recorder hint | Debug-only line under deck header (`ENGINE: LEGACY` / `…NOT WIRED`) |
| Native Audio Test | Unchanged — long-press About (debug Android) |

**Behavior:** Toggle persists across app restarts. `_play` / `_record` / `_stop` and `just_audio` are **unchanged**. Setting is **not read** by transport code yet.

**Access:** Home **SETTINGS**, or **OPEN SETTINGS** from pre-record reminder while on recorder (passes transport-busy check).

**Next recommended step:** **N3E-A** — when unified native API exists, read this flag and delegate PLAY only with N3D test WAVs; or continue with `OrpheusRecorderEngine` wiring behind the same flag.

---

## 13. N3E-E implemented

**Scope:** Pure-Dart **engine selection guard** — decides what *would* run; does **not** change audio.

| Deliverable | Location |
|-------------|----------|
| `OrpheusAudioEngineKind` | `lib/recorder/recorder_engine_selector.dart` |
| `RecorderEngineSelection` | same |
| `selectRecorderEngine(...)` | same |
| `formatRecorderEngineDebugLine` | same |
| `kOrpheusDevNativeProjectEligibleOverride` | `false` in repo — dev-only simulation |

**Selector rules (in order):**

1. `experimentalNativeAudioEngineEnabled == false` → **legacy**
2. `!isDebugBuild` → **legacy** (toggle hidden in release)
3. `!platformIsAndroid` → **legacy**
4. `projectHasLegacyM4aTracks` → **legacy**, reason `LEGACY M4A PROJECT`
5. `!projectIsNativeEligible` → **legacy**, reason `NATIVE TEST PROJECT REQUIRED`
6. All gates pass → **nativeExperimental** (still not wired to Oboe)

**Eligibility today:** `projectIsNativeEligible` is always `false` via `kOrpheusDevNativeProjectEligibleOverride` — real projects cannot select native yet. No `audioEngine` in `session.json`.

**Debug header:** Uses selection result (`ENGINE: LEGACY`, `ENGINE: LEGACY - …`, or `ENGINE: NATIVE EXPERIMENTAL SELECTED - NOT WIRED`).

**Next step:** **N3E-A** — read `RecorderEngineSelection` when delegating transport; or enable eligibility only for explicit dev native test projects (N3F).

---

## 14. N3E-F implemented

**Scope:** Dev-only **native test project** type and selector gating — **no native audio routing**.

| Item | Detail |
|------|--------|
| Create path | CassetteHomeScreen → **CREATE NATIVE TEST PROJECT** (`kDebugMode` only) |
| Auto name | `NATIVE_TEST_001`, `NATIVE_TEST_002`, … |
| Session field | `audioEngine`: `"legacy"` (default) or `"native_test"` |
| Old sessions | Missing `audioEngine` → **legacy** |
| M4A on disk | Forces **legacy** selection (`LEGACY M4A PROJECT`) even if `audioEngine` is `native_test` |
| Recorder audio | `_play` / `_record` / `_stop` / export unchanged (still M4A + just_audio) |

**Selector (debug header):**

| Condition | Header |
|-----------|--------|
| Normal project, toggle OFF | `ENGINE: LEGACY` |
| Normal project, toggle ON | `ENGINE: LEGACY - NATIVE TEST PROJECT REQUIRED` |
| `native_test`, toggle OFF | `ENGINE: LEGACY - NATIVE AVAILABLE` |
| `native_test`, toggle ON, no M4A | `ENGINE: NATIVE EXPERIMENTAL SELECTED - NOT WIRED` |
| Any project with `.m4a` tracks | `ENGINE: LEGACY - LEGACY M4A PROJECT` |

**Debug lines:** `PROJECT ENGINE: LEGACY` / `NATIVE TEST` plus engine line above.

**Toast:** `NATIVE TEST PROJECT` on load (debug, `native_test` only).

**Next step:** **N3E-G** — native playback-only bridge when `RecorderEngineSelection` is `nativeExperimental` (read flag + delegate PLAY only; WAV record path later).

---

*Document version: N3E — updated after N3E-F (2026-05-16).*
