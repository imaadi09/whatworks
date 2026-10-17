import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class Helpers {
  // Short display form of a person's name for compact surfaces (chat sender
  // label, activity log actor): initials of the first two words, uppercased.
  // 'Me' is kept as-is so the current user's own bubbles stay readable.
  static String nameInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed == 'Me') return trimmed;
    final parts = trimmed
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length == 1) {
      final word = parts.first;
      return word.length > 2
          ? word.substring(0, 2).toUpperCase()
          : word.toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  // Format date
  static String formatDate(DateTime date) {
    return DateFormat('dd/MM/yyyy').format(date);
  }

  // Format deadline - shows time only if specifically set (not 23:59)
  static String formatDeadline(DateTime deadline) {
    // Check if time is specifically set (not the default end-of-day 23:59)
    final isDefaultTime = deadline.hour == 23 && deadline.minute == 59;

    if (isDefaultTime) {
      // Only show date
      return DateFormat('MMM dd, yyyy').format(deadline);
    } else {
      // Show date and time
      return DateFormat('MMM dd, yyyy hh:mm a').format(deadline);
    }
  }

  // Format date with time
  static String formatDateTime(DateTime date) {
    return DateFormat('dd/MM/yyyy HH:mm').format(date);
  }

  // Format time only
  static String formatTime(DateTime date) {
    return DateFormat('HH:mm').format(date);
  }

  // Get relative time — compact, no " ago" suffix so the card meta line keeps
  // maximum width for the message preview ("36m", "2h", "5d"). "Now" replaces
  // "Just now"; past the 7-day window it falls back to a condensed dd/MM with
  // no year.
  static String getRelativeTime(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inSeconds < 60) {
      return 'Now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d';
    } else {
      return DateFormat('dd/MM').format(date);
    }
  }

  // "1 Day" / "3 Days" — shared day-count label so every surface formats
  // overdue/remaining days the same way.
  static String dayCountLabel(int days) => days == 1 ? '1 Day' : '$days Days';

  // "3 Days Overdue" — shared overdue label.
  static String overdueLabel(int daysOverdue) =>
      '${dayCountLabel(daysOverdue)} Overdue';

  // Format deadline badge (WhatsApp-style)
  static String formatDeadlineBadge(DateTime? deadline) {
    if (deadline == null) return '';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final deadlineDate = DateTime(deadline.year, deadline.month, deadline.day);
    final difference = deadlineDate.difference(today).inDays;

    if (difference < 0) {
      // Overdue - word format so it reads clearly in messages/badges
      return overdueLabel(difference.abs());
    } else if (difference == 0) {
      return 'Today';
    } else {
      // Days remaining
      return dayCountLabel(difference);
    }
  }

  // Get deadline badge color based on urgency
  static String getDeadlineStatus(DateTime? deadline, bool isClosed) {
    if (isClosed) return 'closed';
    if (deadline == null) return 'no-deadline';

    final now = DateTime.now();
    final difference = deadline.difference(now);
    final days = difference.inDays;

    if (days < 0) return 'overdue';
    if (days <= 2) return 'nearing';
    return 'on-time';
  }

  // Format file size
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // Format duration (for voice notes)
  static String formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  // Get initials from name
  static String getInitials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[parts.length - 1][0]}'.toUpperCase();
  }

  // Truncate text with ellipsis
  static String truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  // Generate unique ID
  static String generateId() {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  // Calculate progress percentage
  static String progressPercentage(double progress) {
    return '${(progress * 100).toInt()}%';
  }

  // Check if task is behind schedule
  // Returns true if progress is less than expected based on time elapsed
  static bool isTaskBehindSchedule({
    required double progress,
    required DateTime createdAt,
    DateTime? deadline,
  }) {
    // If no deadline, we can't determine schedule
    if (deadline == null) return false;

    final now = DateTime.now();

    // If deadline has passed or task is overdue
    if (now.isAfter(deadline)) {
      // Task should be 100% complete
      return progress < 1.0;
    }

    // Calculate expected progress based on time elapsed
    final totalDuration = deadline.difference(createdAt).inMilliseconds;
    final elapsedDuration = now.difference(createdAt).inMilliseconds;

    // Avoid division by zero
    if (totalDuration <= 0) return false;

    final expectedProgress = elapsedDuration / totalDuration;

    // Task is behind if actual progress is less than expected
    return progress < expectedProgress;
  }

  // Calculate task duration in days
  static int getTaskDurationDays(DateTime createdAt, DateTime? deadline) {
    if (deadline == null) return 0;
    return deadline.difference(createdAt).inDays;
  }

  /// Returns true if [s] looks like a Firebase UID (20+ chars, no spaces,
  /// alphanumeric). Shared by the cards and name-resolution logic.
  static bool looksLikeUid(String s) =>
      s.length >= 20 &&
      !s.contains(' ') &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

  // Calculate expected progress based on time elapsed
  static double getExpectedProgress(DateTime createdAt, DateTime? deadline) {
    if (deadline == null) return 0.0;

    final now = DateTime.now();

    // If deadline has passed, expected progress is 100%
    if (now.isAfter(deadline)) return 1.0;

    final totalDuration = deadline.difference(createdAt).inMilliseconds;
    final elapsedDuration = now.difference(createdAt).inMilliseconds;

    if (totalDuration <= 0) return 0.0;

    return (elapsedDuration / totalDuration).clamp(0.0, 1.0);
  }

  // Get progress speed color (blue shades)
  // Returns color based on how close actual progress is to expected progress
  static Color getProgressSpeedColor(
    double actualProgress,
    double expectedProgress,
  ) {
    if (expectedProgress == 0.0) return Colors.blue;

    final ratio = actualProgress / expectedProgress;

    if (ratio >= 1.0) {
      // On track or ahead - dark blue
      return const Color(0xFF0D47A1); // Dark blue
    } else if (ratio >= 0.75) {
      // Slightly behind - medium-dark blue
      return const Color(0xFF1565C0); // Medium-dark blue
    } else if (ratio >= 0.5) {
      // Moderately behind - medium blue
      return const Color(0xFF1976D2); // Medium blue
    } else if (ratio >= 0.25) {
      // Significantly behind - light-medium blue
      return const Color(0xFF42A5F5); // Light-medium blue
    } else {
      // Very far behind - light blue
      return const Color(0xFF90CAF9); // Light blue
    }
  }

  /// Normalize a phone number to a consistent format for Firestore queries.
  /// Strips spaces, dashes, parentheses and leading zeros; ensures + prefix.
  /// If the number has no country code, [defaultCountryCode] is prepended
  /// (defaults to '+91' for India).
  /// Returns null if input is null or empty.
  static String? normalizePhone(
    String? phone, {
    String defaultCountryCode = '+91',
  }) {
    if (phone == null) return null;
    // Strip all non-digit characters except leading +
    var cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return null;

    // Remove leading + if present, we'll re-add it
    if (cleaned.startsWith('+')) cleaned = cleaned.substring(1);

    // Strip leading zeros (common in local formats like 09876543210)
    while (cleaned.startsWith('0')) {
      cleaned = cleaned.substring(1);
    }

    if (cleaned.isEmpty) return null;

    // If number is shorter than 12 digits, assume local and prepend country code
    // (country code without + is 1-3 digits; subscriber number is 7-12 digits)
    if (cleaned.length <= 12 &&
        !cleaned.startsWith(defaultCountryCode.replaceFirst('+', ''))) {
      cleaned = defaultCountryCode.replaceFirst('+', '') + cleaned;
    }

    return '+$cleaned';
  }

  /// Detect the last action type from message text.
  /// Returns {'icon': IconData, 'color': Color, 'day': String?} or null.
  /// ⚠️ Card-strip icon mapper (fallback when actions table cache is empty) —
  /// keyword order matters and every action type MUST have a branch here.
  /// Keep in sync with detectActionType below and the ACTION-TYPE CHECKLIST
  /// in task_detail_screen.dart above _getActionMessages.
  static Map<String, dynamic>? detectLastAction(String? messageText) {
    if (messageText == null || messageText.isEmpty) return null;
    final lower = messageText.toLowerCase();

    // Response notifications ("↩️ Replied by …", "✅ Marked as done by …",
    // "🔓 Blocker resolved by …") are chat-feed pointers, NOT actions — same
    // guard as detectActionType (which documents why). The send-time
    // "(Follow up 1)" label suffix in their texts would otherwise hit the
    // keyword branches below and mint a phantom chip on the card strip.
    if (lower.contains('replied by ') ||
        lower.contains('marked as done by ') ||
        lower.contains('blocker resolved by ')) {
      return null;
    }

    // Sales/CRM Query action posts "❓ Query: <note>" via the generic builder.
    // Match the emoji+label signature FIRST (see detectActionType) so the card
    // strip fallback icon is right even when the note holds other keywords.
    if (messageText.contains('❓ Query')) {
      return {
        'icon': Icons.question_mark,
        'color': const Color(0xFF7048E8), // Purple
        'abbr': 'Qry',
      };
    }

    // Sales-cycle actions (check before generic types — e.g. "💳 Payment
    // Reminder" must match payment, not reminder)
    if (messageText.contains('💵') || lower.startsWith('cash')) {
      return {
        'icon': Icons.account_balance_wallet,
        'color': const Color(0xFF099268), // Teal green
        'abbr': 'Cash',
      };
    }
    if (messageText.contains('💰') || lower.startsWith('quotation')) {
      return {
        'icon': Icons.request_quote,
        'color': const Color(0xFF2F9E44), // Green
        'abbr': 'Quote',
      };
    }
    if (messageText.contains('🤝') || lower.startsWith('meeting')) {
      return {
        'icon': Icons.groups,
        'color': const Color(0xFF3B5BDB), // Indigo
        'day': extractFollowUpDay(messageText),
        'abbr': 'Meet',
      };
    }
    if (messageText.contains('🛠️') || lower.startsWith('site visit')) {
      return {
        'icon': Icons.handyman,
        'color': const Color(0xFF1098AD), // Cyan
        'day': extractFollowUpDay(messageText),
        'abbr': 'Visit',
      };
    }
    if (messageText.contains('🔧') || lower.startsWith('repaired')) {
      return {
        'icon': Icons.build,
        'color': const Color(0xFF1971C2), // Blue
        'abbr': 'Fix',
      };
    }
    if (messageText.contains('✔️') || lower.startsWith('verified')) {
      return {
        'icon': Icons.verified,
        'color': const Color(0xFF2F9E44), // Green
        'abbr': 'Ver',
      };
    }
    if (messageText.contains('📞') || lower.startsWith('call log')) {
      return {
        'icon': Icons.call,
        'color': const Color(0xFF0C8599), // Teal
        'abbr': 'Call',
      };
    }
    if (messageText.contains('💬') || lower.startsWith('whatsapp')) {
      return {
        'icon': Icons.chat,
        'color': const Color(0xFF25D366), // WhatsApp green
        'abbr': 'WA',
      };
    }
    if (messageText.contains('💳') || lower.startsWith('payment')) {
      return {
        'icon': Icons.payments,
        'color': const Color(0xFF7048E8), // Purple
        'day': extractFollowUpDay(messageText),
        'abbr': 'Pay',
      };
    }
    if (messageText.contains('📦') || lower.startsWith('sample')) {
      return {
        'icon': Icons.inventory_2_outlined,
        'color': const Color(0xFFAE3EC9), // Grape
        'abbr': 'Smpl',
      };
    }
    if (messageText.contains('🚚') || lower.startsWith('deliver')) {
      return {
        'icon': Icons.local_shipping,
        'color': const Color(0xFFF76707), // Orange
        'day': extractFollowUpDay(messageText),
        'abbr': 'Deliv',
      };
    }
    if (messageText.contains('📥') || lower.startsWith('collect')) {
      return {
        'icon': Icons.call_received,
        'color': const Color(0xFF0C8599), // Teal
        'day': extractFollowUpDay(messageText),
        'abbr': 'Coll',
      };
    }
    if (messageText.contains('🏷️') || lower.startsWith('negotiation')) {
      return {
        'icon': Icons.local_offer_outlined,
        'color': const Color(0xFFF08C00), // Amber
        'abbr': 'Nego',
      };
    }
    if (messageText.contains('🏆') ||
        lower.startsWith('won —') ||
        lower.startsWith('won:')) {
      return {
        'icon': Icons.emoji_events,
        'color': const Color(0xFF2F9E44), // Green
        'abbr': 'Won',
      };
    }
    if (messageText.contains('❌') ||
        lower.startsWith('lost —') ||
        lower.startsWith('lost:')) {
      return {
        'icon': Icons.cancel,
        'color': const Color(0xFFE03131), // Red
        'abbr': 'Lost',
      };
    }
    if (messageText.contains('📉') ||
        lower.startsWith('dropped —') ||
        lower.startsWith('dropped:')) {
      return {
        'icon': Icons.remove_circle_outline,
        'color': const Color(0xFF868E96), // Grey
        'abbr': 'Drop',
      };
    }

    // Assignee-side actions (check before follow-up — extension messages
    // contain a date but must not classify as follow-up)
    if (messageText.contains('🚧') || lower.contains('blocker raised')) {
      return {
        'icon': Icons.block,
        'color': const Color(0xFFC92A2A), // Dark red
        'abbr': 'Blk',
      };
    }
    if (lower.contains('approval requested')) {
      return {
        'icon': Icons.fact_check,
        'color': const Color(0xFF0B7285), // Teal
        'abbr': 'Req',
      };
    }
    if (messageText.contains('⏳') || lower.contains('extension requested')) {
      return {
        'icon': Icons.more_time,
        'color': const Color(0xFF3B5BDB), // Indigo
        'day': extractFollowUpDay(messageText),
        'abbr': 'Ext',
      };
    }
    if (messageText.contains('📈') || lower.contains('progress report')) {
      return {
        'icon': Icons.trending_up,
        'color': const Color(0xFF7048E8), // Purple
        'abbr': 'Prog',
      };
    }

    // Follow-up (check before reminder — follow-up messages may contain 'reminder')
    if (lower.contains('follow-up') ||
        lower.contains('follow up') ||
        lower.startsWith('followup') ||
        messageText.contains('Follow-up scheduled') ||
        // Mirrors the follow-up guard in detectActionType: a bare 📅 is shared
        // with deadline edits and scheduled-task notices, so require the token.
        (messageText.contains('📅') && lower.contains('follow'))) {
      return {
        'icon': Icons.event_note,
        'color': const Color(0xFF1971C2), // Blue
        'day': extractFollowUpDay(messageText),
        'abbr': 'Fup',
      };
    }

    // Reminder
    if (lower.contains('reminder') ||
        messageText.contains('sent a reminder') ||
        messageText.contains('Reminder scheduled')) {
      return {
        'icon': Icons.alarm,
        'color': const Color(0xFFE8590C), // Orange
        'abbr': 'Rem',
      };
    }

    // Warning / Escalation
    if (messageText.contains('\u26a0\ufe0f') ||
        messageText.contains('🚨') ||
        lower.contains('escalation') ||
        lower.contains('warning') ||
        messageText.contains('Warning')) {
      return {
        'icon': Icons.report_gmailerrorred,
        'color': const Color(0xFFE03131), // Red
        'abbr': 'Warn',
      };
    }

    // Query / Status Request
    if (lower.contains('status request') ||
        lower.contains('status report') ||
        messageText.contains('asked for an update') ||
        messageText.contains('requested a status') ||
        lower.startsWith('query') ||
        lower.contains('query #')) {
      return {
        'icon': Icons.question_mark,
        'color': const Color(0xFF7048E8), // Purple
        'abbr': 'Qry',
      };
    }

    return null;
  }

  /// Action types that stay open until someone acts on them (reply / mark done
  /// / grant / resolve) — the same set the card action chips and the
  /// bell/attention pending counts use. Informational types (reminder, warning,
  /// cash, progress, sales-cycle logs) are excluded there, so they are excluded
  /// here too.
  ///
  /// Lives here rather than only on `CardActionIcons` because the providers'
  /// unread-count write-through needs it as well, and card_action_icons.dart
  /// imports task_provider — a provider importing the widget back would be a
  /// cycle. `CardActionIcons.closureTypes` is now an alias of this, so the two
  /// can never drift.
  static const Set<String> actionClosureTypes = {
    'query',
    'approval',
    'extension',
    'blocker',
    'followup',
    'call',
    // Meeting / Visit / Demo: forward-dated commitments that stay open until
    // the owner marks them done — same affordance as a scheduled Call.
    'meeting',
    'sitevisit',
    'sample',
    // Quotation / Estimate / Negotiation: an awaiting-sign-off deal stage —
    // stays pending until the other side taps Approve (which writes the done
    // flag). Negotiation behaves identically.
    'quotation',
    'negotiation',
    // Field-service: a repair awaits sign-off; a verified job awaits closure.
    'repaired',
    'verified',
    // Delivery: scheduled hand-over stays open until marked delivered.
    'delivery',
    // Collection: the pick-up stays open until marked collected (and it gates
    // delivery — only a collected ticket can be delivered).
    'collect',
  };

  /// Display label per canonical [actionClosureTypes] key, in the order the
  /// "Needs Attention" tally should read. All four summary strips
  /// (task_actions, assignee_tasks, sales_actions, assignee_sales) render from
  /// this ONE map so their per-type tallies can never drift from each other or
  /// from the Needs Attention filter. Insertion order fixes display order.
  static const Map<String, String> actionAttentionLabels = {
    'query': 'Query',
    'followup': 'Follow-up',
    'approval': 'Request',
    'extension': 'Extension',
    'blocker': 'Blocker',
    'call': 'Call',
    'meeting': 'Meeting',
    'sitevisit': 'Visit',
    'sample': 'Demo',
    'quotation': 'Quotation',
    'negotiation': 'Negotiation',
    'delivery': 'Delivery',
    'collect': 'Collected',
    'repaired': 'Repaired',
    'verified': 'Verified',
  };

  /// Action types that close on a *reply* (someone answers) rather than a
  /// done-tick. Every other [actionClosureTypes] entry is an owed closure that
  /// stays open until it is explicitly marked done.
  ///
  /// 'approval' (Request) and 'query' (Query) are deliberately NOT here: both
  /// must stay open until the item is explicitly resolved — answering with a
  /// reply does not close them. A Request closes via Done (recipient) or Close
  /// (creator); a Query closes via Close (creator) only. Both write the generic
  /// done flag. An 'extension' still closes on the reply that grants/denies it.
  static const Set<String> _replyClosingActions = {'extension'};

  /// ⚠️ THE single "is this action still pending someone?" rule. Card chips,
  /// the Pending number, the bell, navigation badges and the Actions-tab
  /// Needs-Attention / Overdue filters all call this so they can never
  /// disagree (see the recurring stale-predicate-copies pitfall).
  /// - A done flag closes every type.
  /// - Anything outside [actionClosureTypes] is informational (reminder,
  ///   warning, cash, payment, progress, quotations, outcomes, edits…) and is
  ///   never pending — so it must not pile up in Overdue either.
  /// - Extension closes on a reply; query and approval (Request) stay open
  ///   until explicitly marked done/closed; all other closure types likewise
  ///   stay open until marked done.
  static bool isActionPending(
    String? actionType, {
    bool isDone = false,
    bool isReplied = false,
  }) {
    if (isDone || actionType == null) return false;
    if (!actionClosureTypes.contains(actionType)) return false;
    if (_replyClosingActions.contains(actionType)) return !isReplied;
    return true;
  }

  /// Canonicalise a Sales Actions-tab item's DISPLAY type back into the
  /// actions-table key the shared predicates expect. The Sales row loaders
  /// camelcase `followup` → `followUp` for labels, but every other key already
  /// matches [detectActionType]; this keeps those call sites honest.
  static String actionKeyFromDisplay(String type) =>
      type == 'followUp' ? 'followup' : type;

  /// Card last-message preview text. Every recognized action leads with its
  /// name followed by the details — ``<Action name>: <details>`` — so a
  /// Reminder, Follow-up, Cash, Query, etc. all read consistently (user rule).
  /// The leading emoji, the ``<Action label>: `` stem, the trailing
  /// ``by <actor> at <time>`` scaffolding and any wrapping quotes are stripped
  /// from the details half. Response notices (Done / Reply / Resolve) are
  /// rephrased to name the action they answered. Status-change lines render
  /// as ``Status: <old> → <new>``. Plain chat messages are returned untouched.
  static String cardPreviewText(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    // Status echo lines get their own compact form before the generic passes,
    // so the "by <actor> at <time>" tail never crowds the short preview.
    final status = _statusCardForm(raw);
    if (status != null) return status;
    // Response notices precede the classifier pass: detectActionType
    // deliberately returns null for them (chat-feed pointers, not actions),
    // so they would otherwise hit the plain-message early return below.
    final notice = _noticeCardForm(raw);
    if (notice != null) return notice;
    // Every recognized action renders as "<Action name>: <details>" (user:
    // lead with the action name like Reminder already does, consistent across
    // actions). Plain chat messages are returned untouched.
    final key = detectActionType(raw);
    if (key == null) return raw;
    return _actionCardForm(raw, key);
  }

  /// Display name (the part before the colon) for an action key. Cash keeps
  /// its verb in the detail (via _cashCardForm), so the name is the plain
  /// category here.
  static String _actionName(String key) {
    switch (key) {
      case 'reminder':
        return 'Reminder';
      case 'followup':
        return 'Follow-up';
      case 'query':
        return 'Query';
      case 'warning':
        return 'Warning';
      case 'blocker':
        return 'Blocker';
      case 'approval':
        return 'Approval';
      case 'extension':
        return 'Extension';
      case 'progress':
        return 'Progress';
      case 'quotation':
        return 'Quotation';
      case 'meeting':
        return 'Meeting';
      case 'sitevisit':
        return 'Site visit';
      case 'call':
        return 'Call';
      case 'cash':
        return 'Cash';
      case 'payment':
        return 'Payment';
      case 'sample':
        return 'Sample';
      case 'delivery':
        return 'Delivery';
      case 'collect':
        return 'Collect';
      case 'negotiation':
        return 'Negotiation';
      case 'won':
        return 'Won';
      case 'lost':
        return 'Lost';
      case 'dropped':
        return 'Dropped';
      case 'repaired':
        return 'Repaired';
      case 'verified':
        return 'Verified';
      case 'whatsapp':
        return 'WhatsApp';
      default:
        return key.isEmpty
            ? key
            : key[0].toUpperCase() + key.substring(1);
    }
  }

  /// ``<Action name>: <details>`` card preview. Cash reuses _cashCardForm so it
  /// reads "Cash: Added ₹500 — note" instead of a bare amount; every other
  /// action derives its details via _actionDetail.
  static String _actionCardForm(String raw, String key) {
    final name = _actionName(key);
    final detail = key == 'cash'
        ? (_cashCardForm(raw) ?? '')
        : _actionDetail(raw, name);
    return detail.isEmpty ? name : '$name: $detail';
  }

  /// The "details" half of an action preview: strip the leading emoji, the
  /// `<Label>:` stem (or the bare label word when there is no colon), the
  /// trailing ``by <Name> at <time>`` scaffolding, a leftover leading "for /
  /// until", and any wrapping double quotes — leaving just what the user
  /// typed plus any scheduled date.
  static String _actionDetail(String raw, String name) {
    var d = raw.split('\n').first.trim();
    d = d.replaceFirst(RegExp(r'^[\p{So}\p{Cf}\u200D\s]+', unicode: true), '');
    final colon = d.indexOf(':');
    if (colon > 0 &&
        colon <= 30 &&
        !d.substring(0, colon).contains(RegExp(r'[0-9]'))) {
      // Short digit-free label stem ("Follow-up scheduled:", "Due:").
      d = d.substring(colon + 1);
    } else {
      // No colon (e.g. `Reminder "call client"`) — drop the leading name word.
      d = d.replaceFirst(
        RegExp(
          '^\\s*${RegExp.escape(name)}'
          r'\b\s*(?:raised|scheduled|requested|report|changed|log)?\s*[:—–\-]?\s*',
          caseSensitive: false,
        ),
        '',
      );
    }
    d = d.replaceFirst(
      RegExp(r'\s+by\s+.+?\s+at\s+.+$', caseSensitive: false),
      '',
    );
    d = d.replaceFirst(RegExp(r'^\s*(?:for|until)\s+', caseSensitive: false), '');
    if (d.length >= 2 && d.startsWith('"') && d.endsWith('"')) {
      d = d.substring(1, d.length - 1);
    }
    return d.trim();
  }

  /// Compact card-preview form of a status-change line. The send-time text is
  /// ``📊 Status changed: <old> → <new> by <actor> at <time>`` (legacy wording
  /// used ``from <old> to <new>``); this drops the boilerplate and the
  /// actor/timestamp tail down to ``Status: <old> → <new>`` so the status change
  /// shows as a meaningful preview. Returns null for any non-status line, and
  /// a bare "📊 Status changed" when the transition can't be parsed.
  static String? _statusCardForm(String raw) {
    // Match the exact system-line signature (case-sensitive, same breadth the
    // old blanking used) so a plain chat message that merely mentions a
    // "status change" is never reformatted into a fake status preview.
    if (!raw.contains('Status changed') && !raw.contains('changed status to')) {
      return null;
    }
    final arrow = RegExp(
      r'Status changed:\s*(.+?)\s*→\s*(.+?)(?:\s+by\s.+|\s*$)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (arrow != null) {
      final before = arrow.group(1)!.trim();
      final after = arrow.group(2)!.trim();
      if (before.isNotEmpty && after.isNotEmpty) {
        return 'Status: $before → $after';
      }
    }
    // Legacy "… changed status to <new> …".
    final to = RegExp(
      r'changed status to (.+?)(?:\s+by\s.+|\s*$)',
      caseSensitive: false,
    ).firstMatch(raw);
    final newStatus = to?.group(1)?.trim();
    if (newStatus != null && newStatus.isNotEmpty) {
      return 'Status: $newStatus';
    }
    return 'Status';
  }

  /// Rephrase a response-notice line ("✅ Marked as done by Aditya (Follow up
  /// 1) at …") into the short card form the user asked for — "✓ Follow up 1 by
  /// Aditya", "↩ Query 2 replied by Aditya" — because the bare boilerplate
  /// never says WHAT was answered. The send-time text carries the referenced
  /// card's label in parentheses (see _noticeText in the detail screens); a
  /// legacy notice without the suffix degrades to verb + actor only. Returns
  /// null when the line is not a response notice (emoji lead + actor marker
  /// must both match, so a typed message is never mangled).
  static String? _noticeCardForm(String raw) {
    final lower = raw.toLowerCase();
    final isDone =
        raw.startsWith('✅') && lower.contains('marked as done by ');
    final isReply = raw.startsWith('↩') && lower.contains('replied by ');
    final isResolve =
        raw.startsWith('🔓') && lower.contains('blocker resolved by ');
    if (!isDone && !isReply && !isResolve) return null;
    // Labeled form first (non-greedy actor must not swallow the "(Label)"),
    // then the legacy "by <actor> at <time>" fallback.
    final labeled = RegExp(r'by (.+?) \((.+?)\) at ').firstMatch(raw);
    final actor = labeled?.group(1) ??
        RegExp(r'by (.+?) at ').firstMatch(raw)?.group(1) ??
        '';
    final label = labeled?.group(2);
    if (label != null && label.isNotEmpty) {
      if (isDone) return '✓ $label by $actor';
      if (isReply) return '↩ $label replied by $actor';
      return '🔓 $label resolved by $actor';
    }
    if (isDone) return '✓ Done by $actor';
    if (isReply) return '↩ Replied by $actor';
    return '🔓 Blocker resolved by $actor';
  }

  /// Compact card-preview form of a cash ledger line. Send text is
  /// "💵 Cash Added: ₹500 — note\nBalance: ₹800" (verbs Added / Expense /
  /// Refund) or "💵 Cash Settled — note\nBalance: …". The generic stem-strip
  /// would reduce these to "₹500 — note" — and a bare "₹500" (or just the
  /// number) when no note was typed — so render a self-describing
  /// ``<Verb> ₹amount — note`` phrase instead ("Added ₹500", "Expense ₹200",
  /// "Settled"). Returns null for anything that isn't a cash verb line, so
  /// Payment/Due (💳) and plain chat messages fall through untouched. The
  /// running-balance line is dropped — the card shows one clipped line.
  static String? _cashCardForm(String raw) {
    if (!raw.contains('💵') && !raw.toLowerCase().startsWith('cash')) {
      return null;
    }
    final firstLine = raw.split('\n').first.trim();
    final verbMatch = RegExp(
      r'Cash\s+(Added|Expense|Refund|Settled)',
      caseSensitive: false,
    ).firstMatch(firstLine);
    if (verbMatch == null) return null;
    final v = verbMatch.group(1)!.toLowerCase();
    final verb = v[0].toUpperCase() + v.substring(1);
    final amtMatch = RegExp(r'[₹$€£]\s?[\d,]+(?:\.\d+)?').firstMatch(firstLine);
    final amount = amtMatch?.group(0)?.replaceAll(RegExp(r'\s'), '');
    // Trailing note after the first dash separator; drop the auto
    // "Account settled" placeholder so a bare settle reads just "Settled".
    final note = RegExp(r'[—–-]\s+(.+)$').firstMatch(firstLine)?.group(1)?.trim() ?? '';
    final head = amount != null ? '$verb $amount' : verb;
    if (verb == 'Settled' && note.toLowerCase() == 'account settled') {
      return head;
    }
    return note.isEmpty ? head : '$head — $note';
  }

  /// True when this message text is an action line that awaits a response or
  /// closure from the recipient. Used to decide whether a system-typed action
  /// message should still raise an unread badge.
  static bool awaitsClosure(String? messageText) =>
      actionClosureTypes.contains(detectActionType(messageText));

  /// Whether a just-sent ACTION CARD is still undoable by its sender (a
  /// delete-for-everyone within the short undo window). True for any message
  /// the classifier recognises as an action — query, follow-up, call, meeting,
  /// visit, reminder, warning, cash, payment, progress, quotation, extension,
  /// request, … — and FALSE for:
  ///  • a plain status/edit/assignment system line (never classifies as an
  ///    action, so it stays a frozen, non-deletable audit entry), and
  ///  • a Blocker, which is a changeable choice the owner RESOLVES rather than
  ///    deletes.
  /// The caller layers the remaining conditions on top (is the sender, within
  /// the window, and no reply/done/child has landed on the card).
  static bool isUndoableAction(String? messageText) {
    final key = detectActionType(messageText);
    return key != null && key != 'blocker';
  }

  /// Detect action type from message text.
  /// Returns an action key ('reminder', 'followup', 'query', 'warning',
  /// 'cash', 'blocker', 'approval', 'extension', 'progress', 'quotation',
  /// 'meeting', 'sitevisit', 'call', 'payment', 'sample', 'negotiation',
  /// 'won', 'lost', 'dropped') or null.
  /// Used by write-through logic to populate the actions table.
  /// ⚠️ PRIMARY ACTION CLASSIFIER — this is the gate that decides whether a
  /// message is indexed into the SQLite actions table at all (write-through
  /// AND backfill in local_database_service.dart). A type missing here never
  /// reaches card strips or Actions tabs. New action types MUST be added here
  /// first; see ACTION-TYPE CHECKLIST in task_detail_screen.dart.
  static String? detectActionType(String? messageText) {
    if (messageText == null || messageText.isEmpty) return null;
    final lower = messageText.toLowerCase();

    // Response notifications ("↩️ Replied by …", "✅ Marked as done by …",
    // "🔓 Blocker resolved by …") are chat feed pointers, NOT actions
    // themselves — the card they reference holds the state. Their texts
    // collide with the keyword branches below (a real blocker card starts
    // "🚧 Blocker raised:"), so without this guard the resolved notice
    // classified as an OPEN blocker: the tap handler reopened the Raise
    // Blocker dialog and the dashboard/assignee pending counts grew a
    // phantom pending row. Signatures are the ' by …' actor suffix none
    // of the real action texts carry.
    if (lower.contains('replied by ') ||
        lower.contains('marked as done by ') ||
        lower.contains('blocker resolved by ')) {
      return null;
    }

    // Sales/CRM Query action posts "❓ Query: <note>" via the generic builder
    // (module_config emoji '❓' + label 'Query'). The bare-label check below
    // (startsWith('query')) misses it because the emoji leads the string, so it
    // never indexed → no card chip, no Actions-tab row, no pending count.
    // Match the emoji+label signature FIRST, before any keyword/emoji branch,
    // so a query whose note contains "follow up"/"reminder" (or a sales emoji)
    // still classifies as a query. A stray ❓ in a normal message won't match
    // unless immediately followed by " Query".
    if (messageText.contains('❓ Query')) return 'query';

    // Sales-cycle actions (check before generic types — e.g. "💳 Payment
    // Reminder" must match payment, not reminder)
    if (messageText.contains('💵') || lower.startsWith('cash')) return 'cash';
    if (messageText.contains('💰') || lower.startsWith('quotation'))
      return 'quotation';
    if (messageText.contains('🤝') || lower.startsWith('meeting'))
      return 'meeting';
    if (messageText.contains('🛠️') || lower.startsWith('site visit'))
      return 'sitevisit';
    // Field-service repair lifecycle (Service Teams). Check before the
    // generic follow-up/reminder keywords so a note mentioning "repair" or
    // "verify" doesn't mis-classify.
    if (messageText.contains('🔧') || lower.startsWith('repaired'))
      return 'repaired';
    if (messageText.contains('✔️') || lower.startsWith('verified'))
      return 'verified';
    if (messageText.contains('📞') || lower.startsWith('call log'))
      return 'call';
    // WhatsApp — customer communication action (informational, like Call).
    // Recorded by CustomerCommsService.whatsapp; format "💬 WhatsApp message…".
    if (messageText.contains('💬') || lower.startsWith('whatsapp'))
      return 'whatsapp';
    if (messageText.contains('💳') || lower.startsWith('payment'))
      return 'payment';
    if (messageText.contains('📦') || lower.startsWith('sample'))
      return 'sample';
    // Delivery — goods/parts handed over (Sales & Service). Dated + open until
    // marked delivered, so it is a real actionable due. Leads on the emoji so
    // a note containing other keywords still classifies correctly.
    if (messageText.contains('🚚') || lower.startsWith('deliver'))
      return 'delivery';
    // Collection — technician picks the device/item up (Service). Dated + open
    // until marked collected; gates delivery (only collected can be delivered).
    if (messageText.contains('📥') || lower.startsWith('collect'))
      return 'collect';
    if (messageText.contains('🏷️') || lower.startsWith('negotiation'))
      return 'negotiation';
    if (messageText.contains('🏆') ||
        lower.startsWith('won —') ||
        lower.startsWith('won:'))
      return 'won';
    if (messageText.contains('❌') ||
        lower.startsWith('lost —') ||
        lower.startsWith('lost:'))
      return 'lost';
    if (messageText.contains('📉') ||
        lower.startsWith('dropped —') ||
        lower.startsWith('dropped:'))
      return 'dropped';

    // Assignee-side actions (check before follow-up — extension messages
    // contain a date but must not classify as follow-up)
    if (messageText.contains('🚧') || lower.contains('blocker raised'))
      return 'blocker';
    if (lower.contains('approval requested')) return 'approval';
    if (messageText.contains('⏳') || lower.contains('extension requested'))
      return 'extension';
    if (messageText.contains('📈') || lower.contains('progress report'))
      return 'progress';

    // Follow-up (check before reminder)
    if (lower.contains('follow-up') ||
        lower.contains('follow up') ||
        lower.startsWith('followup') ||
        messageText.contains('Follow-up scheduled') ||
        // ⚠️ A bare 📅 is NOT a follow-up signature. Deadline edits
        // ("📅 Deadline updated: X → Y"), "📅 Task scheduled!" and
        // "📅 Reminder scheduled …" all lead with that emoji, and matching on it
        // alone indexed them as open Fup actions — phantom pending chips,
        // Actions-tab rows and inflated follow-up occurrence numbers. Require a
        // real follow-up token.
        (messageText.contains('📅') && lower.contains('follow'))) {
      return 'followup';
    }

    // Reminder
    if (lower.contains('reminder') ||
        messageText.contains('sent a reminder') ||
        messageText.contains('Reminder scheduled')) {
      return 'reminder';
    }

    // Warning / Escalation (legacy 'warning' key kept for data compatibility)
    if (messageText.contains('⚠️') ||
        messageText.contains('🚨') ||
        lower.contains('escalation') ||
        lower.contains('warning') ||
        messageText.contains('Warning')) {
      return 'warning';
    }

    // Query / Status Request
    if (lower.contains('status request') ||
        lower.contains('status report') ||
        messageText.contains('asked for an update') ||
        messageText.contains('requested a status') ||
        lower.startsWith('query') ||
        lower.contains('query #')) {
      return 'query';
    }

    return null;
  }

  /// Extract the signed cash delta from a cash action message.
  /// "💵 Cash Added: ₹500" → +500, "💵 Cash Expense: ₹200" → -200,
  /// "💵 Cash Refund: ₹100" → -100. Returns null for non-amount cash
  /// messages (e.g. "💵 Cash Settled") and non-cash messages.
  /// ⚠️ Regex is coupled to the exact text emitted by cash_action_dialog.dart
  /// _submit (verbs 'Added'/'Expense'/'Refund', '₹' + formatCashAmount output).
  /// Changing the format there breaks this parser and all cash balances.
  static double? extractCashDelta(String? text) {
    if (text == null || text.isEmpty) return null;
    final m = RegExp(
      r'Cash\s+(Added|Expense|Refund)\s*:\s*₹\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final amount = double.tryParse(m.group(2)!.replaceAll(',', ''));
    if (amount == null) return null;
    final verb = m.group(1)!.toLowerCase();
    // "Added" is an inflow (raises the balance); Expense / Refund are outflows.
    // Payment is NOT a cash inflow — it is tracked as a receivable collection
    // (see [extractReceivableDelta]) and never touches the cash balance.
    return verb == 'added' ? amount : -amount;
  }

  /// Receivables contribution from a "💳 Due: ₹…" / "💳 Collected: ₹…" line.
  /// Returns the (due, collected) amounts this single message adds; (0,0) for
  /// non-receivable messages. Only the FIRST line is parsed (the amount line) —
  /// the "Due · Collected · Outstanding" footer is display-only and would
  /// otherwise double-count. ⚠️ Regex coupled to cash_action_dialog.dart.
  static (double due, double collected) extractReceivableDelta(String? text) {
    if (text == null || text.isEmpty || !text.contains('💳')) {
      return (0, 0);
    }
    final amountLine = text.split('\n').first;
    final dueMatch = RegExp(
      r'Due\s*:\s*₹\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(amountLine);
    final collectedMatch = RegExp(
      r'Collected\s*:\s*₹\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(amountLine);
    final due = dueMatch != null
        ? (double.tryParse(dueMatch.group(1)!.replaceAll(',', '')) ?? 0)
        : 0.0;
    final collected = collectedMatch != null
        ? (double.tryParse(collectedMatch.group(1)!.replaceAll(',', '')) ?? 0)
        : 0.0;
    return (due, collected);
  }

  /// Running receivables across a list of message texts: total billed [due],
  /// total [collected] and the resulting [outstanding] (due − collected).
  static (double due, double collected, double outstanding) computeReceivables(
    Iterable<String?> texts,
  ) {
    double due = 0;
    double collected = 0;
    for (final t in texts) {
      final d = extractReceivableDelta(t);
      due += d.$1;
      collected += d.$2;
    }
    return (due, collected, due - collected);
  }

  /// Compute the running cash balance from a list of message texts
  /// (oldest or newest first — order doesn't matter for a sum).
  static double computeCashBalance(Iterable<String?> texts) {
    double balance = 0;
    for (final t in texts) {
      balance += extractCashDelta(t) ?? 0;
    }
    return balance;
  }

  /// Format an amount for cash messages: ₹1,250 or ₹1,250.50
  /// ⚠️ Output is parsed back by extractCashDelta's regex ([\d,] with optional
  /// decimals) — changing separators/currency symbol breaks cash balances.
  static String formatCashAmount(double amount) {
    final isWhole = amount == amount.roundToDouble();
    final s = isWhole
        ? amount.round().abs().toString()
        : amount.abs().toStringAsFixed(2);
    // Add thousand separators (Indian-style grouping not required; simple grouping)
    final parts = s.split('.');
    final buf = StringBuffer();
    final digits = parts[0];
    for (int i = 0; i < digits.length; i++) {
      buf.write(digits[i]);
      final remaining = digits.length - i - 1;
      if (remaining > 0 && remaining % 3 == 0) buf.write(',');
    }
    final sign = amount < 0 ? '-' : '';
    return parts.length > 1 ? '$sign₹$buf.${parts[1]}' : '$sign₹$buf';
  }

  /// Extract the day number from a follow-up message.
  /// e.g. "📅 Follow-up scheduled for 15/07/2025 ..." → '15'
  static String? extractFollowUpDay(String text) {
    // Match date patterns: dd/MM/yyyy, dd-MM-yyyy, or "15 Jul" etc.
    final m = RegExp(
      r'(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})',
    ).firstMatch(text);
    if (m != null) return m.group(1);
    // Try "for 15 Jul" or "for July 15"
    final m2 = RegExp(
      r'(?:for|on)\s+(?:\w+\s+)?(\d{1,2})(?:\s|,|$)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m2 != null) return m2.group(1);
    return null;
  }

  /// Parse a date string from action messages.
  /// Supports: dd/MM/yyyy HH:mm, "Jan 15, 2026 09:00 AM", "Jan 15, 2026", dd/MM/yyyy
  static DateTime? parseActionDate(String dateStr) {
    try {
      final trimmed = dateStr.trim();
      final months = {
        'Jan': 1,
        'Feb': 2,
        'Mar': 3,
        'Apr': 4,
        'May': 5,
        'Jun': 6,
        'Jul': 7,
        'Aug': 8,
        'Sep': 9,
        'Oct': 10,
        'Nov': 11,
        'Dec': 12,
      };
      // Format 1: "dd/MM/yyyy HH:mm"
      final m1 = RegExp(
        r'(\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2})',
      ).firstMatch(trimmed);
      if (m1 != null) {
        return DateTime(
          int.parse(m1.group(3)!),
          int.parse(m1.group(2)!),
          int.parse(m1.group(1)!),
          int.parse(m1.group(4)!),
          int.parse(m1.group(5)!),
        );
      }
      // Format 2: "Jan 15, 2026 09:00 AM"
      final m2 = RegExp(
        r'(\w+) (\d{1,2}), (\d{4}) (\d{1,2}):(\d{2}) (AM|PM)',
      ).firstMatch(trimmed);
      if (m2 != null) {
        var hour = int.parse(m2.group(4)!);
        final period = m2.group(6)!;
        if (period == 'PM' && hour < 12) hour += 12;
        if (period == 'AM' && hour == 12) hour = 0;
        return DateTime(
          int.parse(m2.group(3)!),
          months[m2.group(1)!] ?? 1,
          int.parse(m2.group(2)!),
          hour,
          int.parse(m2.group(5)!),
        );
      }
      // Format 3: "Jan 15, 2026"
      final m3 = RegExp(r'(\w+) (\d{1,2}), (\d{4})').firstMatch(trimmed);
      if (m3 != null) {
        return DateTime(
          int.parse(m3.group(3)!),
          months[m3.group(1)!] ?? 1,
          int.parse(m3.group(2)!),
          9,
          0,
        );
      }
      // Format 4: "dd/MM/yyyy"
      final m4 = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(trimmed);
      if (m4 != null) {
        return DateTime(
          int.parse(m4.group(3)!),
          int.parse(m4.group(2)!),
          int.parse(m4.group(1)!),
          9,
          0,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Parse all dates from an action message (For: <date> patterns, date patterns, etc.)
  static List<DateTime> parseAllActionDates(String messageText) {
    final results = <DateTime>[];
    // "For: <date>"
    for (final m in RegExp(
      r'For:\s*([^\n]+)',
      multiLine: true,
    ).allMatches(messageText)) {
      final dt = parseActionDate(m.group(1)!.trim());
      if (dt != null && !results.any((r) => r == dt)) results.add(dt);
    }
    // Standalone date patterns (dd/MM/yyyy) with an OPTIONAL trailing time —
    // "… at 10:00 AM" (Visit/Meeting captions) or "… 14:30" (Call/formatDateTime
    // captions). The old bare-date match built DateTime(y,m,d) = midnight, so a
    // 10:00 AM visit was indexed at 00:00 and its actions-list badge read
    // "12:00 AM". A date with no time defaults to 09:00 (same as parseActionDate
    // 's bare-date branch) so an undated action never shows midnight either.
    final dateWithTime = RegExp(
      r'(\d{2})/(\d{2})/(\d{4})(?:\s*(?:at\s+)?(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?)?',
    );
    for (final m in dateWithTime.allMatches(messageText)) {
      final (hour, minute) = _actionTimeFromParts(
        m.group(4),
        m.group(5),
        m.group(6),
      );
      final dt = DateTime(
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
        int.parse(m.group(1)!),
        hour,
        minute,
      );
      if (!results.any((r) => r == dt)) results.add(dt);
    }
    // "Jan 15, 2026" patterns — same optional trailing-time handling.
    final months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final monthWithTime = RegExp(
      r'(\w+) (\d{1,2}), (\d{4})(?:\s*(?:at\s+)?(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?)?',
    );
    for (final m in monthWithTime.allMatches(messageText)) {
      final mon = months[m.group(1)];
      if (mon != null) {
        final (hour, minute) = _actionTimeFromParts(
          m.group(4),
          m.group(5),
          m.group(6),
        );
        final dt = DateTime(
          int.parse(m.group(3)!),
          mon,
          int.parse(m.group(2)!),
          hour,
          minute,
        );
        if (!results.any((r) => r == dt)) results.add(dt);
      }
    }
    return results;
  }

  /// Hour/minute for a date match's optional trailing time parts. When no time
  /// was captured, fall back to 09:00 (workday default, matching
  /// [parseActionDate]'s bare-date branch) so a date-only action's badge never
  /// renders midnight ("12:00 AM"). Converts a 12-hour AM/PM pair when present.
  static (int hour, int minute) _actionTimeFromParts(
    String? hh,
    String? mm,
    String? ampm,
  ) {
    if (hh == null || mm == null) return (9, 0);
    var hour = int.parse(hh);
    final minute = int.parse(mm);
    final p = ampm?.toUpperCase();
    if (p == 'PM' && hour < 12) hour += 12;
    if (p == 'AM' && hour == 12) hour = 0;
    return (hour, minute);
  }
}
