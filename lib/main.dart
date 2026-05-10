/// ORPHEUS DECK
/// Junkfeathers Tech Four-Track Recorder
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audio_session/audio_session.dart' as as_sess;

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
                                                "Junkfeathers Tech Multitrack Recorder",
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
  Timer? _metronomeTimer;
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
  bool _headphonesConfirmed = false;

  late AudioPlayer _metronomePlayer;
  String _beepPath = '';
  String _clickPath = '';
  String _woodPath = '';

  final AudioRecorder _recorder = AudioRecorder();

  /// Independent just_audio players — one per track. Using just_audio
  /// instead of audioplayers because just_audio handles concurrent
  /// Android AudioFocus correctly without stealing the session from siblings.
  final List<ja.AudioPlayer> _trackPlayers =
      List.generate(4, (_) => ja.AudioPlayer());

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
    _metronomePlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _initMetronome();
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
    _metronomeTimer?.cancel();
    _autosaveTimer?.cancel();
    _amplitudeSub?.cancel();
    for (var sub in _playerCompletionSubs) {
      sub?.cancel();
    }

    if (_isRecording) {
      _recorder.stop();
    }
    _recorder.dispose();

    _metronomePlayer.dispose();
    for (var player in _trackPlayers) {
      player.dispose();
    }

    if (_isExporting && _exportSessionId != null) {
      FFmpegKit.cancel(_exportSessionId);
    }
    super.dispose();
  }

  Uint8List _generateWav(int frequency, int durationMs, String type) {
    int sampleRate = 44100;
    int numSamples = (sampleRate * durationMs) ~/ 1000;
    int byteRate = sampleRate * 2;

    var buffer = ByteData(44 + numSamples * 2);
    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46);
    buffer.setUint32(4, 36 + numSamples * 2, Endian.little);
    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45);
    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20);
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61);
    buffer.setUint32(40, numSamples * 2, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      double t = i / sampleRate;
      double sample = 0;
      double envelope = 1.0 - (i / numSamples);

      if (type == 'BEEP') {
        sample = sin(2 * pi * frequency * t);
      } else if (type == 'CLICK') {
        sample = (Random().nextDouble() * 2 - 1) * envelope;
      } else if (type == 'WOOD') {
        sample = (sin(2 * pi * frequency * t) +
                0.5 * sin(2 * pi * (frequency * 2.5) * t)) *
            pow(envelope, 3);
      }

      int val = (sample * 32767).toInt();
      if (val > 32767) val = 32767;
      if (val < -32768) val = -32768;
      buffer.setInt16(44 + i * 2, val, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  Future<void> _initMetronome() async {
    final dir = await getTemporaryDirectory();

    File fBeep = File('${dir.path}/beep.wav');
    await fBeep.writeAsBytes(_generateWav(880, 50, 'BEEP'));
    _beepPath = fBeep.path;

    File fClick = File('${dir.path}/click.wav');
    await fClick.writeAsBytes(_generateWav(0, 15, 'CLICK'));
    _clickPath = fClick.path;

    File fWood = File('${dir.path}/wood.wav');
    await fWood.writeAsBytes(_generateWav(400, 30, 'WOOD'));
    _woodPath = fWood.path;
  }

  void _playMetronomeTick() {
    String path = _clickPath;
    if (_metronomeSound == 'BEEP') path = _beepPath;
    if (_metronomeSound == 'WOOD') path = _woodPath;
    if (path.isNotEmpty) {
      debugPrint("Orpheus Deck: METRONOME TICK - $_metronomeSound");
      _metronomePlayer.stop().then((_) {
        _metronomePlayer.play(DeviceFileSource(path));
      });
    }
  }

  void _startMetronomeTicker() {
    _metronomeTimer?.cancel();
    if (!_metronomeOn) return;
    int msPerBeat = (60000 / _bpm).round();

    debugPrint("Orpheus Deck: METRONOME STARTING at $_bpm BPM");

    if (_isRecording) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!_isRecording || !_metronomeOn) return;
        _playMetronomeTick();
        _metronomeTimer =
            Timer.periodic(Duration(milliseconds: msPerBeat), (Timer t) {
          _playMetronomeTick();
        });
      });
    } else {
      _playMetronomeTick();
      _metronomeTimer =
          Timer.periodic(Duration(milliseconds: msPerBeat), (Timer t) {
        _playMetronomeTick();
      });
    }
  }

  void _stopMetronomeTicker() {
    _metronomeTimer?.cancel();
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
    }
    _waveformCache.clear();
    _exports.clear();
    _headphonesConfirmed = false;
    _recordDuration = 0;
    _playbackProgress = 0.0;
    _playbackMs = 0;
    _lastUndo.clear();

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
          _headphonesConfirmed = false;
        });
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
    final uriStr = e.storageUri;
    if (uriStr != null && uriStr.startsWith('content://')) {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromUri(Uri.parse(uriStr))],
        text: 'Exported from Orpheus Deck',
      ));
      return;
    }
    if (e.absolutePath != null && File(e.absolutePath!).existsSync()) {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(e.absolutePath!)],
        text: 'Exported from Orpheus Deck',
      ));
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

  Future<void> _exportMix(bool isMasterMix) async {
    if (_isRecording || _isPlaying) _stop();

    setState(() {
      _isExporting = true;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      debugPrint('Orpheus Deck: FFmpeg temp write dir: ${tempDir.path}');

      String timestamp = (DateTime.now().millisecondsSinceEpoch).toString();
      String outName = isMasterMix
          ? "mastermix_$timestamp.wav"
          : "raw_mix_$timestamp.wav";
      String outPath = '${tempDir.path}/orpheus_exp_$timestamp.wav';

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

  void _showMetronomeMenu() {
    showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: Border.all(color: Colors.white, width: 2),
              title: const Text("METRONOME",
                  style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold)),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("STATUS",
                          style: TextStyle(
                              color: Colors.white54, fontFamily: 'monospace')),
                      GestureDetector(
                          onTap: () {
                            setState(() => _metronomeOn = !_metronomeOn);
                            setDialogState(() {});
                            _saveSession();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: _metronomeOn ? Colors.white : Colors.black,
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
                              color: Colors.white54, fontFamily: 'monospace')),
                      Row(children: [
                        IconButton(
                            icon: const Icon(Icons.remove, color: Colors.white),
                            onPressed: () {
                              if (_bpm > 40) {
                                setState(() => _bpm--);
                                setDialogState(() {});
                                _saveSession();
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
                            onPressed: () {
                              if (_bpm < 240) {
                                setState(() => _bpm++);
                                setDialogState(() {});
                                _saveSession();
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
                              color: Colors.white54, fontFamily: 'monospace')),
                      DropdownButton<String>(
                        value: _metronomeSound,
                        dropdownColor: Colors.black,
                        style: const TextStyle(
                            color: Colors.white, fontFamily: 'monospace'),
                        underline: Container(height: 1, color: Colors.white54),
                        items: ['CLICK', 'BEEP', 'WOOD'].map((String val) {
                          return DropdownMenuItem<String>(
                            value: val,
                            child: Text(val),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _metronomeSound = val);
                            setDialogState(() {});
                            _playMetronomeTick();
                            _saveSession();
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
        int maxMs = _getMaxPlaybackDuration();
        if (maxMs > 0) {
          setState(() {
            _playbackMs += 50;
            _playbackProgress = _playbackMs / maxMs;
            if (_playbackProgress > 1.0) _playbackProgress = 1.0;
          });
        }
      }
      if (t.tick % 20 == 0) {
        setState(() {
          _recordDuration++;
        });
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

      _startTicker();
      _startMetronomeTicker();
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

    if (_metronomeOn) {
      _showSnackbar("METRONOME DISABLED DURING RECORDING ON THIS BUILD");
      _metronomePlayer.stop();
      _stopMetronomeTicker();
      setState(() => _metronomeOn = false);
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

      _updateMixerState();

      // Stop all just_audio track players and reset position.
      for (var p in _trackPlayers) {
        await p.stop();
        await p.seek(Duration.zero);
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
          debugPrint(
              "Orpheus Deck: OVERDUB TRK $i setFilePath OK | state: ${_trackPlayers[i].processingState}");
          overdubIndices.add(i);
        } catch (e) {
          debugPrint("Orpheus Deck: OVERDUB TRK $i setFilePath ERROR - $e");
        }
      }

      // ── OVERDUB LAUNCH (FIXED SEQUENCING) ────────────────────────────────
      // Strategy: 
      // 1. Prepare backing players (seek zero, set volume).
      // 2. Start recorder and WAIT for confirmation.
      // 3. Immediately start backing playback without awaiting it to finish.
      
      debugPrint("Orpheus Deck: OVERDUB LAUNCH - starting recorder first");
      debugPrint(
          'Orpheus Deck: record audioInterruption=${isOverdub ? AudioInterruptionMode.none : AudioInterruptionMode.pause} (isOverdub=$isOverdub)');
      final Stopwatch sw = Stopwatch();
      sw.start();
      
      // A. Start recorder
      try {
        await _recorder.start(
          RecordConfig(
            encoder: AudioEncoder.aacLc,
            numChannels: 1,
            sampleRate: 44100,
            bitRate: 128000,
            audioInterruption: isOverdub
                ? AudioInterruptionMode.none
                : AudioInterruptionMode.pause,
          ),
          path: path,
        );
        debugPrint("Orpheus Deck: Recorder confirmed started at ${sw.elapsedMilliseconds}ms");
      } catch (e) {
        debugPrint("Orpheus Deck: Recorder start ERROR - $e");
        sw.stop();
        return;
      }

      // B. Start backing playback immediately after recorder confirms
      if (overdubIndices.isNotEmpty) {
        debugPrint("Orpheus Deck: Starting ${overdubIndices.length} backing players");
        // We do NOT await the futures here, just fire and forget so they play 
        // while the recorder is running.
        for (int i in overdubIndices) {
           _trackPlayers[i].play(); 
        }
      }
      
      sw.stop();

      // 2. Measure and store the offset.
      final int measuredOffsetMs = sw.elapsedMilliseconds;
      setState(() {
        _trackOffsets[armedIndex] = measuredOffsetMs;
      });
      debugPrint(
          "Orpheus Deck: OVERDUB LAUNCH complete | recorder+players delta: ${measuredOffsetMs}ms | offset stored for track $armedIndex");

      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 50))
          .listen((amp) {
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
        _recordDuration = 0;
        _playbackMs = 0;
        _playbackProgress = 0.0;
      });
      _startTicker();
      _startMetronomeTicker();
    }
  }

  Future<void> _stop() async {
    if (_isExporting && _exportSessionId != null) {
      FFmpegKit.cancel(_exportSessionId);
      return;
    }

    _stopMetronomeTicker();
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
              "Orpheus Deck: Recorder stopped. File size: $fileSize bytes at $path");

          if (fileSize > 0 &&
              _liveAmplitudes.isNotEmpty &&
              _liveAmplitudes.any((a) => a > 0.03)) {
            setState(() {
              _trackFiles[armedIndex] = path;
              _waveformCache[path] = List.from(_liveAmplitudes);
              _armedTracks[armedIndex] = false;
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

    _tickerTimer?.cancel();
    _metronomeTimer?.cancel();

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
                isMetronomeOn: _metronomeOn,
                onPlay: _play,
                onStop: _stop,
                onStopLongPress: _resetTimer,
                onRecord: _record,
                onMetro: _showMetronomeMenu,
              ),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _initAudioSession() async {
    final session = await as_sess.AudioSession.instance;
    await session.configure(as_sess.AudioSessionConfiguration(
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
    ));
    debugPrint("Orpheus Deck: Audio session configured for playAndRecord");
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
                "JUNKFEATHERS TECH // MK-I",
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
  final bool isMetronomeOn;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onStopLongPress;
  final VoidCallback onRecord;
  final VoidCallback onMetro;

  const TransportControls({
    super.key,
    required this.isPlaying,
    required this.isRecording,
    required this.isMetronomeOn,
    required this.onPlay,
    required this.onStop,
    required this.onStopLongPress,
    required this.onRecord,
    required this.onMetro,
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
            label: "METRO",
            icon: Icons.timer,
            isActive: isMetronomeOn,
            onTap: onMetro,
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
