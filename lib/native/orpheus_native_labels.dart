import 'orpheus_native_bindings.dart';
import 'orpheus_native_duplex_bindings.dart';

/// Oboe 1.10 enum labels (see oboe/Definitions.h).
class OrpheusNativeLabels {
  OrpheusNativeLabels._();

  static String apiUsed(int value) {
    switch (value) {
      case 0:
        return 'Unspecified';
      case 1:
        return 'OpenSL ES';
      case 2:
        return 'AAudio';
      default:
        return 'Unknown';
    }
  }

  static String performanceMode(int value) {
    switch (value) {
      case 10:
        return 'None';
      case 11:
        return 'PowerSaving';
      case 12:
        return 'LowLatency';
      case 13:
        return 'PowerSavingOffloaded';
      default:
        return 'Unknown';
    }
  }

  static String sharingMode(int value) {
    switch (value) {
      case 0:
        return 'Exclusive';
      case 1:
        return 'Shared';
      default:
        return 'Unknown';
    }
  }

  static String oboeResult(int code) {
    if (code == 0) {
      return 'OK';
    }
    return 'Error $code';
  }

  static String formatDiagnosticsSummary(
    OrpheusNativeDiagnosticsData d,
  ) {
    final buf = StringBuffer()
      ..writeln('API: ${apiUsed(d.apiUsed)} (raw ${d.apiUsed})')
      ..writeln(
        'Performance: ${performanceMode(d.actualPerformanceMode)} '
        '(raw ${d.actualPerformanceMode})',
      )
      ..writeln(
        'Sharing: ${sharingMode(d.actualSharingMode)} '
        '(raw ${d.actualSharingMode})',
      )
      ..writeln('Sample rate: ${d.actualSampleRate} Hz (requested ${d.requestedSampleRate})')
      ..writeln('Burst: ${d.framesPerBurst}  Buffer: ${d.bufferSizeInFrames}')
      ..writeln('XRuns: ${d.xRunCount}')
      ..writeln('Android API: ${d.androidSdkVersion}')
      ..writeln('Exclusive attempted: ${d.exclusiveAttempted == 1 ? 'yes' : 'no'}')
      ..writeln('Shared fallback: ${d.sharedFallbackUsed == 1 ? 'yes' : 'no'}')
      ..writeln(
        'AudioApi set: ${d.unspecifiedAudioApi == 1 ? 'Unspecified (Oboe default)' : 'explicit'}',
      );
    if (d.lastOpenErrorCode != 0) {
      buf.writeln(
        'Last open error: ${oboeResult(d.lastOpenErrorCode)} (code ${d.lastOpenErrorCode})',
      );
    }
    if (d.apiUsed == 1 && d.androidSdkVersion >= 26) {
      buf.writeln(
        'Note: OpenSL ES was chosen by Oboe, not forced by Orpheus. '
        'See logcat tag OrpheusNative for open attempts.',
      );
    }
    return buf.toString().trimRight();
  }

  static String formatDuplexSummary(OrpheusDuplexDiagnosticsData d) {
    final buf = StringBuffer()
      ..writeln('API: ${apiUsed(d.apiUsed)} (raw ${d.apiUsed})')
      ..writeln(
        'Performance: ${performanceMode(d.performanceMode)} '
        '(raw ${d.performanceMode})',
      )
      ..writeln(
        'Sharing: ${sharingMode(d.sharingMode)} (raw ${d.sharingMode})',
      )
      ..writeln('Sample rate: ${d.sampleRate} Hz')
      ..writeln('Burst: ${d.framesPerBurst}  Buffer: ${d.bufferSizeInFrames}')
      ..writeln('XRuns: ${d.xRunCount}')
      ..writeln('Android API: ${d.androidSdkVersion}')
      ..writeln(
        'Backing: ${d.backingFramesGenerated} samples '
        '(${d.backingDurationSec.toStringAsFixed(1)} s, 6 clicks / 6 s generated)',
      )
      ..writeln(
        'Recorded: ${d.recordedFramesWritten} samples '
        '(${d.recordedDurationSec.toStringAsFixed(1)} s)',
      )
      ..writeln(
        'Transport samples: ${d.transportStartSample} → ${d.transportStopSample}',
      )
      ..writeln(
        'Callbacks: out=${d.outputCallbackCount} in=${d.inputCallbackCount}',
      )
      ..writeln(
        'First frames: out=${d.firstOutputFrameSample} in=${d.firstInputFrameSample}',
      )
      ..writeln(
        'Est. in/out delta: ${d.estimatedInputOutputDeltaSamples} samples',
      )
      ..writeln(
        'backingPlay=${d.backingPlaySuccess} record=${d.recordSuccess} '
        'wav=${d.wavWriteSuccess}',
      )
      ..writeln(
        'Exclusive attempted: ${d.exclusiveAttempted == 1 ? 'yes' : 'no'}',
      )
      ..writeln(
        'Shared fallback: ${d.sharedFallbackUsed == 1 ? 'yes' : 'no'}',
      );
    if (d.lastOpenErrorCode != 0) {
      buf.writeln(
        'Last open error: ${oboeResult(d.lastOpenErrorCode)} '
        '(code ${d.lastOpenErrorCode})',
      );
    }
    return buf.toString().trimRight();
  }
}
