import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Cassette-style tape position: reels + ruler + head. Not a DAW timeline.
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
  /// Optional subtle spin-up / coast (multiplier 0→1). Not transport logic.
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

  /// Subtle spin-up after transport starts (illusion only).
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
    const double reelSlot = 76;
    const double stripHeight = 46;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white38, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: reelSlot,
            height: reelSlot,
            child: AnimatedBuilder(
              animation: Listenable.merge([_spin, _spinRamp]),
              builder: (context, _) {
                final rot = _spin.value *
                    2 *
                    math.pi *
                    (_spinning ? _spinMul : 1.0);
                return CustomPaint(
                  painter: _ReelPainter(
                    rotation: rot,
                    tapeProgress: _progress,
                    isLeft: true,
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: stripHeight,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final seekHere = widget.seekEnabled &&
                          !_spinning &&
                          w > 0;
                      final flowPhase = _spinning
                          ? (widget.playbackMs % 1200) / 1200.0
                          : 0.0;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: seekHere
                            ? (e) => _seekFromLocalDx(
                                  e.localPosition.dx,
                                  w,
                                )
                            : null,
                        onHorizontalDragUpdate: seekHere
                            ? (d) => _seekFromLocalDx(
                                  d.localPosition.dx,
                                  w,
                                )
                            : null,
                        child: CustomPaint(
                          size: Size(w, stripHeight),
                          painter: _TapeStripPainter(
                            progress: _progress,
                            tapeFlowActive: _spinning,
                            flowPhase: flowPhase,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(
                  height: 11,
                  child: CustomPaint(
                    painter: _TapeRulerLabelsPainter(),
                    child: SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: reelSlot,
            height: reelSlot,
            child: AnimatedBuilder(
              animation: Listenable.merge([_spin, _spinRamp]),
              builder: (context, _) {
                final rot = _spin.value *
                    2 *
                    math.pi *
                    (_spinning ? _spinMul : 1.0);
                return CustomPaint(
                  painter: _ReelPainter(
                    rotation: rot,
                    tapeProgress: _progress,
                    isLeft: false,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Fixed-size reel hardware + rotating spokes + tape mass radius only.
///
/// **Tape mass:** [tapeProgress] 0 = start of side, 1 = end.
/// - Left supply reel: mass full at 0, thin at 1 → fill = `1 - tapeProgress`.
/// - Right take-up reel: mass thin at 0, full at 1 → fill = `tapeProgress`.
/// Outer flange radius is constant; only the wound-tape outer radius lerps.
class _ReelPainter extends CustomPainter {
  _ReelPainter({
    required this.rotation,
    required this.tapeProgress,
    required this.isLeft,
  });

  final double rotation;
  final double tapeProgress;
  final bool isLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final hardwareR = math.min(size.width, size.height) / 2 - 1.5;
    const hubR = 5.5;
    const hubRing = 1.2;
    final t = tapeProgress.clamp(0.0, 1.0);
    final fill = isLeft ? (1.0 - t) : t;

    const tapeOuterMin = hubR + hubRing + 3.0;
    final tapeOuterMax = hardwareR - 4.0;
    final tapeOuter = _lerpDouble(tapeOuterMin, tapeOuterMax, fill)
        .clamp(tapeOuterMin, tapeOuterMax);

    // 1) Tape mass (annulus hub+clearance .. tapeOuter)
    final tapePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
    final outerTape = Path()
      ..addOval(Rect.fromCircle(center: c, radius: tapeOuter));
    final hubHole = Path()
      ..addOval(Rect.fromCircle(center: c, radius: hubR + hubRing));
    final tapeRing = Path.combine(
      PathOperation.difference,
      outerTape,
      hubHole,
    );
    canvas.drawPath(tapeRing, tapePaint);

    // 2) Spokes — fixed geometry, rotate only
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rotation);
    const spokeInner = hubR + hubRing + 1.0;
    final spokeOuter = hardwareR - 3.5;
    final spokePaint = Paint()
      ..color = Colors.white60
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square;
    for (int k = 0; k < 3; k++) {
      final a = k * 2 * math.pi / 3;
      final p1 = Offset(math.cos(a), math.sin(a)) * spokeInner;
      final p2 = Offset(math.cos(a), math.sin(a)) * spokeOuter;
      canvas.drawLine(p1, p2, spokePaint);
    }
    canvas.restore();

    // 3) Center hub (fixed)
    canvas.drawCircle(
      c,
      hubR,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      c,
      hubR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 4) Outer reel hardware — fixed radius
    canvas.drawCircle(
      c,
      hardwareR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ReelPainter old) {
    return old.rotation != rotation ||
        old.tapeProgress != tapeProgress ||
        old.isLeft != isLeft;
  }
}

class _TapeStripPainter extends CustomPainter {
  _TapeStripPainter({
    required this.progress,
    required this.tapeFlowActive,
    required this.flowPhase,
  });

  final double progress;
  final bool tapeFlowActive;
  final double flowPhase;

  @override
  void paint(Canvas canvas, Size size) {
    final yMid = size.height * 0.52;
    final w = size.width;
    final p = progress.clamp(0.0, 1.0);
    final rawX = p * w;
    final headX = w <= 10 ? w * 0.5 : rawX.clamp(4.0, w - 4.0);

    // Tape ribbon (subtle directional shimmer when moving)
    final linePaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    if (tapeFlowActive && w > 8) {
      const dash = 5.0;
      final offset = flowPhase * dash * 2;
      double x = -offset;
      while (x < w) {
        canvas.drawLine(Offset(x, yMid), Offset(x + dash, yMid), linePaint);
        x += dash * 2;
      }
    } else {
      canvas.drawLine(Offset(0, yMid), Offset(w, yMid), linePaint);
    }

    // Minute ticks — secondary, soft
    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (int m = 1; m < 15; m++) {
      final x = w * (m / 15.0);
      final tall = m % 5 == 0;
      final h = tall ? 5.0 : 2.5;
      canvas.drawLine(Offset(x, yMid - h), Offset(x, yMid + h), tickPaint);
    }

    // Mechanical tape-head marker: thin vertical + guide notch (not a scrub triangle)
    const halfW = 1.0;
    const vTop = 6.0;
    const vBot = 20.0;
    canvas.drawRect(
      Rect.fromLTRB(headX - halfW, vTop, headX + halfW, vBot),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.drawLine(
      Offset(headX - 5, yMid),
      Offset(headX + 5, yMid),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _TapeStripPainter old) {
    return old.progress != progress ||
        old.tapeFlowActive != tapeFlowActive ||
        old.flowPhase != flowPhase;
  }
}

class _TapeRulerLabelsPainter extends CustomPainter {
  const _TapeRulerLabelsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    const labels = ['0', '5', '10', '15'];
    final w = size.width;
    for (int i = 0; i < labels.length; i++) {
      final x = w * (i / 3.0);
      tp.text = TextSpan(
        text: labels[i],
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.22),
          fontFamily: 'monospace',
          fontSize: 8,
          height: 1,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, 0));
    }
  }

  @override
  bool shouldRepaint(covariant _TapeRulerLabelsPainter old) => false;
}

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
