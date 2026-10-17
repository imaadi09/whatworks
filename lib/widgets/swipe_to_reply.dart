import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// WhatsApp-style swipe-right-to-reply gesture wrapper.
///
/// Wraps a chat bubble or action card: dragging the row rightwards reveals a
/// quiet reply arrow at the left edge, and releasing past [triggerExtent]
/// fires [onReply] (the screen then sets its reply target and shows the
/// preview bar above the input). The child animates back to rest either way,
/// exactly like WhatsApp's resetDistance behavior.
///
/// Gesture coexistence is deliberate: only horizontal drags are claimed, so
/// taps, long-presses and the reverse ListView's vertical scroll keep their
/// normal arena resolution. When [enabled] is false the child is returned
/// untouched — no gesture, no Stack, zero overhead on non-replayable rows
/// (deleted tombstones, metadata trails).
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
    this.triggerExtent = 80.0,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  /// Pixels of rightward drag required to fire the reply on release.
  final double triggerExtent;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  // The controller's value IS the current offset in pixels (0..maxExtent),
  // so drag updates drive it directly and release just reverses to rest —
  // no setState rebuild of the whole row per pointer event.
  static const double _maxExtent = 120.0;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0,
      upperBound: _maxExtent,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _controller.value = (_controller.value + details.delta.dx).clamp(
      0.0,
      _maxExtent,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    if (_controller.value >= widget.triggerExtent) {
      HapticFeedback.lightImpact();
      widget.onReply();
    }
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    // The arrow fades in over the first half of the trigger travel so the
    // hint appears just before the thumb reaches the resting position.
    final arrowOpacity = Tween<double>(
      begin: 0.0,
      end: 0.7,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      behavior: HitTestBehavior.deferToChild,
      child: Stack(
        children: [
          // Left-edge reply hint, revealed as the bubble slides right.
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: FadeTransition(
                opacity: arrowOpacity,
                child: const Icon(
                  Icons.reply,
                  size: 20,
                  color: Color(0xFF868E96), // WhatsApp hint grey
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            child: widget.child,
            builder: (context, child) => Transform.translate(
              offset: Offset(_controller.value, 0),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
