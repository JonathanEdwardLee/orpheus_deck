/// ORPHEUS DECK
/// Retro cassette interface, pro native audio engine.
/// Read ORPHEUS_DESIGN_MANIFESTO.md and ORPHEUS_NATIVE_AUDIO_PLAN.md
/// before making architectural audio changes.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audio_session/audio_session.dart' as as_sess;

import 'widgets/tape_reel_transport.dart';

import 'orpheus_latency_calibration.dart';
import 'native/orpheus_native_test_screen.dart';
import 'recorder/native_oboe_recorder_engine.dart';
import 'recorder/native_test_wav_generator.dart';
import 'recorder/recorder_engine_selector.dart';

/// One cassette side — fixed transport length (0 … tapeLengthMs).
/// Clip lengths do not shorten the tape; matches ORPHEUS_DESIGN_MANIFESTO.md.
const int tapeLengthMs = 15 * 60 * 1000;

/// Header / dial tape clock [`mm:ss`] from [`tapeTransportMs`] (same as `_playbackMs`).
String _tapeClockMmSs(int ms) {
  final int clampedMs = ms < 0 ? 0 : ms;
  final int totalSec = clampedMs ~/ 1000;
  final m = (totalSec ~/ 60).toString().padLeft(2, '0');
  final s = (totalSec % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _formatExportDateTime(DateTime d) {
  final l = d.toLocal();
  final y = l.year.toString().padLeft(4, '0');
  final mo = l.month.toString().padLeft(2, '0');
  final da = l.day.toString().padLeft(2, '0');
  final h = l.hour.toString().padLeft(2, '0');
  final mi = l.minute.toString().padLeft(2, '0');
  return '$y-$mo-$da $h:$mi';
}

/// Matches [pubspec.yaml] version — shown in Settings ▸ About.
const String kOrpheusAppVersion = '1.0.0+1';

OverlayEntry? _orpheusOledToastEntry;

/// OLED-style status toast — black panel, white border, uppercase monospace.
void showOrpheusOledToast(BuildContext context, String message) {
  _orpheusOledToastEntry?.remove();
  _orpheusOledToastEntry = null;
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final upper = message.toUpperCase();
  final entry = OverlayEntry(
    builder: (ctx) {
      final pad = MediaQuery.paddingOf(ctx);
      return Stack(
        children: [
          Positioned(
            left: 16,
            right: 16,
            top: pad.top + 56,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Text(
                      upper,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        letterSpacing: 0.6,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  _orpheusOledToastEntry = entry;
  overlay.insert(entry);
  Future<void>.delayed(const Duration(milliseconds: 2300), () {
    entry.remove();
    if (identical(_orpheusOledToastEntry, entry)) {
      _orpheusOledToastEntry = null;
    }
  });
}

/// App-level preferences at Documents/OrpheusDeck/settings.json (not per session).
///
/// Latency test: plays a disposable click WAV, records briefly to temp files,
/// and writes [manualLatencyAdjustMs]; see [OrpheusLatencyCalibration].
class OrpheusSettings {
  OrpheusSettings._();
  static final OrpheusSettings instance = OrpheusSettings._();

  static const int manualLatencyAdjustMinMs = -2000;
  static const int manualLatencyAdjustMaxMs = 2000;

  /// Must run Settings ▸ LATENCY TEST before compensation can stay ON across
  /// launches. Stored in settings.json.
  bool latencyCalibrated = false;

  /// Subtracted from decoded file seek when ON; aligns export adelay similarly.
  /// Does **not** change stored [trackTapeStartMs].
  bool latencyCompensationEnabled = false;

  /// When true, show the pre-record informational checklist dialog.
  bool recordingCheckReminderEnabled = true;

  /// Subtracted from decoded file position during PLAY/REC monitoring/export
  /// **when [latencyCompensationEnabled] is true**;
  /// **positive** pulls perceived playback earlier vs the tape timeline.
  int manualLatencyAdjustMs = 0;

  /// Last successful LATENCY TEST (epoch millis); diagnostic / future routing UI.
  int lastLatencyTestMs = 0;

  /// N3E-D: persisted preference only — main recorder still uses legacy audio.
  bool experimentalNativeAudioEngineEnabled = false;

  Future<File> _settingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final deck = Directory('${dir.path}/OrpheusDeck');
    if (!await deck.exists()) {
      await deck.create(recursive: true);
    }
    return File('${deck.path}/settings.json');
  }

  Future<void> load() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) {
        await save();
        return;
      }
      final dynamic raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) {
        latencyCalibrated = raw['latencyCalibrated'] is bool
            ? raw['latencyCalibrated'] as bool
            : false;

        final dynamic manRaw = raw['manualLatencyAdjustMs'];
        if (manRaw is num) {
          manualLatencyAdjustMs = manRaw
              .round()
              .clamp(manualLatencyAdjustMinMs, manualLatencyAdjustMaxMs);
        } else {
          manualLatencyAdjustMs = 0;
        }

        final lt = raw['lastLatencyTestMs'];
        if (lt is num) {
          lastLatencyTestMs = lt.toInt();
        } else {
          lastLatencyTestMs = 0;
        }

        final dynamic latRaw = raw['latencyCompensationEnabled'];

        final dynamic recRemRaw = raw['recordingCheckReminderEnabled'];
        recordingCheckReminderEnabled =
            recRemRaw is bool ? recRemRaw : true;

        if (!latencyCalibrated) {
          latencyCompensationEnabled = false;
        } else {
          latencyCompensationEnabled = latRaw is bool ? latRaw : true;
        }

        final dynamic nativeExpRaw = raw['experimentalNativeAudioEngineEnabled'];
        experimentalNativeAudioEngineEnabled =
            nativeExpRaw is bool ? nativeExpRaw : false;
      } else {
        latencyCalibrated = false;
        latencyCompensationEnabled = false;
        manualLatencyAdjustMs = 0;
        recordingCheckReminderEnabled = true;
        lastLatencyTestMs = 0;
        experimentalNativeAudioEngineEnabled = false;
      }
    } catch (e, st) {
      debugPrint('Orpheus Deck: settings load error $e\n$st');
      latencyCalibrated = false;
      latencyCompensationEnabled = false;
      manualLatencyAdjustMs = 0;
      recordingCheckReminderEnabled = true;
      lastLatencyTestMs = 0;
      experimentalNativeAudioEngineEnabled = false;
    }
  }

  Future<void> save() async {
    final file = await _settingsFile();
    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        'latencyCalibrated': latencyCalibrated,
        'latencyCompensationEnabled': latencyCompensationEnabled,
        'manualLatencyAdjustMs': manualLatencyAdjustMs,
        'recordingCheckReminderEnabled': recordingCheckReminderEnabled,
        'lastLatencyTestMs': lastLatencyTestMs,
        'experimentalNativeAudioEngineEnabled':
            experimentalNativeAudioEngineEnabled,
      }),
      flush: true,
    );
  }

  Future<void> setExperimentalNativeAudioEngineEnabled(bool enabled) async {
    experimentalNativeAudioEngineEnabled = enabled;
    await save();
    debugPrint(
      'Orpheus Deck: settings experimentalNativeAudioEngineEnabled=$enabled',
    );
  }

  Future<void> setLatencyCompensation(bool enabled) async {
    if (enabled && !latencyCalibrated) {
      debugPrint(
        'Orpheus Deck: latency compensation ON ignored until calibrated',
      );
      return;
    }
    latencyCompensationEnabled = enabled;
    await save();
    debugPrint(
      'Orpheus Deck: settings latencyCompensationEnabled=$enabled',
    );
  }

  Future<void> applySuccessfulLatencyCalibration(int medianRoundTripMs) async {
    manualLatencyAdjustMs = medianRoundTripMs.clamp(
      manualLatencyAdjustMinMs,
      manualLatencyAdjustMaxMs,
    );
    latencyCalibrated = true;
    latencyCompensationEnabled = true;
    lastLatencyTestMs = DateTime.now().millisecondsSinceEpoch;
    await save();
    debugPrint(
      'Orpheus Deck: latency calibrated medianMs=$manualLatencyAdjustMs',
    );
  }

  Future<void> setManualLatencyAdjustMs(int deltaMs) async {
    manualLatencyAdjustMs = deltaMs.clamp(
      manualLatencyAdjustMinMs,
      manualLatencyAdjustMaxMs,
    );
    await save();
    debugPrint(
      'Orpheus Deck: settings manualLatencyAdjustMs=$manualLatencyAdjustMs',
    );
  }

  Future<void> bumpManualLatencyAdjustMs(int delta) async =>
      setManualLatencyAdjustMs(manualLatencyAdjustMs + delta);

  Future<void> setRecordingCheckReminderEnabled(bool enabled) async {
    recordingCheckReminderEnabled = enabled;
    await save();
    debugPrint(
      'Orpheus Deck: settings recordingCheckReminderEnabled=$enabled',
    );
  }
}

