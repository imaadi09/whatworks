import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/constants.dart';

/// Reusable numeric PIN entry: a row of dots + a 3x4 keypad.
///
/// Fully self-contained (no native dependency). The parent supplies a title,
/// optional subtitle, an [errorText] to flash on a wrong attempt, and an
/// [onCompleted] callback fired once [pinLength] digits are entered. The parent
/// clears the field via the [controller] after validating.
class PinEntryView extends StatefulWidget {
  final String title;
  final String? subtitle;
  final int pinLength;
  final String? errorText;
  final ValueChanged<String> onCompleted;
  final PinEntryController? controller;

  const PinEntryView({
    super.key,
    required this.title,
    required this.onCompleted,
    this.subtitle,
    this.pinLength = 4,
    this.errorText,
    this.controller,
  });

  @override
  State<PinEntryView> createState() => _PinEntryViewState();
}

/// Lets the parent reset the entered digits after a (failed) validation.
class PinEntryController {
  _PinEntryViewState? _state;
  void clear() => _state?._clear();
}

class _PinEntryViewState extends State<PinEntryView> {
  String _entered = '';

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    super.dispose();
  }

  void _clear() {
    if (mounted) setState(() => _entered = '');
  }

  void _onDigit(String d) {
    if (_entered.length >= widget.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() => _entered += d);
    if (_entered.length == widget.pinLength) {
      widget.onCompleted(_entered);
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline, size: 48, color: AppTheme.primaryGreen),
        const SizedBox(height: 16),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            widget.subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
          ),
        ],
        const SizedBox(height: 28),
        // Dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.pinLength, (i) {
            final filled = i < _entered.length;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? AppTheme.primaryGreen : Colors.transparent,
                border: Border.all(
                  color: hasError
                      ? Colors.red
                      : (filled ? AppTheme.primaryGreen : AppTheme.lightText),
                  width: 2,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 20,
          child: hasError
              ? Text(
                  widget.errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                )
              : null,
        ),
        const SizedBox(height: 12),
        _buildKeypad(),
      ],
    );
  }

  Widget _buildKeypad() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.5,
        children: [
          for (var n = 1; n <= 9; n++) _key('$n'),
          const SizedBox.shrink(),
          _key('0'),
          IconButton(
            onPressed: _onBackspace,
            icon: const Icon(Icons.backspace_outlined, size: 26),
          ),
        ],
      ),
    );
  }

  Widget _key(String digit) {
    return InkWell(
      onTap: () => _onDigit(digit),
      customBorder: const CircleBorder(),
      child: Center(
        child: Text(
          digit,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
