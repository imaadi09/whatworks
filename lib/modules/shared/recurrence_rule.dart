import 'dart:convert';
import 'dart:math' as math;

/// How often a series repeats. V1 keeps this deliberately small — daily /
/// weekly / monthly plus a "custom" day-interval. Anything more elaborate
/// (nth-weekday, count-based ends, exclusion dates) is intentionally out of
/// scope so the engine and UX stay simple.
enum RecurrenceFreq { daily, weekly, monthly, custom }

/// A compact, JSON-serializable recurrence rule.
///
/// Stored as a single TEXT column (`recurrence`) on the series ANCHOR row only;
/// generated occurrences carry `seriesId` but a null rule. All date math is
/// deterministic from [anchor] + the frequency so every device computes the
/// same occurrence dates (and therefore the same deterministic occurrence ids),
/// which is what makes materialization idempotent across restarts and devices.
class RecurrenceRule {
  final RecurrenceFreq freq;

  /// Every N days/weeks/months (>= 1). "Custom" uses this as a day interval.
  final int interval;

  /// 1=Mon..7=Sun. Reserved for weekly; V1 repeats on the anchor's weekday.
  final int? weekday;

  /// 1..31. Reserved for monthly; V1 repeats on the anchor's day-of-month.
  final int? dayOfMonth;

  /// First occurrence (date + time-of-day). The anchor item's own schedule.
  final DateTime anchor;

  /// Inclusive end of the series (null = never ends).
  final DateTime? endDate;

  /// Paused series produce no further occurrences until resumed.
  final bool paused;

  /// Materialized up to (exclusive). Advanced by the engine after each run so
  /// the next pass only considers the window beyond it.
  final DateTime? generatedUntil;

  const RecurrenceRule({
    required this.freq,
    this.interval = 1,
    this.weekday,
    this.dayOfMonth,
    required this.anchor,
    this.endDate,
    this.paused = false,
    this.generatedUntil,
  });

  RecurrenceRule copyWith({
    RecurrenceFreq? freq,
    int? interval,
    int? weekday,
    int? dayOfMonth,
    DateTime? anchor,
    DateTime? endDate,
    bool? paused,
    DateTime? generatedUntil,
  }) {
    return RecurrenceRule(
      freq: freq ?? this.freq,
      interval: interval ?? this.interval,
      weekday: weekday ?? this.weekday,
      dayOfMonth: dayOfMonth ?? this.dayOfMonth,
      anchor: anchor ?? this.anchor,
      endDate: endDate ?? this.endDate,
      paused: paused ?? this.paused,
      generatedUntil: generatedUntil ?? this.generatedUntil,
    );
  }

  /// True once [t] is past the series end date (never-ending series => false).
  bool isEndedBefore(DateTime t) => endDate != null && t.isAfter(endDate!);

  int get _step => interval < 1 ? 1 : interval;

  DateTime _advance(DateTime d) {
    switch (freq) {
      case RecurrenceFreq.daily:
      case RecurrenceFreq.custom:
        return d.add(Duration(days: _step));
      case RecurrenceFreq.weekly:
        return d.add(Duration(days: 7 * _step));
      case RecurrenceFreq.monthly:
        return _addMonths(d, _step);
    }
  }

  static DateTime _addMonths(DateTime d, int months) {
    final target = d.month + months;
    final year = d.year + (target - 1) ~/ 12;
    final month = ((target - 1) % 12) + 1;
    final day = math.min(d.day, _daysInMonth(year, month));
    return DateTime(year, month, day, d.hour, d.minute, d.second);
  }

  static int _daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  /// First occurrence strictly after [from], or null when the series has ended.
  /// Bounded loop: anchors are created "now", so this walks only a few steps in
  /// practice; the guard protects against a pathological far-past anchor.
  DateTime? nextOccurrenceAfter(DateTime from) {
    var c = anchor;
    var guard = 0;
    while (!c.isAfter(from)) {
      c = _advance(c);
      if (++guard > 5000) return null;
    }
    if (endDate != null && c.isAfter(endDate!)) return null;
    return c;
  }

  /// Occurrences in the half-open window ([from], [end]], capped at [limit].
  List<DateTime> occurrencesAfter(
    DateTime from,
    DateTime end, {
    int limit = 50,
  }) {
    final out = <DateTime>[];
    var c = nextOccurrenceAfter(from);
    var guard = 0;
    while (c != null &&
        !c.isAfter(end) &&
        out.length < limit &&
        guard++ < 5000) {
      out.add(c);
      c = _advance(c);
      if (endDate != null && c.isAfter(endDate!)) break;
    }
    return out;
  }

