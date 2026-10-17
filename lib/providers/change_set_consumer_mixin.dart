import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/local_database_service.dart';
import '../services/sync_telemetry.dart';

/// Shared change-set consumer (roadmap 4.1) for the list providers.
///
/// Replaces the amplifier described in SYNC_AND_DATABASE_ARCHITECTURE.md §4.1 —
/// "one row written → re-scan the whole table → rebuild the whole screen" —
/// with "patch just the rows that changed, in memory".
///
/// This is a COMMON resource: it is written once and mixed into both
/// [TaskProvider] and [BaseModuleProvider] (which Sales and CRM extend), so the
/// subscription, burst-coalescing, patch-vs-reload decision and notify
/// discipline are identical across all three modules. A module supplies only
/// the minimal hooks that touch its own in-memory list — the same hook pattern
/// [ModuleCachesMixin] already uses.
///
/// Safety-first: whenever a change-set is bulk (no ids), a delete, larger than
/// [patchThreshold], or the patch throws, it falls back to [fullReload] — the
/// exact behaviour the legacy table-name-only stream had. Patching is therefore
/// a strict optimisation, never a correctness risk.
mixin ChangeSetConsumerMixin<T> on ChangeNotifier {
  StreamSubscription<TableChange>? _changeSetSub;
  Timer? _changeSetDebounce;

  // The burst accumulated since the last flush: upserts, deletes (with known
  // ids), and a flag for any bulk/id-less event that forces a full reload.
  final Set<String> _pendingUpsertIds = <String>{};
  final Set<String> _pendingDeleteIds = <String>{};
  bool _pendingFullReload = false;
  DateTime? _changeSetFirstPendingAt;

  // Re-entrancy guard: a patch has an async fetch gap, so overlapping flushes
  // collapse into one trailing pass (mirrors TaskProvider's reload coalescing).
  bool _flushInFlight = false;
  bool _flushQueued = false;

  // ── Module hooks (the only module-specific surface) ───────────────────────

  /// The table whose change-sets drive this list (e.g. `tasks`, `enquiries`,
  /// `crm_enquiries`).
  @protected
  String get changeSetTable;

  /// Fetch ONLY [ids] that still belong in this user's list (module filter
  /// applied, newest first). Ids absent from the result were deleted or no
  /// longer match, and must be removed from the in-memory lists.
  @protected
  Future<List<T>> fetchRowsByIds(Set<String> ids);

  /// The id of a row, used to match it against the change-set.
  @protected
  String idOf(T row);

  /// Insert/replace [rows] into the in-memory list(s), re-splitting and
  /// re-sorting exactly as a full reload would (including any per-row
  /// side-work such as action-icon preload). Awaited before the single
  /// [notifyListeners], so a module can finish async side-work first.
  @protected
  Future<void> applyUpsertedRows(List<T> rows);

  /// Remove [ids] from the in-memory list(s).
  @protected
  void removeRowsByIds(Set<String> ids);

  /// The legacy full-table reload — the fallback for a bulk/id-less event, a
  /// burst larger than [patchThreshold], or any patch failure. MUST call
  /// [notifyListeners] itself when it changes the list (it replaces the whole
  /// list); the mixin notifies only on the surgical patch path.
  @protected
  Future<void> fullReload();

  /// Above this many changed ids in one burst, a single [fullReload] is cheaper
  /// than an N-id patch. Override for an unusually large/small list.
  @protected
  int get patchThreshold => 40;

  /// Debounce window that coalesces a burst of change-sets into one patch.
  @protected
  Duration get changeSetWindow => const Duration(milliseconds: 300);

  /// Hard cap so a never-pausing write burst still flushes (mirrors
  /// [LocalDatabaseService.tableChangesDebounced]'s `maxWait`).
  @protected
  Duration get changeSetMaxWait => const Duration(seconds: 2);

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Start consuming change-sets for [changeSetTable]. Idempotent: calling
  /// again replaces the previous subscription. Call after the first full load.
  @protected
  void startChangeSetConsumer() {
    _changeSetSub?.cancel();
    _changeSetSub = LocalDatabaseService()
        .tableChanges2
        .where((change) => change.table == changeSetTable)
        .listen(_onChangeSet);
  }

  /// Stop consuming and drop pending state. Call from `dispose`.
  @protected
  void stopChangeSetConsumer() {
    _changeSetSub?.cancel();
    _changeSetSub = null;
    _changeSetDebounce?.cancel();
    _changeSetDebounce = null;
    _pendingUpsertIds.clear();
    _pendingDeleteIds.clear();
    _pendingFullReload = false;
    _changeSetFirstPendingAt = null;
  }

  // ── Coalescing + dispatch ───────────────────────────────────────────────

  void _onChangeSet(TableChange change) {
    // An id-less (bulk) event has no rows to patch, so it forces the safe
    // full-reload path for the whole coalesced batch. Deletes WITH ids are
    // tracked separately and removed surgically — no full scan needed.
    if (change.ids.isEmpty) {
      _pendingFullReload = true;
    } else if (change.kind == ChangeKind.delete) {
      _pendingDeleteIds.addAll(change.ids);
    } else {
      _pendingUpsertIds.addAll(change.ids);
    }
    _changeSetFirstPendingAt ??= DateTime.now();

    _changeSetDebounce?.cancel();
    _changeSetDebounce = Timer(changeSetWindow, _flushChangeSet);

    // maxWait guarantee: don't starve if writes never pause for the window.
    if (DateTime.now().difference(_changeSetFirstPendingAt!) >=
        changeSetMaxWait) {
      _flushChangeSet();
    }
  }

  Future<void> _flushChangeSet() async {
    _changeSetDebounce?.cancel();
    _changeSetDebounce = null;
    _changeSetFirstPendingAt = null;

    if (_flushInFlight) {
      _flushQueued = true;
      return;
    }
    _flushInFlight = true;
    try {
      await _applyPendingChangeSet();
    } finally {
      _flushInFlight = false;
      if (_flushQueued) {
        _flushQueued = false;
        // Short delay so writes arriving during the pass batch together.
        _changeSetDebounce?.cancel();
        _changeSetDebounce = Timer(
          const Duration(milliseconds: 150),
          _flushChangeSet,
        );
      }
    }
  }

  Future<void> _applyPendingChangeSet() async {
    // Snapshot and clear the accumulators first so writes arriving during the
    // async fetch start a fresh burst rather than being lost.
    final upsertIds = Set<String>.of(_pendingUpsertIds);
    final deleteIds = Set<String>.of(_pendingDeleteIds);
    final forceFull = _pendingFullReload;
    _pendingUpsertIds.clear();
    _pendingDeleteIds.clear();
    _pendingFullReload = false;

    // A bulk/id-less event has no rows to patch -> trusted legacy full reload.
    if (forceFull) {
      SyncTelemetry.instance.recordChangeSetFullReload();
      await fullReload();
      return;
    }
    // An id both upserted and deleted in the same burst: the delete wins.
    upsertIds.removeAll(deleteIds);
    // Too many rows in one burst -> one full reload beats N by-ids patches.
    if (upsertIds.length + deleteIds.length > patchThreshold) {
      SyncTelemetry.instance.recordChangeSetFullReload();
      await fullReload();
      return;
    }
    if (upsertIds.isEmpty && deleteIds.isEmpty) return;

    try {
      var changed = false;
      final toRemove = Set<String>.of(deleteIds);
      if (upsertIds.isNotEmpty) {
        final rows = await fetchRowsByIds(upsertIds);
        final returnedIds = rows.map(idOf).toSet();
        // Ids we asked for but didn't get back were deleted or no longer match
        // this user's filter -> drop them from the in-memory lists.
        toRemove.addAll(upsertIds.difference(returnedIds));
        if (rows.isNotEmpty) {
          await applyUpsertedRows(rows);
          SyncTelemetry.instance.recordChangeSetPatch(rows.length);
          changed = true;
        }
      }
      if (toRemove.isNotEmpty) {
        removeRowsByIds(toRemove);
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (e) {
      // Any patch failure degrades to the trusted full reload.
      debugPrint(
        '[ChangeSet] patch failed for $changeSetTable; falling back to full '
        'reload: $e',
      );
      SyncTelemetry.instance.recordChangeSetFullReload();
      await fullReload();
    }
  }
}
