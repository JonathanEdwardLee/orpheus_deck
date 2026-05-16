# ORPHEUS NATIVE AUDIO PLAN

## Mission

Orpheus Deck is a serious mobile four-track recorder with a retro cassette-inspired interface.

The visual identity is lo-fi, hardware-like, monochrome, and tape-inspired.

The audio engine should be professional, modern, low-latency, sample-accurate, and trustworthy.

The goal is:

**Retro interface. Pro native audio engine.**

Lo-fi bleed, delay, and tape artifacts should be optional creative modes, not forced limitations.

The default recording experience should help musicians stay in creative flow. Latency, late overdubs, bad monitoring, or confusing calibration should be treated as serious problems.

## Architecture Direction

Flutter remains responsible for:

- UI
- cassette workflow
- project management
- settings
- export menus
- navigation
- visual tape/reel metaphor

Native Android C++ becomes responsible for:

- playback
- recording
- overdub monitoring
- click/guide timing
- latency measurement
- sample-position transport
- per-track scheduling
- mixer state
- timing compensation

## Android Engine Target

Use Google Oboe.

Preferred stack:

- Oboe C++
- AAudio on modern Android
- OpenSL ES fallback through Oboe
- PerformanceMode::LowLatency
- SharingMode::Exclusive requested when available
- 48 kHz preferred
- callback-based audio
- sample counters, not millisecond timers

Prefer Oboe 1.10.0 unless build compatibility requires fallback.

## Timing Model

The engine must use samples internally.

Flutter may display:

- minutes
- seconds
- milliseconds
- tape position

But the engine must think in:

- sample frames
- sample offsets
- sample-accurate transport position

Preferred model:

trackTapeStartSamples = where the musician intended the take to begin on tape

recordLatencyOffsetSamples = technical correction for recorded placement

effectiveTapeStartSamples = trackTapeStartSamples - recordLatencyOffsetSamples

Do not silently mutate the musician's intended tape position.

Use effectiveTapeStartSamples for:

- playback scheduling
- waveform lane placement
- export alignment
- overdub monitoring alignment

## Callback Safety Rules

Inside Oboe audio callbacks:

- no file I/O
- no memory allocation
- no locks
- no std::mutex
- no Dart calls
- no JSON/string building
- no blocking operations

All shared C++ state accessed from FFI must use atomics:

- std::atomic<int64_t>
- std::atomic<int32_t>
- std::atomic<bool>

The audio callback must remain lock-free.

Recorded audio should go into a lock-free / ring buffer first. A worker thread should write audio to disk.

## Diagnostics

Do not pass diagnostics as JSON strings from native code.

Use strict C structs through FFI.

Example:

struct StreamDiagnostics {
    int32_t sampleRate;
    int32_t framesPerBurst;
    int32_t bufferSizeInFrames;
    int32_t xRunCount;
    int32_t performanceMode;
    int32_t sharingMode;
    int32_t apiUsed;
};

## Click / Latency Test Signal

For native click or latency tests, do not use a continuous sine wave.

Use a sharp transient:

- single-sample impulse
or
- very short 2 ms square burst

This makes sample-level latency detection possible.

## Recording Modes

Orpheus Deck should eventually support:

### Tight Mode

Default serious recording mode.

- wired headphones recommended
- live mic software monitoring off by default
- user hears backing tracks and click
- native engine compensates recorded placement
- goal is tight overdubs

### Lo-Fi Bleed Mode

Creative mode.

- speaker playback allowed
- room bleed allowed
- phone mic can capture playback artifacts
- latency compensation optional/off
- intentional cassette-style chaos

### Advanced Mode

Future mode.

- manual offset
- route profiles
- calibration values
- USB/audio interface info
- diagnostic timing stats

## Bluetooth Policy

Bluetooth should not be marketed as professional overdub mode.

The app should warn:

Bluetooth may have unstable timing. Use wired headphones or a USB audio interface for tight overdubs.

Bluetooth can remain useful for sketching, but tight recording cannot be guaranteed.

## Native Development Phases

### Phase N1 — Native Oboe Handshake

This is not a full recorder.

Goal:

Prove that native Oboe can open input/output, play a click, record mic, write a WAV, and report diagnostics.

N1 must not alter the main recorder workflow.

Success criteria:

- app builds
- native library loads
- Oboe stream opens
- click plays
- mic records
- WAV file is valid and playable
- no crash
- stream details are logged
- xrun count is reported
- Flutter UI remains responsive

### Phase N2 — Full Duplex Overdub Prototype (complete)

Goal:

Prove native engine can play backing audio and record mic simultaneously with tighter alignment than the Flutter plugin path.

N2B timing analysis, N2C display, N2D compensation proof, and N2E profile selection are implemented on the dev Native Audio Test screen.

### Phase N2E — Latency Profile Selection (complete)

Multi-pass N2B/N2D calibration chooses `defaultRecordLatencyOffsetSamples` (median of good passes). Dev-only; not wired to main recorder.

Observed phone target: ~2900 samples @ 48 kHz (~60 ms) until per-route profiles exist.

### Phase N3 — Native Four-Track Engine

Goal:

Native engine owns four-track playback, one mic record input, click guide, sample-accurate transport, mixer, and latency compensation.

**Full architecture, FFI API, data model, migration, risks, and subphases:** see **[N3_ARCHITECTURE.md](N3_ARCHITECTURE.md)**.

| Subphase | Summary |
|----------|---------|
| **N3A** | Architecture report (this planning doc) |
| **N3B** | One-track WAV playback + transport (dev only) |
| **N3C** | One-track playback + mic overdub to WAV |
| **N3D** | Four-track WAV mixer test |
| **N3E** | Hidden native recorder mode → real UI (parallel to legacy) |
| **N3F** | Session metadata + M4A→WAV migration helper |

**Next implementation:** N3B (do not replace main recorder until N3E checklist passes).

### Phase N4 — Export Alignment

Export must use the same timing metadata as native playback.

### Phase N5 — Pro Routing

Future support for:

- USB audio interfaces
- route-specific latency profiles
- Bluetooth warning/sketch mode
- device latency database

## Development Rule

Do not remove the existing Flutter audio engine until the native engine proves itself.

Build native audio beside the current app first.

N1 is a proof-of-concept only.
