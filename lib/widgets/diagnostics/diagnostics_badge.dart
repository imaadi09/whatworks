import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/sync_telemetry.dart';

/// Floating glance-badge for [SyncTelemetry], mounted at the app root
/// (`MaterialApp.builder`) so it stays visible across every route while the
/// tester has it enabled. Shows a compact live summary with a severity-colored
/// edge and dot; tap opens the full diagnostics panel (via [onOpen]), drag to
/// reposition. Polls the singleton at 1 Hz.
///
/// Purely observational — it reads counters and never touches sync/read/write
/// behaviour. The widget is a full-screen transparent [Stack] with a single
/// small chip, so taps anywhere except the chip fall through to the app below.
class DiagnosticsBadge extends StatefulWidget {
  final VoidCallback? onOpen;
  const DiagnosticsBadge({super.key, this.onOpen});

  @override
  State<DiagnosticsBadge> createState() => _DiagnosticsBadgeState();
}

class _DiagnosticsBadgeState extends State<DiagnosticsBadge> {
  final SyncTelemetry _tel = SyncTelemetry.instance;
  Timer? _ticker;

  /// Top-left of the chip; null until the first drag (then a default is used).
  Offset? _pos;

  // Generous estimates used only to clamp the chip on-screen while dragging.
  static const double _chipW = 168;
  static const double _chipH = 30;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Color _sev(TelSeverity s) {
    if (s == TelSeverity.crit) return Colors.red.shade400;
    if (s == TelSeverity.warn) return Colors.amber.shade400;
    return Colors.green.shade400;
  }

  String _n(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  /// R = Firestore reads (docs), W = writes, L = active listeners, N = provider
  /// notifies. The single worst-severity color flags "something is worth a
  /// look" at a glance; the panel has the per-metric breakdown.
  String _summary() {
    if (!_tel.enabled) return 'diag off';
    return 'R${_n(_tel.fsReads)} W${_n(_tel.fsWrites)} '
        'L${_tel.activeListeners} N${_n(_tel.notifyCount)}';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;
          final maxX = (w - _chipW).clamp(0.0, double.infinity);
          final maxY = (h - _chipH).clamp(0.0, double.infinity);
          // Default: bottom-right, lifted clear of the usual FAB/nav area.
          final def = Offset(maxX - 12, (h - _chipH - 160).clamp(0.0, maxY));
          final pos = _pos ?? def;
          final color = _sev(_tel.worstSeverity());
          return Stack(
            children: [
              Positioned(
                left: pos.dx.clamp(0.0, maxX),
                top: pos.dy.clamp(0.0, maxY),
                child: GestureDetector(
                  onTap: widget.onOpen,
                  onPanUpdate: (d) {
                    setState(() {
                      final cur = _pos ?? def;
                      _pos = Offset(
                        (cur.dx + d.delta.dx).clamp(0.0, maxX),
                        (cur.dy + d.delta.dy).clamp(0.0, maxY),
                      );
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.80),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: color, width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _summary(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
