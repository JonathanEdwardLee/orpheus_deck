import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';

import 'orpheus_native_audio.dart';
import 'orpheus_native_bindings.dart';
import 'orpheus_native_duplex_bindings.dart';
import 'orpheus_native_labels.dart';

/// Hidden Phase N1/N2 dev screen — not linked from normal user flow.
class OrpheusNativeTestScreen extends StatefulWidget {
  const OrpheusNativeTestScreen({super.key});

  @override
  State<OrpheusNativeTestScreen> createState() =>
      _OrpheusNativeTestScreenState();
}

class _OrpheusNativeTestScreenState extends State<OrpheusNativeTestScreen> {
  static const int _n1RecordMs = 2500;

  bool _busy = false;
  String _log = 'Ready.';
  OrpheusNativeDiagnosticsData? _n1Diag;
  OrpheusDuplexDiagnosticsData? _n2Diag;

  Future<void> _runHandshake() async {
    setState(() {
      _busy = true;
      _log = 'Running N1 Oboe handshake…';
      _n1Diag = null;
      _n2Diag = null;
    });
    try {
      final diag = await OrpheusNativeAudio.instance.runHandshake(
        recordDurationMs: _n1RecordMs,
      );
      final path = OrpheusNativeAudio.instance.lastWavPath;
      if (!mounted) return;
      setState(() {
        _n1Diag = diag;
        _log = 'N1 success.\n'
            'WAV (~${(_n1RecordMs / 1000).toStringAsFixed(1)} s record): $path\n\n'
            '${OrpheusNativeLabels.formatDiagnosticsSummary(diag)}';
      });
    } catch (e, st) {
      debugPrint('Orpheus N1 handshake failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _log = 'N1 failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _runDuplex() async {
    setState(() {
      _busy = true;
      _log = 'Running N2 full-duplex overdub…';
      _n2Diag = null;
    });
    try {
      final diag = await OrpheusNativeAudio.instance.runDuplexTest();
      final path = OrpheusNativeAudio.instance.lastN2WavPath;
      if (!mounted) return;
      setState(() {
        _n2Diag = diag;
        _log = 'N2 success.\n'
            'Backing: 6 clicks / 6 s generated natively (48 kHz mono).\n'
            'Recorded WAV: $path\n\n'
            '${OrpheusNativeLabels.formatDuplexSummary(diag)}\n\n'
            '${OrpheusNativeLabels.formatTimingAnalysis(diag)}';
      });
    } catch (e, st) {
      debugPrint('Orpheus N2 duplex failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _log = 'N2 failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openWav(String? path) async {
    if (path != null) {
      await OpenFile.open(path);
    }
  }

  Future<void> _shareWav(String? path) async {
    if (path == null || !File(path).existsSync()) {
      return;
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Orpheus N2 duplex test WAV'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n1Path = OrpheusNativeAudio.instance.lastWavPath;
    final n2Path = OrpheusNativeAudio.instance.lastN2WavPath;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Native Audio Test (N1 / N2)',
          style: TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Dev-only native Oboe tests.\n'
              'Does not affect the main four-track recorder.\n\n'
              'N1 RECORDS A SHORT NATIVE TEST WAV.\n'
              'N2 PLAYS NATIVE CLICK BACKING AND RECORDS MIC AT THE SAME TIME.\n'
              'N2B MEASURES CLICK ALIGNMENT IN THE RECORDED WAV (ENGINEERING).\n'
              'USE PHONE SPEAKER SO THE MIC CAN HEAR CLICKS.\n'
              'NEITHER USES YOUR CURRENT PROJECT OR FOUR-TRACK SESSION.',
              style: TextStyle(
                color: Colors.white54,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _runHandshake,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              child: Text(
                _busy ? 'RUNNING…' : 'RUN N1 HANDSHAKE',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy ? null : _runDuplex,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white24,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'RUN N2 FULL-DUPLEX TEST (+ N2B TIMING)',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (n1Path != null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _openWav(n1Path),
                    child: const Text(
                      'OPEN N1 WAV',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            if (n2Path != null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _openWav(n2Path),
                    child: const Text(
                      'OPEN N2 WAV',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _shareWav(n2Path),
                    child: const Text(
                      'SHARE N2 WAV',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _log,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ),
            ),
            if (_n1Diag != null) ...[
              const Divider(color: Colors.white24),
              Text(
                'N1 raw:\n${_rawN1Block(_n1Diag!)}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
            if (_n2Diag != null) ...[
              const Divider(color: Colors.white24),
              Text(
                'N2 raw:\n${_rawN2Block(_n2Diag!)}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _rawN1Block(OrpheusNativeDiagnosticsData d) {
    return 'sampleRate=${d.sampleRate}\n'
        'framesPerBurst=${d.framesPerBurst}\n'
        'bufferSizeInFrames=${d.bufferSizeInFrames}\n'
        'xRunCount=${d.xRunCount}\n'
        'apiUsed=${d.apiUsed}\n'
        'performanceMode=${d.performanceMode}\n'
        'sharingMode=${d.sharingMode}\n'
        'wavWriteSuccess=${d.wavWriteSuccess}';
  }

  String _rawN2Block(OrpheusDuplexDiagnosticsData d) {
    return 'sampleRate=${d.sampleRate}\n'
        'framesPerBurst=${d.framesPerBurst}\n'
        'bufferSizeInFrames=${d.bufferSizeInFrames}\n'
        'xRunCount=${d.xRunCount}\n'
        'apiUsed=${d.apiUsed}\n'
        'performanceMode=${d.performanceMode}\n'
        'sharingMode=${d.sharingMode}\n'
        'backingFramesGenerated=${d.backingFramesGenerated}\n'
        'recordedFramesWritten=${d.recordedFramesWritten}\n'
        'transportStartSample=${d.transportStartSample}\n'
        'transportStopSample=${d.transportStopSample}\n'
        'outputCallbackCount=${d.outputCallbackCount}\n'
        'inputCallbackCount=${d.inputCallbackCount}\n'
        'firstOutputFrameSample=${d.firstOutputFrameSample}\n'
        'firstInputFrameSample=${d.firstInputFrameSample}\n'
        'estimatedInputOutputDeltaSamples=${d.estimatedInputOutputDeltaSamples}\n'
        'backingPlaySuccess=${d.backingPlaySuccess}\n'
        'recordSuccess=${d.recordSuccess}\n'
        'wavWriteSuccess=${d.wavWriteSuccess}\n'
        'clicksExpected=${d.clicksExpected}\n'
        'clicksDetected=${d.clicksDetected}\n'
        'analysisSuccess=${d.analysisSuccess}\n'
        'analysisFailureReason=${d.analysisFailureReason}\n'
        'medianOffsetSamples=${d.medianOffsetSamples}\n'
        'medianOffsetMsTimes1000=${d.medianOffsetMsTimes1000}\n'
        'spreadSamples=${d.spreadSamples}\n'
        'confidencePercent=${d.confidencePercent}\n'
        'recordLatencyOffsetSamples=${d.recordLatencyOffsetSamples}';
  }
}

/// Opens the hidden native test UI (Android debug builds).
void openOrpheusNativeTestScreen(BuildContext context) {
  if (!Platform.isAndroid) {
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const OrpheusNativeTestScreen(),
    ),
  );
}
