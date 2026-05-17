import 'dart:ffi';

/// Dart copy of native N3C overdub diagnostics.
class OrpheusN3OverdubDiagnosticsData {
  const OrpheusN3OverdubDiagnosticsData({
    required this.sampleRate,
    required this.framesPerBurst,
    required this.bufferSizeInFrames,
    required this.xRunCount,
    required this.apiUsed,
    required this.performanceMode,
    required this.sharingMode,
    required this.inputStreamOpened,
    required this.outputStreamOpened,
    required this.backingWavLoadSuccess,
    required this.wavWriteSuccess,
    required this.playbackComplete,
    required this.recordSuccess,
    required this.errorCode,
    required this.exclusiveAttempted,
    required this.sharedFallbackUsed,
    required this.analysisSuccess,
    required this.compensatedAlignmentSuccess,
    required this.clicksDetected,
    required this.clicksExpected,
    required this.confidencePercent,
    required this.medianOffsetMsTimes1000,
    required this.compensatedQualityPercent,
    required this.profileResidualMsTimes1000,
    required this.profileCompensationResult,
    required this.recordedFramesSanity,
    required this.backingWavTotalFrames,
    required this.backingStartSample,
    required this.recordStartSample,
    required this.defaultRecordLatencyOffsetSamples,
    required this.effectiveRecordStartSample,
    required this.recordedFramesWritten,
    required this.currentTransportSample,
    required this.transportStopSample,
    required this.outputCallbackCount,
    required this.inputCallbackCount,
    required this.measuredMedianOffsetSamples,
    required this.measuredSelfResidualSamples,
    required this.profileResidualSamples,
    required this.expectedRecordedFrames,
  });

  final int sampleRate;
  final int framesPerBurst;
  final int bufferSizeInFrames;
  final int xRunCount;
  final int apiUsed;
  final int performanceMode;
  final int sharingMode;
  final int inputStreamOpened;
  final int outputStreamOpened;
  final int backingWavLoadSuccess;
  final int wavWriteSuccess;
  final int playbackComplete;
  final int recordSuccess;
  final int errorCode;
  final int exclusiveAttempted;
  final int sharedFallbackUsed;
  final int analysisSuccess;
  final int compensatedAlignmentSuccess;
  final int clicksDetected;
  final int clicksExpected;
  final int confidencePercent;
  final int medianOffsetMsTimes1000;
  final int compensatedQualityPercent;
  final int profileResidualMsTimes1000;
  /// 0 = UNSTABLE, 1 = OK, 2 = PASS.
  final int profileCompensationResult;
  final int recordedFramesSanity;
  final int backingWavTotalFrames;
  final int backingStartSample;
  final int recordStartSample;
  final int defaultRecordLatencyOffsetSamples;
  final int effectiveRecordStartSample;
  final int recordedFramesWritten;
  final int currentTransportSample;
  final int transportStopSample;
  final int outputCallbackCount;
  final int inputCallbackCount;
  final int measuredMedianOffsetSamples;
  final int measuredSelfResidualSamples;
  final int profileResidualSamples;
  final int expectedRecordedFrames;

  double get transportSeconds =>
      sampleRate > 0 ? currentTransportSample / sampleRate : 0;

  double get measuredMedianOffsetMs =>
      sampleRate > 0
          ? measuredMedianOffsetSamples * 1000.0 / sampleRate
          : medianOffsetMsTimes1000 / 1000.0;

  double get profileOffsetMs =>
      sampleRate > 0
          ? defaultRecordLatencyOffsetSamples * 1000.0 / sampleRate
          : 0;

  double get profileResidualMs =>
      sampleRate > 0
          ? profileResidualSamples * 1000.0 / sampleRate
          : profileResidualMsTimes1000 / 1000.0;

  double get measuredSelfResidualMs =>
      sampleRate > 0 ? measuredSelfResidualSamples * 1000.0 / sampleRate : 0;

  String get profileCompensationResultLabel {
    switch (profileCompensationResult) {
      case 2:
        return 'PASS';
      case 1:
        return 'OK';
      default:
        return 'UNSTABLE';
    }
  }

  String get recordedFramesSanityLabel =>
      recordedFramesSanity == 1 ? 'OK' : 'WARNING';

  int get recordedFramesDelta =>
      (recordedFramesWritten - expectedRecordedFrames).abs();

  bool get diagnosticsPlausible {
    if (backingWavLoadSuccess == 1 &&
        (backingWavTotalFrames <= 0 || backingWavTotalFrames > 50000000)) {
      return false;
    }
    if (outputCallbackCount < 0 || outputCallbackCount > 50000000) {
      return false;
    }
    return true;
  }
}

/// Must match OrpheusN3OverdubDiagnostics in audio_types.h (sizeof == 224).
@Packed(8)
final class OrpheusN3OverdubDiagnostics extends Struct {
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
  external int inputStreamOpened;

  @Int32()
  external int outputStreamOpened;

  @Int32()
  external int backingWavLoadSuccess;

  @Int32()
  external int wavWriteSuccess;

  @Int32()
  external int playbackComplete;

  @Int32()
  external int recordSuccess;

  @Int32()
  external int errorCode;

  @Int32()
  external int exclusiveAttempted;

  @Int32()
  external int sharedFallbackUsed;

  @Int32()
  external int analysisSuccess;

  @Int32()
  external int compensatedAlignmentSuccess;

  @Int32()
  external int clicksDetected;

  @Int32()
  external int clicksExpected;

  @Int32()
  external int confidencePercent;

  @Int32()
  external int medianOffsetMsTimes1000;

  @Int32()
  external int compensatedQualityPercent;

  @Int32()
  external int profileResidualMsTimes1000;

  @Int32()
  external int profileCompensationResult;

  @Int32()
  external int recordedFramesSanity;

  @Int32()
  external int paddingForInt64Align;

  @Int64()
  external int backingWavTotalFrames;

  @Int64()
  external int backingStartSample;

  @Int64()
  external int recordStartSample;

  @Int64()
  external int defaultRecordLatencyOffsetSamples;

  @Int64()
  external int effectiveRecordStartSample;

  @Int64()
  external int recordedFramesWritten;

  @Int64()
  external int currentTransportSample;

  @Int64()
  external int transportStopSample;

  @Int64()
  external int outputCallbackCount;

  @Int64()
  external int inputCallbackCount;

  @Int64()
  external int measuredMedianOffsetSamples;

  @Int64()
  external int measuredSelfResidualSamples;

  @Int64()
  external int profileResidualSamples;

  @Int64()
  external int expectedRecordedFrames;
}
