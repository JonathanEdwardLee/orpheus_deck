/// Shared types for [OrpheusRecorderEngine] implementations (N3E seam).
library;

/// Cassette deck has four tracks.
const int kOrpheusRecorderTrackCount = 4;

/// Native engine target rate; legacy UI still uses ms for display.
const int kOrpheusRecorderSampleRate = 48000;

/// Snapshot returned by [OrpheusRecorderEngine.getDiagnostics].
class OrpheusRecorderDiagnostics {
  const OrpheusRecorderDiagnostics({
    required this.engineId,
    required this.sampleRate,
    required this.currentTransportSample,
    required this.xRunCount,
    required this.isPlaying,
    required this.isRecording,
    this.lastError,
    this.tracksLoaded = 0,
    this.apiUsed,
    this.performanceMode,
    this.sharingMode,
  });

  final String engineId;
  final int sampleRate;
  final int currentTransportSample;
  final int xRunCount;
  final bool isPlaying;
  final bool isRecording;
  final String? lastError;

  /// Native-only hints (null for legacy placeholder).
  final int? tracksLoaded;
  final int? apiUsed;
  final int? performanceMode;
  final int? sharingMode;

  double get transportSeconds =>
      sampleRate > 0 ? currentTransportSample / sampleRate : 0;
}
