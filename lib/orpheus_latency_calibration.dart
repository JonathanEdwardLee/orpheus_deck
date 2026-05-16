import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart' as as_sess;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Calibration outcome; caller persists via [OrpheusSettings].
class LatencyCalibResult {
  const LatencyCalibResult._({
    required this.ok,
    required this.medianMs,
    required this.userMessage,
  });

  final bool ok;
  final int medianMs;
  final String userMessage;

  factory LatencyCalibResult.success(int m) => LatencyCalibResult._(
        ok: true,
        medianMs: m,
        userMessage: 'LATENCY SET: $m MS',
      );

  factory LatencyCalibResult.fail(String m) =>
      LatencyCalibResult._(ok: false, medianMs: 0, userMessage: m);
}

/// Plays one sharp click → records WAV → detects first strong peak × 3, median.
class OrpheusLatencyCalibration {
  OrpheusLatencyCalibration._();

  static const int sampleRate = 44100;

  /// Time from recorder start → play() invocation (defines “expected click” time).
  static const int playbackDelayMs = 350;

  /// Ignore earlier samples during analysis (pre-roll rumble).
  static const int warmupDiscardMs = 320;

  static const int maxSpreadMs = 200;
  static const int clampMaxSavedMs = 500;

  static const String _noiseFail =
      'COULD NOT DETECT CLICK.\nTRY AGAIN IN A QUIET ROOM OR USE PHONE SPEAKER.';

