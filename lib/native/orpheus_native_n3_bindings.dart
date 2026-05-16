import 'dart:ffi';

/// Dart copy of native N3B playback diagnostics.
class OrpheusN3PlaybackDiagnosticsData {
  const OrpheusN3PlaybackDiagnosticsData({
    required this.sampleRate,
    required this.framesPerBurst,
    required this.bufferSizeInFrames,
    required this.xRunCount,
    required this.apiUsed,
    required this.performanceMode,
    required this.sharingMode,
    required this.outputStreamOpened,
    required this.wavLoadSuccess,
    required this.wavSampleRate,
    required this.wavChannels,
    required this.playbackComplete,
    required this.isPlaying,
    required this.errorCode,
    required this.exclusiveAttempted,
    required this.sharedFallbackUsed,
    required this.wavTotalFrames,
    required this.playbackStartSample,
    required this.playbackStopSample,
    required this.currentTransportSample,
    required this.outputCallbackCount,
  });

  final int sampleRate;
  final int framesPerBurst;
  final int bufferSizeInFrames;
  final int xRunCount;
  final int apiUsed;
  final int performanceMode;
  final int sharingMode;
  final int outputStreamOpened;
  final int wavLoadSuccess;
  final int wavSampleRate;
  final int wavChannels;
  final int playbackComplete;
  final int isPlaying;
  final int errorCode;
  final int exclusiveAttempted;
  final int sharedFallbackUsed;
  final int wavTotalFrames;
  final int playbackStartSample;
  final int playbackStopSample;
  final int currentTransportSample;
  final int outputCallbackCount;

  double get transportSeconds =>
      sampleRate > 0 ? currentTransportSample / sampleRate : 0;

  double get wavDurationSeconds =>
      wavSampleRate > 0 ? wavTotalFrames / wavSampleRate : 0;
}

/// Must match OrpheusN3PlaybackDiagnostics in audio_types.h.
@Packed(4)
final class OrpheusN3PlaybackDiagnostics extends Struct {
  @Int32()
  external int sampleRate;

  @Int32()
  external int framesPerBurst;

  @Int32()
  external int bufferSizeInFrames;

  @Int32()
  external int xRunCount;

  @Int32()
  external int apiUsed;

  @Int32()
  external int performanceMode;

  @Int32()
  external int sharingMode;

  @Int32()
  external int outputStreamOpened;

  @Int32()
  external int wavLoadSuccess;

  @Int32()
  external int wavSampleRate;

  @Int32()
  external int wavChannels;

  @Int32()
  external int playbackComplete;

  @Int32()
  external int isPlaying;

  @Int32()
  external int errorCode;

  @Int32()
  external int exclusiveAttempted;

  @Int32()
  external int sharedFallbackUsed;

  @Int32()
  external int paddingForInt64Align;

  @Int64()
  external int wavTotalFrames;

  @Int64()
  external int playbackStartSample;

  @Int64()
  external int playbackStopSample;

  @Int64()
  external int currentTransportSample;

  @Int64()
  external int outputCallbackCount;
}
