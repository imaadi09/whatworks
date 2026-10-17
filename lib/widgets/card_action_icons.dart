import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../providers/task_provider.dart';
import '../utils/constants.dart';
import '../utils/helpers.dart';
import 'card_widgets.dart';

/// Single source of truth for the card bottom-row action icon strip.
///
/// Shared by TaskCard, SalesCard and the home-screen assignee card so the
/// actionType→icon/color mapping, the cached-message fallback scan and the
/// 22x22 chip rendering can never drift apart between modules.
class CardActionIcons {
  CardActionIcons._();

  /// Acronyms whose action needs attention and keeps a red chip (blocker,
  /// escalation, lost); every other action renders in the caller's calm base
  /// color so the card strip is not a rainbow of type colors. Escalation uses
  /// the legacy 'warning' key, so its acronym is 'Esc'.
  static const Set<String> _attentionAbbrs = {'Blk', 'Esc', 'Lost'};

  /// Action types that require a response, closure or next action from
  /// someone (reply / mark done / grant / resolve). Informational types
  /// (reminder, warning, cash, progress, sales-cycle logs) are excluded
  /// from the bell/attention-mode pending counts and chip strips.
  ///
  /// Aliased to Helpers so the providers' unread-count write-through can use
  /// the identical definition without importing this widget (which imports
  /// task_provider back).
  static const Set<String> closureTypes = Helpers.actionClosureTypes;

