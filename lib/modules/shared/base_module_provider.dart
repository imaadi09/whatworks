import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../modules/sales/models/enquiry.dart';
import '../../modules/shared/base_module_service.dart';
import '../../modules/shared/module_config.dart';
import '../../modules/shared/team_service.dart';
import '../../modules/sales/services/milestone_settings_service.dart';
import '../../models/message.dart';
import '../../utils/paywall_constants.dart';
import '../../services/sequential_id_service.dart';
import '../../services/firebase_service.dart';
import '../../services/local_database_service.dart';
import '../../services/startup_trace.dart';
import '../../services/module_plan_cache.dart';
import '../../utils/helpers.dart';
import '../../providers/unread_counts_mixin.dart';
import 'work_item_provider.dart';
import 'recurrence_rule.dart';

/// EnquiryModel-concrete module provider (Sales/CRM).
/// Both SalesProvider and CrmProvider extend this.
///
/// The type-generic list engine — the in-memory list, loading/error/filter/
/// sort state, pagination + change-set plumbing, message/action-icon caches,
/// recovery sweep, teams wiring and identity-repair adapters — now lives in
/// [WorkItemProvider] (shared with, and pre-shaped for, a future TaskProvider).
/// This class keeps ONLY the EnquiryModel-specific surface: the `service` /
/// `config` wiring, the SQLite/remote hooks, `copyWith`-based CRUD, and the
/// status-pipeline + clientName filter/sort.
///
/// ⚠️ PARITY RULE: The Task module is this app's reference implementation.
/// EVERY correction and enhancement made in the Task module MUST be
/// replicated in the other modules (Sales, CRM, Inventory) so behavior
/// stays identical — filters (e.g. Deleted view), swipe actions,
/// multi-select, dialogs, mutator contracts (memory-first before awaits),
/// navigation, and activity-log formatting alike. When a Task-module fix
/// lands, audit these module files and port the gap in the same change.
abstract class BaseModuleProvider extends WorkItemProvider<EnquiryModel> {
  final BaseModuleService service;
  final ModuleConfig config;
  final FirebaseService _firebaseService = FirebaseService();
  final TeamService _teamService;

  BaseModuleProvider({required this.service, required this.config})
    : _teamService = TeamService(tableName: config.teamsTableName);

  // ── Bridges to the generic engine state in WorkItemProvider ────────────
  // The type-generic list + flags now live in WorkItemProvider<T> as
  // @protected members (a different library, so not directly nameable here).
  // These private bridges keep every concrete EnquiryModel method below
  // byte-identical to the pre-split provider while sharing the ONE state the
  // generic engine drives.
  List<EnquiryModel> get _enquiries => items;
  set _enquiries(List<EnquiryModel> value) => items = value;
  bool get _isLoading => loading;
  set _isLoading(bool value) => loading = value;
  set _errorMessage(String? value) => error = value;
  String? get _loadedUserId => loadedUserId;
  set _loadedUserId(String? value) => loadedUserId = value;
  String get _statusFilter => statusFilterValue;
  String get _sortBy => sortByValue;
  String get _searchQuery => searchQueryValue;
  String? get _pagingUserId => pagingUserId;
  set _pagingUserId(String? value) => pagingUserId = value;
  String? get _currentUserPhone => currentUserPhone;

  // TeamManagementMixin hooks — module flavor routes through config
  @override
  TeamService get teamService => _teamService;

  @override
  String get teamPrefKey => config.teamPrefKey;

  @override
  Future<int> cardCountInTeam(String teamId) =>
      service.getTeamEnquiryCount(teamId);

  @override
  void onTeamSwitched() {
    if (_loadedUserId != null) {
      loadEnquiries(_loadedUserId!);
    }
  }

  /// Tear down this module's list Firestore listeners
  /// (`module_<collection>_by*`). Wired to the Sales/CRM home screen's dispose
  /// so switching modules (pushReplacement disposes the outgoing home)
  /// unmounts the inactive module's 4 list listeners instead of keeping them
  /// streaming + writing SQLite for the whole session. Idempotent
  /// (cancel-by-key); SQLite keeps rows and re-attach on return is a delta
  /// read. No-op until a load has set [_loadedUserId].
  void stopListSync() {
    final userId = _loadedUserId;
    if (userId == null) return;
    _firebaseService.stopModuleEnquirySync(
      userId,
      config.firestoreCollection,
      userPhone: _currentUserPhone,
    );
  }

  // ModuleCachesMixin hooks — module flavor routes through config
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchActionIcons(
    List<String> parentIds,
  ) => LocalDatabaseService().getModuleActionIconsForParents(
    parentIds,
    tableName: config.actionsTableName,
  );

  @override
  void startMessageSyncFor(String parentId) => _firebaseService
      .startModuleMessageSync(parentId, config.firestoreCollection);

  // Fresh-install message recovery hooks — enquiry flavor of the shared sweep
  // in ModuleCachesMixin (TaskProvider supplies the task flavor). The
  // algorithm, timer and latch all live in the mixin; only these differ. The
  // latch key preserves the historical per-module+user namespace so already-
  // recovered devices don't re-sweep after the refactor.
  @override
  String get recoveryScope => config.enquiriesTableName;

  @override
  String get recoveryLatchKey =>
      'messages_recovered_${config.actionsTableName}_${_loadedUserId ?? FirebaseAuth.instance.currentUser?.uid ?? ''}';

  @override
  Future<void> fetchMessagesForRecovery(String id) => _firebaseService
      .fetchModuleMessagesOnceFor(id, config.firestoreCollection);

  // SQLite change notification subscription (actions icons only; enquiries now
  // flow through the shared ChangeSetConsumerMixin)
  StreamSubscription<TableChange>? _actionsTableSub;

  // Coalesces bursts of action-icon reloads during sync/recovery writes
  Timer? _iconReloadDebounce;

  // Module actions tables already backfilled this session
  static final Set<String> _backfilledActionTables = {};

  // ── Getters ────────────────────────────────────────────────────────────

  List<EnquiryModel> get enquiries => _enquiries;
  bool get hasMoreEnquiries => hasMoreItems;

  // ── PaginationMixin<EnquiryModel> hooks ─────────────────────────
  // Cursor, has-more flag, in-flight guard and the load-more algorithm come
  // from the shared PaginationMixin — the identical engine TaskProvider runs.
  // Sales/CRM supply only the SQLite read (fetchPage); the generic append lives
  // in WorkItemProvider.

