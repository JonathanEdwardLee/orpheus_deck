/// Native Oboe playback + record bridge for native_test projects (N3E-G/H).
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../native/orpheus_native_audio.dart';
import '../native/orpheus_native_bindings.dart';
import '../native/orpheus_native_n3c_bindings.dart';
import '../native/orpheus_native_n3d_bindings.dart';
import 'orpheus_recorder_engine.dart';

/// 48 kHz — native_test transport clock (matches N3D/N3C).
const int kOrpheusNativeTestSampleRate = 48000;

/// Dev default when N2E profile is not in memory (~60 ms @ 48 kHz).
const int kOrpheusNativeDevRecordLatencyOffsetSamples = 2900;

/// Cassette side length — matches [tapeLengthMs] in main.dart.
const int kOrpheusNativeTestTapeLengthMs = 15 * 60 * 1000;

int orpheusMsToNativeSamples(int ms) =>
    (ms * kOrpheusNativeTestSampleRate / 1000).round();

int orpheusNativeSamplesToMs(int samples) =>
    (samples * 1000 / kOrpheusNativeTestSampleRate).round();

class NativeOboePlaybackException implements Exception {
  NativeOboePlaybackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of stopping a native record session (N3E-H).
class NativeOboeRecordResult {
  const NativeOboeRecordResult({
    required this.success,
    required this.path,
    required this.recordLatencyOffsetSamples,
    required this.recordedFramesWritten,
    required this.xRunCount,
    this.diagnostics,
  });

  final bool success;
  final String path;
  final int recordLatencyOffsetSamples;
  final int recordedFramesWritten;
  final int xRunCount;
  final OrpheusN3OverdubDiagnosticsData? diagnostics;

  int get durationMs => orpheusNativeSamplesToMs(recordedFramesWritten);
}

/// N3D playback + N3C record-only for native_test projects.
class NativeOboeRecorderEngine implements OrpheusRecorderEngine {
  NativeOboeRecorderEngine({OrpheusNativeBindings? bindings})
      : _bindings = bindings ?? OrpheusNativeBindings.instance;

  final OrpheusNativeBindings _bindings;

  bool _n3dSessionOpen = false;
  bool _n3cSessionOpen = false;
  bool _playing = false;
  bool _recording = false;
  String? _recordOutputPath;
  int _lastRecordLatencyOffsetSamples = kOrpheusNativeDevRecordLatencyOffsetSamples;

  @override
  String get engineId => 'native';

  @override
  bool get isNative => true;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isRecording => _recording;

  bool get n3dSessionOpen => _n3dSessionOpen;

  bool get n3cSessionOpen => _n3cSessionOpen;

  /// Alias for N3D transport poll during playback (N3E-G).
  bool get sessionOpen => _n3dSessionOpen;

  int get lastRecordLatencyOffsetSamples => _lastRecordLatencyOffsetSamples;

