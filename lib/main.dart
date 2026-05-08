import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const OrpheusDeckApp());
}

/// The Session model to persist the app state
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
  List<String> exports;
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
      'exports': exports,
      'bpm': bpm,
      'metronomeOn': metronomeOn,
      'metronomeSound': metronomeSound,
    };
  }

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      projectName: json['projectName'] as String? ?? 'SESSION_001',
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
      updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt'] as String) : DateTime.now(),
      trackFiles: List<String?>.from(json['trackFiles'] as List),
      waveformCache: (json['waveformCache'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, List<double>.from(e as List)),
      ),
      trackIds: List<String?>.from(json['trackIds'] as List? ?? [null, null, null, null]),
      trackOffsets: List<int>.from(json['trackOffsets'] as List? ?? [0, 0, 0, 0]),
      trackVolumes: List<double>.from(json['trackVolumes'] as List? ?? [1.0, 1.0, 1.0, 1.0]),
      trackMutes: List<bool>.from(json['trackMutes'] as List? ?? [false, false, false, false]),
      trackSolos: List<bool>.from(json['trackSolos'] as List? ?? [false, false, false, false]),
      exports: List<String>.from(json['exports'] as List? ?? []),
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
          background: Colors.black,
        ),
      ),
      home: const OrpheusConsole(),
    );
  }
}

/// The main stateful console for the 4-track recorder.
class OrpheusConsole extends StatefulWidget {
  const OrpheusConsole({super.key});

  @override
  State<OrpheusConsole> createState() => _OrpheusConsoleState();
}

class _OrpheusConsoleState extends State<OrpheusConsole> {
  bool _isPlaying = false;
  bool _isRecording = false;
  bool _isExporting = false;
  int _recordDuration = 0;
  int? _exportSessionId;
  
  Timer? _tickerTimer;
  Timer? _metronomeTimer;
  Timer? _autosaveTimer;
  
  String _projectName = "SESSION_001";
  DateTime _sessionCreatedAt = DateTime.now();

  final List<bool> _armedTracks = [false, false, false, false];
  final List<String?> _trackFiles = [null, null, null, null];
  final List<double> _trackVolumes = [1.0, 1.0, 1.0, 1.0];
  final List<bool> _trackMutes = [false, false, false, false];
  final List<bool> _trackSolos = [false, false, false, false];
  List<String> _exports = [];

  // Metronome & Settings
  int _bpm = 120;
  bool _metronomeOn = false;
  String _metronomeSound = 'CLICK';
  bool _headphonesConfirmed = false;
  
  late AudioPlayer _metronomePlayer;
  String _beepPath = '';
  String _clickPath = '';
  String _woodPath = '';

  final AudioRecorder _recorder = AudioRecorder();
  final List<AudioPlayer> _players = List.generate(4, (_) => AudioPlayer());

  final Map<String, List<double>> _waveformCache = {};
  List<double> _liveAmplitudes = [];
  StreamSubscription<Amplitude>? _amplitudeSub;
  
  double _playbackProgress = 0.0;
  int _playbackMs = 0;

  @override
  void initState() {
    super.initState();
    _metronomePlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _metronomePlayer.setPlayerMode(PlayerMode.lowLatency);
    _initMetronome();
    _loadSession();
    
    // Auto-save protection loop
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
    _recorder.dispose();
    _metronomePlayer.dispose();
    for (var player in _players) {
      player.dispose();
    }
    super.dispose();
  }

