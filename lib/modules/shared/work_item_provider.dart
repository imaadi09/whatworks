import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../providers/assignee_identity_repair_mixin.dart';
import '../../providers/change_set_consumer_mixin.dart';
import '../../providers/module_caches_mixin.dart';
import '../../providers/pagination_mixin.dart';
import '../../providers/unread_counts_mixin.dart';
import '../../services/sync_telemetry.dart';
import '../../utils/helpers.dart';
import 'team_management_mixin.dart';
import 'work_item.dart';

/// Type-generic list engine shared by the module providers.
///
/// Holds ONLY what is common to every [WorkItem] module — the in-memory list,
/// the loading/error/filter/sort STATE, the pagination + change-set plumbing,
/// the message/action-icon caches, the fresh-install recovery sweep, the teams
/// wiring and the identity-repair field adapters — all expressed against
/// `T extends [WorkItem]`. Everything concrete-typed (SQLite reads, remote
/// transport, `copyWith` mutations, status/clientName filtering) is left as an
/// abstract hook for the subclass to supply.
///
/// [BaseModuleProvider] supplies the `EnquiryModel` flavor and is the ONLY
/// consumer of this engine: Sales and CRM both run this single-`items` list.
///
/// ARCHITECTURAL DIVERGENCE (Step 5a finding; deliberate, not a gap): the Task
/// module does NOT extend this engine and will not be migrated onto it. Task
/// needs a THREE-list provider model partitioned by ownership (`_byMeTasks`,
/// `_toMeTasks`, `_participantTasks`, surfaced as the byMe/toMe/participant/
/// deleted/archived views), which a single `items` list cannot represent
/// without changing Task semantics: its filter/sort defaults, recovery and
/// repair candidate sets and paging hooks are all three-list shaped. `TaskModel`
/// is therefore intentionally left WITHOUT `implements WorkItem` (no nominal
/// convergence). Shared Task vs Sales/CRM behavior stays deduplicated one layer
/// down, at the 6 generic `<T>` mixins (ModuleCaches, TeamManagement,
/// ChangeSetConsumer, UnreadCounts, AssigneeIdentityRepair, Pagination) that
/// BOTH `TaskProvider` and `BaseModuleProvider` apply directly. Do not migrate
/// Task here unless a concrete future duplication problem justifies
/// redesigning this base.
///
/// ⚠️ PARITY RULE: The Task module is this app's reference implementation.
/// EVERY correction and enhancement made in the Task module MUST be replicated
/// here (and in the concrete subclasses) so behavior stays identical across
/// modules. When a Task-module fix lands, audit this engine and port the gap.
abstract class WorkItemProvider<T extends WorkItem> extends ChangeNotifier
    with
        ModuleCachesMixin,
        TeamManagementMixin,
        ChangeSetConsumerMixin<T>,
        UnreadCountsMixin,
        AssigneeIdentityRepairMixin<T>,
        PaginationMixin<T> {
  /// Telemetry hook (shared by Sales + CRM): count provider notifications.
  /// Purely observational — a no-op unless diagnostics recording is enabled.
  ///
  /// [revision] also advances on every notify so derived UI values (the home
  /// Actions badge `_attentionCount`) can memoize on data change instead of
  /// recomputing on every rebuild — see R3 in DB_SYNC_FIREBASE_EFFICIENCY.md.
  int revision = 0;

  @override
  void notifyListeners() {
    revision++;
    SyncTelemetry.instance.recordNotify();
    super.notifyListeners();
  }

  // ── Generic engine state ───────────────────────────────────────────────
  // @protected (not library-private) so the concrete subclass — which lives in
  // a different library — can drive the SAME list/flags the generic methods
  // below read and write. There is exactly one copy of this state.
  @protected
  List<T> items = [];
  @protected
  bool loading = false;
  @protected
  String? error;
  @protected
  String? loadedUserId;

  // Filter/sort STATE. The concrete subclass applies the module-specific
  // filtering/sorting (status pipeline, clientName search, ...); the state and
  // its setters are identical across modules, so they live here.
  @protected
  String statusFilterValue = 'All';
  @protected
  String sortByValue = 'Last Action';
  @protected
  String searchQueryValue = '';

  // Cursor uid captured by the concrete load-more wrapper for [fetchPage].
  @protected
  String? pagingUserId;

  /// Normalized phone of the signed-in user (phone-auth app, so populated after
  /// login). Single source for the phone-based item sync and the identity-repair
  /// hook below.
  @protected
  String? get currentUserPhone =>
      Helpers.normalizePhone(FirebaseAuth.instance.currentUser?.phoneNumber);

  // ── Public read-only getters ───────────────────────────────────────────
  bool get isLoading => loading;
  String? get errorMessage => error;
  String get statusFilter => statusFilterValue;
  String get sortBy => sortByValue;
  String get searchQuery => searchQueryValue;

  /// Public rebuild trigger so settings screens (e.g. milestone enable toggle)
  /// can refresh list cards immediately. Named distinctly from the silent data
  /// reload, which takes a userId.
  void rebuildCards() => notifyListeners();

  /// Signature of the current [items] — see [workItemSignature]. A reload
  /// compares this before/after and skips its notify when nothing a card
  /// renders actually changed, so a sync burst that decodes to the same rows
  /// no longer rebuilds the whole list for identical pixels.
  @protected
  String currentItemsSignature() => workItemListSignature(items);

  bool get hasActiveFilters =>
      statusFilterValue != 'All' || sortByValue != 'Last Action';

  void setStatusFilter(String filter) {
    statusFilterValue = filter;
    notifyListeners();
  }

  void setSortBy(String sort) {
    sortByValue = sort;
    notifyListeners();
  }

  void clearFilters() {
    statusFilterValue = 'All';
    sortByValue = 'Last Action';
    searchQueryValue = '';
    notifyListeners();
  }

  void setSearchQuery(String query) {
    searchQueryValue = query;
    notifyListeners();
  }

  /// Preload action icons for every loaded item.
  @protected
  Future<void> preloadAllActionIcons() async {
    await preloadActionIconsFor(items.map((e) => e.id).toList());
  }

  /// Reload action icons for every loaded item (debounced table-change path).
  @protected
  void reloadActionIcons({bool skipNotify = false}) {
    reloadActionIconsFor(
      items.map((e) => e.id).toList(),
      skipNotify: skipNotify,
    );
  }

  Future<void> prefetchMessages(List<String> itemIds) =>
      prefetchMessagesInto(itemIds);

  // ── ModuleCachesMixin hooks (type-generic) ─────────────────────────────
  @override
  int get prefetchMessageLimit => 200;

  @override
  Set<String> get recoveryCandidateIds => items.map((e) => e.id).toSet();

  @override
  int get recoveryBatchSize => 5;

  // ── TeamManagementMixin hook (type-generic) ────────────────────────────
  @override
  void reportTeamError(String message) {
    error = message;
    notifyListeners();
  }

  // ── ChangeSetConsumerMixin<T> hooks (type-generic over WorkItem) ───────
  // The surgical patch/replace/remove algorithms touch only `id`/`updatedAt`,
  // both on WorkItem, so they are written once here against T.
  @override
  String idOf(T row) => row.id;

  @override
  Future<void> applyUpsertedRows(List<T> rows) async {
    // Refresh icons for just the changed items before the single notify.
    await preloadActionIconsFor(rows.map((e) => e.id).toList());
    for (final e in rows) {
      final idx = items.indexWhere((x) => x.id == e.id);
      if (idx >= 0) {
        items[idx] = e;
      } else {
        items.add(e);
      }
    }
    // Keep the newest-first order the full reload's SQL provides.
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    hasMoreItems = items.length > pageSize;
  }

  @override
  void removeRowsByIds(Set<String> ids) {
    items.removeWhere((e) => ids.contains(e.id));
    hasMoreItems = items.length > pageSize;
  }

  // ── PaginationMixin<T> hook (type-generic over WorkItem) ───────────────
  @override
  Future<void> appendPage(List<T> newItems) async {
    items.addAll(newItems);

    // Preload action icons for the new items.
    final newIds = newItems.map((e) => e.id).toSet();
    await preloadActionIconsFor(newIds.toList());
  }

  // ── AssigneeIdentityRepairMixin<T> hooks (type-generic over WorkItem) ──
  // This mixin was written when `T` had no shared interface, so every module
  // re-declared these adapters. Now that `T extends WorkItem` each one is a
  // direct property read and lives here once. Only the `copyWith`-based
  // [applyIdentityRepair] and the remote/local write-back stay abstract hooks.
  @override
  String get repairUserId =>
      loadedUserId ?? FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  String get repairUserPhone => currentUserPhone ?? '';

  @override
  List<T> get repairCandidates {
    final uid = repairUserId;
    return items.where((e) => e.createdBy == uid).toList();
  }

  @override
  String repairItemId(T item) => item.id;

  @override
  Map<String, dynamic>? repairItemExtraFields(T item) => item.extraFields;

  @override
  String repairItemCreatedBy(T item) => item.createdBy;

  @override
  String repairItemAssignedToName(T item) => item.assignedTo;

  @override
  String? repairItemAssignedToUid(T item) => item.assignedToUid;

  @override
  String? repairItemAssignedToPhone(T item) => item.assignedToPhone;

  @override
  List<String> repairItemParticipants(T item) => item.participants;

  // ── Teardown (generic engine resources) ────────────────────────────────
  // Concrete subclasses cancel their own subscriptions first, then call
  // super.dispose() to release the shared resources below.
  @override
  void dispose() {
    disposeTeams();
    stopChangeSetConsumer();
    cancelMessageRecovery();
    cancelIdentityRepair();
    messagesCache.clear();
    actionIconsCache.clear();
    super.dispose();
  }
}
