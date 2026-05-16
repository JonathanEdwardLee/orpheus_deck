import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'orpheus_native_bindings.dart';
import 'orpheus_native_duplex_bindings.dart';
import 'orpheus_native_labels.dart';
import 'orpheus_native_latency_profile.dart';
import 'orpheus_native_n3_bindings.dart';
import 'orpheus_native_n3c_bindings.dart';

/// Phase N1 — Oboe handshake orchestration (no main recorder integration).
class OrpheusNativeAudio {
  OrpheusNativeAudio._();

  static final OrpheusNativeAudio instance = OrpheusNativeAudio._();

  OrpheusNativeBindings? _bindings;
  String? _lastWavPath;
  String? _lastN2WavPath;
  String? _n3WavPath;
  bool _n3SessionOpen = false;

  String? _n3cBackingPath;
  String? _lastN3cRecordPath;
  bool _n3cSessionOpen = false;
  int? _lastN2eRecommendedOffsetSamples;

  /// Dev-only fallback when N2E profile is not in memory (not production settings).
  static const int devDefaultRecordLatencyOffsetSamples = 2900;

  bool get isAndroid => Platform.isAndroid;

  String? get lastWavPath => _lastWavPath;

  String? get lastN2WavPath => _lastN2WavPath;

  String? get lastN3WavPath => _n3WavPath;

  String? get lastN3cRecordPath => _lastN3cRecordPath;

  String? get lastN3cBackingPath => _n3cBackingPath;

  bool get isN3SessionOpen => _n3SessionOpen;

  int get recordLatencyOffsetForNativeTest =>
      _lastN2eRecommendedOffsetSamples ?? devDefaultRecordLatencyOffsetSamples;

  void rememberN2eRecommendedOffset(int? samples) {
    _lastN2eRecommendedOffsetSamples = samples;
  }

  OrpheusNativeBindings get bindings {
    if (!isAndroid) {
      throw UnsupportedError('Native audio requires Android');
    }
    return _bindings ??= OrpheusNativeBindings.instance;
  }