  Uint8List _generateWav(int frequency, int durationMs, String type) {
    int sampleRate = 44100;
    int numSamples = (sampleRate * durationMs) ~/ 1000;
    int byteRate = sampleRate * 2;
    
    var buffer = ByteData(44 + numSamples * 2);
    buffer.setUint8(0, 0x52); buffer.setUint8(1, 0x49); buffer.setUint8(2, 0x46); buffer.setUint8(3, 0x46); 
    buffer.setUint32(4, 36 + numSamples * 2, Endian.little);
    buffer.setUint8(8, 0x57); buffer.setUint8(9, 0x41); buffer.setUint8(10, 0x56); buffer.setUint8(11, 0x45); 
    buffer.setUint8(12, 0x66); buffer.setUint8(13, 0x6D); buffer.setUint8(14, 0x74); buffer.setUint8(15, 0x20); 
    buffer.setUint32(16, 16, Endian.little); 
    buffer.setUint16(20, 1, Endian.little); 
    buffer.setUint16(22, 1, Endian.little); 
    buffer.setUint32(24, sampleRate, Endian.little); 
    buffer.setUint32(28, byteRate, Endian.little); 
    buffer.setUint16(32, 2, Endian.little); 
    buffer.setUint16(34, 16, Endian.little); 
    buffer.setUint8(36, 0x64); buffer.setUint8(37, 0x61); buffer.setUint8(38, 0x74); buffer.setUint8(39, 0x61); 
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
        sample = (sin(2 * pi * frequency * t) + 0.5 * sin(2 * pi * (frequency * 2.5) * t)) * pow(envelope, 3);
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
      _metronomePlayer.play(DeviceFileSource(path));
    }
  }

  void _startMetronomeTicker() {
    _metronomeTimer?.cancel();
    if (!_metronomeOn) return;
    int msPerBeat = (60000 / _bpm).round();
    _playMetronomeTick(); 
    _metronomeTimer = Timer.periodic(Duration(milliseconds: msPerBeat), (Timer t) {
      _playMetronomeTick();
    });
  }

  void _stopMetronomeTicker() {
    _metronomeTimer?.cancel();
  }

  // --- Project Management & Persistence ---

  Future<String> _getLastProjectName() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/OrpheusDeck/last_project.txt');
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {}
    return "SESSION_001";
  }

  Future<void> _setLastProjectName(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/OrpheusDeck/last_project.txt');
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(name);
    } catch (e) {}
  }

  Future<void> _recoverOrphanedRecordings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (await projDir.exists()) {
        final files = projDir.listSync();
        bool recovered = false;
        for (var file in files) {
          if (file is File && file.path.endsWith('.m4a') && file.path.contains('track_')) {
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
                    debugPrint("Orpheus Deck: RECOVERY LOG - Recovered orphaned recording to track $trackIndex: ${file.path}");
                  } else {
                    debugPrint("Orpheus Deck: RECOVERY LOG - Ignored older orphan for track $trackIndex: ${file.path}");
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
    } catch (e) {
      debugPrint("Orpheus Deck: RECOVERY LOG - Error during recovery: $e");
    }
  }

  Future<void> _loadSession() async {
    try {
      _projectName = await _getLastProjectName();
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
              debugPrint("Warning: File missing for track $i at $trackPath");
              session.trackFiles[i] = null;
              session.waveformCache.remove(trackPath);
            }
          }
        }
        
        setState(() {
          _projectName = session.projectName;
          _sessionCreatedAt = session.createdAt;
          for (int i = 0; i < 4; i++) {
            _trackFiles[i] = session.trackFiles[i];
            _trackVolumes[i] = session.trackVolumes[i];
            _trackMutes[i] = session.trackMutes[i];
            _trackSolos[i] = session.trackSolos[i];
          }
          _waveformCache.addAll(session.waveformCache);
          
          _exports = List<String>.from(session.exports);
          _exports.removeWhere((path) => !File(path).existsSync());

          _bpm = session.bpm;
          _metronomeOn = session.metronomeOn;
          _metronomeSound = session.metronomeSound;
          _headphonesConfirmed = false;
        });
        debugPrint("Orpheus Deck: Session loaded successfully from ${file.path}");
      } else {
        debugPrint("Orpheus Deck: No existing session found for $_projectName. Starting fresh.");
      }
      
      await _recoverOrphanedRecordings();
      _updateMixerState();
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
        trackOffsets: [0, 0, 0, 0],
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
      
      // Atomic save to prevent corruption if app crashes during write
      await tempFile.writeAsString(jsonEncode(session.toJson()), flush: true);
      await tempFile.rename(finalFile.path);
      
      await _setLastProjectName(_projectName);
    } catch (e) {
      debugPrint("Orpheus Deck: Error saving session: $e");
    }
  }

  Future<void> _renameProject(String newName) async {
    if (newName.trim().isEmpty || newName == _projectName) return;
    _stop();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final oldDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      final newDir = Directory('${dir.path}/OrpheusDeck/$newName');
      
      if (await oldDir.exists()) {
        await oldDir.rename(newDir.path);
        
        Map<String, List<double>> newCache = {};
        for (int i = 0; i < 4; i++) {
          if (_trackFiles[i] != null) {
            String oldPath = _trackFiles[i]!;
            String newPath = oldPath.replaceFirst('/OrpheusDeck/$_projectName/', '/OrpheusDeck/$newName/');
            _trackFiles[i] = newPath;
            if (_waveformCache.containsKey(oldPath)) {
              newCache[newPath] = _waveformCache[oldPath]!;
            }
          }
        }
        _waveformCache.clear();
        _waveformCache.addAll(newCache);

        List<String> newExports = [];
        for (String exportPath in _exports) {
          String newPath = exportPath.replaceFirst('/OrpheusDeck/$_projectName/', '/OrpheusDeck/$newName/');
          newExports.add(newPath);
        }
        _exports.clear();
        _exports.addAll(newExports);
      }
      
      setState(() {
        _projectName = newName;
      });
      await _saveSession();
      _showSnackbar("PROJECT RENAMED");
    } catch(e) {
      _showSnackbar("ERR: RENAME FAILED");
      debugPrint("Rename error: $e");
    }
  }

  Future<void> _newProject(String name) async {
    if (name.trim().isEmpty) return;
    _stop();
    setState(() {
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
    });
    _updateMixerState();
    await _saveSession();
    _showSnackbar("NEW PROJECT CREATED");
  }

  Future<void> _exportMix(bool isYoutubeMaster) async {
    if (_isRecording || _isPlaying) _stop();
    
    setState(() {
      _isExporting = true;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final projDir = Directory('${dir.path}/OrpheusDeck/$_projectName');
      if (!await projDir.exists()) await projDir.create(recursive: true);

      String timestamp = (DateTime.now().millisecondsSinceEpoch).toString();
      String outName = isYoutubeMaster ? "youtube_master_$timestamp.wav" : "raw_mix_$timestamp.wav";
      String outPath = '${projDir.path}/$outName';

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
        filterGraph += ";${mixInputs}amix=inputs=$activeCount:duration=longest,volume=$activeCount[mix]";
        outPad = "[mix]";
      }

      if (isYoutubeMaster) {
        filterGraph += ";${outPad}loudnorm=I=-14:TP=-1:LRA=11[master]";
        outPad = "[master]";
      }

      List<String> command = [
        ...inputs,
        "-filter_complex", filterGraph,
        "-map", outPad,
        outPath
      ];

      FFmpegKit.executeWithArgumentsAsync(command, (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          setState(() {
            _exports.add(outPath);
          });
          _saveSession();
          _showExportSuccessDialog(outPath);
        } else if (ReturnCode.isCancel(returnCode)) {
          final file = File(outPath);
          if (file.existsSync()) file.deleteSync();
          _showSnackbar("EXPORT CANCELED");
          debugPrint("Orpheus Deck: RECOVERY LOG - Export canceled safely.");
        } else {
          final logs = await session.getLogsAsString();
          debugPrint("Orpheus Deck: RECOVERY LOG - FFmpeg Error: $logs");
          _showSnackbar("ERR: EXPORT FAILED");
        }
        setState(() {
          _isExporting = false;
          _exportSessionId = null;
        });
      }).then((session) {
        _exportSessionId = session.getSessionId();
      });
    } catch (e) {
      debugPrint("Export error: $e");
      _showSnackbar("ERR: EXPORT FAILED");
      setState(() {
        _isExporting = false;
      });
    }
  }

  void _showExportSuccessDialog(String path) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: const Text("EXPORT COMPLETE", style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
          content: SelectableText(
            "Saved to:\n$path",
            style: const TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 10),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Share.shareXFiles([XFile(path)], text: 'Exported from Orpheus Deck');
              },
              child: const Text("SHARE", style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
  }

  void _showExportOptionsDialog(String path) {
    String filename = path.split(RegExp(r'[/\\]')).last;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: Text(filename, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
          content: const Text("What would you like to do?", style: TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 10)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                final file = File(path);
                if (file.existsSync()) {
                  file.deleteSync();
                }
                setState(() {
                  _exports.remove(path);
                });
                _saveSession();
                _showSnackbar("EXPORT DELETED");
              },
              child: const Text("DELETE", style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Share.shareXFiles([XFile(path)], text: 'Exported from Orpheus Deck');
              },
              child: const Text("SHARE", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
  }

  void _showMetronomeMenu() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: Border.all(color: Colors.white, width: 2),
              title: const Text("METRONOME", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Row(
                     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                     children: [
                       const Text("STATUS", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
                       GestureDetector(
                         onTap: () {
                           setState(() => _metronomeOn = !_metronomeOn);
                           setDialogState(() {});
                           _saveSession();
                         },
                         child: Container(
                           padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                           decoration: BoxDecoration(
                             color: _metronomeOn ? Colors.white : Colors.black,
                             border: Border.all(color: Colors.white),
                           ),
                           child: Text(_metronomeOn ? "ON" : "OFF", style: TextStyle(color: _metronomeOn ? Colors.black : Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                         )
                       )
                     ]
                   ),
                   const SizedBox(height: 16),
                   Row(
                     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                     children: [
                       const Text("BPM", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
                       Row(
                         children: [
                           IconButton(
                             icon: const Icon(Icons.remove, color: Colors.white),
                             onPressed: () {
                               if (_bpm > 40) {
                                 setState(() => _bpm--);
                                 setDialogState(() {});
                                 _saveSession();
                               }
                             }
                           ),
                           Text("$_bpm", style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.bold)),
                           IconButton(
                             icon: const Icon(Icons.add, color: Colors.white),
                             onPressed: () {
                               if (_bpm < 240) {
                                 setState(() => _bpm++);
                                 setDialogState(() {});
                                 _saveSession();
                               }
                             }
                           ),
                         ]
                       )
                     ]
                   ),
                   const SizedBox(height: 16),
                   Row(
                     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                     children: [
                       const Text("SOUND", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
                       DropdownButton<String>(
                         value: _metronomeSound,
                         dropdownColor: Colors.black,
                         style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
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
                     ]
                   )
                ]
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("CLOSE", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _showProjectMenu() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: const Text(
            "PROJECT MGMT", 
            style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _menuButton("RENAME PROJECT", () {
                  Navigator.pop(context);
                  _showNameDialog("RENAME PROJECT", _projectName, _renameProject);
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
                _menuButton("EXPORT YT MASTER", () {
                  Navigator.pop(context);
                  _exportMix(true);
                }),
                const SizedBox(height: 16),
                Container(height: 1, color: Colors.white24),
                const SizedBox(height: 16),
                const Text("EXPORTS", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                if (_exports.isEmpty)
                  const Text("NO EXPORTS YET", style: TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 10), textAlign: TextAlign.center)
                else
                  ..._exports.map((path) {
                    String filename = path.split(RegExp(r'[/\\]')).last;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: _menuButton(filename, () {
                        Navigator.pop(context);
                        _showExportOptionsDialog(path);
                      }),
                    );
                  }).toList(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CLOSE", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
            ),
          ],
        );
      }
    );
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
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showNameDialog(String title, String initialText, Function(String) onSubmit) {
    TextEditingController ctrl = TextEditingController(text: initialText);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: Text(title, style: const TextStyle(color: Colors.white, fontFamily: 'monospace')),
          content: TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCEL", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                onSubmit(ctrl.text);
              },
              child: const Text("SAVE", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
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

  // --- Transport, Audio & Mixer Logic ---

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
      _players[i].setVolume(targetVolume);
    }
  }

  void _setVolume(int index, double value) {
    setState(() {
      _trackVolumes[index] = value;
    });
    _updateMixerState();
    _saveSession();
  }

  void _toggleMute(int index) {
    setState(() {
      _trackMutes[index] = !_trackMutes[index];
    });
    _updateMixerState();
    _saveSession();
  }

  void _toggleSolo(int index) {
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
      if (_trackFiles[i] != null && _waveformCache.containsKey(_trackFiles[i]!)) {
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
    if (_trackFiles[index] != null && _waveformCache.containsKey(_trackFiles[index])) {
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
      
      _updateMixerState(); 
      
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null) {
          await _players[i].setSourceDeviceFile(_trackFiles[i]!);
          await _players[i].resume();
        }
      }
      _startTicker();
      _startMetronomeTicker();
    }
  }

  void _showHeadphonesWarning() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: Border.all(color: Colors.white, width: 2),
          title: const Text("WARNING", style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
          content: const Text("USE HEADPHONES FOR OVERDUB TO PREVENT AUDIO BLEED.", style: TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 12)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCEL", style: TextStyle(color: Colors.white54, fontFamily: 'monospace')),
            ),
            TextButton(
              onPressed: () {
                setState(() => _headphonesConfirmed = true);
                Navigator.pop(context);
                _record(); 
              },
              child: const Text("I AM USING HEADPHONES", style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
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
      String shortTimestamp = (DateTime.now().millisecondsSinceEpoch % 10000000).toString();
      final path = '${projDir.path}/track_${armedIndex}_$shortTimestamp.m4a';

      _updateMixerState(); 

      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null && i != armedIndex) {
          await _players[i].setSourceDeviceFile(_trackFiles[i]!);
          await _players[i].resume();
        }
      }

      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

      _amplitudeSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 50)).listen((amp) {
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
          setState(() {
            _trackFiles[armedIndex] = path;
            _waveformCache[path] = List.from(_liveAmplitudes);
            _armedTracks[armedIndex] = false; 
            recordedSomething = true;
          });
        }
      }
      _liveAmplitudes.clear();
    }

    for (var player in _players) {
      await player.stop();
    }

    setState(() {
      _isPlaying = false;
      _isRecording = false;
      _tickerTimer?.cancel();
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

  void _clearTrack(int index) {
    if (_isRecording || _isPlaying) {
      _showSnackbar('ERR: STOP TRANSPORT TO CLEAR');
      return;
    }
    if (_trackFiles[index] != null) {
      final file = File(_trackFiles[index]!);
      if (file.existsSync()) {
        file.deleteSync();
      }
      setState(() {
        _waveformCache.remove(_trackFiles[index]);
        _trackFiles[index] = null;
      });
      _showSnackbar('TRK 0${index + 1} CLEARED');
      _saveSession();
    }
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
}

/// The OLED display header showing timer, project name, and status.
class DeckHeader extends StatelessWidget {
  final String statusLabel;
  final int duration;
  final String projectName;
  final VoidCallback onProjectTap;

  const DeckHeader({
    super.key,
    required this.statusLabel,
    required this.duration,
    required this.projectName,
    required this.onProjectTap,
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
          // Branding & Project Name
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
              GestureDetector(
                onTap: onProjectTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
          
          // Timer and Status
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
                    (statusLabel == 'RECORDING' || statusLabel == 'OVERDUB' || statusLabel == 'EXPORTING')
                        ? "● $statusLabel"
                        : statusLabel,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: statusLabel != 'IDLE' ? FontWeight.bold : FontWeight.normal,
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

/// A single track strip with an arm button, real waveform view, clear option, and basic mixer controls.
class TrackStrip extends StatelessWidget {
  final int trackNumber;
  final bool isArmed;
  final bool isPlaying;
  final bool isRecording;
  final String? filePath;
  final List<double> amplitudes;
  final double playbackProgress;
  
  // Mixer properties
  final double volume;
  final bool isMuted;
  final bool isSoloed;
  
  final VoidCallback onArmToggled;
  final VoidCallback onClear;
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
    required this.onVolumeChanged,
    required this.onMuteToggled,
    required this.onSoloToggled,
  });

  bool get _isWaveformActive {
    bool hasAudio = filePath != null;
    if (isRecording) {
      if (isArmed) return true;
      if (hasAudio) return true; // Overdub playback
      return false;
    } else {
      return isPlaying && hasAudio;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool hasAudio = filePath != null;
    String displayId = hasAudio ? filePath!.split(RegExp(r'[/\\]')).last.replaceAll('.m4a', '') : "";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          // Main Deck Row
          Row(
            children: [
              // Track Label & File info
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
              
              // Arm Button
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

              // Reusable Waveform Widget
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
              
              // Clear Button
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

          // Mixer Controls Row
          Row(
            children: [
              const SizedBox(width: 65), // Alignment spacer
              
              // Mute Button
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
              
              // Solo Button
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
              
              // Volume Slider
              const Text("VOL", style: TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 10)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: onVolumeChanged,
                  ),
                ),
              ),
              
              // Spacing alignment for right side to match clear button
              if (hasAudio) const SizedBox(width: 48),
            ],
          ),
        ],
      ),
    );
  }
}

/// A reusable widget that renders a list of audio amplitudes into a monochrome waveform.
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

/// Lightweight custom painter optimized for Android to draw waveform bars and a playhead.
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
      int startIndex = amplitudes.length > maxVisibleBars ? amplitudes.length - maxVisibleBars : 0;
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

/// The bottom hardware buttons for transport control.
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

/// A custom button widget for transport controls, styled like Adafruit hardware switches.
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
