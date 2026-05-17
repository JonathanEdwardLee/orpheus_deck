import 'package:flutter/foundation.dart';

import 'orpheus_recorder_engine.dart';

/// Default engine until hidden native mode is wired (N3E-D+).
OrpheusRecorderEngine createLegacyRecorderEngine() =>
    LegacyFlutterRecorderEngine();

/// Placeholder for today's `just_audio` + `record` path in `lib/main.dart`.
///
/// N3E-C: Does **not** open streams or drive transport. [RecorderScreen] keeps
/// calling `_play`, `_record`, and `_stop` until a later phase delegates here.
class LegacyFlutterRecorderEngine implements OrpheusRecorderEngine {
  LegacyFlutterRecorderEngine();

  bool _initialized = false;
  bool _disposed = false;
  bool _mirrorPlaying = false;
  bool _mirrorRecording = false;
  int _mirrorTransportSample = 0;
  int _sampleRate = kOrpheusRecorderSampleRate;
  String? _lastError;

  final List<String?> _trackPaths =
      List<String?>.filled(kOrpheusRecorderTrackCount, null);
  final List<int> _trackTapeStartSamples =
      List<int>.filled(kOrpheusRecorderTrackCount, 0);
  final List<int> _recordLatencyOffsetSamples =
      List<int>.filled(kOrpheusRecorderTrackCount, 0);
  final List<double> _gains =
      List<double>.filled(kOrpheusRecorderTrackCount, 1.0);
  final List<bool> _mutes =
      List<bool>.filled(kOrpheusRecorderTrackCount, false);
  final List<bool> _solos =
      List<bool>.filled(kOrpheusRecorderTrackCount, false);

  @override
  String get engineId => 'legacy';

  @override
  bool get isNative => false;

  @override
  bool get isPlaying => _mirrorPlaying;

  @override
  bool get isRecording => _mirrorRecording;

  void _ensureActive() {
    if (_disposed) {
      throw StateError('LegacyFlutterRecorderEngine disposed');
    }
  }

  void _ensureTrackIndex(int index) {
    if (index < 0 || index >= kOrpheusRecorderTrackCount) {
      throw RangeError.range(
        index,
        0,
        kOrpheusRecorderTrackCount - 1,
        'track index',
      );
    }
  }

  @override
  Future<void> initialize() async {
    _ensureActive();
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (kDebugMode) {
      debugPrint(
        'Orpheus RecorderEngine [legacy]: initialize (placeholder — '
        'main.dart still owns audio)',
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _initialized = false;
    _mirrorPlaying = false;
    _mirrorRecording = false;
    if (kDebugMode) {
      debugPrint('Orpheus RecorderEngine [legacy]: dispose');
    }
  }

  @override
  Future<void> loadProjectTracks({
    required List<String?> trackPaths,
    required List<int> trackTapeStartSamples,
    required List<int> recordLatencyOffsetSamples,
    required int sampleRate,
  }) async {
    _ensureActive();
    _sampleRate = sampleRate > 0 ? sampleRate : kOrpheusRecorderSampleRate;
    for (var i = 0; i < kOrpheusRecorderTrackCount; i++) {
      _trackPaths[i] =
          i < trackPaths.length ? trackPaths[i] : null;
      _trackTapeStartSamples[i] = i < trackTapeStartSamples.length
          ? trackTapeStartSamples[i]
          : 0;
      _recordLatencyOffsetSamples[i] = i < recordLatencyOffsetSamples.length
          ? recordLatencyOffsetSamples[i]
          : 0;
    }
    // TODO(N3E): Delegate to RecorderScreen session load when wired.
  }

  @override
  Future<void> startPlayback({required int startSample}) async {
    _ensureActive();
    _mirrorTransportSample = startSample < 0 ? 0 : startSample;
    _mirrorPlaying = true;
    _mirrorRecording = false;
    // TODO(N3E): Delegate to _play() / just_audio players in main.dart.
    if (kDebugMode) {
      debugPrint(
        'Orpheus RecorderEngine [legacy]: startPlayback($startSample) '
        '(no-op until delegation)',
      );
    }
  }

  @override
  Future<void> startRecording({
    required int armedTrack,
    required int startSample,
    required String outputPath,
    required int defaultRecordLatencyOffsetSamples,
  }) async {
    _ensureActive();
    _ensureTrackIndex(armedTrack);
    _mirrorTransportSample = startSample < 0 ? 0 : startSample;
    _mirrorRecording = true;
    _mirrorPlaying = false;
    // TODO(N3E): Delegate to _record() / AudioRecorder in main.dart.
    if (kDebugMode) {
      debugPrint(
        'Orpheus RecorderEngine [legacy]: startRecording '
        'trk=$armedTrack sample=$startSample path=$outputPath '
        'offset=$defaultRecordLatencyOffsetSamples (no-op)',
      );
    }
  }

  @override
  Future<void> stop() async {
    _ensureActive();
    _mirrorPlaying = false;
    _mirrorRecording = false;
    // TODO(N3E): Delegate to _stop() in main.dart.
  }

  @override
  Future<void> setTrackGain(int index, double gain) async {
    _ensureActive();
    _ensureTrackIndex(index);
    _gains[index] = gain;
    // TODO(N3E): Delegate to _updateMixerState / player.setVolume.
  }

  @override
  Future<void> setTrackMute(int index, bool muted) async {
    _ensureActive();
    _ensureTrackIndex(index);
    _mutes[index] = muted;
  }

  @override
  Future<void> setTrackSolo(int index, bool solo) async {
    _ensureActive();
    _ensureTrackIndex(index);
    _solos[index] = solo;
  }

  @override
  Future<int> getTransportSample() async {
    _ensureActive();
    return _mirrorTransportSample;
  }

  @override
  Future<OrpheusRecorderDiagnostics> getDiagnostics() async {
    _ensureActive();
    final loaded = _trackPaths
        .where((p) => p != null && p.isNotEmpty)
        .length;
    return OrpheusRecorderDiagnostics(
      engineId: engineId,
      sampleRate: _sampleRate,
      currentTransportSample: _mirrorTransportSample,
      xRunCount: 0,
      isPlaying: _mirrorPlaying,
      isRecording: _mirrorRecording,
      lastError: _lastError,
      tracksLoaded: loaded,
    );
  }
}
