import 'orpheus_native_duplex_bindings.dart';

/// One N2E calibration pass (N2 full-duplex + N2B/N2D diagnostics).
class OrpheusN2ePassRecord {
  const OrpheusN2ePassRecord({
    required this.runIndex,
    required this.diagnostics,
    required this.isGood,
    this.rejectReason,
  });

  final int runIndex;
  final OrpheusDuplexDiagnosticsData diagnostics;
  final bool isGood;
  final String? rejectReason;

  factory OrpheusN2ePassRecord.evaluate(
    int runIndex,
    OrpheusDuplexDiagnosticsData d,
  ) {
    final reason = _rejectReason(d);
    return OrpheusN2ePassRecord(
      runIndex: runIndex,
      diagnostics: d,
      isGood: reason == null,
      rejectReason: reason,
    );
  }

  static String? _rejectReason(OrpheusDuplexDiagnosticsData d) {
    if (d.analysisSuccess != 1) {
      return 'timing analysis failed';
    }
    if (d.compensatedAlignmentSuccess != 1) {
      return 'compensation proof failed';
    }
    if (d.clicksDetected < 5) {
      return 'clicksDetected < 5';
    }
    if (d.confidencePercent < 80) {
      return 'confidence < 80%';
    }
    if (d.spreadSamples > 1000) {
      return 'spread > 1000 samples';
    }
    if (d.xRunCount > 0) {
      return 'xRunCount > 0';
    }
    return null;
  }
}

/// N2E multi-pass profile result (engineering only — not production settings).
class OrpheusLatencyProfileResult {
  const OrpheusLatencyProfileResult({
    required this.totalRuns,
    required this.goodPassCount,
    required this.passes,
    required this.profileSuccess,
    required this.qualityLabel,
    required this.profileQualityPercent,
    this.sampleRate,
    this.recommendedOffsetSamples,
    this.recommendedOffsetMs,
    this.profileSpreadSamples,
    this.failureMessage,
  });

  final int totalRuns;
  final int goodPassCount;
  final List<OrpheusN2ePassRecord> passes;
  final bool profileSuccess;
  final int? sampleRate;
  final int? recommendedOffsetSamples;
  final double? recommendedOffsetMs;
  final int? profileSpreadSamples;
  final String qualityLabel;
  final int profileQualityPercent;
  final String? failureMessage;

  /// Dev-only label for future N3 wiring — not persisted to main recorder.
  static const String devOnlyFieldName = 'defaultRecordLatencyOffsetSamples';
}

/// Selects a recommended record latency offset from multiple N2 passes.
class OrpheusLatencyProfile {
  OrpheusLatencyProfile._();

  static const int defaultPassCount = 3;
  static const int minGoodPasses = 2;
  static const int spreadGoodMaxSamples = 1000;
  static const int spreadOkMaxSamples = 2000;

  static OrpheusLatencyProfileResult compute(List<OrpheusN2ePassRecord> passes) {
    final totalRuns = passes.length;
    final good = passes.where((p) => p.isGood).toList();
    final goodCount = good.length;

    if (goodCount < minGoodPasses) {
      return OrpheusLatencyProfileResult(
        totalRuns: totalRuns,
        goodPassCount: goodCount,
        passes: passes,
        profileSuccess: false,
        qualityLabel: 'UNSTABLE',
        profileQualityPercent: 0,
        failureMessage:
            'Fewer than $minGoodPasses good passes. Turn volume up, keep room '
            'quiet, use phone speaker, keep phone still, then rerun.',
      );
    }

    final offsets = good.map((p) => p.diagnostics.medianOffsetSamples).toList()
      ..sort();
    final recommended = _medianInt(offsets);
    final spread = offsets.last - offsets.first;
    final rate = good.last.diagnostics.sampleRate;
    final recommendedMs =
        rate > 0 ? recommended * 1000.0 / rate : 0.0;

    final qualityLabel = _qualityLabel(goodCount, spread);
    final qualityPercent = _profileQualityPercent(goodCount, totalRuns, spread);

    return OrpheusLatencyProfileResult(
      totalRuns: totalRuns,
      goodPassCount: goodCount,
      passes: passes,
      profileSuccess: true,
      sampleRate: rate,
      recommendedOffsetSamples: recommended,
      recommendedOffsetMs: recommendedMs,
      profileSpreadSamples: spread,
      qualityLabel: qualityLabel,
      profileQualityPercent: qualityPercent,
    );
  }

  static String _qualityLabel(int goodCount, int spread) {
    if (goodCount >= defaultPassCount && spread <= spreadGoodMaxSamples) {
      return 'GOOD';
    }
    if (goodCount >= minGoodPasses && spread <= spreadOkMaxSamples) {
      return 'OK';
    }
    return 'UNSTABLE';
  }

  static int _profileQualityPercent(
    int goodCount,
    int totalRuns,
    int spread,
  ) {
    var score = goodCount >= defaultPassCount ? 92 : 78;
    if (spread <= spreadGoodMaxSamples) {
      score += 8;
    } else if (spread <= spreadOkMaxSamples) {
      score += 2;
    } else {
      score -= 25;
    }
    if (goodCount < totalRuns) {
      score -= (totalRuns - goodCount) * 8;
    }
    if (spread > spreadGoodMaxSamples) {
      final penalty = ((spread - spreadGoodMaxSamples) * 15) ~/ spreadOkMaxSamples;
      score -= penalty.clamp(0, 30);
    }
    return score.clamp(0, 100);
  }

  static int _medianInt(List<int> sorted) {
    if (sorted.isEmpty) {
      return 0;
    }
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }
}
