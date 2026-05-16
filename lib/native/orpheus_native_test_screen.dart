import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';

import 'orpheus_native_audio.dart';
import 'orpheus_native_bindings.dart';
import 'orpheus_native_labels.dart';

/// Hidden Phase N1 dev screen — not linked from normal user flow.
class OrpheusNativeTestScreen extends StatefulWidget {
  const OrpheusNativeTestScreen({super.key});

  @override
  State<OrpheusNativeTestScreen> createState() =>
      _OrpheusNativeTestScreenState();
}

class _OrpheusNativeTestScreenState extends State<OrpheusNativeTestScreen> {
  bool _busy = false;
  String _log = 'Ready.';
  OrpheusNativeDiagnosticsData? _diag;

  Future<void> _runHandshake() async {
    setState(() {
      _busy = true;
      _log = 'Running N1 Oboe handshake…';
      _diag = null;
    });
    try {
      final diag = await OrpheusNativeAudio.instance.runHandshake();
      final path = OrpheusNativeAudio.instance.lastWavPath;
      if (!mounted) return;
      setState(() {
        _diag = diag;
        _log = 'Success.\n'
            'WAV (~${(diag.actualSampleRate * 2.5 / 1000).toStringAsFixed(1)} s target): $path\n\n'
            '${OrpheusNativeLabels.formatDiagnosticsSummary(diag)}';
      });
    } catch (e, st) {
      debugPrint('Orpheus N1 handshake failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _log = 'Failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Native Audio Test (N1)',
          style: TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Phase N1 Oboe handshake — dev only.\n'
              'Does not affect the main four-track recorder.\n\n'
              'N1 RECORDS A SHORT NATIVE TEST WAV.\n'
              'IT DOES NOT USE YOUR CURRENT PROJECT.\n'
              'IT DOES NOT RENDER OR PLAY THE FOUR-TRACK SESSION.',
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
            const SizedBox(height: 12),
            if (OrpheusNativeAudio.instance.lastWavPath != null)
              TextButton(
                onPressed: () {
                  final p = OrpheusNativeAudio.instance.lastWavPath;
                  if (p != null) {
                    OpenFile.open(p);
                  }
                },
                child: const Text(
                  'OPEN LAST WAV',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
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
            if (_diag != null) ...[
              const Divider(color: Colors.white24),
              Text(
                _rawDiagnosticsBlock(_diag!),
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

  String _rawDiagnosticsBlock(OrpheusNativeDiagnosticsData d) {
    return 'Raw struct fields:\n'
        'sampleRate=${d.sampleRate}\n'
        'actualSampleRate=${d.actualSampleRate}\n'
        'requestedSampleRate=${d.requestedSampleRate}\n'
        'framesPerBurst=${d.framesPerBurst}\n'
        'bufferSizeInFrames=${d.bufferSizeInFrames}\n'
        'xRunCount=${d.xRunCount}\n'
        'performanceMode=${d.performanceMode}\n'
        'actualPerformanceMode=${d.actualPerformanceMode}\n'
        'requestedPerformanceMode=${d.requestedPerformanceMode}\n'
        'sharingMode=${d.sharingMode}\n'
        'actualSharingMode=${d.actualSharingMode}\n'
        'requestedSharingMode=${d.requestedSharingMode}\n'
        'apiUsed=${d.apiUsed}\n'
        'exclusiveAttempted=${d.exclusiveAttempted}\n'
        'sharedFallbackUsed=${d.sharedFallbackUsed}\n'
        'unspecifiedAudioApi=${d.unspecifiedAudioApi}\n'
        'lastOpenErrorCode=${d.lastOpenErrorCode}\n'
        'androidSdkVersion=${d.androidSdkVersion}\n'
        'inputStreamOpened=${d.inputStreamOpened}\n'
        'outputStreamOpened=${d.outputStreamOpened}\n'
        'wavWriteSuccess=${d.wavWriteSuccess}';
  }
}

/// Opens the hidden N1 test UI (Android debug builds).
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