  Map<String, dynamic> toMap() => {
    'freq': freq.name,
    'interval': interval,
    if (weekday != null) 'weekday': weekday,
    if (dayOfMonth != null) 'dayOfMonth': dayOfMonth,
    'anchor': anchor.toIso8601String(),
    if (endDate != null) 'endDate': endDate!.toIso8601String(),
    'paused': paused,
    if (generatedUntil != null)
      'generatedUntil': generatedUntil!.toIso8601String(),
  };

  String toJson() => jsonEncode(toMap());

  factory RecurrenceRule.fromMap(Map<String, dynamic> m) {
    return RecurrenceRule(
      freq: RecurrenceFreq.values.firstWhere(
        (e) => e.name == m['freq'],
        orElse: () => RecurrenceFreq.daily,
      ),
      interval: (m['interval'] as num?)?.toInt() ?? 1,
      weekday: (m['weekday'] as num?)?.toInt(),
      dayOfMonth: (m['dayOfMonth'] as num?)?.toInt(),
      anchor:
          DateTime.tryParse((m['anchor'] as String?) ?? '') ?? DateTime.now(),
      endDate: m['endDate'] != null
          ? DateTime.tryParse(m['endDate'] as String)
          : null,
      paused: m['paused'] == true,
      generatedUntil: m['generatedUntil'] != null
          ? DateTime.tryParse(m['generatedUntil'] as String)
          : null,
    );
  }

  /// Null-safe parse of the stored JSON column. Returns null for a blank or
  /// malformed value so a bad row can never crash materialization.
  static RecurrenceRule? tryParse(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return RecurrenceRule.fromMap(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  /// Convert a LEGACY completion-driven rule map (`{'type','days'}`, stored in
  /// `extraFields['recurrence']` by the shipped Task feature) into a time-driven
  /// rule anchored at [anchor]. Calendar types map directly; 'afterCompletion'
  /// and 'none' have no time-driven equivalent → null (the item stops
  /// repeating). Used by the deferred Phase-2B migration + read-compat getter.
  static RecurrenceRule? fromLegacyMap(
    Map<String, dynamic> legacy, {
    required DateTime anchor,
  }) {
    final type = legacy['type'] as String? ?? 'none';
    final days = (legacy['days'] as num?)?.toInt() ?? 1;
    switch (type) {
      case 'daily':
        return RecurrenceRule(freq: RecurrenceFreq.daily, anchor: anchor);
      case 'weekly':
        return RecurrenceRule(freq: RecurrenceFreq.weekly, anchor: anchor);
      case 'monthly':
        return RecurrenceRule(freq: RecurrenceFreq.monthly, anchor: anchor);
      case 'custom':
        return RecurrenceRule(
          freq: RecurrenceFreq.custom,
          interval: days < 1 ? 1 : days,
          anchor: anchor,
        );
      default:
        return null; // 'none' and 'afterCompletion'
    }
  }

  /// Human label for chat/system messages and the deadline editor.
  String get label {
    final base = switch (freq) {
      RecurrenceFreq.daily =>
        interval > 1 ? 'Repeats every $interval days' : 'Repeats daily',
      RecurrenceFreq.weekly =>
        interval > 1 ? 'Repeats every $interval weeks' : 'Repeats weekly',
      RecurrenceFreq.monthly =>
        interval > 1 ? 'Repeats every $interval months' : 'Repeats monthly',
      RecurrenceFreq.custom =>
        'Repeats every $_step day${_step == 1 ? '' : 's'}',
    };
    final end = endDate != null ? ' until ${_fmtDate(endDate!)}' : '';
    return '$base$end${paused ? ' (paused)' : ''}';
  }

  /// Compact label for tight spots (e.g. the deadline DateCard).
  String get shortLabel {
    final base = switch (freq) {
      RecurrenceFreq.daily => interval > 1 ? 'every ${interval}d' : 'daily',
      RecurrenceFreq.weekly => interval > 1 ? 'every ${interval}w' : 'weekly',
      RecurrenceFreq.monthly => interval > 1 ? 'every ${interval}m' : 'monthly',
      RecurrenceFreq.custom => 'every ${_step}d',
    };
    return paused ? '$base · paused' : base;
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