  @override
  Future<List<EnquiryModel>> fetchPage(int offset, int limit) =>
      LocalDatabaseService().getModuleEnquiriesPaginated(
        _pagingUserId ?? _loadedUserId ?? '',
        limit: limit,
        offset: offset,
        tableName: config.enquiriesTableName,
      );

  /// Load more enquiries (lazy loading / pagination) — captures the caller's
  /// uid for [fetchPage], then runs the shared engine. Existing
  /// `salesProvider.loadMoreEnquiries(uid)` call sites stay unchanged.
  Future<void> loadMoreEnquiries(String userId) {
    _pagingUserId = userId;
    return loadMoreItems();
  }

  /// Get all enquiries from SQLite (for Actions tab which needs all enquiries)
  Future<List<EnquiryModel>> getAllEnquiries(
    String userId, {
    String? teamId,
  }) async {
    return await service.getEnquiriesFromLocal(userId, teamId: teamId);
  }

  // Team state (teams/currentTeamId/currentTeamName/teamsLoaded) comes from
  // TeamManagementMixin — shared with TaskProvider.

  /// Big line of the home AppBar title: the module display name (sector-aware,
  /// e.g. "Sales Teams" / "Service Teams"). Paired with [appBarTeamName] to
  /// render the same two-line format as the Task home.
  String get appBarModuleName => config.displayName;

  /// Small line under the module name: the current team name, or "Team One"
  /// when no team name is set (a lone default team often has no distinct name).
  String get appBarTeamName {
    final t = currentTeamName;
    return (t != null && t.isNotEmpty) ? t : 'Team One';
  }

  List<EnquiryModel> get filteredEnquiries {
    var list = _applyStatusFilter(_enquiries);
    list = _applySearch(list);
    return _applySort(list);
  }

  /// Apply the current 3-dot VIEW filter + SORT to an externally-built list
  /// (e.g. the Assignee tab's person-scoped enquiries) so every tab honors
  /// the same menu selections. Search is intentionally not applied — the
  /// search bar only exists on the My Enquiries tabs.
  List<EnquiryModel> applyFiltersTo(List<EnquiryModel> list) {
    return _applySort(_applyStatusFilter(list));
  }

  // ── Teams ──────────────────────────────────────────────────────────────
  // Team state + CRUD come from TeamManagementMixin (shared with
  // TaskProvider). Module-specific behavior plugs in via hooks: teamService,
  // teamPrefKey, cardCountInTeam, onTeamSwitched, reportTeamError.

  // ── Data Loading ───────────────────────────────────────────────────────

  Future<void> loadEnquiries(String userId) async {
    if (_isLoading) return;
    final tr = StartupTrace.instance.begin(
      'module.loadEnquiries',
      kind: StartupTraceKind.provider,
    );
    // Account switch: drop the previous user's cards before loading so they
    // can't linger when the new account has no local rows (the assignments
    // below only replace _enquiries when the read is non-empty).
    if (_loadedUserId != null && _loadedUserId != userId) {
      _enquiries = [];
      _loadedUserId = null;
    }
    _isLoading = true;
    _errorMessage = null;
    resetPagination();
    notifyListeners();

    try {
      final teamId = currentTeamId;

      // Enquiries now consume rich change-sets (4.1) via the SHARED
      // ChangeSetConsumerMixin — the same mixin TaskProvider uses — patching
      // only the rows that changed instead of re-scanning the whole table.
      // Idempotent: safe on every loadEnquiries / team switch.
      startChangeSetConsumer();

      // Start background sync (delta — always the user's full superset;
      // team scoping happens on local reads)
      _firebaseService.startModuleEnquirySync(
        userId,
        config.firestoreCollection,
        config.enquiriesTableName,
        userPhone: _currentUserPhone,
      );

      // Read from SQLite immediately
      final localResult = await LocalDatabaseService().getModuleEnquiries(
        userId,
        teamId: teamId,
        tableName: config.enquiriesTableName,
      );

      if (localResult.isNotEmpty) {
        _enquiries = localResult;
        _loadedUserId = userId;
      }

      markFirstPage(localResult.length);

      // Auto-purge soft-deleted enquiries older than 30 days (fire-and-forget)
      // — parity with TaskProvider._purgeOldDeletedTasks.
      _purgeOldDeletedEnquiries();

      // B8 parity: mark timed-out uploads as failed (fire-and-forget). The
      // sweep itself is table-wide over the shared `messages` table, but it was
      // only ever triggered from TaskProvider.loadTasks — so a user who never
      // opened the Task module left attachment sends stuck in 'pending'
      // forever, with no error state and no retry.
      _cleanupStalePendingMessages();

      // Listen for actions table changes (debounced to coalesce the burst of
      // writes that background sync / message recovery produces)
      _actionsTableSub?.cancel();
      _actionsTableSub = LocalDatabaseService().tableChanges2
          .where((c) => c.table == config.actionsTableName)
          .listen((_) {
            _iconReloadDebounce?.cancel();
            _iconReloadDebounce = Timer(
              const Duration(milliseconds: 300),
              reloadActionIcons,
            );
          });

      // One-time backfill of the module actions table from existing messages —
      // fixes historical messages saved before module-aware write-through
      // existed. Fire-and-forget: must not block the enquiry list; the actions
      // table-change notify refreshes icons when it completes.
      //
      // This Set is only a per-session short-circuit. The PERSISTED latch lives
      // in _ensureModuleActionsBackfilled, because the scan reads every message
      // and rewrites every action row — an in-memory guard re-ran all of that
      // on every cold launch.
      if (!_backfilledActionTables.contains(config.actionsTableName)) {
        _backfilledActionTables.add(config.actionsTableName);
        unawaited(_ensureModuleActionsBackfilled(config));
      }

      await preloadAllActionIcons();

      // One-shot fresh-install recovery (15s: after the enquiry sync settles)
      // — the SHARED sweep in ModuleCachesMixin (Task runs the identical one).
      // It reads the current user + loaded enquiries live when it fires, so a
      // user switch that re-runs loadEnquiries simply retargets it.
      scheduleMessageRecovery();

      // One-shot creator-side repair of multi-assignee identity fields
      // (12s: after the enquiry sync burst settles) — the SAME shared sweep
      // TaskProvider runs, so Sales/CRM heal legacy assignee identity too.
      scheduleInitialIdentityRepair();
    } catch (e) {
      _errorMessage = 'Failed to load enquiries: $e';
    }

    _isLoading = false;
    StartupTrace.instance.end(tr, rows: _enquiries.length);
    notifyListeners();
  }

