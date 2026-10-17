import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/helpers.dart';

/// Shared Cash + Receivables dialog used by the Task, Sales, and CRM detail
/// screens.
///
/// ONE sheet, TWO sections:
///  • Cash — Add Cash / Expense / Refund with an amount, or mark Settled.
///    Returns e.g. "💵 Cash Added: ₹500 — advance\nBalance: ₹800".
///  • Receivables (Sales/CRM only, when [includeReceivables]) — record what the
///    customer owes ("Due") and what has come in ("Collected"). Returns e.g.
///    "💳 Due: ₹5,000 — invoice\nDue ₹5,000 · Collected ₹0 · Outstanding ₹5,000".
///    Payment is NOT folded into the cash balance — it is a receivable, and the
///    running Due / Collected / Outstanding figures ride in the message footer
///    so they show in the chat bubble.
///
/// [costCategories] (display label, message keyword) adds an optional cost type
/// row to CASH entries (Service Teams billing: Visit Charge / Service Fee /
/// Parts). The category rides INSIDE the note (before the em-dash) so every
/// existing parser keeps working unchanged; the caller receives it separately
/// via [CashActionResult] to store the id→category map in extraFields.
class CashActionResult {
  final String text;
  final String? category;

  const CashActionResult({required this.text, this.category});
}

Future<CashActionResult?> showCashActionDialog(
  BuildContext context, {
  required double currentBalance,
  double currentDue = 0,
  double currentCollected = 0,
  List<(String, String)> costCategories = const [],
  bool includeReceivables = false,
}) {
  return showDialog<CashActionResult>(
    context: context,
    builder: (ctx) => _CashActionDialog(
      currentBalance: currentBalance,
      currentDue: currentDue,
      currentCollected: currentCollected,
      costCategories: costCategories,
      includeReceivables: includeReceivables,
    ),
  );
}

const Color _cashColor = Color(0xFF099268);
const Color _dueColor = Color(0xFF7048E8); // Purple — matches the payment chip

enum _OpKind { cashIn, cashOut, settle, due, collected }

/// One sub-operation row in the dialog. [verb] appears in the canonical
/// message ("💵 Cash <verb>: ₹…" / "💳 <verb>: ₹…"); [kind] decides which
/// section it belongs to and how the running figure is recomputed.
class _CashOp {
  final String label;
  final String verb;
  final IconData icon;
  final _OpKind kind;
  const _CashOp(this.label, this.verb, this.icon, this.kind);

  bool get isCash =>
      kind == _OpKind.cashIn || kind == _OpKind.cashOut || kind == _OpKind.settle;
  bool get isReceivable => kind == _OpKind.due || kind == _OpKind.collected;
  bool get isSettle => kind == _OpKind.settle;
  bool get takesAmount => !isSettle;
}

class _CashActionDialog extends StatefulWidget {
  final double currentBalance;
  final double currentDue;
  final double currentCollected;
  final List<(String, String)> costCategories;
  final bool includeReceivables;

  const _CashActionDialog({
    required this.currentBalance,
    this.currentDue = 0,
    this.currentCollected = 0,
    this.costCategories = const [],
    this.includeReceivables = false,
  });

  @override
  State<_CashActionDialog> createState() => _CashActionDialogState();
}

class _CashActionDialogState extends State<_CashActionDialog> {
  List<_CashOp> get _ops => [
    const _CashOp(
      'Add Cash',
      'Added',
      Icons.add_circle_outline,
      _OpKind.cashIn,
    ),
    const _CashOp(
      'Expense',
      'Expense',
      Icons.remove_circle_outline,
      _OpKind.cashOut,
    ),
    const _CashOp(
      'Refund',
      'Refund',
      Icons.replay_circle_filled_outlined,
      _OpKind.cashOut,
    ),
    const _CashOp('Settled', 'Settled', Icons.task_alt, _OpKind.settle),
    if (widget.includeReceivables) ...[
      const _CashOp('Due', 'Due', Icons.request_quote, _OpKind.due),
      const _CashOp('Collected', 'Collected', Icons.payments, _OpKind.collected),
    ],
  ];

  int _selectedOp = 0;
  int _selectedCostType = -1; // -1 = no category chosen
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  String? _amountError;

  _CashOp get _op => _ops[_selectedOp];
  bool get _isSettle => _op.isSettle;
  bool get _isReceivable => _op.isReceivable;
  bool get _showCategories =>
      _op.isCash && !_isSettle && widget.costCategories.isNotEmpty;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  double? get _enteredAmount =>
      double.tryParse(_amountController.text.replaceAll(',', '').trim());

  // Running figures for the selected entry, used by the preview + message.
  double get _newCashBalance {
    if (!_op.isCash || _isSettle) return widget.currentBalance;
    final amt = _enteredAmount ?? 0;
    return _op.kind == _OpKind.cashIn
        ? widget.currentBalance + amt
        : widget.currentBalance - amt;
  }

  double get _newDue =>
      _op.kind == _OpKind.due ? widget.currentDue + (_enteredAmount ?? 0) : widget.currentDue;

  double get _newCollected =>
      _op.kind == _OpKind.collected
      ? widget.currentCollected + (_enteredAmount ?? 0)
      : widget.currentCollected;

  double get _newOutstanding => _newDue - _newCollected;

