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
    required this.compensatedAlignmentSuccess,
    required this.compensatedQualityPercent,
    required this.compensatedMedianResidualMsTimes1000,
    required this.perClickOffsetCount,
    required this.appliedCompensationSamples,
    required this.compensatedMedianResidualSamples,
    required this.compensatedResidualMinSamples,
    required this.compensatedResidualMaxSamples,
    required this.compensatedResidualSpreadSamples,
    required this.perClickOffsets,
    required this.perClickResiduals,
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

  final int compensatedAlignmentSuccess;
  final int compensatedQualityPercent;
  final int compensatedMedianResidualMsTimes1000;
  final int perClickOffsetCount;
  final int appliedCompensationSamples;
  final int compensatedMedianResidualSamples;
  final int compensatedResidualMinSamples;
  final int compensatedResidualMaxSamples;
  final int compensatedResidualSpreadSamples;
  final List<int> perClickOffsets;
  final List<int> perClickResiduals;

  double get backingDurationSec =>
      sampleRate > 0 ? backingFramesGenerated / sampleRate : 0;

  double get recordedDurationSec =>
      sampleRate > 0 ? recordedFramesWritten / sampleRate : 0;

  /// Display-only ms; samples remain source of truth.
  double get medianOffsetMs {
    if (sampleRate > 0) {
      return medianOffsetSamples * 1000.0 / sampleRate;
    }
    return medianOffsetMsTimes1000 / 1000.0;
  }

  double get compensatedMedianResidualMs {
    if (sampleRate > 0) {
      return compensatedMedianResidualSamples * 1000.0 / sampleRate;
    }
    return compensatedMedianResidualMsTimes1000 / 1000.0;
  }

  double get appliedCompensationMs =>
      sampleRate > 0 ? appliedCompensationSamples * 1000.0 / sampleRate : 0;
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

  @Int32()
  external int compensatedAlignmentSuccess;

  @Int32()
  external int compensatedQualityPercent;

  @Int32()
  external int compensatedMedianResidualMsTimes1000;

  @Int32()
  external int perClickOffsetCount;

  @Int64()
  external int appliedCompensationSamples;

  @Int64()
  external int compensatedMedianResidualSamples;

  @Int64()
  external int compensatedResidualMinSamples;

  @Int64()
  external int compensatedResidualMaxSamples;

  @Int64()
  external int compensatedResidualSpreadSamples;

  @Int64()
  external int perClickOffset0;

  @Int64()
  external int perClickOffset1;

  @Int64()
  external int perClickOffset2;

  @Int64()
  external int perClickOffset3;

  @Int64()
  external int perClickOffset4;

  @Int64()
  external int perClickOffset5;

  @Int64()
  external int perClickResidual0;

  @Int64()
  external int perClickResidual1;

  @Int64()
  external int perClickResidual2;

  @Int64()
  external int perClickResidual3;

  @Int64()
  external int perClickResidual4;

  @Int64()
  external int perClickResidual5;
}