  /// Latched gate around the module actions backfill, mirroring main.dart's
  /// `_backfillActionsIfNeeded` step for step:
  ///
  /// ```
  /// prefs[module_actions_backfill_done_<table>]  -> skip the scan if latched
  /// getModuleActionCount(table) > 0              -> latch, skip the scan
  /// getTotalMessageCount() == 0                  -> return WITHOUT latching
  /// backfillModuleActionsFromMessages()          -> latch
  /// ```
  ///
  /// The third step is the load-bearing one: on a fresh install the messages
  /// have not synced down yet, and latching against an empty database would
  /// permanently prevent indexing anything that arrives later.
  ///
  /// The mis-file purge runs on EVERY launch regardless of the latch — it
  /// repairs rows write-through drops into the shared `actions` table when a
  /// message beats its parent enquiry down, so it is ongoing work rather than
  /// a one-time migration.
  Future<void> _ensureModuleActionsBackfilled(ModuleConfig config) async {
    final db = LocalDatabaseService();
    final table = config.actionsTableName;
    try {
      final prefs = await SharedPreferences.getInstance();
      final latchKey = 'module_actions_backfill_done_$table';
      if (!(prefs.getBool(latchKey) ?? false)) {
        if (await db.getModuleActionCount(actionsTableName: table) > 0) {
          // Already populated — latch so the scan never runs on this device.
          await prefs.setBool(latchKey, true);
        } else if (await db.getTotalMessageCount() > 0) {
          await db.backfillModuleActionsFromMessages(
            actionsTableName: table,
            enquiriesTableName: config.enquiriesTableName,
          );
          await prefs.setBool(latchKey, true);
        }
        // else: nothing synced yet — leave unlatched and try again next load.
      }
    } catch (e) {
      debugPrint('[ModuleActions] Backfill gate failed for $table: $e');
    }
    try {
      await db.purgeMisfiledEnquiryActions(
        enquiriesTableName: config.enquiriesTableName,
      );
    } catch (e) {
      debugPrint('[ModuleActions] Mis-file purge failed: $e');
    }
  }

  // ── ChangeSetConsumerMixin<EnquiryModel> hooks (4.1) ────────────────────
  // The SAME shared change-set consumer TaskProvider uses: patch only the
  // enquiries that changed instead of re-scanning the whole table. Written once
  // in the mixin, so Sales and CRM (both extend this class) get it identically;
  // the module-specific surface is just these hooks over `config`.

  @override
  String get changeSetTable => config.enquiriesTableName;

  @override
  Future<List<EnquiryModel>> fetchRowsByIds(Set<String> ids) =>
      LocalDatabaseService().getModuleEnquiriesByIds(
        ids,
        tableName: config.enquiriesTableName,
      );

  @override
  Future<void> fullReload() async {
    final userId = _loadedUserId;
    if (userId == null) return;
    final tr = StartupTrace.instance.begin(
      'module.fullReload',
      kind: StartupTraceKind.provider,
    );
    // No-op suppression: full reloads fire on every bulk table change (a sync
    // burst, a chat message bumping an enquiry clock, a retention sweep), and
    // each notify re-filters, re-sorts and rebuilds every card. Capture what
    // the UI holds now and only notify when the re-read actually moved.
    final beforeSignature = currentItemsSignature();
    final result = await LocalDatabaseService().getModuleEnquiries(
      userId,
      teamId: currentTeamId,
      tableName: config.enquiriesTableName,
    );
    // Mirror the legacy listener: only replace on a non-empty read, so a
    // transient empty result can't wipe a populated list. Notifies itself.
    if (result.isNotEmpty) {
      _enquiries = result;
      _loadedUserId = userId;
      hasMoreItems = result.length > pageSize;
      if (currentItemsSignature() != beforeSignature) notifyListeners();
    }
    StartupTrace.instance.end(tr, rows: result.length);
  }

  /// Silent refresh
  Future<void> refresh(String userId) async {
    _errorMessage = null;
    try {
      _firebaseService.startModuleEnquirySync(
        userId,
        config.firestoreCollection,
        config.enquiriesTableName,
        userPhone: _currentUserPhone,
      );

      // Same no-op suppression as [fullReload]: a pull-to-refresh that lands on
      // unchanged rows must not rebuild the list.
      final beforeSignature = currentItemsSignature();
      final localResult = await service.getEnquiriesFromLocal(
        userId,
        teamId: currentTeamId,
      );
      if (localResult.isNotEmpty) {
        _enquiries = localResult;
        _loadedUserId = userId;
        if (currentItemsSignature() != beforeSignature) notifyListeners();
      }
    } catch (e) {
      _errorMessage = 'Failed to refresh: $e';
      notifyListeners();
    }
  }

  // ── Message Cache ──────────────────────────────────────────────────────

  // getCachedMessages / loadCachedMessages / getActionIcons come from
  // ModuleCachesMixin (task module base).

  Future<List<MessageModel>> loadMessages(String enquiryId) async {
    if (messagesCache.containsKey(enquiryId)) {
      return messagesCache[enquiryId]!;
    }
    final sqliteMsgs = await LocalDatabaseService().getMessages(
      enquiryId,
      limit: 50,
    );
    if (sqliteMsgs.isNotEmpty) {
      messagesCache[enquiryId] = sqliteMsgs;
      notifyListeners();
      return sqliteMsgs;
    }
    final messages = await service.getRecentMessages(enquiryId);
    if (messages.isNotEmpty) {
      await LocalDatabaseService().saveMessages(
        messages,
        parentType: 'enquiry',
      );
    }
    messagesCache[enquiryId] = messages;
    notifyListeners();
    return messages;
  }

  Future<List<MessageModel>> loadOlderMessages(String enquiryId) async {
    final cached = messagesCache[enquiryId];
    if (cached == null || cached.isEmpty) return [];
    final oldestDate = cached.first.createdAt;
    final older = await LocalDatabaseService().getMessagesBefore(
      enquiryId,
      oldestDate,
      limit: 30,
    );
    if (older.isNotEmpty) {
      final existingIds = cached.map((m) => m.id).toSet();
      final newMsgs = older.where((m) => !existingIds.contains(m.id)).toList();
      if (newMsgs.isNotEmpty) {
        messagesCache[enquiryId] = [...newMsgs, ...cached];
        notifyListeners();
      }
      return messagesCache[enquiryId]!;
    }
    final olderFromFirestore = await service.getOlderMessages(
      enquiryId,
      oldestDate,
    );
    if (olderFromFirestore.isNotEmpty) {
      await LocalDatabaseService().saveMessages(
        olderFromFirestore,
        parentType: 'enquiry',
      );
      final existingIds = cached.map((m) => m.id).toSet();
      final newMsgs = olderFromFirestore
          .where((m) => !existingIds.contains(m.id))
          .toList();
      messagesCache[enquiryId] = [...newMsgs, ...cached];
      notifyListeners();
    }
    return messagesCache[enquiryId]!;
  }

