import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';

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

  Session({
    required this.projectName,
    required this.createdAt,
    required this.updatedAt,
    required this.trackFiles,
    required this.waveformCache,
    required this.trackIds,
    required this.trackOffsets,
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
    };
  }

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      projectName: json['projectName'] as String? ?? 'UNTITLED_PROJECT',
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
      updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt'] as String) : DateTime.now(),
      trackFiles: List<String?>.from(json['trackFiles'] as List),
      waveformCache: (json['waveformCache'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, List<double>.from(e as List)),
      ),
      trackIds: List<String?>.from(json['trackIds'] as List? ?? [null, null, null, null]),
      trackOffsets: List<int>.from(json['trackOffsets'] as List? ?? [0, 0, 0, 0]),
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
        // Enforcing the monochrome OLED style globally
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
  int _recordDuration = 0;
  
  // Ticker for smooth waveform and playhead updates
  Timer? _tickerTimer;
  
  // Session data
  String _projectName = "SESSION_001";
  DateTime _sessionCreatedAt = DateTime.now();

  // Audio state
  final List<bool> _armedTracks = [false, false, false, false];
  final List<String?> _trackFiles = [null, null, null, null];
  final AudioRecorder _recorder = AudioRecorder();
  final List<AudioPlayer> _players = List.generate(4, (_) => AudioPlayer());

  // Waveform caching and live recording state
  final Map<String, List<double>> _waveformCache = {};
  List<double> _liveAmplitudes = [];
  StreamSubscription<Amplitude>? _amplitudeSub;
  
  // Playback sync
  double _playbackProgress = 0.0;
  int _playbackMs = 0;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _amplitudeSub?.cancel();
    _recorder.dispose();
    for (var player in _players) {
      player.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSession() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/session.json');
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final session = Session.fromJson(jsonDecode(jsonString));
        
        // Verify files actually exist on disk, otherwise mark track empty
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
          }
          _waveformCache.addAll(session.waveformCache);
        });
        debugPrint("Orpheus Deck: Session loaded successfully from ${file.path}");
      } else {
        debugPrint("Orpheus Deck: No existing session found. Starting fresh.");
      }
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
      );
      
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/session.json');
      await file.writeAsString(jsonEncode(session.toJson()));
      debugPrint("Orpheus Deck: Session saved successfully to ${file.path}");
    } catch (e) {
      debugPrint("Orpheus Deck: Error saving session: $e");
    }
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

  /// High-frequency ticker (50ms) to update waveforms, playhead, and the seconds timer.
  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 50), (Timer t) {
      // Update playback progress
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

      // Update seconds display
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
        // We know we sampled amplitude every 50ms, so duration = length * 50
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
    if (_isRecording) return; 
    if (!_isPlaying) {
      setState(() {
        _isPlaying = true;
        _recordDuration = 0; 
        _playbackMs = 0;
        _playbackProgress = 0.0;
      });
      
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null) {
          await _players[i].setSourceDeviceFile(_trackFiles[i]!);
          await _players[i].resume();
        }
      }
      _startTicker();
    }
  }

  Future<void> _record() async {
    if (_isRecording) return;
    
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

    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showSnackbar('ERR: MIC PERMISSION DENIED');
      return;
    }

    if (await _recorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();
      String shortTimestamp = (DateTime.now().millisecondsSinceEpoch % 10000000).toString();
      final path = '${dir.path}/track_${armedIndex}_$shortTimestamp.m4a';

      // Start playback for any existing tracks before recording starts (Overdub)
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null && i != armedIndex) {
          await _players[i].setSourceDeviceFile(_trackFiles[i]!);
          await _players[i].resume();
        }
      }

      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

      // Listen to real-time amplitude stream to draw the live waveform
      _amplitudeSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 50)).listen((amp) {
        setState(() {
          // Normalize DB to 0.0 - 1.0 (Approx -45dB floor)
          double normalized = (amp.current + 45) / 45;
          if (normalized < 0.02) normalized = 0.02; // Small noise floor visual
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
    }
  }

  Future<void> _stop() async {
    bool recordedSomething = false;

    if (_isRecording) {
      _amplitudeSub?.cancel();
      final path = await _recorder.stop();
      if (path != null) {
        int armedIndex = _armedTracks.indexOf(true);
        if (armedIndex != -1) {
          setState(() {
            _trackFiles[armedIndex] = path;
            // Cache the recorded amplitude waveform data
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
        _waveformCache.remove(_trackFiles[index]); // clear cache
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
                        onArmToggled: () => _toggleArmTrack(index),
                        onClear: () => _clearTrack(index),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TransportControls(
                isPlaying: _isPlaying,
                isRecording: _isRecording,
                onPlay: _play,
                onStop: _stop,
                onStopLongPress: _resetTimer,
                onRecord: _record,
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

  const DeckHeader({
    super.key,
    required this.statusLabel,
    required this.duration,
    required this.projectName,
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
              const SizedBox(height: 4),
              Text(
                "PROJECT: $projectName",
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
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
                    (statusLabel == 'RECORDING' || statusLabel == 'OVERDUB')
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

/// A single track strip with an arm button, real waveform view, and clear option.
class TrackStrip extends StatelessWidget {
  final int trackNumber;
  final bool isArmed;
  final bool isPlaying;
  final bool isRecording;
  final String? filePath;
  final List<double> amplitudes;
  final double playbackProgress;
  final VoidCallback onArmToggled;
  final VoidCallback onClear;

  const TrackStrip({
    super.key,
    required this.trackNumber,
    required this.isArmed,
    required this.isPlaying,
    required this.isRecording,
    required this.filePath,
    required this.amplitudes,
    required this.playbackProgress,
    required this.onArmToggled,
    required this.onClear,
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
    String displayId = hasAudio ? filePath!.split('_').last.replaceAll('.m4a', '') : "";

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
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
      // Draw a flat line if no audio data is present
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), paint);
      return;
    }

    final int maxVisibleBars = (size.width / 4).floor(); // 4 pixels per bar spacing

    if (isLive) {
      // Scrolling waveform from right to left during active recording
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
      // Static waveform scaled to fit the full width during playback
      List<double> renderAmps = [];
      
      // Downsample amplitudes if they exceed the physical width to maintain performance
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

      // Draw Playhead Indicator overlay
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
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onStopLongPress;
  final VoidCallback onRecord;

  const TransportControls({
    super.key,
    required this.isPlaying,
    required this.isRecording,
    required this.onPlay,
    required this.onStop,
    required this.onStopLongPress,
    required this.onRecord,
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
        width: 80,
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
                fontSize: 12,
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