  /// Tiny green ✓ badge overlaid on a done/replied action so the action's
  /// own icon stays visible (shared by cards, chat, Activity log, Actions
  /// tab). Returns [child] unchanged when [done] is false.
  static Widget withDoneBadge(Widget child, {bool done = true}) {
    if (!done) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -3,
          right: -3,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: const Color(0xFF2F9E44),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1),
            ),
            child: const Icon(Icons.check, size: 6, color: Colors.white),
          ),
        ),
      ],
    );
  }

  /// Tiny gray "+" badge overlaid on the FIRST shown chip (top-left) when
  /// more actions are hidden in pending mode — replaces the old "+N" chip
  /// that consumed a slot and made the strip overlap. Mirrors
  /// [withDoneBadge] but on the opposite corner so the two never collide.
  static Widget withMoreBadge(Widget child) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -3,
          left: -3,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: const Color(0xFF868E96),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1),
            ),
            child: const Icon(Icons.add, size: 7, color: Colors.white),
          ),
        ),
      ],
    );
  }

  /// Compact detail for an Actions-tab row: shows only the user-posted
  /// content — the typed note/text, the date for extensions, the amount for
  /// cash. Generated scaffolding ("raised/scheduled/requested", `by Name`,
  /// "at <datetime>", "until") is stripped so the row after "|" carries
  /// just what the user typed.
  static String compactDetail(String message, {String typeName = ''}) {
    var d = message.trim();
    if (d.isEmpty) return '';
    final type = typeName.toLowerCase();

    // Cash: the amount only ("₹500").
    if (type == 'cash' || d.contains('💵')) {
      final m = RegExp(r'[₹$€£]?\s?\d[\d,]*(?:\.\d+)?').firstMatch(d);
      return (m?.group(0) ?? '').trim();
    }

    // Extension: the requested date only.
    if (type == 'extension') {
      final m = RegExp(
        r'until\s+(.+?)(?=\s+by\s|\s+at\s|$)',
        caseSensitive: false,
      ).firstMatch(d);
      if (m == null) return '';
      return m.group(1)!.split(' — ').first.replaceAll('"', '').trim();
    }

    // Follow-up: the quoted note if any, else the scheduled date.
    if (type == 'followup') {
      final q = RegExp(r'"([^"]+)"').firstMatch(d);
      if (q != null) return q.group(1)!.trim();
      final m = RegExp(
        r'scheduled:?\s*(?:for\s+)?(.+?)(?=\s+by\s|\s+at\s|$)',
        caseSensitive: false,
      ).firstMatch(d);
      return m != null ? m.group(1)!.trim() : '';
    }

    // Blocker / Request: the quoted user text only (no Raised/by Name).
    if (type == 'blocker' || type == 'approval') {
      final q = RegExp(r'"([^"]+)"').firstMatch(d);
      return q != null ? q.group(1)!.trim() : '';
    }

    // Everything else: strip leading emoji/symbols, the type prefix and any
    // trailing "by Name at <datetime>" scaffolding.
    d = d.replaceFirst(RegExp(r'^[^\w]*', unicode: true), '');
    d = d.replaceFirst(
      RegExp(
        r'^(?:query|follow[\s-]*up|followup|reminder|warning|blocker|approval(?:\s+request(?:ed)?)?|extension(?:\s+request(?:ed)?)?|status(?:\s+(?:report|request))?|progress(?:\s+report)?|call|cash(?:\s+(?:added|expense|refund|settled))?)\s*(?:#\s*\d+)?\s*[:\-\u2013\u2014\u00B7]?\s*',
        caseSensitive: false,
      ),
      '',
    );
    d = d.replaceFirst(
      RegExp(r'\s+by\s+.+?\s+at\s+.+$', caseSensitive: false),
      '',
    );
    return d.trim();
  }

  /// Ordering key for the Actions views: future-scheduled actions rank
  /// first (soonest due first); everything else follows, latest created
  /// first.
  static (int, int) actionSortTuple(DateTime scheduled, DateTime created) {
    final future = scheduled.isAfter(DateTime.now());
    return (
      future ? 0 : 1,
      future
          ? scheduled.millisecondsSinceEpoch
          : -created.millisecondsSinceEpoch,
    );
  }

  static int compareActions(
    DateTime schedA,
    DateTime creatA,
    DateTime schedB,
    DateTime creatB,
  ) {
    final ta = actionSortTuple(schedA, creatA);
    final tb = actionSortTuple(schedB, creatB);
    final c = ta.$1.compareTo(tb.$1);
    return c != 0 ? c : ta.$2.compareTo(tb.$2);
  }

  /// Most attention-worthy tuple of a group (earliest in display order).
  static (int, int) minActionTuple((int, int) a, (int, int) b) {
    final c = a.$1.compareTo(b.$1);
    if (c != 0) return c < 0 ? a : b;
    return a.$2 <= b.$2 ? a : b;
  }

  /// Numbering group key for the "#N" running counters on Actions-tab rows.
  /// Cash/Payment sub-types (Added/Expense/Refund/Settled, Due/Collected)
  /// share ONE family counter so row numbers agree with the chat cards'
  /// family numbering ("Cash Added 3" counts every 💵 entry).
  static String numberingGroupKey(String base) {
    if (base.startsWith('Cash')) return 'Cash';
    if (base.startsWith('Payment')) return 'Payment';
    return base;
  }

  /// Status-free base label for an action row — open and closed rows of one
  /// type share it so the "#N" running number stays on a single sequence.
  static String actionBaseLabel({
    required String typeName,
    required String message,
    String? overrideBase,
  }) {
    if (overrideBase != null) return overrideBase;
    final lower = message.toLowerCase();
    if (lower.startsWith('warning') || lower.contains('warning')) {
      return 'Warning';
    }
    if (typeName == 'query' ||
        lower.startsWith('query') ||
        lower.contains('status request')) {
      return 'Query';
    }
    if (lower.startsWith('status report')) return 'Status Report';
    if (lower.contains('follow-up') ||
        lower.contains('followup') ||
        lower.contains('follow up')) {
      return 'Follow-up';
    }
    if (typeName == 'blocker') return 'Blocker';
    if (typeName == 'approval') return 'Request';
    if (typeName == 'extension') return 'Extension';
    if (typeName == 'progressReport') return 'Progress Report';
    // Receivable entries (💳 Due/Collected) — checked BEFORE the cash catch
    // because Task action rows map 'payment' onto ActionType.cash.
    if (message.contains('💳') || lower.startsWith('payment')) {
      final firstLine = message.split('\n').first;
      if (firstLine.contains('Collected')) return 'Payment Collected';
      if (firstLine.contains('Due')) return 'Payment Due';
      return 'Payment';
    }
    if (typeName == 'cash' ||
        message.contains('💵') ||
        lower.startsWith('cash')) {
      if (message.contains('Cash Added')) return 'Cash Added';
      if (message.contains('Cash Expense')) return 'Cash Expense';
      if (message.contains('Cash Refund')) return 'Cash Refund';
      if (message.contains('Cash Settled')) return 'Cash Settled';
      return 'Cash';
    }
    if (typeName == 'call') return 'Call';
    // Dated commitments now surfaced on the Task Actions tab (widened enum).
    if (typeName == 'meeting' ||
        message.contains('🤝') ||
        lower.startsWith('meeting')) {
      return 'Meeting';
    }
    if (typeName == 'siteVisit' ||
        message.contains('🛠️') ||
        lower.startsWith('visit') ||
        lower.contains('site visit')) {
      return 'Visit';
    }
    // Sales-cycle / field-service cards. Actions-tab rows resolve these through
    // the ModuleConfig catalog label first, so this generic cascade never saw
    // them and they fell through to the 'Reminder' catch-all below.
    // [_responseRefLabel] deliberately REJECTS that catch-all (an unclassified
    // card must not be mislabeled), which left a "Marked as done" notice on a
    // Delivery / Sample-Demo / Quotation card rendering as a bare "✅ Done"
    // with no action name. Map the keys to the SAME words those cards' own
    // headers use so the notice reads "Delivery 1 · ✅ Done".
    const salesCycleBaseLabels = {
      'delivery': 'Delivery',
      'sample': 'Sample/Demo',
      'quotation': 'Quotation',
      'negotiation': 'Negotiation',
      'collect': 'Collected',
      'repaired': 'Repaired',
      'verified': 'Verified',
    };
    final salesCycleLabel = salesCycleBaseLabels[typeName];
    if (salesCycleLabel != null) return salesCycleLabel;
    return 'Reminder';
  }

  /// Core actionType → icon/color mapping. Replied/done actions keep their
  /// own icon and carry a 'done' flag (rendered as the ✓ badge) instead of
  /// being swapped for a generic check — the action identity stays visible.
  /// Returns null for unknown types (callers fall back to [neutralVisual] —
  /// the row is never dropped from a card strip).
  /// ⚠️ Task-module keys only — new action types need a case here (see
  /// ACTION-TYPE CHECKLIST in
  /// task_detail_screen.dart). This must cover EVERY key _runTaskAction can
  /// dispatch: the Task sheet also posts the sales-cycle actions (meeting,
  /// call, sitevisit, payment). A type missing here no longer disappears from
  /// the card — fromCachedIcons keeps it as a neutral pill — but it loses its
  /// icon identity, and the icon still matters wherever the entry is painted
  /// (chat/log). Sales/CRM cards resolve their own types via the ModuleConfig
  /// callback instead.
  static Map<String, dynamic>? visualFor(
    String actionType, {
    bool isReplied = false,
    bool isDone = false,
  }) {
    switch (actionType) {
      case 'followup':
        return {'icon': Icons.event_note, 'color': const Color(0xFF1971C2)};
      case 'reminder':
        return {'icon': Icons.alarm, 'color': const Color(0xFFE8590C)};
      case 'warning':
        return {'icon': Icons.error, 'color': const Color(0xFFE03131)};
      case 'query':
        return {
          'icon': Icons.question_mark,
          'color': const Color(0xFF7048E8),
          'done': isReplied,
        };
      case 'blocker':
        return {
          'icon': Icons.block,
          'color': const Color(0xFFC92A2A),
          'done': isDone,
        };
      case 'approval':
        return {
          'icon': Icons.fact_check,
          'color': const Color(0xFF0B7285),
          'done': isReplied,
        };
      case 'extension':
        return {
          'icon': Icons.more_time,
          'color': const Color(0xFF3B5BDB),
          'done': isReplied,
        };
      case 'progress':
        return {'icon': Icons.trending_up, 'color': const Color(0xFF7048E8)};
      case 'cash':
        return {
          'icon': Icons.account_balance_wallet,
          'color': const Color(0xFF099268),
        };
      // 🤝 Meeting / 📞 Call / 🛠️ Visit — dated commitments the Task sheet
      // posts (Sales parity). Open until the owner marks done; the ✓ lands via
      // the row's isDone in fromCachedIcons, so icon+color only is enough.
      // Icons/colors mirror Helpers.detectLastAction (fallback strip).
      case 'meeting':
        return {'icon': Icons.groups, 'color': const Color(0xFF3B5BDB)};
      case 'call':
        return {'icon': Icons.call, 'color': const Color(0xFF0C8599)};
      case 'sitevisit':
        return {'icon': Icons.handyman, 'color': const Color(0xFF1098AD)};
      // 💳 Payment receivable — reopened by the Cash/Payment dialog.
      case 'payment':
        return {'icon': Icons.payments, 'color': const Color(0xFF7048E8)};
      // WhatsApp — auto-recorded customer communication (like call/progress),
      // informational so it carries no done/replied state and is NOT a
      // closureType. Resolved here for Task cards and as the actionFor()
      // fallback for Sales/CRM cards.
      case 'whatsapp':
        return {'icon': Icons.chat, 'color': const Color(0xFF25D366)};
      default:
        return null;
    }
  }

  /// Short acronym printed inside the compact action chip so the action
  /// type reads at a glance (Fup = follow-up, Blk = blocker, Req = request…).
  /// Unknown types (module-specific) fall back to their first three letters.
  static String abbrFor(String actionType) {
    switch (actionType) {
      case 'followup':
        return 'Fup';
      case 'reminder':
        return 'Rem';
      case 'warning':
        // Escalation shares the legacy 'warning' key; print it as 'Esc' so the
        // chip reads as Escalation, never as the removed 'Warning' action.
        return 'Esc';
      case 'query':
        return 'Qry';
      case 'blocker':
        return 'Blk';
      case 'approval':
        return 'Req';
      case 'extension':
        return 'Ext';
      case 'progress':
        return 'Prog';
      case 'cash':
        return 'Cash';
      case 'quotation':
        return 'Quote';
      case 'meeting':
        return 'Meet';
      case 'sitevisit':
        return 'Visit';
      case 'repaired':
        return 'Fix';
      case 'verified':
        return 'Ver';
      case 'call':
        return 'Call';
      case 'whatsapp':
        return 'WA';
      case 'payment':
        return 'Pay';
      case 'sample':
        return 'Smpl';
      case 'delivery':
        return 'Deliv';
      case 'collect':
        return 'Coll';
      case 'negotiation':
        return 'Nego';
      case 'won':
        return 'Won';
      case 'lost':
        return 'Lost';
      case 'dropped':
        return 'Drop';
      default:
        return actionType.length >= 3
            ? actionType.substring(0, 3).toUpperCase()
            : actionType.toUpperCase();
    }
  }

  /// The visual every UNMAPPED action type gets on a chip strip. The chips
  /// print an acronym + number (the icon is never painted), so this only has
  /// to exist to keep the row in the strip — an unmapped type must never cost
  /// the card its newest action.
  static Map<String, dynamic> neutralVisual() => const {
    'icon': Icons.bolt,
    'color': AppTheme.secondaryText,
  };

  /// Decode cached actions-table rows (from the O(3) icon cache) into
  /// visual entries {icon, color, day}.
  ///
  /// [resolve] lets module cards (sales/CRM) map their own action types via
  /// ModuleConfig. A type nothing maps to is NOT dropped: the chips only print
  /// the acronym + occurrence number, so an unmapped type still renders as a
  /// neutral pill via [neutralVisual]. Dropping used to swallow the NEWEST
  /// action whenever its type was missing from the switch, so marking an
  /// action done made the single chip fall back to an older (already-done)
  /// action instead of updating.
  /// [hasDay] decides which types also carry a due day (default: followup only).
  static List<Map<String, dynamic>> fromCachedIcons(
    List<Map<String, dynamic>> cachedIcons, {
    Map<String, dynamic>? Function(
      String actionType,
      bool isReplied,
      bool isDone,
    )?
    resolve,
    bool Function(String actionType)? hasDay,
  }) {
    final List<Map<String, dynamic>> actions = [];
    for (final icon in cachedIcons) {
      final actionType = icon['actionType'] as String;
      final isReplied = (icon['isReplied'] as int) == 1;
      final isDone = ((icon['isDone'] as int?) ?? 0) == 1;
      final text = icon['text'] as String? ?? '';
      final visual =
          (resolve != null
              ? resolve(actionType, isReplied, isDone)
              : visualFor(actionType, isReplied: isReplied, isDone: isDone)) ??
          neutralVisual();
      final withDay = hasDay != null
          ? hasDay(actionType)
          : actionType == 'followup';
      final day = withDay ? Helpers.extractFollowUpDay(text) : null;
      actions.add({
        'icon': visual['icon'],
        'color': visual['color'],
        'day': day,
        'done': visual['done'] == true || isReplied || isDone,
        'abbr': abbrFor(actionType),
        'type': actionType,
        'isReplied': isReplied,
        'isDone': isDone,
        // Occurrence number baked on the chat card at send time (actions
        // index seqNo) — lets the chip read "Rem 4" like the card header does.
        'seqNo': icon['seqNo'] as int?,
      });
    }
    return actions;
  }

  /// Fallback when the actions cache is empty: scan cached messages newest
  /// first (max 3); replied queries keep their icon and get the ✓ badge.
  /// Returned OLDEST-FIRST (chronological, left→right on the card) to match
  /// the actions-table cache order.
  static List<Map<String, dynamic>> fromCachedMessages(
    List<MessageModel> messages,
  ) {
    final List<Map<String, dynamic>> actions = [];
    for (int i = messages.length - 1; i >= 0 && actions.length < 3; i--) {
      final msg = messages[i];
      final action = Helpers.detectLastAction(msg.text);
      if (action != null) {
        action['type'] = Helpers.detectActionType(msg.text);
        // Keep reply and done separate so the pendingOnly filter can apply
        // the per-type rule (a reply closes queries but not follow-ups).
        if (msg.isFollowUpDone) action['done'] = true;
        if (msg.isReplied) action['isReplied'] = true;
        // The messages cache carries the authoritative number, so the chip
        // reads identically whether it came from the actions index or here.
        if (msg.sequenceNumber != null) {
          action['seqNo'] = msg.sequenceNumber;
        }
        actions.add(action);
      }
    }
    return actions.reversed.toList();
  }

  /// Full task-module strip: actions-table cache → cached-message scan →
  /// last-message text detection, rendered as chips. Shared by TaskCard
  /// and the home-screen assignee card.
  static List<Widget> taskChips(
    BuildContext context,
    String taskId,
    String? messageText, {
    Color? baseColor,
    bool pendingOnly = false,
    bool fill = false,
  }) {
    // Try action icons cache first (from actions table — O(3) query)
    List<Map<String, dynamic>> actions = [];
    try {
      final taskProvider = Provider.of<TaskProvider>(context, listen: false);
      final cachedIcons = taskProvider.getActionIcons(taskId);
      if (cachedIcons != null && cachedIcons.isNotEmpty) {
        actions = fromCachedIcons(cachedIcons);
      }
    } catch (_) {}

    // Fallback: scan cached messages if no action icons in cache
    if (actions.isEmpty) {
      try {
        final taskProvider = Provider.of<TaskProvider>(context, listen: false);
        final messages = taskProvider.getCachedMessages(taskId);
        if (messages != null && messages.isNotEmpty) {
          actions = fromCachedMessages(messages);
        }
      } catch (_) {
        final action = Helpers.detectLastAction(messageText);
        if (action != null) actions.add(action);
      }
    }

    // Attention mode: keep only actions that still need a response or
    // closure — informational actions (reminders, warnings, cash, logs)
    // are hidden so the card shows just what is waiting on someone.
    if (pendingOnly) {
      actions.removeWhere((a) {
        final type = a['type'] as String?;
        final isDone = a['done'] == true || a['isDone'] == true;
        // A reply closes queries/requests/extensions; everything else in the
        // closure set stays open until marked done. Delegates to the single
        // shared rule so chips, pending counts and the Actions tab agree.
        return !Helpers.isActionPending(
          type,
          isDone: isDone,
          isReplied: a['isReplied'] == true,
        );
      });
    }

    return renderChips(
      actions,
      baseColor: baseColor,
      pendingMode: pendingOnly,
      fill: fill,
      // Task cards show ONLY the most recent action chip (the single
      // right-column pill in the redesigned card); Sales/CRM keep the
      // previous two-chip strip by calling renderChips directly.
      maxChips: 1,
    );
  }

  /// Render entries as compact acronym chips (filled color background,
  /// e.g. FU/AP/BL). Every chip prints the action's occurrence number
  /// ("Rem 4", "Fup 2") — the same number the chat card carries, counted
  /// per card — falling back to the due day ("Fup 28") only for rows baked
  /// without one. Actions read
  /// chronologically LEFT→RIGHT (oldest first, newest at the right).
  /// Only the last [maxChips] actions are shown (default 2; task cards pass
  /// 1). The leading "+N" overflow chip
  /// appears only in pending mode (attention toggle ON) — in the normal
  /// view the hidden count adds no information. Pending mode paints the
  /// chips solid orange with white text so they stand out at a glance.
  /// All chips share the CardMetaChip defaults (same padding, font and
  /// height) so every pill on a card is one uniform size. Returns the
  /// bare chips with NO separators — CardChipsRow places each one in
  /// its own Expanded slot of the line-1 chip row.
  static List<Widget> renderChips(
    List<Map<String, dynamic>> actions, {
    Color? baseColor,
    bool pendingMode = false,
    bool fill = false,
    int maxChips = 2,
  }) {
    if (actions.isEmpty) return <Widget>[];
    final shown = actions.length > maxChips
        ? actions.sublist(actions.length - maxChips)
        : actions;
    final hidden = actions.length - shown.length;
    final List<Widget> widgets = [];
    for (final action in shown) {
      final abbr = (action['abbr'] as String?) ?? 'ACT';
      // Attention items use the calm muted-red tint; pending mode paints
      // solid orange with white text; everything else joins the soft
      // card-pill family in the caller's base color.
      final attention = _attentionAbbrs.contains(abbr);
      // Normal action chips read as a neutral grey pill carrying the SAME
      // secondary-text grey as the line-2 state tiles (bg tint + label) —
      // colour on a card is reserved for genuine problems (the urgency flag /
      // attention chips). Pending (attention-toggle) chips keep the module
      // tint painted solid so they still stand out; attention chips get a grey
      // tile with problem-coloured text (red only for Lost).
      final isPending = pendingMode && !attention;
      final attentionTextColor = abbr == 'Lost'
          ? AppTheme.mutedRed
          : AppTheme.primaryText;
      final color = attention
          ? AppTheme.lightText
          : (isPending
                ? (baseColor ?? const Color(0xFF64748B))
                : AppTheme.secondaryText);
      final day = action['day'] as String?;
      final done = action['done'] == true;
      final seqNo = action['seqNo'] as int?;

      // Chip text: a SCHEDULED row prints its due day with the word "on"
      // ("Fup on 28") — when to act is the operative detail, and `day` is only
      // ever set for date-carrying types (follow-up always; in Sales/CRM also
      // anything with a date picker, see sales_card's hasDay callback). Every
      // other row prints its baked OCCURRENCE number hyphenated ("Qry-1"),
      // which is per card (baked at send time) and matches the chat card header
      // the action was taken on — that is what keeps a list of cards reading as
      // separate counts instead of one running sequence. The two markers are
      // the disambiguator: a bare "Fup 3" (due on the 3rd) was otherwise
      // byte-identical to occurrence #3. Plain acronym when neither applies.
      final label = day != null
          ? '$abbr on $day'
          : (seqNo != null ? '$abbr-$seqNo' : abbr);

      // Acronym chip; done actions keep the tiny ✓ badge on top
      widgets.add(
        withDoneBadge(
          CardMetaChip(
            label: label,
            color: color,
            textColor: attention
                ? attentionTextColor
                : (isPending ? null : AppTheme.secondaryText),
            solid: pendingMode && !attention,
            fill: fill,
          ),
          done: done,
        ),
      );
    }
    // Overflow cue: a tiny "+" on the first chip instead of a "+N" chip
    // (which consumed a slot and made the chip strip overlap).
    if (hidden > 0 && pendingMode && widgets.isNotEmpty) {
      widgets[0] = withMoreBadge(widgets[0]);
    }
    return widgets;
  }
}
