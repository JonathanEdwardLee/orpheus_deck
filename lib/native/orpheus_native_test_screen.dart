import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';

import 'orpheus_native_audio.dart';
import 'orpheus_native_bindings.dart';

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
        _log = 'Success.\nWAV: $path\n'
            'rate=${diag.sampleRate} burst=${diag.framesPerBurst} '
            'buf=${diag.bufferSizeInFrames} xruns=${diag.xRunCount}\n'
            'api=${OrpheusNativeAudio.apiLabel(diag.apiUsed)} '
            'perf=${OrpheusNativeAudio.performanceLabel(diag.performanceMode)} '
            'sharing=${OrpheusNativeAudio.sharingLabel(diag.sharingMode)}';
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
              'Does not affect the main four-track recorder.',
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
                'Diagnostics struct:\n'
                'sampleRate=${_diag!.sampleRate}\n'
                'framesPerBurst=${_diag!.framesPerBurst}\n'
                'bufferSizeInFrames=${_diag!.bufferSizeInFrames}\n'
                'xRunCount=${_diag!.xRunCount}\n'
                'performanceMode=${_diag!.performanceMode}\n'
                'sharingMode=${_diag!.sharingMode}\n'
                'apiUsed=${_diag!.apiUsed}\n'
                'inputStreamOpened=${_diag!.inputStreamOpened}\n'
                'outputStreamOpened=${_diag!.outputStreamOpened}\n'
                'wavWriteSuccess=${_diag!.wavWriteSuccess}',
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