  // ⚠️ CANONICAL MESSAGE FORMATS are defined here:
  //   Cash:       "💵 Cash Added: ₹500 — note\nBalance: ₹800"
  //   Cash settle:"💵 Cash Settled — note/Account settled\nBalance: ₹X"
  //   Receivable: "💳 Due: ₹5,000 — note\nDue ₹5,000 · Collected ₹0 · Outstanding ₹5,000"
  // Parsed by Helpers.extractCashDelta / extractReceivableDelta / detectActionType
  // and _buildSystemMessage in the task + sales detail screens (amount +
  // balance/outstanding lines). Changing these formats breaks those parsers —
  // update them together.
  void _submit() {
    if (_op.takesAmount) {
      final amt = _enteredAmount;
      if (amt == null || amt <= 0) {
        setState(() => _amountError = 'Enter a valid amount');
        return;
      }
    }

    final verb = _op.verb;
    final note = _noteController.text.trim();
    // Chosen cost type becomes the FIRST segment of the note (cash only), so
    // the canonical "amount — note" shape is untouched.
    final category = (_selectedCostType >= 0 && _showCategories)
        ? widget.costCategories[_selectedCostType].$1
        : null;
    final fullNote = category == null
        ? note
        : (note.isEmpty ? category : '$category — $note');

    final buf = StringBuffer();
    if (_isReceivable) {
      buf.write('💳 $verb: ${Helpers.formatCashAmount(_enteredAmount!)}');
      if (fullNote.isNotEmpty) buf.write(' — $fullNote');
      buf.write('\nDue ${Helpers.formatCashAmount(_newDue)}');
      buf.write(' · Collected ${Helpers.formatCashAmount(_newCollected)}');
      buf.write(' · Outstanding ${Helpers.formatCashAmount(_newOutstanding)}');
    } else {
      buf.write('💵 Cash ');
      if (_isSettle) {
        buf.write('Settled');
        buf.write(note.isNotEmpty ? ' — $note' : ' — Account settled');
      } else {
        buf.write('$verb: ${Helpers.formatCashAmount(_enteredAmount!)}');
        if (fullNote.isNotEmpty) buf.write(' — $fullNote');
      }
      buf.write('\nBalance: ${Helpers.formatCashAmount(_newCashBalance)}');
    }

    Navigator.of(context).pop(
      CashActionResult(text: buf.toString(), category: category),
    );
  }

  Color get _accent => _isReceivable ? _dueColor : _cashColor;

  Widget _chip(int i) {
    final op = _ops[i];
    final selected = _selectedOp == i;
    final color = op.isReceivable ? _dueColor : _cashColor;
    return ChoiceChip(
      avatar: Icon(op.icon, size: 16, color: selected ? Colors.white : color),
      label: Text(op.label),
      labelStyle: TextStyle(
        fontSize: 13,
        color: selected ? Colors.white : Colors.black87,
      ),
      selectedColor: color,
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => setState(() {
        _selectedOp = i;
        _amountError = null;
      }),
    );
  }

  List<int> _indicesWhere(bool Function(_CashOp) test) {
    final out = <int>[];
    for (var i = 0; i < _ops.length; i++) {
      if (test(_ops[i])) out.add(i);
    }
    return out;
  }

  Widget _sectionLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Container(width: 3, height: 12, color: color),
        const SizedBox(width: 6),
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: color,
          ),
        ),
      ],
    ),
  );

  String get _previewText {
    if (_isSettle) return 'Account will be marked as settled';
    if (_isReceivable) {
      return 'Due ${Helpers.formatCashAmount(_newDue)} · '
          'Collected ${Helpers.formatCashAmount(_newCollected)}\n'
          'Outstanding ${Helpers.formatCashAmount(_newOutstanding)}';
    }
    return 'New balance: ${Helpers.formatCashAmount(_newCashBalance)}';
  }

  @override
  Widget build(BuildContext context) {
    final cashIndices = _indicesWhere((o) => o.isCash);
    final recvIndices = _indicesWhere((o) => o.isReceivable);
    final headerFigure = _isReceivable
        ? _newOutstanding
        : _newCashBalance;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          Icon(
            _isReceivable ? Icons.payments : Icons.account_balance_wallet,
            color: _accent,
            size: 24,
          ),
          const SizedBox(width: 8),
          Text(
            widget.includeReceivables ? 'Cash / Payment' : 'Cash',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            Helpers.formatCashAmount(headerFigure),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('Cash', _cashColor),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: cashIndices.map(_chip).toList(),
            ),
            if (recvIndices.isNotEmpty) ...[
              const SizedBox(height: 14),
              _sectionLabel('Payment / Receivables', _dueColor),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: recvIndices.map(_chip).toList(),
              ),
            ],
            const SizedBox(height: 16),
            if (_op.takesAmount) ...[
              // Optional cost type (Service Teams billing categories, cash only).
              if (_showCategories) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(widget.costCategories.length, (i) {
                    final selected = _selectedCostType == i;
                    return ChoiceChip(
                      label: Text(widget.costCategories[i].$1),
                      labelStyle: TextStyle(
                        fontSize: 12,
                        color: selected ? Colors.white : Colors.black87,
                      ),
                      selectedColor: _cashColor,
                      selected: selected,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(
                        () => _selectedCostType = selected ? -1 : i,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                ],
                autofocus: true,
                onChanged: (_) => setState(() => _amountError = null),
                decoration: InputDecoration(
                  labelText: 'Amount',
                  prefixText: '₹ ',
                  errorText: _amountError,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _noteController,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: _isSettle
                    ? 'Note (optional)'
                    : (_showCategories && _selectedCostType >= 0
                          ? 'Details (optional)'
                          : (_showCategories
                                ? 'Cost type / details (optional)'
                                : 'Note (optional)')),
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Resulting figure preview (balance for cash, receivables for Due/Collected).
            Text(
              _previewText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
          ),
          child: Text(_isSettle ? 'Mark Settled' : 'Save'),
        ),
      ],
    );
  }
}
