import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Circular gas-pressure style loading dial with a sweeping needle.
class GaugeLoadingIndicator extends StatefulWidget {
  final double size;
  final String label;
  final Color? trackColor;
  final Color? accentColor;

  const GaugeLoadingIndicator({
    super.key,
    this.size = 160,
    this.label = 'Loading',
    this.trackColor,
    this.accentColor,
  });

  @override
  State<GaugeLoadingIndicator> createState() => _GaugeLoadingIndicatorState();
}

class _GaugeLoadingIndicatorState extends State<GaugeLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.accentColor ?? scheme.primary;
    final track = widget.trackColor ?? scheme.outlineVariant.withValues(alpha: 0.45);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return CustomPaint(
                painter: _GaugePainter(
                  progress: _ctrl.value,
                  accent: accent,
                  track: track,
                  background: scheme.surface,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        Text(
          widget.label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  final Color accent;
  final Color track;
  final Color background;

  _GaugePainter({
    required this.progress,
    required this.accent,
    required this.track,
    required this.background,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.42;
    const start = math.pi * 0.75; // 135°
    const sweep = math.pi * 1.5; // 270°

    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      base,
    );

    final glow = Paint()
      ..color = accent.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.11
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final active = Paint()
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: [accent.withValues(alpha: 0.2), accent],
        transform: GradientRotation(start),
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeCap = StrokeCap.round;

    final needleAngle = start + sweep * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep * progress,
      false,
      glow,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep * progress,
      false,
      active,
    );

    // Tick marks
    final tickPaint = Paint()
      ..color = accent.withValues(alpha: 0.55)
      ..strokeWidth = 2;
    for (var i = 0; i <= 10; i++) {
      final a = start + sweep * (i / 10);
      final outer = Offset(
        center.dx + math.cos(a) * (radius + 2),
        center.dy + math.sin(a) * (radius + 2),
      );
      final inner = Offset(
        center.dx + math.cos(a) * (radius - size.width * 0.05),
        center.dy + math.sin(a) * (radius - size.width * 0.05),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }

    // Needle
    final needleLen = radius * 0.78;
    final tip = Offset(
      center.dx + math.cos(needleAngle) * needleLen,
      center.dy + math.sin(needleAngle) * needleLen,
    );
    final needle = Paint()
      ..color = accent
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, needle);

    canvas.drawCircle(center, size.width * 0.055, Paint()..color = accent);
    canvas.drawCircle(center, size.width * 0.025, Paint()..color = background);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.accent != accent ||
      oldDelegate.track != track;
}
