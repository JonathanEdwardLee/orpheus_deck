import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Two-part transport: **tape position window** (tuner / locator) +
/// **cassette reel window** (emotional mechanism). Not a DAW timeline.
class TapeReelTransport extends StatefulWidget {
  const TapeReelTransport({
    super.key,
    required this.playbackMs,
    required this.tapeLengthMs,
    required this.isPlaying,
    required this.isRecording,
    required this.seekEnabled,
    required this.onTapeSeekMs,
  });

  final int playbackMs;
  final int tapeLengthMs;
  final bool isPlaying;
  final bool isRecording;
  final bool seekEnabled;
  final ValueChanged<int> onTapeSeekMs;

  @override
  State<TapeReelTransport> createState() => _TapeReelTransportState();
}

class _TapeReelTransportState extends State<TapeReelTransport>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _spinRamp;

  bool get _spinning => widget.isPlaying || widget.isRecording;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _spinRamp = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 320),
    );
    if (_spinning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _spinRamp.forward();
        _spin.repeat();
      });
    }
  }

  @override
  void didUpdateWidget(TapeReelTransport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.isPlaying || oldWidget.isRecording;
    if (_spinning && !was) {
      if (mounted) {
        _spinRamp.forward();
        _spin.repeat();
      }
    } else if (!_spinning && was) {
      _spin.stop();
      _spinRamp.reverse();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _spinRamp.dispose();
    super.dispose();
  }

  double get _progress {
    if (widget.tapeLengthMs <= 0) return 0;
    return (widget.playbackMs / widget.tapeLengthMs).clamp(0.0, 1.0);
  }

  double get _spinMul =>
      0.2 + 0.8 * Curves.easeOutCubic.transform(_spinRamp.value);

  void _seekFromLocalDx(double dx, double width) {
    if (width <= 0) return;
    final frac = (dx / width).clamp(0.0, 1.0);
    final ms =
        (frac * widget.tapeLengthMs).round().clamp(0, widget.tapeLengthMs);
    widget.onTapeSeekMs(ms);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TapePositionPanel(
          progress: _progress,
          tapeLengthMs: widget.tapeLengthMs,
          seekEnabled: widget.seekEnabled && !_spinning,
          transportActive: _spinning,
          onSeekDx: _seekFromLocalDx,
        ),
        const SizedBox(height: 10),
        _CassetteMechanismPanel(
          progress: _progress,
          spinning: _spinning,
          spinAnimation: _spin,
          spinMul: _spinMul,
        ),
      ],
    );
  }
}

// --- TOP: tape locator (separate from reels; radio-deck / tuner feel) ---

class _TapePositionPanel extends StatelessWidget {
  const _TapePositionPanel({
    required this.progress,
    required this.tapeLengthMs,
    required this.seekEnabled,
    required this.transportActive,
    required this.onSeekDx,
  });

  final double progress;
  final int tapeLengthMs;
  final bool seekEnabled;
  final bool transportActive;
  final void Function(double dx, double width) onSeekDx;

  @override
  Widget build(BuildContext context) {
    const trackH = 28.0;
    const labelH = 12.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: transportActive
              ? Colors.white.withValues(alpha: 0.42)
              : Colors.white.withValues(alpha: 0.22),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: trackH,
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: seekEnabled
                      ? (e) => onSeekDx(e.localPosition.dx, w)
                      : null,
                  onHorizontalDragUpdate: seekEnabled
                      ? (d) => onSeekDx(d.localPosition.dx, w)
                      : null,
                  child: CustomPaint(
                    size: Size(w, trackH),
                    painter: _TapeLocatorTrackPainter(
                      progress: progress,
                      transportActive: transportActive,
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: labelH,
            child: CustomPaint(
              painter: _TapeLocatorLabelsPainter(),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TapeLocatorTrackPainter extends CustomPainter {
  _TapeLocatorTrackPainter({
    required this.progress,
    required this.transportActive,
  });

  final double progress;
  final bool transportActive;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final y = size.height * 0.55;
    final p = progress.clamp(0.0, 1.0);
    final headX = w <= 12 ? w * 0.5 : (p * w).clamp(6.0, w - 6.0);

    // Inner channel (tuner window)
    final chTop = y - 5;
    final chBot = y + 5;
    canvas.drawRect(
      Rect.fromLTWH(0, chTop, w, chBot - chTop),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.06)
        ..style = PaintingStyle.fill,
    );

    final baseStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y), Offset(w, y), baseStroke);

    // Minute ticks: small every minute, larger every 5
    for (int m = 1; m < 15; m++) {
      final x = w * (m / 15.0);
      final major = m % 5 == 0;
      final h = major ? 7.0 : 3.5;
      canvas.drawLine(
        Offset(x, y - h),
        Offset(x, y + h),
        Paint()
          ..color = Colors.white.withValues(alpha: major ? 0.32 : 0.16)
          ..strokeWidth = 1,
      );
    }

    // Locator — slides with position; slightly brighter when transport runs
    final locA = transportActive ? 0.95 : 0.78;
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(headX, y),
        width: 2,
        height: 14,
      ),
      Paint()..color = Colors.white.withValues(alpha: locA),
    );
    canvas.drawLine(
      Offset(headX - 4, y),
      Offset(headX + 4, y),
      Paint()
        ..color = Colors.white.withValues(alpha: locA * 0.55)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _TapeLocatorTrackPainter old) {
    return old.progress != progress ||
        old.transportActive != transportActive;
  }
}

