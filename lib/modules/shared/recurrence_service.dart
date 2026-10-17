import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/local_database_service.dart';
import '../../utils/paywall_constants.dart';
import 'recurrence_rule.dart';

/// Builds and persists ONE generated occurrence from an already-cloned row map.
/// Supplied by the caller (the app root) so the engine stays free of provider
/// dependencies and each module reuses its OWN existing create path
/// (`TaskProvider.createTask` / `BaseModuleProvider.createEnquiry`) — which in
/// turn reuses milestone templates, reminders, SQLite-first persistence and the
/// Firestore relay. Must throw [PlanLimitException] when the plan cap is hit so
/// the engine can stop that series and retry later.
typedef RecurrenceCreate = Future<void> Function(Map<String, dynamic> row);

/// Shared recurrence materialization engine (Phase-2A).
///
/// Time-driven, NOT completion-driven: a scheduled occurrence is created when
/// its date arrives regardless of whether the previous one is done. The engine
/// is bounded, incremental, idempotent and deferred — it does no work when no
/// series exist (the indexed `nextDue` query returns zero rows) and never
/// materializes distant-future work.
///
/// Identity/dedup: every logical occurrence has a deterministic id
/// `rec_<seriesId>_<yyyy-MM-dd>` derived from the series + occurrence date, so
/// repeated runs, restarts, provider refreshes and multiple devices all converge
/// on the same row/doc id instead of creating duplicates. No distributed lock,
/// no timing reliance.
class RecurrenceService {
  RecurrenceService._();
  static final RecurrenceService instance = RecurrenceService._();
  factory RecurrenceService() => instance;

  /// Near-term window to materialize. Small on purpose: occurrences are cheap
  /// to regenerate on the next run, so we never build a year of future items.
  static const int horizonDays = 14;

  /// Caps that keep a single run bounded regardless of how many series exist.
  static const int maxSeriesPerRun = 50;
  static const int maxOccurrencesPerSeries = 20;

  /// One-way latch: once the legacy completion-driven backlog is fully drained
  /// we never scan again. Safe to latch permanently because the shipped feature
  /// that wrote `extraFields['recurrence']` is retired, so no NEW legacy rows
  /// can ever appear (unlike a "recurrence in use" hint, this cannot drift).
  static const String legacyMigratedPref = 'recurrence_legacy_migrated_v1';

  /// Deterministic occurrence identity (the row PK and the Firestore doc id).
  static String occurrenceId(String seriesId, DateTime occ) {
    final key =
        '${occ.year.toString().padLeft(4, '0')}-'
        '${occ.month.toString().padLeft(2, '0')}-'
        '${occ.day.toString().padLeft(2, '0')}';
    return 'rec_${seriesId}_$key';
  }

  /// Materialize due occurrences for all three work-item tables. Runs the
  /// tables sequentially; each is independently bounded and idle when empty.
  Future<int> materializeAll({
    required RecurrenceCreate task,
    required RecurrenceCreate sales,
    required RecurrenceCreate crm,
  }) async {
    var created = 0;
    created += await materializeTable(table: 'tasks', create: task);
    created += await materializeTable(table: 'enquiries', create: sales);
    created += await materializeTable(table: 'crm_enquiries', create: crm);
    return created;
  }

  /// Materialize one table. Returns the number of occurrences created.
  Future<int> materializeTable({
    required String table,
    required RecurrenceCreate create,
    DateTime? now,
  }) async {
    final nowDt = now ?? DateTime.now();
    final horizonEnd = nowDt.add(const Duration(days: horizonDays));
    final db = LocalDatabaseService();

    // Bounded, index-backed candidate set: only anchors that can produce an
    // occurrence within the horizon. Empty (and effectively free) when unused.
    final anchors = await db.dueRecurrenceAnchors(
      table,
      horizonEnd.millisecondsSinceEpoch,
      limit: maxSeriesPerRun,
    );
    if (anchors.isEmpty) return 0;

    var created = 0;
    for (final row in anchors) {
      created += await _materializeAnchor(
        table: table,
        row: row,
        create: create,
        now: nowDt,
        horizonEnd: horizonEnd,
      );
    }
    return created;
  }

