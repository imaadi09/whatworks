import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// WhatsApp-style "@mention" support for the chat composers (Task, Sales and
/// CRM detail screens).
///
/// [ChatMentionController] tracks the "@" token under the caret and exposes the
/// filtered list of candidate names; [MentionSuggestions] renders that list as
/// a docked popup just above the input bar. Tapping a row replaces the partial
/// "@query" in the message field with "@FullName ".
///
/// Candidates are resolved lazily through a [candidatesProvider] callback so
/// the picker always reflects the current task/enquiry participants without
/// the screens having to push updates into the controller.
class ChatMentionController extends ChangeNotifier {
  ChatMentionController({required this.candidatesProvider});

  /// Returns the display names that can be mentioned (everyone on the chat).
  final List<String> Function() candidatesProvider;

  String? _query;
  List<String> _matches = const [];

  /// The lowercased text typed after the active "@" (null when no mention is
  /// in progress).
  String? get query => _query;

  /// Candidate names matching the current [query].
  List<String> get matches => _matches;

  /// True when a mention is being composed and at least one name matches — the
  /// dropdown should be visible.
  bool get isActive => _query != null && _matches.isNotEmpty;

  /// Re-evaluate the "@" token for the given text-field value. Call on every
  /// text or selection change (a TextEditingController listener covers both).
  void updateFrom(TextEditingValue value) {
    final caret = value.selection.baseOffset;
    final text = value.text;
    String? q;
    if (caret >= 0 && caret <= text.length) {
      final before = text.substring(0, caret);
      final at = before.lastIndexOf('@');
      if (at != -1) {
        final token = before.substring(at + 1);
        final prevChar = at == 0 ? ' ' : before[at - 1];
        final boundaryOk =
            at == 0 || prevChar == ' ' || prevChar == '\n' || prevChar == '\t';
        // A mention token runs until the first whitespace; once the user types
        // a space the mention is "committed" and the dropdown should close.
        if (boundaryOk && !token.contains(' ') && !token.contains('\n')) {
          q = token.toLowerCase();
        }
      }
    }
    _query = q;
    _recompute();
    notifyListeners();
  }

  void _recompute() {
    final q = _query;
    if (q == null) {
      _matches = const [];
      return;
    }
    final candidates = candidatesProvider();
    _matches = candidates.where((c) => c.toLowerCase().contains(q)).toList();
  }

  /// Hide the dropdown without touching the text field.
  void clear() {
    if (_query == null && _matches.isEmpty) return;
    _query = null;
    _matches = const [];
    notifyListeners();
  }

  /// Replace the in-progress "@query" in [messageController] with "@[name] ".
  void applyReplacement(TextEditingController messageController, String name) {
    final value = messageController.value;
    final caret = value.selection.baseOffset;
    final text = value.text;
    if (caret < 0 || caret > text.length) {
      clear();
      return;
    }
    final before = text.substring(0, caret);
    final at = before.lastIndexOf('@');
    if (at == -1) {
      clear();
      return;
    }
    final inserted = '@$name ';
    final newText = before.substring(0, at) + inserted + text.substring(caret);
    messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
    clear();
    // Keep the composer mic/send toggle (and anything else listening) in sync.
    notifyListeners();
  }
}

/// Docked suggestion list shown above the chat input bar while a mention is
/// active. Self-sizes to the number of matches (capped) and dismisses itself
/// when [ChatMentionController.isActive] is false.
class MentionSuggestions extends StatelessWidget {
  const MentionSuggestions({
    super.key,
    required this.mention,
    required this.messageController,
    this.accentColor,
  });

  final ChatMentionController mention;
  final TextEditingController messageController;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppTheme.headerGreen;
    return ListenableBuilder(
      listenable: mention,
      builder: (context, _) {
        if (!mention.isActive) return const SizedBox.shrink();
        final matches = mention.matches;
        return Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[300]!, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  'Mention someone',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 4),
                  itemCount: matches.length,
                  itemBuilder: (context, i) {
                    final name = matches[i];
                    final initial = name.isNotEmpty
                        ? name.trim()[0].toUpperCase()
                        : '?';
                    return ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(
                        horizontal: 0,
                        vertical: -2,
                      ),
                      leading: CircleAvatar(
                        radius: 15,
                        backgroundColor: accent.withOpacity(0.15),
                        child: Text(
                          initial,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                        ),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryText,
                        ),
                      ),
                      onTap: () =>
                          mention.applyReplacement(messageController, name),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
