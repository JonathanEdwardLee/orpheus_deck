import 'orpheus_native_bindings.dart';
import 'orpheus_native_duplex_bindings.dart';
import 'orpheus_native_latency_profile.dart';
import 'orpheus_native_n3_bindings.dart';
import 'orpheus_native_n3c_bindings.dart';

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

  static String timingFailureMessage(int reason) {
    switch (reason) {
      case 1:
        return 'Recorded buffer too short for analysis.';
      case 2:
        return 'No clicks detected in recording.';
      case 3:
        return 'Too few click matches for reliable median.';
      case 4:
        return 'Offset spread too large between clicks.';
      default:
        return 'Timing analysis failed (code $reason).';
    }
  }

  static String timingQualityLabel(OrpheusDuplexDiagnosticsData d) {
    if (d.analysisSuccess == 1 &&
        d.clicksDetected >= 5 &&
        d.confidencePercent >= 80 &&
        d.spreadSamples <= 1000) {
      return 'QUALITY: GOOD';
    }
    return 'QUALITY: UNSTABLE';
  }

  /// N2B engineering validation block (not user calibration).
  static String formatTimingAnalysis(OrpheusDuplexDiagnosticsData d) {
    final quality = timingQualityLabel(d);
    if (d.analysisSuccess != 1) {
      return '$quality\n'
          'TIMING ANALYSIS FAILED\n'
          '${timingFailureMessage(d.analysisFailureReason)}\n'
          'CLICKS DETECTED: ${d.clicksDetected} / ${d.clicksExpected}\n'
          'USE PHONE SPEAKER. TURN VOLUME UP.\n'
          'MIC MUST HEAR THE CLICKS.';
    }
    return '$quality\n'
        'TIMING ANALYSIS\n'
        'CLICKS DETECTED: ${d.clicksDetected} / ${d.clicksExpected}\n'
        'MEDIAN OFFSET: ${d.medianOffsetSamples} SAMPLES / '
        '${d.medianOffsetMs.toStringAsFixed(1)} MS\n'
        'SPREAD: ${d.spreadSamples} SAMPLES '
        '(${d.minOffsetSamples} … ${d.maxOffsetSamples})\n'
        'CONFIDENCE: ${d.confidencePercent}%\n'
        'recordLatencyOffsetSamples: ${d.recordLatencyOffsetSamples}\n'
        'RUN 2–3 TIMES. USE A CONSISTENT VALUE.';
  }

  static String compensationResultLabel(OrpheusDuplexDiagnosticsData d) {
    if (d.compensatedAlignmentSuccess == 1) {
      return 'RESULT: PASS';
    }
    return 'RESULT: UNSTABLE';
  }

  /// N2D: proves median offset can align a recorded take (engineering only).
  static String formatCompensationProof(OrpheusDuplexDiagnosticsData d) {
    final result = compensationResultLabel(d);
    if (d.perClickOffsetCount == 0 && d.analysisSuccess != 1) {
      return 'COMPENSATION PROOF\n'
          'Run N2 with timing analysis first.\n'
          '$result';
    }
    return 'COMPENSATION PROOF\n'
        'UNCOMPENSATED: ${d.medianOffsetSamples} SAMPLES / '
        '${d.medianOffsetMs.toStringAsFixed(1)} MS\n'
        'APPLIED: ${d.appliedCompensationSamples} SAMPLES / '
        '${d.appliedCompensationMs.toStringAsFixed(1)} MS\n'
        'RESIDUAL: ${d.compensatedMedianResidualSamples} SAMPLES / '
        '${d.compensatedMedianResidualMs.toStringAsFixed(1)} MS\n'
        'RESIDUAL SPREAD: ${d.compensatedResidualSpreadSamples} SAMPLES '
        '(${d.compensatedResidualMinSamples} … ${d.compensatedResidualMaxSamples})\n'
        '$result\n'
        'QUALITY: ${d.compensatedQualityPercent}%\n'
        'This proves the measured offset can align a recorded take.\n'
        'This is still an engineering test, not the final user latency test.';
  }

  static String formatPerClickOffsets(OrpheusDuplexDiagnosticsData d) {
    final n = d.perClickOffsetCount;
    if (n <= 0) {
      return '';
    }
    final buf = StringBuffer('PER-CLICK OFFSETS:\n');
    for (var i = 0; i < n && i < d.perClickOffsets.length; i++) {
      final off = d.perClickOffsets[i];
      final res = i < d.perClickResiduals.length ? d.perClickResiduals[i] : 0;
      buf.writeln('click ${i + 1} offset $off samples (residual $res)');
    }
    return buf.toString().trimRight();
  }

  /// N2E multi-pass profile block (engineering — not saved to main recorder).
  static String formatLatencyProfile(OrpheusLatencyProfileResult p) {
    final buf = StringBuffer('N2E CALIBRATION PROFILE\n');
    buf.writeln('RUNS GOOD: ${p.goodPassCount} / ${p.totalRuns}');

    if (!p.profileSuccess) {
      buf.writeln('PROFILE: FAILED');
      if (p.failureMessage != null) {
        buf.writeln(p.failureMessage);
      }
      buf.writeln('QUALITY: ${p.qualityLabel}');
      buf.writeln(_n2eInstructions);
      return buf.toString().trimRight();
    }

    final ms = p.recommendedOffsetMs ?? 0;
    buf.writeln(
      'RECOMMENDED OFFSET: ${p.recommendedOffsetSamples} SAMPLES / '
      '${ms.toStringAsFixed(1)} MS',
    );
    buf.writeln('PROFILE SPREAD: ${p.profileSpreadSamples} SAMPLES');
    buf.writeln('QUALITY: ${p.qualityLabel}');
    buf.writeln('PROFILE CONFIDENCE: ${p.profileQualityPercent}%');
    buf.writeln(
      '${OrpheusLatencyProfileResult.devOnlyFieldName}: '
      '${p.recommendedOffsetSamples}',
    );
    buf.writeln(_n2eInstructions);
    return buf.toString().trimRight();
  }

  static const String _n2eInstructions =
      'USE PHONE SPEAKER.\n'
      'VOLUME UP.\n'
      'KEEP PHONE STILL.\n'
      'RUN AGAIN IF THE VALUE CHANGES A LOT.';

  static String formatN2ePassSummary(OrpheusN2ePassRecord pass) {
    final d = pass.diagnostics;
    final status = pass.isGood ? 'GOOD' : 'REJECTED';
    final detail = pass.isGood
        ? 'offset=${d.medianOffsetSamples} spread=${d.spreadSamples}'
        : (pass.rejectReason ?? 'unknown');
    return 'Run ${pass.runIndex}: $status — $detail';
  }

  static String formatN3cOverdub(OrpheusN3OverdubDiagnosticsData d) {
    if (!d.diagnosticsPlausible) {
      return 'N3C OVERDUB TEST\n'
          'N3C DIAGNOSTICS INVALID\n'
          '(check @Packed(8) FFI layout)\n'
          'RAW frames=${d.backingWavTotalFrames} transport=${d.currentTransportSample}';
    }
    const devDefault = 2900;
    final offsetLabel = d.defaultRecordLatencyOffsetSamples == devDefault
        ? 'DEV DEFAULT ONLY'
        : 'FROM N2E PROFILE (dev memory)';
    return 'N3C OVERDUB TEST\n'
        'BACKING: ${d.backingWavTotalFrames} frames @ ${d.sampleRate} Hz\n'
        'RECORD START: ${d.recordStartSample} samples\n'
        'PROFILE OFFSET USED: ${d.defaultRecordLatencyOffsetSamples} samples / '
        '${d.profileOffsetMs.toStringAsFixed(1)} ms ($offsetLabel)\n'
        'effectiveRecordStartSample: ${d.effectiveRecordStartSample}\n'
        'TRANSPORT: ${d.currentTransportSample} samples '
        '(${d.transportSeconds.toStringAsFixed(2)} s)\n'
        'RECORDED: ${d.recordedFramesWritten} / EXPECTED ${d.expectedRecordedFrames} '
        '(${d.recordedFramesSanityLabel}, delta ${d.recordedFramesDelta})\n'
        'PLAYBACK COMPLETE: ${d.playbackComplete == 1 ? 'YES' : 'NO'}\n'
        'RECORD SUCCESS: ${d.recordSuccess == 1 ? 'YES' : 'NO'}\n'
        'WAV WRITE: ${d.wavWriteSuccess == 1 ? 'YES' : 'NO'}\n'
        'XRUNS: ${d.xRunCount}\n'
        'API: ${apiUsed(d.apiUsed)} | ${performanceMode(d.performanceMode)} | '
        '${sharingMode(d.sharingMode)}\n'
        'ALIGNMENT PROOF (RECORDED MIC)\n'
        'CLICKS: ${d.clicksDetected} / ${d.clicksExpected}\n'
        'MEASURED OFFSET: ${d.measuredMedianOffsetSamples} samples / '
        '${d.measuredMedianOffsetMs.toStringAsFixed(1)} ms\n'
        'PROFILE OFFSET USED: ${d.defaultRecordLatencyOffsetSamples} samples / '
        '${d.profileOffsetMs.toStringAsFixed(1)} ms\n'
        'PROFILE RESIDUAL: ${d.profileResidualSamples} samples / '
        '${d.profileResidualMs.toStringAsFixed(1)} ms\n'
        'PROFILE RESULT: ${d.profileCompensationResultLabel}\n'
        'SELF-CHECK RESIDUAL: ${d.measuredSelfResidualSamples} samples / '
        '${d.measuredSelfResidualMs.toStringAsFixed(1)} ms\n'
        '(self-check applies measured median to same take — not profile proof)\n'
        'N2D SELF-CHECK PASS: ${d.compensatedAlignmentSuccess == 1 ? 'YES' : 'NO'} '
        '(${d.compensatedQualityPercent}%)';
  }

  static String formatN3bPlayback(OrpheusN3PlaybackDiagnosticsData d) {
    if (!d.diagnosticsPlausible) {
      return 'N3B ONE-TRACK PLAYBACK\n'
          'N3B DIAGNOSTICS INVALID\n'
          '(FFI struct mismatch or uninitialized — check @Packed(8) / C layout)\n'
          'RAW: wavFrames=${d.wavTotalFrames} transport=${d.currentTransportSample} '
          'callbacks=${d.outputCallbackCount}';
    }
    return 'N3B ONE-TRACK PLAYBACK\n'
        'WAV: ${d.wavSampleRate} Hz / ${d.wavChannels} ch / '
        '${d.wavTotalFrames} frames '
        '(${d.wavDurationSeconds.toStringAsFixed(1)} s)\n'
        'TRANSPORT: ${d.currentTransportSample} samples '
        '(${d.transportSeconds.toStringAsFixed(2)} s)\n'
        'RANGE: ${d.playbackStartSample} … ${d.playbackStopSample}\n'
        'PLAYING: ${d.isPlaying == 1 ? 'YES' : 'NO'}\n'
        'COMPLETE: ${d.playbackComplete == 1 ? 'YES' : 'NO'}\n'
        'XRUNS: ${d.xRunCount}\n'
        'API: ${apiUsed(d.apiUsed)} | '
        '${performanceMode(d.performanceMode)} | '
        '${sharingMode(d.sharingMode)}\n'
        'BURST / BUFFER: ${d.framesPerBurst} / ${d.bufferSizeInFrames}\n'
        'OUTPUT CALLBACKS: ${d.outputCallbackCount}';
  }

  static String copyRecommendedOffsetLine(OrpheusLatencyProfileResult p) {
    if (!p.profileSuccess || p.recommendedOffsetSamples == null) {
      return '';
    }
    return '${OrpheusLatencyProfileResult.devOnlyFieldName}='
        '${p.recommendedOffsetSamples}';
  }
}
