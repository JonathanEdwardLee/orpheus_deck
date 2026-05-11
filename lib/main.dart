/// ORPHEUS DECK
/// Orpheus Deck — four-track recorder
///
/// IMPORTANT:
/// This app is intentionally NOT a modern DAW.
/// Read ORPHEUS_DESIGN_MANIFESTO.md before making architectural changes.
///
/// Core philosophy:
/// - fast idea capture
/// - four-track limitation
/// - cassette/tape workflow
/// - lo-fi experimentation
/// - minimal editing
/// - hardware-style interaction

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
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

/// One cassette side — matches ORPHEUS_DESIGN_MANIFESTO.md.
const int kOrpheusTapeLengthMs = 15 * 60 * 1000;

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

void main() {
  runApp(const OrpheusDeckApp());
}

enum UndoAction { none, clearTrack, mixer, rename }

class UndoState {
  UndoAction action = UndoAction.none;

  int? trackIndex;
  String? trackFile;
  List<double>? trackWaveform;

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

List<int> fourTrackIntsFromJson(dynamic raw, int fill) {
  final list = List<int>.from(raw as List? ?? const <int>[]);
  while (list.length < 4) {
    list.add(fill);
  }
  if (list.length > 4) {
    return list.sublist(0, 4);
  }
  return list;
}

class Session {
  String projectName;
  DateTime createdAt;
  DateTime updatedAt;
  List<String?> trackFiles;
  Map<String, List<double>> waveformCache;
  List<String?> trackIds;
  List<int> trackOffsets;
  List<double> trackVolumes;
  List<bool> trackMutes;
  List<bool> trackSolos;
  List<ExportEntry> exports;
  int bpm;
  bool metronomeOn;
  String metronomeSound;
  /// One bar (4 beats) of CLICK-only pre-roll before the recorder starts.
  bool clickOneBarCountIn;
  /// Tape position (ms) when this track’s audio begins (post count-in).
  List<int> trackRecordStartTapeMs;

  Session({
    required this.projectName,
    required this.createdAt,
    required this.updatedAt,
    required this.trackFiles,
    required this.waveformCache,
    required this.trackIds,
    required this.trackOffsets,
    required this.trackVolumes,
    required this.trackMutes,
    required this.trackSolos,
    required this.exports,
    required this.bpm,
    required this.metronomeOn,
    required this.metronomeSound,
    required this.clickOneBarCountIn,
    required this.trackRecordStartTapeMs,
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
      'trackVolumes': trackVolumes,
      'trackMutes': trackMutes,
      'trackSolos': trackSolos,
      'exports': exports.map((e) => e.toJson()).toList(),
      'bpm': bpm,
      'metronomeOn': metronomeOn,
      'metronomeSound': metronomeSound,
      'clickOneBarCountIn': clickOneBarCountIn,
      'trackRecordStartTapeMs': trackRecordStartTapeMs,
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
      clickOneBarCountIn: json['clickOneBarCountIn'] as bool? ?? false,
      trackRecordStartTapeMs:
          fourTrackIntsFromJson(json['trackRecordStartTapeMs'], 0),
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

class _JunkfeathersGlitchSplashState extends State<JunkfeathersGlitchSplash>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 5500));
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
      body: Center(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            return SizedBox(
              width: 256,
              height: 128,
              child: CustomPaint(
                painter: JunkfeathersLogoPainter(_ctrl.value),
              ),
            );
          },
        ),
      ),
    );
  }
}

class JunkfeathersLogoPainter extends CustomPainter {
  final double progress;

  JunkfeathersLogoPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 128, size.height / 64);

    int phase = 0;
    double phaseProgress = 0.0;
    if (progress < (1500 / 5500)) {
      phase = 0;
      phaseProgress = progress / (1500 / 5500);
    } else if (progress < (4500 / 5500)) {
      phase = 1;
      phaseProgress = (progress - (1500 / 5500)) / (3000 / 5500);
    } else {
      phase = 2;
      phaseProgress = (progress - (4500 / 5500)) / (1000 / 5500);
    }

    int totalSteps = 5500 ~/ 55;
    int globalStep = (progress * totalSteps).floor();
    Random globalR = Random(globalStep);

    double jitterX = 0;
    double jitterY = 0;

    if (phase != 1) {
      if (globalR.nextInt(100) < 30) {
        jitterX = (globalR.nextInt(3) - 1.0);
        jitterY = (globalR.nextInt(3) - 1.0);
      }
    }

    canvas.translate(jitterX, jitterY);

    double opacity = 1.0;
    if (phase == 0) {
      opacity = 0.1 + (0.9 * phaseProgress);
    }
    if (phase == 2) {
      opacity = 1.0 - (0.9 * phaseProgress);
    }

    if (phase != 1) {
      if (globalR.nextInt(100) < 5) {
        opacity *= 0.5 + (globalR.nextDouble() * 0.5);
      }
    }

    final whitePaint = Paint()
      ..color = Colors.white.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: opacity)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    _drawText(canvas, "JUNKFEATHERS", 6, 1, opacity);
    _drawText(canvas, "TECH", 18, 2, opacity);

    _drawBird(canvas, 32, 50, 12, linePaint, whitePaint);
    _drawBird(canvas, 96, 50, 12, linePaint, whitePaint);

    if (phase != 1) {
      int steps = phase == 0 ? 25 : 21;
      int currentStep = (phaseProgress * (steps - 1)).floor();

      int coverChance = 0;
      if (phase == 0) {
        coverChance = (90 - (75 * currentStep / (steps - 1))).toInt();
      }
      if (phase == 2) {
        coverChance = (15 + (80 * currentStep / (steps - 1))).toInt();
      }

      final blackPaint = Paint()..color = Colors.black;
      final fastLinePaint = Paint()
        ..color = Colors.white.withValues(alpha: opacity);

      for (int y = 0; y < 64;) {
        int h = globalR.nextInt(9) + 2;
        if (globalR.nextInt(100) < coverChance) {
          canvas.drawRect(
              Rect.fromLTWH(0, y.toDouble(), 128, h.toDouble()), blackPaint);
        } else {
          if (globalR.nextInt(100) < 10) {
            canvas.drawRect(
                Rect.fromLTWH(0, y.toDouble(), 128, 1), fastLinePaint);
          }
        }
        y += h;
      }
    }

    canvas.translate(-jitterX, -jitterY);

    final scanlinePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    for (double sy = 0; sy < 64; sy += 2) {
      canvas.drawRect(Rect.fromLTWH(0, sy, 128, 1), scanlinePaint);
    }
  }

  void _drawText(
      Canvas canvas, String text, double y, int size, double opacity) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: opacity),
          fontFamily: 'monospace',
          fontSize: size * 8.0,
          fontWeight: FontWeight.bold,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    double x = (128 - textPainter.width) / 2;
    textPainter.paint(canvas, Offset(x, y));
  }

  void _drawBird(Canvas canvas, double cx, double cy, double r,
      Paint strokePaint, Paint fillPaint) {
    canvas.drawCircle(Offset(cx, cy), r, strokePaint);

    double exL = cx - (r / 2);
    double exR = cx + (r / 2);
    double ey = cy - (r / 4);
    double s = 2;

    canvas.drawLine(
        Offset(exL - s, ey - s), Offset(exL + s, ey + s), strokePaint);
    canvas.drawLine(
        Offset(exL - s, ey + s), Offset(exL + s, ey - s), strokePaint);

    canvas.drawLine(
        Offset(exR - s, ey - s), Offset(exR + s, ey + s), strokePaint);
    canvas.drawLine(
        Offset(exR - s, ey + s), Offset(exR + s, ey - s), strokePaint);

    double bx = cx;
    double by = cy + (r / 3);

    Path beak = Path()
      ..moveTo(bx, by + 3)
      ..lineTo(bx - 4, by - 2)
      ..lineTo(bx + 4, by - 2)
      ..close();

    canvas.drawPath(beak, fillPaint);
  }

  @override
  bool shouldRepaint(covariant JunkfeathersLogoPainter old) =>
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
      if (await projDir.exists()) {
        final entities = projDir.listSync();
        _allProjects.clear();
        for (var e in entities) {
          if (e is Directory) {
            String name = e.path.split(RegExp(r'[/\\]')).last;
            _allProjects.add(name);
          }
        }
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
                      return ListTile(
                        title: Text(name,
                            style: const TextStyle(
                                color: Colors.white, fontFamily: 'monospace')),
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
                                                "Four-Track Recorder",
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
                    if (hasProjects) ...[
                      const SizedBox(height: 16),
                      _MenuBtn("LOAD PROJECT", _loadProject),
                    ],
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
    canvas.drawRRect(windowRect, paint);

    double reelR = winH * 0.45;
    double leftReelX = winX + winW * 0.15;
    double rightReelX = winX + winW * 0.85;
    double reelY = winY + winH / 2;

    canvas.drawLine(Offset(leftReelX, reelY + reelR),
        Offset(rightReelX, reelY + reelR), paint);
    canvas.drawLine(Offset(leftReelX, reelY - reelR),
        Offset(rightReelX, reelY - reelR), paint);

    void drawReel(double cx, double cy, double radius, double rotation) {
      canvas.drawCircle(Offset(cx, cy), radius, paint);
      canvas.drawCircle(Offset(cx, cy), radius * 0.3, paint);

      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rotation);
      for (int i = 0; i < 3; i++) {
        canvas.rotate(2 * pi / 3);
        canvas.drawLine(Offset(0, radius * 0.3), Offset(0, radius), paint);
      }
      canvas.restore();
    }

    canvas.drawCircle(
        Offset(leftReelX, reelY),
        winH * 0.8,
        Paint()
          ..color = Colors.white24
          ..style = PaintingStyle.fill);
    canvas.drawCircle(
        Offset(rightReelX, reelY),
        winH * 0.5,
        Paint()
          ..color = Colors.white24
          ..style = PaintingStyle.fill);

    double rotL = spinProgress * 2 * pi;
    double rotR = spinProgress * 3 * pi;
    drawReel(leftReelX, reelY, reelR, rotL);
    drawReel(rightReelX, reelY, reelR, rotR);

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

  const RecorderScreen({
    super.key,
    required this.projectName,
    required this.isNewProject,
  });

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class OrpheusConsole extends RecorderScreen {
  const OrpheusConsole(
      {super.key, required super.projectName, required super.isNewProject});
}

class _RecorderScreenState extends State<RecorderScreen> {
  bool _isPlaying = false;
  bool _isRecording = false;
  bool _isExporting = false;
  int _recordDuration = 0;
  int? _exportSessionId;

  Timer? _tickerTimer;
  Timer? _autosaveTimer;

  late String _projectName;
  DateTime _sessionCreatedAt = DateTime.now();

  final List<bool> _armedTracks = [false, false, false, false];
  final List<String?> _trackFiles = [null, null, null, null];
  final List<int> _trackOffsets = [
    0,
    0,
    0,
    0
  ]; // ms offset per track (measured at overdub start)
  final List<double> _trackVolumes = [1.0, 1.0, 1.0, 1.0];
  final List<bool> _trackMutes = [false, false, false, false];
  final List<bool> _trackSolos = [false, false, false, false];
  List<ExportEntry> _exports = [];

  static const MethodChannel _androidExportChannel =
      MethodChannel('com.junkfeathers.orpheusdeck/export');

  int _bpm = 120;
  bool _metronomeOn = false;
  String _metronomeSound = 'CLICK';
  bool _clickOneBarCountIn = false;
  /// Tape time (ms) where each track’s recorded audio lines up (after count-in).
  final List<int> _trackRecordStartTapeMs = [0, 0, 0, 0];
  /// Set when [AudioRecorder.start] succeeds; applied in [_stop] if the take is kept.
  int? _pendingRecordStartTapeMs;
  bool _headphonesConfirmed = false;

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
  int _playbackMs = 0;

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

  /// Tape length for transport clock: content duration, or 15:00 when click-only practice.
  int _tapeTimelineMaxMs() {
    final content = _getMaxPlaybackDuration();
    if (content > 0) return content;
    if (_metronomeOn) return kOrpheusTapeLengthMs;
    return 0;
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

  /// Load CLICK file, stop, seek to [tapeMs] — does **not** call [play].
  Future<bool> _prepareClickPlayerAtTapeMs(int tapeMs,
      {bool showBuildingUi = false}) async {
    if (!_metronomeOn) return true;
    try {
      final path = await _ensureClickTrackFile(showBuildingUi: showBuildingUi);
      if (path == null || !File(path).existsSync()) {
        debugPrint('Orpheus Deck: CLICK prepare aborted (no file) tapeMs=$tapeMs');
        return false;
      }
      if (_clickPlayerSourcePath != path) {
        await _clickPlayer.setFilePath(path);
        _clickPlayerSourcePath = path;
      }
      await _clickPlayer.setVolume(1.0);
      await _clickPlayer.stop();
      await _clickPlayer.seek(Duration(milliseconds: tapeMs));
      debugPrint(
          'Orpheus Deck: CLICK prepared (stopped+seek) tapeMs=$tapeMs path=$path');
      return true;
    } catch (e, st) {
      debugPrint('Orpheus Deck: CLICK prepare FAILED tapeMs=$tapeMs $e\n$st');
      _disableClickTrackDueToAudioConflict();
      return false;
    }
  }

  Future<void> _tryStartClickPlayback({
    required String contextTag,
    int? tapePositionMs,
  }) async {
    if (!_metronomeOn) return;
    final int pos = tapePositionMs ?? _playbackMs;
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
      await _clickPlayer.seek(Duration(milliseconds: pos));
      await _clickPlayer.play();
      debugPrint(
          'Orpheus Deck: CLICK player START ctx=$contextTag posMs=$pos '
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

  Future<void> _initializeNewProject(String name) async {
    _projectName = name;
    _sessionCreatedAt = DateTime.now();
    for (int i = 0; i < 4; i++) {
      _trackFiles[i] = null;
      _armedTracks[i] = false;
      _trackVolumes[i] = 1.0;
      _trackMutes[i] = false;
      _trackSolos[i] = false;
      _trackOffsets[i] = 0;
      _trackRecordStartTapeMs[i] = 0;
    }
    _waveformCache.clear();
    _exports.clear();
    _clickOneBarCountIn = false;
    _pendingRecordStartTapeMs = null;
    _headphonesConfirmed = false;
    _recordDuration = 0;
    _playbackProgress = 0.0;
    _playbackMs = 0;
    _lastUndo.clear();
    _clickPlayerSourcePath = null;

    _updateMixerState();
    await _saveSession();
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
          for (int i = 0; i < 4; i++) {
            _trackFiles[i] = session.trackFiles[i];
            _trackOffsets[i] = session.trackOffsets[i];
            _trackVolumes[i] = session.trackVolumes[i];
            _trackMutes[i] = session.trackMutes[i];
            _trackSolos[i] = session.trackSolos[i];
          }
          _waveformCache.addAll(session.waveformCache);

          _exports = keptExports;

          _bpm = session.bpm;
          _metronomeOn = session.metronomeOn;
          _metronomeSound = session.metronomeSound;
          _clickOneBarCountIn = session.clickOneBarCountIn;
          final trs = session.trackRecordStartTapeMs;
          for (int i = 0; i < 4; i++) {
            _trackRecordStartTapeMs[i] = i < trs.length ? trs[i] : 0;
          }
          _headphonesConfirmed = false;
        });
        _clickPlayerSourcePath = null;
      }

      _lastUndo.clear();
      await _recoverOrphanedRecordings();
      _updateMixerState();
      await _setLastProjectName(_projectName);
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
        trackVolumes: _trackVolumes,
        trackMutes: _trackMutes,
        trackSolos: _trackSolos,
        exports: _exports,
        bpm: _bpm,
        metronomeOn: _metronomeOn,
        metronomeSound: _metronomeSound,
        clickOneBarCountIn: _clickOneBarCountIn,
        trackRecordStartTapeMs: List<int>.from(_trackRecordStartTapeMs),
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

  Future<void> _deleteExportEntry(ExportEntry e) async {
    if (Platform.isAndroid &&
        e.storageUri != null &&
        e.storageUri!.startsWith('content://')) {
      try {
        await _androidExportChannel
            .invokeMethod('deleteMusicExport', {'uri': e.storageUri});
      } catch (err) {
        debugPrint('Orpheus Deck: deleteMusicExport $err');
      }
      return;
    }
    if (e.absolutePath != null) {
      await _deleteExportIfExists(e.absolutePath!);
    }
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

      List<String> inputs = [];
      List<String> filterParts = [];
      List<double> targetVolList = [];
      int activeCount = 0;

      bool anySolo = _trackSolos.contains(true);

      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null && File(_trackFiles[i]!).existsSync()) {
          double targetVol = 0.0;
          if (anySolo) {
            if (_trackSolos[i] && !_trackMutes[i]) targetVol = _trackVolumes[i];
          } else {
            if (!_trackMutes[i]) targetVol = _trackVolumes[i];
          }

          if (targetVol > 0.01) {
            inputs.add("-i");
            inputs.add(_trackFiles[i]!);
            targetVolList.add(targetVol);
            activeCount++;
          }
        }
      }

      if (activeCount == 0) {
        _showSnackbar("ERR: NO AUDIBLE TRACKS");
        setState(() => _isExporting = false);
        return;
      }

      for (int i = 0; i < activeCount; i++) {
        filterParts.add("[$i:a]volume=${targetVolList[i]}[a$i]");
      }

      String filterGraph = filterParts.join(";");
      String outPad = "[a0]";

      if (activeCount > 1) {
        String mixInputs = "";
        for (int i = 0; i < activeCount; i++) {
          mixInputs += "[a$i]";
        }
        filterGraph +=
            ";${mixInputs}amix=inputs=$activeCount:duration=longest,volume=$activeCount[mix]";
        outPad = "[mix]";
      }

      if (isMasterMix) {
        filterGraph += ";${outPad}loudnorm=I=-14:TP=-1:LRA=11[master]";
        outPad = "[master]";
      }

      List<String> command = [
        ...inputs,
        "-filter_complex",
        filterGraph,
        "-map",
        outPad,
        "-vn",
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
          debugPrint(
              'Orpheus Deck: export verify ok=${ver.ok} detail=${ver.detail} duration=${ver.durationSec ?? "?"}');

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
            content: SelectableText(
              body,
              style: const TextStyle(
                  color: Colors.white54, fontFamily: 'monospace', fontSize: 10),
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

  void _showExportOptionsDialog(ExportEntry entry) {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: Text(entry.filename,
                style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12)),
            content: Text(
              '${entry.kind}\n${entry.displayPath}',
              style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 10),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await _deleteExportEntry(entry);
                  setState(() {
                    _exports.removeWhere((x) => _sameExportEntry(x, entry));
                  });
                  _saveSession();
                  _showSnackbar("EXPORT DELETED");
                },
                child: const Text("DELETE",
                    style: TextStyle(
                        color: Colors.white, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  if (!_exportShareLooksValid(entry)) {
                    _showSnackbar("ERR: EXPORT FILE INVALID OR MISSING");
                    return;
                  }
                  await _shareExportEntry(entry);
                },
                child: const Text("SHARE",
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

  bool _sameExportEntry(ExportEntry a, ExportEntry b) {
    if (a.storageUri != null && b.storageUri != null) {
      return a.storageUri == b.storageUri;
    }
    if (a.absolutePath != null && b.absolutePath != null) {
      return a.absolutePath == b.absolutePath;
    }
    return identical(a, b);
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
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Timeline WAV in project folder — not mixed to export. Turn OFF for silent monitor.',
                      style: TextStyle(
                          color: Colors.white54,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35),
                    ),
                    const SizedBox(height: 16),
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
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("1 BAR COUNT-IN",
                            style: TextStyle(
                                color: Colors.white54,
                                fontFamily: 'monospace')),
                        GestureDetector(
                          onTap: () {
                            setState(
                                () => _clickOneBarCountIn = !_clickOneBarCountIn);
                            setDialogState(() {});
                            debugPrint(
                                'Orpheus Deck: CLICK COUNT-IN '
                                '${_clickOneBarCountIn ? "ON" : "OFF"}');
                            _saveSession();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: _clickOneBarCountIn
                                  ? Colors.white
                                  : Colors.black,
                              border: Border.all(color: Colors.white54),
                            ),
                            child: Text(
                              _clickOneBarCountIn ? "ON" : "OFF",
                              style: TextStyle(
                                  color: _clickOneBarCountIn
                                      ? Colors.black
                                      : Colors.white,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
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
                  const Text("EXPORTS",
                      style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  if (_exports.isEmpty)
                    const Text("NO EXPORTS YET",
                        style: TextStyle(
                            color: Colors.white54,
                            fontFamily: 'monospace',
                            fontSize: 10),
                        textAlign: TextAlign.center)
                  else
                    ..._exports.map((ExportEntry e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: _menuButton(e.filename, () {
                          Navigator.pop(context);
                          _showExportOptionsDialog(e);
                        }),
                      );
                    }),
                  const SizedBox(height: 24),
                  _menuButton("EXIT TO MENU", () {
                    _stop();
                    Navigator.pop(context);
                    Navigator.pushReplacementNamed(context, '/home');
                  }),
                  const SizedBox(height: 24),
                  _menuButton("TEST OVERDUB ENGINE", () {
                    Navigator.pop(context);
                    _testOverdubEngine();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: Colors.white24,
        duration: const Duration(seconds: 2),
      ),
    );
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
      if (_isPlaying) {
        final int maxMs = _tapeTimelineMaxMs();
        if (maxMs > 0) {
          final int nextMs = _playbackMs + 50;
          if (nextMs >= maxMs) {
            setState(() {
              _playbackMs = maxMs;
              _playbackProgress = 1.0;
            });
            scheduleMicrotask(() async {
              await _stop();
            });
          } else {
            setState(() {
              _playbackMs = nextMs;
              _playbackProgress = _playbackMs / maxMs;
              if (_playbackProgress > 1.0) _playbackProgress = 1.0;
            });
          }
        }
      }
      if (t.tick % 20 == 0) {
        setState(() {
          _recordDuration++;
        });
      }
      if (t.tick % 20 == 0 && _isPlaying && _metronomeOn) {
        unawaited(_resyncClickPlayerToTransport());
      }
    });
  }

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

  Future<void> _play() async {
    if (_isRecording || _isExporting) return;
    if (!_isPlaying) {
      setState(() {
        _isPlaying = true;
        _recordDuration = 0;
        _playbackMs = 0;
        _playbackProgress = 0.0;
      });

      // Stop and reset all just_audio track players.
      for (var p in _trackPlayers) {
        await p.stop();
        await p.seek(Duration.zero);
      }

      // Prepare sources. setFilePath must complete before play().
      final List<int> readyIndices = [];
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] == null) continue;
        final file = File(_trackFiles[i]!);
        final bool exists = file.existsSync();
        final int size = exists ? file.lengthSync() : 0;
        final bool audible = _isTrackAudible(i);
        final double vol = audible ? _trackVolumes[i] : 0.0;

        debugPrint(
            "Orpheus Deck: PLAY TRK $i | path: ${_trackFiles[i]} | exists: $exists | size: $size | mute: ${_trackMutes[i]} | solo: ${_trackSolos[i]} | vol: $vol | audible: $audible | player: ${_trackPlayers[i].hashCode}");

        if (!exists || size == 0) {
          debugPrint("Orpheus Deck: PLAY TRK $i SKIP - missing/empty");
          continue;
        }
        if (!audible) {
          debugPrint(
              "Orpheus Deck: PLAY TRK $i SKIP - not audible (muted/solo)");
          continue;
        }
        try {
          await _trackPlayers[i].setFilePath(_trackFiles[i]!);
          await _trackPlayers[i].setVolume(vol);
          debugPrint(
              "Orpheus Deck: PLAY TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
          readyIndices.add(i);
        } catch (e) {
          debugPrint("Orpheus Deck: PLAY TRK $i setFilePath ERROR - $e");
        }
      }

      // Fire play() on all ready players simultaneously.
      debugPrint(
          "Orpheus Deck: Starting ${readyIndices.length} just_audio players: $readyIndices");
      try {
        await Future.wait(readyIndices.map((i) => _trackPlayers[i].play()));
        debugPrint("Orpheus Deck: All players play() OK");
      } catch (e) {
        debugPrint("Orpheus Deck: play() ERROR - $e");
      }

      await _tryStartClickPlayback(contextTag: 'play');

      _startTicker();
      _attachPlayerCompletionListeners(readyIndices);
    }
  }

  /// Subscribe to each active player's processingStateStream.
  /// When ALL active players reach [ProcessingState.completed], trigger _stop()
  /// so the UI never stays stuck in PLAY mode after natural playback end.
  void _attachPlayerCompletionListeners(List<int> activeIndices) {
    // Cancel any existing subscriptions first.
    for (int i = 0; i < 4; i++) {
      _playerCompletionSubs[i]?.cancel();
      _playerCompletionSubs[i] = null;
    }
    if (activeIndices.isEmpty) return;

    // Track how many players have finished.
    int completedCount = 0;
    final int total = activeIndices.length;

    for (int i in activeIndices) {
      _playerCompletionSubs[i] =
          _trackPlayers[i].processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) {
          debugPrint('Orpheus Deck: TRK $i reached ProcessingState.completed');
          completedCount++;
          if (completedCount >= total && _isPlaying && !_isRecording) {
            debugPrint(
                'Orpheus Deck: All $total active players completed — auto-stopping');
            _stop();
          }
        }
      });
    }
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

  void _showHeadphonesWarning() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.black,
            shape: Border.all(color: Colors.white, width: 2),
            title: const Text("WARNING",
                style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            content: const Text(
                "USE HEADPHONES FOR OVERDUB TO PREVENT AUDIO BLEED.",
                style: TextStyle(
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 12)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CANCEL",
                    style: TextStyle(
                        color: Colors.white54, fontFamily: 'monospace')),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _headphonesConfirmed = true);
                  Navigator.pop(context);
                  _record();
                },
                child: const Text("I AM USING HEADPHONES",
                    style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
  }

  Future<void> _record() async {
    if (_isRecording || _isExporting) return;

    int armedCount = _armedTracks.where((isArmed) => isArmed).length;
    if (armedCount != 1) {
      _showSnackbar('ERR: EXACTLY 1 TRACK MUST BE ARMED');
      return;
    }

    int armedIndex = _armedTracks.indexOf(true);

    if (_trackFiles[armedIndex] != null) {
      _showSnackbar('ERR: TRACK FULL. CLEAR FIRST.');
      return;
    }

    bool isOverdub = _trackFiles.any((file) => file != null);
    if (isOverdub && !_headphonesConfirmed) {
      _showHeadphonesWarning();
      return;
    }

    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showSnackbar('ERR: MIC PERMISSION DENIED');
      return;
    }

    if (await _recorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (!await projDir.exists()) {
        await projDir.create(recursive: true);
      }
      String shortTimestamp =
          (DateTime.now().millisecondsSinceEpoch % 10000000).toString();
      final path = '${projDir.path}/track_${armedIndex}_$shortTimestamp.m4a';

      _pendingRecordStartTapeMs = null;
      _updateMixerState();

      final int recordTapeStartMs = _playbackMs;
      final int countInBarMs = (_clickOneBarCountIn && _metronomeOn)
          ? (240000.0 / _bpm).round()
          : 0;
      final int clickPreRollSeekMs = countInBarMs > 0
          ? (recordTapeStartMs - countInBarMs).clamp(0, 1 << 30)
          : recordTapeStartMs;
      final int actualCountInMs =
          countInBarMs > 0 ? (recordTapeStartMs - clickPreRollSeekMs) : 0;

      // Stop all just_audio track players; align to current tape position.
      for (var p in _trackPlayers) {
        await p.stop();
        await p.seek(Duration(milliseconds: recordTapeStartMs));
      }

      // Prepare overdub backing tracks with just_audio.
      final List<int> overdubIndices = [];
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] == null || i == armedIndex) continue;
        final file = File(_trackFiles[i]!);
        final bool exists = file.existsSync();
        final int size = exists ? file.lengthSync() : 0;
        final bool audible = _isTrackAudible(i);
        final double vol = audible ? _trackVolumes[i] : 0.0;

        debugPrint(
            "Orpheus Deck: OVERDUB TRK $i | path: ${_trackFiles[i]} | exists: $exists | size: $size | audible: $audible | vol: $vol");

        if (!exists || size == 0) continue;
        if (!audible) {
          debugPrint("Orpheus Deck: OVERDUB TRK $i SKIP - not audible");
          continue;
        }
        try {
          await _trackPlayers[i].setFilePath(_trackFiles[i]!);
          await _trackPlayers[i].setVolume(vol);
          await _trackPlayers[i]
              .seek(Duration(milliseconds: recordTapeStartMs));
          debugPrint(
              "Orpheus Deck: OVERDUB TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
          overdubIndices.add(i);
        } catch (e) {
          debugPrint("Orpheus Deck: OVERDUB TRK $i setFilePath ERROR - $e");
        }
      }

      // Concurrent just_audio (backing and/or CLICK) requires
      // [AudioInterruptionMode.none] or the recorder yields to playback and
      // records silence on some devices.

      final bool clickEnabled = _metronomeOn;
      final bool hasConcurrentPlayback = isOverdub || clickEnabled;
      final AudioInterruptionMode recordInterruptionMode = hasConcurrentPlayback
          ? AudioInterruptionMode.none
          : AudioInterruptionMode.pause;

      debugPrint(
          'Orpheus Deck: RECORD LAUNCH tapeStartMs=$recordTapeStartMs '
          'countInBarMs=$countInBarMs actualCountInMs=$actualCountInMs '
          'isOverdub=$isOverdub clickEnabled=$clickEnabled '
          'hasConcurrentPlayback=$hasConcurrentPlayback '
          'audioInterruption=$recordInterruptionMode');

      if (clickEnabled) {
        final int prepareSeekMs =
            actualCountInMs > 0 ? clickPreRollSeekMs : recordTapeStartMs;
        final ok = await _prepareClickPlayerAtTapeMs(prepareSeekMs,
            showBuildingUi: true);
        if (!ok) return;
        if (actualCountInMs > 0) {
          debugPrint(
              'Orpheus Deck: RECORD CLICK count-in ${actualCountInMs}ms '
              '(1 bar=${countInBarMs}ms) seekMs=$prepareSeekMs → tape=$recordTapeStartMs @ $_bpm BPM');
          await _clickPlayer.play();
          await Future.delayed(Duration(milliseconds: actualCountInMs));
          if (!mounted) {
            await _stopClickPlayback();
            return;
          }
        }
      }

      final Stopwatch sw = Stopwatch();
      sw.start();

      // A. Start recorder (after optional CLICK count-in).
      final recordCfg = _recordConfigForCurrentSession(recordInterruptionMode);
      debugPrint(
          'Orpheus Deck: RecordConfig json=${jsonEncode(recordCfg.toMap())}');
      try {
        await _recorder.start(
          recordCfg,
          path: path,
        );
        debugPrint(
            "Orpheus Deck: Recorder start CONFIRMED at ${sw.elapsedMilliseconds}ms path=$path");
        _pendingRecordStartTapeMs = recordTapeStartMs;
      } catch (e, st) {
        debugPrint(
            "Orpheus Deck: Recorder start ERROR $e\n$st");
        sw.stop();
        await _stopClickPlayback();
        return;
      }

      // B. Backing + CLICK aligned to [recordTapeStartMs] (CLICK may already be playing after count-in).
      if (overdubIndices.isNotEmpty) {
        debugPrint(
            "Orpheus Deck: Starting ${overdubIndices.length} backing players at tapeMs=$recordTapeStartMs");
        for (int i in overdubIndices) {
          await _trackPlayers[i].seek(Duration(milliseconds: recordTapeStartMs));
          _trackPlayers[i].play();
        }
      }

      if (clickEnabled) {
        try {
          await _clickPlayer.seek(Duration(milliseconds: recordTapeStartMs));
          await _clickPlayer.play();
          debugPrint(
              'Orpheus Deck: CLICK seek+play tapeMs=$recordTapeStartMs '
              'afterRecorder posMs=${_clickPlayer.position.inMilliseconds}');
        } catch (e, st) {
          debugPrint(
              'Orpheus Deck: CLICK seek+play after recorder FAILED $e\n$st');
          await _stopClickPlayback();
          _disableClickTrackDueToAudioConflict();
        }
      }

      sw.stop();

      final int measuredOffsetMs = sw.elapsedMilliseconds;
      setState(() {
        _trackOffsets[armedIndex] = measuredOffsetMs;
      });
      debugPrint(
          "Orpheus Deck: RECORD LAUNCH complete | delta=${measuredOffsetMs}ms "
          "track=$armedIndex recordStartTapeMs=$recordTapeStartMs "
          'countInBarMs=$countInBarMs actualCountInMs=$actualCountInMs');

      int recAmpLogTicks = 0;
      int clickBleedNearBeatLoudCount = 0;
      final int recAmpDiagTicks = clickEnabled ? 100 : 40;
      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 50))
          .listen((amp) {
        if (recAmpLogTicks < recAmpDiagTicks) {
          if (clickEnabled) {
            final recMs = recordTapeStartMs + recAmpLogTicks * 50;
            final mpb = 60000.0 / _bpm;
            final phase = recMs % mpb;
            final nearBeat = phase < 35 || phase > mpb - 35;
            final loudish = amp.current > -38;
            if (nearBeat && loudish) clickBleedNearBeatLoudCount++;
            debugPrint(
                'Orpheus Deck: REC amplitude tick=$recAmpLogTicks '
                'currentDb=${amp.current} nearBeatWindow=$nearBeat '
                'phaseMs=${phase.toStringAsFixed(0)} bpm=$_bpm '
                'nearBeatLoudCount=$clickBleedNearBeatLoudCount');
            if (recAmpLogTicks == recAmpDiagTicks - 1) {
              debugPrint(
                  'Orpheus Deck: REC CLICK bleed diag (${recAmpDiagTicks * 50}ms): '
                  'nearBeat+loudishCount=$clickBleedNearBeatLoudCount/$recAmpDiagTicks '
                  '(quiet room / covered mic: high count suggests capture-path bleed)');
            }
          } else {
            debugPrint(
                'Orpheus Deck: REC amplitude tick=$recAmpLogTicks '
                'currentDb=${amp.current} isOverdub=$isOverdub clickEnabled=$clickEnabled');
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

      final int tapeMax = _tapeTimelineMaxMs();
      final double prog =
          tapeMax > 0 ? (recordTapeStartMs / tapeMax).clamp(0.0, 1.0) : 0.0;
      setState(() {
        _isRecording = true;
        _isPlaying = true;
        _recordDuration = 0;
        _playbackMs = recordTapeStartMs;
        _playbackProgress = prog;
      });
      _startTicker();
    }
  }

  Future<void> _stop() async {
    if (_isExporting && _exportSessionId != null) {
      FFmpegKit.cancel(_exportSessionId);
      return;
    }

    bool recordedSomething = false;

    if (_isRecording) {
      _amplitudeSub?.cancel();
      final int? commitRecordTapeMs = _pendingRecordStartTapeMs;
      _pendingRecordStartTapeMs = null;
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
            setState(() {
              _trackFiles[armedIndex] = path;
              _waveformCache[path] = List.from(_liveAmplitudes);
              _armedTracks[armedIndex] = false;
              _trackRecordStartTapeMs[armedIndex] = commitRecordTapeMs ?? 0;
              recordedSomething = true;
            });
          } else {
            debugPrint("Orpheus Deck: Ignored silent/empty recording.");
            if (file.existsSync()) file.deleteSync();
            setState(() {
              _armedTracks[armedIndex] = false;
            });
          }
        }
      }
      _liveAmplitudes.clear();
    }

    for (var player in _trackPlayers) {
      await player.stop();
    }

    await _stopClickPlayback();

    _tickerTimer?.cancel();

    setState(() {
      _isPlaying = false;
      _isRecording = false;
    });

    if (recordedSomething) {
      _saveSession();
    }
  }

  void _resetTimer() {
    setState(() {
      _stop();
      _recordDuration = 0;
      _playbackProgress = 0.0;
      _playbackMs = 0;
    });
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
      _trackRecordStartTapeMs[index] = 0;
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
                duration: _recordDuration,
                projectName: _projectName,
                onProjectTap: _showProjectMenu,
                hasUndo: _lastUndo.hasUndo,
                onUndo: _performUndo,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: ListView.separated(
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
                        playbackProgress: _playbackProgress,
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
              const SizedBox(height: 16),
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
    final cfg = as_sess.AudioSessionConfiguration(
      avAudioSessionCategory: as_sess.AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          as_sess.AVAudioSessionCategoryOptions.defaultToSpeaker,
      avAudioSessionMode: as_sess.AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          as_sess.AVAudioSessionRouteSharingPolicy.defaultPolicy,
      androidAudioAttributes: const as_sess.AndroidAudioAttributes(
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

  Future<void> _testOverdubEngine() async {
    _showSnackbar('STARTING OVERDUB DIAGNOSTIC...');
    
    int? sourceIdx;
    for (int i=0; i<4; i++) {
      if (_trackFiles[i] != null) {
        sourceIdx = i;
        break;
      }
    }
    
    if (sourceIdx == null) {
      _showSnackbar('ERR: RECORD AT LEAST 1 TRACK FIRST');
      return;
    }

    final String sourcePath = _trackFiles[sourceIdx]!;
    debugPrint('Orpheus Deck: [DIAG] Source found at TRK $sourceIdx: $sourcePath');

    final dir = await getApplicationDocumentsDirectory();
    final testPath = '${dir.path}/overdub_test.m4a';
    final testFile = File(testPath);
    if (testFile.existsSync()) testFile.deleteSync();

    await _trackPlayers[sourceIdx].stop();
    await _trackPlayers[sourceIdx].setFilePath(sourcePath);
    await _trackPlayers[sourceIdx].setVolume(1.0);

    debugPrint('Orpheus Deck: [DIAG] Starting 10s overdub test...');
    final sw = Stopwatch();
    sw.start();

    debugPrint('Orpheus Deck: [DIAG] T+${sw.elapsedMilliseconds}ms - Requesting recorder start');
    try {
      await _recorder.start(const RecordConfig(), path: testPath);
      debugPrint('Orpheus Deck: [DIAG] T+${sw.elapsedMilliseconds}ms - Recorder confirmed');

      debugPrint('Orpheus Deck: [DIAG] T+${sw.elapsedMilliseconds}ms - Requesting playback start');
      _trackPlayers[sourceIdx].play();
      debugPrint('Orpheus Deck: [DIAG] T+${sw.elapsedMilliseconds}ms - Playback requested (fire-and-forget)');

      await Future.delayed(const Duration(seconds: 10));

      debugPrint('Orpheus Deck: [DIAG] T+${sw.elapsedMilliseconds}ms - Stopping test');
      await _recorder.stop();
      await _trackPlayers[sourceIdx].stop();
      sw.stop();

      final int size = File(testPath).existsSync() ? File(testPath).lengthSync() : 0;
      debugPrint('Orpheus Deck: [DIAG] Test complete. Saved file size: $size bytes');
      
      if (size > 1000) {
        _showSnackbar('DIAG SUCCESS: $size BYTES');
      } else {
        _showSnackbar('DIAG FAILURE: FILE EMPTY');
      }
    } catch (e) {
      debugPrint('Orpheus Deck: [DIAG] ERROR during test: $e');
      _showSnackbar('DIAG ERROR: $e');
      await _recorder.stop();
      await _trackPlayers[sourceIdx].stop();
      sw.stop();
    }
  }
}

class DeckHeader extends StatelessWidget {
  final String statusLabel;
  final int duration;
  final String projectName;
  final VoidCallback onProjectTap;
  final bool hasUndo;
  final VoidCallback onUndo;

  const DeckHeader({
    super.key,
    required this.statusLabel,
    required this.duration,
    required this.projectName,
    required this.onProjectTap,
    this.hasUndo = false,
    required this.onUndo,
  });

  String get _formattedTime {
    final m = (duration ~/ 60).toString().padLeft(2, '0');
    final s = (duration % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
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
              const SizedBox(height: 6),
              Row(
                children: [
                  GestureDetector(
                    onTap: onProjectTap,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        border: Border.all(color: Colors.white54, width: 1),
                      ),
                      child: Text(
                        "PROJECT: $projectName",
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
                "FOUR-TRACK RECORDER // MK-I",
                style: TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 8,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formattedTime,
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
  final double playbackProgress;

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
    required this.playbackProgress,
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
    String displayId = hasAudio
        ? filePath!.split(RegExp(r'[/\\]')).last.replaceAll('.m4a', '')
        : "";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 65,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "TRK\n0$trackNumber",
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    if (hasAudio) ...[
                      const SizedBox(height: 4),
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: const Text(
                          "M4A",
                          style: TextStyle(
                            color: Colors.black,
                            fontFamily: 'monospace',
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        displayId,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontFamily: 'monospace',
                          fontSize: 8,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ],
                  ],
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
                      playbackProgress: playbackProgress,
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

class WaveformDisplay extends StatelessWidget {
  final List<double> amplitudes;
  final bool isLive;
  final double playbackProgress;
  final bool isActive;

  const WaveformDisplay({
    super.key,
    required this.amplitudes,
    this.isLive = false,
    this.playbackProgress = 0.0,
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
            playbackProgress: playbackProgress,
            isActive: isActive,
          ),
        );
      },
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final bool isLive;
  final double playbackProgress;
  final bool isActive;

  WaveformPainter({
    required this.amplitudes,
    required this.isLive,
    required this.playbackProgress,
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isActive ? Colors.white : Colors.white24
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final playheadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0;

    final double midY = size.height / 2;

    if (amplitudes.isEmpty) {
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), paint);
      return;
    }

    final int maxVisibleBars = (size.width / 4).floor();

    if (isLive) {
      int startIndex = amplitudes.length > maxVisibleBars
          ? amplitudes.length - maxVisibleBars
          : 0;
      List<double> visibleAmps = amplitudes.sublist(startIndex);

      double startX = size.width;
      for (int i = visibleAmps.length - 1; i >= 0; i--) {
        double amp = visibleAmps[i];
        double barHeight = amp * size.height;
        if (barHeight < 2) barHeight = 2;

        canvas.drawLine(
          Offset(startX, midY - barHeight / 2),
          Offset(startX, midY + barHeight / 2),
          paint,
        );
        startX -= 4.0;
      }
    } else {
      List<double> renderAmps = [];

      if (amplitudes.length > maxVisibleBars) {
        int chunkSize = (amplitudes.length / maxVisibleBars).ceil();
        for (int i = 0; i < amplitudes.length; i += chunkSize) {
          double maxVal = 0;
          for (int j = i; j < i + chunkSize && j < amplitudes.length; j++) {
            if (amplitudes[j] > maxVal) maxVal = amplitudes[j];
          }
          renderAmps.add(maxVal);
        }
      } else {
        renderAmps = amplitudes;
      }

      double step = size.width / renderAmps.length;
      for (int i = 0; i < renderAmps.length; i++) {
        double amp = renderAmps[i];
        double barHeight = amp * size.height;
        if (barHeight < 2) barHeight = 2;
        double x = i * step;

        canvas.drawLine(
          Offset(x, midY - barHeight / 2),
          Offset(x, midY + barHeight / 2),
          paint,
        );
      }

      if (playbackProgress > 0.0 && playbackProgress <= 1.0 && isActive) {
        double playheadX = playbackProgress * size.width;
        canvas.drawLine(
          Offset(playheadX, 0),
          Offset(playheadX, size.height),
          playheadPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.amplitudes.length != amplitudes.length ||
        oldDelegate.playbackProgress != playbackProgress ||
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
      padding: const EdgeInsets.all(16),
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
