import 'package:flutter/material.dart';
import '../modules/shared/recurrence_rule.dart';

/// Combined deadline + repeat picker for the Task module (Phase-2B).
///
/// ONE dialog holds the calendar and the repeat rule, so editing a deadline
/// never pops a second dialog. The repeat rule is now a time-driven
/// [RecurrenceRule] (stored on the dedicated `recurrence` column), NOT the old
/// completion-driven `extraFields['recurrence']` map — the shipped "roll the
/// same task forward on close" behavior is retired in favor of the shared
/// materializer generating separate occurrence rows.
///
/// V1 scope (deliberately small): Does not repeat / Daily / Weekly / Monthly /
/// Custom (every N days), plus an OPTIONAL end date and a pause toggle. The old
/// "X days after completion" type has no time-driven equivalent and is gone.
///
/// Returns null if dismissed/cancelled (caller keeps the existing date + rule),
/// or the chosen date plus rule on Set. [rule] is null when "Does not repeat"
/// is selected, which tells the caller to clear the series.
Future<({DateTime date, RecurrenceRule? rule})?> showDeadlinePicker(
  BuildContext context, {
  required DateTime initialDate,
  RecurrenceRule? initialRule,
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final now = DateTime.now();
  return showDialog<({DateTime date, RecurrenceRule? rule})>(
    context: context,
    builder: (ctx) => _DeadlinePickerDialog(
      initialDate: initialDate,
      initialRule: initialRule,
      firstDate: firstDate ?? now,
      lastDate: lastDate ?? now.add(const Duration(days: 365)),
    ),
  );
}

/// Dropdown labels in display order. 'none' is first and the default, so the
/// picker opens collapsed on "Does not repeat" and only reveals the rest when
/// the user pulls the dropdown open.
const List<(String, String)> _kRecurrenceOptions = [
  ('none', 'Does not repeat'),
  ('daily', 'Daily'),
  ('weekly', 'Weekly'),
  ('monthly', 'Monthly'),
  ('custom', 'Custom (every N days)'),
];

class _DeadlinePickerDialog extends StatefulWidget {
  const _DeadlinePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    this.initialRule,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final RecurrenceRule? initialRule;

  @override
  State<_DeadlinePickerDialog> createState() => _DeadlinePickerDialogState();
}

class _DeadlinePickerDialogState extends State<_DeadlinePickerDialog> {
  late DateTime _date;
  late String _type;
  late int _days;
  late bool _hasEnd;
  DateTime? _endDate;
  late bool _paused;
  final TextEditingController _dayController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // CalendarDatePicker asserts initialDate sits inside [firstDate, lastDate].
    // An existing deadline in the past (before firstDate) would crash it, so
    // clamp for display; the caller still rebuilds end-of-day from this date.
    _date = widget.initialDate;
    if (_date.isBefore(widget.firstDate)) _date = widget.firstDate;
    if (_date.isAfter(widget.lastDate)) _date = widget.lastDate;

    final r = widget.initialRule;
    if (r != null) {
      _type = switch (r.freq) {
        RecurrenceFreq.daily => 'daily',
        RecurrenceFreq.weekly => 'weekly',
        RecurrenceFreq.monthly => 'monthly',
        RecurrenceFreq.custom => 'custom',
      };
      _days = r.interval < 1 ? 7 : r.interval;
      _endDate = r.endDate;
      _hasEnd = r.endDate != null;
      _paused = r.paused;
    } else {
      _type = 'none';
      _days = 7;
      _endDate = null;
      _hasEnd = false;
      _paused = false;
    }
    _dayController.text = '$_days';
  }

  @override
  void dispose() {
    _dayController.dispose();
    super.dispose();
  }

  bool get _needsDays => _type == 'custom';
  bool get _repeats => _type != 'none';

  static DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59);

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _date.add(const Duration(days: 30)),
      firstDate: _date,
      lastDate: _date.add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _endDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Row(
        children: [
          Icon(Icons.event, color: Color(0xFF3B5BDB)),
          SizedBox(width: 8),
          Text('Deadline'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CalendarDatePicker(
                initialDate: _date,
                firstDate: widget.firstDate,
                lastDate: widget.lastDate,
                onDateChanged: (d) => setState(() => _date = d),
              ),
              const SizedBox(height: 8),
              // Repeat, collapsed to a dropdown that defaults to "Does not
              // repeat"; the other options only appear when it is pulled open.
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Repeat',
                  prefixIcon: Icon(Icons.repeat, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _type,
                    isExpanded: true,
                    style: const TextStyle(fontSize: 14, color: Colors.black87),
                    items: [
                      for (final o in _kRecurrenceOptions)
                        DropdownMenuItem<String>(
                          value: o.$1,
                          child: Text(o.$2),
                        ),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? 'none'),
                  ),
                ),
              ),
              if (_needsDays)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Row(
                    children: [
                      const Text('Every', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 68,
                        child: TextField(
                          controller: _dayController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          onChanged: (v) =>
                              _days = int.tryParse(v.trim()) ?? _days,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('day(s)', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              // Optional end date + pause, only meaningful once it repeats.
              if (_repeats) ...[
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Set end date', style: TextStyle(fontSize: 14)),
                  value: _hasEnd,
                  onChanged: (v) => setState(() {
                    _hasEnd = v;
                    if (v && _endDate == null) {
                      _endDate = _date.add(const Duration(days: 30));
                    }
                  }),
                ),
                if (_hasEnd)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _pickEndDate,
                      icon: const Icon(Icons.event_available, size: 18),
                      label: Text(
                        _endDate == null
                            ? 'Choose end date'
                            : 'Ends ${_fmt(_endDate!)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Paused', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    'Hold future occurrences without deleting the series',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _paused,
                  onChanged: (v) => setState(() => _paused = v),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            RecurrenceRule? rule;
            if (_repeats) {
              final freq = switch (_type) {
                'daily' => RecurrenceFreq.daily,
                'weekly' => RecurrenceFreq.weekly,
                'monthly' => RecurrenceFreq.monthly,
                _ => RecurrenceFreq.custom,
              };
              rule = RecurrenceRule(
                freq: freq,
                interval: _type == 'custom' ? (_days < 1 ? 1 : _days) : 1,
                // Anchor at end-of-day so it matches the deadline the caller
                // stores (date-only pickers normalize to 23:59).
                anchor: _endOfDay(_date),
                endDate: _hasEnd && _endDate != null
                    ? _endOfDay(_endDate!)
                    : null,
                paused: _paused,
              );
            }
            Navigator.pop(context, (date: _date, rule: rule));
          },
          child: const Text('Set'),
        ),
      ],
    );
  }
}
