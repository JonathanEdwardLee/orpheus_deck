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
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  bool get _spinning => widget.isPlaying || widget.isRecording;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (_spinning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _spin.repeat();
      });
    }
  }

  @override
  void didUpdateWidget(TapeReelTransport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.isPlaying || oldWidget.isRecording;
    if (_spinning && !was) {
      if (mounted) _spin.repeat();
    } else if (!_spinning && was) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  double get _progress {
    if (widget.tapeLengthMs <= 0) return 0;
    return (widget.playbackMs / widget.tapeLengthMs).clamp(0.0, 1.0);
  }

  void _seekFromLocalDx(double dx, double width) {
    if (width <= 0) return;
    final frac = (dx / width).clamp(0.0, 1.0);
    final ms =
        (frac * widget.tapeLengthMs).round().clamp(0, widget.tapeLengthMs);
    widget.onTapeSeekMs(ms);
  }

  @override
  Widget build(BuildContext context) {
    const double reelSlot = 56;
    const double stripHeight = 52;
    const double labelRow = 14;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
              animation: _spin,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ReelPainter(
                    rotation: _spinning ? _spin.value * 2 * math.pi : 0,
                    radiusT: _progress,
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
                          painter: _TapeStripPainter(progress: _progress),
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(
                  height: labelRow,
                  child: CustomPaint(
                    painter: const _TapeRulerLabelsPainter(),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: reelSlot,
            height: reelSlot,
            child: AnimatedBuilder(
              animation: _spin,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ReelPainter(
                    rotation: _spinning ? _spin.value * 2 * math.pi : 0,
                    radiusT: _progress,
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

/// radiusT: 0 = start (left large), 1 = end (right large).
class _ReelPainter extends CustomPainter {
  _ReelPainter({
    required this.rotation,
    required this.radiusT,
    required this.isLeft,
  });

  final double rotation;
  final double radiusT;
  final bool isLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final t = radiusT.clamp(0.0, 1.0);
    final radius = isLeft
        ? _lerpDouble(26, 13, t)
        : _lerpDouble(13, 26, t);
    const hubR = 5.0;
    const stroke = 2.5;

    final outer = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rotation);

    canvas.drawCircle(Offset.zero, radius, outer);
    canvas.drawCircle(Offset.zero, radius, ring);

    for (int k = 0; k < 3; k++) {
      final a = k * 2 * math.pi / 3;
      final p1 = Offset(math.cos(a), math.sin(a)) * (hubR + 2);
      final p2 = Offset(math.cos(a), math.sin(a)) * (radius - stroke);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.square,
      );
    }

    canvas.drawCircle(Offset.zero, hubR, Paint()..color = Colors.white);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReelPainter old) {
    return old.rotation != rotation ||
        old.radiusT != radiusT ||
        old.isLeft != isLeft;
  }
}

class _TapeStripPainter extends CustomPainter {
  _TapeStripPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const yMid = 24.0;
    final w = size.width;
    final p = progress.clamp(0.0, 1.0);
    final rawX = p * w;
    final headX = w <= 10 ? w * 0.5 : rawX.clamp(5.0, w - 5.0);

    final line = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, yMid), Offset(w, yMid), line);

    // Minute ticks (15 min → tick each minute at w * (m/15)).
    final tickPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (int m = 1; m < 15; m++) {
      final x = w * (m / 15.0);
      final tall = m % 5 == 0;
      final h = tall ? 8.0 : 4.0;
      canvas.drawLine(Offset(x, yMid - h), Offset(x, yMid + h), tickPaint);
    }

    // Playhead / tape head triangle
    final tri = Path()
      ..moveTo(headX, 4)
      ..lineTo(headX - 5, 16)
      ..lineTo(headX + 5, 16)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _TapeStripPainter old) {
    return old.progress != progress;
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
        style: const TextStyle(
          color: Colors.white38,
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
  bool shouldRepaint(covariant _TapeRulerLabelsPainter old) => false;
}

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
