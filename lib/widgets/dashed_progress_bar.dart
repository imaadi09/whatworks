import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// Vertical solid progress bar shared by TaskCard and SalesCard.
/// Fills bottom-to-top: the filled portion is painted in [color] over a faint
/// solid track — same geometry as the old dashed bar (3x60) so card layout
/// is unchanged.
class DashedProgressBar extends StatelessWidget {
  final double progress; // 0.0 .. 1.0
  final Color color;
  final double width;
  final double height;

  const DashedProgressBar({
    super.key,
    required this.progress,
    required this.color,
    this.width = 3,
    this.height = 60,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _DashedBarPainter(
        progress: progress.clamp(0.0, 1.0),
        color: color,
        trackColor: AppTheme.lightText.withOpacity(0.15),
      ),
    );
  }
}

class _DashedBarPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color trackColor;

  _DashedBarPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.width / 2);
    final filledHeight = size.height * progress;

    // Solid track (full height), then the filled portion bottom-to-top.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(0, 0, size.width, size.height),
        radius,
      ),
      Paint()..color = trackColor,
    );
    if (filledHeight > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, size.height - filledHeight, size.width, size.height),
          radius,
        ),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedBarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor;
}
