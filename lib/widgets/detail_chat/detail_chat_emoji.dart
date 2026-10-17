import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// Shared WhatsApp-style emoji picker used by the Task, Sales and CRM chat
/// input bars. Shows a bottom sheet of common emojis; each tap inserts the
/// emoji into the caller's message controller at the last known cursor
/// position and keeps the sheet open so several emojis can be added quickly.
///
/// Works even while the soft keyboard is hidden: the insertion offset is
/// tracked from the controller's selection, so emojis land where the user
/// last had the caret.
class ChatEmojiPicker {
  ChatEmojiPicker._();

  static const List<Map<String, dynamic>> _groups = [
    {
      'label': 'Smileys',
      'emojis': [
        '😀', '😃', '😄', '😁', '😅', '😂', '🤣', '🙂',
        '😉', '😊', '😇', '🥰', '😍', '😘', '😜', '🤪',
        '🤔', '🤨', '😐', '😏', '😒', '🙄', '😬', '😌',
        '😴', '🤤', '😷', '🤒', '🥵', '🥶', '😵', '🤯',
        '🥳', '😎', '🤓', '😟', '😢', '😭', '😤', '😡',
        '🤬', '😱', '😨', '😰', '😥', '🤗', '🤭', '🙃',
      ],
    },
    {
      'label': 'Gestures',
      'emojis': [
        '👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙',
        '👈', '👉', '👆', '👇', '☝️', '✋', '🤚', '🖐️',
        '👋', '💪', '🙏', '🦶', '👏', '🙌', '👐', '🤲',
        '🤝', '✍️', '💅', '🤳', '👊', '✊', '🤛', '🤜',
      ],
    },
    {
      'label': 'Hearts',
      'emojis': [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
        '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
        '💘', '💝', '💟', '💌', '💋', '😻', '💐', '🌹',
      ],
    },
    {
      'label': 'Things',
      'emojis': [
        '✅', '❌', '⭕', '❗', '❓', '💯', '🔥', '✨',
        '🎉', '🎊', '🎁', '🏆', '🥇', '🎯', '💡', '🔔',
        '📌', '📎', '✏️', '📝', '📁', '📅', '⏰', '⌛',
        '📞', '💰', '💵', '🪙', '📈', '🚗', '✈️', '🏠',
      ],
    },
    {
      'label': 'Nature',
      'emojis': [
        '☀️', '🌤️', '🌧️', '⛈️', '🌈', '❄️', '🌊', '🌙',
        '⭐', '🌟', '⚡', '🔆', '🐶', '🐱', '🐦', '🦋',
        '🌸', '🌻', '🌴', '🍀', '🌿', '🍎', '🍕', '☕',
      ],
    },
  ];

  /// Insert [emoji] into [controller] at the last known caret position.
  static void insert(TextEditingController controller, String emoji) {
    final text = controller.text;
    final selection = controller.selection;
    final valid =
        selection.isValid &&
        selection.baseOffset >= 0 &&
        selection.baseOffset <= text.length;
    final offset = valid ? selection.baseOffset : text.length;
    final start = valid && selection.start >= 0 ? selection.start : offset;
    final end =
        valid && selection.end >= 0 && selection.end <= text.length
            ? selection.end
            : offset;
    controller.value = controller.value.copyWith(
      text: text.replaceRange(start, end, emoji),
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  /// Open the picker. Insertions go into [controller].
  static Future<void> show(
    BuildContext context,
    TextEditingController controller,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _EmojiSheet(
        controller: controller,
        groups: _groups,
      ),
    );
  }
}

class _EmojiSheet extends StatefulWidget {
  final TextEditingController controller;
  final List<Map<String, dynamic>> groups;

  const _EmojiSheet({required this.controller, required this.groups});

  @override
  State<_EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<_EmojiSheet> {
  int _groupIndex = 0;

  @override
  Widget build(BuildContext context) {
    final group = widget.groups[_groupIndex];
    final emojis = List<String>.from(group['emojis'] as List);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Category tabs
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  for (int i = 0; i < widget.groups.length; i++)
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _groupIndex = i),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: i == _groupIndex
                                    ? AppTheme.headerGreen
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            widget.groups[i]['label'] as String,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: i == _groupIndex
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == _groupIndex
                                  ? AppTheme.headerGreen
                                  : AppTheme.secondaryText,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Emoji grid
            SizedBox(
              height: 260,
              child: GridView.count(
                crossAxisCount: 8,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final emoji in emojis)
                    InkWell(
                      onTap: () => ChatEmojiPicker.insert(
                        widget.controller,
                        emoji,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      child: Center(
                        child: Text(emoji, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
