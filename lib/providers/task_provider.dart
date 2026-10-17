import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';
import '../models/task_draft.dart';
import '../models/message.dart';
import '../services/firebase_service.dart';
import '../services/local_database_service.dart';
import '../services/notification_service.dart';
import '../services/module_plan_cache.dart';
import '../services/sync_telemetry.dart';
import '../services/startup_trace.dart';
import '../utils/helpers.dart';
import '../utils/paywall_constants.dart';
import '../modules/shared/team_service.dart';
import '../modules/shared/work_item.dart';
import '../modules/shared/module_config.dart';
import '../modules/shared/recurrence_rule.dart';
import '../modules/shared/team_management_mixin.dart';
import 'change_set_consumer_mixin.dart';
import '../modules/sales/services/milestone_settings_service.dart';
import '../models/milestone.dart';
import 'module_caches_mixin.dart';
import 'unread_counts_mixin.dart';
import 'assignee_identity_repair_mixin.dart';
import 'pagination_mixin.dart';

class TaskProvider extends ChangeNotifier
    with
        ModuleCachesMixin,
        TeamManagementMixin,
        ChangeSetConsumerMixin<TaskModel>,
        UnreadCountsMixin,
        AssigneeIdentityRepairMixin<TaskModel>,
        PaginationMixin<TaskModel> {
  final FirebaseService _firebaseService = FirebaseService();

  // ModuleCachesMixin hooks — task flavor of the shared cache logic
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchActionIcons(
    List<String> parentIds,
  ) => LocalDatabaseService().getActionIconsForParents(parentIds);

  @override
  void startMessageSyncFor(String parentId) =>
      _firebaseService.startMessageSync(parentId);

  @override
  int get prefetchMessageLimit => 10000;

  // Fresh-install message recovery hooks — task flavor of the shared sweep in
  // ModuleCachesMixin (Sales/CRM supply the enquiry flavor). The algorithm,
  // timer and latch all live in the mixin; only these adapters differ.
  @override
  String get recoveryScope => 'tasks';

  @override
  String get recoveryLatchKey => 'messages_recovered_$_currentUserId';

  @override
  Set<String> get recoveryCandidateIds => <String>{
    ..._byMeTasks.map((t) => t.id),
    ..._toMeTasks.map((t) => t.id),
    ..._participantTasks.map((t) => t.id),
  };

  @override
  int get recoveryBatchSize => 2;

  @override
  Future<void> fetchMessagesForRecovery(String id) =>
      _firebaseService.fetchMessagesOnceFor(id);

  List<TaskModel> _byMeTasks = [];
  List<TaskModel> _toMeTasks = [];
  bool _isLoading = false;
  String _selectedFilter = 'All';
  String _sortBy = 'Latest Activity';
  String _searchQuery = '';
  String _currentUserId = ''; // Current user's UID for filtering
  String _currentUserPhone =
      ''; // Current user's normalized phone for dual-lookup queries
  DateTime? _lastSyncTime; // When streams last emitted
  String? _syncError; // Last sync error
  int _rawByMeCount = 0; // Before filtering
  Timer? _reloadDebounce; // Coalesces rapid Firestore sync writes
  Timer? _iconReloadDebounce; // Coalesces rapid action-icon reloads
  bool _reloadInFlight = false; // A SQLite -> memory reload is running
  bool _reloadQueued = false; // Another reload was asked for mid-flight
  Timer? _syncStartTimer; // Defers Firestore sync past first-frame work
  int _rawToMeCount = 0; // Before filtering

  // Stream subscription for SQLite change notifications
  StreamSubscription<TableChange>? _tableChangesSubscription;
  List<TaskModel> _participantTasks =
      []; // Tasks where user is in participants list

  // ── Teams (personal, viewer-side placement) ────────────────────────────
  // Team state + CRUD come from TeamManagementMixin; the hooks below plug in
  // the task-specific table, pref key, placement count and reload behavior.
  final TeamService _teamService = TeamService(
    tableName: 'task_teams',
    logTag: 'TaskTeams',
  );
  static const String _teamPrefKey = 'current_task_team_id';

  @override
  TeamService get teamService => _teamService;

  @override
  String get teamPrefKey => _teamPrefKey;

  @override
  Future<int> cardCountInTeam(String teamId) async => getTeamTaskCount(teamId);

  @override
  void onTeamSwitched() {
    resetPagination();
    if (_currentUserId.isNotEmpty) _reloadTasksFromSQLite();
  }

  // Getters
  String get currentUserId => _currentUserId;
  bool get hasMoreTasks => hasMoreItems;

  // ── PaginationMixin<TaskModel> hooks ────────────────────────────────────
  // The page cursor, has-more flag, in-flight guard and load-more algorithm
  // come from the shared PaginationMixin (Sales/CRM run the identical engine).
  // Task supplies only its guard, its SQLite read and its 3-way list splice.
  @override
  bool get canLoadMore => _currentUserId.isNotEmpty;

  @override
  Future<List<TaskModel>> fetchPage(int offset, int limit) =>
      LocalDatabaseService().getTasksPaginated(
        _currentUserId,
        limit: limit,
        offset: offset,
      );

  @override
  Future<void> appendPage(List<TaskModel> newTasks) async {
    // Add new tasks to the appropriate lists
    final newByMe = newTasks
        .where((t) => t.createdBy == _currentUserId)
        .toList();
    final newToMe = newTasks
        .where((t) => t.assignedToUid == _currentUserId)
        .toList();
    final newParticipant = newTasks
        .where(
          (t) =>
              t.participants.contains(_currentUserId) &&
              t.createdBy != _currentUserId &&
              t.assignedToUid != _currentUserId,
        )
        .toList();

    _byMeTasks.addAll(newByMe);
    _toMeTasks.addAll(newToMe);
    _participantTasks.addAll(newParticipant);

    // Preload action icons for new tasks
    final newTaskIds = newTasks.map((t) => t.id).toSet();
    await preloadActionIconsFor(newTaskIds.toList());
  }

  /// Load more tasks (lazy loading / pagination) — thin wrapper over the
  /// shared engine so existing `taskProvider.loadMoreTasks()` call sites stay.
  Future<void> loadMoreTasks() => loadMoreItems();

  /// Get all tasks from SQLite (for Actions tab which needs all tasks)
  Future<List<TaskModel>> getAllTasks(String userId) async {
    return await LocalDatabaseService().getTasks(userId);
  }

  bool _matchesCurrentUser(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return false;
    return normalized == _currentUserId;
  }

  bool _listContainsCurrentUser(Iterable<dynamic> values) {
    return values.any((value) => _matchesCurrentUser(value?.toString()));
  }

  bool _isCreatedByCurrentUser(TaskModel task) {
    return _matchesCurrentUser(task.createdBy);
  }

  bool _isAssignedToCurrentUser(TaskModel task) {
    final extraFields = task.extraFields ?? const <String, dynamic>{};
    final assigneeUids = extraFields['assigneeUids'];

    // Check if current user is the assignee (primary or one of multi-assignees)
    // NOTE: Do NOT check task.participants - that includes creators too!
    return _matchesCurrentUser(task.assignedToUid) ||
        (assigneeUids is List && _listContainsCurrentUser(assigneeUids)) ||
        (_currentUserPhone.isNotEmpty &&
            task.assignedToPhone != null &&
            task.assignedToPhone!.trim() == _currentUserPhone);
  }

  /// Check if the task is assigned ONLY to the current user (no other assignees).
  bool _isAssignedOnlyToMe(TaskModel task) {
    final extraFields = task.extraFields ?? const <String, dynamic>{};
    final assigneeUids = extraFields['assigneeUids'];

    // If there are multi-assignees, check if I'm the only one
    if (assigneeUids is List && assigneeUids.isNotEmpty) {
      // Filter out nulls and empty strings
      final validUids = assigneeUids
          .where((uid) => uid != null && uid.toString().isNotEmpty)
          .map((uid) => uid.toString())
          .toList();
      // If only one UID and it matches current user, it's assigned only to me
      if (validUids.length == 1) {
        return _matchesCurrentUser(validUids.first);
      }
      // Multiple assignees - not only me
      return false;
    }

    // Single assignee: check if it's the current user
    return _matchesCurrentUser(task.assignedToUid) ||
        (_currentUserPhone.isNotEmpty &&
            task.assignedToPhone != null &&
            task.assignedToPhone!.trim() == _currentUserPhone);
  }

  /// BY ME tasks: tasks I created for OTHERS (even if I'm also an assignee).
  /// If I created a task ONLY for myself, it goes in TO ME.
  List<TaskModel> get byMeTasks {
    final filtered = _byMeTasks
        .where(
          (task) => _isCreatedByCurrentUser(task) && !_isAssignedOnlyToMe(task),
        )
        .toList();
    // Deduplicate by task ID
    final seenIds = <String>{};
    final deduped = <TaskModel>[];
    for (final task in filtered) {
      if (seenIds.add(task.id)) {
        deduped.add(task);
      }
    }
    final existing = _filterAndSortTasks(deduped);
    return existing;
  }

  /// TO ME tasks: tasks where current user is the assignee or one of the assignees
  /// Includes: tasks assigned to me by others + tasks I created ONLY for myself
  /// EXCLUDES: tasks I created for others (those go in By Me)
  List<TaskModel> get toMeTasks {
    final allToMe = <TaskModel>[];

    // Add tasks where current user is the primary assignee.
    allToMe.addAll(_toMeTasks);

    // Add group/multi-assignee tasks where current user is one of the assignees.
    allToMe.addAll(_participantTasks);

    // Add tasks I created ONLY for myself (self-assigned with no other assignees)
    allToMe.addAll(
      _byMeTasks.where(
        (task) => _isCreatedByCurrentUser(task) && _isAssignedOnlyToMe(task),
      ),
    );

    // Remove duplicates by task ID
    final taskMap = <String, TaskModel>{};
    for (final task in allToMe) {
      taskMap[task.id] = task;
    }

    // Filter out:
    // 1. Tasks I created for OTHERS (those go in By Me)
    // 2. Draft tasks where the current user is NOT the creator
    final filtered = taskMap.values.where((task) {
      // EXCLUDE: Tasks I created for others (not only for myself)
      if (_isCreatedByCurrentUser(task) && !_isAssignedOnlyToMe(task)) {
        return false;
      }

      // Filter out draft tasks where the current user is NOT the creator
      // (drafts should only be visible to the creator until activated)
      final isDraft = task.extraFields?['isDraft'] == true;
      if (!isDraft) return true; // Not a draft, always show
      // Draft task: only show if current user is the creator
      return _isCreatedByCurrentUser(task);
    }).toList();

    final existing = _filterAndSortTasks(filtered);
    return existing;
  }

  /// PARTICIPANT tasks: tasks where user is one of the assignees but not the primary assignee.
  List<TaskModel> get participantTasks => _filterAndSortTasks(
    _participantTasks
        .where(
          (task) =>
              _isAssignedToCurrentUser(task) &&
              !_matchesCurrentUser(task.assignedToUid),
        )
        .toList(),
  );

  /// DELETED tasks: soft-deleted tasks visible only under the 'Deleted' filter
  List<TaskModel> get deletedTasks {
    final all = <TaskModel>{};
    for (final t in _byMeTasks) {
      if (t.isDeleted) all.add(t);
    }
    for (final t in _toMeTasks) {
      if (t.isDeleted) all.add(t);
    }
    for (final t in _participantTasks) {
      if (t.isDeleted) all.add(t);
    }
    return all.toList()..sort(
      (a, b) =>
          (b.deletedAt ?? b.updatedAt).compareTo(a.deletedAt ?? a.updatedAt),
    );
  }

  /// ARCHIVED tasks: hidden from normal views, shown only in the Archived
  /// filter. Never auto-purged — unarchive restores them in place.
  List<TaskModel> get archivedTasks {
    final all = <TaskModel>{};
    for (final t in _byMeTasks) {
      if (t.isArchived) all.add(t);
    }
    for (final t in _toMeTasks) {
      if (t.isArchived) all.add(t);
    }
    for (final t in _participantTasks) {
      if (t.isArchived) all.add(t);
    }
    return all.toList()..sort(
      (a, b) =>
          (b.archivedAt ?? b.updatedAt).compareTo(a.archivedAt ?? a.updatedAt),
    );
  }

  /// ALL visible tasks: combines byMe, toMe, and participant tasks (no duplicates)
  List<TaskModel> get allTasks {
    final taskMap = <String, TaskModel>{};

    // Add byMe tasks
    for (final task in byMeTasks) {
      taskMap[task.id] = task;
    }

    // Add toMe tasks
    for (final task in toMeTasks) {
      taskMap[task.id] = task;
    }

    // Add participant tasks
    for (final task in participantTasks) {
      taskMap[task.id] = task;
    }

    return _filterAndSortTasks(taskMap.values.toList());
  }

  bool get isLoading => _isLoading;
  String get selectedFilter => _selectedFilter;
  String get sortBy => _sortBy;
  String get searchQuery => _searchQuery;

  /// Debug info for sync verification
  Map<String, dynamic> get debugInfo => {
    'currentUserId': _currentUserId,
    'isLoading': _isLoading,
    'rawByMeCount': _rawByMeCount,
    'rawToMeCount': _rawToMeCount,
    'filteredByMeCount': byMeTasks.length,
    'filteredToMeCount': toMeTasks.length,
    'lastSyncTime': _lastSyncTime?.toIso8601String() ?? 'never',
    'syncError': _syncError ?? 'none',
  };

  TaskProvider();

  // ── Teams (personal, viewer-side placement) ─────────────────────────────

  // Team state getters (teams/currentTeamId/currentTeamName/teamsLoaded/
  // defaultTeamId) and team CRUD come from TeamManagementMixin.

  /// Big line of the Task home AppBar title: the module display name
  /// ("WorkTracker", sector-aware). Paired with [teamAppBarName] to match the
  /// Sales/CRM two-line home format.
  String get moduleAppBarName => ModuleConfig.task.displayName;

  /// Small line under the module name: the current team name, or "Team One"
  /// when no team name is set.
  String get teamAppBarName {
    final team = currentTeamName;
    return (team != null && team.isNotEmpty) ? team : 'Team One';
  }

  /// Viewer-side placement: the team a task is displayed under for the
  /// CURRENT user.
  ///   • My own task  → the team I created it in (stored [TaskModel.teamId]).
  ///   • Someone else's task → MY own team whose members contain the creator
  ///     (the counterpart); if I have no such team it lands in my default team.
  String displayTeamIdForTask(TaskModel task) {
    if (_isCreatedByCurrentUser(task)) {
      final stored = task.teamId;
      if (stored != null && stored.isNotEmpty) return stored;
      return defaultTeamId;
    }
    for (final team in teams) {
      if (team.hasMember(task.createdBy)) return team.id;
    }
    // Phone-keyed members: phonebook contacts added before joining the app.
    final phone = Helpers.normalizePhone(task.createdByPhone);
    if (phone != null && phone.isNotEmpty) {
      for (final team in teams) {
        if (team.hasMemberPhone(phone)) return team.id;
      }
    }
    return defaultTeamId;
  }

  /// True if [task] should appear under the currently selected team.
  bool _matchesCurrentTeam(TaskModel task) {
    // No team context yet (teams not loaded / none exist) → show everything.
    if (currentTeamId == null || teams.isEmpty) return true;
    return displayTeamIdForTask(task) == currentTeamId;
  }

  /// Public team-scope check so views that load tasks on their own (e.g. the
  /// Assignee tab) can honor the currently selected team.
  bool isInCurrentTeam(TaskModel task) => _matchesCurrentTeam(task);

  /// Number of visible tasks currently placed in [teamId] (deletion guard).
  int getTeamTaskCount(String teamId) {
    final seen = <String>{};
    var count = 0;
    for (final list in [_byMeTasks, _toMeTasks, _participantTasks]) {
      for (final t in list) {
        if (t.isDeleted || t.isArchived || !seen.add(t.id)) continue;
        if (displayTeamIdForTask(t) == teamId) count++;
      }
    }
    return count;
  }

  // loadTeams / ensureDefaultTeam / createTeam / renameTeam / deleteTeam /
  // switchTeam / addTeamMember / removeTeamMember all come from
  // TeamManagementMixin (shared with Sales/CRM providers).

  /// Phone-number switch sweep: re-point the denormalized phone fields on the
  /// user's Firestore task docs (creator/assignee slots) to [newPhone] and
  /// mirror locally. Ownership is UID-keyed, so tasks never change hands —
  /// only the phone metadata moves to the new number.
  Future<void> migrateOwnPhone({
    required String oldPhone,
    required String newPhone,
  }) async {
    if (_currentUserId.isEmpty || newPhone.isEmpty) return;
    final newNorm = Helpers.normalizePhone(newPhone) ?? newPhone;
    final oldDigits = oldPhone.replaceAll(RegExp(r'\D'), '');
    final oldSuffix = oldDigits.length >= 10
        ? oldDigits.substring(oldDigits.length - 10)
        : oldDigits;

    bool isOldPhone(String? stored) {
      if (stored == null || stored.isEmpty) return false;
      if (stored == newNorm) return false;
      if (stored == oldPhone) return true;
      final digits = stored.replaceAll(RegExp(r'\D'), '');
      if (digits.isEmpty || oldSuffix.isEmpty) return false;
      return digits.length >= 10 &&
          digits.substring(digits.length - 10) == oldSuffix;
    }

    final seen = <String>{};
    final all = [..._byMeTasks, ..._toMeTasks, ..._participantTasks];
    var migrated = 0;
    for (final task in all) {
      if (!seen.add(task.id) || task.isDeleted) continue;

      final updates = <String, dynamic>{};
      if (task.createdBy == _currentUserId && isOldPhone(task.createdByPhone)) {
        updates['createdByPhone'] = newNorm;
      }
      if ((task.assignedToUid ?? '') == _currentUserId &&
          isOldPhone(task.assignedToPhone)) {
        updates['assignedToPhone'] = newNorm;
      }
      final extra = task.extraFields ?? <String, dynamic>{};
      final phones = extra['assigneePhones'];
      List<String>? newPhones;
      if (phones is List && phones.any((p) => isOldPhone(p?.toString()))) {
        newPhones = phones
            .map(
              (p) =>
                  isOldPhone(p?.toString()) ? newNorm : (p?.toString() ?? ''),
            )
            .toList();
        updates['extraFields.assigneePhones'] = newPhones;
      }
      if (updates.isEmpty) continue;

      try {
        await _firebaseService.updateTaskField(task.id, updates);
        migrated++;
      } catch (e) {
        // Offline / doc missing — local mirror below still applies.
        print('[PhoneSwitch] Firestore sweep write failed for ${task.id}: $e');
      }

      // Mirror locally so this device reflects the new phone immediately.
      final newExtra = Map<String, dynamic>.from(extra);
      if (newPhones != null) newExtra['assigneePhones'] = newPhones;
      try {
        await LocalDatabaseService().saveTasks([
          task.copyWith(
            createdByPhone: updates.containsKey('createdByPhone')
                ? newNorm
                : task.createdByPhone,
            assignedToPhone: updates.containsKey('assignedToPhone')
                ? newNorm
                : task.assignedToPhone,
            extraFields: newExtra,
            updatedAt: DateTime.now(),
          ),
        ]);
      } catch (e) {
        print('[PhoneSwitch] Local mirror failed for ${task.id}: $e');
      }
    }
    if (migrated > 0) {
      debugPrint('[PhoneSwitch] Swept phone on $migrated Firestore task(s)');
    }
  }

  List<TaskModel> _filterAndSortTasks(List<TaskModel> tasks) {
    var filtered = tasks;

    // Always exclude soft-deleted and archived tasks from normal views
    filtered = filtered
        .where((task) => !task.isDeleted && !task.isArchived)
        .toList();

    // Team scoping — keep only tasks that belong to the currently selected
    // team (viewer-side placement, see displayTeamIdForTask).
    filtered = filtered.where(_matchesCurrentTeam).toList();

    // Do NOT filter out completed/cancelled here - let the home screen handle status filtering
    // The home screen's _statusFilter will filter appropriately

    // Apply search filter (title, description, assignee, tags, category,
    // milestones)
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((task) {
        // Basic fields
        if (task.title.toLowerCase().contains(q)) return true;
        if (task.description.toLowerCase().contains(q)) return true;
        if (task.assignedTo.toLowerCase().contains(q)) return true;
        // Tags
        if (task.tags.any((tag) => tag.toLowerCase().contains(q))) return true;
        // Template
        if (task.template?.toLowerCase().contains(q) ?? false) return true;
        // Category
        if ((task.category ?? '').toLowerCase().contains(q)) return true;
        // Customer / company / site — the existing client fields (Phase-2D):
        // typing a customer, company or site name in search filters to it.
        if ((task.clientName ?? '').toLowerCase().contains(q)) return true;
        if ((task.clientCompany ?? '').toLowerCase().contains(q)) return true;
        if ((task.clientAddress ?? '').toLowerCase().contains(q)) return true;
        // Milestone titles
        if (task.milestones.any((m) => m.title.toLowerCase().contains(q))) {
          return true;
        }
        // User-defined custom-field values (Phase-2E sector fit): a value typed
        // into a custom field — e.g. an asset no. or site — is searchable just
        // like the built-in fields.
        final extras = task.extraFields;
        if (extras != null) {
          for (int slot = 1; slot <= 3; slot++) {
            final v = extras['customField$slot'];
            if (v is String && v.toLowerCase().contains(q)) return true;
          }
        }
        // Note: Message search requires Firestore query - not implemented yet
        return false;
      }).toList();
    }

    // Apply category filter
    switch (_selectedFilter) {
      case 'Deadlines Nearing':
        filtered = filtered.where((task) => task.isDeadlineNearing).toList();
        break;
      case 'Overdue':
        filtered = filtered.where((task) => task.isOverdue).toList();
        break;
      case 'High Priority':
        filtered = filtered.where((task) => task.priority >= 3).toList();
        break;
      case 'Urgent Only':
        filtered = filtered.where((task) => task.isUrgent).toList();
        break;
      case 'Longest Pending':
        filtered = List.from(filtered)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
    }

    // Apply sorting
    switch (_sortBy) {
      case 'Deadline':
        filtered = List.from(filtered)
          ..sort((a, b) {
            if (a.deadline == null) return 1;
            if (b.deadline == null) return -1;
            return a.deadline!.compareTo(b.deadline!);
          });
        break;
      case 'Priority':
        filtered = List.from(filtered)
          ..sort((a, b) => b.priority.compareTo(a.priority));
        break;
      case 'Oldest':
        filtered = List.from(filtered)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case 'Latest Activity':
      default:
        // Sort by the same key the card displays (lastMessageTime ?? updatedAt)
        // so list order always matches the visible "ago" timestamps.
        filtered = List.from(filtered)
          ..sort(
            (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
              a.lastMessageTime ?? a.updatedAt,
            ),
          );
    }

    return filtered;
  }

  // Load tasks for user — SQLite only. Background sync writes to SQLite.
  void loadTasks(String userId, {String? userPhone}) {
    StartupTrace.instance.instant(
      'task.loadTasks (arm 5s sync)',
      StartupTraceKind.provider,
    );
    // Account switch: drop the previous user's in-memory lists immediately
    // so they can't flash while the new (empty) SQLite read is in flight.
    if (_currentUserId.isNotEmpty && _currentUserId != userId) {
      _byMeTasks = [];
      _toMeTasks = [];
      _participantTasks = [];
    }
    _currentUserId = userId;
    _currentUserPhone = userPhone?.trim() ?? '';
    _isLoading = true;
    _syncError = null;
    resetPagination(); // Reset pagination on new load
    notifyListeners();

    // Load personal teams (drives viewer-side task placement). Fire-and-forget;
    // it notifies listeners once loaded, re-scoping the lists by team.
    unawaited(loadTeams(userId));

    // Defer background sync (Firestore -> SQLite) so the initial listener
    // emissions (which decode every cached task doc) don't compete with
    // first-frame rendering. SQLite already has the data for instant display.
    // 5s: keeps the burst clear of the user's first interactions and ahead
    // of the staggered FCM/contacts/backfill jobs (6s/8s/9s).
    _syncStartTimer?.cancel();
    _syncStartTimer = Timer(const Duration(seconds: 5), () {
      if (_currentUserId == userId) {
        _firebaseService.startTaskSync(userId, userPhone: userPhone);
      }
    });

    // One-shot creator-side repair of multi-assignee identity fields
    // (12s: after the sync burst and staggered startup jobs settle).
    scheduleInitialIdentityRepair();

    // One-shot fresh-install recovery (15s: after task sync settles) — the
    // SHARED sweep in ModuleCachesMixin (Sales/CRM run the identical one). It
    // reads the current user + loaded tasks live when it fires, so a user
    // switch that re-runs loadTasks simply retargets it — no stale-user guard
    // needed, since re-arming already cancelled the previous user's timer.
    scheduleMessageRecovery();

    // Cancel existing subscription
    _tableChangesSubscription?.cancel();

    // Initial read from SQLite
    _reloadTasksFromSQLite();

    // Auto-purge soft-deleted tasks older than 30 days (fire-and-forget)
    _purgeOldDeletedTasks();

    // Auto-cleanup stale pending messages (fire-and-forget)
    _cleanupStalePendingMessages();

    // Tasks now consume rich change-sets (4.1) and patch only the rows that
    // changed — see ChangeSetConsumerMixin, the shared consumer also used by
    // Sales/CRM via BaseModuleProvider. Idempotent: safe on every loadTasks.
    startChangeSetConsumer();

    // Actions-icon reload: listens on the typed change-set stream but reacts
    // only to the `actions` table (debounced) — separate from the task-row
    // patching in ChangeSetConsumerMixin.
    _tableChangesSubscription = LocalDatabaseService().tableChanges2.listen((
      change,
    ) {
      if (change.table == 'actions') {
        // Actions changed - only reload icons, not tasks (debounced to
        // coalesce bursts of writes during background sync)
        _iconReloadDebounce?.cancel();
        _iconReloadDebounce = Timer(const Duration(milliseconds: 300), () {
          _reloadActionIcons(skipNotify: false);
        });
      }
    });
  }

  /// Telemetry hook: count provider notifications. Purely observational — a
  /// no-op unless diagnostics recording is enabled.
  ///
  /// [revision] also advances on every notify so derived UI values (the home
  /// Actions badge `_attentionCount`) can memoize on data change instead of
  /// recomputing on every rebuild — see R3 in DB_SYNC_FIREBASE_EFFICIENCY.md.
  int revision = 0;

  @override
  void notifyListeners() {
    revision++;
    SyncTelemetry.instance.recordNotify();
    StartupTrace.instance.notify();
    super.notifyListeners();
  }

  /// Re-read all tasks from SQLite (not paginated for initial load).
  ///
  /// Overlapping calls collapse into one trailing pass: a single reload scans
  /// every task row, rebuilds the three lists and pre-reads all action-icon
  /// strips, so running two at once doubles the UI-isolate work for the same
  /// result. Bursts are common (a chat message bumps the task clock, the sync
  /// listeners land a batch, a team switch fires) and used to pile up.
  ///
  /// The pass ends in a notify ONLY when something a card renders actually
  /// changed (or a spinner/error state has to clear). Those bursts usually
  /// decode to the very same rows, and each notify re-filters, re-sorts and
  /// rebuilds every card for identical pixels — that redundant rebuild is the
  /// visible "refresh" a few seconds after launch, when the deferred Firestore
  /// sync lands.
  void _reloadTasksFromSQLite() {
    SyncTelemetry.instance.recordReloadInvoked();
    if (_reloadInFlight) {
      SyncTelemetry.instance.recordReloadCoalesced();
      _reloadQueued = true;
      return;
    }
    _reloadInFlight = true;
    _reloadQueued = false;
    SyncTelemetry.instance.recordReloadExecuted();
    final tr = StartupTrace.instance.begin(
      'task.reload',
      kind: StartupTraceKind.provider,
    );
    // Load ALL tasks initially (not paginated)
    LocalDatabaseService()
        .getTasks(_currentUserId)
        .then((allTasks) async {
          // Captured BEFORE the lists are replaced — see [_bucketSignature].
          // A first load must always notify (the spinner has to disappear even
          // for an empty list), and so must an error clearing.
          final wasLoading = _isLoading;
          final hadError = _syncError != null;
          final beforeSignature = _bucketSignature();

          // Reset lists and populate with all tasks
          _byMeTasks = allTasks
              .where((t) => t.createdBy == _currentUserId)
              .toList();
          _toMeTasks = allTasks
              .where((t) => t.assignedToUid == _currentUserId)
              .toList();
          _participantTasks = allTasks
              .where(
                (t) =>
                    t.participants.contains(_currentUserId) &&
                    t.createdBy != _currentUserId &&
                    t.assignedToUid != _currentUserId,
              )
              .toList();

          // Check if there are more tasks beyond page size (for load more)
          markFirstPage(allTasks.length);

          _rawByMeCount = _byMeTasks.length;
          _rawToMeCount = _toMeTasks.length;
          _isLoading = false;
          _lastSyncTime = DateTime.now();
          _syncError = null;

          // Batch: Load action icons BEFORE notifying to avoid double rebuild
          final iconsChanged = await _preloadActionIcons();

          // Single notification after all data is ready — skipped when the
          // reload changed nothing the UI renders.
          if (wasLoading ||
              hadError ||
              iconsChanged ||
              _bucketSignature() != beforeSignature) {
            notifyListeners();
          }
        })
        .catchError((e) {
          _isLoading = false;
          notifyListeners();
        })
        .whenComplete(() {
          StartupTrace.instance.end(
            tr,
            rows:
                _byMeTasks.length +
                _toMeTasks.length +
                _participantTasks.length,
          );
          _reloadInFlight = false;
          if (!_reloadQueued) return;
          _reloadQueued = false;
          // Short delay so writes arriving during the pass batch together
          // instead of triggering one reload each.
          _reloadDebounce?.cancel();
          _reloadDebounce = Timer(
            const Duration(milliseconds: 150),
            _reloadTasksFromSQLite,
          );
        });
  }

  /// Preload action icons for all tasks (called before notifyListeners).
  /// Returns whether any strip actually changed.
  Future<bool> _preloadActionIcons() async {
    final allTaskIds = <String>{};
    allTaskIds.addAll(_byMeTasks.map((t) => t.id));
    allTaskIds.addAll(_toMeTasks.map((t) => t.id));
    allTaskIds.addAll(_participantTasks.map((t) => t.id));
    return preloadActionIconsFor(allTaskIds.toList());
  }

  // ── No-op notify suppression (Task twin of workItemSignature) ──────────
  // TaskModel deliberately does not implement WorkItem (see the divergence note
  // in WorkItemProvider), so the Task-side render signature lives here. Keep the
  // two in step: both must cover every field a list card renders, including the
  // ones written WITHOUT bumping `updatedAt` — unreadCounts and the lastMessage*
  // snapshot (UnreadCountsMixin) — or a real badge/preview update gets
  // suppressed along with the no-ops.

  String _taskSignature(TaskModel t) {
    final unread = t.unreadCounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      t.id,
      t.updatedAt.millisecondsSinceEpoch,
      t.title.hashCode,
      t.description.hashCode,
      t.createdBy,
      t.createdByName ?? '',
      t.assignedTo,
      t.assignedToUid ?? '',
      t.assignedToPhone ?? '',
      t.priority,
      t.isUrgent ? 1 : 0,
      t.progress,
      t.isClosed ? 1 : 0,
      t.isCancelled ? 1 : 0,
      t.isArchived ? 1 : 0,
      t.isDeleted ? 1 : 0,
      t.isGroupTask ? 1 : 0,
      t.deadline?.millisecondsSinceEpoch ?? 0,
      t.startDate?.millisecondsSinceEpoch ?? 0,
      t.teamId ?? '',
      t.displayId ?? 0,
      t.category ?? '',
      t.rating ?? 0,
      t.reminderCount,
      t.warningCount,
      t.statusRequestCount,
      t.tags.join(','),
      t.participants.join(','),
      t.clientName ?? '',
      t.extraFields?.toString().hashCode ?? 0,
      unread.map((x) => '${x.key}:${x.value}').join(','),
      t.lastMessageText?.hashCode ?? 0,
      t.lastMessageTime?.millisecondsSinceEpoch ?? 0,
      t.milestones.map(milestoneSignature).join(','),
    ].join('|');
  }

  /// Signature of everything the home lists render: the three ownership
  /// buckets, in the order the tabs read them.
  String _bucketSignature() => [
    _byMeTasks.map(_taskSignature).join('#'),
    _toMeTasks.map(_taskSignature).join('#'),
    _participantTasks.map(_taskSignature).join('#'),
  ].join('~');

  // ── ChangeSetConsumerMixin<TaskModel> hooks (4.1) ─────────────────────
  // The SHARED change-set consumer patches only the tasks that changed instead
  // of re-scanning the whole table. The task-specific surface is limited to
  // these hooks; the subscription, coalescing and patch-vs-reload decision live
  // in the shared mixin — common to Sales and CRM via BaseModuleProvider.

  @override
  String get changeSetTable => 'tasks';

  @override
  Future<List<TaskModel>> fetchRowsByIds(Set<String> ids) =>
      LocalDatabaseService().getTasksByIds(_currentUserId, ids);

  @override
  String idOf(TaskModel row) => row.id;

  @override
  Future<void> applyUpsertedRows(List<TaskModel> rows) async {
    // Refresh action icons for JUST the changed tasks BEFORE notifying — same
    // discipline as the full reload's _preloadActionIcons (icons then one
    // notify), so a patched card never renders with a stale icon strip.
    await preloadActionIconsFor(rows.map((t) => t.id).toList());
    for (final task in rows) {
      _removeTaskFromLists(task.id);
      _placeTaskInLists(task);
    }
    _sortTaskLists();
    _rawByMeCount = _byMeTasks.length;
    _rawToMeCount = _toMeTasks.length;
  }

  @override
  void removeRowsByIds(Set<String> ids) {
    for (final id in ids) {
      _removeTaskFromLists(id);
    }
    _rawByMeCount = _byMeTasks.length;
    _rawToMeCount = _toMeTasks.length;
  }

  @override
  Future<void> fullReload() async {
    // _reloadTasksFromSQLite is fire-and-forget with its own coalescing guard
    // and calls notifyListeners() itself when the scan completes.
    _reloadTasksFromSQLite();
  }

  /// Place a task into whichever lists it matches — the SAME predicates as
  /// _reloadTasksFromSQLite (a self-assigned task lands in both byMe and toMe).
  void _placeTaskInLists(TaskModel t) {
    if (t.createdBy == _currentUserId) _byMeTasks.add(t);
    if (t.assignedToUid == _currentUserId) _toMeTasks.add(t);
    if (t.participants.contains(_currentUserId) &&
        t.createdBy != _currentUserId &&
        t.assignedToUid != _currentUserId) {
      _participantTasks.add(t);
    }
  }

  void _removeTaskFromLists(String id) {
    _byMeTasks.removeWhere((t) => t.id == id);
    _toMeTasks.removeWhere((t) => t.id == id);
    _participantTasks.removeWhere((t) => t.id == id);
  }

  /// Re-sort the three lists newest-first, matching the SQL `ORDER BY
  /// updatedAt DESC` the full reload relies on.
  void _sortTaskLists() {
    int byUpdatedAtDesc(TaskModel a, TaskModel b) =>
        b.updatedAt.compareTo(a.updatedAt);
    _byMeTasks.sort(byUpdatedAtDesc);
    _toMeTasks.sort(byUpdatedAtDesc);
    _participantTasks.sort(byUpdatedAtDesc);
  }

  /// Auto-purge soft-deleted tasks older than 30 days from SQLite and Firestore.
  /// The Firestore purge query is gated to once per day — no need to spend
  /// a query on every app launch.
  void _purgeOldDeletedTasks() async {
    try {
      await LocalDatabaseService().purgeDeletedTasks();
      final prefs = await SharedPreferences.getInstance();
      final lastPurgeMs = prefs.getInt('last_firestore_purge_ms') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastPurgeMs < const Duration(days: 1).inMilliseconds) return;
      await prefs.setInt('last_firestore_purge_ms', now);
      await _firebaseService.purgeDeletedTasks();
    } catch (e) {
      print('TaskProvider: Error purging deleted tasks: $e');
    }
  }

  /// Auto-cleanup messages stuck in 'pending' upload state for >30 minutes.
  void _cleanupStalePendingMessages() async {
    try {
      final count = await LocalDatabaseService().cleanupStalePendingMessages();
      if (count > 0) {
        print('TaskProvider: Cleaned up $count stale pending messages');
      }
    } catch (e) {
      print('TaskProvider: Error cleaning up pending messages: $e');
    }
  }

  // ── AssigneeIdentityRepairMixin<TaskModel> hooks ───────────────────────
  // Task is the reference implementation; the shared mixin owns the whole
  // sweep (contact load, phone→UID resolution, latches, write-back). These
  // adapt it to TaskModel + task state. BaseModuleProvider supplies the
  // EnquiryModel equivalents, so the same proven repair heals Sales/CRM too.
  @override
  String get repairScope => 'tasks';

  @override
  String get repairUserId => _currentUserId;

  @override
  String get repairUserPhone => _currentUserPhone;

  @override
  List<TaskModel> get repairCandidates => _byMeTasks;

  @override
  String repairItemId(TaskModel item) => item.id;

  @override
  Map<String, dynamic>? repairItemExtraFields(TaskModel item) =>
      item.extraFields;

  @override
  String repairItemCreatedBy(TaskModel item) => item.createdBy;

  @override
  String repairItemAssignedToName(TaskModel item) => item.assignedTo;

  @override
  String? repairItemAssignedToUid(TaskModel item) => item.assignedToUid;

  @override
  String? repairItemAssignedToPhone(TaskModel item) => item.assignedToPhone;

  @override
  List<String> repairItemParticipants(TaskModel item) => item.participants;

  @override
  TaskModel applyIdentityRepair(
    TaskModel item, {
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
  ) => _firebaseService.updateTaskField(itemId, updates);

  @override
  Future<void> writeIdentityRepairLocal(TaskModel repairedItem) =>
      LocalDatabaseService().saveTasks([repairedItem]);

  // Set filter
  void setFilter(String filter) {
    _selectedFilter = filter;
    notifyListeners();
  }

  // Set sort
  void setSort(String sort) {
    _sortBy = sort;
    notifyListeners();
  }

  // Set search query
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  /// The task exactly as it was persisted by [createTask] — milestone
  /// templates applied, team stamped, id assigned. Callers that navigate
  /// straight to TaskDetailScreen must use this instead of their in-hand
  /// model, which predates template application (the defaults would
  /// otherwise never show up on the freshly created task).
  Future<TaskModel> persistedTask(TaskModel fallback, String taskId) async {
    return await LocalDatabaseService().getTaskById(taskId) ??
        fallback.copyWith(id: taskId);
  }

  // Create task
  Future<String?> createTask(
    TaskModel task, {
    String? planType,
    String? explicitId,
  }) async {
    try {
      // Hard plan-limit gate: block before any persistence. Counts come from
      // local SQLite so this stays fast and works offline.
      final effectivePlan = await ModulePlanCache.effectivePlanForModule(
        planType,
        'task',
      );
      if (effectivePlan != null) {
        final check = await PaywallLimits.checkCreateTaskLimit(
          planType: effectivePlan,
          task: task,
          countActiveTasks: LocalDatabaseService().countActiveTasks,
        );
        if (!check.allowed) {
          print('[Paywall] Blocked task creation: ${check.message}');
          throw PlanLimitException(check.feature, check.message);
        }
      }

      final taskId = explicitId ?? Helpers.generateId();
      // Milestone templates: brand-new tasks without milestones get the
      // user-configured task templates (TOOLS → Milestone Settings).
      // Templates only affect newly created tasks — same as Sales/CRM.
      if (task.milestones.isEmpty) {
        try {
          final milestoneSettings = MilestoneSettingsService(module: 'task');
          // Only apply templates when milestones are enabled in settings.
          if (await milestoneSettings.isEnabled()) {
            final templates = await milestoneSettings.getEffectiveTemplates();
            if (templates.isNotEmpty) {
              final templateNow = DateTime.now();
              task = task.copyWith(
                milestones: templates.asMap().entries.map((entry) {
                  final t = entry.value;
                  DateTime? deadline;
                  if (t.deadlineOffsetDays != null) {
                    deadline = templateNow.add(
                      Duration(days: t.deadlineOffsetDays!),
                    );
                  }
                  return MilestoneModel(
                    id: Helpers.generateId(),
                    title: t.title,
                    order: entry.key,
                    createdAt: templateNow,
                    deadline: deadline,
                    // Payment/delivery kind rides onto the card (parity with
                    // Sales/CRM; task templates rarely tag, but the shape holds).
                    kind: t.kind,
                  );
                }).toList(),
              );
            }
          }
        } catch (e) {
          print('[TaskProvider] Error applying milestone templates: $e');
        }
      }
      // Stamp the creator's currently selected team (single source of truth for
      // viewer-side placement). Keep an explicitly-set teamId if present.
      final stampedTask = task.teamId != null
          ? task
          : task.copyWith(teamId: currentTeamId ?? defaultTeamId);
      // Recurrence (Phase-2A): a brand-new item carrying a rule but no seriesId
      // becomes the series ANCHOR — seriesId = its own id, nextDue = the first
      // occurrence after the anchor date. The shared materializer later reads
      // nextDue to generate occurrences. Generated occurrences arrive with
      // recurrence == null and a preset seriesId, so they are never re-anchored.
      var preparedTask = stampedTask;
      if (stampedTask.recurrence != null && stampedTask.seriesId == null) {
        final rule = RecurrenceRule.tryParse(stampedTask.recurrence);
        preparedTask = stampedTask.copyWith(
          seriesId: taskId,
          nextDue: rule?.nextOccurrenceAfter(rule.anchor),
        );
      }
      // Write to SQLite first — instant persistence
      final savedTask = preparedTask.copyWith(id: taskId);
      await LocalDatabaseService().saveTask(savedTask);
      // Fire-and-forget to Firestore for delivery to other users
      _firebaseService
          .createTask(preparedTask, taskId: taskId)
          .then((_) {})
          .catchError((e) {
            print('Error creating task in Firestore: $e');
          });
      // Schedule local deadline reminders (fire-and-forget)
      _syncTaskReminders(savedTask);
      return taskId;
    } on PlanLimitException {
      rethrow;
    } catch (e) {
      print('Error creating task: $e');
      return null;
    }
  }

  // Update task
  Future<void> updateTask(
    String taskId,
    TaskModel task, {
    bool clearAssignee = false,
  }) async {
    try {
      // Write to SQLite first
      // clearAssignee honors the intentional unassign blanks through the
      // local-first blank-preservation merge (mirrors the Firestore guard).
      await LocalDatabaseService().saveTask(task, clearAssignee: clearAssignee);
      // Keep in-memory lists in sync so list cards (draft flag, status,
      // milestones, etc.) refresh immediately without waiting for a reload.
      _byMeTasks = _byMeTasks.map((t) => t.id == taskId ? task : t).toList();
      _toMeTasks = _toMeTasks.map((t) => t.id == taskId ? task : t).toList();
      _participantTasks = _participantTasks
          .map((t) => t.id == taskId ? task : t)
          .toList();
      notifyListeners();
      // Fire-and-forget to Firestore
      _firebaseService
          .updateTask(taskId, task, clearAssignee: clearAssignee)
          .catchError((e) {
            print('Error updating task in Firestore: $e');
          });
      // Keep local deadline reminders in sync with the new state
      _syncTaskReminders(task);
    } catch (e) {
      print('Error updating task: $e');
    }
  }

  /// Schedule/cancel local deadline reminders based on task state.
  /// Open task with a deadline → reminders on; closed/cancelled/deleted or
  /// no deadline → reminders cancelled.
  void _syncTaskReminders(TaskModel task) {
    final active =
        !task.isClosed &&
        !task.isCancelled &&
        !task.isDeleted &&
        !task.isArchived;
    NotificationService().syncDeadlineReminders(
      taskId: task.id,
      taskTitle: task.title,
      deadline: active ? task.deadline : null,
    );
  }

  /// Public rebuild trigger so settings screens (e.g. milestone enable
  /// toggle) can refresh list cards immediately.
  void refresh() => notifyListeners();

  // Soft-delete task — marks isDeleted=true, hidden from normal views
  Future<void> deleteTask(String taskId) async {
    try {
      final task = await LocalDatabaseService().getTaskById(taskId);
      if (task == null) return;
      final updated = task.copyWith(
        isDeleted: true,
        deletedAt: DateTime.now(),
        deletedBy: _currentUserId,
        updatedAt: DateTime.now(),
      );
      // Update SQLite
      await LocalDatabaseService().saveTask(updated);
      // Deleted tasks shouldn't ring deadline alerts
      NotificationService().cancelDeadlineReminders(taskId);
      // Keep in-memory lists in sync immediately so swipe-to-dismiss UIs
      // remove the card without waiting for the next reload.
      _byMeTasks = _byMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _toMeTasks = _toMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _participantTasks = _participantTasks
          .map((t) => t.id == taskId ? updated : t)
          .toList();
      notifyListeners();
      // Fire-and-forget to Firestore
      _firebaseService
          .tasks()
          .doc(taskId)
          .update({
            'isDeleted': true,
            'deletedAt': FieldValue.serverTimestamp(),
            'deletedBy': _currentUserId,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print('Error soft-deleting task in Firestore: $e');
          });
    } catch (e) {
      print('Error soft-deleting task: $e');
    }
  }

  // Restore a soft-deleted task
  Future<void> restoreTask(String taskId) async {
    try {
      final task = await LocalDatabaseService().getTaskById(taskId);
      if (task == null || !task.isDeleted) return;
      // Full rebuild (not copyWith) — copyWith cannot clear deletedAt/deletedBy
      // back to null (`deletedAt: deletedAt ?? this.deletedAt`), which left the
      // restored task still carrying its delete timestamp (mirrors the
      // restoreEnquiry fix in BaseModuleProvider).
      final updated = TaskModel(
        id: task.id,
        title: task.title,
        description: task.description,
        createdBy: task.createdBy,
        createdByName: task.createdByName,
        createdByPhone: task.createdByPhone,
        assignedTo: task.assignedTo,
        assignedToUid: task.assignedToUid,
        assignedToPhone: task.assignedToPhone,
        participants: task.participants,
        participantHistory: task.participantHistory,
        isGroupTask: task.isGroupTask,
        priority: task.priority,
        isUrgent: task.isUrgent,
        deadline: task.deadline,
        progress: task.progress,
        tags: task.tags,
        extraFields: task.extraFields,
        createdAt: task.createdAt,
        startDate: task.startDate,
        updatedAt: DateTime.now(),
        isClosed: task.isClosed,
        isCancelled: task.isCancelled,
        rating: task.rating,
        template: task.template,
        reminderCount: task.reminderCount,
        warningCount: task.warningCount,
        statusRequestCount: task.statusRequestCount,
        lastMessageText: task.lastMessageText,
        lastMessageTime: task.lastMessageTime,
        milestones: task.milestones,
        unreadCounts: task.unreadCounts,
        displayId: task.displayId,
        category: task.category,
        teamId: task.teamId,
        isArchived: task.isArchived,
        archivedAt: task.archivedAt,
        archivedBy: task.archivedBy,
      );
      // Update SQLite
      await LocalDatabaseService().saveTask(updated);
      // Keep in-memory lists in sync so the restored card shows its clean
      // state immediately (no stale deletedAt lingering on list cards).
      _byMeTasks = _byMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _toMeTasks = _toMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _participantTasks = _participantTasks
          .map((t) => t.id == taskId ? updated : t)
          .toList();
      notifyListeners();
      // Restored task should ring deadline alerts again
      _syncTaskReminders(updated);
      // Fire-and-forget to Firestore
      _firebaseService
          .tasks()
          .doc(taskId)
          .update({
            'isDeleted': false,
            'deletedAt': null,
            'deletedBy': null,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print('Error restoring task in Firestore: $e');
          });
    } catch (e) {
      print('Error restoring task: $e');
    }
  }

  // Archive a task — marks isArchived=true, hidden from normal views.
  // Unlike delete, archived tasks are never purged and can be restored
  // at any time via unarchiveTask.
  Future<void> archiveTask(String taskId) async {
    try {
      final task = await LocalDatabaseService().getTaskById(taskId);
      if (task == null || task.isArchived) return;
      final updated = task.copyWith(
        isArchived: true,
        archivedAt: DateTime.now(),
        archivedBy: _currentUserId,
        updatedAt: DateTime.now(),
      );
      // Update SQLite
      await LocalDatabaseService().saveTask(updated);
      // Archived tasks shouldn't ring deadline alerts
      NotificationService().cancelDeadlineReminders(taskId);
      _byMeTasks = _byMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _toMeTasks = _toMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _participantTasks = _participantTasks
          .map((t) => t.id == taskId ? updated : t)
          .toList();
      notifyListeners();
      // Fire-and-forget to Firestore
      _firebaseService
          .tasks()
          .doc(taskId)
          .update({
            'isArchived': true,
            'archivedAt': FieldValue.serverTimestamp(),
            'archivedBy': _currentUserId,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print('Error archiving task in Firestore: $e');
          });
    } catch (e) {
      print('Error archiving task: $e');
    }
  }

  // Restore an archived task back to normal views
  Future<void> unarchiveTask(String taskId) async {
    try {
      final task = await LocalDatabaseService().getTaskById(taskId);
      if (task == null || !task.isArchived) return;
      final updated = task.copyWith(
        isArchived: false,
        updatedAt: DateTime.now(),
      );
      // Update SQLite
      await LocalDatabaseService().saveTask(updated);
      _byMeTasks = _byMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _toMeTasks = _toMeTasks.map((t) => t.id == taskId ? updated : t).toList();
      _participantTasks = _participantTasks
          .map((t) => t.id == taskId ? updated : t)
          .toList();
      notifyListeners();
      // Re-arm deadline reminders if the task is still active
      _syncTaskReminders(updated);
      // Fire-and-forget to Firestore
      _firebaseService
          .tasks()
          .doc(taskId)
          .update({
            'isArchived': false,
            'archivedAt': null,
            'archivedBy': null,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print('Error unarchiving task in Firestore: $e');
          });
    } catch (e) {
      print('Error unarchiving task: $e');
    }
  }

  // Permanently delete a task (hard delete — for purge or manual)
  Future<void> permanentlyDeleteTask(String taskId) async {
    try {
      // Drop from in-memory lists FIRST (before any await) so swipe-to-purge
      // UIs remove the card synchronously — the SQLite purge can take long
      // enough for a stream-driven rebuild to snap the Dismissible back.
      _byMeTasks = _byMeTasks.where((t) => t.id != taskId).toList();
      _toMeTasks = _toMeTasks.where((t) => t.id != taskId).toList();
      _participantTasks = _participantTasks
          .where((t) => t.id != taskId)
          .toList();
      notifyListeners();
      await LocalDatabaseService().deleteTask(taskId);
      NotificationService().cancelDeadlineReminders(taskId);
      _firebaseService.tasks().doc(taskId).delete().catchError((e) {
        print('Error permanently deleting task in Firestore: $e');
      });
    } catch (e) {
      print('Error permanently deleting task: $e');
    }
  }

  // Cancel task — marks isCancelled=true; filtered from home cards
  Future<void> cancelTask(String taskId) async {
    try {
      // Update SQLite first
      final task = await LocalDatabaseService().getTaskById(taskId);
      if (task != null) {
        await LocalDatabaseService().saveTask(
          task.copyWith(
            extraFields: {...?task.extraFields, 'isCancelled': true},
          ),
        );
      }
      // Fire-and-forget to Firestore
      _firebaseService
          .tasks()
          .doc(taskId)
          .update({
            'isCancelled': true,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print('Error cancelling task in Firestore: $e');
          });
    } catch (e) {
      print('Error cancelling task: $e');
    }
  }

  // Save task as draft
  Future<String?> saveTaskDraft(TaskDraft draft) async {
    try {
      final draftId = Helpers.generateId();
      // Write to SQLite first
      await LocalDatabaseService().saveTaskDraft(
        draftId,
        _currentUserId,
        draft,
      );
      // Fire-and-forget to Firestore
      _firebaseService.saveTaskDraft(draft).then((_) {}).catchError((e) {
        print('Error saving draft to Firestore: $e');
      });
      return draftId;
    } catch (e) {
      print('Error saving draft: $e');
      return null;
    }
  }

  // Send message
  Future<void> sendMessage(String taskId, MessageModel message) async {
    try {
      // Use the message's existing ID (already generated by caller)
      final msgId = message.id.isNotEmpty ? message.id : Helpers.generateId();
      // Write to SQLite first — instant persistence
      final savedMessage = message.id.isNotEmpty
          ? message
          : message.copyWith(id: msgId);
      await LocalDatabaseService().saveMessage(savedMessage);
      // Unread badge for the recipients, resolved from the card itself rather
      // than from whichever screen happened to send it. The detail screen used
      // to do this for typed messages only, so a reminder or status update fired
      // from the home screen — or a forward, or a failed-send retry — bumped
      // nothing at all, and because the push function also skips non-regular
      // messages the recipient then got no signal whatsoever. Doing it once here
      // covers every send path.
      var unreadRecipientUids = const <String>[];
      if (UnreadCountsMixin.awaitsRecipientRead(message.type, message.text)) {
        unreadRecipientUids = await _unreadRecipientsForTask(
          taskId,
          message.senderId,
        );
      }
      // Fire-and-forget to Firestore for delivery to other users
      _firebaseService
          .sendMessage(
            taskId,
            message,
            messageId: msgId,
            unreadRecipientUids: unreadRecipientUids,
          )
          .then((_) {})
          .catchError((e) {
            print('Error sending message in Firestore: $e');
            // Mark message as failed in local DB so UI can show it
            LocalDatabaseService().markMessageUploadFailed(
              msgId,
              'Failed to sync: $e',
            );
          });
    } catch (e) {
      print('Error sending message: $e');
      rethrow;
    }
  }

  /// UIDs that should see a new message on this task as unread — everyone who
  /// can open the card, minus the sender. Resolved from the card's own fields,
  /// never from a team-list lookup.
  /// The lists are PAGINATED, so a card outside the loaded page — or one
  /// opened straight from a notification — is absent from memory; the SQLite
  /// row is the fallback, otherwise the badge silently goes to nobody.
  Future<List<String>> _unreadRecipientsForTask(
    String taskId,
    String senderId,
  ) async {
    final task =
        _taskInMemory(taskId) ??
        await LocalDatabaseService().getTaskById(taskId);
    if (task == null) return const [];
    return <String>{
      task.createdBy,
      if (task.assignedToUid != null) task.assignedToUid!,
      ...task.participants,
    }.where((uid) => uid.isNotEmpty && uid != senderId).toList();
  }

  /// Find a task among the lists this provider already holds — no I/O.
  TaskModel? _taskInMemory(String taskId) {
    for (final t in _byMeTasks) {
      if (t.id == taskId) return t;
    }
    for (final t in _toMeTasks) {
      if (t.id == taskId) return t;
    }
    for (final t in _participantTasks) {
      if (t.id == taskId) return t;
    }
    return null;
  }

  // Update message
  Future<void> updateMessage(
    String taskId,
    String messageId,
    Map<String, dynamic> updates,
  ) async {
    try {
      // Update SQLite first — use copyWith to avoid toMap/fromMap type issues.
      // R6.4: PK lookup by messageId, not getMessages(taskId)+firstWhere. The
      // old path read up to 50 rows to find one and threw StateError when the
      // target was older than the latest 50 (e.g. closing an older action),
      // which is why such closes silently failed. Same row, O(1), any age.
      final msg = await LocalDatabaseService().getMessageById(messageId);
      if (msg == null) throw StateError('Message not found: $messageId');

      // Handle deletedFor: FieldValue.arrayUnion can't be applied locally,
      // so manually add the UID to the existing list
      List<String> updatedDeletedFor = msg.deletedFor;
      if (updates['deletedFor'] is FieldValue) {
        // Extract the UID from the FieldValue (it's always a single-element union)
        // We parse it from the Firestore FieldValue by reading the updates map
        // Since we can't inspect FieldValue internals, handle it via the caller's convention:
        // the caller passes 'deletedForUid' alongside the FieldValue for local use
        final uid = updates['deletedForUid'] as String?;
        if (uid != null && !msg.deletedFor.contains(uid)) {
          updatedDeletedFor = [...msg.deletedFor, uid];
        }
      } else if (updates['deletedFor'] is List<String>) {
        updatedDeletedFor = updates['deletedFor'] as List<String>;
      }

      final updatedMsg = msg.copyWith(
        isFollowUpDone:
            updates['isFollowUpDone'] as bool? ?? msg.isFollowUpDone,
        followUpDoneBy:
            updates['followUpDoneBy'] as String? ?? msg.followUpDoneBy,
        followUpDoneAt: updates['followUpDoneAt'] != null
            ? (updates['followUpDoneAt'] as Timestamp).toDate()
            : msg.followUpDoneAt,
        isReplied: updates['isReplied'] as bool? ?? msg.isReplied,
        queryReply: updates['queryReply'] as String? ?? msg.queryReply,
        repliedBy: updates['repliedBy'] as String? ?? msg.repliedBy,
        repliedAt: updates['repliedAt'] != null
            ? (updates['repliedAt'] as Timestamp).toDate()
            : msg.repliedAt,
        deletedFor: updatedDeletedFor,
        deleted: updates['deleted'] as bool? ?? msg.deleted,
        text: updates['text'] as String? ?? msg.text,
      );
      await LocalDatabaseService().saveMessage(updatedMsg);
      // Fire-and-forget to Firestore
      _firebaseService.updateMessage(taskId, messageId, updates).catchError((
        e,
      ) {
        print('Error updating message in Firestore: $e');
      });
    } catch (e) {
      print('Error updating message: $e');
      rethrow;
    }
  }

  // Delete message
  Future<void> deleteMessage(String taskId, String messageId) async {
    try {
      // Delete from SQLite first
      await LocalDatabaseService().deleteMessage(messageId);
      // Fire-and-forget to Firestore
      _firebaseService.deleteMessage(taskId, messageId).catchError((e) {
        print('Error deleting message in Firestore: $e');
      });
    } catch (e) {
      print('Error deleting message: $e');
      rethrow;
    }
  }

  /// Full clean undo of a just-sent action card, on top of the chat
  /// soft-delete the caller has already pushed through [updateMessage]:
  /// drop the durable system-log mirror and reverse the unread badge the
  /// card raised on the recipients, so the Activity log, pending counts
  /// and every other device agree the action never happened.
  ///
  /// SQLite FIRST (local mirror row deleted, local unreadCounts decremented),
  /// then the Firestore transports — strictly sequential and fire-and-forget,
  /// so the UI never awaits the network here and a transport failure never
  /// masquerades as a failed undo (the local stores already agreed; the next
  /// detail-screen re-mirror reconciles whatever the transport missed).
  Future<void> undoActionCard(
    String taskId,
    MessageModel message, {
    required List<String> recipientUids,
  }) async {
    // 1. SQLite first — the undo is done once local storage agrees.
    await LocalDatabaseService().deleteSystemLogLocal(taskId, message.id);
    // Same definition the send path used to raise the badge (shared static),
    // so undo reverses exactly what was counted — never more, never less.
    final raisedBadge = UnreadCountsMixin.awaitsRecipientRead(
      message.type,
      message.text,
    );
    if (raisedBadge && recipientUids.isNotEmpty) {
      await LocalDatabaseService().decrementUnreadCountsLocal(
        unreadTableName,
        taskId,
        recipientUids,
      );
    }

    // 2. Sequential fire-and-forget transports.
    _firebaseService.deleteSystemLog(taskId, message.id).catchError((e) {
      print('Error deleting system log mirror in Firestore: $e');
    });
    if (raisedBadge && recipientUids.isNotEmpty) {
      // Bundled with an updatedAt bump so the delta-synced recipients
      // actually receive the decrement — an updatedAt-silent write can
      // lose the race and never be re-triggered (UnreadCountsMixin rule;
      // unlike a chat-open reset, this one MUST travel).
      _firebaseService
          .updateTaskField(taskId, {
            'updatedAt': FieldValue.serverTimestamp(),
            for (final uid in recipientUids)
              'unreadCounts.$uid': FieldValue.increment(-1),
          })
          .catchError((e) {
            print('Error reversing unread badge in Firestore: $e');
          });
    }
  }

  // UnreadCountsMixin hooks — task flavor of the shared unread logic. The
  // algorithm (increment recipients / reset sender, and reset-on-open written
  // to SQLite first) lives in the mixin; only the table + transport differ.
  @override
  String get unreadTableName => 'tasks';

  @override
  Future<void> writeUnreadFields(String itemId, Map<String, dynamic> updates) =>
      _firebaseService.updateTaskField(itemId, updates);

  // Get SQLite-backed message stream for real-time updates
  Stream<List<MessageModel>> messageStream(String taskId) {
    return LocalDatabaseService().watchMessages(taskId);
  }

  // Get SQLite-backed task stream for real-time updates
  //
  // R6.1: single-row PK lookup (getTaskById), not a full-table getTasks +
  // firstWhere. The only consumer (task_detail_screen) subscribes for a task
  // the user already opened, so the PK returns the same row while avoiding an
  // O(table) deserialize on every 'tasks' table-change event — that per-event
  // full-table read was the dominant source of the getTasks call storm.
  Stream<TaskModel?> taskStream(String taskId) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await LocalDatabaseService().getTaskById(taskId);
      await for (final _ in LocalDatabaseService().tableChanges2.where(
        (c) => c.table == 'tasks',
      )) {
        yield await LocalDatabaseService().getTaskById(taskId);
      }
    }).asBroadcastStream();
  }

  /// Test Firebase connectivity and permissions
  Future<Map<String, dynamic>> testFirebaseConnection(String userId) async {
    return await _firebaseService.testFirebaseConnection(userId);
  }

  /// Cache of messages per task and action-icons cache both live in
  /// ModuleCachesMixin (shared with BaseModuleProvider).

  /// Cache messages for a task (called from TaskDetailScreen after loading)
  void cacheMessages(String taskId, List<MessageModel> messages) {
    // Skip the notify when nothing changed: the detail screen's message
    // stream calls this on EVERY emission, and notifying each time forced
    // every screen watching this provider (home list behind the detail
    // screen included) to rebuild for identical data.
    final existing = messagesCache[taskId];
    final unchanged =
        existing != null &&
        existing.length == messages.length &&
        existing
            .map((m) => m.id)
            .toSet()
            .containsAll(messages.map((m) => m.id));
    messagesCache[taskId] = messages;
    if (!unchanged) notifyListeners();
  }

  /// Reload action icons for all current tasks from the actions table.
  /// Uses batch query (1 DB call instead of N).
  /// If [skipNotify] is true, don't call notifyListeners() (used when called from _reloadTasksFromSQLite).
  void _reloadActionIcons({bool skipNotify = false}) {
    final allTaskIds = <String>{};
    allTaskIds.addAll(_byMeTasks.map((t) => t.id));
    allTaskIds.addAll(_toMeTasks.map((t) => t.id));
    allTaskIds.addAll(_participantTasks.map((t) => t.id));
    reloadActionIconsFor(allTaskIds.toList(), skipNotify: skipNotify);
  }

  /// Remove cached messages for a task (forces re-fetch)
  void removeCachedMessages(String taskId) {
    messagesCache.remove(taskId);
  }

  /// One-time fetch of messages for a task from SQLite.
  /// Also triggers background sync to warm the cache for next open.
  Future<List<MessageModel>> fetchMessagesOnce(String taskId) async {
    // Start background sync to warm Firestore -> SQLite pipeline
    _firebaseService.startMessageSync(taskId);
    final messages = await LocalDatabaseService().getMessages(
      taskId,
      limit: 10000,
    );
    messagesCache[taskId] = messages;
    notifyListeners();
    return messages;
  }

  /// Prefetch messages for multiple tasks in parallel from SQLite (used by Actions tab).
  /// Also triggers background syncs to warm the cache.
  Future<void> prefetchMessagesForTasks(List<String> taskIds) =>
      prefetchMessagesInto(taskIds);

  /// Tear down the Task list Firestore listeners (`tasks_by*`). Wired to the
  /// Task home screen's dispose so switching to Sales/CRM (which uses
  /// pushReplacement, disposing this screen) unmounts Task's 4 list listeners
  /// instead of keeping them streaming for the whole session. Idempotent
  /// (cancel-by-key); SQLite keeps rows and re-attach on return is a delta
  /// read. Root [dispose] also routes through here.
  void stopListSync() {
    _firebaseService.stopTaskSync(_currentUserId, userPhone: _currentUserPhone);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _iconReloadDebounce?.cancel();
    _syncStartTimer?.cancel();
    cancelIdentityRepair();
    cancelMessageRecovery();
    _tableChangesSubscription?.cancel();
    stopChangeSetConsumer();
    disposeTeams();
    stopListSync();
    print('TaskProvider: Disposed and cancelled subscriptions');
    super.dispose();
  }
}
