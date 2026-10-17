import 'package:flutter/material.dart';

import '../models/message.dart';
import '../utils/constants.dart';
import '../utils/helpers.dart';

/// A single money transaction parsed from a chat message, with the running
/// total snapshot taken right AFTER it was applied (cash balance for the
/// ledger:'cash' pass, outstanding for 'payments').
class CashStatementEntry {
  final String messageId;
  final DateTime date;

  /// 'Added' / 'Expense' / 'Refund' / 'Settled' / 'Due' / 'Collected'
  final String verb;

  /// Signed cash delta, or the billed/received amount for receivable rows.
  final double amount;

  /// Amount printed unsigned (₹500); sign is conveyed by [isInflow] + color.
  final String display;
  final bool isInflow;

  /// Running total right after this entry (balance / outstanding).
  final double running;

  /// Sender display name resolved via the host screen's own lookup.
  final String actor;

  /// Note / cost-category segment from the message's first line, if any.
  final String note;

  /// True for the zero-delta 'Settled' marker (no amount in the text).
  final bool isSettled;

  const CashStatementEntry({
    required this.messageId,
    required this.date,
    required this.verb,
    required this.amount,
    required this.display,
    required this.isInflow,
    required this.running,
    required this.actor,
    this.note = '',
    this.isSettled = false,
  });
}

/// Parse cash/payment messages into chronological (oldest→newest) statement
/// entries with running totals.
///
/// [ledger] `'cash'` keeps 💵 Added/Expense/Refund (+ the Settled marker when
/// [includeSettledMarker]); `'payments'` keeps 💳 Due/Collected receivable
/// rows and snapshots Outstanding instead of the cash balance. Both reuse the
/// same [Helpers.extractCashDelta]/[Helpers.extractReceivableDelta] parsers as
/// the chat bubbles and the card summary strip, so the statement can never
/// disagree with the figures shown on the card.
List<CashStatementEntry> buildCashStatement(
  List<MessageModel> messages, {
  required String ledger,
  bool includeSettledMarker = false,
  String Function(String senderId)? senderNameOf,
}) {
  // Oldest → newest so the running totals accumulate correctly.
  final sorted = [...messages]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  double balance = 0;
  double due = 0;
  double collected = 0;
  final entries = <CashStatementEntry>[];

  for (final m in sorted) {
    final text = m.text;
    String actor = '';
    if (senderNameOf != null) {
      try {
        actor = senderNameOf(m.senderId);
      } catch (_) {
        actor = '';
      }
    }

    if (ledger == 'cash') {
      final delta = Helpers.extractCashDelta(text);
      if (delta != null) {
        balance += delta;
        // First line shape: "💵 Cash Added: ₹500 — note…"
        final verbMatch = RegExp(
          r'Cash\s+(Added|Expense|Refund)',
          caseSensitive: false,
        ).firstMatch(text);
        final verb = verbMatch?.group(1) ?? 'Cash';
        final amountStr = RegExp(
          r'₹\s*([\d,]+(?:\.\d+)?)',
        ).firstMatch(text)?.group(1);
        entries.add(
          CashStatementEntry(
            messageId: m.id,
            date: m.createdAt,
            verb: verb,
            amount: delta,
            display: '₹${amountStr ?? Helpers.formatCashAmount(delta.abs())}',
            isInflow: delta > 0,
            running: balance,
            actor: actor,
            note: _trailingNote(text.split('\n').first),
          ),
        );
      } else if (includeSettledMarker && text.contains('Cash Settled')) {
        entries.add(
          CashStatementEntry(
            messageId: m.id,
            date: m.createdAt,
            verb: 'Settled',
            amount: 0,
            display: '—',
            isInflow: false,
            running: balance,
            actor: actor,
            note: _trailingNote(text.split('\n').first),
            isSettled: true,
          ),
        );
      }
    } else {
      final (rowDue, rowCollected) = Helpers.extractReceivableDelta(text);
      if (rowDue == 0 && rowCollected == 0) continue;
      due += rowDue;
      collected += rowCollected;
      // First line shape: "💳 Due: ₹5,000 — invoice…" / "💳 Collected: ₹…"
      final verb = rowDue > 0 ? 'Due' : 'Collected';
      final amt = rowDue > 0 ? rowDue : rowCollected;
      final amountStr = RegExp(
        r'₹\s*([\d,]+(?:\.\d+)?)',
      ).firstMatch(text)?.group(1);
      entries.add(
        CashStatementEntry(
          messageId: m.id,
          date: m.createdAt,
          verb: verb,
          amount: amt,
          display: '₹${amountStr ?? Helpers.formatCashAmount(amt)}',
          // A Due raises the receivable (shown as an inflow of the ledger);
          // a Collection reduces it (shown as outflow-style grey-green).
          isInflow: verb == 'Due',
          running: due - collected,
          actor: actor,
          note: _trailingNote(text.split('\n').first),
        ),
      );
    }
  }
  return entries;
}

