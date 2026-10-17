import 'package:flutter/material.dart';

import 'shared_detail_widgets.dart';

/// Result of the Schedule Call dialog: the chosen date/time plus the note.
class ScheduleCallResult {
  final DateTime when;
  final String note;
  // Picker rule (user): the date always defaults to tomorrow, but a TIME is
  // only attached when the user actually opens the clock and picks one.
  // hasTime == false means a day-only schedule: the chat caption carries just
  // the date (no fabricated hour), and the reminder/stored moment falls back
  // to [reminderAt].
  final bool hasTime;
  const ScheduleCallResult({
    required this.when,
    required this.note,
    this.hasTime = false,
  });

  /// A day-only schedule still needs a concrete instant for the local reminder
  /// and the stored scheduledAt. Default it to 09:00 — the same start-of-day
  /// time the actions indexer assumes — WITHOUT leaking that hour into the chat
  /// caption (the caption keys off [hasTime], not this).
  DateTime get reminderAt => hasTime
      ? when
      : DateTime(when.year, when.month, when.day, 9, 0);
}

const List<String> _kMonthsShort = [
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

String _fmtDate(DateTime d) =>
    '${_kMonthsShort[d.month - 1]} ${d.day}, ${d.year}';

String _fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final p = d.hour < 12 ? 'AM' : 'PM';
  return '$h:$m $p';
}

/// Single-popup "Schedule Call" dialog shared by Task and Sales/CRM.
///
/// Date and time are chosen through the native Material pickers (calendar +
/// clock dial) via two tappable rows, and the note box sits in the same popup.
/// This replaced an earlier six-spinner roller layout that users found
/// fiddly: the familiar system pickers are one tap each and need no scrolling.
Future<ScheduleCallResult?> showScheduleCallDialog(
  BuildContext context, {
  Color accentColor = const Color(0xFF0C8599),
  // Reusable for the paired "Schedule Meeting" flow: the caller swaps the
  // header icon + title; everything else (date/time rows + note box) is the
  // same appointment picker.
  String title = 'Schedule Call',
  IconData icon = Icons.call,
  // "Previous calls: 3" note. Callers pass the running count of this action
  // already on record so the sender knows which occurrence they are creating
  // (the chat numbers the resulting card previousCount + 1). Silent at 0.
  String previousLabel = '',
  int previousCount = 0,
  String previousEmoji = '',
}) async {
  final now = DateTime.now();
  // Picker rule: default to TOMORROW, day-only (no time). DateTime normalises
  // the day+1 overflow, so month/year boundaries are handled for free. The
  // hour stays 0 until the user actually opens the clock — [timeChosen] tracks
  // that so a left-untouched schedule sends only the date to the chat.
  var when = DateTime(now.year, now.month, now.day + 1);
  var timeChosen = false;
  String? errorText;

  // Mutable picker state lives in the showDialog builder (NOT inside the
  // StatefulBuilder builder — that closure re-runs on every setDialogState
  // and would silently reset everything).
  final noteController = TextEditingController();

  final result = await showDialog<ScheduleCallResult>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        Future<void> pickDate() async {
          final d = await showDatePicker(
            context: ctx,
            initialDate: when,
            firstDate: now,
            lastDate: now.add(const Duration(days: 365 * 2)),
          );
          if (d != null) {
            setDialogState(() {
              when = DateTime(d.year, d.month, d.day, when.hour, when.minute);
              errorText = null;
            });
          }
        }

        Future<void> pickTime() async {
          final t = await showTimePicker(
            context: ctx,
            // First open starts from 10:00 AM (a friendly business-hours
            // default) rather than the midnight placeholder.
            initialTime: timeChosen
                ? TimeOfDay.fromDateTime(when)
                : const TimeOfDay(hour: 10, minute: 0),
          );
          if (t != null) {
            setDialogState(() {
              when = DateTime(
                when.year,
                when.month,
                when.day,
                t.hour,
                t.minute,
              );
              timeChosen = true;
              errorText = null;
            });
          }
        }

        // One tappable row: icon + small label over the current value, with a
        // dropdown chevron so it reads as "tap to change".
        Widget field({
          required IconData icon,
          required String label,
          required String value,
          required VoidCallback onTap,
          // Optional trailing clear affordance (day-only Time row) so a chosen
          // time can be removed again — reverts to "not set", date-only.
          VoidCallback? onClear,
        }) {
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDEE2E6)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: accentColor),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF868E96),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (onClear != null) ...[
                    GestureDetector(
                      onTap: onClear,
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Color(0xFF868E96),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Icon(Icons.arrow_drop_down, color: Color(0xFF868E96)),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: [
              Icon(icon, color: accentColor, size: 24),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (previousCount > 0 && previousLabel.isNotEmpty) ...[
                  PreviousActionHint(
                    label: previousLabel,
                    count: previousCount,
                    color: accentColor,
                    emoji: previousEmoji,
                  ),
                  const SizedBox(height: 10),
                ],
                field(
                  icon: Icons.calendar_today,
                  label: 'Date',
                  value: _fmtDate(when),
                  onTap: pickDate,
                ),
                const SizedBox(height: 10),
                field(
                  icon: Icons.schedule,
                  label: 'Time',
                  value: timeChosen ? _fmtTime(when) : 'Not set (optional)',
                  onTap: pickTime,
                  onClear: timeChosen
                      ? () => setDialogState(() {
                              when = DateTime(
                                when.year,
                                when.month,
                                when.day,
                              );
                              timeChosen = false;
                            })
                      : null,
                ),
                const SizedBox(height: 14),
                // Note box lives in the same popup.
                TextField(
                  controller: noteController,
                  maxLines: 2,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Add a note for this call...',
                    counterText: '',
                    hintStyle: const TextStyle(fontSize: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: accentColor, width: 2),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
                if (errorText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      errorText!,
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (!when.isAfter(DateTime.now())) {
                  setDialogState(() => errorText = 'Pick a future date');
                  return;
                }
                Navigator.pop(
                  ctx,
                  ScheduleCallResult(
                    when: when,
                    note: noteController.text.trim(),
                    hasTime: timeChosen,
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Schedule'),
            ),
          ],
        );
      },
    ),
  );

  noteController.dispose();
  return result;
}