  Future<void> ensureMicPermission() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw StateError('Microphone permission denied');
    }
  }

  void _check(int code, OrpheusNativeBindings b) {
    if (code != 0) {
      throw StateError(b.readLastError());
    }
  }

  Future<OrpheusNativeDiagnosticsData> runHandshake({
    int recordDurationMs = 2500,
    Duration finalizeTimeout = const Duration(seconds: 8),
  }) async {
    await ensureMicPermission();
    final b = bindings;

    _check(b.init(), b);
    try {
      _check(b.openStreams(), b);

      _check(b.playImpulse(), b);

      final dir = await getTemporaryDirectory();
      final wavPath =
          '${dir.path}/orpheus_n1_handshake_${DateTime.now().millisecondsSinceEpoch}.wav';
      _lastWavPath = wavPath;

      final pathPtr = wavPath.toNativeUtf8();
      try {
        _check(b.startRecord(pathPtr, recordDurationMs), b);
      } finally {
        malloc.free(pathPtr);
      }

      await Future<void>.delayed(
        Duration(milliseconds: recordDurationMs + 400),
      );
      _check(b.stopRecord(), b);

      final deadline = DateTime.now().add(finalizeTimeout);
      OrpheusNativeDiagnosticsData diag;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        diag = b.readDiagnostics();
        if (diag.wavWriteSuccess == 1) {
          break;
        }
      } while (DateTime.now().isBefore(deadline));

      if (diag.wavWriteSuccess != 1) {
        throw StateError('WAV finalize timeout or failed');
      }

      final file = File(wavPath);
      if (!await file.exists() || await file.length() < 44) {
        throw StateError('WAV missing or too small');
      }

      debugPrint(
        'Orpheus N1: handshake OK — ${OrpheusNativeLabels.formatDiagnosticsSummary(diag)} '
        'path=$wavPath',
      );
      return diag;
    } finally {
      b.shutdown();
      _bindings = null;
    }
  }

  /// Phase N2 — full-duplex click backing + mic record (dev only).
  Future<OrpheusDuplexDiagnosticsData> runDuplexTest({
    Duration completeTimeout = const Duration(seconds: 12),
  }) async {
    await ensureMicPermission();
    final b = bindings;

    _check(b.n2Init(), b);
    try {
      _check(b.n2OpenStreams(), b);

      final dir = await getTemporaryDirectory();
      final wavPath =
          '${dir.path}/orpheus_n2_duplex_${DateTime.now().millisecondsSinceEpoch}.wav';
      _lastN2WavPath = wavPath;

      final pathPtr = wavPath.toNativeUtf8();
      try {
        _check(b.n2StartDuplex(pathPtr), b);
      } finally {
        malloc.free(pathPtr);
      }

      final deadline = DateTime.now().add(completeTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (b.n2IsComplete() == 1) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final diag = b.readDuplexDiagnostics();
      if (diag.wavWriteSuccess != 1) {
        throw StateError('N2 duplex did not complete or WAV write failed');
      }

      final file = File(wavPath);
      if (!await file.exists() || await file.length() < 44) {
        throw StateError('N2 WAV missing or too small');
      }

      debugPrint(
        'Orpheus N2: duplex OK — ${OrpheusNativeLabels.formatDuplexSummary(diag)} '
        'path=$wavPath',
      );
      return diag;
    } finally {
      b.n2Shutdown();
      _bindings = null;
    }
  }

  /// Phase N2E — run [passCount] N2 passes and select recommended latency offset.
  Future<OrpheusLatencyProfileResult> runCalibrationProfile({
    int passCount = OrpheusLatencyProfile.defaultPassCount,
    Duration pauseBetweenPasses = const Duration(seconds: 2),
    void Function(int currentPass, int totalPasses)? onPassStarted,
  }) async {
    final passes = <OrpheusN2ePassRecord>[];
    for (var i = 0; i < passCount; i++) {
      onPassStarted?.call(i + 1, passCount);
      if (i > 0) {
        await Future<void>.delayed(pauseBetweenPasses);
      }
      final diag = await runDuplexTest();
      passes.add(OrpheusN2ePassRecord.evaluate(i + 1, diag));
    }
    final profile = OrpheusLatencyProfile.compute(passes);
    if (profile.profileSuccess && profile.recommendedOffsetSamples != null) {
      rememberN2eRecommendedOffset(profile.recommendedOffsetSamples);
    }
    debugPrint(
      'Orpheus N2E: ${profile.goodPassCount}/${profile.totalRuns} good — '
      '${OrpheusNativeLabels.formatLatencyProfile(profile)}',
    );
    return profile;
  }

  /// Phase N3B — open session, generate/load 8 s test WAV, open Oboe output.
  Future<String> ensureN3bSession() async {
    if (_n3SessionOpen && _n3WavPath != null) {
      return _n3WavPath!;
    }
    final b = bindings;
    _check(b.n3Init(), b);

    final dir = await getTemporaryDirectory();
    final wavPath = '${dir.path}/orpheus_n3b_test.wav';
    final pathPtr = wavPath.toNativeUtf8();
    try {
      _check(b.n3GenerateTestWav(pathPtr), b);
    } finally {
      malloc.free(pathPtr);
    }
    _check(b.n3OpenStreams(), b);

    _n3WavPath = wavPath;
    _n3SessionOpen = true;
    debugPrint('Orpheus N3B: session ready path=$wavPath');
    return wavPath;
  }

  OrpheusN3PlaybackDiagnosticsData readN3Diagnostics() =>
      bindings.readN3Diagnostics();

  /// Start playback from [startSample] and poll until complete or [timeout].
  Future<OrpheusN3PlaybackDiagnosticsData> runN3bPlayback({
    int startSample = 0,
    Duration timeout = const Duration(seconds: 12),
    void Function(OrpheusN3PlaybackDiagnosticsData diag)? onTransportTick,
  }) async {
    final b = bindings;
    await ensureN3bSession();
    b.n3StopPlayback();
    _check(b.n3StartPlayback(startSample), b);

    final deadline = DateTime.now().add(timeout);
    OrpheusN3PlaybackDiagnosticsData diag = b.readN3Diagnostics();
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      diag = b.readN3Diagnostics();
      onTransportTick?.call(diag);
      if (b.n3IsPlaybackComplete() == 1) {
        break;
      }
      if (diag.isPlaying == 0 &&
          diag.currentTransportSample >= diag.playbackStopSample) {
        break;
      }
    }

    debugPrint(
      'Orpheus N3B: playback done transport=${diag.currentTransportSample} '
      'xruns=${diag.xRunCount} complete=${diag.playbackComplete}',
    );
    return diag;
  }

  Future<void> stopN3b() async {
    if (!_n3SessionOpen) {
      return;
    }
    final b = bindings;
    b.n3StopPlayback();
    b.n3Shutdown();
    _n3SessionOpen = false;
    _bindings = null;
    debugPrint('Orpheus N3B: session stopped');
  }

  OrpheusN3OverdubDiagnosticsData readN3cDiagnostics() =>
      bindings.readN3cDiagnostics();

  /// Phase N3C — WAV backing + mic overdub with shared transport (dev only).
  Future<OrpheusN3OverdubDiagnosticsData> runN3cOverdub({
    int backingStartSample = 0,
    Duration completeTimeout = const Duration(seconds: 14),
    void Function(OrpheusN3OverdubDiagnosticsData diag)? onTransportTick,
  }) async {
    await ensureMicPermission();
    await stopN3b();
    await stopN3c();

    final b = bindings;
    _check(b.n3cInit(), b);

    try {
      final dir = await getTemporaryDirectory();
      final backingPath = '${dir.path}/orpheus_n3c_backing.wav';
      final recordPath =
          '${dir.path}/orpheus_n3c_record_${DateTime.now().millisecondsSinceEpoch}.wav';

      final backingPtr = backingPath.toNativeUtf8();
      try {
        _check(b.n3cGenerateBackingWav(backingPtr), b);
      } finally {
        malloc.free(backingPtr);
      }

      final offset = recordLatencyOffsetForNativeTest;
      _check(b.n3cSetDefaultRecordLatencyOffset(offset), b);
      _check(b.n3cOpenStreams(), b);

      final recordPtr = recordPath.toNativeUtf8();
      try {
        _check(b.n3cStartOverdub(recordPtr, backingStartSample), b);
      } finally {
        malloc.free(recordPtr);
      }

      _n3cBackingPath = backingPath;
      _lastN3cRecordPath = recordPath;
      _n3cSessionOpen = true;

      final deadline = DateTime.now().add(completeTimeout);
      OrpheusN3OverdubDiagnosticsData diag = b.readN3cDiagnostics();
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        diag = b.readN3cDiagnostics();
        onTransportTick?.call(diag);
        if (b.n3cIsComplete() == 1) {
          break;
        }
      }

      if (diag.wavWriteSuccess != 1) {
        throw StateError('N3C overdub did not finalize WAV');
      }

      final file = File(recordPath);
      if (!await file.exists() || await file.length() < 44) {
        throw StateError('N3C record WAV missing or too small');
      }

      debugPrint(
        'Orpheus N3C: overdub OK transport=${diag.currentTransportSample} '
        'offset=$offset xruns=${diag.xRunCount} record=$recordPath',
      );
      return diag;
    } finally {
      // Keep session open for STOP / seek buttons until explicit stopN3c.
    }
  }

  Future<void> stopN3c() async {
    if (!_n3cSessionOpen && _bindings == null) {
      return;
    }
    final b = _bindings ?? OrpheusNativeBindings.instance;
    b.n3cStopOverdub();
    b.n3cShutdown();
    _n3cSessionOpen = false;
    if (_bindings != null) {
      _bindings = null;
    }
    debugPrint('Orpheus N3C: session stopped');
  }
}
