import 'dart:ffi';

/// Dart copy of native N3D four-track mixer diagnostics.
class OrpheusN3MixerDiagnosticsData {
  const OrpheusN3MixerDiagnosticsData({
    required this.sampleRate,
    required this.framesPerBurst,
    required this.bufferSizeInFrames,
    required this.xRunCount,
    required this.apiUsed,
    required this.performanceMode,
    required this.sharingMode,
    required this.outputStreamOpened,
    required this.tracksLoaded,
    required this.tracksActive,
    required this.soloActive,
    required this.playbackComplete,
    required this.isPlaying,
    required this.errorCode,
    required this.exclusiveAttempted,
    required this.sharedFallbackUsed,
    required this.track0GainTimes1000,
    required this.track1GainTimes1000,
    required this.track2GainTimes1000,
    required this.track3GainTimes1000,
    required this.track0Muted,
    required this.track1Muted,
    required this.track2Muted,
    required this.track3Muted,
    required this.track0Solo,
    required this.track1Solo,
    required this.track2Solo,
    required this.track3Solo,
    required this.currentTransportSample,
    required this.transportStartSample,
    required this.transportStopSample,
    required this.outputCallbackCount,
    required this.track0StartSample,
    required this.track1StartSample,
    required this.track2StartSample,
    required this.track3StartSample,
    required this.track0EffectiveStartSample,
    required this.track1EffectiveStartSample,
    required this.track2EffectiveStartSample,
    required this.track3EffectiveStartSample,
    required this.track0FramesMixed,
    required this.track1FramesMixed,
    required this.track2FramesMixed,
    required this.track3FramesMixed,
  });

  final int sampleRate;
  final int framesPerBurst;
  final int bufferSizeInFrames;
  final int xRunCount;
  final int apiUsed;
  final int performanceMode;
  final int sharingMode;
  final int outputStreamOpened;
  final int tracksLoaded;
  final int tracksActive;
  final int soloActive;
  final int playbackComplete;
  final int isPlaying;
  final int errorCode;
  final int exclusiveAttempted;
  final int sharedFallbackUsed;
  final int track0GainTimes1000;
  final int track1GainTimes1000;
  final int track2GainTimes1000;
  final int track3GainTimes1000;
  final int track0Muted;
  final int track1Muted;
  final int track2Muted;
  final int track3Muted;
  final int track0Solo;
  final int track1Solo;
  final int track2Solo;
  final int track3Solo;
  final int currentTransportSample;
  final int transportStartSample;
  final int transportStopSample;
  final int outputCallbackCount;
  final int track0StartSample;
  final int track1StartSample;
  final int track2StartSample;
  final int track3StartSample;
  final int track0EffectiveStartSample;
  final int track1EffectiveStartSample;
  final int track2EffectiveStartSample;
  final int track3EffectiveStartSample;
  final int track0FramesMixed;
  final int track1FramesMixed;
  final int track2FramesMixed;
  final int track3FramesMixed;

  double get transportSeconds =>
      sampleRate > 0 ? currentTransportSample / sampleRate : 0;

  List<int> get trackStartSamples => [
        track0StartSample,
        track1StartSample,
        track2StartSample,
        track3StartSample,
      ];

  List<int> get trackEffectiveStartSamples => [
        track0EffectiveStartSample,
        track1EffectiveStartSample,
        track2EffectiveStartSample,
        track3EffectiveStartSample,
      ];

  List<int> get trackFramesMixed => [
        track0FramesMixed,
        track1FramesMixed,
        track2FramesMixed,
        track3FramesMixed,
      ];

  bool get diagnosticsPlausible {
    if (tracksLoaded < 0 || tracksLoaded > 4) {
      return false;
    }
    if (outputCallbackCount < 0 || outputCallbackCount > 50000000) {
      return false;
    }
    if (currentTransportSample < 0 ||
        currentTransportSample > transportStopSample + sampleRate) {
      return false;
    }
    return true;
  }
}

/// Must match OrpheusN3MixerDiagnostics in audio_types.h (256 bytes).
@Packed(8)
final class OrpheusN3MixerDiagnostics extends Struct {
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
  external int tracksLoaded;

  @Int32()
  external int tracksActive;

  @Int32()
  external int soloActive;

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
  external int track0GainTimes1000;

  @Int32()
  external int track1GainTimes1000;

  @Int32()
  external int track2GainTimes1000;

  @Int32()
  external int track3GainTimes1000;

  @Int32()
  external int track0Muted;

  @Int32()
  external int track1Muted;

  @Int32()
  external int track2Muted;

  @Int32()
  external int track3Muted;

  @Int32()
  external int track0Solo;

  @Int32()
  external int track1Solo;

  @Int32()
  external int track2Solo;

  @Int32()
  external int track3Solo;

  @Int32()
  external int paddingForInt64Align;

  @Int32()
  external int padding2;

  @Int32()
  external int padding3;

  @Int32()
  external int padding4;

  @Int64()
  external int currentTransportSample;

  @Int64()
  external int transportStartSample;

  @Int64()
  external int transportStopSample;

  @Int64()
  external int outputCallbackCount;

  @Int64()
  external int track0StartSample;

  @Int64()
  external int track1StartSample;

  @Int64()
  external int track2StartSample;

  @Int64()
  external int track3StartSample;

  @Int64()
  external int track0EffectiveStartSample;

  @Int64()
  external int track1EffectiveStartSample;

  @Int64()
  external int track2EffectiveStartSample;

  @Int64()
  external int track3EffectiveStartSample;

  @Int64()
  external int track0FramesMixed;

  @Int64()
  external int track1FramesMixed;

  @Int64()
  external int track2FramesMixed;

  @Int64()
  external int track3FramesMixed;
}
