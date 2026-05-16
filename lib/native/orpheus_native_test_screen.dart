import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';

import 'orpheus_native_audio.dart';
import 'orpheus_native_bindings.dart';
import 'orpheus_native_duplex_bindings.dart';
import 'orpheus_native_labels.dart';
import 'orpheus_native_latency_profile.dart';

/// Hidden Phase N1/N2 dev screen — not linked from normal user flow.
class OrpheusNativeTestScreen extends StatefulWidget {
  const OrpheusNativeTestScreen({super.key});

  @override
  State<OrpheusNativeTestScreen> createState() =>
      _OrpheusNativeTestScreenState();
}

class _OrpheusNativeTestScreenState extends State<OrpheusNativeTestScreen> {
  static const int _n1RecordMs = 2500;

  static const TextStyle _mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    height: 1.4,
  );

  static const TextStyle _monoSmall = TextStyle(
    fontFamily: 'monospace',
    fontSize: 10,
    height: 1.35,
    color: Colors.white38,
  );

  bool _busy = false;
  bool _showRawDetails = false;
  String _status = 'Ready.';
  OrpheusNativeDiagnosticsData? _n1Diag;
  OrpheusDuplexDiagnosticsData? _n2Diag;
  OrpheusLatencyProfileResult? _n2eProfile;

  Future<void> _runHandshake() async {
    setState(() {
      _busy = true;
      _status = 'Running N1 Oboe handshake…';
      _n1Diag = null;
      _n2Diag = null;
      _showRawDetails = false;
    });
    try {
      final diag = await OrpheusNativeAudio.instance.runHandshake(
        recordDurationMs: _n1RecordMs,
      );
      final path = OrpheusNativeAudio.instance.lastWavPath;
      if (!mounted) return;
      setState(() {
        _n1Diag = diag;
        _status = 'N1 complete.\nWAV (~${(_n1RecordMs / 1000).toStringAsFixed(1)} s): $path';
      });
    } catch (e, st) {
      debugPrint('Orpheus N1 handshake failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _status = 'N1 failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _runCalibrationProfile() async {
    setState(() {
      _busy = true;
      _status = 'Running N2E calibration profile (pass 1/3)…';
      _n2eProfile = null;
      _showRawDetails = false;
    });
    try {
      final profile = await OrpheusNativeAudio.instance.runCalibrationProfile(
        onPassStarted: (current, total) {
          if (!mounted) return;
          setState(() {
            _status = 'Running N2E calibration profile (pass $current/$total)…';
          });
        },
      );
      final lastPass = profile.passes.isNotEmpty
          ? profile.passes.last.diagnostics
          : null;
      if (!mounted) return;
      setState(() {
        _n2eProfile = profile;
        if (lastPass != null) {
          _n2Diag = lastPass;
        }
        if (profile.profileSuccess) {
          _status =
              'N2E complete.\n'
              'Recommended: ${profile.recommendedOffsetSamples} samples '
              '(${profile.recommendedOffsetMs?.toStringAsFixed(1)} ms).';
        } else {
          _status = 'N2E profile failed — see instructions below.';
        }
      });
    } catch (e, st) {
      debugPrint('Orpheus N2E profile failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _status = 'N2E failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _copyRecommendedOffset() async {
    final line = OrpheusNativeLabels.copyRecommendedOffsetLine(_n2eProfile!);
    if (line.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: line));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Copied dev-only offset line (not applied to main recorder).',
          style: TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _runDuplex() async {
    setState(() {
      _busy = true;
      _status = 'Running N2 full-duplex + N2B timing…';
      _n2Diag = null;
      _showRawDetails = false;
    });
    try {
      final diag = await OrpheusNativeAudio.instance.runDuplexTest();
      final path = OrpheusNativeAudio.instance.lastN2WavPath;
      if (!mounted) return;
      setState(() {
        _n2Diag = diag;
        _status = 'N2 complete.\nRecorded WAV: $path';
      });
    } catch (e, st) {
      debugPrint('Orpheus N2 duplex failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _status = 'N2 failed: $e';
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

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        text,
        style: _mono.copyWith(
          color: Colors.white54,
          fontSize: 10,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _summaryLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label: $value',
        style: _mono.copyWith(color: Colors.white70),
      ),
    );
  }

  Widget _buildN1Summary(OrpheusNativeDiagnosticsData d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('N1 SUMMARY'),
        _summaryLine('API', OrpheusNativeLabels.apiUsed(d.apiUsed)),
        _summaryLine(
          'Performance',
          OrpheusNativeLabels.performanceMode(d.actualPerformanceMode),
        ),
        _summaryLine(
          'Sharing',
          OrpheusNativeLabels.sharingMode(d.actualSharingMode),
        ),
        _summaryLine('Sample rate', '${d.actualSampleRate} Hz'),
        _summaryLine('XRuns', '${d.xRunCount}'),
        _summaryLine('Burst / buffer', '${d.framesPerBurst} / ${d.bufferSizeInFrames}'),
      ],
    );
  }

  Color _profileQualityColor(String label) {
    switch (label) {
      case 'GOOD':
        return Colors.greenAccent;
      case 'OK':
        return Colors.lightGreenAccent;
      default:
        return Colors.orangeAccent;
    }
  }

  Widget _buildN2eProfile(OrpheusLatencyProfileResult p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('N2E PROFILE'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            color: Colors.white.withValues(alpha: 0.06),
          ),
          child: Text(
            OrpheusNativeLabels.formatLatencyProfile(p),
            style: _mono.copyWith(
              color: _profileQualityColor(p.qualityLabel),
              fontWeight: FontWeight.bold,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ...p.passes.map(
          (pass) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              OrpheusNativeLabels.formatN2ePassSummary(pass),
              style: _mono.copyWith(
                color: pass.isGood ? Colors.white54 : Colors.orangeAccent,
              ),
            ),
          ),
        ),
        if (p.profileSuccess) ...[
          const SizedBox(height: 8),
          SelectableText(
            OrpheusNativeLabels.copyRecommendedOffsetLine(p),
            style: _mono.copyWith(color: Colors.white38),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _busy ? null : _copyRecommendedOffset,
            child: const Text(
              'COPY RECOMMENDED OFFSET (DEV ONLY)',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildN2Summary(OrpheusDuplexDiagnosticsData d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('N2 STREAM SUMMARY'),
        _summaryLine('API', OrpheusNativeLabels.apiUsed(d.apiUsed)),
        _summaryLine(
          'Performance',
          OrpheusNativeLabels.performanceMode(d.performanceMode),
        ),
        _summaryLine(
          'Sharing',
          OrpheusNativeLabels.sharingMode(d.sharingMode),
        ),
        _summaryLine('Sample rate', '${d.sampleRate} Hz'),
        _summaryLine('XRuns', '${d.xRunCount}'),
        _summaryLine('Burst / buffer', '${d.framesPerBurst} / ${d.bufferSizeInFrames}'),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            color: Colors.white.withValues(alpha: 0.06),
          ),
          child: Text(
            OrpheusNativeLabels.formatTimingAnalysis(d),
            style: _mono.copyWith(
              color: d.analysisSuccess == 1 ? Colors.white : Colors.orangeAccent,
              fontWeight: FontWeight.bold,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            color: Colors.white.withValues(alpha: 0.06),
          ),
          child: Text(
            OrpheusNativeLabels.formatCompensationProof(d),
            style: _mono.copyWith(
              color: d.compensatedAlignmentSuccess == 1
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
              fontWeight: FontWeight.bold,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRawDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _showRawDetails = !_showRawDetails),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(
                  _showRawDetails ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white54,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  'RAW DETAILS',
                  style: _mono.copyWith(
                    color: Colors.white54,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showRawDetails) ...[
          if (_n1Diag != null)
            Text(
              'N1 raw:\n${_rawN1Block(_n1Diag!)}',
              style: _monoSmall,
            ),
          if (_n1Diag != null && _n2Diag != null) const SizedBox(height: 12),
          if (_n2Diag != null)
            Text(
              'N2 raw:\n${_rawN2Block(_n2Diag!)}',
              style: _monoSmall,
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final n1Path = OrpheusNativeAudio.instance.lastWavPath;
    final n2Path = OrpheusNativeAudio.instance.lastN2WavPath;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

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
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
          children: [
            Text(
              'Dev-only native Oboe tests.\n'
              'Does not affect the main four-track recorder.\n\n'
              'N1 RECORDS A SHORT NATIVE TEST WAV.\n'
              'N2 PLAYS NATIVE CLICK BACKING AND RECORDS MIC AT THE SAME TIME.\n'
              'N2B MEASURES CLICK ALIGNMENT (ENGINEERING VALIDATION).\n'
              'N2D PROVES COMPENSATION ZEROS RESIDUAL OFFSET.\n'
              'N2E RUNS 3 PASSES AND PICKS A RECOMMENDED ROUTE OFFSET.\n'
              'NEITHER USES YOUR CURRENT PROJECT OR FOUR-TRACK SESSION.',
              style: _mono.copyWith(color: Colors.white54),
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
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                'FOR TIMING ANALYSIS:\n'
                'USE PHONE SPEAKER.\n'
                'TURN VOLUME UP.\n'
                'KEEP ROOM QUIET.\n'
                'MIC MUST HEAR THE CLICKS.',
                style: _mono.copyWith(
                  color: Colors.white54,
                  fontWeight: FontWeight.bold,
                  height: 1.45,
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
            FilledButton(
              onPressed: _busy ? null : _runCalibrationProfile,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal.shade900,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'RUN N2E CALIBRATION PROFILE',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (n1Path != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openWav(n1Path),
                  child: const Text(
                    'OPEN N1 WAV',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
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
            const SizedBox(height: 8),
            _sectionTitle('STATUS'),
            Text(
              _status,
              style: _mono.copyWith(color: Colors.white70),
            ),
            if (_n1Diag != null) _buildN1Summary(_n1Diag!),
            if (_n2Diag != null) _buildN2Summary(_n2Diag!),
            if (_n2eProfile != null) _buildN2eProfile(_n2eProfile!),
            if (_n1Diag != null || _n2Diag != null) ...[
              const Divider(color: Colors.white24, height: 24),
              _buildRawDetails(),
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
        'recordLatencyOffsetSamples=${d.recordLatencyOffsetSamples}\n'
        'appliedCompensationSamples=${d.appliedCompensationSamples}\n'
        'compensatedMedianResidualSamples=${d.compensatedMedianResidualSamples}\n'
        'compensatedResidualSpreadSamples=${d.compensatedResidualSpreadSamples}\n'
        'compensatedAlignmentSuccess=${d.compensatedAlignmentSuccess}\n'
        'compensatedQualityPercent=${d.compensatedQualityPercent}\n'
        '${OrpheusNativeLabels.formatPerClickOffsets(d)}';
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