  // ── CRUD ───────────────────────────────────────────────────────────────

  Future<String?> createEnquiry(
    EnquiryModel enquiry, {
    String? planType,
    String? explicitId,
  }) async {
    // Hard plan-limit gate: block before any persistence.
    final moduleKey = config.type == ModuleType.crm ? 'crm' : 'sale';
    final effectivePlan = await ModulePlanCache.effectivePlanForModule(
      planType,
      moduleKey,
    );
    if (effectivePlan != null) {
      final check = await PaywallLimits.checkCreateEnquiryLimit(
        planType: effectivePlan,
        enquiry: enquiry,
        module: moduleKey,
        countActiveTasks: LocalDatabaseService().countActiveTasks,
      );
      if (!check.allowed) {
        print('[Paywall] Blocked $moduleKey creation: ${check.message}');
        throw PlanLimitException(check.feature, check.message);
      }
    }

    // Apply the module's default milestone template when the caller did not
    // supply milestones — single application point for sales/CRM, mirroring
    // TaskProvider.createTask for tasks.
    if (enquiry.milestones.isEmpty) {
      final milestoneSettings = MilestoneSettingsService(
        module: config.type == ModuleType.crm ? 'crm' : 'sales',
      );
      // Only apply templates when milestones are enabled in settings.
      if (await milestoneSettings.isEnabled()) {
        final templates = await milestoneSettings.getEffectiveTemplates();
        final templateNow = DateTime.now();
        enquiry = enquiry.copyWith(
          milestones: templates.asMap().entries.map((entry) {
            final t = entry.value;
            DateTime? deadline;
            if (t.deadlineOffsetDays != null) {
              deadline = templateNow.add(Duration(days: t.deadlineOffsetDays!));
            }
            return MilestoneModel(
              id: 'milestone_${entry.key}',
              title: t.title,
              order: entry.key,
              deadline: deadline,
              // Payment/delivery tag rides onto the card — the user still
              // ticks completion by hand; only the KIND is templated.
              kind: t.kind,
            );
          }).toList(),
        );
      }
    }

    int? displayId = enquiry.displayId;
    final isDraft = enquiry.extraFields?['isDraft'] == true;
    if (displayId == null && !isDraft) {
      displayId = await SequentialIdService().getNextId(config.sequentialIdKey);
    }
    final enquiryWithId = enquiry.copyWith(
      displayId: displayId,
      // Seed the participants invariant at creation so the Firestore doc carries
      // it from the start (mirrors TaskModel quick-create, which pre-populates
      // participants with createdBy + assignedToUid). enquiryToRow already
      // enforces this locally; this closes the Firestore side so cross-device
      // `where('participants', arrayContains: uid)` discovery works immediately.
      participants: participantsUnion(
        enquiry.participants,
        createdBy: enquiry.createdBy,
        assignedToUid: enquiry.assignedToUid,
        extraFields: enquiry.extraFields,
      ),
    );

    final id = explicitId ?? Helpers.generateId();
    // Recurrence (Phase-2A): a brand-new item carrying a rule but no seriesId
    // becomes the series ANCHOR — seriesId = its own id, nextDue = the first
    // occurrence after the anchor date. Generated occurrences arrive with
    // recurrence == null and a preset seriesId, so they are never re-anchored.
    // Mirrors TaskProvider.createTask.
    var preparedEnquiry = enquiryWithId;
    if (enquiryWithId.recurrence != null && enquiryWithId.seriesId == null) {
      final rule = RecurrenceRule.tryParse(enquiryWithId.recurrence);
      preparedEnquiry = enquiryWithId.copyWith(
        seriesId: id,
        nextDue: rule?.nextOccurrenceAfter(rule.anchor),
      );
    }
    final realEnquiry = preparedEnquiry.copyWith(id: id);
    _enquiries.insert(0, realEnquiry);
    await LocalDatabaseService().saveModuleEnquiry(
      realEnquiry,
      tableName: config.enquiriesTableName,
    );
    notifyListeners();
    service
        .createEnquiry(preparedEnquiry, enquiryId: id)
        .then((_) {})
        .catchError((e) {
          print('Error creating enquiry in Firestore: $e');
        });
    return id;
  }

  /// Reload the persisted enquiry after create — the SQLite row is the
  /// source of truth (milestone template is applied inside createEnquiry),
  /// so navigation must carry the persisted object, not the pre-create one.
  Future<EnquiryModel> persistedEnquiry(
    EnquiryModel fallback,
    String id,
  ) async {
    return await LocalDatabaseService().getModuleEnquiryById(
          id,
          tableName: config.enquiriesTableName,
        ) ??
        fallback.copyWith(id: id);
  }