  @override
  Future<void> initialize() async {
    if (!Platform.isAndroid) {
      throw NativeOboePlaybackException('native engine requires Android');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
  }

  @override
  Future<void> loadProjectTracks({
    required List<String?> trackPaths,
    required List<int> trackTapeStartSamples,
    required List<int> recordLatencyOffsetSamples,
    required int sampleRate,
  }) async {
    if (sampleRate != kOrpheusNativeTestSampleRate) {
      throw NativeOboePlaybackException(
        'native_test requires $kOrpheusNativeTestSampleRate Hz',
      );
    }

    await _ensureN3dSession();
    _bindings.n3dStopMix();
    _bindings.n3dUnloadAllTracks();

    int loaded = 0;
    for (int i = 0; i < 4; i++) {
      final path = trackPaths[i];
      if (path == null || path.isEmpty) {
        continue;
      }
      if (!path.toLowerCase().endsWith('.wav')) {
        throw NativeOboePlaybackException('track $i is not WAV: $path');
      }
      if (!File(path).existsSync()) {
        throw NativeOboePlaybackException('track $i missing: $path');
      }

      final tapeStart = i < trackTapeStartSamples.length
          ? trackTapeStartSamples[i]
          : 0;
      final offset = i < recordLatencyOffsetSamples.length
          ? recordLatencyOffsetSamples[i]
          : 0;

      final pathPtr = path.toNativeUtf8();
      try {
        _check(
          _bindings.n3dLoadTrack(i, pathPtr, tapeStart, offset),
          'load track $i',
        );
        loaded++;
      } finally {
        malloc.free(pathPtr);
      }
    }

    if (loaded < 1) {
      throw NativeOboePlaybackException('no WAV tracks loaded');
    }
  }

  void setTapeLengthMs(int tapeLengthMs) {
    _bindings.n3dSetTapeLengthSamples(orpheusMsToNativeSamples(tapeLengthMs));
  }

  @override
  Future<void> startPlayback({required int startSample}) async {
    await _ensureN3dSession();
    if (!_n3dSessionOpen) {
      throw NativeOboePlaybackException('N3D session not open');
    }
    _bindings.n3dStopMix();
    _check(_bindings.n3dStartMix(startSample), 'start mix');
    _playing = true;
    debugPrint('Orpheus N3E-G: native playback start sample=$startSample');
  }

  @override
  Future<void> startRecording({
    required int armedTrack,
    required int startSample,
    required String outputPath,
    required int defaultRecordLatencyOffsetSamples,
  }) async {
    if (_recording) {
      throw NativeOboePlaybackException('already recording');
    }

    await stopN3dSession();
    await _ensureN3cSession();

    _lastRecordLatencyOffsetSamples = defaultRecordLatencyOffsetSamples > 0
        ? defaultRecordLatencyOffsetSamples
        : OrpheusNativeAudio.instance.recordLatencyOffsetForNativeTest;

    _check(
      _bindings.n3cSetDefaultRecordLatencyOffset(
        _lastRecordLatencyOffsetSamples,
      ),
      'set record latency offset',
    );
    _check(_bindings.n3cOpenStreamsRecordOnly(), 'open record streams');

    final tapeLengthSamples =
        orpheusMsToNativeSamples(kOrpheusNativeTestTapeLengthMs);
    final pathPtr = outputPath.toNativeUtf8();
    try {
      _check(
        _bindings.n3cStartRecordOnly(
          pathPtr,
          startSample,
          tapeLengthSamples,
        ),
        'start record-only',
      );
    } finally {
      malloc.free(pathPtr);
    }

    _recordOutputPath = outputPath;
    _recording = true;
    debugPrint(
      'Orpheus N3E-H: native record start track=$armedTrack '
      'sample=$startSample path=$outputPath '
      'offset=$_lastRecordLatencyOffsetSamples',
    );
  }

  /// Stop native record, finalize WAV on worker thread, shut down N3C.
  Future<NativeOboeRecordResult> finalizeRecording({
    Duration completeTimeout = const Duration(seconds: 8),
  }) async {
    if (!_n3cSessionOpen && !_recording) {
      return NativeOboeRecordResult(
        success: false,
        path: _recordOutputPath ?? '',
        recordLatencyOffsetSamples: _lastRecordLatencyOffsetSamples,
        recordedFramesWritten: 0,
        xRunCount: 0,
      );
    }

    _bindings.n3cStopOverdub();

    final deadline = DateTime.now().add(completeTimeout);
    OrpheusN3OverdubDiagnosticsData diag = _bindings.readN3cDiagnostics();
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      diag = _bindings.readN3cDiagnostics();
      if (_bindings.n3cIsComplete() == 1) {
        break;
      }
    }

    final path = _recordOutputPath ?? '';
    final bool wavOk = diag.wavWriteSuccess == 1;
    final bool fileOk = path.isNotEmpty &&
        File(path).existsSync() &&
        File(path).lengthSync() >= 44;

    await stopN3cSession();

    final success = wavOk && fileOk;
    debugPrint(
      'Orpheus N3E-H: record finalize success=$success '
      'frames=${diag.recordedFramesWritten} xruns=${diag.xRunCount} path=$path',
    );

    return NativeOboeRecordResult(
      success: success,
      path: path,
      recordLatencyOffsetSamples: diag.defaultRecordLatencyOffsetSamples,
      recordedFramesWritten: diag.recordedFramesWritten,
      xRunCount: diag.xRunCount,
      diagnostics: diag,
    );
  }

  @override
  Future<void> stop() async {
    if (_recording) {
      await finalizeRecording();
      return;
    }
    await stopN3dSession();
  }

  Future<void> stopN3dSession() async {
    if (!_n3dSessionOpen) {
      return;
    }
    _bindings.n3dStopMix();
    _bindings.n3dShutdown();
    _n3dSessionOpen = false;
    _playing = false;
    debugPrint('Orpheus N3E-G: N3D session stopped');
  }

  Future<void> stopN3cSession() async {
    if (!_n3cSessionOpen) {
      return;
    }
    _bindings.n3cStopOverdub();
    _bindings.n3cShutdown();
    _n3cSessionOpen = false;
    _recording = false;
    _recordOutputPath = null;
    debugPrint('Orpheus N3E-H: N3C session stopped');
  }

  @override
  Future<void> setTrackGain(int index, double gain) async {
    if (!_n3dSessionOpen) return;
    _check(_bindings.n3dSetTrackGain(index, gain), 'set gain $index');
  }

  @override
  Future<void> setTrackMute(int index, bool muted) async {
    if (!_n3dSessionOpen) return;
    _check(_bindings.n3dSetTrackMute(index, muted ? 1 : 0), 'set mute $index');
  }

  @override
  Future<void> setTrackSolo(int index, bool solo) async {
    if (!_n3dSessionOpen) return;
    _check(_bindings.n3dSetTrackSolo(index, solo ? 1 : 0), 'set solo $index');
  }

