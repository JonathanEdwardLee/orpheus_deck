/// Native Oboe playback-only bridge for native_test projects (N3E-G).
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../native/orpheus_native_audio.dart';
import '../native/orpheus_native_bindings.dart';
import '../native/orpheus_native_n3d_bindings.dart';
import 'orpheus_recorder_engine.dart';

/// 48 kHz — native_test playback clock (matches N3D mixer).
const int kOrpheusNativeTestSampleRate = 48000;

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

/// Playback-only N3D bridge; recording is intentionally unsupported until N3E-H.
class NativeOboeRecorderEngine implements OrpheusRecorderEngine {
  NativeOboeRecorderEngine({OrpheusNativeBindings? bindings})
      : _bindings = bindings ?? OrpheusNativeBindings.instance;

  final OrpheusNativeBindings _bindings;

  bool _sessionOpen = false;
  bool _playing = false;

  @override
  String get engineId => 'native';

  @override
  bool get isNative => true;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isRecording => false;

  bool get sessionOpen => _sessionOpen;

  @override
  Future<void> initialize() async {
    if (!Platform.isAndroid) {
      throw NativeOboePlaybackException('native playback requires Android');
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
        'native_test playback requires $kOrpheusNativeTestSampleRate Hz',
      );
    }

    await _ensureSession();
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
    await _ensureSession();
    if (!_sessionOpen) {
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
    throw UnsupportedError('native recording not implemented (N3E-H)');
  }

  @override
  Future<void> stop() async {
    if (!_sessionOpen && !_playing) {
      return;
    }
    final b = _bindings;
    b.n3dStopMix();
    b.n3dShutdown();
    _sessionOpen = false;
    _playing = false;
    debugPrint('Orpheus N3E-G: native playback stopped');
  }

  @override
  Future<void> setTrackGain(int index, double gain) async {
    if (!_sessionOpen) return;
    _check(_bindings.n3dSetTrackGain(index, gain), 'set gain $index');
  }

  @override
  Future<void> setTrackMute(int index, bool muted) async {
    if (!_sessionOpen) return;
    _check(_bindings.n3dSetTrackMute(index, muted ? 1 : 0), 'set mute $index');
  }

  @override
  Future<void> setTrackSolo(int index, bool solo) async {
    if (!_sessionOpen) return;
    _check(_bindings.n3dSetTrackSolo(index, solo ? 1 : 0), 'set solo $index');
  }

  void applyMixerState({
    required List<double> volumes,
    required List<bool> mutes,
    required List<bool> solos,
  }) {
    if (!_sessionOpen) return;
    for (int i = 0; i < 4; i++) {
      _bindings.n3dSetTrackGain(i, volumes[i]);
      _bindings.n3dSetTrackMute(i, mutes[i] ? 1 : 0);
      _bindings.n3dSetTrackSolo(i, solos[i] ? 1 : 0);
    }
  }

  @override
  Future<int> getTransportSample() async {
    if (!_sessionOpen) return 0;
    return _bindings.n3dGetTransportSample();
  }

  int get currentTransportSample => _sessionOpen ? _bindings.n3dGetTransportSample() : 0;

  bool get isPlaybackComplete =>
      _sessionOpen && _bindings.n3dIsPlaybackComplete() == 1;

  OrpheusN3MixerDiagnosticsData readMixerDiagnostics() =>
      _bindings.readN3dDiagnostics();

  @override
  Future<OrpheusRecorderDiagnostics> getDiagnostics() async {
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

  Future<void> _ensureSession() async {
    if (_sessionOpen) {
      return;
    }
    await OrpheusNativeAudio.instance.stopN3d();
    await OrpheusNativeAudio.instance.stopN3c();
    await OrpheusNativeAudio.instance.stopN3b();

    _check(_bindings.n3dInit(), 'init');
    _sessionOpen = true;
  }

  void _check(int code, String label) {
    if (code == 0) {
      return;
    }
    final err = _bindings.readLastError();
    throw NativeOboePlaybackException('$label failed: $err');
  }
}