  Future<void> updateEnquiry(String id, Map<String, dynamic> data) async {
    final index = _enquiries.indexWhere((e) => e.id == id);
    if (index != -1) {
      final current = _enquiries[index];

      // An explicit blank assignedTo in the update map is a DELIBERATE
      // unassign (only the Manage Assignees "removed the last assignee"
      // path sends it). The local-first merge would otherwise revert the
      // blank assignee fields back to the stored values, so flag the clear
      // to honor it. (The updatedAt watermark is bumped for every edit below,
      // so the row always outranks the stored copy and lands.)
      final intentionalUnassign = data['assignedTo'] == '';

      Map<String, dynamic>? updatedExtraFields = current.extraFields;
      for (final key in data.keys) {
        if (key.startsWith('extraFields.')) {
          final fieldKey = key.substring('extraFields.'.length);
          updatedExtraFields = {
            ...(updatedExtraFields ?? {}),
            fieldKey: data[key],
          };
        }
      }

      _enquiries[index] = current.copyWith(
        status: data['status'] as String?,
        title: data['title'],
        clientName: data['clientName'],
        description: data['description'],
        displayId: data['displayId'],
        // -1 is the "clear rating" sentinel (copyWith can't express null) —
        // matches the `_setRating` tap-same-star-to-clear UX in CRM detail.
        rating: data['rating'] == -1 ? null : data['rating'] as int?,
        progress: data['progress']?.toDouble(),
        priority: data['priority'],
        isUrgent: data['isUrgent'],
        deadline: data['deadline'],
        // Recurrence (Phase-2B): the deadline editor sets the recurrence trio
        // (recurrence/seriesId/nextDue) when a rule is chosen, or sends
        // clearRecurrence to null all three on "Does not repeat". Whitelisted
        // here so the trio persists to SQLite via saveModuleEnquiry; the raw
        // data map still relays to Firestore below. Mirrors TaskModel.copyWith.
        recurrence: data['recurrence'] as String?,
        seriesId: data['seriesId'] as String?,
        nextDue: data['nextDue'] as DateTime?,
        clearRecurrence: data['clearRecurrence'] == true,
        assignedTo: data['assignedTo'],
        assignedToUid: data['assignedToUid'],
        assignedToPhone: data['assignedToPhone'],
        participants: data['participants'] != null
            ? (data['participants'] as List).map((e) => e.toString()).toList()
            : null,
        clientPhone: data['clientPhone'],
        clientEmail: data['clientEmail'],
        milestones: data['milestones'] != null
            ? (data['milestones'] as List)
                  .map(
                    (m) => MilestoneModel.fromMap(
                      Map<String, dynamic>.from(m),
                      m['id'] ?? '',
                    ),
                  )
                  .toList()
            : null,
        extraFields: updatedExtraFields != current.extraFields
            ? updatedExtraFields
            : null,
        // Bump the watermark on EVERY edit. _upsertRowIfChanged skips a row
        // whose incoming updatedAt is not strictly newer than the stored one;
        // keeping the old stamp for non-assignee fields (status, title,
        // progress, milestones, …) meant those changes never landed in SQLite,
        // so the SQLite-driven cards kept showing the stale value — the
        // reported "sale enquiry status won't change". Mirrors the Task module,
        // where every caller rebuilds the model with updatedAt: now().
        updatedAt: DateTime.now(),
      );
      await LocalDatabaseService().saveModuleEnquiry(
        _enquiries[index],
        tableName: config.enquiriesTableName,
        clearAssignee: intentionalUnassign,
      );
      notifyListeners();
    }
    // `clearRecurrence` is a transient local-only sentinel (the model's
    // copyWith can't express null through `?? this.x`); strip it before
    // relaying to Firestore so the doc isn't polluted with non-schema fields.
    // The explicit null recurrence/seriesId/nextDue keys already clear them
    // remotely.
    final relay = Map<String, dynamic>.from(data)..remove('clearRecurrence');
    service.updateEnquiry(id, relay).catchError((e) {
      print('Error updating enquiry in Firestore: $e');
    });
  }

  /// Archive a card — hides it from normal views without deleting it.
  /// Never auto-purged; [unarchiveEnquiry] restores it in place.
  Future<void> archiveEnquiry(String id) async {
    final index = _enquiries.indexWhere((e) => e.id == id);
    if (index == -1) return;
    final updated = _enquiries[index].copyWith(
      isArchived: true,
      updatedAt: DateTime.now(),
    );
    _enquiries[index] = updated;
    await LocalDatabaseService().saveModuleEnquiry(
      updated,
      tableName: config.enquiriesTableName,
    );
    notifyListeners();
    service
        .updateEnquiry(id, {
          'isArchived': true,
          'archivedAt': FieldValue.serverTimestamp(),
          'archivedBy': _loadedUserId ?? '',
          'updatedAt': FieldValue.serverTimestamp(),
        })
        .catchError((e) {
          print('Error archiving enquiry in Firestore: $e');
        });
  }

  /// Restore an archived card back to normal views.
  Future<void> unarchiveEnquiry(String id) async {
    final index = _enquiries.indexWhere((e) => e.id == id);
    if (index == -1) return;
    final updated = _enquiries[index].copyWith(
      isArchived: false,
      updatedAt: DateTime.now(),
    );
    _enquiries[index] = updated;
    await LocalDatabaseService().saveModuleEnquiry(
      updated,
      tableName: config.enquiriesTableName,
    );
    notifyListeners();
    service
        .updateEnquiry(id, {
          'isArchived': false,
          'archivedAt': null,
          'archivedBy': null,
          'updatedAt': FieldValue.serverTimestamp(),
        })
        .catchError((e) {
          print('Error unarchiving enquiry in Firestore: $e');
        });
  }