/// "💵 Cash Expense: ₹200 — site materials" → "site materials".
String _trailingNote(String firstLine) {
  final idx = firstLine.indexOf('—');
  if (idx < 0) return '';
  return firstLine.substring(idx + 1).trim();
}

/// Date-wise transaction statement popup shown when the user taps the Cash or
/// Payments row of the card's money summary. Groups entries under day headers
/// (Today / DD MMM YYYY), with a running total per row and a grand-total
/// footer. Tapping a row closes the sheet and scrolls the chat to that
/// message via [onJumpToMessage].
Future<void> showCashStatementSheet(
  BuildContext context, {
  required String title,
  required List<CashStatementEntry> entries,
  required String footerLabel,
  required String footerValue,
  void Function(String messageId)? onJumpToMessage,
}) {
  // Group by calendar day, newest day first; rows inside a day newest first
  // too (the statement reads like a bank passbook).
  final groups = <DateTime, List<CashStatementEntry>>{};
  for (final e in entries) {
    groups
        .putIfAbsent(
          DateTime(e.date.year, e.date.month, e.date.day),
          () => <CashStatementEntry>[],
        )
        .add(e);
  }
  final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(sheetCtx).size.height * 0.7,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.lightGrey,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Icon(
                    title.toLowerCase().contains('payment')
                        ? Icons.payments
                        : Icons.account_balance_wallet,
                    size: 18,
                    color: const Color(0xFF099268),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No transactions yet',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: days.length,
                      itemBuilder: (context, i) {
                        final day = days[i];
                        final rows = [...groups[day]!]
                          ..sort((a, b) => b.date.compareTo(a.date));
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                _dayLabel(day),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.secondaryText,
                                ),
                              ),
                            ),
                            ...rows.map(
                              (e) => _StatementRow(
                                entry: e,
                                onJump: onJumpToMessage == null
                                    ? null
                                    : () {
                                        Navigator.of(sheetCtx).pop();
                                        onJumpToMessage(e.messageId);
                                      },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            // Grand-total footer — same figure the card summary row shows.
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF7F8FA),
                border: Border(top: BorderSide(color: AppTheme.lightGrey)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      footerLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                  ),
                  Text(
                    footerValue,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF099268),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// "Today" / "Yesterday" / "30 Sep 2026" style day header.
String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff == -1) return 'Tomorrow';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final dateStr = '${d.day} ${months[d.month - 1]} ${d.year}';
  if (now.year == d.year) return dateStr.replaceAll(' ${d.year}', '');
  return dateStr;
}

class _StatementRow extends StatelessWidget {
  final CashStatementEntry entry;
  final VoidCallback? onJump;

  const _StatementRow({required this.entry, this.onJump});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    // Row accent: green for inflow, red for outflow; receivable Due rows use
    // amber (money promised, not received), collections use green.
    final color = e.isSettled
        ? AppTheme.secondaryText
        : e.verb == 'Due'
        ? const Color(0xFFF59F00)
        : e.verb == 'Collected'
        ? const Color(0xFF099268)
        : e.isInflow
        ? const Color(0xFF099268)
        : const Color(0xFFE03131);
    final icon = switch (e.verb) {
      'Added' => Icons.arrow_downward,
      'Expense' => Icons.arrow_upward,
      'Refund' => Icons.undo,
      'Settled' => Icons.task_alt,
      'Due' => Icons.request_quote,
      'Collected' => Icons.payments,
      _ => Icons.receipt_long,
    };

    return InkWell(
      onTap: onJump,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 15, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.actor.isEmpty ? e.verb : '${e.verb} · ${e.actor}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  if (e.note.isNotEmpty)
                    Text(
                      e.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                  Text(
                    '${TimeOfDay.fromDateTime(e.date).format(context)} · '
                    '${e.isSettled ? 'Account settled' : 'Balance: ${Helpers.formatCashAmount(e.running)}'}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!e.isSettled)
              Text(
                '${e.isInflow || e.verb == 'Collected' ? '+' : '−'}${e.display}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            if (onJump != null)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppTheme.lightGrey,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