class _TapeLocatorLabelsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    const labels = ['0', '5', '10', '15'];
    final w = size.width;
    for (int i = 0; i < labels.length; i++) {
      final x = w * (i / 3.0);
      tp.text = TextSpan(
        text: labels[i],
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.2),
          fontFamily: 'monospace',
          fontSize: 9,
          height: 1,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, 0));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- BOTTOM: cassette window (tape dominates; small hubs; path between) ---

class _CassetteMechanismPanel extends StatelessWidget {
  const _CassetteMechanismPanel({
    required this.progress,
    required this.spinning,
    required this.spinAnimation,
    required this.spinMul,
  });

  final double progress;
  final bool spinning;
  final Animation<double> spinAnimation;
  final double spinMul;

  @override
  Widget build(BuildContext context) {
    const h = 102.0;
    return Container(
      height: h,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.26),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: AnimatedBuilder(
        animation: spinAnimation,
        builder: (context, _) {
          final base = spinAnimation.value *
              2 *
              math.pi *
              (spinning ? spinMul : 1.0);
          // Larger wound pack → slower rotation (cassette-ish cue).
          final t = progress.clamp(0.0, 1.0);
          final leftFill = 1.0 - t;
          final rightFill = t;
          // More wound tape → slower hub (inverse of pack size).
          final rotL =
              base * (0.52 + 0.48 * (0.35 + 0.65 * (1.0 - leftFill)));
          final rotR =
              base * (0.52 + 0.48 * (0.35 + 0.65 * (1.0 - rightFill)));
          final flow = spinning ? spinAnimation.value : 0.0;
          return CustomPaint(
            painter: _CassetteWindowPainter(
              progress: progress,
              rotationLeft: rotL,
              rotationRight: rotR,
              pathFlow: flow,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

/// Single “window” like menu [CassettePainter]: dark tape blobs dominate, small reels inside.
class _CassetteWindowPainter extends CustomPainter {
  _CassetteWindowPainter({
    required this.progress,
    required this.rotationLeft,
    required this.rotationRight,
    required this.pathFlow,
  });

  final double progress;
  final double rotationLeft;
  final double rotationRight;
  final double pathFlow;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0);
    final leftFill = 1.0 - t;
    final rightFill = t;

    const inset = 8.0;
    final shell = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, 4, size.width - inset * 2, size.height - 12),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      shell,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      shell,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final rect = shell.outerRect;
    final midY = rect.center.dy;
    final leftCx = rect.left + rect.width * 0.21;
    final rightCx = rect.left + rect.width * 0.79;

    // Max radius for tape mass (~ menu: winH * 0.8 style dominance)
    final tapeMaxR = math.min(rect.height * 0.46, rect.width * 0.2);
    final tapeMinR = tapeMaxR * 0.22;

    final tapeLeftR = _lerpDouble(tapeMinR, tapeMaxR, leftFill);
    final tapeRightR = _lerpDouble(tapeMinR, tapeMaxR, rightFill);

    // Small fixed hub/spoke assembly (compact cassette)
    final hubR = tapeMaxR * 0.14;
    final spokeInner = hubR * 1.15;
    final spokeOuter = tapeMaxR * 0.34;

    // 1) Dark tape mass (dominant) — menu uses white24; slightly darker for OLED
    final tapeFill = Paint()
      ..color = Colors.white.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(leftCx, midY), tapeLeftR, tapeFill);
    canvas.drawCircle(Offset(rightCx, midY), tapeRightR, tapeFill);

    // Subtle outer lip on tape pack
    final lip = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(Offset(leftCx, midY), tapeLeftR, lip);
    canvas.drawCircle(Offset(rightCx, midY), tapeRightR, lip);

    // Tape path: upper/lower runs (menu cassette style), tangent to tape packs
    final yLow = midY + math.min(tapeLeftR, tapeRightR) * 0.72;
    final yHigh = midY - math.min(tapeLeftR, tapeRightR) * 0.72;
    final leftEdgeX = leftCx + tapeLeftR;
    final rightEdgeX = rightCx - tapeRightR;
    if (rightEdgeX > leftEdgeX + 4) {
      final pathPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square;
      canvas.drawLine(
        Offset(leftEdgeX, yHigh),
        Offset(rightEdgeX, yHigh),
        pathPaint,
      );
      canvas.drawLine(
        Offset(leftEdgeX, yLow),
        Offset(rightEdgeX, yLow),
        pathPaint,
      );
      if (pathFlow > 0) {
        const dash = 4.0;
        final off = pathFlow * dash * 2;
        final thin = Paint()
          ..color = Colors.white.withValues(alpha: 0.09)
          ..strokeWidth = 1;
        double x = leftEdgeX - off % (dash * 2);
        while (x < rightEdgeX) {
          canvas.drawLine(Offset(x, yHigh - 1), Offset(x + dash, yHigh - 1), thin);
          x += dash * 2;
        }
      }
    }

    void drawHub(double cx, double cy, double rot) {
      // Spokes only inside tape — short, delicate
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rot);
      final sp = Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.square;
      for (int k = 0; k < 3; k++) {
        final a = k * 2 * math.pi / 3;
        final p1 = Offset(math.cos(a), math.sin(a)) * spokeInner;
        final p2 = Offset(math.cos(a), math.sin(a)) * spokeOuter;
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

    drawHub(leftCx, midY, rotationLeft);
    drawHub(rightCx, midY, rotationRight);
  }

  @override
  bool shouldRepaint(covariant _CassetteWindowPainter old) {
    return old.progress != progress ||
        old.rotationLeft != rotationLeft ||
        old.rotationRight != rotationRight ||
        old.pathFlow != pathFlow;
  }
}

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