/// Shared settings UI (home menu + recording reminder “OPEN SETTINGS”).
void showOrpheusDeckSettingsDialog(
  BuildContext outerContext, {
  bool Function()? isTransportBusy,
}) {
  showDialog(
    context: outerContext,
    builder: (dialogContext) {
      var latencyCalibBusy = false;

      return StatefulBuilder(
        builder: (context, setDialogState) {
          final bool calibrated =
              OrpheusSettings.instance.latencyCalibrated;
          final latencyOn =
              OrpheusSettings.instance.latencyCompensationEnabled;
          final int manualAdj = OrpheusSettings.instance.manualLatencyAdjustMs;
          final bool recReminderOn =
              OrpheusSettings.instance.recordingCheckReminderEnabled;
          final bool nativeExperimentalOn = OrpheusSettings
              .instance.experimentalNativeAudioEngineEnabled;

          bool transportBusy() => isTransportBusy?.call() ?? false;

          Widget stepBtn(String t, Future<void> Function() act) {
            return TextButton(
              onPressed: () async {
                await act();
                setDialogState(() {});
              },
              style: TextButton.styleFrom(
                minimumSize: const Size(40, 32),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                foregroundColor: Colors.white,
              ),
              child: Text(t,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            );
          }

          void openLatencyInstructions() {
            if (transportBusy()) {
              showOrpheusOledToast(outerContext, 'STOP PLAY/REC FIRST');
              return;
            }
            showDialog<void>(
              context: dialogContext,
              builder: (prepCtx) {
                return AlertDialog(
                  backgroundColor: Colors.black,
                  shape: Border.all(color: Colors.white, width: 2),
                  title: const Text(
                    'LATENCY TEST',
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  content: const SingleChildScrollView(
                    child: Text(
                      'FOR BEST RESULTS:\n'
                      'USE WIRED HEADPHONES OR PHONE SPEAKER.\n'
                      'BLUETOOTH MAY BE LATE OR UNSTABLE.\n'
                      'KEEP THE PHONE QUIET.\n'
                      'THE APP WILL PLAY CLICKS AND LISTEN FOR THEM.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(prepCtx),
                      child: const Text(
                        'CANCEL',
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(prepCtx);
                        if (transportBusy()) {
                          showOrpheusOledToast(
                              outerContext, 'STOP PLAY/REC FIRST');
                          return;
                        }
                        () async {
                          setDialogState(() => latencyCalibBusy = true);
                          final r =
                              await OrpheusLatencyCalibration.runCalibration();
                          if (r.ok) {
                            await OrpheusSettings.instance
                                .applySuccessfulLatencyCalibration(
                                    r.medianMs);
                          }
                          setDialogState(() => latencyCalibBusy = false);
                          if (outerContext.mounted) {
                            showOrpheusOledToast(outerContext, r.userMessage);
                          }
                          setDialogState(() {});
                        }();
                      },
                      child: const Text(
                        'START TEST',
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          }

          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text(
              'SETTINGS',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'RECORDING',
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'RECORDING CHECK REMINDER',
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Switch(
                        value: recReminderOn,
                        activeThumbColor: Colors.black,
                        activeTrackColor: Colors.white,
                        inactiveThumbColor: Colors.white54,
                        inactiveTrackColor: Colors.white24,
                        onChanged: (v) async {
                          await OrpheusSettings.instance
                              .setRecordingCheckReminderEnabled(v);
                          setDialogState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recReminderOn
                        ? 'ON: show checklist before REC.'
                        : 'OFF: skip pre-record checklist.',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'LATENCY TEST',
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed:
                          latencyCalibBusy ? null : openLatencyInstructions,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      child: Text(
                        latencyCalibBusy
                            ? 'RUNNING…'
                            : 'RUN LATENCY TEST',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'RUN AGAIN IF YOU CHANGE HEADPHONES.',
                    style: TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'LATENCY COMPENSATION',
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Switch(
                        value: calibrated && latencyOn,
                        activeThumbColor: Colors.black,
                        activeTrackColor: Colors.white,
                        inactiveThumbColor: Colors.white54,
                        inactiveTrackColor: Colors.white24,
                        onChanged: calibrated
                            ? (v) async {
                                await OrpheusSettings.instance
                                    .setLatencyCompensation(v);
                                setDialogState(() {});
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    !calibrated
                        ? 'RUN TEST FIRST.'
                        : (latencyOn
                            ? 'ON: keeps overdubs tighter.'
                            : 'OFF: natural delay effect.'),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'LATENCY ADJUST',
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'LATENCY: $manualAdj MS',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    latencyOn
                        ? 'Fine-tune if overdubs sound late or early. '
                            'PLAY / monitor / EXPORT. Tape positions unchanged.'
                        : 'When compensation is OFF, recording keeps natural delay '
                            '(value kept for next time compensation is ON).',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      stepBtn(
                          '-100',
                          () => OrpheusSettings.instance
                              .bumpManualLatencyAdjustMs(-100)),
                      stepBtn(
                          '+100',
                          () => OrpheusSettings.instance
                              .bumpManualLatencyAdjustMs(100)),
                      stepBtn(
                          '-10',
                          () => OrpheusSettings.instance
                              .bumpManualLatencyAdjustMs(-10)),
                      stepBtn(
                          '+10',
                          () => OrpheusSettings.instance
                              .bumpManualLatencyAdjustMs(10)),
                    ],
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'EXPERIMENTAL (DEBUG)',
                      style: TextStyle(
                        color: Colors.white54,
                        fontFamily: 'monospace',
                        fontSize: 10,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'USE NATIVE AUDIO ENGINE (EXPERIMENTAL)',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Switch(
                          value: nativeExperimentalOn,
                          activeThumbColor: Colors.black,
                          activeTrackColor: Colors.white,
                          inactiveThumbColor: Colors.white54,
                          inactiveTrackColor: Colors.white24,
                          onChanged: (v) async {
                            if (transportBusy()) {
                              showOrpheusOledToast(
                                outerContext,
                                'STOP PLAY/REC FIRST',
                              );
                              return;
                            }
                            await OrpheusSettings.instance
                                .setExperimentalNativeAudioEngineEnabled(v);
                            if (!outerContext.mounted) {
                              return;
                            }
                            setDialogState(() {});
                            showOrpheusOledToast(
                              outerContext,
                              v
                                  ? 'EXPERIMENTAL. NOT USED BY MAIN RECORDER YET.'
                                  : 'LEGACY ENGINE ACTIVE',
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      nativeExperimentalOn
                          ? 'EXPERIMENTAL. NOT USED BY MAIN RECORDER YET.'
                          : 'LEGACY ENGINE ACTIVE',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                        fontSize: 9,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'LONG-PRESS ABOUT BELOW FOR NATIVE AUDIO TEST.',
                      style: TextStyle(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                        fontSize: 9,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'ABOUT',
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onLongPress: kDebugMode && Platform.isAndroid
                        ? () {
                            Navigator.pop(dialogContext);
                            openOrpheusNativeTestScreen(outerContext);
                          }
                        : null,
                    child: const Text(
                      'Orpheus Deck\n'
                      'Four-Track Audio Recorder\n'
                      'MK-I Beta\n'
                      'Version $kOrpheusAppVersion',
                      style: TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'PRO MODE (COMING LATER)',
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'PRO MODE FEATURES COMING LATER',
                    style: TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: latencyCalibBusy
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text(
                  'CLOSE',
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Parameters for [buildClickTrackWavBytes] (must stay simple for [compute]).
class ClickWavParams {
  final int bpm;
  final String sound;
  const ClickWavParams(this.bpm, this.sound);
}

int _clipAddI16(int a, int b) {
  final x = a + b;
  if (x > 32767) return 32767;
  if (x < -32768) return -32768;
  return x;
}

void _mixMechanicalClick(Int16List buf, int start, int bufLen, int peak) {
  const sr = 44100;
  final n = (sr * 0.012).round();
  for (int i = 0; i < n; i++) {
    final idx = start + i;
    if (idx >= bufLen) break;
    final t = i / sr;
    final env = exp(-t / 0.00042);
    final grain =
        ((((idx * 7919) ^ (i * 1103515245)) & 0xffff) / 32768.0) - 0.5;
    final s = (grain * env * peak).round();
    buf[idx] = _clipAddI16(buf[idx], s);
  }
}

void _mixBeepHit(Int16List buf, int start, int bufLen, int peak) {
  const sr = 44100;
  const freq = 740.0;
  final n = (sr * 0.036).round();
  for (int i = 0; i < n; i++) {
    final idx = start + i;
    if (idx >= bufLen) break;
    final t = i / sr;
    final env = pow(1.0 - (t / 0.036).clamp(0.0, 1.0), 2.2).toDouble();
    final s = (sin(2 * pi * freq * t) * env * peak).round();
    buf[idx] = _clipAddI16(buf[idx], s);
  }
}

void _mixWoodHit(Int16List buf, int start, int bufLen, int peak) {
  const sr = 44100;
  final n = (sr * 0.040).round();
  for (int i = 0; i < n; i++) {
    final idx = start + i;
    if (idx >= bufLen) break;
    final t = i / sr;
    final env = exp(-t / 0.0085);
    final s1 = sin(2 * pi * 312 * t);
    final s2 = 0.42 * sin(2 * pi * 905 * t);
    final s = ((s1 + s2) * env * peak * 0.52).round();
    buf[idx] = _clipAddI16(buf[idx], s);
  }
}

void _mixClickHitAt(Int16List buf, int start, String sound, int bufLen) {
  const peak = 13500;
  switch (sound) {
    case 'BEEP':
      _mixBeepHit(buf, start, bufLen, peak);
      break;
    case 'WOOD':
      _mixWoodHit(buf, start, bufLen, peak);
      break;
    default:
      _mixMechanicalClick(buf, start, bufLen, peak);
  }
}

Uint8List _pcmMono16LeToWavBytes(Int16List samples, int sampleRate) {
  final dataSize = samples.length * 2;
  final out = Uint8List(44 + dataSize);
  final h = ByteData.sublistView(out, 0, 44);
  h.setUint8(0, 0x52);
  h.setUint8(1, 0x49);
  h.setUint8(2, 0x46);
  h.setUint8(3, 0x46);
  h.setUint32(4, 36 + dataSize, Endian.little);
  h.setUint8(8, 0x57);
  h.setUint8(9, 0x41);
  h.setUint8(10, 0x56);
  h.setUint8(11, 0x45);
  h.setUint8(12, 0x66);
  h.setUint8(13, 0x6D);
  h.setUint8(14, 0x74);
  h.setUint8(15, 0x20);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  h.setUint8(36, 0x64);
  h.setUint8(37, 0x61);
  h.setUint8(38, 0x74);
  h.setUint8(39, 0x61);
  h.setUint32(40, dataSize, Endian.little);
  out.setRange(
    44,
    44 + dataSize,
    samples.buffer.asUint8List(samples.offsetInBytes, dataSize),
  );
  return out;
}

/// Heavy work — run via [compute] to avoid janking the UI isolate.
Uint8List buildClickTrackWavBytes(ClickWavParams p) {
  const int sampleRate = 44100;
  const int durationSec = 15 * 60;
  const int totalSamples = sampleRate * durationSec;
  final samples = Int16List(totalSamples);
  final double samplesPerBeat = sampleRate * 60.0 / p.bpm;
  for (int beat = 0;; beat++) {
    final start = (beat * samplesPerBeat).round();
    if (start >= totalSamples) break;
    _mixClickHitAt(samples, start, p.sound, totalSamples);
  }
  return _pcmMono16LeToWavBytes(samples, sampleRate);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  await OrpheusSettings.instance.load();
  runApp(const OrpheusDeckApp());
}

enum UndoAction { none, clearTrack, mixer, rename }

class UndoState {
  UndoAction action = UndoAction.none;

  int? trackIndex;
  String? trackFile;
  List<double>? trackWaveform;
  int? trackTapeStartMs;

  List<double>? volumes;
  List<bool>? mutes;
  List<bool>? solos;

  String? oldName;
  String? newName;

  void clear() {
    action = UndoAction.none;
    trackIndex = null;
    trackFile = null;
    trackWaveform = null;
    trackTapeStartMs = null;
    volumes = null;
    mutes = null;
    solos = null;
    oldName = null;
    newName = null;
  }

  bool get hasUndo => action != UndoAction.none;
}

/// Final mix export metadata (session.json). Raw track M4As stay internal-only.
class ExportEntry {
  final String filename;
  /// User-facing location, e.g. Music/Orpheus Deck/foo.wav
  final String displayPath;
  final String? storageUri;
  final String? absolutePath;
  final String kind;
  final DateTime createdAt;

  ExportEntry({
    required this.filename,
    required this.displayPath,
    this.storageUri,
    this.absolutePath,
    required this.kind,
    required this.createdAt,
  });

  String get shareRef => storageUri ?? absolutePath ?? '';

  ExportEntry copyWith({
    String? filename,
    String? displayPath,
    String? storageUri,
    String? absolutePath,
    String? kind,
    DateTime? createdAt,
  }) {
    return ExportEntry(
      filename: filename ?? this.filename,
      displayPath: displayPath ?? this.displayPath,
      storageUri: storageUri ?? this.storageUri,
      absolutePath: absolutePath ?? this.absolutePath,
      kind: kind ?? this.kind,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'displayPath': displayPath,
        if (storageUri != null) 'storageUri': storageUri,
        if (absolutePath != null) 'absolutePath': absolutePath,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ExportEntry.fromJson(Map<String, dynamic> json) {
    final abs = json['absolutePath'] as String?;
    final fname = json['filename'] as String? ??
        (abs != null ? abs.split(RegExp(r'[/\\]')).last : '');
    return ExportEntry(
      filename: fname,
      displayPath: json['displayPath'] as String? ?? fname,
      storageUri: json['storageUri'] as String?,
      absolutePath: abs,
      kind: json['kind'] as String? ?? 'RAW MIX',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  /// Older sessions stored exports as plain filesystem paths.
  factory ExportEntry.fromLegacyPath(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final lower = name.toLowerCase();
    final kind = lower.contains('mastermix') || lower.contains('youtube_master')
        ? 'MASTERMIX'
        : 'RAW MIX';
    return ExportEntry(
      filename: name,
      displayPath: path,
      storageUri: null,
      absolutePath: path,
      kind: kind,
      createdAt: DateTime.now(),
    );
  }
}

List<ExportEntry> parseExportsFromJson(dynamic raw) {
  if (raw == null) return [];
  if (raw is! List) return [];
  final out = <ExportEntry>[];
  for (final item in raw) {
    if (item is String) {
      out.add(ExportEntry.fromLegacyPath(item));
    } else if (item is Map) {
      out.add(ExportEntry.fromJson(Map<String, dynamic>.from(item)));
    }
  }
  return out;
}

class _ExportBrowseSnapshot {
  const _ExportBrowseSnapshot({
    required this.entries,
    required this.footerHintText,
  });

  final List<ExportEntry> entries;
  /// Shown below the scroll list (empty library / Music scan caveat).
  final String? footerHintText;
}

class Session {
  String projectName;
  DateTime createdAt;
  DateTime updatedAt;
  List<String?> trackFiles;
  Map<String, List<double>> waveformCache;
  List<String?> trackIds;
  List<int> trackOffsets;
  List<int> trackTapeStartMs;
  List<double> trackVolumes;
  List<bool> trackMutes;
  List<bool> trackSolos;
  List<ExportEntry> exports;
  int bpm;
  bool metronomeOn;
  String metronomeSound;
  /// `legacy` (default) or `native_test` (dev sandbox only).
  String audioEngine;

  Session({
    required this.projectName,
    required this.createdAt,
    required this.updatedAt,
    required this.trackFiles,
    required this.waveformCache,
    required this.trackIds,
    required this.trackOffsets,
    required this.trackTapeStartMs,
    required this.trackVolumes,
    required this.trackMutes,
    required this.trackSolos,
    required this.exports,
    required this.bpm,
    required this.metronomeOn,
    required this.metronomeSound,
    this.audioEngine = kOrpheusAudioEngineLegacy,
  });

  Map<String, dynamic> toJson() {
    return {
      'projectName': projectName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'trackFiles': trackFiles,
      'waveformCache': waveformCache,
      'trackIds': trackIds,
      'trackOffsets': trackOffsets,
      'trackTapeStartMs': trackTapeStartMs,
      'trackVolumes': trackVolumes,
      'trackMutes': trackMutes,
      'trackSolos': trackSolos,
      'exports': exports.map((e) => e.toJson()).toList(),
      'bpm': bpm,
      'metronomeOn': metronomeOn,
      'metronomeSound': metronomeSound,
      'audioEngine': audioEngine,
    };
  }

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      projectName: json['projectName'] as String? ?? 'SESSION_001',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : DateTime.now(),
      trackFiles: List<String?>.from(json['trackFiles'] as List),
      waveformCache: (json['waveformCache'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, List<double>.from(e as List)),
      ),
      trackIds: List<String?>.from(
          json['trackIds'] as List? ?? [null, null, null, null]),
      trackOffsets:
          List<int>.from(json['trackOffsets'] as List? ?? [0, 0, 0, 0]),
      trackTapeStartMs: List<int>.from(
          json['trackTapeStartMs'] as List? ?? [0, 0, 0, 0]),
      trackVolumes: List<double>.from(
          json['trackVolumes'] as List? ?? [1.0, 1.0, 1.0, 1.0]),
      trackMutes: List<bool>.from(
          json['trackMutes'] as List? ?? [false, false, false, false]),
      trackSolos: List<bool>.from(
          json['trackSolos'] as List? ?? [false, false, false, false]),
      exports: parseExportsFromJson(json['exports']),
      bpm: json['bpm'] as int? ?? 120,
      metronomeOn: json['metronomeOn'] as bool? ?? false,
      metronomeSound: json['metronomeSound'] as String? ?? 'CLICK',
      audioEngine: parseProjectAudioEngineFromSessionJson(json),
    );
  }
}

class OrpheusDeckApp extends StatelessWidget {
  const OrpheusDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Orpheus Deck',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white,
          surface: Colors.black,
        ),
      ),
      initialRoute: '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/home': (context) => const CassetteHomeScreen(),
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return JunkfeathersGlitchSplash(
      onComplete: () {
        Navigator.pushReplacementNamed(context, '/home');
      },
    );
  }
}

class JunkfeathersGlitchSplash extends StatefulWidget {
  final VoidCallback onComplete;
  const JunkfeathersGlitchSplash({super.key, required this.onComplete});

  @override
  State<JunkfeathersGlitchSplash> createState() =>
      _JunkfeathersGlitchSplashState();
}

/// ~4.2s total: fade-in → light glitch → strong glitch → full-screen signal loss.
const int _kJunkfeathersSplashTotalMs = 4200;

const double _kSpEndFade = 0.11;
const double _kSpEndLight = 0.38;
const double _kSpEndHeavy = 0.66;

/// Phases: 0 fade-in, 1 light interference, 2 strong interference, 3 glitch-out.
void _splashPhasesFour(
  double t,
  void Function(int phase, double phaseProgress) out,
) {
  if (t < _kSpEndFade) {
    out(0, t / _kSpEndFade);
  } else if (t < _kSpEndLight) {
    out(1, (t - _kSpEndFade) / (_kSpEndLight - _kSpEndFade));
  } else if (t < _kSpEndHeavy) {
    out(2, (t - _kSpEndLight) / (_kSpEndHeavy - _kSpEndLight));
  } else {
    out(3, (t - _kSpEndHeavy) / (1.0 - _kSpEndHeavy));
  }
}

class _JunkfeathersGlitchSplashState extends State<JunkfeathersGlitchSplash>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _kJunkfeathersSplashTotalMs),
    );
    _ctrl.forward().then((_) {
      if (mounted) widget.onComplete();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final t = _ctrl.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: JunkfeathersSplashBackdropPainter(t),
                child: const SizedBox.expand(),
              ),
              Center(
                child: SizedBox(
                  width: 236,
                  height: 118,
                  child: CustomPaint(
                    painter: JunkfeathersLogoMarkPainter(t),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Full-bleed boot interference: bands, tear, scanlines — no random specks.
class JunkfeathersSplashBackdropPainter extends CustomPainter {
  JunkfeathersSplashBackdropPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    int phase = 0;
    double phaseProgress = 0;
    _splashPhasesFour(progress, (p, pp) {
      phase = p;
      phaseProgress = pp;
    });

    final int globalStep = (progress * 240).floor();
    final Random globalR = Random(globalStep);

    final double w = size.width;
    final double h = size.height;

    // Master visibility (fade-in/out ends of sequence).
    double master = 1.0;
    if (phase == 0) {
      master = 0.04 + 0.96 * phaseProgress;
    } else if (phase == 3) {
      master = 1.0 - 0.97 * phaseProgress;
    }

    // Phase-dependent corruption strength (no "star" noise).
    int coverBase;
    double tearAmp;
    int scanMul; // 1 = every 3px, 2 = denser in heavy phases
    if (phase == 0) {
      coverBase = (6 + (14 * phaseProgress)).toInt();
      tearAmp = 0;
      scanMul = 1;
    } else if (phase == 1) {
      coverBase = 18 + (globalR.nextInt(15));
      tearAmp = 3.0 + phaseProgress * 4.0;
      scanMul = 1;
    } else if (phase == 2) {
      coverBase = 48 + (globalR.nextInt(22));
      tearAmp = 10.0 + phaseProgress * 12.0;
      scanMul = 2;
    } else {
      coverBase = 72 + (globalR.nextInt(25));
      tearAmp = 22.0 + phaseProgress * 26.0;
      scanMul = 2;
    }

    final Paint bandPaint = Paint()
      ..color = Colors.black.withValues(alpha: master);
    final Paint fastLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.82 * master);
    final Paint tearWhite = Paint()
      ..color = Colors.white.withValues(alpha: 0.35 * master);

    int y = 0;
    while (y < h) {
      int bandH = globalR.nextInt(14) + 4;
      if (y + bandH > h) bandH = max(0, (h - y).floor());
      if (bandH <= 0) break;

      final rowRand = Random(globalStep ^ (y * 9973));
      final tearDx =
          (rowRand.nextDouble() - 0.5) * 2.0 * tearAmp * master;

      int coverChance = (coverBase + rowRand.nextInt(12)).clamp(0, 98);
      if (globalR.nextInt(100) < coverChance) {
        canvas.drawRect(
          Rect.fromLTWH(tearDx, y.toDouble(), w, bandH.toDouble()),
          bandPaint,
        );
      } else {
        if (globalR.nextInt(100) < (phase >= 2 ? 22 : 12)) {
          canvas.drawRect(
              Rect.fromLTWH(tearDx, y.toDouble(), w, 1.2), fastLine);
        }
        if (phase >= 2 && globalR.nextInt(100) < 18) {
          canvas.drawRect(
            Rect.fromLTWH(tearDx + w * 0.35, y.toDouble(), w * 0.12, 1),
            tearWhite,
          );
        }
      }
      y += bandH;
    }

    final Paint scan = Paint()
      ..color = Colors.black.withValues(alpha: 0.14 * master);
    for (double sy = 0; sy < h; sy += (3 / scanMul)) {
      canvas.drawRect(Rect.fromLTWH(0, sy, w, 1), scan);
    }
  }

  @override
  bool shouldRepaint(covariant JunkfeathersSplashBackdropPainter old) =>
      old.progress != progress;
}

/// Logo wordmark + outline dead birds (full-screen glitch lives in backdrop only).
class JunkfeathersLogoMarkPainter extends CustomPainter {
  JunkfeathersLogoMarkPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 128, size.height / 64);

    int phase = 0;
    double phaseProgress = 0;
    _splashPhasesFour(progress, (p, pp) {
      phase = p;
      phaseProgress = pp;
    });

    const int totalSteps = 240;
    final int globalStep = (progress * totalSteps).floor();
    final Random globalR = Random(globalStep);

    double jMag = 0;
    if (phase == 1) jMag = 1.0;
    if (phase == 2) jMag = 2.0;
    if (phase == 3) jMag = 3.2 + phaseProgress * 3.5;

    double jitterX = (globalR.nextDouble() - 0.5) * 2.0 * jMag;
    double jitterY = (globalR.nextDouble() - 0.5) * 2.0 * jMag;
    if (phase == 0) {
      jitterX *= 0.35;
      jitterY *= 0.35;
    }

    canvas.translate(jitterX, jitterY);

    double master = 1.0;
    if (phase == 0) {
      master = 0.06 + 0.94 * phaseProgress;
    }
    if (phase == 3) {
      master = 1.0 - 0.98 * phaseProgress;
    }
    if (phase == 1 || phase == 2) {
      if (globalR.nextInt(100) < 8) {
        master *= 0.5 + globalR.nextDouble() * 0.5;
      }
    }

    const double wordPx = 12.0;
    _drawWordmarkGlitch(canvas, 'JUNKFEATHERS', 7, master, wordPx, globalStep ^ 31);
    _drawWordmarkGlitch(canvas, 'TECH', 22, master, wordPx, globalStep ^ 997);

    _drawBirdOutlined(canvas, 32, 45, 10.8, master);
    _drawBirdOutlined(canvas, 96, 45, 10.8, master);

    // Final phase: slice the mark itself (backdrop already carries interference).
    if (phase == 3) {
      final Random corruptR = Random(globalStep ^ 0x5fce);
      final int cov =
          (36 + phaseProgress * 58).round().clamp(32, 98).toInt();
      for (int yy = 0; yy < 64; yy += 3) {
        if (corruptR.nextInt(100) >= cov) continue;
        final bh = corruptR.nextInt(5) + 1;
        canvas.drawRect(
          Rect.fromLTWH(0, yy.toDouble(), 128, bh.toDouble()),
          Paint()..color = Colors.black.withValues(alpha: master),
        );
      }
    }

    canvas.translate(-jitterX, -jitterY);
  }

  void _drawWordmarkGlitch(
    Canvas canvas,
    String text,
    double y,
    double m,
    double fontPx,
    int lineSalt,
  ) {
    final double shimmer =
        sin(progress * pi * 2.6 + y * 0.08).clamp(-1.0, 1.0) * 0.045;
    final double textAlpha = (m * (0.72 + shimmer)).clamp(0.12, 1.0);

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: textAlpha),
          fontFamily: 'monospace',
          fontSize: fontPx,
          fontWeight: FontWeight.bold,
          height: 1.05,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: 124);
    final double x = (128 - textPainter.width) * 0.5;
    textPainter.paint(canvas, Offset(x, y));

    final double w = textPainter.width;
    final double h = textPainter.height;
    final Random sliceR = Random(
      lineSalt ^
          ((progress * 100000).floor()) ^
          text.hashCode ^
          0x9e3779b9,
    );

    double gy = y;
    final double bottom = y + h;
    while (gy < bottom) {
      if (sliceR.nextInt(100) < 48) {
        final double gap = 0.85 + sliceR.nextDouble() * 0.55;
        canvas.drawRect(
          Rect.fromLTRB(x - 1, gy, x + w + 1, gy + gap),
          Paint()
            ..color = Colors.black
                .withValues(alpha: m * (0.38 + sliceR.nextDouble() * 0.28)),
        );
      }
      if (sliceR.nextInt(100) < 12) {
        canvas.drawRect(
          Rect.fromLTRB(x + sliceR.nextDouble() * w * 0.08, gy, x + w, gy + 0.85),
          Paint()
            ..color = Colors.black
                .withValues(alpha: m * (0.18 + sliceR.nextDouble() * 0.12)),
        );
      }
      if (sliceR.nextInt(100) < 8) {
        canvas.drawRect(
          Rect.fromLTWH(x - 1, gy, w + 2, 0.65),
          Paint()
            ..color =
                Colors.white.withValues(alpha: m * (0.1 + sliceR.nextDouble() * 0.08)),
        );
      }
      gy += 2.0 + sliceR.nextDouble() * 2.4;
    }
  }

  void _drawBirdOutlined(
      Canvas canvas, double cx, double cy, double r, double m) {
    final Paint interior = Paint()
      ..color = Colors.black.withValues(alpha: m)
      ..style = PaintingStyle.fill;

    final Paint ring = Paint()
      ..color = Colors.white.withValues(alpha: m * 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;

    final Paint eyeStroke = Paint()
      ..color = Colors.white.withValues(alpha: m * 0.88)
      ..strokeWidth = 1.45
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(Offset(cx, cy), r, interior);
    canvas.drawCircle(Offset(cx, cy), r, ring);

    final double exL = cx - (r / 2);
    final double exR = cx + (r / 2);
    final double eyeY = cy - (r / 4);
    const double s = 2.0;

    canvas.drawLine(
        Offset(exL - s, eyeY - s), Offset(exL + s, eyeY + s), eyeStroke);
    canvas.drawLine(
        Offset(exL - s, eyeY + s), Offset(exL + s, eyeY - s), eyeStroke);
    canvas.drawLine(
        Offset(exR - s, eyeY - s), Offset(exR + s, eyeY + s), eyeStroke);
    canvas.drawLine(
        Offset(exR - s, eyeY + s), Offset(exR + s, eyeY - s), eyeStroke);

    final double bx = cx;
    final double by = cy + (r / 3);

    final Path beak = Path()
      ..moveTo(bx, by + 2.8)
      ..lineTo(bx - 3.8, by - 1.8)
      ..lineTo(bx + 3.8, by - 1.8)
      ..close();

    final Paint beakFill = Paint()
      ..color = Colors.white.withValues(alpha: m * 0.82)
      ..style = PaintingStyle.fill;
    canvas.drawPath(beak, beakFill);
    canvas.drawPath(
      beak,
      Paint()
        ..color = Colors.white.withValues(alpha: m * 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.85,
    );
  }

  @override
  bool shouldRepaint(covariant JunkfeathersLogoMarkPainter old) =>
      old.progress != progress;
}

class CassetteHomeScreen extends StatefulWidget {
  const CassetteHomeScreen({super.key});

  @override
  State<CassetteHomeScreen> createState() => _CassetteHomeScreenState();
}

class _CassetteHomeScreenState extends State<CassetteHomeScreen>
    with SingleTickerProviderStateMixin {
  String? _lastProjectName;
  final List<String> _allProjects = [];
  final Map<String, bool> _nativeTestProjectFlags = {};
  late AnimationController _idleCtrl;

  @override
  void initState() {
    super.initState();
    _idleCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 10))
          ..repeat();
    _scanProjects();
  }

  @override
  void dispose() {
    _idleCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanProjects() async {
    try {
      final dir = await getApplicationDocumentsDirectory();

      final lastFile = File('${dir.path}/OrpheusDeck/last_project.txt');
      if (await lastFile.exists()) {
        _lastProjectName = await lastFile.readAsString();
      }

      final projDir = Directory('${dir.path}/OrpheusDeck');
      _nativeTestProjectFlags.clear();
      if (await projDir.exists()) {
        final entities = projDir.listSync();
        _allProjects.clear();
        for (var e in entities) {
          if (e is Directory) {
            String name = e.path.split(RegExp(r'[/\\]')).last;
            _allProjects.add(name);
            _nativeTestProjectFlags[name] =
                await _isNativeTestProjectFolder(dir.path, name);
          }
        }
        _allProjects.sort();
      }

      if (mounted) setState(() {});
    } catch (e, s) {
      debugPrint('Error scanning projects: $e\n$s');
    }
  }

  String _sanitizeName(String input) {
    String clean = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (clean.isEmpty) return "SESSION_001";
    return clean;
  }

  Future<bool> _isNativeTestProjectFolder(
    String deckRootPath,
    String projectName,
  ) async {
    if (projectName.startsWith(kOrpheusNativeTestProjectNamePrefix)) {
      return true;
    }
    try {
      final file = File('$deckRootPath/$projectName/session.json');
      if (!await file.exists()) {
        return false;
      }
      final dynamic raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) {
        return isNativeTestAudioEngine(
          parseProjectAudioEngineFromSessionJson(raw),
        );
      }
    } catch (e, s) {
      debugPrint('Orpheus Deck: native test flag read error $e\n$s');
    }
    return false;
  }

  String _nextNativeTestProjectName() {
    var index = 1;
    while (true) {
      final name =
          '$kOrpheusNativeTestProjectNamePrefix${index.toString().padLeft(3, '0')}';
      if (!_allProjects.contains(name)) {
        return name;
      }
      index++;
    }
  }

  void _createNativeTestProject() {
    final name = _nextNativeTestProjectName();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => RecorderScreen(
          projectName: name,
          isNewProject: true,
          createAsNativeTestProject: true,
        ),
      ),
    );
  }

  void _startNewProject() {
    TextEditingController ctrl = TextEditingController(text: "SESSION_NEW");
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text("NEW PROJECT NAME",
                style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            content: TextField(
              controller: ctrl,
              style:
                  const TextStyle(color: Colors.white, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CANCEL",
                    style: TextStyle(
                        color: Colors.white54, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  String safeName = _sanitizeName(ctrl.text);
                  Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (_) => RecorderScreen(
                              projectName: safeName, isNewProject: true)));
                },
                child: const Text("START",
                    style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
  }

  void _loadProject() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text("LOAD PROJECT",
                style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView.builder(
                    itemCount: _allProjects.length,
                    itemBuilder: (context, idx) {
                      String name = _allProjects[idx];
                      final bool isNativeTest =
                          _nativeTestProjectFlags[name] == true;
                      return ListTile(
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (isNativeTest)
                              const Text(
                                'NATIVE TEST PROJECT',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontFamily: 'monospace',
                                  fontSize: 9,
                                  letterSpacing: 0.5,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => RecorderScreen(
                                      projectName: name, isNewProject: false)));
                        },
                      );
                    })),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CANCEL",
                    style: TextStyle(
                        color: Colors.white54, fontFamily: 'monospace')),
              ),
            ],
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    bool hasProjects = _allProjects.isNotEmpty;

    return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
            child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedBuilder(
                        animation: _idleCtrl,
                        builder: (context, child) {
                          return SizedBox(
                              height: 180,
                              child:
                                  Stack(alignment: Alignment.center, children: [
                                CustomPaint(
                                  size: const Size(double.infinity, 180),
                                  painter: CassettePainter(_idleCtrl.value),
                                ),
                                Positioned(
                                    top: 24,
                                    left: 0,
                                    right: 0,
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            color: Colors.black,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            child: const Text("ORPHEUS DECK",
                                                style: TextStyle(
                                                    color: Colors.white,
                                                    fontFamily: 'monospace',
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 18,
                                                    letterSpacing: 2),
                                                textAlign: TextAlign.center),
                                          ),
                                          const SizedBox(height: 8),
                                          Container(
                                            color: Colors.black,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            child: const Text(
                                                "Four-Track Audio Recorder",
                                                style: TextStyle(
                                                    color: Colors.white54,
                                                    fontFamily: 'monospace',
                                                    fontSize: 10),
                                                textAlign: TextAlign.center),
                                          ),

                                        ]))
                              ]));
                        }),
                    const SizedBox(height: 48),
                    if (_lastProjectName != null &&
                        _allProjects.contains(_lastProjectName)) ...[
                      Text("LAST PROJECT: $_lastProjectName",
                          style: const TextStyle(
                              color: Colors.white54,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      _MenuBtn("RESUME LAST PROJECT", () {
                        Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                                builder: (_) => RecorderScreen(
                                    projectName: _lastProjectName!,
                                    isNewProject: false)));
                      }),
                      const SizedBox(height: 16),
                    ],
                    _MenuBtn("START NEW PROJECT", _startNewProject),
                    if (kDebugMode) ...[
                      const SizedBox(height: 16),
                      _MenuBtn(
                        "CREATE NATIVE TEST PROJECT",
                        _createNativeTestProject,
                      ),
                    ],
                    if (hasProjects) ...[
                      const SizedBox(height: 16),
                      _MenuBtn("LOAD PROJECT", _loadProject),
                    ],
                    const SizedBox(height: 16),
                    _MenuBtn("SETTINGS", () {
                      showOrpheusDeckSettingsDialog(context);
                    }),
                  ],
                ))));
  }
}

class CassettePainter extends CustomPainter {
  final double spinProgress;

  CassettePainter(this.spinProgress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final RRect outerRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
        const Radius.circular(8));
    canvas.drawRRect(outerRect, paint);

    final RRect labelRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(12, 12, size.width - 24, size.height * 0.45),
        const Radius.circular(4));
    canvas.drawRRect(labelRect, paint);

    double lineY1 = size.height * 0.35;
    double lineY2 = size.height * 0.42;
    canvas.drawLine(Offset(20, lineY1), Offset(size.width - 20, lineY1), paint);
    canvas.drawLine(Offset(20, lineY2), Offset(size.width - 20, lineY2), paint);

    double winW = size.width * 0.60;
    double winH = size.height * 0.22;
    double winX = (size.width - winW) / 2;
    double winY = size.height * 0.55;

    final RRect windowRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(winX, winY, winW, winH), const Radius.circular(4));

    // Reel window visuals match [TapeReelTransport] / [_CassetteWindowPainter]
    // (static tape-at-start: left pack large, right pack small).
    final rect = windowRect.outerRect;
    final midY = rect.center.dy;
    final leftCx = rect.left + rect.width * 0.21;
    final rightCx = rect.left + rect.width * 0.79;
    const leftFill = 1.0;
    const rightFill = 0.0;

    final tapeMaxR = min(rect.height * 0.46, rect.width * 0.2);
    final tapeMinR = tapeMaxR * 0.22;
    final tapeLeftR = tapeMinR + (tapeMaxR - tapeMinR) * leftFill;
    final tapeRightR = tapeMinR + (tapeMaxR - tapeMinR) * rightFill;

    final hubR = tapeMaxR * 0.14;
    final spokeInner = hubR * 1.15;
    final spokeOuter = tapeMaxR * 0.34;

    canvas.save();
    canvas.clipRRect(windowRect);

    canvas.drawRRect(
      windowRect,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill,
    );

    final tapeFill = Paint()
      ..color = Colors.white.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(leftCx, midY), tapeLeftR, tapeFill);
    canvas.drawCircle(Offset(rightCx, midY), tapeRightR, tapeFill);

    final lip = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(Offset(leftCx, midY), tapeLeftR, lip);
    canvas.drawCircle(Offset(rightCx, midY), tapeRightR, lip);

    final yLow = midY + min(tapeLeftR, tapeRightR) * 0.72;
    final yHigh = midY - min(tapeLeftR, tapeRightR) * 0.72;
    final leftEdgeX = leftCx + tapeLeftR;
    final rightEdgeX = rightCx - tapeRightR;
    if (rightEdgeX > leftEdgeX + 4) {
      final pathPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square;
      canvas.drawLine(
          Offset(leftEdgeX, yHigh), Offset(rightEdgeX, yHigh), pathPaint);
      canvas.drawLine(
          Offset(leftEdgeX, yLow), Offset(rightEdgeX, yLow), pathPaint);
      final pathFlow = spinProgress;
      if (pathFlow > 0) {
        const dash = 4.0;
        final off = pathFlow * dash * 2;
        final thin = Paint()
          ..color = Colors.white.withValues(alpha: 0.09)
          ..strokeWidth = 1;
        double x = leftEdgeX - off % (dash * 2);
        while (x < rightEdgeX) {
          canvas.drawLine(
              Offset(x, yHigh - 1), Offset(x + dash, yHigh - 1), thin);
          x += dash * 2;
        }
      }
    }

    final base = spinProgress * 2 * pi;
    final rotL =
        base * (0.52 + 0.48 * (0.35 + 0.65 * (1.0 - leftFill)));
    final rotR =
        base * (0.52 + 0.48 * (0.35 + 0.65 * (1.0 - rightFill)));

    void drawHub(double cx, double cy, double rot) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rot);
      final sp = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.square;
      for (int k = 0; k < 3; k++) {
        final a = k * 2 * pi / 3;
        final p1 = Offset(cos(a), sin(a)) * spokeInner;
        final p2 = Offset(cos(a), sin(a)) * spokeOuter;
        canvas.drawLine(p1, p2, sp);
      }
      canvas.restore();

      canvas.drawCircle(
        Offset(cx, cy),
        hubR,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(cx, cy),
        hubR,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    drawHub(leftCx, midY, rotL);
    drawHub(rightCx, midY, rotR);

    canvas.restore();

    canvas.drawRRect(
      windowRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.38)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    void drawScrew(double cx, double cy) {
      canvas.drawCircle(Offset(cx, cy), 3, paint);
      canvas.drawLine(Offset(cx - 2, cy - 2), Offset(cx + 2, cy + 2), paint);
    }

    drawScrew(8, 8);
    drawScrew(size.width - 8, 8);
    drawScrew(8, size.height - 8);
    drawScrew(size.width - 8, size.height - 8);

    double trapTopW = size.width * 0.6;
    double trapBotW = size.width * 0.7;
    double trapX = (size.width - trapBotW) / 2;
    double trapTopX = (size.width - trapTopW) / 2;
    double trapY = size.height - 18;

    Path trapPath = Path()
      ..moveTo(trapTopX, trapY)
      ..lineTo(trapTopX + trapTopW, trapY)
      ..lineTo(trapX + trapBotW, size.height)
      ..lineTo(trapX, size.height)
      ..close();

    canvas.drawPath(trapPath, paint);

    canvas.drawCircle(Offset(size.width * 0.3, size.height - 8), 4, paint);
    canvas.drawCircle(Offset(size.width * 0.7, size.height - 8), 4, paint);
    canvas.drawCircle(Offset(size.width * 0.5, size.height - 8), 4, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CassettePainter old) =>
      old.spinProgress != spinProgress;
}

class _MenuBtn extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  const _MenuBtn(this.text, this.onTap);

  @override
  State<_MenuBtn> createState() => _MenuBtnState();
}

class _MenuBtnState extends State<_MenuBtn> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 50),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: _isPressed ? Colors.white : Colors.black,
            border: Border.all(
                color: _isPressed ? Colors.white : Colors.white70,
                width: _isPressed ? 3 : 2),
          ),
          child: Text(widget.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isPressed ? Colors.black : Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 14,
                letterSpacing: 1,
              )),
        ));
  }
}

