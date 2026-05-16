import 'dart:ffi';

/// Dart copy of native N2 duplex diagnostics (includes N2B timing fields).
class OrpheusDuplexDiagnosticsData {
  const OrpheusDuplexDiagnosticsData({
    required this.sampleRate,
    required this.framesPerBurst,
    required this.bufferSizeInFrames,
    required this.xRunCount,
    required this.apiUsed,
    required this.performanceMode,
    required this.sharingMode,
    required this.outputStreamOpened,
    required this.inputStreamOpened,
    required this.wavWriteSuccess,
    required this.backingPlaySuccess,
    required this.recordSuccess,
    required this.exclusiveAttempted,
    required this.sharedFallbackUsed,
    required this.lastOpenErrorCode,
    required this.androidSdkVersion,
    required this.backingFramesGenerated,
    required this.recordedFramesWritten,
    required this.transportStartSample,
    required this.transportStopSample,
    required this.outputCallbackCount,
    required this.inputCallbackCount,
    required this.firstOutputFrameSample,
    required this.firstInputFrameSample,
    required this.estimatedInputOutputDeltaSamples,
    required this.clicksExpected,
    required this.clicksDetected,
    required this.analysisSuccess,
    required this.analysisFailureReason,
    required this.confidencePercent,
    required this.medianOffsetMsTimes1000,
    required this.medianOffsetSamples,
    required this.minOffsetSamples,
    required this.maxOffsetSamples,
    required this.spreadSamples,
    required this.recordLatencyOffsetSamples,
  });

  final int sampleRate;
  final int framesPerBurst;
  final int bufferSizeInFrames;
  final int xRunCount;
  final int apiUsed;
  final int performanceMode;
  final int sharingMode;
  final int outputStreamOpened;
  final int inputStreamOpened;
  final int wavWriteSuccess;
  final int backingPlaySuccess;
  final int recordSuccess;
  final int exclusiveAttempted;
  final int sharedFallbackUsed;
  final int lastOpenErrorCode;
  final int androidSdkVersion;

  final int backingFramesGenerated;
  final int recordedFramesWritten;
  final int transportStartSample;
  final int transportStopSample;
  final int outputCallbackCount;
  final int inputCallbackCount;
  final int firstOutputFrameSample;
  final int firstInputFrameSample;
  final int estimatedInputOutputDeltaSamples;

  final int clicksExpected;
  final int clicksDetected;
  final int analysisSuccess;
  final int analysisFailureReason;
  final int confidencePercent;
  final int medianOffsetMsTimes1000;
  final int medianOffsetSamples;
  final int minOffsetSamples;
  final int maxOffsetSamples;
  final int spreadSamples;
  final int recordLatencyOffsetSamples;

  double get backingDurationSec =>
      sampleRate > 0 ? backingFramesGenerated / sampleRate : 0;

  double get recordedDurationSec =>
      sampleRate > 0 ? recordedFramesWritten / sampleRate : 0;

  double get medianOffsetMs => medianOffsetMsTimes1000 / 1000.0;
}

/// Must match OrpheusDuplexDiagnostics in audio_types.h.
@Packed(8)
final class OrpheusDuplexDiagnostics extends Struct {
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
  external int inputStreamOpened;

  @Int32()
  external int wavWriteSuccess;

  @Int32()
  external int backingPlaySuccess;

  @Int32()
  external int recordSuccess;

  @Int32()
  external int exclusiveAttempted;

  @Int32()
  external int sharedFallbackUsed;

  @Int32()
  external int lastOpenErrorCode;

  @Int32()
  external int androidSdkVersion;

  @Int32()
  external int paddingForInt64Align;

  @Int64()
  external int backingFramesGenerated;

  @Int64()
  external int recordedFramesWritten;

  @Int64()
  external int transportStartSample;

  @Int64()
  external int transportStopSample;

  @Int64()
  external int outputCallbackCount;

  @Int64()
  external int inputCallbackCount;

  @Int64()
  external int firstOutputFrameSample;

  @Int64()
  external int firstInputFrameSample;

  @Int64()
  external int estimatedInputOutputDeltaSamples;

  @Int32()
  external int clicksExpected;

  @Int32()
  external int clicksDetected;

  @Int32()
  external int analysisSuccess;

  @Int32()
  external int analysisFailureReason;

  @Int32()
  external int confidencePercent;

  @Int32()
  external int medianOffsetMsTimes1000;

  @Int32()
  external int timingPadding;

  @Int64()
  external int medianOffsetSamples;

  @Int64()
  external int minOffsetSamples;

  @Int64()
  external int maxOffsetSamples;

  @Int64()
  external int spreadSamples;

  @Int64()
  external int recordLatencyOffsetSamples;
}