  void applyMixerState({
    required List<double> volumes,
    required List<bool> mutes,
    required List<bool> solos,
  }) {
    if (!_n3dSessionOpen) return;
    for (int i = 0; i < 4; i++) {
      _bindings.n3dSetTrackGain(i, volumes[i]);
      _bindings.n3dSetTrackMute(i, mutes[i] ? 1 : 0);
      _bindings.n3dSetTrackSolo(i, solos[i] ? 1 : 0);
    }
  }

  @override
  Future<int> getTransportSample() async {
    if (_recording && _n3cSessionOpen) {
      return _bindings.readN3cDiagnostics().currentTransportSample;
    }
    if (_n3dSessionOpen) {
      return _bindings.n3dGetTransportSample();
    }
    return 0;
  }

  int get currentTransportSample {
    if (_recording && _n3cSessionOpen) {
      return _bindings.readN3cDiagnostics().currentTransportSample;
    }
    if (_n3dSessionOpen) {
      return _bindings.n3dGetTransportSample();
    }
    return 0;
  }

  bool get isPlaybackComplete =>
      _n3dSessionOpen && _bindings.n3dIsPlaybackComplete() == 1;

  bool get isRecordTransportAtTapeEnd {
    if (!_recording || !_n3cSessionOpen) return false;
    final d = _bindings.readN3cDiagnostics();
    return d.currentTransportSample >= d.transportStopSample;
  }

  OrpheusN3MixerDiagnosticsData readMixerDiagnostics() =>
      _bindings.readN3dDiagnostics();

  OrpheusN3OverdubDiagnosticsData readRecordDiagnostics() =>
      _bindings.readN3cDiagnostics();

  @override
  Future<OrpheusRecorderDiagnostics> getDiagnostics() async {
    if (_recording && _n3cSessionOpen) {
      final d = readRecordDiagnostics();
      return OrpheusRecorderDiagnostics(
        engineId: engineId,
        sampleRate: d.sampleRate,
        currentTransportSample: d.currentTransportSample,
        xRunCount: d.xRunCount,
        isPlaying: false,
        isRecording: true,
        tracksLoaded: d.backingWavLoadSuccess,
        apiUsed: d.apiUsed,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
      );
    }
    final d = readMixerDiagnostics();
    return OrpheusRecorderDiagnostics(
      engineId: engineId,
      sampleRate: d.sampleRate,
      currentTransportSample: d.currentTransportSample,
      xRunCount: d.xRunCount,
      isPlaying: d.isPlaying == 1,
      isRecording: false,
      tracksLoaded: d.tracksLoaded,
      apiUsed: d.apiUsed,
      performanceMode: d.performanceMode,
      sharingMode: d.sharingMode,
    );
  }

  Future<void> preparePlayback({
    required List<String?> trackPaths,
    required List<int> trackTapeStartMs,
    required List<int> recordLatencyOffsetMs,
    required int tapeLengthMs,
    required List<double> volumes,
    required List<bool> mutes,
    required List<bool> solos,
  }) async {
    final tapeStartSamples = List<int>.generate(
      4,
      (i) => orpheusMsToNativeSamples(
        i < trackTapeStartMs.length ? trackTapeStartMs[i] : 0,
      ),
    );
    final offsetSamples = List<int>.generate(
      4,
      (i) => orpheusMsToNativeSamples(
        i < recordLatencyOffsetMs.length ? recordLatencyOffsetMs[i] : 0,
      ),
    );

    await loadProjectTracks(
      trackPaths: trackPaths,
      trackTapeStartSamples: tapeStartSamples,
      recordLatencyOffsetSamples: offsetSamples,
      sampleRate: kOrpheusNativeTestSampleRate,
    );
    setTapeLengthMs(tapeLengthMs);
    applyMixerState(volumes: volumes, mutes: mutes, solos: solos);

    _check(_bindings.n3dOpenStreams(), 'open streams');
  }

  Future<void> _ensureN3dSession() async {
    if (_n3dSessionOpen) {
      return;
    }
    await stopN3cSession();
    await OrpheusNativeAudio.instance.stopN3d();
    await OrpheusNativeAudio.instance.stopN3c();
    await OrpheusNativeAudio.instance.stopN3b();

    _check(_bindings.n3dInit(), 'N3D init');
    _n3dSessionOpen = true;
  }

  Future<void> _ensureN3cSession() async {
    if (_n3cSessionOpen) {
      return;
    }
    await stopN3dSession();
    await OrpheusNativeAudio.instance.stopN3d();
    await OrpheusNativeAudio.instance.stopN3c();
    await OrpheusNativeAudio.instance.stopN3b();

    _check(_bindings.n3cInit(), 'N3C init');
    _n3cSessionOpen = true;
  }

  void _check(int code, String label) {
    if (code == 0) {
      return;
    }
    final err = _bindings.readLastError();
    throw NativeOboePlaybackException('$label failed: $err');
  }
}