  Future<int> _materializeAnchor({
    required String table,
    required Map<String, dynamic> row,
    required RecurrenceCreate create,
    required DateTime now,
    required DateTime horizonEnd,
  }) async {
    final db = LocalDatabaseService();
    final anchorId = row['id'] as String;
    final rule = RecurrenceRule.tryParse(row['recurrence'] as String?);
    if (rule == null) return 0;
    final seriesId = (row['seriesId'] as String?) ?? anchorId;

    // Paused or ended → drop it from the due set so future runs skip it.
    if (rule.paused || rule.isEndedBefore(now)) {
      await _advanceIfChanged(
        table,
        row,
        anchorId,
        rule,
        rule.generatedUntil,
        null,
      );
      return 0;
    }

    final generatedUntil = rule.generatedUntil ?? rule.anchor;
    final due = rule.occurrencesAfter(
      generatedUntil,
      horizonEnd,
      limit: maxOccurrencesPerSeries,
    );

    if (due.isEmpty) {
      // Nothing new in the horizon; push nextDue forward so we don't rescan.
      final nextDue = rule.nextOccurrenceAfter(generatedUntil);
      await _advanceIfChanged(
        table,
        row,
        anchorId,
        rule,
        generatedUntil,
        nextDue,
      );
      return 0;
    }

    // One indexed lookup per due series (not per occurrence) → idempotency set.
    final existing = await db.seriesOccurrenceIds(table, seriesId);

    var lastMaterialized = generatedUntil;
    var created = 0;
    for (final occ in due) {
      final occId = occurrenceId(seriesId, occ);
      if (existing.contains(occId)) {
        lastMaterialized = occ; // already present (prior run / other device)
        continue;
      }
      final occRow = _cloneOccurrenceRow(
        row,
        occId: occId,
        seriesId: seriesId,
        occurrence: occ,
        now: now,
      );
      try {
        await create(occRow);
        lastMaterialized = occ;
        created++;
      } on PlanLimitException {
        // At the module's active-card cap: stop this series and leave
        // generatedUntil where it is so the next run retries (idempotent).
        break;
      } catch (_) {
        // Any other failure: don't advance past it; retry next run.
        break;
      }
    }

    final nextDue = rule.nextOccurrenceAfter(lastMaterialized);
    await _advanceIfChanged(
      table,
      row,
      anchorId,
      rule.copyWith(generatedUntil: lastMaterialized),
      lastMaterialized,
      nextDue,
    );
    return created;
  }

  /// Persist the anchor's advanced rule + nextDue, but only when something
  /// actually moved (avoids a needless write + change-set notify every run).
  Future<void> _advanceIfChanged(
    String table,
    Map<String, dynamic> row,
    String anchorId,
    RecurrenceRule newRule,
    DateTime? generatedUntil,
    DateTime? nextDue,
  ) async {
    final oldRule = RecurrenceRule.tryParse(row['recurrence'] as String?);
    final oldNextDue = row['nextDue'] as int?;
    final newNextDue = nextDue?.millisecondsSinceEpoch;
    final genChanged = oldRule?.generatedUntil != generatedUntil;
    final dueChanged = oldNextDue != newNextDue;
    if (!genChanged && !dueChanged) return;
    await LocalDatabaseService().advanceRecurrenceAnchor(
      table,
      anchorId,
      newRule.toJson(),
      newNextDue,
    );
  }