class RecorderScreen extends StatefulWidget {
  final String projectName;
  final bool isNewProject;
  final bool createAsNativeTestProject;

  const RecorderScreen({
    super.key,
    required this.projectName,
    required this.isNewProject,
    this.createAsNativeTestProject = false,
  });

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class OrpheusConsole extends RecorderScreen {
  const OrpheusConsole({
    super.key,
    required super.projectName,
    required super.isNewProject,
    super.createAsNativeTestProject,
  });
}

class _RecorderScreenState extends State<RecorderScreen> {
  /// N3E-G: native playback-only bridge when selector is nativeExperimental.
  NativeOboeRecorderEngine? _nativeOboeEngine;
  bool _nativePlaybackActive = false;

  bool _isPlaying = false;
  bool _isRecording = false;
  bool _isExporting = false;
  int? _exportSessionId;

  Timer? _tickerTimer;
  Timer? _autosaveTimer;

  late String _projectName;
  DateTime _sessionCreatedAt = DateTime.now();
  String _projectAudioEngine = kOrpheusAudioEngineLegacy;

  final List<bool> _armedTracks = [false, false, false, false];
  final List<String?> _trackFiles = [null, null, null, null];
  final List<int> _trackOffsets = [
    0,
    0,
    0,
    0
  ]; // ms offset per track (measured at overdub start)
  final List<int> _trackTapeStartMs = [0, 0, 0, 0];
  final List<double> _trackVolumes = [1.0, 1.0, 1.0, 1.0];
  final List<bool> _trackMutes = [false, false, false, false];
  final List<bool> _trackSolos = [false, false, false, false];
  List<ExportEntry> _exports = [];

  static const MethodChannel _androidExportChannel =
      MethodChannel('com.junkfeathers.orpheusdeck/export');

  int _bpm = 120;
  bool _metronomeOn = false;
  String _metronomeSound = 'CLICK';

  final AudioRecorder _recorder = AudioRecorder();

  /// Independent just_audio players — one per track. Using just_audio
  /// instead of audioplayers because just_audio handles concurrent
  /// Android AudioFocus correctly without stealing the session from siblings.
  final List<ja.AudioPlayer> _trackPlayers =
      List.generate(4, (_) => ja.AudioPlayer());

  /// Hidden click-track bus: timeline WAV only — never an armed recording track.
  late ja.AudioPlayer _clickPlayer;
  StreamSubscription<ja.PlaybackEvent>? _clickPlaybackSub;
  String? _clickPlayerSourcePath;
  bool _isBuildingClickTrack = false;

  final Map<String, List<double>> _waveformCache = {};
  final List<double> _liveAmplitudes = [];
  StreamSubscription<Amplitude>? _amplitudeSub;
  /// One subscription per track player, watching for natural playback completion.
  final List<StreamSubscription?> _playerCompletionSubs = [null, null, null, null];

  double _playbackProgress = 0.0;
  /// Cassette tape head (ms); header clock, locator/reel, and waveform playhead
  /// all read this field from parent rebuilds (`setState` every transport tick).
  int _playbackMs = 0;
  int? _activeRecordTapeStartMs;

  /// Tracks scheduled for playback that have not yet reached their tape-start.
  /// Promoted to play() inside [_startTicker] when [_playbackMs] catches up.
  final Set<int> _pendingPlaybackIndices = {};

  /// Total scheduled tracks (immediate + pending) for the current PLAY session.
  /// Used together with [_completedPlaybackCount] for the auto-stop check so
  /// tape transport keeps running until every scheduled clip has finished.
  int _scheduledPlaybackCount = 0;
  int _completedPlaybackCount = 0;

  final UndoState _lastUndo = UndoState();

  @override
  void initState() {
    super.initState();
    _projectName = widget.projectName;
    _clickPlayer = ja.AudioPlayer();
    _clickPlaybackSub = _clickPlayer.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        debugPrint('Orpheus Deck: CLICK player stream error: $e\n$st');
        _disableClickTrackDueToAudioConflict();
      },
    );
    _initAudioSession();

    if (widget.isNewProject) {
      _initializeNewProject(_projectName);
    } else {
      _loadSession();
    }

