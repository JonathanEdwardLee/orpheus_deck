import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  runApp(const OrpheusDeckApp());
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
  Timer? _timer;

  // Track state: keeps track of which tracks are currently armed for recording
  final List<bool> _armedTracks = [false, false, false, false];
  
  // Track files: keeps track of the local file paths for recorded audio
  final List<String?> _trackFiles = [null, null, null, null];

  // Audio recording and playback instances
  final AudioRecorder _recorder = AudioRecorder();
  final List<AudioPlayer> _players = List.generate(4, (_) => AudioPlayer());

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    for (var player in _players) {
      player.dispose();
    }
    super.dispose();
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

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      setState(() {
        _recordDuration++;
      });
    });
  }

  String get _deckStatus {
    if (_isRecording) {
      return _trackFiles.any((file) => file != null) ? "OVERDUB" : "RECORDING";
    } else if (_isPlaying) {
      return "PLAYBACK";
    }
    return "IDLE";
  }

  Future<void> _play() async {
    if (_isRecording) return; // Prevent normal playing while recording
    if (!_isPlaying) {
      setState(() {
        _isPlaying = true;
        _recordDuration = 0; // Reset timer for playback from the beginning
      });
      
      // Start playback for any track that has a recorded file
      for (int i = 0; i < 4; i++) {
        if (_trackFiles[i] != null) {
          await _players[i].setSourceDeviceFile(_trackFiles[i]!);
          await _players[i].resume();
        }
      }
      _startTimer();
    }
  }

  Future<void> _record() async {
    if (_isRecording) return; // Already recording
    
    int armedCount = _armedTracks.where((isArmed) => isArmed).length;
    if (armedCount != 1) {
      _showSnackbar('ERR: EXACTLY 1 TRACK MUST BE ARMED');
      return;
    }

    int armedIndex = _armedTracks.indexOf(true);
    
    // Prevent recording over an existing track unless cleared
    if (_trackFiles[armedIndex] != null) {
      _showSnackbar('ERR: TRACK FULL. CLEAR FIRST.');
      return;
    }

    // Request microphone permission
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

      setState(() {
        _isRecording = true;
        _isPlaying = true; // Overdub implies playback is active
        _recordDuration = 0;
      });
      _startTimer();
    }
  }

  Future<void> _stop() async {
    // Stop recording and save file path
    if (_isRecording) {
      final path = await _recorder.stop();
      if (path != null) {
        int armedIndex = _armedTracks.indexOf(true);
        if (armedIndex != -1) {
          setState(() {
            _trackFiles[armedIndex] = path;
            _armedTracks[armedIndex] = false; // Auto-disarm after recording
          });
        }
      }
    }

    // Stop all audio players
    for (var player in _players) {
      await player.stop();
    }

    setState(() {
      _isPlaying = false;
      _isRecording = false;
      _timer?.cancel();
    });
  }

  void _resetTimer() {
    setState(() {
      _stop();
      _recordDuration = 0;
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
        _trackFiles[index] = null;
      });
      _showSnackbar('TRK 0${index + 1} CLEARED');
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
              // Top Section: Header & Display
              DeckHeader(
                statusLabel: _deckStatus,
                duration: _recordDuration,
              ),
              const SizedBox(height: 16),
              
              // Middle Section: Tracks
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
                        onArmToggled: () => _toggleArmTrack(index),
                        onClear: () => _clearTrack(index),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Bottom Section: Transport Controls
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

/// The OLED display header showing timer and status.
class DeckHeader extends StatelessWidget {
  final String statusLabel;
  final int duration;

  const DeckHeader({
    super.key,
    required this.statusLabel,
    required this.duration,
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
          // Branding
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "ORPHEUS DECK",
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                  letterSpacing: 2,
                ),
              ),
              SizedBox(height: 4),
              Text(
                "JUNKFEATHERS TECH // MK-I",
                style: TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 10,
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

/// A single track strip with an arm button, waveform placeholder, and clear option.
class TrackStrip extends StatelessWidget {
  final int trackNumber;
  final bool isArmed;
  final bool isPlaying;
  final bool isRecording;
  final String? filePath;
  final VoidCallback onArmToggled;
  final VoidCallback onClear;

  const TrackStrip({
    super.key,
    required this.trackNumber,
    required this.isArmed,
    required this.isPlaying,
    required this.isRecording,
    required this.filePath,
    required this.onArmToggled,
    required this.onClear,
  });

  /// Logic to determine if this specific track's waveform should animate
  bool get _isWaveformActive {
    bool hasAudio = filePath != null;
    if (isRecording) {
      if (isArmed) return true;
      if (hasAudio) return true; // Overdub playback
      return false;
    } else {
      // During standard playback, animate if it has audio and we are playing
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

          // Waveform Placeholder
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Colors.white54, width: 1),
              ),
              child: WaveformPlaceholder(
                isActive: _isWaveformActive,
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

/// A decorative waveform that animates slightly when active.
class WaveformPlaceholder extends StatelessWidget {
  final bool isActive;

  const WaveformPlaceholder({super.key, required this.isActive});

  @override
  Widget build(BuildContext context) {
    // A simple row of vertical bars to simulate a waveform
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(30, (index) {
        // Pseudo-random heights for the waveform
        final heightMultiplier = [0.3, 0.8, 0.5, 0.9, 0.4, 1.0, 0.6, 0.2][index % 8];
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 3,
          height: isActive ? 30 * heightMultiplier : 2,
          color: isActive ? Colors.white : Colors.white24,
        );
      }),
    );
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