  /// Clone an anchor row into a fresh occurrence row. Starts from the anchor's
  /// own row (so it only ever contains columns valid for THIS table), then
  /// resets per-occurrence state. Milestones are cleared so the module's
  /// existing create path applies the current template to the occurrence.
  Map<String, dynamic> _cloneOccurrenceRow(
    Map<String, dynamic> anchor, {
    required String occId,
    required String seriesId,
    required DateTime occurrence,
    required DateTime now,
  }) {
    final row = Map<String, dynamic>.from(anchor);
    final nowMs = now.millisecondsSinceEpoch;

    row['id'] = occId;
    row['seriesId'] = seriesId;
    row['recurrence'] = null; // occurrences are never anchors
    row['nextDue'] = null;

    // Deadline lands on the occurrence date, preserving the anchor's time of
    // day so reminders fire at the expected hour.
    final anchorDeadline = anchor['deadline'] as int?;
    if (anchorDeadline != null) {
      final ad = DateTime.fromMillisecondsSinceEpoch(anchorDeadline);
      row['deadline'] = DateTime(
        occurrence.year,
        occurrence.month,
        occurrence.day,
        ad.hour,
        ad.minute,
      ).millisecondsSinceEpoch;
    } else {
      row['deadline'] = DateTime(
        occurrence.year,
        occurrence.month,
        occurrence.day,
      ).millisecondsSinceEpoch;
    }

    row['createdAt'] = nowMs;
    row['updatedAt'] = nowMs;
    row['progress'] = 0.0;

    // Reset per-occurrence state — only for columns this table actually has.
    void reset(String col, Object? value) {
      if (row.containsKey(col)) row[col] = value;
    }

    reset('isClosed', 0);
    reset('isCancelled', 0);
    reset('rating', null);
    reset('unreadCounts', '{}');
    reset('lastMessageText', null);
    reset('lastMessageTime', null);
    reset('reminderCount', 0);
    reset('warningCount', 0);
    reset('statusRequestCount', 0);
    reset('participantHistory', '[]');
    reset('displayId', null); // let the create path assign a fresh one
    reset('milestones', '[]'); // re-apply the current template on create
    reset('status', 'active');
    reset('isArchived', 0);
    reset('archivedAt', null);
    reset('archivedBy', null);
    reset('isDeleted', 0);
    reset('deletedAt', null);
    reset('deletedBy', null);

    return row;
  }

  /// One-time convergence (Phase-2B) of the SHIPPED completion-driven Task
  /// recurrence onto this time-driven engine. The old feature stored a rule map
  /// in `extraFields['recurrence']` and rolled the SAME row forward on close;
  /// that behavior is retired. Calendar rules (daily/weekly/monthly/custom) are
  /// converted into real series anchors on the dedicated column so those tasks
  /// keep repeating; `afterCompletion` has no time-driven equivalent, so its
  /// rule is dropped and the task simply stops repeating (flagged in the 2B
  /// report). Bounded by [limit] and idempotent: a converted row gains a
  /// non-null `recurrence` and loses the legacy `extraFields` key, so it never
  /// matches again. Returns the number of tasks converted.
  Future<int> migrateLegacyTaskRecurrence({int limit = 100}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(legacyMigratedPref) == true) return 0;
    final db = LocalDatabaseService();
    final rows = await db.legacyRecurrenceCandidates('tasks', limit: limit);
    if (rows.isEmpty) {
      await prefs.setBool(legacyMigratedPref, true);
      return 0;
    }
    var migrated = 0;
    for (final row in rows) {
      final id = row['id'] as String;
      Map<String, dynamic> extra = {};
      final rawExtra = row['extraFields'] as String?;
      if (rawExtra != null && rawExtra.isNotEmpty) {
        try {
          extra = Map<String, dynamic>.from(jsonDecode(rawExtra) as Map);
        } catch (_) {
          extra = {};
        }
      }
      final legacy = extra['recurrence'];
      extra.remove('recurrence'); // single source of truth = the new column
      final deadlineMs = row['deadline'] as int?;
      final anchor = deadlineMs != null
          ? DateTime.fromMillisecondsSinceEpoch(deadlineMs)
          : DateTime.now();
      final rule = legacy is Map
          ? RecurrenceRule.fromLegacyMap(
              Map<String, dynamic>.from(legacy),
              anchor: anchor,
            )
          : null;
      await db.applyRecurrenceMigration(
        'tasks',
        id,
        recurrence: rule?.toJson(),
        seriesId: rule != null ? id : null,
        nextDue: rule?.nextOccurrenceAfter(rule.anchor)?.millisecondsSinceEpoch,
        extraFields: jsonEncode(extra),
      );
      migrated++;
    }
    // Latch only once the backlog is fully drained (fewer candidates than the
    // cap); otherwise run again next launch to convert the remainder.
    if (migrated < limit) await prefs.setBool(legacyMigratedPref, true);
    return migrated;
  }
}