  static Future<LatencyCalibResult> runCalibration() async {
    final recorder = AudioRecorder();

    Directory? workDir;
    File? calibrationClick;

    try {
      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        return LatencyCalibResult.fail('MIC PERMISSION DENIED');
      }

      await _configureAudioSession();

      final wd = Directory(
        '${(await getTemporaryDirectory()).path}/orc_lat_${DateTime.now().millisecondsSinceEpoch}',
      );
      await wd.create(recursive: true);
      workDir = wd;

      calibrationClick = File('${wd.path}/click.wav');
      await calibrationClick.writeAsBytes(buildCalibrationClickWav(), flush: true);

      if (!await recorder.hasPermission()) {
        return LatencyCalibResult.fail('MIC NOT AVAILABLE');
      }

      final results = <int>[];
      final clickPath = calibrationClick.path;
      for (var trial = 0; trial < 3; trial++) {
        final player = AudioPlayer();
        try {
          await player.setFilePath(clickPath);
          await player.setVolume(1.0);
          await player.seek(Duration.zero);

          final recordedPath =
              '${wd.path}/cap_$trial.${DateTime.now().microsecondsSinceEpoch}.wav';

          await recorder.start(
            const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 44100,
              numChannels: 1,
              bitRate: 128000,
              autoGain: false,
              echoCancel: false,
              noiseSuppress: false,
              audioInterruption: AudioInterruptionMode.none,
              androidConfig: AndroidRecordConfig(
                useLegacy: false,
                muteAudio: false,
                manageBluetooth: true,
                audioSource: AndroidAudioSource.mic,
                speakerphone: false,
                audioManagerMode: AudioManagerMode.modeNormal,
              ),
            ),
            path: recordedPath,
          );

          await Future<void>.delayed(
            const Duration(milliseconds: playbackDelayMs),
          );
          await player.play();

          await Future<void>.delayed(const Duration(milliseconds: 900));

          await recorder.stop();
          await player.stop();

          Int16List? pcm;
          final cap = File(recordedPath);
          try {
            if (cap.existsSync()) pcm = parseMono16Wav(await cap.readAsBytes());
          } finally {
            try {
              if (cap.existsSync()) cap.deleteSync();
            } catch (_) {}
          }

          final ms = pcm == null ? null : estimateRoundTripLatencyMs(pcm);
          if (ms != null) results.add(ms);
        } finally {
          await player.dispose();
        }

        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      if (results.length != 3) return LatencyCalibResult.fail(_noiseFail);
      results.sort();
      if (results[2] - results[0] > maxSpreadMs) {
        return LatencyCalibResult.fail(_noiseFail);
      }

      final median = results[1];
      return LatencyCalibResult.success(median.clamp(0, clampMaxSavedMs).toInt());
    } catch (e, st) {
      debugPrint('Orpheus Deck: LATENCY_CALIB_FAIL $e\n$st');
      return LatencyCalibResult.fail(_noiseFail);
    } finally {
      try {
        if (await recorder.isRecording()) await recorder.stop();
      } catch (_) {}
      await recorder.dispose();

      try {
        if (calibrationClick != null &&
            calibrationClick.existsSync()) {
          calibrationClick.deleteSync();
        }
      } catch (_) {}

      try {
        final wd = workDir;
        if (wd != null && wd.existsSync()) {
          for (final e in wd.listSync()) {
            try {
              if (e is File) e.deleteSync();
            } catch (_) {}
          }
          wd.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  static Future<void> _configureAudioSession() async {
    final session = await as_sess.AudioSession.instance;
    const cfg = as_sess.AudioSessionConfiguration(
      avAudioSessionCategory: as_sess.AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          as_sess.AVAudioSessionCategoryOptions.defaultToSpeaker,
      avAudioSessionMode: as_sess.AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          as_sess.AVAudioSessionRouteSharingPolicy.defaultPolicy,
      androidAudioAttributes: as_sess.AndroidAudioAttributes(
        contentType: as_sess.AndroidAudioContentType.music,
        flags: as_sess.AndroidAudioFlags.none,
        usage: as_sess.AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: as_sess.AndroidAudioFocusGainType.gain,
    );
    await session.configure(cfg);
    await session.setActive(true);
  }

  /// Returns round-trip latency in ms clamped preview, or null if rejected.
  static int? estimateRoundTripLatencyMs(Int16List samples) {
    if (samples.length < 512) return null;

    final ig = ((warmupDiscardMs / 1000.0) * sampleRate)
        .round()
        .clamp(0, samples.length - 64);

    final nfEnd = min(ig + (sampleRate * 0.04).round(), samples.length);
    double acc = 0;
    var n = 0;
    for (var i = ig; i < nfEnd; i++) {
      acc += samples[i].abs().toDouble();
      n++;
    }
    final floor = n > 0 ? acc / n : 0.0;
    final thresh = max(floor * 10.0, 3200.0);

    var firstIx = -1;
    for (var i = ig; i < samples.length; i++) {
      if (samples[i].abs().toDouble() >= thresh) {
        firstIx = i;
        break;
      }
    }
    if (firstIx < 0) return null;

    final onsetWallMs = (firstIx / sampleRate * 1000).round();
    final delta = onsetWallMs - playbackDelayMs;
    if (delta < 0 || delta > 800) return null;

    return delta.clamp(0, clampMaxSavedMs).toInt();
  }

  /// Locate `data` chunk and return mono int16 PCM.
  static Int16List? parseMono16Wav(Uint8List b) {
    if (b.length < 44) return null;

    var off = 12;
    int? dataStart;
    var dataLen = 0;

    while (off + 8 <= b.length) {
      final tagBytes = b.sublist(off, off + 4);
      final tag =
          '${String.fromCharCode(tagBytes[0])}${String.fromCharCode(tagBytes[1])}${String.fromCharCode(tagBytes[2])}${String.fromCharCode(tagBytes[3])}';
      final sz =
          ByteData.sublistView(b, off + 4, off + 8).getUint32(0, Endian.little);
      final chunkStart = off + 8;
      if (tag == 'data') {
        dataStart = chunkStart;
        dataLen = sz;
        break;
      }
      off = chunkStart + sz + (sz & 1);
    }

    if (dataStart == null || dataStart + dataLen > b.length) return null;

    final n = dataLen ~/ 2;
    if (n < 512) return null;

    final out = Int16List(n);
    final bd = ByteData.sublistView(b);
    var p = dataStart;
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(p, Endian.little);
      p += 2;
    }
    return out;
  }

  /// Mono click — mostly silence , short broadband pulse.
  static Uint8List buildCalibrationClickWav() {
    const leadMs = 200;
    const tailMs = 220;
    const totalMs = leadMs + 90 + tailMs;
    final n = (sampleRate * totalMs / 1000).ceil();

    final buf = Int16List(n);
    const start = sampleRate * leadMs ~/ 1000;
    final hitDur = max(12, sampleRate ~/ 220);

    for (var i = 0; i < hitDur && start + i < n; i++) {
      final t = i / sampleRate;
      final env = exp(-t / 0.00042);
      final grain =
          ((((start + i) * 7919) ^ (i * 1103515245)) & 0xffff) / 32768.0 -
              0.45;
      var s =
          grain * env * 12000 + sin(pi * i / hitDur) * env * 19500 + env * 9000;
      s = s.clamp(-30000.0, 30000.0);
      final summed = buf[start + i] + s.round();
      buf[start + i] =
          summed > 32767 ? 32767 : (summed < -32768 ? -32768 : summed);
    }

    final dataSize = n * 2;
    final out = Uint8List(44 + dataSize);
    final h = ByteData.sublistView(out, 0, 44);

    void putAscii(int offset, String s) {
      for (var k = 0; k < 4 && k < s.length; k++) {
        out[offset + k] = s.codeUnitAt(k);
      }
    }

    putAscii(0, 'RIFF');
    h.setUint32(4, 36 + dataSize, Endian.little);
    putAscii(8, 'WAVE');
    putAscii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, sampleRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    putAscii(36, 'data');
    h.setUint32(40, dataSize, Endian.little);

    out.setRange(
      44,
      44 + dataSize,
      buf.buffer.asUint8List(buf.offsetInBytes, dataSize),
    );
    return out;
  }
}