    _autosaveTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isPlaying || _isRecording) _saveSession();
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _autosaveTimer?.cancel();
    _amplitudeSub?.cancel();
    for (var sub in _playerCompletionSubs) {
      sub?.cancel();
    }

    if (_isRecording) {
      _recorder.stop();
    }
    _recorder.dispose();
    unawaited(_nativeOboeEngine?.dispose());

    _clickPlaybackSub?.cancel();
    _clickPlaybackSub = null;
    _clickPlayer.dispose();

    for (var player in _trackPlayers) {
      player.dispose();
    }

    if (_isExporting && _exportSessionId != null) {
      FFmpegKit.cancel(_exportSessionId);
    }
    super.dispose();
  }

  String _clickSoundFileSlug(String sound) {
    switch (sound) {
      case 'BEEP':
        return 'beep';
      case 'WOOD':
        return 'wood';
      default:
        return 'click';
    }
  }

  String _clickFilenameForCurrentSpec() =>
      'click_${_bpm}_${_clickSoundFileSlug(_metronomeSound)}.wav';

  Future<String> _clickTrackAbsolutePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
    if (!await projDir.exists()) {
      await projDir.create(recursive: true);
    }
    return '${projDir.path}/${_clickFilenameForCurrentSpec()}';
  }

  bool _fileMatchesCurrentClickSpec(String absolutePath) {
    final name = absolutePath.split(RegExp(r'[/\\]')).last;
    return name == _clickFilenameForCurrentSpec();
  }

  /// Upper bound for [_playbackMs] during transport (play or record).
  /// Always the physical tape side — never the longest recorded clip.
  int _tapeTransportMaxMs() => tapeLengthMs;

  /// Updates [_playbackMs] and [_playbackProgress] without [setState].
  /// Use inside existing [setState] blocks, or call [_setTapeHeadMs] from UI.
  void _applyTapeHeadClamped(int ms) {
    final int maxMs = _tapeTransportMaxMs();
    _playbackMs = ms.clamp(0, maxMs);
    _playbackProgress = maxMs > 0 ? _playbackMs / maxMs : 0.0;
    if (_playbackProgress > 1.0) _playbackProgress = 1.0;
  }

  /// Single entry point for moving the tape head (transport clock + reel + dial).
  void _setTapeHeadMs(int ms) {
    if (!mounted) return;
    setState(() => _applyTapeHeadClamped(ms));
  }

  /// Longest clip on the deck (ms), for diagnostics only — not the tape clock cap.
  int _getMaxPlaybackDuration() {
    int maxMs = 0;
    for (int i = 0; i < 4; i++) {
      if (_trackFiles[i] != null &&
          _waveformCache.containsKey(_trackFiles[i]!)) {
        int ms = _waveformCache[_trackFiles[i]!]!.length * 50;
        if (ms > maxMs) maxMs = ms;
      }
    }
    return maxMs;
  }

  /// FFmpeg `adelay` baseline when latency compensation applies: aligns export
  /// timeline with PLAY/monitor trimming (matches [_playbackSeekMsForTrack]).
  int _exportAdelayMsFromTapeStart(int tapeStartMs) {
    if (!OrpheusSettings.instance.latencyCompensationEnabled) {
      return tapeStartMs.clamp(0, tapeLengthMs);
    }
    final m = OrpheusSettings.instance.manualLatencyAdjustMs;
    return (tapeStartMs - m).clamp(0, tapeLengthMs);
  }

  /// Waveform lane horizontal offset only; unchanged when compensation is OFF.
  int _waveformLaneTapeStartMs(int storedTapeStartMs) {
    if (!OrpheusSettings.instance.latencyCompensationEnabled) {
      return storedTapeStartMs.clamp(0, tapeLengthMs);
    }
    final m = OrpheusSettings.instance.manualLatencyAdjustMs;
    return (storedTapeStartMs - m).clamp(0, tapeLengthMs);
  }

  /// Per-track clip length from cached waveform (ms).
  int _trackContentDurationMs(int trackIndex) {
    final p = _trackFiles[trackIndex];
    if (p == null || !_waveformCache.containsKey(p)) return 0;
    return _waveformCache[p]!.length * 50;
  }

  /// File seek for track [trackIndex] when tape head is at [tapeHeadMs].
  /// Applies optional per-take launch measurement ([_trackOffsets]) when latency
  /// compensation is ON, then global [OrpheusSettings.manualLatencyAdjustMs]
  /// (only while compensation is ON; export uses the same rule via
  /// [_exportAdelayMsFromTapeStart]).
  int _playbackSeekMsForTrack(
    int trackIndex,
    int tapeHeadMs,
    int tapeStart,
    int clipDur,
  ) {
    final int cap = clipDur > 0 ? clipDur : 0x7fffffff;
    int local = (tapeHeadMs - tapeStart).clamp(0, cap);
    if (OrpheusSettings.instance.latencyCompensationEnabled) {
      final int off = _trackOffsets[trackIndex];
      if (off > 0) local = max(0, local - off);
    }
    final int manual = OrpheusSettings.instance.latencyCompensationEnabled
        ? OrpheusSettings.instance.manualLatencyAdjustMs
        : 0;
    local = max(0, local - manual);
    return min(local, cap);
  }

  int _storedLatencyOffsetMs(int measuredLaunchMs) {
    if (!OrpheusSettings.instance.latencyCompensationEnabled) return 0;
    return measuredLaunchMs;
  }

  void _onTapeHeadSeekFromReel(int ms) {
    if (_isPlaying || _isRecording || _isExporting) return;
    _setTapeHeadMs(ms);
    debugPrint(
      'Orpheus Deck: TAPE_HEAD_SEEK playbackMs=$_playbackMs tapeLengthMs=$tapeLengthMs',
    );
  }

  Future<void> _pruneStaleClickWavs(Directory projDir, String keepPath) async {
    if (!await projDir.exists()) return;
    final keepName = keepPath.split(RegExp(r'[/\\]')).last;
    try {
      for (final e in projDir.listSync()) {
        if (e is! File) continue;
        final n = e.path.split(RegExp(r'[/\\]')).last;
        if (n.startsWith('click_') && n.endsWith('.wav') && n != keepName) {
          try {
            await e.delete();
            debugPrint('Orpheus Deck: CLICK removed stale $n');
          } catch (err) {
            debugPrint('Orpheus Deck: CLICK stale delete err $err');
          }
        }
      }
    } catch (e, st) {
      debugPrint('Orpheus Deck: CLICK prune error $e\n$st');
    }
  }

  Future<void> _materializeClickFile(String path) async {
    debugPrint(
        'Orpheus Deck: CLICK generation START bpm=$_bpm sound=$_metronomeSound path=$path');
    final bytes = await compute(
      buildClickTrackWavBytes,
      ClickWavParams(_bpm, _metronomeSound),
    );
    await _pruneStaleClickWavs(File(path).parent, path);
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    final len = await f.length();
    debugPrint(
        'Orpheus Deck: CLICK generation DONE size=$len bpm=$_bpm sound=$_metronomeSound path=$path');
  }

  Future<void> _runWithBuildingClickDialog(Future<void> Function() job) async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        shape: Border.all(color: Colors.white, width: 2),
        content: const Row(
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                'BUILDING CLICK TRACK',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    try {
      await job();
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// Builds WAV on disk when missing or spec changed (filename encodes bpm + sound).
  Future<String?> _ensureClickTrackFile({bool showBuildingUi = false}) async {
    if (!_metronomeOn) return null;
    final path = await _clickTrackAbsolutePath();
    final f = File(path);
    if (await f.exists() && await f.length() > 1000 && _fileMatchesCurrentClickSpec(path)) {
      debugPrint('Orpheus Deck: CLICK reuse existing path=$path size=${await f.length()}');
      return path;
    }
    if (_isBuildingClickTrack) {
      debugPrint('Orpheus Deck: CLICK generation already in progress — skip duplicate');
      return null;
    }
    _isBuildingClickTrack = true;
    try {
      if (showBuildingUi && mounted) {
        await _runWithBuildingClickDialog(() => _materializeClickFile(path));
      } else {
        await _materializeClickFile(path);
      }
    } catch (e, st) {
      debugPrint('Orpheus Deck: CLICK generation FAILED $e\n$st');
      if (mounted) {
        _showSnackbar('ERR: CLICK TRACK BUILD FAILED');
      }
      return null;
    } finally {
      _isBuildingClickTrack = false;
    }
    if (!File(path).existsSync()) return null;
    return path;
  }

  Future<void> _stopClickPlayback() async {
    try {
      await _clickPlayer.stop();
      debugPrint(
          'Orpheus Deck: CLICK player STOP recording=$_isRecording playing=$_isPlaying');
    } catch (e, st) {
      debugPrint('Orpheus Deck: CLICK player stop error $e\n$st');
    }
  }

  void _disableClickTrackDueToAudioConflict() {
    debugPrint(
        'Orpheus Deck: CLICK DISABLED: AUDIO CONFLICT '
        'recording=$_isRecording playing=$_isPlaying overdub=$_isOverdubbing');
    unawaited(_stopClickPlayback());
    if (!mounted) return;
    setState(() => _metronomeOn = false);
    _saveSession();
    _showSnackbar('CLICK DISABLED: AUDIO CONFLICT');
  }

  Future<void> _tryStartClickPlayback({required String contextTag, int? seekMs}) async {
    if (!_metronomeOn) return;
    final bool showBuild =
        contextTag == 'play' || contextTag == 'record';
    try {
      final path = await _ensureClickTrackFile(showBuildingUi: showBuild);
      if (path == null || !File(path).existsSync()) {
        debugPrint('Orpheus Deck: CLICK start aborted (no file) ctx=$contextTag');
        return;
      }
      if (_clickPlayerSourcePath != path) {
        await _clickPlayer.setFilePath(path);
        _clickPlayerSourcePath = path;
      }
      await _clickPlayer.setVolume(1.0);
      final int clickSeekMs = (seekMs ?? _playbackMs).clamp(0, tapeLengthMs);
      await _clickPlayer.seek(Duration(milliseconds: clickSeekMs));
      debugPrint(
          'Orpheus Deck: CLICK seek ctx=$contextTag seekMs=$clickSeekMs');
      await _clickPlayer.play();
      debugPrint(
          'Orpheus Deck: CLICK player START ctx=$contextTag posMs=$clickSeekMs '
          'bpm=$_bpm sound=$_metronomeSound recording=$_isRecording playing=$_isPlaying path=$path');
    } catch (e, st) {
      debugPrint(
          'Orpheus Deck: CLICK player START FAILED ctx=$contextTag recording=$_isRecording $e\n$st');
      _disableClickTrackDueToAudioConflict();
    }
  }

  Future<void> _resyncClickPlayerToTransport() async {
    if (!_metronomeOn || !_isPlaying) return;
    try {
      final pos = _clickPlayer.position.inMilliseconds;
      final delta = (_playbackMs - pos).abs();
      if (delta > 140) {
        await _clickPlayer.seek(Duration(milliseconds: _playbackMs));
        debugPrint(
            'Orpheus Deck: CLICK resync seek to $_playbackMs (was $pos) recording=$_isRecording');
      }
    } catch (e, st) {
      debugPrint('Orpheus Deck: CLICK resync error $e\n$st');
    }
  }

  Future<void> _setLastProjectName(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/OrpheusDeck/last_project.txt');
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(name);
    } catch (e, s) {
      debugPrint('Error setting last project name: $e\n$s');
    }
  }

  Future<void> _cleanTrash() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (await projDir.exists()) {
        final files = projDir.listSync();
        for (var file in files) {
          if (file is File && file.path.endsWith('.trash')) {
            file.deleteSync();
          }
        }
      }
    } catch (e, s) {
      debugPrint('Error cleaning trash: $e\n$s');
    }
  }

  Future<void> _recoverOrphanedRecordings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (await projDir.exists()) {
        final files = projDir.listSync();
        bool recovered = false;
        for (var file in files) {
          if (file is File &&
              file.path.endsWith('.m4a') &&
              file.path.contains('track_')) {
            if (!_trackFiles.contains(file.path)) {
              String filename = file.path.split(RegExp(r'[/\\]')).last;
              final nameParts = filename.split('_');
              if (nameParts.length >= 2) {
                int? trackIndex = int.tryParse(nameParts[1]);
                if (trackIndex != null && trackIndex >= 0 && trackIndex < 4) {
                  if (_trackFiles[trackIndex] == null) {
                    _trackFiles[trackIndex] = file.path;
                    _waveformCache[file.path] = [];
                    recovered = true;
                    debugPrint(
                        "Orpheus Deck: RECOVERY LOG - Recovered orphaned recording to track $trackIndex: ${file.path}");
                  }
                }
              }
            }
          }
        }
        if (recovered) {
          _saveSession();
          _showSnackbar("RECOVERED UNFINISHED RECORDING");
        }
      }
    } catch (e, s) {
      debugPrint('Error recovering recordings: $e\n$s');
    }
  }

  bool get _isNativeTestProject =>
      isNativeTestAudioEngine(_projectAudioEngine);

  void _scheduleNativeTestProjectToastIfNeeded() {
    if (!kDebugMode || !_isNativeTestProject) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      showOrpheusOledToast(context, 'NATIVE TEST PROJECT');
    });
  }

  Future<void> _initializeNewProject(String name) async {
    _projectName = name;
    _sessionCreatedAt = DateTime.now();
    _projectAudioEngine = widget.createAsNativeTestProject && kDebugMode
        ? kOrpheusAudioEngineNativeTest
        : kOrpheusAudioEngineLegacy;
    for (int i = 0; i < 4; i++) {
      _trackFiles[i] = null;
      _armedTracks[i] = false;
      _trackOffsets[i] = 0;
      _trackTapeStartMs[i] = 0;
      _trackVolumes[i] = 1.0;
      _trackMutes[i] = false;
      _trackSolos[i] = false;
    }
    _waveformCache.clear();
    _exports.clear();
    _applyTapeHeadClamped(0);
    _lastUndo.clear();
    _clickPlayerSourcePath = null;

    _updateMixerState();
    await _saveSession();
    _scheduleNativeTestProjectToastIfNeeded();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadSession() async {
    try {
      await _cleanTrash();

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/OrpheusDeck/$_projectName/session.json');

      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final session = Session.fromJson(jsonDecode(jsonString));

        for (int i = 0; i < 4; i++) {
          final trackPath = session.trackFiles[i];
          if (trackPath != null) {
            final f = File(trackPath);
            if (!await f.exists()) {
              session.trackFiles[i] = null;
              session.waveformCache.remove(trackPath);
            }
          }
        }

        final keptExports = <ExportEntry>[];
        for (final e in session.exports) {
          if (await _exportEntryStillValid(e)) keptExports.add(e);
        }

        setState(() {
          _projectName = session.projectName;
          _sessionCreatedAt = session.createdAt;
          _projectAudioEngine = session.audioEngine;
          for (int i = 0; i < 4; i++) {
            _trackFiles[i] = session.trackFiles[i];
            _trackOffsets[i] = session.trackOffsets[i];
            _trackTapeStartMs[i] = session.trackTapeStartMs[i];
            _trackVolumes[i] = session.trackVolumes[i];
            _trackMutes[i] = session.trackMutes[i];
            _trackSolos[i] = session.trackSolos[i];
          }
          _waveformCache.addAll(session.waveformCache);

          _exports = keptExports;

          _bpm = session.bpm;
          _metronomeOn = session.metronomeOn;
          _metronomeSound = session.metronomeSound;
        });
        _clickPlayerSourcePath = null;
      }

      _lastUndo.clear();
      await _recoverOrphanedRecordings();
      _updateMixerState();
      await _setLastProjectName(_projectName);
      _scheduleNativeTestProjectToastIfNeeded();
    } catch (e) {
      debugPrint("Orpheus Deck: Error loading session: $e");
    }
  }

  Future<void> _saveSession() async {
    try {
      final session = Session(
        projectName: _projectName,
        createdAt: _sessionCreatedAt,
        updatedAt: DateTime.now(),
        trackFiles: _trackFiles,
        waveformCache: _waveformCache,
        trackIds: [null, null, null, null],
        trackOffsets: List<int>.from(_trackOffsets),
        trackTapeStartMs: List<int>.from(_trackTapeStartMs),
        trackVolumes: _trackVolumes,
        trackMutes: _trackMutes,
        trackSolos: _trackSolos,
        exports: _exports,
        bpm: _bpm,
        metronomeOn: _metronomeOn,
        metronomeSound: _metronomeSound,
        audioEngine: _projectAudioEngine,
      );

      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (!await projDir.exists()) {
        await projDir.create(recursive: true);
      }

      final tempFile = File('${projDir.path}/session.tmp');
      final finalFile = File('${projDir.path}/session.json');

      await tempFile.writeAsString(jsonEncode(session.toJson()), flush: true);
      await tempFile.rename(finalFile.path);

      await _setLastProjectName(_projectName);
    } catch (e, s) {
      debugPrint('Error saving session: $e\n$s');
    }
  }

  void _performUndo() async {
    if (_isRecording || _isPlaying) {
      _showSnackbar("ERR: STOP TRANSPORT TO UNDO");
      return;
    }

    if (_lastUndo.action == UndoAction.clearTrack) {
      int idx = _lastUndo.trackIndex!;
      String file = _lastUndo.trackFile!;
      if (_trackFiles[idx] != null) {
        _showSnackbar("ERR: TRACK 0${idx + 1} NOT EMPTY");
        return;
      }

      File trash = File('$file.trash');
      if (trash.existsSync()) {
        trash.renameSync(file);
        setState(() {
          _trackFiles[idx] = file;
          _trackTapeStartMs[idx] = _lastUndo.trackTapeStartMs ?? 0;
          if (_lastUndo.trackWaveform != null) {
            _waveformCache[file] = _lastUndo.trackWaveform!;
          }
        });
        _showSnackbar("TRACK 0${idx + 1} RESTORED");
      }
    } else if (_lastUndo.action == UndoAction.mixer) {
      setState(() {
        _trackVolumes.setAll(0, _lastUndo.volumes!);
        _trackMutes.setAll(0, _lastUndo.mutes!);
        _trackSolos.setAll(0, _lastUndo.solos!);
      });
      _updateMixerState();
      _showSnackbar("MIXER SETTINGS RESTORED");
    } else if (_lastUndo.action == UndoAction.rename) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final currentDir =
            Directory('${dir.path}/OrpheusDeck/${_lastUndo.newName}');
        final oldDir =
            Directory('${dir.path}/OrpheusDeck/${_lastUndo.oldName}');
        if (await currentDir.exists()) {
          await currentDir.rename(oldDir.path);

          Map<String, List<double>> newCache = {};
          for (int i = 0; i < 4; i++) {
            if (_trackFiles[i] != null) {
              String currentPath = _trackFiles[i]!;
              String oldPath = currentPath.replaceFirst(
                  '/OrpheusDeck/${_lastUndo.newName}/',
                  '/OrpheusDeck/${_lastUndo.oldName}/');
              _trackFiles[i] = oldPath;
              if (_waveformCache.containsKey(currentPath)) {
                newCache[oldPath] = _waveformCache[currentPath]!;
              }
            }
          }
          _waveformCache.clear();
          _waveformCache.addAll(newCache);

          final newExports = <ExportEntry>[];
          for (final e in _exports) {
            final ap = e.absolutePath;
            if (ap != null &&
                ap.contains('/OrpheusDeck/${_lastUndo.newName}/')) {
              newExports.add(e.copyWith(
                  absolutePath: ap.replaceFirst(
                      '/OrpheusDeck/${_lastUndo.newName}/',
                      '/OrpheusDeck/${_lastUndo.oldName}/')));
            } else {
              newExports.add(e);
            }
          }
          _exports.clear();
          _exports.addAll(newExports);

          setState(() {
            _projectName = _lastUndo.oldName!;
          });
          await _setLastProjectName(_projectName);
          _showSnackbar("PROJECT RENAME UNDONE");
        }
      } catch (e) {
        _showSnackbar("ERR: UNDO RENAME FAILED");
      }
    }

    setState(() {
      _lastUndo.clear();
    });
    _saveSession();
  }

  Future<void> _renameProject(String newName) async {
    String safeName = newName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (safeName.isEmpty || safeName == _projectName) return;
    _stop();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final oldDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      final newDir = Directory('${dir.path}/OrpheusDeck/$safeName');

      if (await oldDir.exists()) {
        _lastUndo.clear();
        _lastUndo.action = UndoAction.rename;
        _lastUndo.oldName = _projectName;
        _lastUndo.newName = safeName;

        await oldDir.rename(newDir.path);

        Map<String, List<double>> newCache = {};
        for (int i = 0; i < 4; i++) {
          if (_trackFiles[i] != null) {
            String oldPath = _trackFiles[i]!;
            String newPath = oldPath.replaceFirst(
                '/OrpheusDeck/$_projectName/', '/OrpheusDeck/$safeName/');
            _trackFiles[i] = newPath;
            if (_waveformCache.containsKey(oldPath)) {
              newCache[newPath] = _waveformCache[oldPath]!;
            }
          }
        }
        _waveformCache.clear();
        _waveformCache.addAll(newCache);

        final newExports = <ExportEntry>[];
        for (final e in _exports) {
          final ap = e.absolutePath;
          if (ap != null && ap.contains('/OrpheusDeck/$_projectName/')) {
            newExports.add(e.copyWith(
                absolutePath: ap.replaceFirst(
                    '/OrpheusDeck/$_projectName/', '/OrpheusDeck/$safeName/')));
          } else {
            newExports.add(e);
          }
        }
        _exports.clear();
        _exports.addAll(newExports);
      }

      setState(() {
        _projectName = safeName;
      });
      _clickPlayerSourcePath = null;
      await _saveSession();
      _showSnackbar("PROJECT RENAMED");
    } catch (e) {
      _showSnackbar("ERR: RENAME FAILED");
    }
  }

  Future<void> _newProject(String name) async {
    String safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (safeName.isEmpty) safeName = "SESSION_001";
    await _cleanTrash();
    _stop();
    await _initializeNewProject(safeName);
    setState(() {});
    _showSnackbar("NEW PROJECT CREATED");
  }

  Future<bool> _exportEntryStillValid(ExportEntry e) async {
    if (e.absolutePath != null) {
      return File(e.absolutePath!).existsSync();
    }
    if (Platform.isAndroid &&
        e.storageUri != null &&
        e.storageUri!.startsWith('content://')) {
      try {
        final ok = await _androidExportChannel.invokeMethod<bool>(
            'contentUriExists', {'uri': e.storageUri});
        return ok ?? true;
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  Future<Directory> _nonAndroidExportDirectory() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return Directory(
          '${downloads.path}${Platform.pathSeparator}Orpheus Deck');
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(
        '${docs.path}${Platform.pathSeparator}OrpheusDeckExports');
  }

  String _nonAndroidDisplayPath(String fileName, Directory destDir) {
    final p = destDir.path;
    if (p.contains('Download')) {
      return 'Downloads/Orpheus Deck/$fileName';
    }
    return 'Documents/OrpheusDeckExports/$fileName';
  }

  Future<ExportEntry?> _finalizeExportAfterFfmpeg({
    required String tempPath,
    required String fileName,
    required String kind,
  }) async {
    if (Platform.isAndroid) {
      try {
        final dynamic raw = await _androidExportChannel.invokeMethod(
          'publishToMusicFolder',
          <String, dynamic>{
            'sourcePath': tempPath,
            'fileName': fileName,
          },
        );
        await _deleteExportIfExists(tempPath);
        if (raw is! Map) return null;
        final uri = raw['uri']?.toString();
        final displayPath =
            raw['displayPath']?.toString() ?? 'Music/Orpheus Deck/$fileName';
        if (uri == null) return null;
        debugPrint(
            'Orpheus Deck: published Android uri=$uri displayPath=$displayPath');
        return ExportEntry(
          filename: fileName,
          displayPath: displayPath,
          storageUri: uri,
          absolutePath: null,
          kind: kind,
          createdAt: DateTime.now(),
        );
      } on PlatformException catch (e, st) {
        debugPrint(
            'Orpheus Deck: publishToMusicFolder ${e.code} ${e.message}\n$st');
        await _deleteExportIfExists(tempPath);
        return null;
      }
    }

    final destDir = await _nonAndroidExportDirectory();
    await destDir.create(recursive: true);
    final destPath =
        '${destDir.path}${Platform.pathSeparator}$fileName';
    await File(tempPath).copy(destPath);
    await _deleteExportIfExists(tempPath);
    debugPrint('Orpheus Deck: published non-Android path=$destPath');
    return ExportEntry(
      filename: fileName,
      displayPath: _nonAndroidDisplayPath(fileName, destDir),
      storageUri: null,
      absolutePath: destPath,
      kind: kind,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _shareExportEntry(ExportEntry e) async {
    try {
      final uriStr = e.storageUri;
      // share_plus on Android treats paths as java.io.File and wraps FileProvider;
      // MediaStore content:// URIs must be sent via ACTION_SEND + EXTRA_STREAM.
      if (uriStr != null &&
          uriStr.startsWith('content://') &&
          Platform.isAndroid) {
        debugPrint('Orpheus Deck: share export — MediaStore URI: $uriStr');
        await _androidExportChannel.invokeMethod<void>('shareMusicExport', {
          'uri': uriStr,
        });
        debugPrint('Orpheus Deck: share export — native share sheet launched');
        return;
      }
      if (e.absolutePath != null && File(e.absolutePath!).existsSync()) {
        final path = e.absolutePath!;
        debugPrint('Orpheus Deck: share export — filesystem path: $path');
        await SharePlus.instance.share(ShareParams(
          files: [XFile(path)],
          text: 'Exported from Orpheus Deck',
        ));
        return;
      }
      debugPrint(
          'Orpheus Deck: share export — nothing to share for ${e.filename}');
    } catch (err, st) {
      debugPrint('Orpheus Deck: share export failed: $err\n$st');
      if (mounted) {
        _showSnackbar('SHARE FAILED');
      }
    }
  }

  Future<void> _tryOpenExportLocation(ExportEntry entry) async {
    if (Platform.isAndroid && entry.storageUri != null) {
      try {
        final opened = await _androidExportChannel
            .invokeMethod<bool>('tryOpenExportLocation', {
          'uri': entry.storageUri,
        });
        if (opened == true && mounted) return;
      } catch (_) {}
      if (mounted) {
        _showSnackbar('Saved to Music / Orpheus Deck');
      }
      return;
    }
    if (entry.absolutePath != null) {
      final dir = File(entry.absolutePath!).parent.path;
      final OpenResult r = await OpenFile.open(dir);
      debugPrint(
          'Orpheus Deck: OpenFile dir type=${r.type} message=${r.message}');
      if (r.type != ResultType.done && mounted) {
        _showSnackbar('Saved to ${entry.displayPath}');
      }
    }
  }

  bool _exportEntrySameLogicalTarget(ExportEntry a, ExportEntry b) {
    final ua = a.storageUri;
    final ub = b.storageUri;
    if (ua != null && ua.isNotEmpty && ub != null && ua == ub) return true;
    final pa = a.absolutePath;
    final pb = b.absolutePath;
    if (pa != null &&
        pb != null &&
        pa.isNotEmpty &&
        pb.isNotEmpty &&
        pa == pb) {
      return true;
    }
    return a.filename.toLowerCase() == b.filename.toLowerCase();
  }

  Future<_ExportBrowseSnapshot> _loadExportsBrowseSnapshot() async {
    bool scanErrored = false;
    final scanMaps = <Map<String, dynamic>>[];

    if (Platform.isAndroid) {
      try {
        final dynamic raw =
            await _androidExportChannel.invokeMethod('scanOrpheusMusicExports');
        if (raw is List) {
          for (final item in raw) {
            if (item is Map) {
              scanMaps.add(Map<String, dynamic>.from(item));
            }
          }
        }
      } catch (e, st) {
        scanErrored = true;
        debugPrint('Orpheus Deck: scanOrpheusMusicExports err $e\n$st');
      }
    }

    ExportEntry scannedRow(Map<String, dynamic> m) {
      final fn = (m['filename']?.toString() ?? '').trim();
      final uri = m['storageUri']?.toString();
      final sec = (m['dateAddedSec'] as num?)?.toInt();
      final lower = fn.toLowerCase();
      final kind = lower.contains('mastermix') ||
              lower.contains('youtube_master')
          ? 'MASTERMIX'
          : 'RAW MIX';
      final DateTime when;
      if (sec != null) {
        when = DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
            .toLocal();
      } else {
        when = DateTime.fromMillisecondsSinceEpoch(0);
      }
      return ExportEntry(
        filename: fn,
        displayPath: 'Music/Orpheus Deck/$fn',
        storageUri: uri,
        absolutePath: null,
        kind: kind,
        createdAt: when,
      );
    }

    final fromScan = scanMaps
        .map(scannedRow)
        .where((e) => e.filename.isNotEmpty)
        .toList();

    final byUri = <String, ExportEntry>{};
    final byName = <String, ExportEntry>{};
    for (final e in _exports) {
      if (e.storageUri != null) byUri[e.storageUri!] = e;
      byName[e.filename.toLowerCase()] = e;
    }

    final merged = List<ExportEntry>.from(_exports);
    for (final e in fromScan) {
      if (e.storageUri != null && byUri.containsKey(e.storageUri)) continue;
      if (byName.containsKey(e.filename.toLowerCase())) continue;
      merged.add(e);
    }
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    String? footer;
    if (merged.isEmpty) {
      footer = 'EXPORTS SAVED TO MUSIC/ORPHEUS DECK';
    } else if (Platform.isAndroid &&
        scanErrored &&
        fromScan.isEmpty) {
      footer =
          'EXPORT SCAN UNAVAILABLE • EXPORTS ALSO SAVED TO MUSIC/ORPHEUS DECK';
    }

    return _ExportBrowseSnapshot(entries: merged, footerHintText: footer);
  }

  Future<bool> _deleteExportBrowsedEntry(ExportEntry e) async {
    bool removed = false;
    if (Platform.isAndroid &&
        e.storageUri != null &&
        e.storageUri!.startsWith('content://')) {
      try {
        final ok = await _androidExportChannel
                .invokeMethod<bool>('deleteMusicExport', {'uri': e.storageUri}) ??
            false;
        if (ok == true) removed = true;
      } catch (err) {
        debugPrint('Orpheus Deck: deleteMusicExport $err');
      }
    }
    final ap = e.absolutePath;
    if (ap != null && File(ap).existsSync()) {
      try {
        await _deleteExportIfExists(ap);
        removed = true;
      } catch (_) {}
    }
    if (!mounted) return removed;
    setState(() {
      _exports.removeWhere((x) => _exportEntrySameLogicalTarget(x, e));
    });
    await _saveSession();
    if (mounted) {
      removed
          ? _showSnackbar('EXPORT REMOVED')
          : _showSnackbar('DELETE FAILED OR EXPORT NOT FOUND');
    }
    return removed;
  }

  Future<void> _showExportsBrowseDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ExportsBrowseHost(recorder: this),
    );
  }

  Future<void> _deleteExportIfExists(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('Orpheus Deck: delete export failed: $e');
    }
  }

  Future<int?> _awaitStableExportSize(File file) async {
    const attempts = 10;
    const delay = Duration(milliseconds: 50);
    int? last;
    for (var i = 0; i < attempts; i++) {
      if (!await file.exists()) return null;
      final len = await file.length();
      if (last != null && len == last && len > 48) return len;
      last = len;
      await Future<void>.delayed(delay);
    }
    return await file.exists() ? await file.length() : null;
  }

  bool _wavRiffWaveHeaderLooksValid(File file) {
    RandomAccessFile? raf;
    try {
      if (file.lengthSync() < 12) return false;
      raf = file.openSync(mode: FileMode.read);
      final b = raf.readSync(12);
      if (b.length < 12) return false;
      final riff = String.fromCharCodes(b.sublist(0, 4));
      final wave = String.fromCharCodes(b.sublist(8, 12));
      return riff == 'RIFF' && wave == 'WAVE';
    } catch (e) {
      debugPrint('Orpheus Deck: WAV header check failed: $e');
      return false;
    } finally {
      raf?.closeSync();
    }
  }

  Future<({bool ok, String detail, String? durationSec})> _verifyExportedWav(
      String path) async {
    final file = File(path);
    final size = await _awaitStableExportSize(file);
    debugPrint('Orpheus Deck: export output path: $path');
    debugPrint('Orpheus Deck: export output size (stable): $size bytes');
    if (size == null || size <= 48) {
      return (
        ok: false,
        detail: 'missing_or_tiny_file size=$size',
        durationSec: null,
      );
    }
    if (!_wavRiffWaveHeaderLooksValid(file)) {
      return (ok: false, detail: 'invalid_riff_wave_header', durationSec: null);
    }
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) {
        return (ok: false, detail: 'ffprobe_no_media_information', durationSec: null);
      }
      final durStr = info.getDuration();
      final durSec = double.tryParse(durStr ?? '');
      debugPrint(
          'Orpheus Deck: ffprobe format=${info.getFormat()} duration=$durStr format_size=${info.getSize()}');
      final audioStreams =
          info.getStreams().where((s) => s.getType() == 'audio').toList();
      final a0 = audioStreams.isNotEmpty ? audioStreams.first : null;
      final codec = a0?.getCodec();
      final sampleRate = a0?.getSampleRate();
      debugPrint(
          'Orpheus Deck: ffprobe audio0 codec=$codec sample_rate=$sampleRate');
      final codecOk = codec == 'pcm_s16le';
      final durOk = durSec != null && durSec > 0.004;
      final ok = codecOk && durOk;
      final detail =
          'codec=$codec duration=$durStr codecOk=$codecOk durOk=$durOk';
      return (ok: ok, detail: detail, durationSec: durStr);
    } catch (e, st) {
      debugPrint('Orpheus Deck: ffprobe error: $e\n$st');
      return (ok: false, detail: 'ffprobe: $e', durationSec: null);
    }
  }

  /// Single path segment for exported WAV names; lowercase [a-z0-9._-].
  String _exportFilenameSlug(String projectName) {
    var s = projectName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    s = s.trim().replaceAll(RegExp(r'\s+'), '_');
    s = s.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    s = s.replaceAll(RegExp(r'_+'), '_');
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    s = s.replaceAll(RegExp(r'^_|_$'), '');
    if (s.isEmpty) s = 'session_001';
    if (s.length > 80) {
      s = s.substring(0, 80).replaceAll(RegExp(r'_+$'), '');
    }
    return s.toLowerCase();
  }

  /// Matches examples like 2026-05-09_103045 (date + time with seconds for uniqueness).
  String _exportFileTimestamp() {
    final n = DateTime.now();
    String z2(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${z2(n.month)}-${z2(n.day)}_${z2(n.hour)}${z2(n.minute)}${z2(n.second)}';
  }

  /// FFprobe one export input file (diagnostic only).
  Future<void> _logExportInputFfprobe({
    required int deckTrackIndex,
    required int ffmpegInputIndex,
    required String path,
  }) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) {
        debugPrint(
          'Orpheus Deck: EXPORT INPUT_PROBE deck=$deckTrackIndex '
          'ffmpegInput=$ffmpegInputIndex path=$path -> no media information',
        );
        return;
      }
      final streams = info.getStreams();
      final audioStreams =
          streams.where((s) => s.getType() == 'audio').toList();
      debugPrint(
        'Orpheus Deck: EXPORT INPUT_PROBE deck=$deckTrackIndex '
        'ffmpegInput=$ffmpegInputIndex path=$path '
        'format=${info.getFormat()} duration=${info.getDuration()} '
        'startTime=${info.getStartTime()} size=${info.getSize()} '
        'audioStreamCount=${audioStreams.length}',
      );
      for (int s = 0; s < audioStreams.length; s++) {
        final a = audioStreams[s];
        debugPrint(
          'Orpheus Deck: EXPORT INPUT_PROBE deck=$deckTrackIndex '
          'stream#$s codec=${a.getCodec()} '
          'sampleRate=${a.getSampleRate()} '
          'channelLayout=${a.getChannelLayout()} '
          'bitrate=${a.getBitrate()} timeBase=${a.getTimeBase()}',
        );
      }
    } catch (e, st) {
      debugPrint(
        'Orpheus Deck: EXPORT INPUT_PROBE deck=$deckTrackIndex '
        'ffmpegInput=$ffmpegInputIndex path=$path error=$e\n$st',
      );
    }
  }

  /// Diagnostic: synthetic 440/660/880 Hz tones at tape 0s / 5s / 10s using the
  /// same adelay → amix → optional loudnorm mapping as [_exportMix].
  /// Publishes Music/Orpheus Deck/export_alignment_test.wav
  /// Not shown in PROJECT MGMT (beta UI); method kept for tooling / future gates.
  // ignore: unused_element
  Future<void> _testExportAlignment({bool masterMix = false}) async {
    if (_isRecording || _isPlaying) _stop();
    if (_isExporting) {
      _showSnackbar('ERR: EXPORT ALREADY RUNNING');
      return;
    }

    setState(() => _isExporting = true);

    const String fileName = 'export_alignment_test.wav';
    const List<int> tapeStartsMs = [0, 5000, 10000];
    const List<int> freqsHz = [440, 660, 880];
    const String rawOutPad = '[export_raw]';
    const String masterOutPad = '[export_master]';

    try {
      final tempDir = await getTemporaryDirectory();
      final outPath =
          '${tempDir.path}/orpheus_alignment_test_${DateTime.now().millisecondsSinceEpoch}.wav';

      final List<String> inputs = [];
      for (final hz in freqsHz) {
        inputs.addAll(['-f', 'lavfi', '-i', 'sine=frequency=$hz:duration=2']);
      }

      final List<String> filterParts = [];
      for (int j = 0; j < tapeStartsMs.length; j++) {
        final int delayMs = tapeStartsMs[j];
        if (delayMs > 0) {
          filterParts.add('[$j:a]adelay=$delayMs:all=1,volume=1[a$j]');
        } else {
          filterParts.add('[$j:a]volume=1[a$j]');
        }
      }

      final String mixInputs =
          List<String>.generate(tapeStartsMs.length, (j) => '[a$j]').join();
      String filterGraph =
          '${filterParts.join(';')};${mixInputs}amix=inputs=${tapeStartsMs.length}:duration=longest:normalize=0$rawOutPad';
      String finalMappedPad = rawOutPad;
      if (masterMix) {
        filterGraph += ';${rawOutPad}loudnorm=I=-14:TP=-1:LRA=11$masterOutPad';
        finalMappedPad = masterOutPad;
      }

      final List<String> command = [
        ...inputs,
        '-filter_complex',
        filterGraph,
        '-map',
        finalMappedPad,
        '-vn',
        '-sn',
        '-dn',
        '-map_metadata',
        '-1',
        '-acodec',
        'pcm_s16le',
        '-ar',
        '44100',
        '-ac',
        '1',
        '-f',
        'wav',
        '-y',
        outPath,
      ];

      final String cmdLogged = command
          .map((a) => (a.contains(' ') || a.contains('"'))
              ? '"${a.replaceAll('"', r'\"')}"'
              : a)
          .join(' ');

      debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT start masterMix=$masterMix');
      debugPrint(
        'Orpheus Deck: TEST_EXPORT_ALIGNMENT expected: '
        '440Hz 0-2s, silence 2-5s, 660Hz 5-7s, silence 7-10s, 880Hz 10-12s',
      );
      debugPrint(
        'Orpheus Deck: TEST_EXPORT_ALIGNMENT tapeStartsMs=$tapeStartsMs '
        'finalMappedPad=$finalMappedPad rawInputAudioMapped=false',
      );
      debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT filter_complex: $filterGraph');
      debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT ffmpeg $cmdLogged');

      final session = await FFmpegKit.executeWithArguments(command);
      final returnCode = await session.getReturnCode();
      final rcVal = returnCode?.getValue();
      final logText = await session.getLogsAsString();
      debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT ffmpeg exit=$rcVal');
      if (logText.isNotEmpty) {
        debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT ffmpeg log:\n$logText');
      }

      if (!ReturnCode.isSuccess(returnCode)) {
        await _deleteExportIfExists(outPath);
        if (mounted) {
          _showSnackbar('ERR: ALIGNMENT TEST FAILED (ffmpeg $rcVal)');
        }
        return;
      }

      final ver = await _verifyExportedWav(outPath);
      int outBytes = -1;
      try {
        final f = File(outPath);
        if (f.existsSync()) outBytes = f.lengthSync();
      } catch (_) {}
      debugPrint(
        'Orpheus Deck: TEST_EXPORT_ALIGNMENT result ok=${ver.ok} '
        'detail=${ver.detail} duration=${ver.durationSec ?? "?"} bytes=$outBytes',
      );

      if (!ver.ok) {
        await _deleteExportIfExists(outPath);
        if (mounted) _showSnackbar('ERR: ALIGNMENT TEST VERIFY FAILED');
        return;
      }

      final entry = await _finalizeExportAfterFfmpeg(
        tempPath: outPath,
        fileName: fileName,
        kind: 'TEST_EXPORT_ALIGNMENT',
      );
      if (entry == null) {
        if (mounted) {
          _showSnackbar(Platform.isAndroid
              ? 'ERR: ALIGNMENT TEST SAVE FAILED'
              : 'ERR: ALIGNMENT TEST SAVE FAILED');
        }
        return;
      }

      debugPrint(
        'Orpheus Deck: TEST_EXPORT_ALIGNMENT saved '
        'displayPath=${entry.displayPath} uri=${entry.storageUri ?? entry.absolutePath}',
      );
      if (mounted) {
        _showSnackbar(
          'ALIGNMENT TEST SAVED\n${entry.displayPath}\n'
          'dur=${ver.durationSec ?? "?"}s — check logcat',
        );
      }
    } catch (e, st) {
      debugPrint('Orpheus Deck: TEST_EXPORT_ALIGNMENT error $e\n$st');
      if (mounted) _showSnackbar('ERR: ALIGNMENT TEST FAILED');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportMix(bool isMasterMix) async {
    if (_isRecording || _isPlaying) _stop();

    setState(() {
      _isExporting = true;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      debugPrint('Orpheus Deck: FFmpeg temp write dir: ${tempDir.path}');

      final slug = _exportFilenameSlug(_projectName);
      final mixSeg = isMasterMix ? 'mastermix' : 'raw_mix';
      final stamp = _exportFileTimestamp();
      final outName = '${slug}_${mixSeg}_$stamp.wav';
      final tempId = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${tempDir.path}/orpheus_exp_$tempId.wav';

      final List<String> inputs = [];
      final List<String> filterParts = [];
      final List<int> trackDelayMs = [];
      final List<int> trackIdxs = [];
      final List<double> targetVolList = [];
      int activeCount = 0;
      int expectedDurationMs = 0;

      final bool anySolo = _trackSolos.contains(true);
      final Set<String> seenInputPaths = {};

      debugPrint(
        'Orpheus Deck: EXPORT_REAL_PROJECT project=$_projectName '
        'isMaster=$isMasterMix playbackMs=$_playbackMs '
        'trackTapeStartMs=$_trackTapeStartMs',
      );

      for (int i = 0; i < 4; i++) {
        final String? path = _trackFiles[i];
        final bool exists = path != null && File(path).existsSync();
        final int tapeStart = _trackTapeStartMs[i];
        final int clipDur = _trackContentDurationMs(i);
        final int tapeEnd = tapeStart + clipDur;

        double targetVol = 0.0;
        String skipReason = '';
        if (!exists) {
          skipReason = 'NO_FILE';
        } else if (anySolo) {
          if (_trackSolos[i] && !_trackMutes[i]) {
            targetVol = _trackVolumes[i];
          }
          if (targetVol <= 0.01) {
            skipReason = _trackSolos[i] ? 'MUTED_OR_ZERO_VOL' : 'NOT_SOLOED';
          }
        } else {
          if (!_trackMutes[i]) targetVol = _trackVolumes[i];
          if (targetVol <= 0.01) skipReason = 'MUTED_OR_ZERO_VOL';
        }

        final bool included = exists && targetVol > 0.01;

        debugPrint(
          'Orpheus Deck: EXPORT TRK $i '
          'path=${path ?? "<none>"} '
          'tapeStartMs=$tapeStart clipDurMs=$clipDur tapeEndMs=$tapeEnd '
          'solo=${_trackSolos[i]} mute=${_trackMutes[i]} '
          'vol=${_trackVolumes[i]} anySolo=$anySolo '
          'included=$included${included ? '' : ' skipReason=$skipReason'}',
        );

        if (!included) continue;

        final bool duplicatePath = seenInputPaths.contains(path);
        seenInputPaths.add(path);
        if (duplicatePath) {
          debugPrint(
            'Orpheus Deck: EXPORT WARN deck=$i DUPLICATE_INPUT_PATH $path',
          );
        }

        inputs.add("-i");
        inputs.add(path);
        final int adelay = _exportAdelayMsFromTapeStart(tapeStart);
        trackDelayMs.add(adelay);
        trackIdxs.add(i);
        targetVolList.add(targetVol);
        final int shiftedEnd = adelay + clipDur;
        if (tapeEnd > expectedDurationMs) expectedDurationMs = tapeEnd;
        if (shiftedEnd > expectedDurationMs) expectedDurationMs = shiftedEnd;
        activeCount++;
      }

      for (int j = 0; j < activeCount; j++) {
        await _logExportInputFfprobe(
          deckTrackIndex: trackIdxs[j],
          ffmpegInputIndex: j,
          path: inputs[(j * 2) + 1],
        );
      }

      debugPrint(
        'Orpheus Deck: EXPORT_REAL inputOrder '
        'deckTracks=$trackIdxs ffmpegDelaysMs=$trackDelayMs '
        'tempOut=$outPath',
      );

      if (activeCount == 0) {
        _showSnackbar("ERR: NO AUDIBLE TRACKS");
        setState(() => _isExporting = false);
        return;
      }

      // Per-track stage: apply tape-position delay (silence prefix) then per-
      // track volume. adelay pads silence at the START of the stream so each
      // recording lands at its trackTapeStartMs in the final mix.
      for (int j = 0; j < activeCount; j++) {
        final int delayMs = trackDelayMs[j];
        final double vol = targetVolList[j];
        if (delayMs > 0) {
          filterParts.add('[$j:a]adelay=$delayMs:all=1,volume=$vol[a$j]');
        } else {
          filterParts.add('[$j:a]volume=$vol[a$j]');
        }
      }

      String filterGraph = filterParts.join(";");
      const String rawOutPad = "[export_raw]";
      const String masterOutPad = "[export_master]";
      String finalMappedPad = rawOutPad;

      if (activeCount > 1) {
        // amix with normalize=0 sums inputs straight (no 1/N scaling and no
        // dropout-transition gain bumps when one delayed track ends earlier
        // than another). duration=longest guarantees the output runs until
        // the last audible track's tape end.
        final String mixInputs = List<String>.generate(
          activeCount,
          (j) => "[a$j]",
        ).join();
        filterGraph +=
            ';${mixInputs}amix=inputs=$activeCount:duration=longest:normalize=0$rawOutPad';
      } else {
        // Even one-track exports go through a named final pad so FFmpeg never
        // has a chance to fall back to an unfiltered input stream.
        filterGraph += ';[a0]anull$rawOutPad';
      }

      if (isMasterMix) {
        filterGraph += ";${rawOutPad}loudnorm=I=-14:TP=-1:LRA=11$masterOutPad";
        finalMappedPad = masterOutPad;
      }

      final List<String> command = [
        ...inputs,
        "-filter_complex",
        filterGraph,
        "-map",
        finalMappedPad,
        "-vn",
        "-sn",
        "-dn",
        "-map_metadata",
        "-1",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "44100",
        "-ac",
        "1",
        "-f",
        "wav",
        "-y",
        outPath,
      ];

      final String cmdLogged = command
          .map((a) => (a.contains(' ') || a.contains('"'))
              ? '"${a.replaceAll('"', r'\"')}"'
              : a)
          .join(' ');
      debugPrint(
        'Orpheus Deck: EXPORT_SUMMARY isMaster=$isMasterMix '
        'activeCount=$activeCount activeTracks=$trackIdxs '
        'delaysMs=$trackDelayMs manualMs=${OrpheusSettings.instance.manualLatencyAdjustMs} '
        'vols=$targetVolList '
        'expectedDurationMs=$expectedDurationMs tapeLengthMs=$tapeLengthMs',
      );
      debugPrint(
        'Orpheus Deck: EXPORT final mapped pad: $finalMappedPad '
        'rawInputAudioMapped=false explicitFilterOutputOnly=true',
      );
      debugPrint('Orpheus Deck: EXPORT filter chain: $filterGraph');
      debugPrint('Orpheus Deck: FFmpeg full command: ffmpeg $cmdLogged');

      FFmpegKit.executeWithArgumentsAsync(command, (session) async {
        try {
          final returnCode = await session.getReturnCode();
          final rcVal = returnCode?.getValue();
          final logText = await session.getLogsAsString();
          debugPrint('Orpheus Deck: FFmpeg exit code: $rcVal');
          if (logText.isNotEmpty) {
            debugPrint('Orpheus Deck: FFmpeg output:\n$logText');
          }

          if (ReturnCode.isCancel(returnCode)) {
            await _deleteExportIfExists(outPath);
            if (mounted) _showSnackbar("EXPORT CANCELED");
            return;
          }
          if (!ReturnCode.isSuccess(returnCode)) {
            await _deleteExportIfExists(outPath);
            if (mounted) {
              _showSnackbar("ERR: EXPORT FAILED (ffmpeg $rcVal)");
            }
            return;
          }

          final ver = await _verifyExportedWav(outPath);
          int outBytes = -1;
          try {
            final outFile = File(outPath);
            if (outFile.existsSync()) outBytes = outFile.lengthSync();
          } catch (_) {}
          debugPrint(
              'Orpheus Deck: EXPORT result ok=${ver.ok} detail=${ver.detail} '
              'duration=${ver.durationSec ?? "?"} bytes=$outBytes '
              'expectedDurationMs=$expectedDurationMs');

          if (!ver.ok) {
            await _deleteExportIfExists(outPath);
            if (mounted) _showSnackbar("ERR: EXPORT VERIFY FAILED");
            return;
          }

          if (!mounted) return;
          final kind = isMasterMix ? 'MASTERMIX' : 'RAW MIX';
          final entry = await _finalizeExportAfterFfmpeg(
            tempPath: outPath,
            fileName: outName,
            kind: kind,
          );
          debugPrint(
            'Orpheus Deck: EXPORT_PUBLISH temp=$outPath fileName=$outName '
            'saved=${entry?.displayPath} uri=${entry?.storageUri ?? entry?.absolutePath}',
          );
          if (entry == null) {
            if (mounted) {
              _showSnackbar(Platform.isAndroid
                  ? 'ERR: SAVE TO MUSIC FAILED (ANDROID 10+)'
                  : 'ERR: EXPORT SAVE FAILED');
            }
            return;
          }

          setState(() {
            _exports.add(entry);
          });
          await _saveSession();
          if (!mounted) return;
          _showExportSuccessDialog(
            entry: entry,
            durationSec: ver.durationSec,
          );
        } catch (e, st) {
          debugPrint('Orpheus Deck: export callback error: $e\n$st');
          await _deleteExportIfExists(outPath);
          if (mounted) _showSnackbar("ERR: EXPORT FAILED");
        } finally {
          if (mounted) {
            setState(() {
              _isExporting = false;
              _exportSessionId = null;
            });
          }
        }
      }).then((session) {
        _exportSessionId = session.getSessionId();
      });
    } catch (e) {
      debugPrint('Orpheus Deck: export setup error: $e');
      _showSnackbar("ERR: EXPORT FAILED");
      setState(() {
        _isExporting = false;
      });
    }
  }

  void _showExportSuccessDialog({
    required ExportEntry entry,
    String? durationSec,
  }) {
    if (entry.storageUri != null) {
      debugPrint('Orpheus Deck: export storageUri=${entry.storageUri}');
    }
    showDialog(
        context: context,
        builder: (context) {
          final String body =
              'Saved:\n${entry.displayPath}\n\nKind: ${entry.kind}\nDuration (ffprobe): ${durationSec ?? '?'}\n';
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text("EXPORT COMPLETE",
                style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  body,
                  style: const TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10),
                ),
                const SizedBox(height: 12),
                const Text(
                  'EXPORT USES CURRENT MIXER STATE',
                  style: TextStyle(
                    color: Colors.white38,
                    fontFamily: 'monospace',
                    fontSize: 9,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  if (!_exportShareLooksValid(entry)) {
                    _showSnackbar("ERR: EXPORT FILE INVALID");
                    return;
                  }
                  await _shareExportEntry(entry);
                },
                child: const Text("SHARE",
                    style: TextStyle(
                        color: Colors.white, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () async {
                  await _tryOpenExportLocation(entry);
                },
                child: const Text("OPEN EXPORT LOCATION",
                    style: TextStyle(
                        color: Colors.white70, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("OK",
                    style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
  }

  bool _quickExportLooksValidSync(File file) {
    try {
      if (!file.existsSync()) return false;
      if (file.lengthSync() <= 48) return false;
      return _wavRiffWaveHeaderLooksValid(file);
    } catch (_) {
      return false;
    }
  }

  bool _exportShareLooksValid(ExportEntry e) {
    if (e.storageUri != null && e.storageUri!.startsWith('content://')) {
      return true;
    }
    if (e.absolutePath != null) {
      return _quickExportLooksValidSync(File(e.absolutePath!));
    }
    return false;
  }

  Future<void> _rebuildClickWavFromDialog() async {
    _clickPlayerSourcePath = null;
    if (!_metronomeOn) return;
    await _ensureClickTrackFile(showBuildingUi: true);
  }

  void _showClickTrackSettings() {
    showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: Border.all(color: Colors.white, width: 2),
              title: const Text("CLICK TRACK",
                  style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CLICK PLAYS A GUIDE RHYTHM WHILE YOU RECORD. IT IS NOT INCLUDED IN EXPORTS.',
                      style: TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.4,
                          letterSpacing: 0.3),
                    ),
                    const SizedBox(height: 18),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("CLICK",
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontFamily: 'monospace')),
                          GestureDetector(
                              onTap: () async {
                                final next = !_metronomeOn;
                                if (next) {
                                  setState(() => _metronomeOn = true);
                                  setDialogState(() {});
                                  debugPrint(
                                      'Orpheus Deck: CLICK TRACK ENABLED '
                                      'bpm=$_bpm recording=$_isRecording playing=$_isPlaying');
                                  _saveSession();
                                  _clickPlayerSourcePath = null;
                                  await _ensureClickTrackFile(
                                      showBuildingUi: true);
                                } else {
                                  setState(() => _metronomeOn = false);
                                  setDialogState(() {});
                                  await _stopClickPlayback();
                                  debugPrint(
                                      'Orpheus Deck: CLICK TRACK DISABLED '
                                      'recording=$_isRecording playing=$_isPlaying');
                                  _saveSession();
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _metronomeOn
                                      ? Colors.white
                                      : Colors.black,
                                  border: Border.all(color: Colors.white),
                                ),
                                child: Text(_metronomeOn ? "ON" : "OFF",
                                    style: TextStyle(
                                        color: _metronomeOn
                                            ? Colors.black
                                            : Colors.white,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.bold)),
                              ))
                        ]),
                    const SizedBox(height: 16),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("BPM",
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontFamily: 'monospace')),
                          Row(children: [
                            IconButton(
                                icon: const Icon(Icons.remove,
                                    color: Colors.white),
                                onPressed: () async {
                                  if (_bpm > 40) {
                                    setState(() => _bpm--);
                                    setDialogState(() {});
                                    debugPrint(
                                        'Orpheus Deck: CLICK TRACK BPM $_bpm '
                                        'recording=$_isRecording playing=$_isPlaying');
                                    _saveSession();
                                    await _rebuildClickWavFromDialog();
                                  }
                                }),
                            Text("$_bpm",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'monospace',
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                icon: const Icon(Icons.add, color: Colors.white),
                                onPressed: () async {
                                  if (_bpm < 240) {
                                    setState(() => _bpm++);
                                    setDialogState(() {});
                                    debugPrint(
                                        'Orpheus Deck: CLICK TRACK BPM $_bpm '
                                        'recording=$_isRecording playing=$_isPlaying');
                                    _saveSession();
                                    await _rebuildClickWavFromDialog();
                                  }
                                }),
                          ])
                        ]),
                    const SizedBox(height: 16),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("SOUND",
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontFamily: 'monospace')),
                          DropdownButton<String>(
                            value: _metronomeSound,
                            dropdownColor: Colors.black,
                            style: const TextStyle(
                                color: Colors.white,
                                fontFamily: 'monospace'),
                            underline:
                                Container(height: 1, color: Colors.white54),
                            items: const [
                              DropdownMenuItem(
                                value: 'CLICK',
                                child: Text('Click'),
                              ),
                              DropdownMenuItem(
                                value: 'BEEP',
                                child: Text('Beep'),
                              ),
                              DropdownMenuItem(
                                value: 'WOOD',
                                child: Text('Wood Block'),
                              ),
                            ],
                            onChanged: (val) async {
                              if (val != null) {
                                setState(() => _metronomeSound = val);
                                setDialogState(() {});
                                debugPrint(
                                    'Orpheus Deck: CLICK TRACK sound=$val bpm=$_bpm');
                                _saveSession();
                                await _rebuildClickWavFromDialog();
                              }
                            },
                          )
                        ])
                  ]),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("CLOSE",
                      style: TextStyle(
                          color: Colors.white54, fontFamily: 'monospace')),
                ),
              ],
            );
          });
        });
  }

  void _showProjectMenu() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text("PROJECT MGMT",
                style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _menuButton("RENAME PROJECT", () {
                    Navigator.pop(context);
                    _showNameDialog(
                        "RENAME PROJECT", _projectName, _renameProject);
                  }),
                  const SizedBox(height: 8),
                  _menuButton("NEW PROJECT", () {
                    Navigator.pop(context);
                    _showNameDialog("NEW PROJECT", "SESSION_NEW", _newProject);
                  }),
                  const SizedBox(height: 16),
                  Container(height: 1, color: Colors.white24),
                  const SizedBox(height: 16),
                  _menuButton("EXPORT RAW MIX", () {
                    Navigator.pop(context);
                    _exportMix(false);
                  }),
                  const SizedBox(height: 8),
                  _menuButton("EXPORT MASTERMIX", () {
                    Navigator.pop(context);
                    _exportMix(true);
                  }),
                  const SizedBox(height: 16),
                  Container(height: 1, color: Colors.white24),
                  const SizedBox(height: 16),
                  _menuButton("EXPORTS", () async {
                    Navigator.pop(context);
                    await _showExportsBrowseDialog();
                  }),
                  if (kDebugMode &&
                      isNativeTestAudioEngine(_projectAudioEngine)) ...[
                    const SizedBox(height: 16),
                    Container(height: 1, color: Colors.white24),
                    const SizedBox(height: 16),
                    _menuButton("GENERATE NATIVE TEST TRACKS", () {
                      Navigator.pop(context);
                      unawaited(_generateNativeTestTracks());
                    }),
                  ],
                  const SizedBox(height: 24),
                  _menuButton("EXIT TO MENU", () {
                    _stop();
                    Navigator.pop(context);
                    Navigator.pushReplacementNamed(context, '/home');
                  }),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CLOSE",
                    style: TextStyle(
                        color: Colors.white54, fontFamily: 'monospace')),
              ),
            ],
          );
        });
  }

  Widget _menuButton(String text, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white54, width: 1),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showNameDialog(
      String title, String initialText, Function(String) onSubmit) {
    TextEditingController ctrl = TextEditingController(text: initialText);
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: Text(title,
                style: const TextStyle(
                    color: Colors.white, fontFamily: 'monospace')),
            content: TextField(
              controller: ctrl,
              style:
                  const TextStyle(color: Colors.white, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CANCEL",
                    style: TextStyle(
                        color: Colors.white54, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  onSubmit(ctrl.text);
                },
                child: const Text("SAVE",
                    style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
  }

  void _showSnackbar(String message) {
    showOrpheusOledToast(context, message);
  }

  void _saveMixerUndo() {
    _lastUndo.clear();
    _lastUndo.action = UndoAction.mixer;
    _lastUndo.volumes = List.from(_trackVolumes);
    _lastUndo.mutes = List.from(_trackMutes);
    _lastUndo.solos = List.from(_trackSolos);
    setState(() {});
  }

  void _onVolumeChangeStart(int index, double value) {
    _saveMixerUndo();
  }

  void _updateMixerState() {
    if (_nativePlaybackActive) {
      _nativeOboeEngine?.applyMixerState(
        volumes: _trackVolumes,
        mutes: _trackMutes,
        solos: _trackSolos,
      );
    }
    bool anySolo = _trackSolos.contains(true);
    for (int i = 0; i < 4; i++) {
      double targetVolume = 0.0;
      if (anySolo) {
        if (_trackSolos[i] && !_trackMutes[i]) {
          targetVolume = _trackVolumes[i];
        }
      } else {
        if (!_trackMutes[i]) {
          targetVolume = _trackVolumes[i];
        }
      }
      // Only update volume if the player is actually active.
      _trackPlayers[i].setVolume(targetVolume);
    }
  }

  bool _isTrackAudible(int i) {
    bool anySolo = _trackSolos.contains(true);
    if (anySolo) {
      return _trackSolos[i] && !_trackMutes[i];
    }
    return !_trackMutes[i];
  }

  void _setVolume(int index, double value) {
    setState(() {
      _trackVolumes[index] = value;
    });
    _updateMixerState();
    _saveSession();
  }

  void _toggleMute(int index) {
    _saveMixerUndo();
    setState(() {
      _trackMutes[index] = !_trackMutes[index];
    });
    _updateMixerState();
    _saveSession();
  }

  void _toggleSolo(int index) {
    _saveMixerUndo();
    setState(() {
      _trackSolos[index] = !_trackSolos[index];
    });
    _updateMixerState();
    _saveSession();
  }

  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 50), (Timer t) {
      if (_nativePlaybackActive && _isPlaying) {
        _pollNativePlaybackTransport(t);
        return;
      }
      if (_isPlaying) {
        final int maxMs = _tapeTransportMaxMs();
        final int nextMs = _playbackMs + 50;
        if (nextMs >= maxMs) {
          setState(() {
            _applyTapeHeadClamped(maxMs);
          });
          scheduleMicrotask(() async {
            await _stop(transportStopReason: 'TAPE_END');
          });
        } else {
          setState(() {
            _applyTapeHeadClamped(nextMs);
          });
          // Both PLAY and RECORD/overdub schedule pending tracks; the ticker
          // promotes them as the tape head reaches each track's tapeStart.
          if (_pendingPlaybackIndices.isNotEmpty) {
            _maybeStartPendingTracks();
          }
        }
      }
      if (t.tick % 20 == 0 && _isPlaying && _metronomeOn) {
        unawaited(_resyncClickPlayerToTransport());
      }
    });
  }

  /// Promote any pending tracks whose tape-start position has been reached.
  /// Fires play() fire-and-forget and attaches a completion listener so the
  /// auto-stop counter still observes their end. Shared between PLAY and
  /// RECORD/overdub monitoring; the log prefix and listener behavior depend
  /// on which transport is active.
  void _maybeStartPendingTracks() {
    if (_pendingPlaybackIndices.isEmpty) return;
    final List<int> toStart = [];
    for (final i in _pendingPlaybackIndices) {
      if (_playbackMs >= _trackTapeStartMs[i]) {
        toStart.add(i);
      }
    }
    if (toStart.isEmpty) return;
    final String modeTag = _isRecording ? 'REC BACKING' : 'PLAY TRK';
    for (final i in toStart) {
      _pendingPlaybackIndices.remove(i);
      final int tapeStart = _trackTapeStartMs[i];
      final int clipDur = _trackContentDurationMs(i);
      final int seekMs =
          _playbackSeekMsForTrack(i, _playbackMs, tapeStart, clipDur);
      try {
        _trackPlayers[i].seek(Duration(milliseconds: seekMs));
        _trackPlayers[i].play();
      } catch (e) {
        debugPrint('Orpheus Deck: $modeTag $i DELAYED_START play() err $e');
      }
      _attachCompletionListenerFor(i);
      debugPrint(
        'Orpheus Deck: $modeTag $i DELAYED_START '
        'tapeStart=$tapeStart seekMs=$seekMs offsetMs=${_trackOffsets[i]} '
        'latencyComp=${OrpheusSettings.instance.latencyCompensationEnabled} '
        'playbackMs=$_playbackMs',
      );
    }
  }

  bool get _isOverdubbing {
    if (!_isRecording) return false;
    return _trackFiles.any((file) => file != null);
  }

  String get _deckStatus {
    if (_isExporting) return "EXPORTING";
    if (_isRecording) {
      return _isOverdubbing ? "OVERDUB" : "RECORDING";
    } else if (_isPlaying) {
      return "PLAYBACK";
    }
    return "IDLE";
  }

  bool _projectHasLegacyM4aTracks() {
    for (final path in _trackFiles) {
      if (path != null && path.toLowerCase().endsWith('.m4a')) {
        return true;
      }
    }
    return false;
  }

  RecorderEngineSelection _recorderEngineSelection() {
    return selectRecorderEngine(
      experimentalNativeAudioEngineEnabled:
          OrpheusSettings.instance.experimentalNativeAudioEngineEnabled,
      isDebugBuild: kDebugMode,
      projectAudioEngine: _projectAudioEngine,
      projectHasLegacyM4aTracks: _projectHasLegacyM4aTracks(),
      platformIsAndroid: Platform.isAndroid,
    );
  }

  String _recorderEngineDebugLine() =>
      formatRecorderEngineDebugLine(_recorderEngineSelection());

  String _projectEngineDebugLine() =>
      formatProjectEngineDebugLine(_projectAudioEngine);

  List<double> _getAmplitudesForTrack(int index) {
    if (_isRecording && _armedTracks[index]) {
      return _liveAmplitudes;
    }
    if (_trackFiles[index] != null &&
        _waveformCache.containsKey(_trackFiles[index])) {
      return _waveformCache[_trackFiles[index]!]!;
    }
    return [];
  }

  bool _shouldAttemptNativePlayback() {
    if (!kDebugMode || !Platform.isAndroid) return false;
    final sel = _recorderEngineSelection();
    if (sel.selectedKind != OrpheusAudioEngineKind.nativeExperimental) {
      return false;
    }
    if (!isNativeTestAudioEngine(_projectAudioEngine)) return false;
    if (!projectNonNullTracksAreWav(_trackFiles)) return false;
    return projectHasAtLeastOneWavTrack(_trackFiles);
  }

  Future<void> _stopNativePlaybackOnly() async {
    if (_nativeOboeEngine != null) {
      await _nativeOboeEngine!.stop();
    }
    _nativePlaybackActive = false;
  }

  void _pollNativePlaybackTransport(Timer t) {
    final engine = _nativeOboeEngine;
    if (engine == null || !engine.sessionOpen) {
      return;
    }
    final int sample = engine.currentTransportSample;
    final int ms = orpheusNativeSamplesToMs(sample);
    final int maxMs = _tapeTransportMaxMs();
    final int clampedMs = ms.clamp(0, maxMs);
    if (engine.isPlaybackComplete || clampedMs >= maxMs) {
      setState(() => _applyTapeHeadClamped(clampedMs));
      scheduleMicrotask(() async {
        await _stop(
          transportStopReason: engine.isPlaybackComplete
              ? 'NATIVE_PLAYBACK_COMPLETE'
              : 'TAPE_END',
        );
      });
      return;
    }
    setState(() => _applyTapeHeadClamped(clampedMs));
  }

  Future<bool> _tryStartNativePlayback() async {
    final int startMs = _playbackMs.clamp(0, tapeLengthMs);
    final int startSample = orpheusMsToNativeSamples(startMs);
    try {
      for (final p in _trackPlayers) {
        await p.stop();
      }
      _nativeOboeEngine ??= NativeOboeRecorderEngine();
      await _nativeOboeEngine!.preparePlayback(
        trackPaths: _trackFiles,
        trackTapeStartMs: _trackTapeStartMs,
        recordLatencyOffsetMs: _trackOffsets,
        tapeLengthMs: tapeLengthMs,
        volumes: _trackVolumes,
        mutes: _trackMutes,
        solos: _trackSolos,
      );
      await _nativeOboeEngine!.startPlayback(startSample: startSample);
      if (!mounted) return false;
      setState(() {
        _isPlaying = true;
        _nativePlaybackActive = true;
        _applyTapeHeadClamped(startMs);
      });
      _showSnackbar('NATIVE PLAYBACK');
      _startTicker();
      debugPrint(
        'Orpheus N3E-G: PLAY_NATIVE startMs=$startMs startSample=$startSample',
      );
      return true;
    } catch (e, st) {
      debugPrint('Orpheus N3E-G: native playback failed: $e\n$st');
      await _stopNativePlaybackOnly();
      if (mounted) {
        _showSnackbar('NATIVE PLAYBACK FAILED - USING LEGACY');
      }
      return false;
    }
  }

  Future<void> _play() async {
    if (_isRecording || _isExporting) return;
    if (_isPlaying) return;

    if (_shouldAttemptNativePlayback()) {
      final bool nativeOk = await _tryStartNativePlayback();
      if (nativeOk) return;
    }

    final int startMs = _playbackMs.clamp(0, tapeLengthMs);

    setState(() {
      _isPlaying = true;
      _applyTapeHeadClamped(startMs);
    });

    // Stop all just_audio track players; per-track seek happens after the
    // source loads, using the new trackTapeStartMs model.
    for (var p in _trackPlayers) {
      await p.stop();
    }

    _pendingPlaybackIndices.clear();
    _resetCompletionTracking();

    debugPrint(
      'Orpheus Deck: PLAY_START tape head playbackMs=$startMs '
      'tapeLengthMs=$tapeLengthMs',
    );

    final List<int> immediate = [];
    final List<int> pending = [];

    for (int i = 0; i < 4; i++) {
      if (_trackFiles[i] == null) continue;
      final file = File(_trackFiles[i]!);
      final bool exists = file.existsSync();
      final int size = exists ? file.lengthSync() : 0;
      final bool audible = _isTrackAudible(i);
      final double vol = audible ? _trackVolumes[i] : 0.0;
      final int tapeStart = _trackTapeStartMs[i];
      final int clipDur = _trackContentDurationMs(i);
      final int tapeEnd = tapeStart + clipDur;
      final bool past = clipDur > 0 && startMs >= tapeEnd;
      final bool delayed = startMs < tapeStart;
      final bool shouldPlayNow = !past && !delayed;

      debugPrint(
        "Orpheus Deck: PLAY TRK $i | path: ${_trackFiles[i]} | "
        "exists=$exists size=$size | "
        "tapeStart=$tapeStart clipDurMs=$clipDur tapeEnd=$tapeEnd | "
        "shouldPlayNow=$shouldPlayNow past=$past delayed=$delayed | "
        "mute=${_trackMutes[i]} solo=${_trackSolos[i]} vol=$vol audible=$audible",
      );

      if (!exists || size == 0) {
        debugPrint("Orpheus Deck: PLAY TRK $i SKIP - missing/empty");
        continue;
      }
      if (!audible) {
        debugPrint(
            "Orpheus Deck: PLAY TRK $i SKIP - not audible (muted/solo)");
        continue;
      }
      if (past) {
        debugPrint(
          'Orpheus Deck: PLAY TRK $i SKIP - past tapeEnd '
          '(tapeEnd=$tapeEnd startMs=$startMs)',
        );
        continue;
      }

      try {
        await _trackPlayers[i].setFilePath(_trackFiles[i]!);
        await _trackPlayers[i].setVolume(vol);
        debugPrint(
            "Orpheus Deck: PLAY TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
      } catch (e) {
        debugPrint("Orpheus Deck: PLAY TRK $i setFilePath ERROR - $e");
        continue;
      }

      if (shouldPlayNow) {
        final int seekMs =
            _playbackSeekMsForTrack(i, startMs, tapeStart, clipDur);
        try {
          await _trackPlayers[i].seek(Duration(milliseconds: seekMs));
        } catch (e) {
          debugPrint('Orpheus Deck: PLAY seek TRK $i err $e');
        }
        immediate.add(i);
        debugPrint(
          'Orpheus Deck: PLAY TRK $i SCHEDULED=IMMEDIATE seekMs=$seekMs '
          'offsetMs=${_trackOffsets[i]} latencyComp='
          '${OrpheusSettings.instance.latencyCompensationEnabled} '
          'tapeStart=$tapeStart tapeEnd=$tapeEnd',
        );
      } else {
        try {
          await _trackPlayers[i].seek(Duration.zero);
        } catch (e) {
          debugPrint('Orpheus Deck: PLAY seek TRK $i err $e');
        }
        _pendingPlaybackIndices.add(i);
        pending.add(i);
        debugPrint(
          'Orpheus Deck: PLAY TRK $i SCHEDULED=PENDING '
          'tapeStart=$tapeStart tapeEnd=$tapeEnd',
        );
      }
    }

    _scheduledPlaybackCount = immediate.length + pending.length;
    _completedPlaybackCount = 0;

    // Fire play() on immediate players — fire-and-forget so [_startTicker]
    // can run. In just_audio, play() returns a Future that only completes
    // when playback ends; awaiting it would freeze the transport clock.
    debugPrint(
      'Orpheus Deck: Starting ${immediate.length} immediate just_audio players: '
      '$immediate (pending=$pending)',
    );
    for (final int i in immediate) {
      try {
        _trackPlayers[i].play();
      } catch (e) {
        debugPrint("Orpheus Deck: play() ERROR TRK $i - $e");
      }
      _attachCompletionListenerFor(i);
    }

    await _tryStartClickPlayback(contextTag: 'play');

    _startTicker();
    debugPrint(
      'Orpheus Deck: PLAY_TRANSPORT_START '
      'tapeLengthMs=$tapeLengthMs playbackMs=$_playbackMs '
      'contentMaxMs=${_getMaxPlaybackDuration()} '
      'immediate=${immediate.length} pending=${pending.length}',
    );
  }

  /// Resets the per-PLAY completion counters and clears any prior listeners.
  /// Must run before [_attachCompletionListenerFor] is called for a new
  /// playback session, otherwise stale counters can fire auto-stop early.
  void _resetCompletionTracking() {
    for (int i = 0; i < 4; i++) {
      _playerCompletionSubs[i]?.cancel();
      _playerCompletionSubs[i] = null;
    }
    _scheduledPlaybackCount = 0;
    _completedPlaybackCount = 0;
  }

  /// Subscribes to one player's processingStateStream.
  ///
  /// During PLAY: when the scheduled player count (immediate + delayed-
  /// promoted) has all completed, _stop() fires so the UI never stays stuck
  /// in PLAY mode after natural end.
  ///
  /// During RECORD/overdub: a backing track finishing must NOT stop the
  /// recorder — the user controls when recording ends. The listener just
  /// logs and exits early so the recorder keeps going until STOP/tape end.
  void _attachCompletionListenerFor(int i) {
    _playerCompletionSubs[i]?.cancel();
    _playerCompletionSubs[i] =
        _trackPlayers[i].processingStateStream.listen((state) {
      if (state != ja.ProcessingState.completed) return;
      if (_isRecording) {
        debugPrint(
          'Orpheus Deck: REC BACKING TRK $i completed '
          '(recorder continues) playbackMs=$_playbackMs',
        );
        return;
      }
      debugPrint('Orpheus Deck: TRK $i reached ProcessingState.completed');
      _completedPlaybackCount++;
      if (_scheduledPlaybackCount > 0 &&
          _completedPlaybackCount >= _scheduledPlaybackCount &&
          _pendingPlaybackIndices.isEmpty &&
          _isPlaying &&
          !_isRecording) {
        debugPrint(
            'Orpheus Deck: All $_scheduledPlaybackCount scheduled players completed — auto-stopping');
        _stop(transportStopReason: 'ALL_PLAYERS_COMPLETE');
      }
    });
  }

  /// Debug helper: bypass solo/mute and play every non-empty track at full volume.
  /// Not exposed in the UI — accessible via code for diagnostics only.
  // ignore: unused_element
  Future<void> _debugTestPlayAll() async {
    debugPrint("Orpheus Deck: TEST PLAY ALL TRACKS");
    for (var p in _trackPlayers) {
      await p.stop();
      await p.seek(Duration.zero);
    }
    final List<int> readyIndices = [];
    for (int i = 0; i < 4; i++) {
      if (_trackFiles[i] == null) continue;
      final file = File(_trackFiles[i]!);
      if (!file.existsSync()) continue;
      debugPrint(
          "Orpheus Deck: TEST TRK $i | ${_trackFiles[i]} | ${file.lengthSync()} bytes | player: ${_trackPlayers[i].hashCode}");
      try {
        await _trackPlayers[i].setFilePath(_trackFiles[i]!);
        await _trackPlayers[i].setVolume(1.0);
        debugPrint(
            "Orpheus Deck: TEST TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
        readyIndices.add(i);
      } catch (e) {
        debugPrint("Orpheus Deck: TEST TRK $i ERROR - $e");
      }
    }
    debugPrint(
        "Orpheus Deck: TEST firing play() on ${readyIndices.length} players: $readyIndices");
    await Future.wait(readyIndices.map((i) => _trackPlayers[i].play()));
    debugPrint("Orpheus Deck: TEST PLAY complete");
  }

  void _showRecordingCheckReminder() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: const Text(
            'RECORDING CHECK',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'USE HEADPHONES FOR CLEAN RECORDING.\n'
                  'SILENCE PHONE NOTIFICATIONS.\n'
                  'SET LATENCY IN SETTINGS IF OVERDUBS FEEL LATE.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      showOrpheusDeckSettingsDialog(
                        context,
                        isTransportBusy: () =>
                            _isRecording || _isPlaying || _isExporting,
                      );
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                    ),
                    child: const Text(
                      'OPEN SETTINGS',
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final nav = Navigator.of(dialogContext);
                await OrpheusSettings.instance
                    .setRecordingCheckReminderEnabled(false);
                if (!mounted) return;
                nav.pop();
                _record(skipRecordingCheckReminder: true);
              },
              child: const Text(
                'DO NOT SHOW AGAIN',
                style: TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _record(skipRecordingCheckReminder: true);
              },
              child: const Text(
                'OK',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _record({bool skipRecordingCheckReminder = false}) async {
    if (_isRecording || _isExporting) return;

    if (_recorderEngineSelection().selectedKind ==
        OrpheusAudioEngineKind.nativeExperimental) {
      _showSnackbar('NATIVE RECORDING COMING NEXT');
      return;
    }

    int armedCount = _armedTracks.where((isArmed) => isArmed).length;
    if (armedCount != 1) {
      _showSnackbar('ERR: EXACTLY 1 TRACK MUST BE ARMED');
      return;
    }

    int armedIndex = _armedTracks.indexOf(true);
    final int recordTapeStartMs = _playbackMs.clamp(0, tapeLengthMs);
    debugPrint(
        'Orpheus Deck: RECORD_TAPE_START armedTrack=$armedIndex recordTapeStartMs=$recordTapeStartMs playbackMs=$_playbackMs');

    if (_trackFiles[armedIndex] != null) {
      _showSnackbar('ERR: TRACK FULL. CLEAR FIRST.');
      return;
    }

    final bool isOverdub = _trackFiles.any((file) => file != null);
    if (!skipRecordingCheckReminder &&
        OrpheusSettings.instance.recordingCheckReminderEnabled) {
      _showRecordingCheckReminder();
      return;
    }

    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showSnackbar('ERR: MIC PERMISSION DENIED');
      return;
    }

    if (await _recorder.hasPermission()) {
      _activeRecordTapeStartMs = recordTapeStartMs;
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (!await projDir.exists()) {
        await projDir.create(recursive: true);
      }
      String shortTimestamp =
          (DateTime.now().millisecondsSinceEpoch % 10000000).toString();
      final path = '${projDir.path}/track_${armedIndex}_$shortTimestamp.m4a';

      _updateMixerState();

      // Stop all just_audio track players; tape-aware seek happens per-track
      // below, using the same scheduling model as [_play].
      for (var p in _trackPlayers) {
        await p.stop();
      }

      _pendingPlaybackIndices.clear();
      _resetCompletionTracking();

      debugPrint(
        'Orpheus Deck: RECORD_START tape head '
        'armedTrack=$armedIndex recordTapeStartMs=$recordTapeStartMs '
        'tapeLengthMs=$tapeLengthMs',
      );

      // Prepare overdub backing tracks: respect trackTapeStartMs so a delayed
      // backing track waits until the recording head reaches its tape position.
      final List<int> immediateBacking = [];
      final List<int> pendingBacking = [];
      for (int i = 0; i < 4; i++) {
        if (i == armedIndex) continue;
        if (_trackFiles[i] == null) continue;
        final file = File(_trackFiles[i]!);
        final bool exists = file.existsSync();
        final int size = exists ? file.lengthSync() : 0;
        final bool audible = _isTrackAudible(i);
        final double vol = audible ? _trackVolumes[i] : 0.0;
        final int tapeStart = _trackTapeStartMs[i];
        final int clipDur = _trackContentDurationMs(i);
        final int tapeEnd = tapeStart + clipDur;
        final bool past = clipDur > 0 && recordTapeStartMs >= tapeEnd;
        final bool delayed = recordTapeStartMs < tapeStart;
        final bool shouldPlayNow = !past && !delayed;

        debugPrint(
          'Orpheus Deck: REC BACKING TRK $i | path: ${_trackFiles[i]} | '
          'exists=$exists size=$size | '
          'tapeStart=$tapeStart clipDurMs=$clipDur tapeEnd=$tapeEnd | '
          'shouldPlayNow=$shouldPlayNow past=$past delayed=$delayed | '
          'vol=$vol audible=$audible',
        );

        if (!exists || size == 0) continue;
        if (!audible) {
          debugPrint("Orpheus Deck: REC BACKING TRK $i SKIP - not audible");
          continue;
        }
        if (past) {
          debugPrint(
            'Orpheus Deck: REC BACKING TRK $i SKIP - past tapeEnd '
            '(tapeEnd=$tapeEnd recordTapeStartMs=$recordTapeStartMs)',
          );
          continue;
        }

        try {
          await _trackPlayers[i].setFilePath(_trackFiles[i]!);
          await _trackPlayers[i].setVolume(vol);
          debugPrint(
              "Orpheus Deck: REC BACKING TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
        } catch (e) {
          debugPrint("Orpheus Deck: REC BACKING TRK $i prepare ERROR - $e");
          continue;
        }

        if (shouldPlayNow) {
          final int seekMs = _playbackSeekMsForTrack(
            i,
            recordTapeStartMs,
            tapeStart,
            clipDur,
          );
          try {
            await _trackPlayers[i].seek(Duration(milliseconds: seekMs));
          } catch (e) {
            debugPrint('Orpheus Deck: REC BACKING TRK $i seek err $e');
          }
          immediateBacking.add(i);
          debugPrint(
            'Orpheus Deck: REC BACKING TRK $i SCHEDULED=IMMEDIATE '
            'seekMs=$seekMs offsetMs=${_trackOffsets[i]} latencyComp='
            '${OrpheusSettings.instance.latencyCompensationEnabled} '
            'tapeStart=$tapeStart tapeEnd=$tapeEnd',
          );
        } else {
          try {
            await _trackPlayers[i].seek(Duration.zero);
          } catch (e) {
            debugPrint('Orpheus Deck: REC BACKING TRK $i seek err $e');
          }
          _pendingPlaybackIndices.add(i);
          pendingBacking.add(i);
          debugPrint(
            'Orpheus Deck: REC BACKING TRK $i SCHEDULED=PENDING '
            'tapeStart=$tapeStart tapeEnd=$tapeEnd',
          );
        }
      }

      _scheduledPlaybackCount = immediateBacking.length + pendingBacking.length;
      _completedPlaybackCount = 0;

      Future<void> finishRecordLaunch() async {
        // ── OVERDUB LAUNCH (FIXED SEQUENCING) ──────────────────────────────
        final bool clickEnabled = _metronomeOn;
        final bool hasConcurrentPlayback = isOverdub || clickEnabled;
        final AudioInterruptionMode recordInterruptionMode =
            hasConcurrentPlayback
                ? AudioInterruptionMode.none
                : AudioInterruptionMode.pause;

        debugPrint("Orpheus Deck: RECORD LAUNCH - starting recorder first");
        debugPrint(
          'Orpheus Deck: record isOverdub=$isOverdub clickEnabled=$clickEnabled '
          'hasConcurrentPlayback=$hasConcurrentPlayback '
          'audioInterruption=$recordInterruptionMode',
        );
        final Stopwatch sw = Stopwatch();
        sw.start();

        final recordCfg =
            _recordConfigForCurrentSession(recordInterruptionMode);
        debugPrint(
            'Orpheus Deck: RecordConfig json=${jsonEncode(recordCfg.toMap())}');
        try {
          await _recorder.start(
            recordCfg,
            path: path,
          );
          debugPrint(
            "Orpheus Deck: Recorder start CONFIRMED at ${sw.elapsedMilliseconds}ms path=$path");
        } catch (e, st) {
          debugPrint("Orpheus Deck: Recorder start ERROR $e\n$st");
          sw.stop();
          _activeRecordTapeStartMs = null;
          debugPrint(
            'Orpheus Deck: TRANSPORT_STOP reason=RECORDER_ERROR '
            'tapeLengthMs=$tapeLengthMs playbackMs=$_playbackMs',
          );
          return;
        }

        if (immediateBacking.isNotEmpty) {
          debugPrint(
            'Orpheus Deck: Starting ${immediateBacking.length} immediate '
            'backing players $immediateBacking (pending=$pendingBacking)',
          );
          for (int i in immediateBacking) {
            _trackPlayers[i].play();
            _attachCompletionListenerFor(i);
          }
        }

        if (_metronomeOn) {
          unawaited(_tryStartClickPlayback(
            contextTag: 'record',
            seekMs: recordTapeStartMs,
          ));
        }

        sw.stop();

        final int measuredOffsetMs = sw.elapsedMilliseconds;
        final int storedOffset = _storedLatencyOffsetMs(measuredOffsetMs);
        setState(() {
          _trackOffsets[armedIndex] = storedOffset;
        });
        debugPrint(
          'Orpheus Deck: RECORD LAUNCH complete | measured=${measuredOffsetMs}ms '
          'stored=$storedOffset latencyComp='
          '${OrpheusSettings.instance.latencyCompensationEnabled} '
          'manualMs=${OrpheusSettings.instance.manualLatencyAdjustMs} '
          'track=$armedIndex',
        );

        int recAmpLogTicks = 0;
        int clickBleedNearBeatLoudCount = 0;
        final int recAmpDiagTicks = clickEnabled ? 100 : 40;
        _amplitudeSub = _recorder
            .onAmplitudeChanged(const Duration(milliseconds: 50))
            .listen((amp) {
          if (recAmpLogTicks < recAmpDiagTicks) {
            if (clickEnabled) {
              final recMs = recAmpLogTicks * 50;
              final mpb = 60000.0 / _bpm;
              final phase = recMs % mpb;
              final nearBeat = phase < 35 || phase > mpb - 35;
              final loudish = amp.current > -38;
              if (nearBeat && loudish) clickBleedNearBeatLoudCount++;
              debugPrint(
                'Orpheus Deck: REC amplitude tick=$recAmpLogTicks '
                'currentDb=${amp.current} nearBeatWindow=$nearBeat '
                'phaseMs=${phase.toStringAsFixed(0)} bpm=$_bpm '
                'nearBeatLoudCount=$clickBleedNearBeatLoudCount',
              );
              if (recAmpLogTicks == recAmpDiagTicks - 1) {
                debugPrint(
                  'Orpheus Deck: REC CLICK bleed diag (${recAmpDiagTicks * 50}ms): '
                  'nearBeat+loudishCount=$clickBleedNearBeatLoudCount/$recAmpDiagTicks '
                  '(quiet room / covered mic: high count suggests capture-path bleed)',
                );
              }
            } else {
              debugPrint(
                'Orpheus Deck: REC amplitude tick=$recAmpLogTicks '
                'currentDb=${amp.current} isOverdub=$isOverdub clickEnabled=$clickEnabled',
              );
            }
            recAmpLogTicks++;
          }
          setState(() {
            double normalized = (amp.current + 45) / 45;
            if (normalized < 0.02) normalized = 0.02;
            if (normalized > 1.0) normalized = 1.0;
            _liveAmplitudes.add(normalized);
          });
        });

        setState(() {
          _isRecording = true;
          _isPlaying = true;
          _applyTapeHeadClamped(recordTapeStartMs);
        });
        debugPrint(
          'Orpheus Deck: RECORD_TRANSPORT_START '
          'armedTrack=$armedIndex recordTapeStartMs=$recordTapeStartMs '
          'tapeLengthMs=$tapeLengthMs playbackMs=$_playbackMs '
          'contentMaxMs=${_getMaxPlaybackDuration()}',
        );
        _startTicker();
      }

      await finishRecordLaunch();
    }
  }

  Future<void> _stop({String transportStopReason = 'USER_STOP'}) async {
    if (_isExporting && _exportSessionId != null) {
      FFmpegKit.cancel(_exportSessionId);
      return;
    }

    // Cassette: second STOP while already idle rewinds tape to 0:00.
    if (!_isRecording && !_isPlaying) {
      debugPrint(
        'Orpheus Deck: TRANSPORT_STOP_IDLE_REWIND '
        'reason=$transportStopReason '
        'tapeLengthMs=$tapeLengthMs playbackMs=$_playbackMs -> 0',
      );
      _setTapeHeadMs(0);
      await _stopClickPlayback();
      return;
    }

    final int contentMaxMs = _getMaxPlaybackDuration();
    debugPrint(
      'Orpheus Deck: TRANSPORT_STOP '
      'reason=$transportStopReason '
      'tapeLengthMs=$tapeLengthMs '
      'playbackMs=$_playbackMs '
      'contentMaxMs=$contentMaxMs '
      'recording=$_isRecording playing=$_isPlaying',
    );

    bool recordedSomething = false;

    if (_isRecording) {
      _amplitudeSub?.cancel();
      final path = await _recorder.stop();
      if (path != null) {
        int armedIndex = _armedTracks.indexOf(true);
        if (armedIndex != -1) {
          final file = File(path);
          int fileSize = file.existsSync() ? file.lengthSync() : 0;
          debugPrint(
              "Orpheus Deck: Recorder stopped. SAVED file size=$fileSize bytes path=$path "
              "ampSamples=${_liveAmplitudes.length} clickEnabled=$_metronomeOn");

          if (fileSize > 0 &&
              _liveAmplitudes.isNotEmpty &&
              _liveAmplitudes.any((a) => a > 0.03)) {
            final int savedTapeStartMs = _activeRecordTapeStartMs ?? 0;
            setState(() {
              _trackFiles[armedIndex] = path;
              _waveformCache[path] = List.from(_liveAmplitudes);
              _trackTapeStartMs[armedIndex] = savedTapeStartMs;
              _armedTracks[armedIndex] = false;
              recordedSomething = true;
            });
            debugPrint(
                'Orpheus Deck: RECORD_SAVE armedTrack=$armedIndex '
                'recordTapeStartMs=$savedTapeStartMs fileSize=$fileSize path=$path');
          } else {
            debugPrint("Orpheus Deck: Ignored silent/empty recording.");
            if (file.existsSync()) file.deleteSync();
            setState(() {
              _armedTracks[armedIndex] = false;
            });
          }
        }
      }
      _activeRecordTapeStartMs = null;
      _liveAmplitudes.clear();
    }

    if (_nativePlaybackActive) {
      await _stopNativePlaybackOnly();
    }

    for (var player in _trackPlayers) {
      await player.stop();
    }

    await _stopClickPlayback();

    _tickerTimer?.cancel();

    _pendingPlaybackIndices.clear();
    _resetCompletionTracking();

    setState(() {
      _isPlaying = false;
      _isRecording = false;
      _nativePlaybackActive = false;
    });

    if (recordedSomething) {
      _saveSession();
    }
  }

  void _resetTimer() {
    unawaited(_resetTimerAfterStop());
  }

  Future<void> _resetTimerAfterStop() async {
    await _stop(transportStopReason: 'LONG_PRESS_RESET');
    if (!mounted) return;
    _setTapeHeadMs(0);
    _showSnackbar('TIMER RESET');
  }

  void _toggleArmTrack(int index) {
    if (_trackFiles[index] != null) {
      _showSnackbar('ERR: TRACK FULL. CLEAR FIRST.');
      return;
    }
    setState(() {
      _armedTracks[index] = !_armedTracks[index];
    });
  }

  /// Debug-only: populate native_test project with 4 staggered WAV click tracks.
  Future<void> _generateNativeTestTracks() async {
    if (!kDebugMode) return;
    if (!isNativeTestAudioEngine(_projectAudioEngine)) {
      _showSnackbar('ERR: NATIVE TEST PROJECT ONLY');
      return;
    }
    if (_isPlaying || _isRecording || _isExporting) {
      _showSnackbar('ERR: STOP TRANSPORT FIRST');
      return;
    }

    try {
      await _stopNativePlaybackOnly();
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (!await projDir.exists()) {
        await projDir.create(recursive: true);
      }

      for (int i = 0; i < 4; i++) {
        final old = _trackFiles[i];
        if (old != null) {
          final f = File(old);
          if (f.existsSync()) {
            await f.delete();
          }
          _waveformCache.remove(old);
        }
      }

      const tapeStartsMs = [0, 1000, 2000, 3000];
      final newPaths = <String>[];

      for (int i = 0; i < 4; i++) {
        final path = '${projDir.path}/native_test_trk$i.wav';
        await writeNativeTestTrackWav(path: path, trackIndex: i);
        newPaths.add(path);
      }

      if (!mounted) return;
      setState(() {
        for (int i = 0; i < 4; i++) {
          _trackFiles[i] = newPaths[i];
          _trackTapeStartMs[i] = tapeStartsMs[i];
          _trackOffsets[i] = 0;
          _armedTracks[i] = false;
          _waveformCache[newPaths[i]] =
              nativeTestTrackWaveformPlaceholder(i);
        }
        _projectAudioEngine = kOrpheusAudioEngineNativeTest;
      });
      await _saveSession();
      _showSnackbar('NATIVE TEST TRACKS READY');
      debugPrint('Orpheus N3E-G: generated 4 native test WAV tracks');
    } catch (e, st) {
      debugPrint('Orpheus N3E-G: generate native test tracks failed: $e\n$st');
      _showSnackbar('ERR: NATIVE TEST TRACK GEN FAILED');
    }
  }

  Future<void> _clearTrack(int index) async {
    if (_isRecording || _isPlaying) {
      _showSnackbar('ERR: STOP TRANSPORT TO CLEAR');
      return;
    }
    if (_trackFiles[index] == null) {
      debugPrint('Orpheus Deck: CLEAR TRK $index - no file, nothing to do');
      return;
    }

    final String filePath = _trackFiles[index]!;
    debugPrint('Orpheus Deck: CLEAR TRK $index START | path: $filePath');

    // 1. Stop and dispose the just_audio player for this track so ExoPlayer
    //    releases its internal file handle before we rename the file.
    try {
      await _trackPlayers[index].stop();
      await _trackPlayers[index].dispose();
      _trackPlayers[index] = ja.AudioPlayer();
      debugPrint(
          'Orpheus Deck: CLEAR TRK $index - player released and recreated');
    } catch (e, s) {
      debugPrint(
          'Orpheus Deck: CLEAR TRK $index - player release ERROR: $e\n$s');
    }

    // 2. Save undo state before mutating anything.
    _lastUndo.clear();
    _lastUndo.action = UndoAction.clearTrack;
    _lastUndo.trackIndex = index;
    _lastUndo.trackFile = filePath;
    _lastUndo.trackWaveform = _waveformCache[filePath];
    _lastUndo.trackTapeStartMs = _trackTapeStartMs[index];

    // 3. Rename the file to .trash (recoverable undo target).
    final File file = File(filePath);
    if (file.existsSync()) {
      try {
        file.renameSync('${file.path}.trash');
        debugPrint('Orpheus Deck: CLEAR TRK $index - renamed to .trash OK');
      } catch (e, s) {
        debugPrint('Orpheus Deck: CLEAR TRK $index - rename FAILED: $e\n$s');
        // Fallback: delete so the path slot is freed even if rename fails.
        try {
          file.deleteSync();
          debugPrint('Orpheus Deck: CLEAR TRK $index - fallback deleteSync OK');
        } catch (e2, s2) {
          debugPrint(
              'Orpheus Deck: CLEAR TRK $index - delete also FAILED: $e2\n$s2');
        }
      }
    } else {
      debugPrint(
          'Orpheus Deck: CLEAR TRK $index - file not on disk (already gone)');
    }

    // 4. Clear all in-memory state for this track atomically.
    setState(() {
      _waveformCache.remove(filePath);
      _trackFiles[index] = null;
      _trackOffsets[index] = 0;
      _trackTapeStartMs[index] = 0;
    });

    debugPrint(
        'Orpheus Deck: CLEAR TRK $index DONE - file/waveform/offset cleared');
    _showSnackbar('TRK 0${index + 1} CLEARED');
    _saveSession();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              DeckHeader(
                statusLabel: _deckStatus,
                tapeTransportMs: _playbackMs,
                projectName: _projectName,
                onProjectTap: _showProjectMenu,
                hasUndo: _lastUndo.hasUndo,
                onUndo: _performUndo,
                debugEngineLine: kDebugMode ? _recorderEngineDebugLine() : null,
                debugProjectEngineLine:
                    kDebugMode ? _projectEngineDebugLine() : null,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    itemCount: 4,
                    separatorBuilder: (context, index) => const Divider(
                      color: Colors.white24,
                      height: 1,
                      thickness: 1,
                    ),
                    itemBuilder: (context, index) {
                      return TrackStrip(
                        trackNumber: index + 1,
                        isArmed: _armedTracks[index],
                        isPlaying: _isPlaying,
                        isRecording: _isRecording,
                        filePath: _trackFiles[index],
                        amplitudes: _getAmplitudesForTrack(index),
                        tapeStartMs: _waveformLaneTapeStartMs(
                          (_isRecording &&
                                  _armedTracks[index] &&
                                  _activeRecordTapeStartMs != null)
                              ? _activeRecordTapeStartMs!
                              : _trackTapeStartMs[index],
                        ),
                        clipDurationMs: (_isRecording && _armedTracks[index])
                            ? _liveAmplitudes.length * 50
                            : _trackContentDurationMs(index),
                        tapeTransportMs: _playbackMs,
                        volume: _trackVolumes[index],
                        isMuted: _trackMutes[index],
                        isSoloed: _trackSolos[index],
                        onArmToggled: () => _toggleArmTrack(index),
                        onClear: () => _clearTrack(index),
                        onVolumeChangeStart: (val) =>
                            _onVolumeChangeStart(index, val),
                        onVolumeChanged: (val) => _setVolume(index, val),
                        onMuteToggled: () => _toggleMute(index),
                        onSoloToggled: () => _toggleSolo(index),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TapeReelTransport(
                playbackMs: _playbackMs,
                tapeLengthMs: tapeLengthMs,
                isPlaying: _isPlaying,
                isRecording: _isRecording,
                seekEnabled: !_isExporting,
                onTapeSeekMs: _onTapeHeadSeekFromReel,
              ),
              const SizedBox(height: 10),
              TransportControls(
                isPlaying: _isPlaying,
                isRecording: _isRecording,
                isClickTrackOn: _metronomeOn,
                onPlay: _play,
                onStop: _stop,
                onStopLongPress: _resetTimer,
                onRecord: _record,
                onClickSettings: _showClickTrackSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _initAudioSession() async {
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
    debugPrint(
        'Orpheus Deck: Audio session configured playAndRecord json=${jsonEncode(cfg.toJson())}');
    try {
      final live = await as_sess.AudioSession.instance;
      debugPrint(
          'Orpheus Deck: AudioSession active id=${identityHashCode(live)} '
          'isConfigured=${live.isConfigured} androidUsage=${live.configuration?.androidAudioAttributes?.usage}');
    } catch (e, st) {
      debugPrint('Orpheus Deck: AudioSession post-config log err $e\n$st');
    }
  }

  /// Recording config: explicit Android [AndroidAudioSource.mic] avoids
  /// OEM [defaultSource] mapping to voice/communication paths that can mix
  /// playback (CLICK) into the encoded stream. AGC/NS/AEC flags stay off.
  RecordConfig _recordConfigForCurrentSession(
      AudioInterruptionMode interruption) {
    return RecordConfig(
      encoder: AudioEncoder.aacLc,
      numChannels: 1,
      sampleRate: 44100,
      bitRate: 128000,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      audioInterruption: interruption,
      androidConfig: const AndroidRecordConfig(
        useLegacy: false,
        muteAudio: false,
        manageBluetooth: true,
        audioSource: AndroidAudioSource.mic,
        speakerphone: false,
        audioManagerMode: AudioManagerMode.modeNormal,
      ),
    );
  }

}

class _ExportsBrowseHost extends StatefulWidget {
  const _ExportsBrowseHost({required this.recorder});
  final _RecorderScreenState recorder;

  @override
  State<_ExportsBrowseHost> createState() => _ExportsBrowseHostState();
}

class _ExportsBrowseHostState extends State<_ExportsBrowseHost> {
  int _reloadNonce = 0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.black,
      shape: Border.all(color: Colors.white, width: 2),
      title: const Text(
        'EXPORTS',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: FutureBuilder<_ExportBrowseSnapshot>(
          key: ValueKey(_reloadNonce),
          future: widget.recorder._loadExportsBrowseSnapshot(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
              return const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              );
            }
            if (snap.hasError) {
              return const Text(
                'EXPORTS SAVED TO MUSIC/ORPHEUS DECK',
                style: TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  height: 1.35,
                ),
              );
            }
            final data = snap.data!;
            if (data.entries.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'NO EXPORTS IN HISTORY',
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  if (data.footerHintText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      data.footerHintText!,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                        fontSize: 9,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView.separated(
                    itemCount: data.entries.length,
                    separatorBuilder: (_, __) => const Divider(
                      color: Colors.white24,
                      height: 1,
                      thickness: 1,
                    ),
                    itemBuilder: (ctx, i) {
                      final e = data.entries[i];
                      final ts = _formatExportDateTime(e.createdAt);
                      final canDelete = (e.storageUri != null &&
                              e.storageUri!.startsWith('content://')) ||
                          (e.absolutePath != null &&
                              File(e.absolutePath!).existsSync());
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.filename,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${e.kind} • $ts',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontFamily: 'monospace',
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () =>
                                      widget.recorder._shareExportEntry(e),
                                  style: TextButton.styleFrom(
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    foregroundColor: Colors.white,
                                  ),
                                  child: const Text(
                                    'SHARE',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => widget.recorder
                                      ._tryOpenExportLocation(e),
                                  style: TextButton.styleFrom(
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    foregroundColor: Colors.white70,
                                  ),
                                  child: const Text(
                                    'OPEN',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                                if (canDelete)
                                  TextButton(
                                    onPressed: () async {
                                      await widget.recorder
                                          ._deleteExportBrowsedEntry(e);
                                      if (mounted) {
                                        setState(() => _reloadNonce++);
                                      }
                                    },
                                    style: TextButton.styleFrom(
                                      minimumSize: Size.zero,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      foregroundColor: Colors.white38,
                                    ),
                                    child: const Text(
                                      'DELETE',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (data.footerHintText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    data.footerHintText!,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      height: 1.35,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'CLOSE',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class DeckHeader extends StatelessWidget {
  final String statusLabel;
  /// Same value as recorder `_playbackMs` (tape transport clock).
  final int tapeTransportMs;
  final String projectName;
  final VoidCallback onProjectTap;
  final bool hasUndo;
  final VoidCallback onUndo;
  final String? debugEngineLine;
  final String? debugProjectEngineLine;

  const DeckHeader({
    super.key,
    required this.statusLabel,
    required this.tapeTransportMs,
    required this.projectName,
    required this.onProjectTap,
    this.hasUndo = false,
    required this.onUndo,
    this.debugEngineLine,
    this.debugProjectEngineLine,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "ORPHEUS DECK",
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: onProjectTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            border:
                                Border.all(color: Colors.white54, width: 1),
                          ),
                          child: Text(
                            "PROJECT: $projectName",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: const TextStyle(
                              color: Colors.white,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (hasUndo) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: onUndo,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                          child: const Text(
                            "UNDO",
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  "FOUR-TRACK AUDIO RECORDER // MK-I",
                  style: TextStyle(
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 8,
                    letterSpacing: 1,
                  ),
                ),
                if (debugProjectEngineLine != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    debugProjectEngineLine!,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 7,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
                if (debugEngineLine != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    debugEngineLine!,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 7,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _tapeClockMmSs(tapeTransportMs),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              Row(
                children: [
                  Text(
                    (statusLabel == 'RECORDING' ||
                            statusLabel == 'OVERDUB' ||
                            statusLabel == 'EXPORTING')
                        ? "● $statusLabel"
                        : statusLabel,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: statusLabel != 'IDLE'
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class TrackStrip extends StatelessWidget {
  final int trackNumber;
  final bool isArmed;
  final bool isPlaying;
  final bool isRecording;
  final String? filePath;
  final List<double> amplitudes;
  final int tapeStartMs;
  final int clipDurationMs;
  /// Same recorder `_playbackMs` as reel / header (transport playhead).
  final int tapeTransportMs;

  final double volume;
  final bool isMuted;
  final bool isSoloed;

  final VoidCallback onArmToggled;
  final VoidCallback onClear;
  final ValueChanged<double>? onVolumeChangeStart;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onMuteToggled;
  final VoidCallback onSoloToggled;

  const TrackStrip({
    super.key,
    required this.trackNumber,
    required this.isArmed,
    required this.isPlaying,
    required this.isRecording,
    required this.filePath,
    required this.amplitudes,
    required this.tapeStartMs,
    required this.clipDurationMs,
    required this.tapeTransportMs,
    required this.volume,
    required this.isMuted,
    required this.isSoloed,
    required this.onArmToggled,
    required this.onClear,
    this.onVolumeChangeStart,
    required this.onVolumeChanged,
    required this.onMuteToggled,
    required this.onSoloToggled,
  });

  bool get _isWaveformActive {
    bool hasAudio = filePath != null;
    if (isRecording) {
      if (isArmed) return true;
      if (hasAudio) return true;
      return false;
    } else {
      return isPlaying && hasAudio;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool hasAudio = filePath != null;
    final String clipId = hasAudio
        ? filePath!.split(RegExp(r'[/\\]')).last.replaceAll('.m4a', '')
        : "";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onLongPress: hasAudio && clipId.isNotEmpty
                    ? () {
                        showOrpheusOledToast(context, 'CLIP: $clipId');
                      }
                    : null,
                child: SizedBox(
                  width: 65,
                  child: Text(
                    'TRK 0$trackNumber',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: onArmToggled,
                child: Container(
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: isArmed ? Colors.white : Colors.black,
                    border: Border.all(color: Colors.white, width: 2),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      "A",
                      style: TextStyle(
                        color: isArmed ? Colors.black : Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Colors.white54, width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.0),
                    child: WaveformDisplay(
                      amplitudes: amplitudes,
                      isLive: isRecording && isArmed,
                      tapeStartMs: tapeStartMs,
                      clipDurationMs: clipDurationMs,
                      playbackMs: tapeTransportMs,
                      tapeLengthMs: tapeLengthMs,
                      isActive: _isWaveformActive,
                    ),
                  ),
                ),
              ),
              if (hasAudio)
                GestureDetector(
                  onTap: onClear,
                  child: Container(
                    width: 36,
                    height: 36,
                    margin: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.white54, width: 1),
                    ),
                    child: const Center(
                      child: Text(
                        "CLR",
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 65),
              GestureDetector(
                onTap: onMuteToggled,
                child: Container(
                  width: 24,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isMuted ? Colors.white : Colors.black,
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                  child: Center(
                    child: Text(
                      "M",
                      style: TextStyle(
                        color: isMuted ? Colors.black : Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onSoloToggled,
                child: Container(
                  width: 24,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isSoloed ? Colors.white : Colors.black,
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                  child: Center(
                    child: Text(
                      "S",
                      style: TextStyle(
                        color: isSoloed ? Colors.black : Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text("VOL",
                  style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 10)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: volume,
                    min: 0.0,
                    max: 1.0,
                    onChangeStart: onVolumeChangeStart,
                    onChanged: onVolumeChanged,
                  ),
                ),
              ),
              if (hasAudio) const SizedBox(width: 48),
            ],
          ),
        ],
      ),
    );
  }
}

/// Max-pool [src] down to [targetCount] bars for tape-lane painting.
List<double> _downsampleWaveformForLane(List<double> src, int targetCount) {
  if (src.isEmpty || targetCount <= 0) return const [];
  if (targetCount >= src.length) return src;
  final out = <double>[];
  final double chunk = src.length / targetCount;
  for (int i = 0; i < targetCount; i++) {
    final int start = (i * chunk).floor();
    final int end = min(((i + 1) * chunk).ceil(), src.length);
    double peak = 0;
    for (int j = start; j < end; j++) {
      if (src[j] > peak) peak = src[j];
    }
    out.add(peak);
  }
  return out;
}

class WaveformDisplay extends StatelessWidget {
  final List<double> amplitudes;
  final bool isLive;
  final int tapeStartMs;
  final int clipDurationMs;
  final int playbackMs;
  final int tapeLengthMs;
  final bool isActive;

  const WaveformDisplay({
    super.key,
    required this.amplitudes,
    this.isLive = false,
    this.tapeStartMs = 0,
    this.clipDurationMs = 0,
    this.playbackMs = 0,
    required this.tapeLengthMs,
    this.isActive = true,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: WaveformPainter(
            amplitudes: amplitudes,
            isLive: isLive,
            tapeStartMs: tapeStartMs,
            clipDurationMs: clipDurationMs,
            playbackMs: playbackMs,
            tapeLengthMs: tapeLengthMs,
            isActive: isActive,
          ),
        );
      },
    );
  }
}

/// Fifteen-minute tape lane: waveform only between [tapeStartMs, tapeEndMs].
class WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final bool isLive;
  final int tapeStartMs;
  final int clipDurationMs;
  final int playbackMs;
  final int tapeLengthMs;
  final bool isActive;

  WaveformPainter({
    required this.amplitudes,
    required this.isLive,
    required this.tapeStartMs,
    required this.clipDurationMs,
    required this.playbackMs,
    required this.tapeLengthMs,
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double midY = h / 2;
    final int tapeLen = max(1, tapeLengthMs);

    final Paint baselinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.14)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, midY), Offset(w, midY), baselinePaint);

    // Subtle minute ticks — tape feel, not a DAW grid.
    for (int m = 1; m < 15; m++) {
      final double x = w * (m / 15.0);
      canvas.drawLine(
        Offset(x, midY - 2),
        Offset(x, midY + 2),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.10)
          ..strokeWidth = 1,
      );
    }

    final int effectiveClipMs = clipDurationMs > 0
        ? clipDurationMs
        : (amplitudes.isEmpty ? 0 : amplitudes.length * 50);

    if (effectiveClipMs > 0 && amplitudes.isNotEmpty) {
      final double xStart = (tapeStartMs / tapeLen) * w;
      final double xEnd =
          ((tapeStartMs + effectiveClipMs) / tapeLen) * w;
      final double clipLeft = xStart.clamp(0.0, w);
      final double clipRight = xEnd.clamp(clipLeft, w);
      final double clipW = clipRight - clipLeft;

      if (clipW >= 1.0) {
        final Paint wavePaint = Paint()
          ..color = isActive ? Colors.white : Colors.white24
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round;

        final int maxBars = max(1, (clipW / 3).floor());
        final List<double> bars =
            _downsampleWaveformForLane(amplitudes, maxBars);
        final double step = clipW / bars.length;

        for (int i = 0; i < bars.length; i++) {
          final double amp = bars[i];
          if (amp <= 0.001) continue;
          double barHeight = amp * h * 0.92;
          if (barHeight < 2) barHeight = 2;
          final double x = clipLeft + (i + 0.5) * step;
          canvas.drawLine(
            Offset(x, midY - barHeight / 2),
            Offset(x, midY + barHeight / 2),
            wavePaint,
          );
        }
      }
    }

    // Shared tape playhead — all lanes, idle/play/record/seek.
    final double playheadX =
        (playbackMs / tapeLen).clamp(0.0, 1.0) * w;
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, h),
      Paint()
        ..color = Colors.white.withValues(alpha: isActive ? 1.0 : 0.72)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.amplitudes.length != amplitudes.length ||
        oldDelegate.playbackMs != playbackMs ||
        oldDelegate.tapeStartMs != tapeStartMs ||
        oldDelegate.clipDurationMs != clipDurationMs ||
        oldDelegate.isActive != isActive ||
        oldDelegate.isLive != isLive;
  }
}

class TransportControls extends StatelessWidget {
  final bool isPlaying;
  final bool isRecording;
  final bool isClickTrackOn;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onStopLongPress;
  final VoidCallback onRecord;
  final VoidCallback onClickSettings;

  const TransportControls({
    super.key,
    required this.isPlaying,
    required this.isRecording,
    required this.isClickTrackOn,
    required this.onPlay,
    required this.onStop,
    required this.onStopLongPress,
    required this.onRecord,
    required this.onClickSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TransportButton(
            label: "PLAY",
            icon: Icons.play_arrow,
            isActive: isPlaying && !isRecording,
            onTap: onPlay,
          ),
          TransportButton(
            label: "STOP",
            icon: Icons.stop,
            isActive: false,
            onTap: onStop,
            onLongPress: onStopLongPress,
          ),
          TransportButton(
            label: "REC",
            icon: Icons.fiber_manual_record,
            isActive: isRecording,
            onTap: onRecord,
          ),
          TransportButton(
            label: "CLICK",
            icon: Icons.graphic_eq,
            isActive: isClickTrackOn,
            onTap: onClickSettings,
          ),
        ],
      ),
    );
  }
}

class TransportButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const TransportButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 70,
        height: 60,
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.black,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isActive ? Colors.black : Colors.white,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 10,
                fontFamily: 'monospace',
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