  /// Auto-purge soft-deleted enquiries older than 30 days from SQLite and
  /// Firestore. Mirrors TaskProvider._purgeOldDeletedTasks: the local purge
  /// runs on every load (a cheap indexed DELETE), while the Firestore purge
  /// query is gated to once per day PER MODULE via a module-specific prefs key
  /// so Sales, CRM and Task never suppress each other's purge.
  void _purgeOldDeletedEnquiries() async {
    try {
      await LocalDatabaseService().purgeDeletedRows(config.enquiriesTableName);
      final prefs = await SharedPreferences.getInstance();
      final key = 'last_firestore_purge_ms_${config.enquiriesTableName}';
      final lastPurgeMs = prefs.getInt(key) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastPurgeMs < const Duration(days: 1).inMilliseconds) return;
      await prefs.setInt(key, now);
      await service.purgeDeletedEnquiries();
    } catch (e) {
      print('BaseModuleProvider: Error purging deleted enquiries: $e');
    }
  }

  /// Mark uploads still 'pending' after 30 minutes as failed — parity with
  /// TaskProvider._cleanupStalePendingMessages. The sweep is table-wide over
  /// the shared `messages` table, so this does not duplicate work per module in
  /// any meaningful sense: it is one index-served query
  /// (idx_messages_fileUrl_createdAt) that returns early without notifying when
  /// nothing is stale. It only guarantees the sweep also runs for users who
  /// never load the Task module.
  void _cleanupStalePendingMessages() async {
    try {
      final count = await LocalDatabaseService().cleanupStalePendingMessages();
      if (count > 0) {
        print('BaseModuleProvider: Cleaned up $count stale pending messages');
      }
    } catch (e) {
      print('BaseModuleProvider: Error cleaning up pending messages: $e');
    }
  }

  /// Soft-delete a card — hides it from normal views and shows it in the
  /// Deleted view, where it can be restored or permanently purged.
  /// Mirrors TaskProvider.deleteTask.
  Future<void> softDeleteEnquiry(String id) async {
    final index = _enquiries.indexWhere((e) => e.id == id);
    if (index == -1) return;
    final updated = _enquiries[index].copyWith(
      isDeleted: true,
      deletedAt: DateTime.now(),
      deletedBy: _loadedUserId ?? '',
      updatedAt: DateTime.now(),
    );
    // Mutate state first (before awaits) so swipe/multi-select deletes drop
    // the card from normal views synchronously — no snap-back.
    _enquiries[index] = updated;
    notifyListeners();
    await LocalDatabaseService().saveModuleEnquiry(
      updated,
      tableName: config.enquiriesTableName,
    );
    service
        .updateEnquiry(id, {
          'isDeleted': true,
          'deletedAt': FieldValue.serverTimestamp(),
          'deletedBy': _loadedUserId ?? '',
          'updatedAt': FieldValue.serverTimestamp(),
        })
        .catchError((e) {
          print('Error soft-deleting enquiry in Firestore: $e');
        });
  }

  /// Restore a soft-deleted card back to normal views.
  Future<void> restoreEnquiry(String id) async {
    final index = _enquiries.indexWhere((e) => e.id == id);
    if (index == -1 || !_enquiries[index].isDeleted) return;
    final current = _enquiries[index];
    // Full rebuild (not copyWith) so deletedAt/deletedBy are cleared.
    final updated = EnquiryModel(
      id: current.id,
      title: current.title,
      clientName: current.clientName,
      description: current.description,
      createdBy: current.createdBy,
      createdByName: current.createdByName,
      createdByPhone: current.createdByPhone,
      assignedTo: current.assignedTo,
      assignedToUid: current.assignedToUid,
      assignedToPhone: current.assignedToPhone,
      status: current.status,
      milestones: current.milestones,
      priority: current.priority,
      isUrgent: current.isUrgent,
      deadline: current.deadline,
      progress: current.progress,
      tags: current.tags,
      extraFields: current.extraFields,
      createdAt: current.createdAt,
      updatedAt: DateTime.now(),
      isClosed: current.isClosed,
      lastMessageText: current.lastMessageText,
      lastMessageTime: current.lastMessageTime,
      unreadCounts: current.unreadCounts,
      teamId: current.teamId,
      displayId: current.displayId,
      rating: current.rating,
      clientPhone: current.clientPhone,
      clientEmail: current.clientEmail,
      category: current.category,
      isArchived: current.isArchived,
      archivedAt: current.archivedAt,
      archivedBy: current.archivedBy,
    );
    _enquiries[index] = updated;
    notifyListeners();
    await LocalDatabaseService().saveModuleEnquiry(
      updated,
      tableName: config.enquiriesTableName,
    );
    service
        .updateEnquiry(id, {
          'isDeleted': false,
          'deletedAt': null,
          'deletedBy': null,
          'updatedAt': FieldValue.serverTimestamp(),
        })
        .catchError((e) {
          print('Error restoring enquiry in Firestore: $e');
        });
  }

  Future<void> deleteEnquiry(String id) async {
    // Drop from in-memory state FIRST (before any await) so swipe/multi-select
    // deletes remove the card synchronously — a slow SQLite delete could let a
    // stream-driven rebuild snap the card back.
    _enquiries.removeWhere((e) => e.id == id);
    messagesCache.remove(id);
    notifyListeners();
    await LocalDatabaseService().deleteModuleEnquiry(
      id,
      tableName: config.enquiriesTableName,
    );
    service.deleteEnquiry(id).catchError((e) {
      print('Error deleting enquiry in Firestore: $e');
    });
  }

  Future<String> sendMessage(String enquiryId, MessageModel message) async {
    final msgId = message.id.isNotEmpty ? message.id : Helpers.generateId();
    final savedMessage = message.id.isNotEmpty
        ? message
        : message.copyWith(id: msgId);
    await LocalDatabaseService().saveMessage(
      savedMessage,
      parentType: 'enquiry',
    );
    messagesCache.putIfAbsent(enquiryId, () => []);
    messagesCache[enquiryId]!.add(savedMessage);
    final index = _enquiries.indexWhere((e) => e.id == enquiryId);
    if (index != -1) {
      _enquiries[index] = _enquiries[index].copyWith(
        // Same 80-char cap the Firestore write applies (B7) — otherwise the
        // card showed the full body until the next reload swapped in the
        // truncated server value.
        lastMessageText: BaseModuleService.lastMessageSnippet(message.text),
        lastMessageTime: DateTime.now(),
      );
    }
    // Task parity (TaskProvider.sendMessage): resolve the badge recipients from
    // the card itself, at the one choke point every send goes through. This
    // used to live in the detail screen and only ran for typed chat messages,
    // so forwards, action messages, milestone/status updates, draft activation
    // and failed-send retries left the recipient's card badge at 0 — and the
    // push function skips non-regular messages too, so they got no signal at
    // all.
    var unreadRecipientUids = const <String>[];
    if (UnreadCountsMixin.awaitsRecipientRead(
      savedMessage.type,
      savedMessage.text,
    )) {
      // _enquiries is paginated, so a card outside the loaded page (or a send
      // started from a notification deep link) is absent from memory. Read it
      // from SQLite instead of silently notifying nobody.
      EnquiryModel? enquiry;
      if (index != -1) {
        enquiry = _enquiries[index];
      } else {
        enquiry = await LocalDatabaseService().getModuleEnquiryById(
          enquiryId,
          tableName: config.enquiriesTableName,
        );
      }
      if (enquiry != null) {
        unreadRecipientUids = <String>{
          enquiry.createdBy,
          if (enquiry.assignedToUid != null) enquiry.assignedToUid!,
          // The authoritative membership list (see the invariant on
          // EnquiryModel.participants). It was omitted before, so a co-member
          // who could open the card never saw a badge.
          ...enquiry.participants,
          ...enquiry.assigneeUids,
        }.where((uid) => uid.isNotEmpty && uid != savedMessage.senderId).toList();
      }
    }
    notifyListeners();
    service
        .sendMessage(
          enquiryId,
          message,
          messageId: msgId,
          unreadRecipientUids: unreadRecipientUids,
        )
        .then((_) {})
        .catchError((e) {
          print('Error sending message in Firestore: $e');
          // B1 parity with TaskProvider.sendMessage: stamp the local row as
          // failed. Without this a Sales/CRM send that could not reach
          // Firestore (offline, rules rejection) stayed in the pending state
          // forever — the SQLite row is the local-first source of truth, so
          // nothing ever corrected it and the user saw a normal-looking message
          // that no one else received.
          LocalDatabaseService().markMessageUploadFailed(
            msgId,
            'Failed to sync: $e',
          );
        });
    // Durable action log (B4 — parity with Task's writeSystemLog). Mirror every
    // system message into the enquiry's system_logs subcollection, keyed by the
    // message id so a rewrite from any device is idempotent. The detail screen's
    // Activity log renders exactly the system-message set, so this copy is
    // faithful to what it shows and survives chat retention / a fresh install.
    // Response notifications (Reply/Done/Resolve) are the exception — they
    // update the original action card in place, so they are never logged as
    // separate rows (matches the detail screen's Activity-log gate).
    final lt = savedMessage.text.toLowerCase();
    final isResponseNotification =
        lt.contains('replied by ') ||
        lt.contains('marked as done by ') ||
        lt.contains('blocker resolved by ');
    if (savedMessage.type == MessageType.system && !isResponseNotification) {
      _firebaseService.writeModuleSystemLog(
        enquiryId: enquiryId,
        collection: config.firestoreCollection,
        messageId: msgId,
        action: BaseModuleService.systemLogAction(savedMessage.text),
        performedBy: savedMessage.senderId,
        details: savedMessage.text,
        createdAt: savedMessage.createdAt,
      );
    }
    return msgId;
  }

  Future<void> updateMessage(
    String enquiryId,
    String messageId,
    Map<String, dynamic> data,
  ) async {
    // R6.4: PK lookup by messageId, not getMessages(enquiryId)+firstWhere —
    // parity with TaskProvider.updateMessage. The old path read up to 50 rows
    // and threw StateError when the target was older than the latest 50, which
    // is why closing an older Sales/CRM action silently did nothing.
    final msg = await LocalDatabaseService().getMessageById(messageId);
    if (msg == null) throw StateError('Message not found: $messageId');

    // Handle deletedFor: FieldValue.arrayUnion can't be applied to the local
    // row, so the caller passes 'deletedForUid' alongside it for the SQLite
    // write — parity with TaskProvider.updateMessage. Without these three
    // fields the shared provider never persisted delete-for-me / delete-for-
    // everyone to SQLite (the local-first source of truth), so deleted enquiry
    // messages reappeared on reload.
    List<String> updatedDeletedFor = msg.deletedFor;
    if (data['deletedFor'] is FieldValue) {
      final uid = data['deletedForUid'] as String?;
      if (uid != null && !msg.deletedFor.contains(uid)) {
        updatedDeletedFor = [...msg.deletedFor, uid];
      }
    } else if (data['deletedFor'] is List<String>) {
      updatedDeletedFor = data['deletedFor'] as List<String>;
    }

    final updatedMsg = msg.copyWith(
      isFollowUpDone: data['isFollowUpDone'] as bool? ?? msg.isFollowUpDone,
      followUpDoneBy: data['followUpDoneBy'] as String? ?? msg.followUpDoneBy,
      followUpDoneAt: data['followUpDoneAt'] != null
          ? (data['followUpDoneAt'] as Timestamp).toDate()
          : msg.followUpDoneAt,
      isReplied: data['isReplied'] as bool? ?? msg.isReplied,
      queryReply: data['queryReply'] as String? ?? msg.queryReply,
      repliedBy: data['repliedBy'] as String? ?? msg.repliedBy,
      repliedAt: data['repliedAt'] != null
          ? (data['repliedAt'] as Timestamp).toDate()
          : msg.repliedAt,
      deletedFor: updatedDeletedFor,
      deleted: data['deleted'] as bool? ?? msg.deleted,
      text: data['text'] as String? ?? msg.text,
    );
    await LocalDatabaseService().saveMessage(updatedMsg, parentType: 'enquiry');
    service.updateMessage(enquiryId, messageId, data).catchError((e) {
      print('Error updating message in Firestore: $e');
    });
  }

  // UnreadCountsMixin hooks — module flavor routes through config + service.
  // Shares ONE unread algorithm with TaskProvider; fixes the Sales/CRM badge
  // that never cleared (the old reset wrote only to Firestore, which doesn't
  // bump updatedAt, so delta sync never echoed it back to SQLite).
  @override
  String get unreadTableName => config.enquiriesTableName;

  @override
  Future<void> writeUnreadFields(String itemId, Map<String, dynamic> updates) =>
      service.updateEnquiryFields(itemId, updates);

  // ── AssigneeIdentityRepairMixin<EnquiryModel> hooks ──────────────────
  // Sales/CRM inherit the SAME creator-side multi-assignee identity repair
  // Task uses (one shared mixin) — legacy enquiries with compressed/misaligned
  // assigneeUids/assigneePhones heal identically, unioning resolved UIDs into
  // participants so cross-device sync delivers to every assignee. The model
  // field adapters + candidate/user accessors are generic over WorkItem and
  // live in WorkItemProvider; only the config-routed scope, the EnquiryModel
  // copyWith rebuild and the remote/local write-back stay module-specific.
  @override
  String get repairScope => config.enquiriesTableName;

  @override
  EnquiryModel applyIdentityRepair(
    EnquiryModel item, {
    required List<String> participants,
    required Map<String, dynamic> extraFields,
    String? assignedToUid,
    String? assignedToPhone,
  }) => item.copyWith(
    participants: participants,
    extraFields: extraFields,
    assignedToUid: assignedToUid,
    assignedToPhone: assignedToPhone,
    updatedAt: DateTime.now(),
  );

  @override
  Future<void> writeIdentityRepairRemote(
    String itemId,
    Map<String, dynamic> updates,
  ) => service.updateEnquiryFields(itemId, updates);

  @override
  Future<void> writeIdentityRepairLocal(EnquiryModel repairedItem) =>
      LocalDatabaseService().saveModuleEnquiries([
        repairedItem,
      ], tableName: config.enquiriesTableName);

  // ── Filter / Sort ──────────────────────────────────────────────────────

  // The filter/sort STATE and its setters (setStatusFilter/setSortBy/
  // clearFilters/setSearchQuery) live in WorkItemProvider (generic); only the
  // EnquiryModel-specific application (status pipeline, clientName search/sort)
  // stays here.

  List<EnquiryModel> _applyStatusFilter(List<EnquiryModel> list) {
    // Archived view: only archived cards, newest first. Archived cards are
    // never auto-purged — unarchive restores them in place.
    if (_statusFilter == 'Archived') {
      final archived = list.where((e) => e.isArchived && !e.isDeleted).toList()
        ..sort(
          (a, b) => (b.archivedAt ?? b.updatedAt).compareTo(
            a.archivedAt ?? a.updatedAt,
          ),
        );
      return archived;
    }
    // Deleted view: only soft-deleted cards, most recently deleted first.
    if (_statusFilter == 'Deleted') {
      final deleted = list.where((e) => e.isDeleted).toList()
        ..sort(
          (a, b) => (b.deletedAt ?? b.updatedAt).compareTo(
            a.deletedAt ?? a.updatedAt,
          ),
        );
      return deleted;
    }
    // Archived and deleted cards stay out of every normal view.
    list = list.where((e) => !e.isArchived && !e.isDeleted).toList();
    // Milestone submenu: cards whose milestone with this title is still
    // pending (that step hasn't been completed yet).
    if (_statusFilter.startsWith('Milestone: ')) {
      final title = _statusFilter.substring('Milestone: '.length);
      return list
          .where(
            (e) => e.milestones.any((m) => m.title == title && !m.isCompleted),
          )
          .toList();
    }
    // Match by status label or special filters
    final statusIndex = config.statusLabels.indexOf(_statusFilter);
    if (statusIndex >= 0) {
      final statusName = config.statusNames[statusIndex];
      return list.where((e) => e.status == statusName).toList();
    }
    switch (_statusFilter) {
      case 'Unassigned':
        // Creator's own cards still waiting to be assigned (assign-later).
        final me = _loadedUserId;
        if (me == null) return const [];
        return list
            .where((e) => e.createdBy == me && e.assignedTo.isEmpty)
            .toList();
      case 'Overdue':
        // Date-only rule (the deadline's calendar day has passed), matching the
        // assignee summary strip's Over count and the card overdue dot
        // (isPastDeadline). The timestamp-based [EnquiryModel.isOverdue] could
        // flag a due-today card as overdue mid-afternoon while the strip still
        // counted it Active — the same strip-vs-filter mismatch fixed on Task.
        return list.where((e) {
          final d = e.deadline;
          if (d == null || e.isClosed) return false;
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          return DateTime(d.year, d.month, d.day).isBefore(today);
        }).toList();
      case 'High Priority':
        return list.where((e) => e.priority == 3).toList();
      case 'Milestones Pending':
        return list
            .where(
              (e) =>
                  e.milestones.isNotEmpty &&
                  !e.milestones.any((m) => m.isCompleted),
            )
            .toList();
      case 'Milestones In Progress':
        return list.where((e) {
          final done = e.milestones.where((m) => m.isCompleted).length;
          return done > 0 && done < e.milestones.length;
        }).toList();
      case 'Milestones Complete':
        return list
            .where(
              (e) =>
                  e.milestones.isNotEmpty &&
                  e.milestones.every((m) => m.isCompleted),
            )
            .toList();
      // Payment/delivery kind filters: built on the user-ticked milestones
      // tagged (in Milestone Settings) as payment or delivery steps.
      // 'Received'/'Delivered' = every tagged step is ticked; 'Pending' =
      // at least one tagged step is still unticked. Cards with no tagged
      // step never appear in either view.
      case 'Payments Received':
        return list.where((e) {
          final tagged = e.milestones
              .where((m) => m.effectiveKind == MilestoneModel.kindPayment)
              .toList();
          return tagged.isNotEmpty && tagged.every((m) => m.isCompleted);
        }).toList();
      case 'Payments Pending':
        return list
            .where(
              (e) => e.milestones.any(
                (m) =>
                    m.effectiveKind == MilestoneModel.kindPayment &&
                    !m.isCompleted,
              ),
            )
            .toList();
      case 'Delivered':
        return list.where((e) {
          final tagged = e.milestones
              .where((m) => m.effectiveKind == MilestoneModel.kindDelivery)
              .toList();
          return tagged.isNotEmpty && tagged.every((m) => m.isCompleted);
        }).toList();
      case 'Delivery Pending':
        return list
            .where(
              (e) => e.milestones.any(
                (m) =>
                    m.effectiveKind == MilestoneModel.kindDelivery &&
                    !m.isCompleted,
              ),
            )
            .toList();
      case 'All':
      default:
        return list;
    }
  }

  List<EnquiryModel> _applySearch(List<EnquiryModel> list) {
    if (_searchQuery.isEmpty) return list;
    final q = _searchQuery.toLowerCase();
    return list.where((e) {
      return e.title.toLowerCase().contains(q) ||
          e.clientName.toLowerCase().contains(q) ||
          // Company / site (existing client fields — Phase-2D): typing a
          // company or site/address name filters the list to it.
          (e.clientCompany ?? '').toLowerCase().contains(q) ||
          (e.clientAddress ?? '').toLowerCase().contains(q) ||
          e.assignedTo.toLowerCase().contains(q) ||
          e.description.toLowerCase().contains(q) ||
          (e.lastMessageText?.toLowerCase().contains(q) ?? false) ||
          (e.category?.toLowerCase().contains(q) ?? false) ||
          e.tags.any((tag) => tag.toLowerCase().contains(q)) ||
          e.milestones.any((m) => m.title.toLowerCase().contains(q)) ||
          // User-defined custom-field values (Phase-2E sector fit): a value
          // typed into a custom field — e.g. an asset no. or site — is
          // searchable just like the built-in fields.
          _matchesCustomField(e.extraFields, q);
    }).toList();
  }

  /// Whether any of the item's custom-field values (slots 1..3) contain the
  /// lower-cased query [q]. Shared by the Sales/CRM search so a sector's
  /// seeded fields (asset no., site, PO …) are findable like native fields.
  static bool _matchesCustomField(Map<String, dynamic>? extraFields, String q) {
    if (extraFields == null) return false;
    for (int slot = 1; slot <= 3; slot++) {
      final v = extraFields['customField$slot'];
      if (v is String && v.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  List<EnquiryModel> _applySort(List<EnquiryModel> list) {
    final sorted = List<EnquiryModel>.from(list);
    switch (_sortBy) {
      case 'Due Date':
        sorted.sort((a, b) {
          if (a.deadline == null && b.deadline == null) return 0;
          if (a.deadline == null) return 1;
          if (b.deadline == null) return -1;
          return a.deadline!.compareTo(b.deadline!);
        });
        break;
      case 'Priority':
        sorted.sort((a, b) => b.priority.compareTo(a.priority));
        break;
      case 'Created':
        sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case 'Client':
        sorted.sort(
          (a, b) =>
              a.clientName.toLowerCase().compareTo(b.clientName.toLowerCase()),
        );
        break;
      case 'Progress':
        sorted.sort((a, b) => a.progress.compareTo(b.progress));
        break;
      case 'Last Action':
      default:
        // Match the card's displayed time (lastMessageTime ?? updatedAt)
        sorted.sort(
          (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
            a.lastMessageTime ?? a.updatedAt,
          ),
        );
        break;
    }
    return sorted;
  }

  // ── Action Icons Cache ──────────────────────────────────────────────────

  // reloadActionIcons (all loaded items) lives in WorkItemProvider; only the
  // module-specific actions-table subscription that drives it stays here.

  @override
  void dispose() {
    // Module-specific subscriptions first, then the shared engine teardown
    // (teams, change-set consumer, recovery/identity timers, caches) which
    // lives in WorkItemProvider.dispose().
    _actionsTableSub?.cancel();
    _iconReloadDebounce?.cancel();
    super.dispose();
  }
}
