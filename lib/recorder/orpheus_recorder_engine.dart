/// Recorder engine seam between cassette UI and audio backends (N3E).
library;

export 'recorder_engine_types.dart';

import 'recorder_engine_types.dart';

/// Future transport/mixer backend for [RecorderScreen] (`lib/main.dart`).
///
/// Today the main recorder still calls `just_audio` and `AudioRecorder` directly.
/// Implementations must not run concurrently (one engine active per screen).
abstract class OrpheusRecorderEngine {
  /// Stable id: `'legacy'` or `'native'`.
  String get engineId;

  bool get isNative;

  bool get isPlaying;

  bool get isRecording;

  Future<void> initialize();

  Future<void> dispose();

  Future<void> loadProjectTracks({
    required List<String?> trackPaths,
    required List<int> trackTapeStartSamples,
    required List<int> recordLatencyOffsetSamples,
    required int sampleRate,
  });

  Future<void> startPlayback({
    required int startSample,
  });

  Future<void> startRecording({
    required int armedTrack,
    required int startSample,
    required String outputPath,
    required int defaultRecordLatencyOffsetSamples,
  });

  Future<void> stop();

  Future<void> setTrackGain(int index, double gain);

  Future<void> setTrackMute(int index, bool muted);

  Future<void> setTrackSolo(int index, bool solo);

  Future<int> getTransportSample();

  Future<OrpheusRecorderDiagnostics> getDiagnostics();
}
