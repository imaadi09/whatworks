import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/task.dart';
import '../models/task_draft.dart';
import '../models/task_participant.dart';
import '../models/milestone.dart';
import '../models/system_log.dart';
import '../modules/sales/models/enquiry.dart';
import '../modules/sales/models/sales_team.dart';
import '../utils/helpers.dart';
import 'sync_telemetry.dart';
import 'startup_trace.dart';

/// What happened to the rows described by a [TableChange].
enum ChangeKind { upsert, delete }

/// The signed-in user's cached plan bundle, read back from the `user_plan`
/// table (see [LocalDatabaseService.getUserPlan]). [modulePlans] is shaped
/// exactly like [UserModel.modulePlans] — per-module maps whose `startDate` /
/// `expiryDate` are Firestore [Timestamp]s — so it hydrates the model and
/// ModulePlanCache with no conversion at the call site.
class LocalUserPlan {
  final String? planType;
  final DateTime? planExpiry;
  final Map<String, Map<String, dynamic>> modulePlans;
  const LocalUserPlan({
    this.planType,
    this.planExpiry,
    this.modulePlans = const {},
  });
}

/// One change-set event on [LocalDatabaseService.tableChanges2].
///
/// Carries the affected row [ids] so a consumer can patch just those rows in
/// memory instead of re-running a full-table scan (the write->pixel amplifier
/// in SYNC_AND_DATABASE_ARCHITECTURE.md 4.1). An empty [ids] set means
/// "unspecified / bulk" — consumers must fall back to a full reload, which
/// keeps behaviour identical to the legacy table-name-only stream. Defined once
/// here in the shared DB layer, so it is common to Task, Sales and CRM.
class TableChange {
  final String table;
  final Set<String> ids;
  final ChangeKind kind;
  const TableChange({
    required this.table,
    this.ids = const <String>{},
    this.kind = ChangeKind.upsert,
  });
}

/// One memoized full-table scan in [LocalDatabaseService]'s shared snapshot
/// cache. Valid only while [revision] still equals the owning table's
/// `revisionOf(table)`; [rows] are the already-deserialized models, handed back
/// to callers as a shallow copy so the shared snapshot can't be mutated.
class _TableSnapshot<T> {
  const _TableSnapshot(this.revision, this.rows);
  final int revision;
  final List<T> rows;
}

/// Enforce the participants invariant `participants ⊇ {createdBy} ∪ {assigneeUids}`
/// and return the de-duplicated union. Module-agnostic: used by both
/// [LocalDatabaseService.taskToRow] and [LocalDatabaseService.enquiryToRow] (and
/// the v23 backfill), so every locally-persisted row carries a participants list
/// that cross-device sync can discover via
/// `where('participants', arrayContains: uid)`. A missing uid means the row never
/// reaches that device, so this is a sync-correctness guarantee, not just display
/// metadata. [extraFields]'assigneeUids' supplies the uids of multi-assignee rows.
List<String> participantsUnion(
  List<String> existing, {
  String? createdBy,
  String? assignedToUid,
  Map<String, dynamic>? extraFields,
}) {
  final set = <String>{
    ...existing.where((u) => u.isNotEmpty),
    if (createdBy != null && createdBy.isNotEmpty) createdBy,
    if (assignedToUid != null && assignedToUid.isNotEmpty) assignedToUid,
  };
  final multi = extraFields?['assigneeUids'];
  if (multi is List) {
    for (final u in multi) {
      if (u is String && u.isNotEmpty) set.add(u);
    }
  }
  return set.toList();
}

/// Local SQLite database service for instant data loading
/// Provides synchronous-like reads from local storage
/// Firebase syncs data in background to keep local DB updated
class LocalDatabaseService {
  static Database? _database;
  static const String _dbName = 'whatworks_local.db';
  static const int _dbVersion = 32;

  // Singleton pattern
  static final LocalDatabaseService _instance =
      LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  // ── Change Notification System ──────────────────────────────────────────
  // Rich change-set stream (4.1): the SINGLE broadcast stream, fired after
  // every write/delete. Carries the affected row [ids] so a consumer patches
  // just those rows instead of re-scanning the whole table; an empty [ids] set
  // means "bulk/unspecified" and consumers fall back to a full reload. Written
  // once here in the shared DB layer — common to Task, Sales and CRM. (The
  // legacy table-name-only `Stream<String>` was retired once every consumer
  // had been ported to this typed stream.)
  final _tableChanges2Controller = StreamController<TableChange>.broadcast();
  Stream<TableChange> get tableChanges2 => _tableChanges2Controller.stream;

  /// Broadcast a write/delete. [ids] are the affected row ids (empty =
  /// unspecified/bulk -> consumers fall back to a full reload, matching legacy
  /// behaviour); [kind] distinguishes upsert from delete. Every write site calls
  /// this, so the change-set contract is defined in one common place.
  void _notify(
    String table, {
    Set<String> ids = const <String>{},
    ChangeKind kind = ChangeKind.upsert,
  }) {
    // Bump this table's change-revision so any shared snapshot taken before the
    // write is treated as stale on the next read (see [_readSnapshot]).
    _tableRevisions[table] = (_tableRevisions[table] ?? 0) + 1;
    _tableChanges2Controller.add(
      TableChange(table: table, ids: ids, kind: kind),
    );
  }

  // ── Shared table-snapshot cache ─────────────────────────────────────────
  // Several always-mounted tabs (Task Actions, Assignee, Sales/CRM Actions)
  // each run the SAME heavy full-table scan on every reload. Rather than let
  // each widget re-scan SQLite, the first reader memoizes the deserialized rows
  // against the owning table's change-revision; every later reader with an
  // unchanged revision gets a shallow copy straight from memory. Any write goes
  // through [_notify], which bumps the revision and self-invalidates the entry.
  final Map<String, int> _tableRevisions = <String, int>{};
  final Map<String, _TableSnapshot<dynamic>> _snapshotCache =
      <String, _TableSnapshot<dynamic>>{};

  /// Monotonic per-table change counter, bumped on every [_notify]. A snapshot
  /// is only valid while this still matches the revision it was taken at.
  int revisionOf(String table) => _tableRevisions[table] ?? 0;

  /// Return a fresh copy of the cached snapshot for [key] if it was taken at
  /// the current revision of [table]; otherwise drop the stale entry and return
  /// null so the caller re-scans. The copy keeps callers from mutating (e.g.
  /// sorting in place) the shared snapshot.
  List<T>? _readSnapshot<T>(String key, String table) {
    final snap = _snapshotCache[key];
    if (snap == null) return null;
    if (snap.revision != revisionOf(table)) {
      _snapshotCache.remove(key);
      return null;
    }
    return List<T>.of(snap.rows as List<T>);
  }

  /// Store [rows] for [key] against [revision] — captured BEFORE the query ran,
  /// so a write that lands mid-query leaves the entry stale (next reader
  /// re-scans) instead of caching pre-write rows as fresh.
  void _writeSnapshot<T>(String key, int revision, List<T> rows) {
    _snapshotCache[key] = _TableSnapshot<T>(revision, rows);
  }

  /// Idle prewarm: fill the shared snapshot cache for [userId]'s heavy list
  /// scans (tasks + both module enquiry tables) so the first tab open hits warm
  /// memory instead of a cold full-table scan. Cheap when already valid — each
  /// reader short-circuits on a revision match.
  Future<void> prewarmListSnapshots(String userId) async {
    if (userId.trim().isEmpty) return;
    try {
      await getTasks(userId);
      await getModuleEnquiries(userId, tableName: 'enquiries');
      await getModuleEnquiries(userId, tableName: 'crm_enquiries');
    } catch (e) {
      print('[LocalDB] prewarmListSnapshots skipped: $e');
    }
  }

  /// Debounced variant of [tableChanges2] filtered to a single [table]: a
  /// burst of writes (e.g. the startup action backfill inserting many rows)
  /// collapses into ONE downstream event after [window] of quiet, so watchers
  /// reload once instead of once-per-row.
  ///
  /// A pure trailing debounce starves watchers if writes never pause for
  /// [window] (a heavy sync burst keeps resetting the timer). [maxWait] caps
  /// that: once a burst has been pending for [maxWait], flush immediately
  /// rather than waiting for quiet that may never come. Emits the table name
  /// as a `Stream<String>` tick, so consumers just reload on each event.
  ///
  /// [matches] optionally narrows which change events participate in the
  /// debounce — e.g. a per-conversation watcher passes
  /// `(c) => c.ids.isEmpty || c.ids.contains(id)` so writes to OTHER rows
  /// neither trigger a reload nor keep a burst alive. Default null = every
  /// event for [table] participates, matching the original behaviour.
  Stream<String> tableChangesDebounced(
    String table, {
    Duration window = const Duration(milliseconds: 300),
    Duration maxWait = const Duration(seconds: 2),
    bool Function(TableChange change)? matches,
  }) {
    late final StreamController<String> controller;
    Timer? timer;
    StreamSubscription<TableChange>? sub;
    // Start of the current un-flushed burst (null = nothing pending). Drives
    // the [maxWait] guarantee below.
    DateTime? firstPendingAt;

    // Emit the pending burst once and reset the trailing/maxWait state.
    void flush() {
      timer?.cancel();
      timer = null;
      if (firstPendingAt == null) return;
      firstPendingAt = null;
      if (!controller.isClosed) controller.add(table);
    }

    controller = StreamController<String>.broadcast(
      onListen: () {
        sub = tableChanges2
            .where((c) => c.table == table && (matches?.call(c) ?? true))
            .listen((_) {
              final now = DateTime.now();
              // Mark the burst start on its first event only.
              firstPendingAt ??= now;
              // Trailing debounce: restart the quiet-window timer on each event.
              timer?.cancel();
              timer = Timer(window, flush);
              // maxWait guarantee: if this burst has been pending >= maxWait, flush
              // now instead of waiting for quiet that may never arrive.
              if (now.difference(firstPendingAt!) >= maxWait) flush();
            });
      },
      onCancel: () {
        timer?.cancel();
        sub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final tOpen = StartupTrace.instance.begin(
      'db.open',
      kind: StartupTraceKind.db,
      caller: '_initDatabase',
    );
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = join(documentsDir.path, _dbName);

    final db = await openDatabase(
      dbPath,
      version: _dbVersion,
      // NOTE: WAL + synchronous=NORMAL was tried here via onConfigure as a
      // saveMessages fsync optimization, but a global blank screen (Task and
      // Sales both empty) appeared with it enabled, which points at the
      // journal_mode change destabilising DB open on-device. The DB open path
      // is the one thing every screen depends on, so it is back to the known-
      // good default (DELETE journal). The real saveMessages win - collapsing
      // the 1+A per-message commits into ONE batch.commit - is retained and
      // does not need WAL. Revisit WAL only behind device verification.
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    StartupTrace.instance.end(tOpen);
    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    // Messages table
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        taskId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        text TEXT,
        type TEXT DEFAULT 'text',
        fileUrl TEXT,
        fileName TEXT,
        duration INTEGER,
        createdAt INTEGER NOT NULL,
        searchableContent TEXT,
        deliveryMethod TEXT,
        isEdited INTEGER DEFAULT 0,
        deleted INTEGER DEFAULT 0,
        deletedFor TEXT DEFAULT '[]',
        downloadedBy TEXT,
        deliveredAt INTEGER,
        deliveredTo TEXT,
        readBy TEXT,
        systemType TEXT DEFAULT 'regular',
        sequenceNumber INTEGER,
        queryReply TEXT,
        repliedBy TEXT,
        repliedAt INTEGER,
        isReplied INTEGER DEFAULT 0,
        isFollowUpDone INTEGER DEFAULT 0,
        followUpDoneBy TEXT,
        followUpDoneAt INTEGER,
        uploadError TEXT,
        replyToMessageId TEXT,
        replyToMessageText TEXT,
        replyToMessageSender TEXT,
        changeKey TEXT
      )
    ''');

    // Index for fast task-based queries
    await db.execute('''
      CREATE INDEX idx_messages_taskId ON messages(taskId)
    ''');
    await db.execute('''
      CREATE INDEX idx_messages_createdAt ON messages(createdAt)
    ''');
    // Conversation-scoped index: serves the chat-open high-water-mark lookup
    // (SELECT MAX(createdAt) WHERE taskId=?) and the paged reads (getMessages/
    // getMessagesBefore filter taskId then order by createdAt) without a scan.
    await db.execute('''
      CREATE INDEX idx_messages_taskId_createdAt ON messages(taskId, createdAt)
    ''');
    // Serves the background upload-retry poll (fileUrl IN ('pending','failed'))
    // and the stale-pending sweep — both used to full-scan messages every run.
    await db.execute('''
      CREATE INDEX idx_messages_fileUrl_createdAt ON messages(fileUrl, createdAt)
    ''');

    // Enquiries table
    await db.execute('''
      CREATE TABLE enquiries (
        id TEXT PRIMARY KEY,
        title TEXT,
        clientName TEXT,
        clientPhone TEXT,
        clientEmail TEXT,
        clientAddress TEXT,
        clientCompany TEXT,
        description TEXT,
        createdBy TEXT,
        createdByName TEXT,
        createdByPhone TEXT,
        assignedTo TEXT,
        assignedToUid TEXT,
        assignedToPhone TEXT,
        participants TEXT DEFAULT '[]',
        status TEXT DEFAULT 'active',
        milestones TEXT DEFAULT '[]',
        priority INTEGER DEFAULT 2,
        isUrgent INTEGER DEFAULT 0,
        deadline INTEGER,
        progress REAL DEFAULT 0.0,
        tags TEXT DEFAULT '[]',
        category TEXT,
        extraFields TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        isClosed INTEGER DEFAULT 0,
        rating INTEGER,
        lastMessageText TEXT,
        lastMessageTime INTEGER,
        unreadCounts TEXT DEFAULT '{}',
        teamId TEXT,
        displayId INTEGER,
        isArchived INTEGER DEFAULT 0,
        archivedAt INTEGER,
        archivedBy TEXT,
        isDeleted INTEGER DEFAULT 0,
        deletedAt INTEGER,
        deletedBy TEXT,
        recurrence TEXT,
        seriesId TEXT,
        nextDue INTEGER
      )
    ''');

    // Index for fast user-based queries
    await db.execute('''
      CREATE INDEX idx_enquiries_createdBy ON enquiries(createdBy)
    ''');
    await db.execute('''
      CREATE INDEX idx_enquiries_assignedToUid ON enquiries(assignedToUid)
    ''');
    await db.execute('''
      CREATE INDEX idx_enquiries_teamId ON enquiries(teamId)
    ''');
    await db.execute('''
      CREATE INDEX idx_enquiries_updatedAt ON enquiries(updatedAt)
    ''');

    // Composite indexes for fast plan-limit active-enquiry counts.
    await db.execute('''
      CREATE INDEX idx_enquiries_createdBy_active ON enquiries(createdBy, isClosed, status)
    ''');
    await db.execute('''
      CREATE INDEX idx_enquiries_assignedToUid_active ON enquiries(assignedToUid, isClosed, status)
    ''');

    // Recurrence (Phase-2A): partial indexes keep the due-anchor and
    // occurrence-dedup lookups cheap while costing ~nothing to maintain
    // (nextDue/seriesId are NULL on ordinary rows).
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_enquiries_nextDue ON enquiries(nextDue) WHERE nextDue IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_enquiries_seriesId ON enquiries(seriesId) WHERE seriesId IS NOT NULL',
    );

    // Tasks table
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT,
        description TEXT,
        createdBy TEXT NOT NULL,
        createdByName TEXT,
        createdByPhone TEXT,
        assignedTo TEXT,
        assignedToUid TEXT,
        assignedToPhone TEXT,
        participants TEXT DEFAULT '[]',
        participantHistory TEXT DEFAULT '[]',
        isGroupTask INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 2,
        isUrgent INTEGER DEFAULT 0,
        deadline INTEGER,
        progress REAL DEFAULT 0.0,
        tags TEXT DEFAULT '[]',
        extraFields TEXT,
        createdAt INTEGER NOT NULL,
        startDate INTEGER,
        updatedAt INTEGER NOT NULL,
        isClosed INTEGER DEFAULT 0,
        isCancelled INTEGER DEFAULT 0,
        rating INTEGER,
        template TEXT,
        category TEXT,
        reminderCount INTEGER DEFAULT 0,
        warningCount INTEGER DEFAULT 0,
        statusRequestCount INTEGER DEFAULT 0,
        lastMessageText TEXT,
        lastMessageTime INTEGER,
        milestones TEXT DEFAULT '[]',
        unreadCounts TEXT DEFAULT '{}',
        displayId INTEGER,
        isDeleted INTEGER DEFAULT 0,
        deletedAt INTEGER,
        deletedBy TEXT,
        teamId TEXT,
        isArchived INTEGER DEFAULT 0,
        archivedAt INTEGER,
        archivedBy TEXT,
        clientName TEXT,
        clientPhone TEXT,
        clientEmail TEXT,
        clientAddress TEXT,
        clientCompany TEXT,
        recurrence TEXT,
        seriesId TEXT,
        nextDue INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_tasks_createdBy ON tasks(createdBy)');
    await db.execute(
      'CREATE INDEX idx_tasks_assignedToUid ON tasks(assignedToUid)',
    );
    await db.execute('CREATE INDEX idx_tasks_updatedAt ON tasks(updatedAt)');
    // Recurrence (Phase-2A) partial indexes — see the enquiries block.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tasks_nextDue ON tasks(nextDue) WHERE nextDue IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tasks_seriesId ON tasks(seriesId) WHERE seriesId IS NOT NULL',
    );

    // Composite indexes for fast plan-limit active-task counts.
    // These are index-only for COUNT(*) because every filtered column is
    // included in the index key.
    await db.execute(
      'CREATE INDEX idx_tasks_createdBy_active ON tasks(createdBy, isDeleted, isCancelled, isClosed)',
    );
    await db.execute(
      'CREATE INDEX idx_tasks_assignedToUid_active ON tasks(assignedToUid, isDeleted, isCancelled, isClosed)',
    );

    // Sales teams table
    await db.execute('''
      CREATE TABLE sales_teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdBy TEXT NOT NULL,
        members TEXT DEFAULT '[]',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sales_teams_createdBy ON sales_teams(createdBy)',
    );

    // Task teams table (personal teams for the Task module)
    await db.execute('''
      CREATE TABLE task_teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdBy TEXT NOT NULL,
        members TEXT DEFAULT '[]',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_task_teams_createdBy ON task_teams(createdBy)',
    );

    // Task drafts table
    await db.execute('''
      CREATE TABLE task_drafts (
        id TEXT PRIMARY KEY,
        createdBy TEXT NOT NULL,
        assignedTo TEXT,
        assigneeUid TEXT,
        assigneePhone TEXT,
        assigneeIsOnApp INTEGER DEFAULT 1,
        title TEXT,
        description TEXT,
        startDate INTEGER,
        deadline INTEGER,
        priority INTEGER DEFAULT 2,
        isUrgent INTEGER DEFAULT 0,
        progress INTEGER DEFAULT 0,
        activateNow INTEGER DEFAULT 1,
        currentStep TEXT DEFAULT 'enteringTitle',
        conversation TEXT DEFAULT '[]',
        createdAt INTEGER,
        updatedAt INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_task_drafts_createdBy ON task_drafts(createdBy)',
    );

    // Milestones table
    await db.execute('''
      CREATE TABLE milestones (
        id TEXT PRIMARY KEY,
        taskId TEXT NOT NULL,
        title TEXT NOT NULL,
        isCompleted INTEGER DEFAULT 0,
        completedAt INTEGER,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_milestones_taskId ON milestones(taskId)',
    );

    // System logs table
    await db.execute('''
      CREATE TABLE system_logs (
        id TEXT PRIMARY KEY,
        taskId TEXT NOT NULL,
        action TEXT NOT NULL,
        performedBy TEXT NOT NULL,
        details TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_system_logs_taskId ON system_logs(taskId)',
    );

    // Actions table (write-through index for fast action queries)
    await db.execute('''
      CREATE TABLE actions (
        id TEXT PRIMARY KEY,
        parentId TEXT NOT NULL,
        parentType TEXT NOT NULL,
        actionType TEXT NOT NULL,
        text TEXT NOT NULL,
        senderId TEXT,
        createdAt INTEGER NOT NULL,
        scheduledDate INTEGER,
        isReplied INTEGER DEFAULT 0,
        isDone INTEGER DEFAULT 0,
        clientName TEXT,
        parentTitle TEXT,
        teamId TEXT,
        seqNo INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_actions_parent ON actions(parentId)');
    await db.execute('CREATE INDEX idx_actions_type ON actions(actionType)');
    await db.execute(
      'CREATE INDEX idx_actions_scheduledDate ON actions(scheduledDate)',
    );
    // Composite index for the Actions/Assignee tab queries which filter by
    // parentType and sort by createdAt DESC — avoids full-table scan + sort.
    await db.execute(
      'CREATE INDEX idx_actions_parentType_createdAt ON actions(parentType, createdAt DESC)',
    );
    // Card icon strips: `WHERE parentId = ? ORDER BY createdAt DESC LIMIT n`
    // becomes a pure index range scan with early termination (no temp sort).
    await db.execute(
      'CREATE INDEX idx_actions_parent_createdAt ON actions(parentId, createdAt DESC)',
    );

    // Sales actions table (dedicated, team-scoped — separate from task actions)
    await db.execute('''
      CREATE TABLE sales_actions (
        id TEXT PRIMARY KEY,
        parentId TEXT NOT NULL,
        teamId TEXT,
        actionType TEXT NOT NULL,
        text TEXT NOT NULL,
        senderId TEXT,
        createdAt INTEGER NOT NULL,
        scheduledDate INTEGER,
        isReplied INTEGER DEFAULT 0,
        isDone INTEGER DEFAULT 0,
        clientName TEXT,
        parentTitle TEXT,
        seqNo INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sales_actions_parentId ON sales_actions(parentId)',
    );
    await db.execute(
      'CREATE INDEX idx_sales_actions_teamId ON sales_actions(teamId)',
    );
    await db.execute(
      'CREATE INDEX idx_sales_actions_actionType ON sales_actions(actionType)',
    );
    await db.execute(
      'CREATE INDEX idx_sales_actions_scheduledDate ON sales_actions(scheduledDate)',
    );
    await db.execute(
      'CREATE INDEX idx_sales_actions_parent_createdAt ON sales_actions(parentId, createdAt DESC)',
    );

    // Users cache table (phone → UID lookup cache + plan type + avatar)
    await db.execute('''
      CREATE TABLE users (
        uid TEXT PRIMARY KEY,
        phone TEXT UNIQUE NOT NULL,
        name TEXT,
        planType TEXT,
        avatarUrl TEXT,
        cachedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_users_phone ON users(phone)');

    // Phonebook-nickname → avatar url index. A task often stores the local
    // contact name ("Sonu") rather than the person's profile name, so cards
    // resolve the leader's photo through this cross-reference. Persisted so
    // the resolution is available instantly at cold start instead of waiting
    // on the contacts + Firestore reload that rebuilds it.
    await db.execute('''
      CREATE TABLE avatar_nicknames (
        name TEXT PRIMARY KEY,
        avatarUrl TEXT NOT NULL,
        cachedAt INTEGER NOT NULL
      )
    ''');

    // Current user's plan bundle (local-first paywall gate) — a single row
    // keyed by the signed-in uid holding the per-module subscriptions that
    // otherwise only live in the Firestore users/{uid} doc. Persisted so plan
    // gating resolves from SQLite on cold start (even offline) instead of
    // waiting on a network read. Kept separate from the `users` table because
    // that one is a mass-written phone→UID counterparty cache whose batches
    // would clobber a self-plan row.
    await db.execute('''
      CREATE TABLE user_plan (
        uid TEXT PRIMARY KEY,
        planType TEXT,
        planExpiry INTEGER,
        modulePlans TEXT,
        cachedAt INTEGER NOT NULL
      )
    ''');

    // Categories table (user-defined, managed in Settings)
    await db.execute('''
      CREATE TABLE categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        module TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');

    // CRM enquiries table (same schema as enquiries)
    await db.execute('''
      CREATE TABLE crm_enquiries (
        id TEXT PRIMARY KEY,
        title TEXT,
        clientName TEXT,
        clientPhone TEXT,
        clientEmail TEXT,
        clientAddress TEXT,
        clientCompany TEXT,
        description TEXT,
        createdBy TEXT,
        createdByName TEXT,
        createdByPhone TEXT,
        assignedTo TEXT,
        assignedToUid TEXT,
        assignedToPhone TEXT,
        participants TEXT DEFAULT '[]',
        status TEXT DEFAULT 'open',
        milestones TEXT DEFAULT '[]',
        priority INTEGER DEFAULT 2,
        isUrgent INTEGER DEFAULT 0,
        deadline INTEGER,
        progress REAL DEFAULT 0.0,
        tags TEXT DEFAULT '[]',
        category TEXT,
        extraFields TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        isClosed INTEGER DEFAULT 0,
        rating INTEGER,
        lastMessageText TEXT,
        lastMessageTime INTEGER,
        unreadCounts TEXT DEFAULT '{}',
        teamId TEXT,
        displayId INTEGER,
        isArchived INTEGER DEFAULT 0,
        archivedAt INTEGER,
        archivedBy TEXT,
        isDeleted INTEGER DEFAULT 0,
        deletedAt INTEGER,
        deletedBy TEXT,
        recurrence TEXT,
        seriesId TEXT,
        nextDue INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_createdBy ON crm_enquiries(createdBy)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_assignedToUid ON crm_enquiries(assignedToUid)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_teamId ON crm_enquiries(teamId)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_updatedAt ON crm_enquiries(updatedAt)',
    );

    // Composite indexes for fast plan-limit active-CRM counts.
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_createdBy_active ON crm_enquiries(createdBy, isClosed, status)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_enquiries_assignedToUid_active ON crm_enquiries(assignedToUid, isClosed, status)',
    );
    // Recurrence (Phase-2A) partial indexes — see the enquiries block.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_nextDue ON crm_enquiries(nextDue) WHERE nextDue IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_seriesId ON crm_enquiries(seriesId) WHERE seriesId IS NOT NULL',
    );

    // CRM teams table
    await db.execute('''
      CREATE TABLE crm_teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdBy TEXT NOT NULL,
        members TEXT DEFAULT '[]',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_crm_teams_createdBy ON crm_teams(createdBy)',
    );

    // CRM actions table
    await db.execute('''
      CREATE TABLE crm_actions (
        id TEXT PRIMARY KEY,
        parentId TEXT NOT NULL,
        teamId TEXT,
        actionType TEXT NOT NULL,
        text TEXT NOT NULL,
        senderId TEXT,
        createdAt INTEGER NOT NULL,
        scheduledDate INTEGER,
        isReplied INTEGER DEFAULT 0,
        isDone INTEGER DEFAULT 0,
        clientName TEXT,
        parentTitle TEXT,
        seqNo INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_crm_actions_parentId ON crm_actions(parentId)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_actions_teamId ON crm_actions(teamId)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_actions_actionType ON crm_actions(actionType)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_actions_scheduledDate ON crm_actions(scheduledDate)',
    );
    await db.execute(
      'CREATE INDEX idx_crm_actions_parent_createdAt ON crm_actions(parentId, createdAt DESC)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add milestones table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS milestones (
          id TEXT PRIMARY KEY,
          taskId TEXT NOT NULL,
          title TEXT NOT NULL,
          isCompleted INTEGER DEFAULT 0,
          completedAt INTEGER,
          createdAt INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_milestones_taskId ON milestones(taskId)',
      );

      // Add system_logs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS system_logs (
          id TEXT PRIMARY KEY,
          taskId TEXT NOT NULL,
          action TEXT NOT NULL,
          performedBy TEXT NOT NULL,
          details TEXT,
          createdAt INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_system_logs_taskId ON system_logs(taskId)',
      );
    }
    if (oldVersion < 3) {
      // Add actions table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS actions (
          id TEXT PRIMARY KEY,
          parentId TEXT NOT NULL,
          parentType TEXT NOT NULL,
          actionType TEXT NOT NULL,
          text TEXT NOT NULL,
          senderId TEXT,
          createdAt INTEGER NOT NULL,
          scheduledDate INTEGER,
          isReplied INTEGER DEFAULT 0,
          isDone INTEGER DEFAULT 0,
          clientName TEXT,
          parentTitle TEXT
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_actions_parent ON actions(parentId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_actions_type ON actions(actionType)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_actions_scheduledDate ON actions(scheduledDate)',
      );
    }
    if (oldVersion < 4) {
      // Add reply-to-message columns to messages table
      await db.execute("ALTER TABLE messages ADD COLUMN replyToMessageId TEXT");
      await db.execute(
        "ALTER TABLE messages ADD COLUMN replyToMessageText TEXT",
      );
      await db.execute(
        "ALTER TABLE messages ADD COLUMN replyToMessageSender TEXT",
      );
    }
    if (oldVersion < 5) {
      // Add soft-delete columns to tasks table
      await db.execute(
        "ALTER TABLE tasks ADD COLUMN isDeleted INTEGER DEFAULT 0",
      );
      await db.execute("ALTER TABLE tasks ADD COLUMN deletedAt INTEGER");
      await db.execute("ALTER TABLE tasks ADD COLUMN deletedBy TEXT");
    }
    if (oldVersion < 6) {
      // Add per-user delivery tracking to messages table
      await db.execute("ALTER TABLE messages ADD COLUMN deliveredTo TEXT");
    }
    if (oldVersion < 7) {
      // Add upload error tracking to messages table
      await db.execute("ALTER TABLE messages ADD COLUMN uploadError TEXT");
    }
    if (oldVersion < 8) {
      // Add readBy column (was missing from migrations) and reply columns (were only in v4 migration, not in CREATE TABLE)
      // Use try/catch since columns may already exist from partial migrations
      for (final col in [
        'readBy',
        'replyToMessageId',
        'replyToMessageText',
        'replyToMessageSender',
      ]) {
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN $col TEXT');
        } catch (_) {
          // Column already exists — safe to ignore
        }
      }
    }
    if (oldVersion < 9) {
      // Add dedicated sales_actions table (team-scoped, separate from task actions)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sales_actions (
          id TEXT PRIMARY KEY,
          parentId TEXT NOT NULL,
          teamId TEXT,
          actionType TEXT NOT NULL,
          text TEXT NOT NULL,
          senderId TEXT,
          createdAt INTEGER NOT NULL,
          scheduledDate INTEGER,
          isReplied INTEGER DEFAULT 0,
          isDone INTEGER DEFAULT 0,
          clientName TEXT,
          parentTitle TEXT
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_actions_parentId ON sales_actions(parentId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_actions_teamId ON sales_actions(teamId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_actions_actionType ON sales_actions(actionType)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_actions_scheduledDate ON sales_actions(scheduledDate)',
      );
      // Backfill: migrate existing enquiry actions from shared actions table
      await _backfillSalesActionsFromShared(db);
    }
    if (oldVersion < 10) {
      // Add users cache table (phone → UID lookup cache)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS users (
          uid TEXT PRIMARY KEY,
          phone TEXT UNIQUE NOT NULL,
          name TEXT,
          cachedAt INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone)',
      );
    }
    if (oldVersion < 11) {
      // Ensure enquiries table exists (may be missing if app was installed before enquiries were added)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS enquiries (
          id TEXT PRIMARY KEY,
          title TEXT,
          clientName TEXT,
          description TEXT,
          createdBy TEXT,
          createdByName TEXT,
          createdByPhone TEXT,
          assignedTo TEXT,
          assignedToUid TEXT,
          assignedToPhone TEXT,
          status TEXT DEFAULT 'active',
          milestones TEXT DEFAULT '[]',
          priority INTEGER DEFAULT 2,
          isUrgent INTEGER DEFAULT 0,
          deadline INTEGER,
          progress REAL DEFAULT 0.0,
          tags TEXT DEFAULT '[]',
          extraFields TEXT,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL,
          isClosed INTEGER DEFAULT 0,
          lastMessageText TEXT,
          lastMessageTime INTEGER,
          unreadCounts TEXT DEFAULT '{}',
          teamId TEXT,
          displayId INTEGER
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_enquiries_createdBy ON enquiries(createdBy)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_enquiries_assignedToUid ON enquiries(assignedToUid)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_enquiries_teamId ON enquiries(teamId)',
      );
    }

    if (oldVersion < 12) {
      // Categories table for user-defined categories
      await db.execute('''
        CREATE TABLE IF NOT EXISTS categories (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          module TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )
      ''');
    }

    if (oldVersion < 13) {
      // CRM enquiries table (same schema as enquiries)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS crm_enquiries (
          id TEXT PRIMARY KEY,
          title TEXT,
          clientName TEXT,
          description TEXT,
          createdBy TEXT,
          createdByName TEXT,
          createdByPhone TEXT,
          assignedTo TEXT,
          assignedToUid TEXT,
          assignedToPhone TEXT,
          status TEXT DEFAULT 'open',
          milestones TEXT DEFAULT '[]',
          priority INTEGER DEFAULT 2,
          isUrgent INTEGER DEFAULT 0,
          deadline INTEGER,
          progress REAL DEFAULT 0.0,
          tags TEXT DEFAULT '[]',
          extraFields TEXT,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL,
          isClosed INTEGER DEFAULT 0,
          lastMessageText TEXT,
          lastMessageTime INTEGER,
          unreadCounts TEXT DEFAULT '{}',
          teamId TEXT,
          displayId INTEGER
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_createdBy ON crm_enquiries(createdBy)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_assignedToUid ON crm_enquiries(assignedToUid)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_teamId ON crm_enquiries(teamId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_updatedAt ON crm_enquiries(updatedAt)',
      );

      // CRM teams table (same schema as sales_teams)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS crm_teams (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          createdBy TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_teams_createdBy ON crm_teams(createdBy)',
      );

      // CRM actions table (same schema as sales_actions)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS crm_actions (
          id TEXT PRIMARY KEY,
          parentId TEXT NOT NULL,
          teamId TEXT,
          actionType TEXT NOT NULL,
          text TEXT NOT NULL,
          senderId TEXT,
          createdAt INTEGER NOT NULL,
          scheduledDate INTEGER,
          isReplied INTEGER DEFAULT 0,
          isDone INTEGER DEFAULT 0,
          clientName TEXT,
          parentTitle TEXT
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_actions_parentId ON crm_actions(parentId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_actions_teamId ON crm_actions(teamId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_actions_actionType ON crm_actions(actionType)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_actions_scheduledDate ON crm_actions(scheduledDate)',
      );
    }

    if (oldVersion < 14) {
      // Premium/Basic differentiation: cache each user's plan type locally
      await db.execute('ALTER TABLE users ADD COLUMN planType TEXT');
    }

    if (oldVersion < 15) {
      // Profile photos / preset avatars on cards and pickers: cache each
      // user's avatarUrl locally so avatars render offline
      await db.execute('ALTER TABLE users ADD COLUMN avatarUrl TEXT');
    }

    if (oldVersion < 16) {
      // Scalability: composite index so the Actions/Assignee tab queries
      // (filter parentType + sort createdAt DESC) use an index instead of a
      // full-table scan + in-memory sort.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_actions_parentType_createdAt ON actions(parentType, createdAt DESC)',
      );
    }

    if (oldVersion < 17) {
      // Plan-limit active counts: composite indexes so SQLite can answer
      // COUNT(*) with an index-only scan instead of reading row data.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tasks_createdBy_active ON tasks(createdBy, isDeleted, isCancelled, isClosed)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tasks_assignedToUid_active ON tasks(assignedToUid, isDeleted, isCancelled, isClosed)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_enquiries_createdBy_active ON enquiries(createdBy, isClosed, status)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_enquiries_assignedToUid_active ON enquiries(assignedToUid, isClosed, status)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_createdBy_active ON crm_enquiries(createdBy, isClosed, status)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crm_enquiries_assignedToUid_active ON crm_enquiries(assignedToUid, isClosed, status)',
      );
    }

    if (oldVersion < 18) {
      // Multi-team for the Task module + explicit team member lists everywhere.
      // Task teams table (personal teams, same schema as sales/crm teams).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS task_teams (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          createdBy TEXT NOT NULL,
          members TEXT DEFAULT '[]',
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_task_teams_createdBy ON task_teams(createdBy)',
      );

      // Members column on existing team tables (may already exist from a
      // partial migration — guard each ALTER in try/catch).
      for (final teamTable in ['sales_teams', 'crm_teams']) {
        try {
          await db.execute(
            "ALTER TABLE $teamTable ADD COLUMN members TEXT DEFAULT '[]'",
          );
        } catch (_) {
          // Column already exists — safe to ignore.
        }
      }

      // teamId on tasks and actions (creator's team). Guarded: partial
      // migrations may have added one of them already.
      for (final col in [
        ['tasks', 'teamId'],
        ['actions', 'teamId'],
      ]) {
        try {
          await db.execute('ALTER TABLE ${col[0]} ADD COLUMN ${col[1]} TEXT');
        } catch (_) {
          // Column already exists — safe to ignore.
        }
      }

      // Index to keep team-scoped task queries fast.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tasks_teamId ON tasks(teamId)',
      );
    }

    // v19: archive support on tasks and module enquiry tables.
    if (oldVersion < 19) {
      for (final col in [
        ['tasks', 'isArchived'],
        ['tasks', 'archivedAt'],
        ['tasks', 'archivedBy'],
        ['enquiries', 'isArchived'],
        ['enquiries', 'archivedAt'],
        ['enquiries', 'archivedBy'],
        ['crm_enquiries', 'isArchived'],
        ['crm_enquiries', 'archivedAt'],
        ['crm_enquiries', 'archivedBy'],
      ]) {
        try {
          final type = col[1] == 'isArchived'
              ? 'INTEGER DEFAULT 0'
              : (col[1] == 'archivedAt' ? 'INTEGER' : 'TEXT');
          await db.execute('ALTER TABLE ${col[0]} ADD COLUMN ${col[1]} $type');
        } catch (_) {
          // Column already exists — safe to ignore.
        }
      }
    }

    // v20: category column on task and enquiry cards (user-defined category
    // was previously dropped by SQLite because the column never existed).
    if (oldVersion < 20) {
      for (final table in ['tasks', 'enquiries', 'crm_enquiries']) {
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN category TEXT');
        } catch (_) {
          // Column already exists — safe to ignore.
        }
      }
    }

    // v21: soft-delete support on module enquiry tables (parity with tasks:
    // deleted cards move to the Deleted view and can be restored or purged).
    if (oldVersion < 21) {
      for (final col in [
        ['enquiries', 'isDeleted'],
        ['enquiries', 'deletedAt'],
        ['enquiries', 'deletedBy'],
        ['crm_enquiries', 'isDeleted'],
        ['crm_enquiries', 'deletedAt'],
        ['crm_enquiries', 'deletedBy'],
      ]) {
        try {
          final type = col[1] == 'isDeleted'
              ? 'INTEGER DEFAULT 0'
              : (col[1] == 'deletedAt' ? 'INTEGER' : 'TEXT');
          await db.execute('ALTER TABLE ${col[0]} ADD COLUMN ${col[1]} $type');
        } catch (_) {
          // Column already exists — safe to ignore.
        }
      }
    }

    // v22: performance indexes. Card icon strips re-query on every task/action
    // write, and the upload-retry service polls pending uploads every 30s —
    // both were full scans with a temp sort until these existed.
    if (oldVersion < 22) {
      for (final statement in [
        'CREATE INDEX IF NOT EXISTS idx_messages_fileUrl_createdAt ON messages(fileUrl, createdAt)',
        'CREATE INDEX IF NOT EXISTS idx_actions_parent_createdAt ON actions(parentId, createdAt DESC)',
        'CREATE INDEX IF NOT EXISTS idx_sales_actions_parent_createdAt ON sales_actions(parentId, createdAt DESC)',
        'CREATE INDEX IF NOT EXISTS idx_crm_actions_parent_createdAt ON crm_actions(parentId, createdAt DESC)',
      ]) {
        try {
          await db.execute(statement);
        } catch (_) {
          // Index already present — safe to ignore.
        }
      }
    }

    // v23: participants parity for Sales/CRM. Enquiries never persisted a local
    // `participants` column, so a uid present only as an assignee (or a
    // multi-assignee) wasn't discoverable by the cross-device sync query
    // `where('participants', arrayContains: uid)` — the row could fail to reach
    // that device. Add the column and backfill the invariant on all three tables
    // so Task, Sales and CRM share one guarantee. Idempotent: ADD COLUMN is
    // guarded, and the backfill only rewrites rows whose union actually differs.
    if (oldVersion < 23) {
      for (final statement in [
        "ALTER TABLE enquiries ADD COLUMN participants TEXT DEFAULT '[]'",
        "ALTER TABLE crm_enquiries ADD COLUMN participants TEXT DEFAULT '[]'",
      ]) {
        try {
          await db.execute(statement);
        } catch (_) {
          // Column already present — safe to ignore.
        }
      }
      for (final table in ['tasks', 'enquiries', 'crm_enquiries']) {
        await _backfillParticipantsInvariant(db, table);
      }
    }

    // v24: customer/contact details for every module. Adds the shared
    // CustomerInfo columns (name/phone/email/address/company) so customer data
    // survives local-first reloads. For enquiries/crm_enquiries this also fixes
    // a latent gap — clientPhone/clientEmail existed on the model but were
    // never persisted locally. Idempotent: each ADD COLUMN is guarded.
    if (oldVersion < 24) {
      for (final statement in [
        "ALTER TABLE tasks ADD COLUMN clientName TEXT",
        "ALTER TABLE tasks ADD COLUMN clientPhone TEXT",
        "ALTER TABLE tasks ADD COLUMN clientEmail TEXT",
        "ALTER TABLE tasks ADD COLUMN clientAddress TEXT",
        "ALTER TABLE tasks ADD COLUMN clientCompany TEXT",
        "ALTER TABLE enquiries ADD COLUMN clientPhone TEXT",
        "ALTER TABLE enquiries ADD COLUMN clientEmail TEXT",
        "ALTER TABLE enquiries ADD COLUMN clientAddress TEXT",
        "ALTER TABLE enquiries ADD COLUMN clientCompany TEXT",
        "ALTER TABLE crm_enquiries ADD COLUMN clientPhone TEXT",
        "ALTER TABLE crm_enquiries ADD COLUMN clientEmail TEXT",
        "ALTER TABLE crm_enquiries ADD COLUMN clientAddress TEXT",
        "ALTER TABLE crm_enquiries ADD COLUMN clientCompany TEXT",
      ]) {
        try {
          await db.execute(statement);
        } catch (_) {
          // Column already present — safe to ignore.
        }
      }
    }

    // v25: content fingerprint for the messages write-skip diff. The diff used
    // to compare `sequenceNumber`, which is NULL for every non-system message,
    // so an EXISTING row was indistinguishable from a MISSING one and
    // saveMessages rewrote the whole conversation on every sync emission. Rows
    // written before v25 keep a NULL changeKey, which fails the comparison once
    // and self-heals on that first rewrite.
    if (oldVersion < 25) {
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN changeKey TEXT');
      } catch (_) {
        // Column already present — safe to ignore.
      }
    }

    // v26: closure/satisfaction rating on module enquiry cards (parity with
    // tasks, which had the column from v1). EnquiryModel carried `rating`
    // and synced it to Firestore, but SQLite silently dropped it — so the
    // stars shown on sales cards never survived a local reload.
    if (oldVersion < 26) {
      for (final table in ['enquiries', 'crm_enquiries']) {
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN rating INTEGER');
        } catch (_) {
          // Column already present — safe to ignore.
        }
      }
    }

    // v27: recurrence primitives (Phase-2A). Additive, nullable columns on all
    // three work-item tables so a series anchor can carry its compact JSON rule
    // and the shared materializer can find due anchors (nextDue) and existing
    // occurrences (seriesId) by index. Partial indexes keep maintenance ~free
    // while recurrence is unused. Fresh installs get these in _onCreate.
    if (oldVersion < 27) {
      for (final table in ['tasks', 'enquiries', 'crm_enquiries']) {
        for (final col in [
          'recurrence TEXT',
          'seriesId TEXT',
          'nextDue INTEGER',
        ]) {
          try {
            await db.execute('ALTER TABLE $table ADD COLUMN $col');
          } catch (_) {
            // Column already present — safe to ignore.
          }
        }
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${table}_nextDue ON $table(nextDue) WHERE nextDue IS NOT NULL',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${table}_seriesId ON $table(seriesId) WHERE seriesId IS NOT NULL',
        );
      }
    }

    // v28: conversation-scoped messages index. The chat-open delta sync now
    // reads the local high-water mark (SELECT MAX(createdAt) WHERE taskId=?)
    // to bound the Firestore listener, and the paged reads filter taskId then
    // order by createdAt. A single-column taskId index forces a scan of the
    // conversation's rows to find the max; the composite makes it one seek.
    if (oldVersion < 28) {
      try {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_taskId_createdAt ON messages(taskId, createdAt)',
        );
      } catch (_) {
        // Index already present — safe to ignore.
      }
    }

    // v29: baked action occurrence number on the actions index tables. The
    // Actions tabs used to recompute a per-family running counter over their
    // (often filtered) visible rows, which drifts from the authoritative
    // number baked onto each message at send time (MessageModel.sequenceNumber).
    // Mirror it onto the index so tabs show the same #N the chat card carries
    // and stay stable under filtering. The actions row id IS the originating
    // message id, so installed DBs are backfilled with a correlated subquery.
    if (oldVersion < 29) {
      for (final table in ['actions', 'sales_actions', 'crm_actions']) {
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN seqNo INTEGER');
        } catch (_) {
          // Column already present — safe to ignore.
        }
        await db.execute(
          'UPDATE $table SET seqNo = '
          '(SELECT sequenceNumber FROM messages WHERE messages.id = $table.id)',
        );
      }
    }

    // v30: reconcile the actions index against the CURRENT classifier. A bare
    // 📅 emoji used to be enough to classify a message as a follow-up, so every
    // deadline edit ("📅 Deadline updated: X → Y"), "📅 Task scheduled!" and
    // "📅 Reminder scheduled …" got indexed as an OPEN Fup action — a phantom
    // pending chip on the card, a bogus Actions-tab row, and inflated
    // follow-up occurrence numbers. detectActionType now requires a follow-up
    // token, so re-derive every stored row from the text it already carries:
    // drop rows that are no longer actions and retype the ones that moved.
    // One-pass, idempotent, and it leaves rows that already agree untouched.
    if (oldVersion < 30) {
      for (final table in ['actions', 'sales_actions', 'crm_actions']) {
        final rows = await db.query(
          table,
          columns: ['id', 'actionType', 'text'],
        );
        final batch = db.batch();
        var touched = 0;
        for (final row in rows) {
          final text = row['text'] as String? ?? '';
          // No text to re-derive from — leave the row as written.
          if (text.isEmpty) continue;
          final detected = Helpers.detectActionType(text);
          final id = row['id'];
          if (detected == null) {
            batch.delete(table, where: 'id = ?', whereArgs: [id]);
            touched++;
          } else if (detected != row['actionType']) {
            batch.update(
              table,
              {'actionType': detected},
              where: 'id = ?',
              whereArgs: [id],
            );
            touched++;
          }
        }
        if (touched > 0) await batch.commit(noResult: true);
      }
    }

    if (oldVersion < 31) {
      // Local-first paywall gate: cache the signed-in user's plan bundle so
      // module gating resolves from SQLite on cold start instead of a direct
      // Firestore users/{uid} read (see saveUserPlan / getUserPlan).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_plan (
          uid TEXT PRIMARY KEY,
          planType TEXT,
          planExpiry INTEGER,
          modulePlans TEXT,
          cachedAt INTEGER NOT NULL
        )
      ''');
    }

    if (oldVersion < 32) {
      // Persist the phonebook-nickname → avatar url index (see
      // [AvatarCacheService.applyNicknameIndex]) so cards resolve a leader's
      // photo by local contact name instantly on cold start instead of waiting
      // for the contact + Firestore rebuild.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS avatar_nicknames (
          name TEXT PRIMARY KEY,
          avatarUrl TEXT NOT NULL,
          cachedAt INTEGER NOT NULL
        )
      ''');
    }
  }

  /// Rewrite [tableName]'s `participants` so every row satisfies the invariant
  /// `participants ⊇ {createdBy} ∪ {assigneeUids}` (see [participantsUnion]).
  /// Rows already satisfying it (compared as a set, so order-insensitive) are
  /// skipped to avoid needless writes. One-time v23 migration; runs for tasks,
  /// enquiries and crm_enquiries.
  Future<void> _backfillParticipantsInvariant(
    Database db,
    String tableName,
  ) async {
    final rows = await db.query(
      tableName,
      columns: [
        'id',
        'createdBy',
        'assignedToUid',
        'extraFields',
        'participants',
      ],
    );
    for (final row in rows) {
      final existing = _decodeStringList(row['participants'] as String?);
      final union = participantsUnion(
        existing,
        createdBy: row['createdBy'] as String?,
        assignedToUid: row['assignedToUid'] as String?,
        extraFields: _decodeMap(row['extraFields'] as String?),
      );
      if (union.length == existing.length && union.every(existing.contains)) {
        continue; // Already complete — no write.
      }
      await db.update(
        tableName,
        {'participants': jsonEncode(union)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  // ── Messages ──────────────────────────────────────────────────────────────

  /// Max updatedAt (ms since epoch) stored in [tableName] — the delta-sync
  /// watermark so Firestore listeners only fetch documents changed since the
  /// newest row already in SQLite.
  ///
  /// Verified (roadmap 4.4) via EXPLAIN QUERY PLAN: for every watermarked table
  /// (tasks, enquiries, crm_enquiries) `SELECT MAX(updatedAt)` resolves to
  /// `SEARCH <table> USING COVERING INDEX idx_<table>_updatedAt` — SQLite's
  /// MIN/MAX optimization does a single rightmost-leaf seek (O(log n)), NOT a
  /// full scan. All three indexes are created in [_onCreate] (crm_enquiries also
  /// in [_onUpgrade]), so no migration is needed. Keep any future watermarked
  /// table index-backed on updatedAt or this watermark check degrades to a
  /// per-launch full scan.
  Future<int?> getMaxUpdatedAt(String tableName) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(updatedAt) AS maxUpdatedAt FROM $tableName',
    );
    return result.first['maxUpdatedAt'] as int?;
  }

  /// IDs of locally-stored messages under [parentId] not yet marked read by
  /// [userId] — lets read receipts be written without fetching the whole
  /// Firestore messages subcollection first.
  Future<List<String>> getUnreadMessageIds(
    String parentId,
    String userId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: 'taskId = ? AND (readBy IS NULL OR readBy NOT LIKE ?)',
      whereArgs: [parentId, '%"$userId"%'],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// UIDs the [currentUid] user has already interacted with — co-participants,
  /// assignees and creators on their tasks/enquiries/CRM records, plus anyone
  /// who has sent a message in a chat they are part of. Powers the scoped
  /// contact picker ("Team = already interacted"). Empty UID and the current
  /// user are excluded; 'system' senders are ignored.
  Future<Set<String>> getInteractedUids(String currentUid) async {
    if (currentUid.isEmpty) return {};
    final db = await database;
    final uids = <String>{};

    // Co-participants / assignees / creators across all three parent tables.
    for (final table in const ['tasks', 'enquiries', 'crm_enquiries']) {
      List<Map<String, Object?>> rows;
      try {
        rows = await db.rawQuery(
          'SELECT participants, assignedToUid, createdBy FROM $table',
        );
      } catch (_) {
        continue;
      }
      for (final r in rows) {
        final parts = _decodeStringList(r['participants'] as String?);
        final assignee = (r['assignedToUid'] as String?) ?? '';
        final creator = (r['createdBy'] as String?) ?? '';
        // Only count records the current user actually belongs to.
        if (currentUid != creator &&
            currentUid != assignee &&
            !parts.contains(currentUid)) {
          continue;
        }
        for (final p in parts) {
          if (p.isNotEmpty && p != currentUid) uids.add(p);
        }
        if (assignee.isNotEmpty && assignee != currentUid) uids.add(assignee);
        if (creator.isNotEmpty && creator != currentUid) uids.add(creator);
      }
    }

    // Anyone who has messaged in a chat the current user is part of.
    try {
      final msgs = await db.rawQuery(
        "SELECT DISTINCT senderId FROM messages "
        "WHERE senderId IS NOT NULL AND senderId != ? AND senderId != 'system'",
        [currentUid],
      );
      for (final m in msgs) {
        final s = (m['senderId'] as String?) ?? '';
        if (s.isNotEmpty) uids.add(s);
      }
    } catch (_) {}

    return uids;
  }

  Future<List<MessageModel>> getMessages(
    String taskId, {
    int limit = 50,
  }) async {
    final tr = StartupTrace.instance.begin(
      'getMessages',
      caller: 'getMessages',
    );
    final w = SyncTelemetry.instance.startTimer();
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );

    final tDecode = StartupTrace.instance.begin(
      'getMessages:decode',
      kind: StartupTraceKind.ui,
      caller: 'getMessages',
    );
    final messages = results.map((row) => _messageFromRow(row)).toList();
    messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    StartupTrace.instance.end(tDecode, rows: messages.length);
    SyncTelemetry.instance.recordDb('getMessages', w, messages.length);
    StartupTrace.instance.end(tr, rows: messages.length);
    return messages;
  }

  /// Get a single message by its ID (PK lookup).
  ///
  /// R6.4: replaces `getMessages(taskId)` (limit 50) + `firstWhere(id)` in
  /// TaskProvider.updateMessage and BaseModuleProvider.updateMessage, which
  /// read up to 50 rows to find one AND threw a StateError when the target
  /// wasn't in the latest 50 — the root cause of "closing an older action
  /// does nothing". A PK lookup is O(1), finds the row at any age, and (like
  /// getTaskById) is not telemetry-tracked, so it drops out of the getMessages
  /// storm count.
  Future<MessageModel?> getMessageById(String messageId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return _messageFromRow(results.first);
  }

  /// Get the display name of the most recent (non-system) message sender
  /// in the given module, excluding the current user.
  /// Used to preselect a person on the home ASSIGNEE tab.
  /// [parentType] is 'task', 'sales' or 'crm'. Returns null if unresolvable.
  Future<String?> getLastMessageSenderName({
    required String parentType,
    required String excludeUid,
  }) async {
    final db = await database;
    final parentTable = parentType == 'task'
        ? 'tasks'
        : parentType == 'crm'
        ? 'crm_enquiries'
        : 'enquiries';
    final rows = await db.rawQuery(
      '''
      SELECT m.senderId, p.createdBy, p.createdByName, p.assignedToUid, p.assignedTo
      FROM messages m
      INNER JOIN $parentTable p ON p.id = m.taskId
      WHERE m.type != 'system' AND m.senderId != 'system' AND m.senderId != ?
      ORDER BY m.createdAt DESC
      LIMIT 1
    ''',
      [excludeUid],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final senderId = row['senderId'] as String?;
    if (senderId == null || senderId.isEmpty) return null;

    // Resolve via cached users table first
    final users = await db.query(
      'users',
      columns: ['name'],
      where: 'uid = ?',
      whereArgs: [senderId],
      limit: 1,
    );
    if (users.isNotEmpty) {
      final name = (users.first['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }

    // Fallback: match sender against the parent row's participant fields
    if (senderId == row['createdBy']) {
      final name = (row['createdByName'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    if (senderId == row['assignedToUid']) {
      final name = (row['assignedTo'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  /// Get messages created before a given date (for pagination).
  Future<List<MessageModel>> getMessagesBefore(
    String taskId,
    DateTime before, {
    int limit = 30,
  }) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'taskId = ? AND createdAt < ?',
      whereArgs: [taskId, before.millisecondsSinceEpoch],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    final messages = results.map((row) => _messageFromRow(row)).toList();
    messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return messages;
  }

  /// Newest locally-cached message time (ms epoch) for a conversation, or null
  /// when nothing is cached yet. Used to bound the chat-open Firestore
  /// listener to messages newer than the local high-water mark so a returning
  /// user does not re-download the whole retained history on every open.
  /// Served by idx_messages_taskId_createdAt (a single B-tree seek for MAX).
  /// [parentId] is the taskId for Task or the enquiryId for Sales/CRM — the
  /// shared messages table keys every module's rows in the `taskId` column.
  Future<int?> getMaxMessageCreatedAt(String parentId) async {
    if (parentId.isEmpty) return null;
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT MAX(createdAt) AS maxCreatedAt FROM messages WHERE taskId = ?',
      [parentId],
    );
    final value = rows.isEmpty ? null : rows.first['maxCreatedAt'];
    return value is int ? value : null;
  }

  /// Move a parent card's clock (updatedAt + lastMessageTime) FORWARD to
  /// [stamp] — never backwards. Replying to an old query (or bulk-loading chat
  /// history) used to drag both columns back to that message's original time,
  /// which re-sorted the card and made the next server snapshot look newer than
  /// the local row.
  ///
  /// [parentType] routes the bump to the parent's own table. This used to
  /// hardcode 'tasks', so a Sales/CRM message — whose `taskId` column holds the
  /// enquiryId — matched no row and returned at the isEmpty guard. A new
  /// enquiry message therefore never re-sorted its card locally; ordering had
  /// to wait for the Firestore echo of the parent doc, and never arrived at all
  /// while offline. Both module tables carry the same updatedAt /
  /// lastMessageTime columns and the same forward-only rule applies.
  ///
  /// The task path is deliberately untouched: it still probes 'tasks' only, so
  /// an orphan task message cannot bump an unrelated enquiry row.
  ///
  /// Raising a local updatedAt also raises the delta-sync watermark for that
  /// table; FirebaseService._watermarkOverlap (5 min) exists precisely to
  /// absorb the gap between this client-clock bump and the parent doc's
  /// serverTimestamp, and _watermarkFor clamps the anchor to `now`.
  Future<void> _bumpParentClockForward(
    Database db,
    String parentId,
    int stamp, {
    String? parentType,
    String? lastMessageText,
  }) async {
    if (parentId.isEmpty) return;
    // enquiries (the shared Sales table) probed first, matching
    // _resolveEnquiryParentInfo's order — the common module resolves in one
    // query instead of always hitting crm_enquiries first and missing.
    final tables = parentType == 'enquiry'
        ? const ['enquiries', 'crm_enquiries']
        : const ['tasks'];
    for (final table in tables) {
      final rows = await db.query(
        table,
        columns: ['updatedAt', 'lastMessageTime'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final bump = <String, dynamic>{};
      final currentUpdated = rows.first['updatedAt'] as int?;
      final currentLast = rows.first['lastMessageTime'] as int?;
      if (currentUpdated == null || stamp > currentUpdated) {
        bump['updatedAt'] = stamp;
      }
      if (currentLast == null || stamp > currentLast) {
        bump['lastMessageTime'] = stamp;
        // Keep the card preview in step with the clock so the last-message
        // line shows the latest text immediately (no wait for Firestore echo).
        if (lastMessageText != null) {
          bump['lastMessageText'] = lastMessageText;
        }
      }
      if (bump.isEmpty) return; // Already at or ahead of this message
      await db.update(table, bump, where: 'id = ?', whereArgs: [parentId]);
      _notify(table, ids: {parentId});
      return;
    }
  }

  /// Save or update a message in local DB
  Future<void> saveMessage(MessageModel message, {String? parentType}) async {
    final db = await database;
    await db.insert(
      'messages',
      _messageToRow(message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // R6.4 Fix B: carry the parent taskId so watchMessages can scope its
    // re-read to this conversation. For the messages table `ids` holds the
    // conversation/parent taskId, NOT the message row id — the only consumer
    // (watchMessages) filters by conversation, and nothing patches message
    // rows by id (ChangeSetConsumerMixin handles tasks/enquiries only;
    // upload_retry_service ignores the payload).
    _notify('messages', ids: {message.taskId});
    // Bump the parent card's clock so home sort reflects the latest activity —
    // forward only (see [_bumpParentClockForward]).
    await _bumpParentClockForward(
      db,
      message.taskId,
      message.createdAt.millisecondsSinceEpoch,
      parentType: parentType,
      lastMessageText: message.text.length > 80
          ? '${message.text.substring(0, 80)}\u2026'
          : message.text,
    );
    // Write-through: populate actions table (non-blocking)
    try {
      if (parentType == 'enquiry') {
        await _writeThroughEnquiryAction(message);
      } else {
        await _writeThroughAction(message, parentType: parentType);
      }
    } catch (e) {
      print('[LocalDB] Write-through action failed: $e');
    }
  }

  /// Save multiple messages in a batch (efficient for bulk sync)
  Future<void> saveMessages(
    List<MessageModel> messages, {
    String? parentType,
  }) async {
    if (messages.isEmpty) return;
    final tr = StartupTrace.instance.begin(
      'saveMessages',
      caller: 'saveMessages',
    );
    final w = SyncTelemetry.instance.startTimer();
    // One stopwatch reused across the four sections below. The total alone
    // cannot say which section costs the 48ms average / 295ms worst case, so
    // each phase records its own elapsed before being reset. startTimer
    // returns null when diagnostics are off, so a production build allocates
    // nothing and every recordDb below short-circuits.
    final wPhase = SyncTelemetry.instance.startTimer();
    final db = await database;

    // Build every row up front: the batch needs it and the change fingerprint
    // is derived from it, so one construction serves both.
    final candidates = <({MessageModel msg, Map<String, dynamic> row})>[
      for (final msg in messages) (msg: msg, row: _messageToRow(msg)),
    ];

    // Optimization: skip writes for messages that already exist unchanged.
    // `changeKey` fingerprints the mutable columns (see [_messageChangeKey]);
    // comparing THAT rather than one nullable field is what makes the skip
    // actually fire.
    // Bound-parameter diff query (no string interpolation of message ids),
    // chunked to stay under SQLite's SQLITE_MAX_VARIABLE_NUMBER. A sync batch
    // is normally tiny; the chunking just keeps a pathological bulk-load from
    // throwing on an oversized IN list.
    final existingKeys = <String, String?>{};
    final msgIds = candidates.map((c) => c.msg.id).toList();
    const chunkSize = 500;
    for (int i = 0; i < msgIds.length; i += chunkSize) {
      final chunk = msgIds.sublist(
        i,
        i + chunkSize > msgIds.length ? msgIds.length : i + chunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final chunkRows = await db.rawQuery(
        'SELECT id, changeKey FROM messages WHERE id IN ($placeholders)',
        chunk,
      );
      for (final row in chunkRows) {
        existingKeys[row['id'] as String] = row['changeKey'] as String?;
      }
    }
    // Phase 1: the write-skip diff query. Runs on EVERY sync emission, even the
    // ones that turn out to change nothing, so it is the cost the early-return
    // path below used to hide completely.
    SyncTelemetry.instance.recordDb(
      'saveMessages:diff',
      wPhase,
      messages.length,
    );
    wPhase?.reset();

    final toWrite = <({MessageModel msg, Map<String, dynamic> row})>[];
    for (final c in candidates) {
      // Presence, not a nullable value: the old check tested `sequenceNumber`,
      // which is NULL for every non-system message, so an existing row looked
      // exactly like a missing one and the whole conversation got rewritten on
      // every emission. Rows predating the changeKey column carry NULL, fail
      // the comparison once, and self-heal on that rewrite.
      if (!existingKeys.containsKey(c.msg.id)) {
        toWrite.add(c); // New message
      } else if (existingKeys[c.msg.id] != c.row['changeKey']) {
        toWrite.add(c); // Changed (receipt, reply, upload, edit, delete)
      }
      // else: unchanged — skip write
    }

    if (toWrite.isEmpty) {
      // Diagnostics: captures the per-event diff-query cost even when the
      // write-skip optimization means nothing is actually written.
      SyncTelemetry.instance.recordDb('saveMessages', w, 0);
      StartupTrace.instance.end(tr, rows: 0, detail: 'no-op (all unchanged)');
      return; // Nothing changed — no write, no notify
    }

    // Resolve every action row BEFORE the commit: parent lookups are reads, and
    // a read queued inside a sqflite batch does not return until commit. One
    // memo per batch keeps it at a single parent query per distinct parent
    // (SYNC_AND_DATABASE_ARCHITECTURE.md §4.4).
    final parentMemo = <String, _ActionParentInfo>{};
    final actionRows = <({String table, Map<String, dynamic> row})>[];
    final actionTables = <String>{};
    // Messages that arrived soft-deleted (a delete-for-everyone / action-card
    // undo propagated from another device). Their action row must go too, or
    // the recipient keeps a phantom pending chip/Actions-tab row: the
    // write-through only inserts, and the "🗑️ deleted" placeholder no longer
    // classifies as an action, so nothing would otherwise remove the old row.
    final tombstoneIds = <String>[];
    for (final c in toWrite) {
      if (c.msg.deleted) {
        tombstoneIds.add(c.msg.id);
        continue;
      }
      try {
        final built = await _buildActionRow(
          db,
          c.msg,
          parentType: parentType,
          parentMemo: parentMemo,
        );
        if (built != null) {
          actionRows.add(built);
          actionTables.add(built.table);
        }
      } catch (e) {
        // Write-through action failed — non-critical, skip silently
      }
    }
    // Phase 2: action-type detection, parent resolution and row construction.
    // CPU and reads only — this phase writes nothing any more.
    SyncTelemetry.instance.recordDb(
      'saveMessages:prepare',
      wPhase,
      toWrite.length,
    );
    wPhase?.reset();

    // Message rows and their action rows commit in ONE transaction. This used
    // to be 1 + A transactions (A = the action messages in the batch), and each
    // commit paid fsyncs — the commit count, not the row count, is what let a
    // 26-row batch reach 295ms. Batching collapses them to a single commit,
    // which is the whole win here (WAL was evaluated and pulled — see
    // _initDatabase — so the default journal still applies).
    final batch = db.batch();
    for (final c in toWrite) {
      batch.insert(
        'messages',
        c.row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final a in actionRows) {
      batch.insert(
        a.table,
        a.row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    // Purge action rows for messages that arrived already deleted. The id lives
    // in exactly one of the three tables, so the deletes against the other two
    // are no-ops; adding every table to the notify set keeps pending counts
    // recomputed wherever the row was.
    if (tombstoneIds.isNotEmpty) {
      for (final id in tombstoneIds) {
        for (final table in ['actions', 'sales_actions', 'crm_actions']) {
          batch.delete(table, where: 'id = ?', whereArgs: [id]);
        }
      }
      actionTables.addAll(['actions', 'sales_actions', 'crm_actions']);
    }
    final tMsgTx = StartupTrace.instance.begin(
      'db.tx:messages',
      kind: StartupTraceKind.tx,
      caller: 'saveMessages',
    );
    await batch.commit(noResult: true);
    StartupTrace.instance.end(tMsgTx, rows: toWrite.length + actionRows.length);
    // Phase 3: the single commit. Bills every row it wrote, message and action
    // alike, so the number is still comparable with the old phase 2.
    SyncTelemetry.instance.recordDb(
      'saveMessages:batch',
      wPhase,
      toWrite.length + actionRows.length,
    );
    wPhase?.reset();
    // R6.4 Fix B: scope the notify to the conversation(s) actually written (a
    // sync batch can span more than one taskId). See saveMessage for why `ids`
    // carries the parent taskId for the messages table.
    _notify('messages', ids: toWrite.map((c) => c.msg.taskId).toSet());
    // One notify per touched actions table instead of one per action message.
    // The per-row notifies used to re-enter the SQLite queue mid-loop, so each
    // following await waited behind the reads they triggered.
    for (final table in actionTables) {
      _notify(table);
    }
    // Bump the parent card's clock for the latest message (so home sort is
    // correct) — forward only, a history load must not drag the card into the
    // past
    final latest = toWrite
        .map((c) => c.msg)
        .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b);
    await _bumpParentClockForward(
      db,
      latest.taskId,
      latest.createdAt.millisecondsSinceEpoch,
      parentType: parentType,
    );
    // Phase 4: the table-change notifies plus the parent clock bump (which
    // reads and may rewrite the parent row). Always bills exactly one row: the
    // parent, never the message batch.
    SyncTelemetry.instance.recordDb('saveMessages:notifyClock', wPhase, 1);
    SyncTelemetry.instance.recordDb('saveMessages', w, toWrite.length);
    StartupTrace.instance.end(tr, rows: toWrite.length);
  }

  /// Delete a single message by ID (explicit user action only)
  Future<void> deleteMessage(String messageId) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [messageId]);
    // Also remove from every actions index table if it was an action — the row
    // lives in exactly one of the three (task / sales / CRM), so the other two
    // deletes are no-ops. crm_actions MUST be included or a deleted CRM action
    // leaves a phantom chip on the card (parity with deleteAction).
    await db.delete('actions', where: 'id = ?', whereArgs: [messageId]);
    await db.delete('sales_actions', where: 'id = ?', whereArgs: [messageId]);
    await db.delete('crm_actions', where: 'id = ?', whereArgs: [messageId]);
    _notify('messages');
    _notify('actions');
    _notify('sales_actions');
    _notify('crm_actions');
  }

  /// Delete an action from the actions table by its message ID.
  /// Used when a message is soft-deleted (delete for everyone) to also
  /// remove its corresponding action log entry.
  Future<void> deleteAction(String messageId) async {
    final db = await database;
    await db.delete('actions', where: 'id = ?', whereArgs: [messageId]);
    await db.delete('sales_actions', where: 'id = ?', whereArgs: [messageId]);
    await db.delete('crm_actions', where: 'id = ?', whereArgs: [messageId]);
    _notify('actions');
    _notify('sales_actions');
    _notify('crm_actions');
  }

  /// Update the fileUrl of a message after upload completes.
  /// Used in the SQLite-first write pattern: message is saved with
  /// fileUrl='pending', then updated with the real Firebase Storage URL.
  /// Also clears any stale uploadError — a real URL means the upload
  /// succeeded, so the message must leave the failed state.
  Future<void> updateMessageFileUrl(String messageId, String fileUrl) async {
    final db = await database;
    await db.update(
      'messages',
      {'fileUrl': fileUrl, 'uploadError': null},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notify('messages');
  }

  /// Mark a message as upload-failed with an error reason.
  Future<void> markMessageUploadFailed(String messageId, String error) async {
    final db = await database;
    await db.update(
      'messages',
      {'fileUrl': 'failed', 'uploadError': error},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notify('messages');
  }

  /// Clear upload error and reset to pending for retry.
  Future<void> clearMessageUploadError(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {'fileUrl': 'pending', 'uploadError': null},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notify('messages');
  }

  /// Get all messages with pending uploads (fileUrl = 'pending').
  /// Returns raw rows (createdAt is integer, not Timestamp).
  Future<List<Map<String, dynamic>>> getPendingUploadMessages() async {
    final db = await database;
    return db.query(
      'messages',
      where: "fileUrl = 'pending'",
      orderBy: 'createdAt ASC',
    );
  }

  /// SQL fragment limiting retry candidates to message types
  /// UploadRetryService._retrySingleUpload can actually re-upload (its switch
  /// covers image / file / voice and returns false for everything else).
  /// Shared by [getRetryableUploadMessages] and [getRetryableUploadCount] so
  /// the gate and the row query can never disagree.
  static const String _kRetryableTypes = "type IN ('image', 'file', 'voice')";

  /// Messages eligible for background upload retry: still 'pending' OR
  /// visibly 'failed' (so a recovered connection also delivers attachments
  /// the user was shown a "Tap to retry" error for).
  ///
  /// Restricted to the three attachment types UploadRetryService can actually
  /// re-upload. A failed TEXT send is also stamped fileUrl='failed' (both
  /// providers do this so the row leaves the pending state), but its retry
  /// hits the switch's `default:` branch and returns false forever — so each
  /// such row pinned the retry COUNT gate above zero permanently and the
  /// service kept polling every 5 minutes for the life of the install.
  Future<List<Map<String, dynamic>>> getRetryableUploadMessages() async {
    final db = await database;
    return db.query(
      'messages',
      where: "fileUrl IN ('pending', 'failed') AND $_kRetryableTypes",
      orderBy: 'createdAt ASC',
    );
  }

  /// Index-only count of messages awaiting a background upload retry. Lets the
  /// retry service skip the full row query (and any upload work) on the common
  /// launch where nothing is pending. Same type restriction as
  /// [getRetryableUploadMessages] so the gate can actually reach zero.
  Future<int> getRetryableUploadCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) FROM messages WHERE fileUrl IN ('pending', 'failed') "
      'AND $_kRetryableTypes',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Public row→model conversion (background retry service rebuilds the
  /// message to deliver it to Firestore after a successful re-upload).
  MessageModel messageFromRow(Map<String, dynamic> row) => _messageFromRow(row);

  /// Find messages stuck in 'pending' state for too long and mark them as failed.
  /// Returns the number of messages cleaned up.
  Future<int> cleanupStalePendingMessages({int maxAgeMinutes = 30}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(minutes: maxAgeMinutes))
        .millisecondsSinceEpoch;
    final staleMessages = await db.query(
      'messages',
      where: "fileUrl = 'pending' AND createdAt < ?",
      whereArgs: [cutoff],
    );
    if (staleMessages.isEmpty) return 0;
    for (final msg in staleMessages) {
      await db.update(
        'messages',
        {
          'fileUrl': 'failed',
          'uploadError': 'Upload timed out — message was not sent',
        },
        where: 'id = ?',
        whereArgs: [msg['id']],
      );
    }
    _notify('messages');
    return staleMessages.length;
  }

  // ── Actions Table ─────────────────────────────────────────────────────

  /// Write-through: if the message is an action, insert/update it in the actions table.
  /// ⚠️ Indexing gate — keyed entirely on Helpers.detectActionType; a type
  /// missing there is never indexed and won't appear in card strips/Actions tabs.
  Future<void> _writeThroughAction(
    MessageModel message, {
    String? parentType,
    Map<String, _ActionParentInfo>? parentMemo,
  }) async {
    final db = await database;
    // A soft-deleted message is never an action; drop any prior row so the
    // pending count clears on this device too (mirrors the saveMessages batch).
    if (message.deleted) {
      await deleteAction(message.id);
      return;
    }
    final built = await _buildActionRow(
      db,
      message,
      parentType: parentType,
      parentMemo: parentMemo,
    );
    if (built == null) return;
    await db.insert(
      built.table,
      built.row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify(built.table);
  }

  /// Build the actions-table row for [message] WITHOUT writing it, plus the
  /// table that row belongs to; null when the message isn't an action.
  ///
  /// Returning the row instead of inserting it is what lets [saveMessages] fold
  /// every action write into the same batch as the message rows, so one sync
  /// emission costs one transaction instead of 1 + A. The single-message
  /// writers keep their own insert + notify.
  ///
  /// Routing is unchanged: [parentMemo] resolves each distinct parent once, and
  /// an enquiry parent goes to its module table (crm_actions when the parent is
  /// in crm_enquiries, else sales_actions) rather than the shared actions table.
  Future<({String table, Map<String, dynamic> row})?> _buildActionRow(
    Database db,
    MessageModel message, {
    String? parentType,
    Map<String, _ActionParentInfo>? parentMemo,
  }) async {
    final actionType = Helpers.detectActionType(message.text);
    if (actionType == null) return null;

    final info =
        parentMemo?[message.taskId] ??
        await _resolveActionParentInfo(db, message.taskId, parentType);
    if (parentMemo != null) parentMemo[message.taskId] = info;

    if (info.parentType == 'enquiry') {
      return (
        table: info.isCrm ? 'crm_actions' : 'sales_actions',
        row: _moduleActionRow(message, info, actionType),
      );
    }
    return (table: 'actions', row: _taskActionRow(message, info, actionType));
  }

  /// Parse the scheduled date out of an action message's text. The task row and
  /// the module row each carried a byte-identical copy of this; both now call it.
  int? _parseActionScheduledDate(String actionType, String text) {
    if (actionType == 'followup') {
      final followUpDateMatch = RegExp(
        r'for\s+(.+?)(?:\s+by\s+|\s+at\s+|$)',
        caseSensitive: false,
      ).firstMatch(text);
      if (followUpDateMatch == null) return null;
      final parsed = Helpers.parseActionDate(
        followUpDateMatch.group(1)!.trim(),
      );
      return parsed?.millisecondsSinceEpoch;
    }
    final dates = Helpers.parseAllActionDates(text);
    return dates.isNotEmpty ? dates.first.millisecondsSinceEpoch : null;
  }

  /// Shared `actions` row for a task-parented message. No teamId: the task
  /// actions table has never carried one, so the shape is preserved exactly.
  Map<String, dynamic> _taskActionRow(
    MessageModel message,
    _ActionParentInfo info,
    String actionType,
  ) {
    return {
      'id': message.id,
      'parentId': message.taskId,
      'parentType': info.parentType,
      'actionType': actionType,
      'text': message.text,
      'senderId': message.senderId,
      'createdAt': message.createdAt.millisecondsSinceEpoch,
      'scheduledDate': _parseActionScheduledDate(actionType, message.text),
      'isReplied': message.isReplied ? 1 : 0,
      'isDone': message.isFollowUpDone ? 1 : 0,
      'clientName': info.clientName,
      'parentTitle': info.parentTitle,
      'seqNo': message.sequenceNumber,
    };
  }

  /// Module actions row (sales_actions / crm_actions): the task shape minus
  /// parentType, plus the team scope.
  Map<String, dynamic> _moduleActionRow(
    MessageModel message,
    _ActionParentInfo info,
    String actionType,
  ) {
    return {
      'id': message.id,
      'parentId': message.taskId,
      'teamId': info.teamId,
      'actionType': actionType,
      'text': message.text,
      'senderId': message.senderId,
      'createdAt': message.createdAt.millisecondsSinceEpoch,
      'scheduledDate': _parseActionScheduledDate(actionType, message.text),
      'isReplied': message.isReplied ? 1 : 0,
      'isDone': message.isFollowUpDone ? 1 : 0,
      'clientName': info.clientName,
      'parentTitle': info.parentTitle,
      'seqNo': message.sequenceNumber,
    };
  }

  /// Update action state (isReplied, isDone) when a message is updated.
  /// Applies to all three actions index tables (task / sales / CRM) — the row
  /// lives in exactly one, so the other updates are no-ops. crm_actions was
  /// previously omitted, so a CRM action's Done/Reply tick never persisted on
  /// this device (the chip stayed pending / lost its ✓ badge).
  Future<void> updateActionState(
    String messageId, {
    bool? isReplied,
    bool? isDone,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{};
    if (isReplied != null) updates['isReplied'] = isReplied ? 1 : 0;
    if (isDone != null) updates['isDone'] = isDone ? 1 : 0;
    if (updates.isEmpty) return;
    await db.update(
      'actions',
      updates,
      where: 'id = ?',
      whereArgs: [messageId],
    );
    await db.update(
      'sales_actions',
      updates,
      where: 'id = ?',
      whereArgs: [messageId],
    );
    await db.update(
      'crm_actions',
      updates,
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notify('actions');
    _notify('sales_actions');
    _notify('crm_actions');
  }

  /// Get all actions for a parent (task or enquiry).
  Future<List<Map<String, dynamic>>> getActionsForParent(
    String parentId,
  ) async {
    final db = await database;
    return await db.query(
      'actions',
      where: 'parentId = ?',
      whereArgs: [parentId],
      orderBy: 'createdAt ASC',
    );
  }

  /// Get last N action icons for a parent (lightweight: returns actionType, isReplied, isDone, createdAt, seqNo).
  Future<List<Map<String, dynamic>>> getActionIconsForParent(
    String parentId, {
    int limit = 3,
  }) async {
    final db = await database;
    final rows = await db.query(
      'actions',
      columns: [
        'actionType',
        'isReplied',
        'isDone',
        'createdAt',
        'id',
        'text',
        // Baked occurrence number — card chips show the same number the chat
        // card and the Actions tab carry.
        'seqNo',
      ],
      where: 'parentId = ?',
      whereArgs: [parentId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.reversed.toList();
  }

  /// Batch-load last N action icons for multiple parents in ONE query.
  /// Returns Map<parentId, List<actionRow>>. Much faster than calling
  /// getActionIconsForParent() per parent (1 query vs N queries).
  /// Limit is generous (100) so pending-action counts and the bell icon
  /// never miss older still-open actions; the chip UI slices down itself.
  Future<Map<String, List<Map<String, dynamic>>>> getActionIconsForParents(
    List<String> parentIds, {
    int limit = 100,
  }) => _actionIconsForParentsFrom('actions', parentIds, limit);

  /// Table-parameterized core — shared by the task actions table and the
  /// module actions tables (getModuleActionIconsForParents).
  Future<Map<String, List<Map<String, dynamic>>>> _actionIconsForParentsFrom(
    String table,
    List<String> parentIds,
    int limit,
  ) async {
    if (parentIds.isEmpty) return {};
    final db = await database;
    // One index-served `LIMIT` query per parent, all of them inside a SINGLE
    // batch (one round-trip to the DB thread). The previous shape selected
    // EVERY action row of EVERY parent — `text` column included — sorted the
    // lot in a temp B-tree and only then sliced down to [limit] in Dart, so a
    // single card refresh decoded thousands of rows on the UI isolate.
    // Chunked so one batch never becomes a long-running transaction.
    const batchSize = 100;
    final result = <String, List<Map<String, dynamic>>>{};
    for (int i = 0; i < parentIds.length; i += batchSize) {
      final chunk = parentIds.sublist(
        i,
        i + batchSize > parentIds.length ? parentIds.length : i + batchSize,
      );
      final batch = db.batch();
      for (final parentId in chunk) {
        batch.rawQuery(
          'SELECT parentId, actionType, isReplied, isDone, createdAt, id, text, seqNo '
          'FROM $table WHERE parentId = ? '
          'ORDER BY createdAt DESC LIMIT ?',
          [parentId, limit],
        );
      }
      final results = await batch.commit();
      for (int j = 0; j < chunk.length; j++) {
        final rows = results[j];
        if (rows is! List || rows.isEmpty) continue;
        // Rows come back DESC (newest first); the UI expects oldest-first.
        result[chunk[j]] = rows
            .cast<Map<String, dynamic>>()
            .toList()
            .reversed
            .toList();
      }
    }
    return result;
  }

  /// Get all actions across all parents, with optional filters.
  ///
  /// When [dateUsesCreatedFallback] is true the date-range filter is applied
  /// to `COALESCE(scheduledDate, createdAt)` so rows without a scheduledDate
  /// are matched by their createdAt — mirroring the UI's date grouping which
  /// falls back to createdAt. Callers that need strict scheduledDate semantics
  /// leave it false (default).
  Future<List<Map<String, dynamic>>> getAllActions({
    String? parentType,
    String? actionType,
    int? dateFrom,
    int? dateTo,
    bool dateUsesCreatedFallback = false,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    String? where;
    List<dynamic>? whereArgs;
    final conditions = <String>[];
    final args = <dynamic>[];
    final dateExpr = dateUsesCreatedFallback
        ? 'COALESCE(scheduledDate, createdAt)'
        : 'scheduledDate';

    if (parentType != null) {
      conditions.add('parentType = ?');
      args.add(parentType);
    }
    if (actionType != null) {
      conditions.add('actionType = ?');
      args.add(actionType);
    }
    if (dateFrom != null) {
      conditions.add('$dateExpr >= ?');
      args.add(dateFrom);
    }
    if (dateTo != null) {
      conditions.add('$dateExpr <= ?');
      args.add(dateTo);
    }
    if (conditions.isNotEmpty) {
      where = conditions.join(' AND ');
      whereArgs = args;
    }

    return await db.query(
      'actions',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// Get full action rows scoped to a specific set of parent ids (e.g. one
  /// assignee's tasks) using a batched `parentId IN (...)` query, instead of
  /// loading every action and discarding non-matching parents in Dart.
  /// Optional [actionType]/[dateFrom]/[dateTo] filters mirror [getAllActions]
  /// (date uses the scheduledDate→createdAt fallback). Rows come back
  /// createdAt-DESC within each batch; callers re-sort as needed.
  Future<List<Map<String, dynamic>>> getActionsForParents(
    List<String> parentIds, {
    String? actionType,
    int? dateFrom,
    int? dateTo,
  }) async {
    if (parentIds.isEmpty) return [];
    final db = await database;
    const batchSize = 100;
    final all = <Map<String, dynamic>>[];
    for (int i = 0; i < parentIds.length; i += batchSize) {
      final chunk = parentIds.sublist(
        i,
        i + batchSize > parentIds.length ? parentIds.length : i + batchSize,
      );
      final placeholders = chunk.map((_) => '?').join(',');
      final conditions = ['parentId IN ($placeholders)'];
      final args = <dynamic>[...chunk];
      if (actionType != null) {
        conditions.add('actionType = ?');
        args.add(actionType);
      }
      if (dateFrom != null) {
        conditions.add('COALESCE(scheduledDate, createdAt) >= ?');
        args.add(dateFrom);
      }
      if (dateTo != null) {
        conditions.add('COALESCE(scheduledDate, createdAt) <= ?');
        args.add(dateTo);
      }
      final rows = await db.rawQuery(
        'SELECT * FROM actions WHERE ${conditions.join(' AND ')} '
        'ORDER BY createdAt DESC',
        args,
      );
      all.addAll(rows);
    }
    return all;
  }

  /// Total number of rows in the messages table (cheap COUNT).
  /// Used to distinguish a fresh install (nothing synced yet) from a
  /// legitimately action-free database before latching the backfill flag.
  Future<int> getTotalMessageCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM messages');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Distinct parent ids that have at least one local message.
  /// Used by the fresh-install message recovery to find tasks whose
  /// history was never downloaded.
  Future<Set<String>> getTaskIdsWithMessages() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT DISTINCT taskId FROM messages');
    return rows.map((r) => r['taskId'] as String).toSet();
  }

  /// Get total count of actions for pagination
  Future<int> getActionCount({
    String? parentType,
    String? actionType,
    int? dateFrom,
    int? dateTo,
  }) async {
    final db = await database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (parentType != null) {
      conditions.add('parentType = ?');
      args.add(parentType);
    }
    if (actionType != null) {
      conditions.add('actionType = ?');
      args.add(actionType);
    }
    if (dateFrom != null) {
      conditions.add('scheduledDate >= ?');
      args.add(dateFrom);
    }
    if (dateTo != null) {
      conditions.add('scheduledDate <= ?');
      args.add(dateTo);
    }

    final whereClause = conditions.isNotEmpty
        ? 'WHERE ${conditions.join(' AND ')}'
        : '';
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM actions $whereClause',
      args,
    );
    return result.first['count'] as int? ?? 0;
  }

  /// Row count of a MODULE actions table (`sales_actions` / `crm_actions`).
  /// [getActionCount] is hardcoded to the shared `actions` table, so the module
  /// backfill latch needs its own cheap COUNT: a database that already has its
  /// index must never pay for the full message scan again.
  Future<int> getModuleActionCount({required String actionsTableName}) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $actionsTableName',
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// Stream that re-queries actions whenever the actions table changes.
  Stream<List<Map<String, dynamic>>> watchAllActions({String? parentType}) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getAllActions(parentType: parentType);
      await for (final _ in tableChangesDebounced('actions')) {
        yield await getAllActions(parentType: parentType);
      }
    }).asBroadcastStream();
  }

  /// Stream that re-queries action icons for a parent whenever the actions table changes.
  Stream<List<Map<String, dynamic>>> watchActionIcons(
    String parentId, {
    int limit = 3,
  }) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getActionIconsForParent(parentId, limit: limit);
      await for (final _ in tableChanges2.where((c) => c.table == 'actions')) {
        yield await getActionIconsForParent(parentId, limit: limit);
      }
    }).asBroadcastStream();
  }

  // ── Sales Actions Table (team-scoped) ──────────────────────────────────

  /// Write-through for enquiry-parented messages: routes to the correct
  /// module actions table (crm_actions if the parent lives in crm_enquiries,
  /// otherwise sales_actions).
  Future<void> _writeThroughEnquiryAction(
    MessageModel message, {
    _ActionParentInfo? info,
    Map<String, _ActionParentInfo>? parentMemo,
  }) async {
    final db = await database;
    // Soft-deleted enquiry action → drop its module row (parity with the task
    // write-through and the saveMessages batch).
    if (message.deleted) {
      await deleteAction(message.id);
      return;
    }
    // Reuse an already-resolved parent (from _writeThroughAction) or the batch
    // memo; otherwise resolve crm-vs-sales routing + display fields once.
    final resolved =
        info ??
        parentMemo?[message.taskId] ??
        await _resolveEnquiryParentInfo(db, message.taskId);
    if (parentMemo != null) parentMemo[message.taskId] = resolved;

    final actionType = Helpers.detectActionType(message.text);
    if (actionType == null) return;
    // crm_actions when the parent lives in crm_enquiries, else sales_actions —
    // the routing writeThroughModuleAction used to apply.
    final table = resolved.isCrm ? 'crm_actions' : 'sales_actions';
    await db.insert(
      table,
      _moduleActionRow(message, resolved, actionType),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify(table);
  }

  /// Resolve the parent of an action message: whether it is a task or an
  /// enquiry, which module table an enquiry belongs to (crm vs sales), and the
  /// denormalized display fields (clientName / parentTitle / teamId) copied onto
  /// the action row.
  ///
  /// Collapses the old two-query pattern (a parentType probe PLUS a separate
  /// display-field lookup, both against `tasks`) into a single query per parent,
  /// preserving the exact routing/fallback semantics of the previous code:
  ///   • parentType 'enquiry'             → module tables (crm-first, else sales)
  ///   • parentType 'task'/other, found    → shared actions table, fields from tasks
  ///   • parentType null, id in tasks      → shared actions table (task)
  ///   • parentType null, id in an enquiry → module tables
  ///   • parentType null, id in neither    → shared actions table ('task' default)
  Future<_ActionParentInfo> _resolveActionParentInfo(
    Database db,
    String parentId,
    String? parentType,
  ) async {
    if (parentType == 'enquiry') {
      return _resolveEnquiryParentInfo(db, parentId);
    }
    // One `tasks` query covers both the probe and the display fields.
    final taskRows = await db.query(
      'tasks',
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (taskRows.isNotEmpty) {
      return _ActionParentInfo(
        parentType: parentType ?? 'task',
        found: true,
        clientName: taskRows.first['createdByName'] as String?,
        parentTitle: taskRows.first['title'] as String?,
      );
    }
    if (parentType == null) {
      // Not a task: only re-route to the module tables if the id is genuinely
      // an enquiry, else keep the historical 'task' default (orphan message).
      final probe = await _resolveEnquiryParentInfo(db, parentId);
      if (probe.found) return probe;
      return const _ActionParentInfo(parentType: 'task');
    }
    // Explicit parentType whose row isn't present yet: preserve the old insert
    // (that parentType, null display fields).
    return _ActionParentInfo(parentType: parentType);
  }

  /// Resolve an enquiry parent for the module actions tables. The shared Sales
  /// `enquiries` table is probed FIRST (the common module), then
  /// `crm_enquiries`; if the id is in neither the message still writes to
  /// sales_actions with null display fields ([_ActionParentInfo.found] == false).
  Future<_ActionParentInfo> _resolveEnquiryParentInfo(
    Database db,
    String parentId,
  ) async {
    final salesRows = await db.query(
      'enquiries',
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (salesRows.isNotEmpty) {
      return _ActionParentInfo(
        parentType: 'enquiry',
        found: true,
        clientName: salesRows.first['clientName'] as String?,
        parentTitle: salesRows.first['title'] as String?,
        teamId: salesRows.first['teamId'] as String?,
      );
    }
    final crmRows = await db.query(
      'crm_enquiries',
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (crmRows.isNotEmpty) {
      return _ActionParentInfo(
        parentType: 'enquiry',
        isCrm: true,
        found: true,
        clientName: crmRows.first['clientName'] as String?,
        parentTitle: crmRows.first['title'] as String?,
        teamId: crmRows.first['teamId'] as String?,
      );
    }
    return const _ActionParentInfo(parentType: 'enquiry');
  }

  /// Get all sales actions for a given team.
  Future<List<Map<String, dynamic>>> getSalesActions(
    String teamId, {
    String table = 'sales_actions',
    String? actionType,
    int? dateFrom,
    int? dateTo,
  }) async {
    final db = await database;
    final conditions = <String>['teamId = ?'];
    final args = <dynamic>[teamId];

    if (actionType != null) {
      conditions.add('actionType = ?');
      args.add(actionType);
    }
    if (dateFrom != null) {
      conditions.add('scheduledDate >= ?');
      args.add(dateFrom);
    }
    if (dateTo != null) {
      conditions.add('scheduledDate <= ?');
      args.add(dateTo);
    }

    return await db.query(
      table,
      where: conditions.join(' AND '),
      whereArgs: args,
      orderBy: 'createdAt DESC',
    );
  }

  /// Stream that re-queries a module's actions whenever [table] changes. The
  /// shared Sales/CRM Actions screen passes `_config.actionsTableName` so CRM
  /// reads crm_actions instead of sales_actions.
  Stream<List<Map<String, dynamic>>> watchSalesActions(
    String? teamId, {
    String table = 'sales_actions',
  }) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      if (teamId != null) {
        yield await getSalesActions(teamId, table: table);
      } else {
        // No team selected — return empty
        yield <Map<String, dynamic>>[];
      }
      // Debounced, mirroring the Task-module watchAllActions sibling: this is a
      // whole-team re-query, so a burst of action writes (message send/edit,
      // reply/done state updates, recovery write-through, sync landing) must
      // collapse into ONE re-query instead of one full table scan + grouped-list
      // rebuild per event. Raw tableChanges2 here saturated the UI isolate and
      // made Sales/CRM progressively lag then appear stuck after a few ops.
      await for (final _ in tableChangesDebounced(table)) {
        if (teamId != null) {
          yield await getSalesActions(teamId, table: table);
        } else {
          yield <Map<String, dynamic>>[];
        }
      }
    }).asBroadcastStream();
  }

  /// Batch-load last N action icons for multiple enquiry parents from sales_actions.
  Future<Map<String, List<Map<String, dynamic>>>> getSalesActionIconsForParents(
    List<String> parentIds, {
    int limit = 3,
  }) async {
    if (parentIds.isEmpty) return {};
    final db = await database;
    // Batch IN clause in chunks of 100 to avoid SQLite limits
    const batchSize = 100;
    final allRows = <Map<String, dynamic>>[];
    for (int i = 0; i < parentIds.length; i += batchSize) {
      final chunk = parentIds.sublist(
        i,
        i + batchSize > parentIds.length ? parentIds.length : i + batchSize,
      );
      final placeholders = chunk.map((_) => '?').join(',');
      final rows = await db.rawQuery(
        'SELECT parentId, actionType, isReplied, isDone, createdAt, id, text '
        'FROM sales_actions WHERE parentId IN ($placeholders) '
        'ORDER BY createdAt DESC',
        chunk,
      );
      allRows.addAll(rows);
    }
    final result = <String, List<Map<String, dynamic>>>{};
    final counts = <String, int>{};
    for (final row in allRows) {
      final pid = row['parentId'] as String;
      final count = counts[pid] ?? 0;
      if (count >= limit) continue;
      counts[pid] = count + 1;
      result.putIfAbsent(pid, () => []).add(row);
    }
    for (final entry in result.entries.toList()) {
      result[entry.key] = entry.value.reversed.toList();
    }
    return result;
  }

  /// Update action state (isReplied, isDone) in sales_actions when a message is updated.
  Future<void> updateSalesActionState(
    String messageId, {
    bool? isReplied,
    bool? isDone,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{};
    if (isReplied != null) updates['isReplied'] = isReplied ? 1 : 0;
    if (isDone != null) updates['isDone'] = isDone ? 1 : 0;
    if (updates.isEmpty) return;
    await db.update(
      'sales_actions',
      updates,
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notify('sales_actions');
  }

  /// Backfill sales_actions from existing shared actions table rows where parentType = 'enquiry'.
  /// Called once during v9 migration.
  Future<void> _backfillSalesActionsFromShared(Database db) async {
    // Get all enquiry actions from the shared table
    final enquiryActions = await db.query(
      'actions',
      where: "parentType = 'enquiry'",
    );
    if (enquiryActions.isEmpty) return;

    // Bulk-load teamIds from enquiries table
    final enquiryIds = enquiryActions
        .map((r) => r['parentId'] as String)
        .toSet();
    final placeholders = enquiryIds.map((_) => '?').join(',');
    final enquiryRows = await db.rawQuery(
      'SELECT id, teamId FROM enquiries WHERE id IN ($placeholders)',
      enquiryIds.toList(),
    );
    final teamIdMap = <String, String?>{};
    for (final row in enquiryRows) {
      teamIdMap[row['id'] as String] = row['teamId'] as String?;
    }

    final batch = db.batch();
    for (final action in enquiryActions) {
      final parentId = action['parentId'] as String;
      batch.insert('sales_actions', {
        'id': action['id'],
        'parentId': parentId,
        'teamId': teamIdMap[parentId],
        'actionType': action['actionType'],
        'text': action['text'],
        'senderId': action['senderId'],
        'createdAt': action['createdAt'],
        'scheduledDate': action['scheduledDate'],
        'isReplied': action['isReplied'],
        'isDone': action['isDone'],
        'clientName': action['clientName'],
        'parentTitle': action['parentTitle'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    if (enquiryActions.isNotEmpty) _notify('sales_actions');
  }

  MessageModel _messageFromRow(Map<String, dynamic> row) {
    return MessageModel(
      id: row['id'] as String,
      taskId: row['taskId'] as String,
      senderId: row['senderId'] as String,
      text: row['text'] as String? ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.name == row['type'],
        orElse: () => MessageType.text,
      ),
      fileUrl: row['fileUrl'] as String?,
      fileName: row['fileName'] as String?,
      duration: row['duration'] as int?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
      searchableContent: row['searchableContent'] as String?,
      deliveryMethod: row['deliveryMethod'] as String?,
      isEdited: (row['isEdited'] as int) == 1,
      deleted: (row['deleted'] as int) == 1,
      deletedFor: _decodeStringList(row['deletedFor'] as String?),
      downloadedBy: _decodeMapStringBool(row['downloadedBy'] as String?),
      deliveredAt: row['deliveredAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deliveredAt'] as int)
          : null,
      deliveredTo: _decodeMapStringDateTime(row['deliveredTo'] as String?),
      readBy: _decodeMapStringDateTime(row['readBy'] as String?),
      systemType: SystemMessageType.values.firstWhere(
        (e) => e.name == row['systemType'],
        orElse: () => SystemMessageType.regular,
      ),
      sequenceNumber: row['sequenceNumber'] as int?,
      queryReply: row['queryReply'] as String?,
      repliedBy: row['repliedBy'] as String?,
      repliedAt: row['repliedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['repliedAt'] as int)
          : null,
      isReplied: (row['isReplied'] as int) == 1,
      isFollowUpDone: (row['isFollowUpDone'] as int) == 1,
      followUpDoneBy: row['followUpDoneBy'] as String?,
      followUpDoneAt: row['followUpDoneAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['followUpDoneAt'] as int)
          : null,
      replyToMessageId: row['replyToMessageId'] as String?,
      replyToMessageText: row['replyToMessageText'] as String?,
      replyToMessageSender: row['replyToMessageSender'] as String?,
      uploadError: row['uploadError'] as String?,
    );
  }

  Map<String, dynamic> _messageToRow(MessageModel message) {
    final row = <String, dynamic>{
      'id': message.id,
      'taskId': message.taskId,
      'senderId': message.senderId,
      'text': message.text,
      'type': message.type.name,
      'fileUrl': message.fileUrl,
      'fileName': message.fileName,
      'duration': message.duration,
      'createdAt': message.createdAt.millisecondsSinceEpoch,
      'searchableContent': message.searchableContent,
      'deliveryMethod': message.deliveryMethod,
      'isEdited': message.isEdited ? 1 : 0,
      'deleted': message.deleted ? 1 : 0,
      'deletedFor': jsonEncode(message.deletedFor),
      'downloadedBy': message.downloadedBy != null
          ? jsonEncode(message.downloadedBy)
          : null,
      'deliveredAt': message.deliveredAt?.millisecondsSinceEpoch,
      'deliveredTo': message.deliveredTo != null
          ? jsonEncode(
              message.deliveredTo!.map(
                (k, v) => MapEntry(k, v.millisecondsSinceEpoch),
              ),
            )
          : null,
      'readBy': message.readBy != null
          ? jsonEncode(
              message.readBy!.map(
                (k, v) => MapEntry(k, v.millisecondsSinceEpoch),
              ),
            )
          : null,
      'systemType': message.systemType.name,
      'sequenceNumber': message.sequenceNumber,
      'queryReply': message.queryReply,
      'repliedBy': message.repliedBy,
      'repliedAt': message.repliedAt?.millisecondsSinceEpoch,
      'isReplied': message.isReplied ? 1 : 0,
      'isFollowUpDone': message.isFollowUpDone ? 1 : 0,
      'followUpDoneBy': message.followUpDoneBy,
      'followUpDoneAt': message.followUpDoneAt?.millisecondsSinceEpoch,
      'replyToMessageId': message.replyToMessageId,
      'replyToMessageText': message.replyToMessageText,
      'replyToMessageSender': message.replyToMessageSender,
      'uploadError': message.uploadError,
    };
    // Derived locally, never sent to Firestore and never read back into the
    // model — see [_messageChangeKey].
    row['changeKey'] = _messageChangeKey(row);
    return row;
  }

  /// Columns whose value can change AFTER a message was first written. The rest
  /// (id, taskId, senderId, type, systemType, deliveryMethod, createdAt) are
  /// immutable, so leaving them out keeps the fingerprint short without losing
  /// a change.
  static const List<String> _kMessageChangeKeyColumns = [
    'text',
    'fileUrl',
    'fileName',
    'duration',
    'searchableContent',
    'isEdited',
    'deleted',
    'deletedFor',
    'downloadedBy',
    'deliveredAt',
    'deliveredTo',
    'readBy',
    'sequenceNumber',
    'queryReply',
    'repliedBy',
    'repliedAt',
    'isReplied',
    'isFollowUpDone',
    'followUpDoneBy',
    'followUpDoneAt',
    'uploadError',
    'replyToMessageId',
    'replyToMessageText',
    'replyToMessageSender',
  ];

  /// Fingerprint of a message row's mutable part, stored in the `changeKey`
  /// column so [saveMessages] can tell "unchanged" from "changed" by reading one
  /// narrow column instead of the whole row.
  ///
  /// \u0001 separates fields so a value can never be confused with its
  /// neighbour's start (message text is arbitrary), and \u0002 stands in for
  /// NULL so a null → '' transition still counts as a change. Both are non-NUL
  /// control characters, which SQLite TEXT handles safely.
  String _messageChangeKey(Map<String, dynamic> row) {
    final buf = StringBuffer();
    for (var i = 0; i < _kMessageChangeKeyColumns.length; i++) {
      if (i > 0) buf.write('\u0001');
      final v = row[_kMessageChangeKeyColumns[i]];
      buf.write(v == null ? '\u0002' : v.toString());
    }
    return buf.toString();
  }

  // ── Enquiries ─────────────────────────────────────────────────────────────

  /// Save or update an enquiry in local DB
  Future<void> saveEnquiry(EnquiryModel enquiry) async {
    final db = await database;

    // Skip write if enquiry hasn't changed (compare updatedAt)
    final existing = await db.query(
      'enquiries',
      columns: ['updatedAt'],
      where: 'id = ?',
      whereArgs: [enquiry.id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final existingUpdatedAt = existing.first['updatedAt'] as int?;
      if (existingUpdatedAt == enquiry.updatedAt.millisecondsSinceEpoch) {
        return; // Unchanged — skip write
      }
    }

    await db.insert(
      'enquiries',
      enquiryToRow(enquiry),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify('enquiries', ids: {enquiry.id});
  }

  /// Delete an enquiry
  Future<void> deleteEnquiry(String enquiryId) async {
    final db = await database;
    await db.delete('enquiries', where: 'id = ?', whereArgs: [enquiryId]);
    _notify('enquiries', ids: {enquiryId}, kind: ChangeKind.delete);
  }

  /// Fetch one module enquiry (sales/CRM) from SQLite by id. Used to reload
  /// the persisted row after create (milestones applied inside the provider).
  Future<EnquiryModel?> getModuleEnquiryById(
    String id, {
    required String tableName,
  }) async {
    final db = await database;
    final rows = await db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return enquiryFromRow(rows.first);
  }

  EnquiryModel enquiryFromRow(Map<String, dynamic> row) {
    return EnquiryModel(
      id: row['id'] as String,
      title: row['title'] as String? ?? '',
      clientName: row['clientName'] as String? ?? '',
      clientPhone: row['clientPhone'] as String?,
      clientEmail: row['clientEmail'] as String?,
      clientAddress: row['clientAddress'] as String?,
      clientCompany: row['clientCompany'] as String?,
      description: row['description'] as String? ?? '',
      createdBy: row['createdBy'] as String? ?? '',
      createdByName: row['createdByName'] as String?,
      createdByPhone: row['createdByPhone'] as String?,
      assignedTo: row['assignedTo'] as String? ?? '',
      assignedToUid: row['assignedToUid'] as String?,
      assignedToPhone: row['assignedToPhone'] as String?,
      participants: _decodeStringList(row['participants'] as String?),
      status: (row['status'] as String?) ?? 'active',
      milestones: _decodeMilestones(row['milestones'] as String?),
      priority: row['priority'] as int? ?? 2,
      isUrgent: (row['isUrgent'] as int) == 1,
      deadline: row['deadline'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deadline'] as int)
          : null,
      progress: (row['progress'] as num).toDouble(),
      tags: _decodeStringList(row['tags'] as String?),
      category: row['category'] as String?,
      extraFields: _decodeMap(row['extraFields'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updatedAt'] as int),
      isClosed: (row['isClosed'] as int) == 1,
      rating: row['rating'] as int?,
      lastMessageText: row['lastMessageText'] as String?,
      lastMessageTime: row['lastMessageTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['lastMessageTime'] as int)
          : null,
      unreadCounts: _decodeMapStringInt(row['unreadCounts'] as String?),
      teamId: row['teamId'] as String?,
      displayId: row['displayId'] as int?,
      isArchived: (row['isArchived'] as int?) == 1,
      archivedAt: row['archivedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['archivedAt'] as int)
          : null,
      archivedBy: row['archivedBy'] as String?,
      isDeleted: (row['isDeleted'] as int?) == 1,
      deletedAt: row['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deletedAt'] as int)
          : null,
      deletedBy: row['deletedBy'] as String?,
      recurrence: row['recurrence'] as String?,
      seriesId: row['seriesId'] as String?,
      nextDue: row['nextDue'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['nextDue'] as int)
          : null,
    );
  }

  Map<String, dynamic> enquiryToRow(EnquiryModel enquiry) {
    return {
      'id': enquiry.id,
      'title': enquiry.title,
      ...enquiry.customerInfo.toRow(),
      'description': enquiry.description,
      'createdBy': enquiry.createdBy,
      'createdByName': enquiry.createdByName,
      'createdByPhone': enquiry.createdByPhone,
      'assignedTo': enquiry.assignedTo,
      'assignedToUid': enquiry.assignedToUid,
      'assignedToPhone': enquiry.assignedToPhone,
      'participants': jsonEncode(
        participantsUnion(
          enquiry.participants,
          createdBy: enquiry.createdBy,
          assignedToUid: enquiry.assignedToUid,
          extraFields: enquiry.extraFields,
        ),
      ),
      'status': enquiry.status,
      'milestones': jsonEncode(
        enquiry.milestones.map((m) => m.toMap()).toList(),
      ),
      'priority': enquiry.priority,
      'isUrgent': enquiry.isUrgent ? 1 : 0,
      'deadline': enquiry.deadline?.millisecondsSinceEpoch,
      'progress': enquiry.progress,
      'tags': jsonEncode(enquiry.tags),
      'category': enquiry.category,
      'extraFields': enquiry.extraFields != null
          ? jsonEncode(enquiry.extraFields)
          : null,
      'createdAt': enquiry.createdAt.millisecondsSinceEpoch,
      'updatedAt': enquiry.updatedAt.millisecondsSinceEpoch,
      'isClosed': enquiry.isClosed ? 1 : 0,
      'rating': enquiry.rating,
      'lastMessageText': enquiry.lastMessageText,
      'lastMessageTime': enquiry.lastMessageTime?.millisecondsSinceEpoch,
      'unreadCounts': jsonEncode(enquiry.unreadCounts),
      'teamId': enquiry.teamId,
      'displayId': enquiry.displayId,
      'isArchived': enquiry.isArchived ? 1 : 0,
      'archivedAt': enquiry.archivedAt?.millisecondsSinceEpoch,
      'archivedBy': enquiry.archivedBy,
      'isDeleted': enquiry.isDeleted ? 1 : 0,
      'deletedAt': enquiry.deletedAt?.millisecondsSinceEpoch,
      'deletedBy': enquiry.deletedBy,
      'recurrence': enquiry.recurrence,
      'seriesId': enquiry.seriesId,
      'nextDue': enquiry.nextDue?.millisecondsSinceEpoch,
    };
  }

  // ── JSON Helpers ──────────────────────────────────────────────────────────

  List<String> _decodeStringList(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      return List<String>.from(jsonDecode(json));
    } catch (_) {
      return [];
    }
  }

  Map<String, bool>? _decodeMapStringBool(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return Map<String, bool>.from(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  Map<String, DateTime>? _decodeMapStringDateTime(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(json));
      return decoded.map(
        (k, v) => MapEntry(k, DateTime.fromMillisecondsSinceEpoch(v as int)),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, int> _decodeMapStringInt(String? json) {
    if (json == null || json.isEmpty) return {};
    try {
      return Map<String, int>.from(jsonDecode(json));
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic>? _decodeMap(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  List<MilestoneModel> _decodeMilestones(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      // De-duplicate by resolved id: legacy double-applied templates left some
      // enquiries carrying the same step many times (see MilestoneModel.dedupeById).
      return MilestoneModel.dedupeById(
        list.asMap().entries.map((entry) {
          final m = entry.value;
          final mMap = Map<String, dynamic>.from(m);
          final mId = (m['id'] != null && (m['id'] as String).isNotEmpty)
              ? m['id'] as String
              : 'milestone_${m['order'] ?? entry.key}';
          return MilestoneModel.fromMap(mMap, mId);
        }).toList(),
      );
    } catch (_) {
      return [];
    }
  }

  // ── Session Lifecycle ─────────────────────────────────────────────────

  /// Wipe every row from every table (called on sign-out).
  ///
  /// The local DB is a device-global cache and several reads (e.g. the
  /// Actions tab, cached users/team members) are not scoped per account,
  /// so leaving it populated would leak one account's tasks, messages and
  /// assignees into the next account signed in on this device. Delta-sync
  /// watermarks are derived from table contents, so wiping also forces a
  /// full re-sync for the next user.
  Future<void> clearSessionData() async {
    try {
      final db = await database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
      );
      final batch = db.batch();
      for (final row in tables) {
        batch.rawDelete('DELETE FROM "${row['name']}"');
      }
      await batch.commit(noResult: true);
      // Let live listeners re-query so on-screen lists empty out.
      for (final row in tables) {
        _notify(row['name'] as String);
      }
      print('[LocalDB] Session data cleared (${tables.length} tables)');
      // Sign-out is the largest bulk delete the app ever performs — every table
      // goes empty while the file keeps its size. Reclaim it in the background.
      unawaited(vacuumIfFragmented(minFreePages: 128));
    } catch (e) {
      print('[LocalDB] Error clearing session data: $e');
    }
  }

  // ── Tasks ──────────────────────────────────────────────────────────────

  /// Get all tasks for a user (created by or assigned to) from local DB
  Future<List<TaskModel>> getTasks(String userId) async {
    // Shared snapshot: every always-mounted tab that needs the full task list
    // reads through here, so memoize on the tasks-table revision and skip the
    // scan + deserialize when nothing changed.
    const table = 'tasks';
    final cacheKey = '$table\u0000$userId';
    final cached = _readSnapshot<TaskModel>(cacheKey, table);
    if (cached != null) return cached;
    final rev = revisionOf(table);
    final tr = StartupTrace.instance.begin('getTasks', caller: 'getTasks');
    final w = SyncTelemetry.instance.startTimer();
    final db = await database;
    // Also match tasks where the user is a secondary assignee: those carry the
    // user only inside the JSON-encoded `participants` array (createdBy is the
    // creator and the primary assignedToUid may be empty/another person).
    final results = await db.rawQuery(
      'SELECT * FROM tasks WHERE createdBy = ? OR assignedToUid = ? OR participants LIKE ? ORDER BY updatedAt DESC',
      [userId, userId, '%"$userId"%'],
    );
    final tDecode = StartupTrace.instance.begin(
      'getTasks:decode',
      kind: StartupTraceKind.ui,
      caller: 'getTasks',
    );
    final out = results.map((row) => taskFromRow(row)).toList();
    StartupTrace.instance.end(tDecode, rows: out.length);
    SyncTelemetry.instance.recordDb('getTasks', w, out.length);
    StartupTrace.instance.end(tr, rows: out.length);
    _writeSnapshot<TaskModel>(cacheKey, rev, out);
    return List<TaskModel>.of(out);
  }

  /// Change-set (4.1) reader: fetch ONLY the given task ids that still match
  /// [userId]'s list filter (createdBy / assignedToUid / participants), newest
  /// first — the same predicate as [getTasks]. Ids absent from the result were
  /// deleted or no longer belong to this user, so the consumer removes them
  /// from its in-memory lists instead of re-scanning every task. One reader,
  /// common to the shared change-set consumer.
  Future<List<TaskModel>> getTasksByIds(String userId, Set<String> ids) async {
    if (ids.isEmpty) return const <TaskModel>[];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final results = await db.rawQuery(
      'SELECT * FROM tasks WHERE id IN ($placeholders) '
      'AND (createdBy = ? OR assignedToUid = ? OR participants LIKE ?) '
      'ORDER BY updatedAt DESC',
      [...ids, userId, userId, '%"$userId"%'],
    );
    return results.map((row) => taskFromRow(row)).toList();
  }

  /// Get tasks with pagination (lazy loading)
  Future<List<TaskModel>> getTasksPaginated(
    String userId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT * FROM tasks WHERE createdBy = ? OR assignedToUid = ? OR participants LIKE ? ORDER BY updatedAt DESC LIMIT ? OFFSET ?',
      [userId, userId, '%"$userId"%', limit, offset],
    );
    return results.map((row) => taskFromRow(row)).toList();
  }

  /// Get total count of tasks for pagination
  Future<int> getTaskCount(String userId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM tasks WHERE createdBy = ? OR assignedToUid = ? OR participants LIKE ?',
      [userId, userId, '%"$userId"%'],
    );
    return result.first['count'] as int? ?? 0;
  }

  /// Count active tasks/enquiries for a user.
  ///
  /// [module] is one of: task, sale, crm, inventory.
  /// [asCreator] true counts items created by [userId]; false counts items
  /// assigned to [userId] (or, for tasks only, where [userId] appears in
  /// participants).
  ///
  /// Active means not completed, cancelled or deleted. The exact SQL filter
  /// depends on the module's table schema so the count stays fast (local
  /// indexed query, no Firestore round-trip).
  ///
  /// The queries are written to use the composite active indexes added in
  /// DB version 17:
  ///   * tasks: (createdBy/assignedToUid, isDeleted, isCancelled, isClosed)
  ///   * enquiries / crm_enquiries: (createdBy/assignedToUid, isClosed, status)
  Future<int> countActiveTasks({
    required String userId,
    bool asCreator = true,
    String module = 'task',
    String? creatorId,
  }) async {
    if (userId.isEmpty) return 0;
    final db = await database;

    String table;
    String activeFilter;
    bool hasParticipants;
    switch (module.toLowerCase()) {
      case 'task':
        table = 'tasks';
        activeFilter =
            'isDeleted = 0 AND isCancelled = 0 AND isClosed = 0 AND isArchived = 0';
        hasParticipants = true;
        break;
      case 'sale':
        table = 'enquiries';
        activeFilter =
            "isDeleted = 0 AND isClosed = 0 AND isArchived = 0 AND status NOT IN ('success','lost','dropped','cancel')";
        hasParticipants = false;
        break;
      case 'crm':
        table = 'crm_enquiries';
        // Escalated is a working state, not a resolution — it stays active
        // (mirrors ModuleConfig.crm.openStatusNames counting it as open).
        activeFilter =
            "isDeleted = 0 AND isClosed = 0 AND isArchived = 0 AND status NOT IN ('resolved','closed')";
        hasParticipants = false;
        break;
      case 'inventory':
        // Inventory module is not implemented yet; return 0 so it never blocks.
        return 0;
      default:
        table = 'tasks';
        activeFilter =
            'isDeleted = 0 AND isCancelled = 0 AND isClosed = 0 AND isArchived = 0';
        hasParticipants = true;
    }

    // Per-creator scoping: when counting cards assigned TO [userId], restrict
    // to cards created by [creatorId] ("N per creator" plan limits).
    final creatorClause = (!asCreator && (creatorId ?? '').isNotEmpty)
        ? ' AND createdBy = ?'
        : '';
    final creatorArgs = (!asCreator && (creatorId ?? '').isNotEmpty)
        ? [creatorId!]
        : <String>[];

    if (asCreator) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table WHERE createdBy = ? AND $activeFilter',
        [userId],
      );
      return (result.first['c'] as int?) ?? 0;
    }

    // Enquiries / CRM only have a primary assignee locally; there is no
    // participants column in those tables. Keep this a single indexed lookup.
    if (!hasParticipants) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table WHERE assignedToUid = ? AND $activeFilter$creatorClause',
        [userId, ...creatorArgs],
      );
      return (result.first['c'] as int?) ?? 0;
    }

    // Tasks: split the count so the primary-assignee path uses the composite
    // index. The participant-only path is a full scan (LIKE with leading
    // wildcard cannot use a B-tree index), but only runs for tasks where the
    // user is a secondary participant.
    final assignedResult = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table WHERE assignedToUid = ? AND $activeFilter$creatorClause',
      [userId, ...creatorArgs],
    );
    final participantResult = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table WHERE '
      "participants LIKE ? AND COALESCE(assignedToUid, '') != ? AND $activeFilter$creatorClause",
      ['%"$userId"%', userId, ...creatorArgs],
    );
    return ((assignedResult.first['c'] as int?) ?? 0) +
        ((participantResult.first['c'] as int?) ?? 0);
  }

  /// Zero the current user's unread count on a row directly — any table with
  /// an `unreadCounts` column (tasks, enquiries, crm_enquiries). Needed because
  /// the Firestore unread-reset doesn't bump updatedAt, so watermarked sync
  /// won't echo it back — the badge must clear locally. Common to all modules.
  Future<void> resetUnreadCountLocal(
    String tableName,
    String itemId,
    String userId,
  ) async {
    final db = await database;
    final rows = await db.query(
      tableName,
      columns: ['unreadCounts'],
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final counts = _decodeMapStringInt(rows.first['unreadCounts'] as String?);
    if ((counts[userId] ?? 0) == 0) return; // Already clear — skip write
    counts[userId] = 0;
    await db.update(
      tableName,
      {'unreadCounts': jsonEncode(counts)},
      where: 'id = ?',
      whereArgs: [itemId],
    );
    _notify(tableName, ids: {itemId});
  }

  /// Decrement per-user unread counts (floored at 0) on a row — the undo
  /// counterpart of [resetUnreadCountLocal]. Reversing the badge a just-sent
  /// action card raised must land in SQLite too: the Firestore decrement
  /// rides an `updatedAt` bump so it syncs to RECIPIENTS, but this device's
  /// own copy of the map would otherwise keep the card counted.
  Future<void> decrementUnreadCountsLocal(
    String tableName,
    String itemId,
    Iterable<String> userIds,
  ) async {
    final db = await database;
    final rows = await db.query(
      tableName,
      columns: ['unreadCounts'],
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final counts = _decodeMapStringInt(rows.first['unreadCounts'] as String?);
    var changed = false;
    for (final uid in userIds) {
      final c = counts[uid] ?? 0;
      if (c > 0) {
        counts[uid] = c - 1;
        changed = true;
      }
    }
    if (!changed) return; // Nothing counted — skip write
    await db.update(
      tableName,
      {'unreadCounts': jsonEncode(counts)},
      where: 'id = ?',
      whereArgs: [itemId],
    );
    _notify(tableName, ids: {itemId});
  }

  /// Columns that decide WHICH list a row belongs to (Assignee vs My Tasks)
  /// plus the last-message preview only this device tracks. An offline
  /// Firestore *cache* snapshot can carry them blank/partial, and INSERT OR
  /// REPLACE then wiped the good local values — the task silently dropped out
  /// of the Assignee tab until a restart re-synced it. Local-first rule: a
  /// blank incoming value never overwrites a known local one.
  static const List<String> _keepLocalWhenBlank = [
    'createdBy',
    'createdByName',
    'createdByPhone',
    'assignedTo',
    'assignedToUid',
    'assignedToPhone',
    'lastMessageText',
    'lastMessageTime',
  ];

  /// Copies stored values back over blank incoming ones (see
  /// [_keepLocalWhenBlank]). Only touches keys present in both maps, so the
  /// module enquiry tables (different column sets) stay safe.
  /// [clearAssignee] marks an INTENTIONAL unassign (creator removed the last
  /// assignee / access revoked): the emptied assignee name/uid/phone must
  /// reach the row instead of being reverted to the stored assignee — same
  /// bypass as `clearAssignee` in FirebaseService.updateTask.
  Map<String, dynamic> _mergeLocalFirst(
    Map<String, dynamic> row,
    Map<String, dynamic> existing, {
    bool clearAssignee = false,
  }) {
    for (final field in _keepLocalWhenBlank) {
      if (clearAssignee &&
          (field == 'assignedTo' ||
              field == 'assignedToUid' ||
              field == 'assignedToPhone')) {
        continue;
      }
      if (!row.containsKey(field) || !existing.containsKey(field)) continue;
      final incoming = row[field];
      final stored = existing[field];
      final incomingBlank =
          incoming == null || (incoming is String && incoming.isEmpty);
      final storedBlank =
          stored == null || (stored is String && stored.isEmpty);
      if (incomingBlank && !storedBlank) row[field] = stored;
    }
    return row;
  }

  /// Insert/replace a row unless the stored copy is already at least as new
  /// (skip-if-unchanged AND skip-if-stale, avoids spurious change events).
  /// Shared by tasks (base) and the module enquiry tables — rows must carry
  /// 'id' and 'updatedAt'. [clearAssignee] honors an intentional unassign
  /// through the local-first merge (see [_mergeLocalFirst]).
  Future<void> _upsertRowIfChanged(
    String table,
    Map<String, dynamic> row, {
    bool clearAssignee = false,
  }) async {
    final db = await database;
    final existing = await db.query(
      table,
      where: 'id = ?',
      whereArgs: [row['id']],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final stored = existing.first;
      final existingUpdatedAt = stored['updatedAt'] as int?;
      final incomingUpdatedAt = row['updatedAt'] as int?;
      // Direction check: equality-only let a cache snapshot whose pending
      // serverTimestamp read as now() replace the local row every emission.
      if (existingUpdatedAt != null &&
          incomingUpdatedAt != null &&
          incomingUpdatedAt <= existingUpdatedAt) {
        return; // Unchanged or stale — skip write
      }
      row = _mergeLocalFirst(row, stored, clearAssignee: clearAssignee);
    }
    await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    // Change-set (4.1): the row's own id, so a consumer patches one row in
    // memory instead of re-scanning. Common to tasks + every module enquiry
    // table (saveTask / saveModuleEnquiry both delegate here).
    _notify(table, ids: {row['id'].toString()});
  }

  /// Batch variant of [_upsertRowIfChanged]: batch-reads the stored rows in one
  /// query and only writes rows that are newer, with the same local-first
  /// field merge.
  Future<void> _upsertRowsIfChanged(
    String table,
    List<Map<String, dynamic>> rows, {
    String? caller,
  }) async {
    if (rows.isEmpty) return;
    final db = await database;
    final ids = rows.map((r) => "'${r['id']}'").join(',');
    final existingRows = await db.rawQuery(
      'SELECT * FROM $table WHERE id IN ($ids)',
    );
    final existingById = {
      for (final row in existingRows) row['id'] as String: row,
    };
    final toWrite = <Map<String, dynamic>>[];
    for (final row in rows) {
      final stored = existingById[row['id'] as String];
      if (stored == null) {
        toWrite.add(row); // New on this device — insert
        continue;
      }
      final existingUpdatedAt = stored['updatedAt'] as int?;
      final incomingUpdatedAt = row['updatedAt'] as int?;
      if (existingUpdatedAt != null &&
          incomingUpdatedAt != null &&
          incomingUpdatedAt <= existingUpdatedAt) {
        continue; // Unchanged or stale — skip write to avoid a change event
      }
      toWrite.add(_mergeLocalFirst(row, stored));
    }
    if (toWrite.isEmpty) return; // Nothing changed — no write, no notify
    final batch = db.batch();
    for (final row in toWrite) {
      batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final tTx = StartupTrace.instance.begin(
      'db.tx:$table',
      kind: StartupTraceKind.tx,
      caller: caller ?? table,
    );
    await batch.commit(noResult: true);
    StartupTrace.instance.end(tTx, rows: toWrite.length);
    // Change-set (4.1): only the rows actually written (stale/unchanged were
    // skipped above), so a consumer patches exactly what changed. Common to
    // tasks + every module enquiry table (saveTasks / saveModuleEnquiries).
    _notify(table, ids: toWrite.map((r) => r['id'].toString()).toSet());
  }

  /// Delete a row by id and notify — shared by tasks and module tables.
  Future<void> _deleteRowById(String table, String id) async {
    final db = await database;
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
    _notify(table, ids: {id}, kind: ChangeKind.delete);
  }

  /// Delete many rows by id in a single statement and notify once (empty list
  /// is a no-op). Used by the participant sync to drop every task/enquiry the
  /// local user was just removed from in one snapshot, so the list reloads a
  /// single time instead of once per row.
  Future<void> _deleteRowsByIds(String table, List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.generate(ids.length, (_) => '?').join(',');
    await db.delete(table, where: 'id IN ($placeholders)', whereArgs: ids);
    _notify(table, ids: ids.toSet(), kind: ChangeKind.delete);
  }

  // ── Recurrence (Phase-2A) ────────────────────────────────────────────────
  // Bounded, index-backed helpers for the shared RecurrenceService. Common to
  // all three work-item tables; the partial indexes on nextDue/seriesId keep
  // these cheap while recurrence is unused.

  /// Series anchors whose next occurrence falls at or before [horizonEndMs].
  /// Uses the partial idx_<table>_nextDue index and returns full rows so the
  /// caller can clone each anchor into an occurrence. Bounded by [limit].
  Future<List<Map<String, dynamic>>> dueRecurrenceAnchors(
    String table,
    int horizonEndMs, {
    int limit = 100,
  }) async {
    final db = await database;
    return db.query(
      table,
      where: 'nextDue IS NOT NULL AND nextDue <= ? AND isDeleted = 0',
      whereArgs: [horizonEndMs],
      limit: limit,
    );
  }

  /// Ids of every row already materialized for [seriesId] — one indexed lookup
  /// per due series, used to make materialization idempotent.
  Future<Set<String>> seriesOccurrenceIds(String table, String seriesId) async {
    final db = await database;
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'seriesId = ?',
      whereArgs: [seriesId],
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// Advance a series anchor after materialization: persist the updated rule
  /// (generatedUntil) + nextDue and emit the change-set notify so the anchor's
  /// card patches in place instead of a full reload.
  Future<void> advanceRecurrenceAnchor(
    String table,
    String id,
    String recurrenceJson,
    int? nextDueMs,
  ) async {
    final db = await database;
    await db.update(
      table,
      {
        'recurrence': recurrenceJson,
        'nextDue': nextDueMs,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify(table, ids: {id});
  }

  /// Phase-2B migration source: rows still carrying a LEGACY completion-driven
  /// rule in `extraFields['recurrence']` with no new-engine column. Bounded by
  /// [limit] and self-draining — the migration writes a non-null `recurrence`
  /// and strips the legacy key, so converted rows never match again. The
  /// `LIKE '%"recurrence"%'` filter is unindexed but cheap and runs at most
  /// once per launch, off the startup critical path.
  Future<List<Map<String, dynamic>>> legacyRecurrenceCandidates(
    String table, {
    int limit = 100,
  }) async {
    final db = await database;
    return db.query(
      table,
      where:
          'recurrence IS NULL AND seriesId IS NULL AND isDeleted = 0 '
          'AND extraFields LIKE ?',
      whereArgs: ['%"recurrence"%'],
      limit: limit,
    );
  }

  /// Persist a migrated recurrence anchor: the new-engine columns plus the
  /// cleaned `extraFields` (legacy key removed), then emit the change-set notify
  /// so any open card patches in place. `updatedAt` is bumped so the row relays.
  Future<void> applyRecurrenceMigration(
    String table,
    String id, {
    String? recurrence,
    String? seriesId,
    int? nextDue,
    String? extraFields,
  }) async {
    final db = await database;
    await db.update(
      table,
      {
        'recurrence': recurrence,
        'seriesId': seriesId,
        'nextDue': nextDue,
        'extraFields': extraFields,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify(table, ids: {id});
  }

  /// Save or update a task in local DB. [clearAssignee] honors an intentional
  /// unassign through the local-first merge (see [_mergeLocalFirst]).
  Future<void> saveTask(TaskModel task, {bool clearAssignee = false}) =>
      _upsertRowIfChanged(
        'tasks',
        taskToRow(task),
        clearAssignee: clearAssignee,
      );

  /// Save multiple tasks in a batch (only writes changed tasks)
  Future<void> saveTasks(List<TaskModel> tasks) async {
    final w = SyncTelemetry.instance.startTimer();
    await _upsertRowsIfChanged(
      'tasks',
      tasks.map(taskToRow).toList(),
      caller: 'saveTasks',
    );
    SyncTelemetry.instance.recordDb('saveTasks', w, tasks.length);
  }

  /// Delete a task by ID (explicit user action only)
  Future<void> deleteTask(String taskId) => _deleteRowById('tasks', taskId);

  /// Bulk-delete tasks by id — used by the participant sync to drop the rows
  /// the local user was just removed from as an assignee.
  Future<void> removeTasksByIds(List<String> ids) =>
      _deleteRowsByIds('tasks', ids);

  /// Local-only transform applied when the participant sync sees a task LEAVE
  /// the user's `arrayContains(participants)` result set (i.e. they were just
  /// removed as an assignee). The card must STAY visible but read as
  /// "Unassigned" and be frozen: blank the assignee name/uid/phone and the
  /// assignee identity fields, and stamp `accessRevoked` so the composer goes
  /// read-only. Crucially the local `participants` list is left untouched — it
  /// still contains the removed uid, which is exactly what keeps the row
  /// matching `getTasks`' participants predicate after the server has stopped
  /// delivering it (the rules deny the read, so this local row is the last
  /// snapshot they legitimately hold and no server write can correct it).
  Future<void> markTaskAccessRevoked(String taskId) async {
    final task = await getTaskById(taskId);
    if (task == null) return;
    if (task.extraFields?['accessRevoked'] == true) return; // idempotent
    final updated = task.copyWith(
      assignedTo: '',
      assignedToUid: '',
      clearAssigneePhone: true,
      // Bump the watermark: the row's content changes locally (freeze +
      // blanking) while the stored copy keeps the old updatedAt, and
      // _upsertRowIfChanged would otherwise skip the write as "unchanged".
      updatedAt: DateTime.now(),
      extraFields: {
        ...?task.extraFields,
        'accessRevoked': true,
        'assigneeUids': <String>[],
        'assigneeNames': <String>[],
        'participantNames': <String>[],
        'assigneePhones': <String>[],
        'assigneePhone': '',
      },
    );
    await saveTask(updated, clearAssignee: true);
  }

  /// Purge soft-deleted rows older than [daysThreshold] days from any table
  /// carrying the isDeleted/deletedAt soft-delete columns (tasks, enquiries,
  /// crm_enquiries). Returns the number of rows purged. Shared so every module
  /// ages out its Deleted view identically.
  Future<int> purgeDeletedRows(String table, {int daysThreshold = 30}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: daysThreshold))
        .millisecondsSinceEpoch;
    final count = await db.delete(
      table,
      where: 'isDeleted = 1 AND deletedAt IS NOT NULL AND deletedAt < ?',
      whereArgs: [cutoff],
    );
    if (count > 0) {
      print(
        '[LocalDB] Purged $count soft-deleted $table rows older than $daysThreshold days',
      );
      _notify(table);
      // Bulk deletes leave the pages on SQLite's freelist — the file keeps its
      // size forever unless something reclaims it. Fire-and-forget: VACUUM
      // rewrites the whole file, so it must never block the caller (this runs
      // from provider maintenance), and it self-skips when the freelist is
      // too small to be worth the I/O.
      unawaited(vacuumIfFragmented());
    }
    return count;
  }

  /// Purge soft-deleted tasks older than [daysThreshold] days.
  /// Returns the number of tasks purged.
  Future<int> purgeDeletedTasks({int daysThreshold = 30}) =>
      purgeDeletedRows('tasks', daysThreshold: daysThreshold);

  // ── Disk Hygiene ──────────────────────────────────────────────────────

  /// Guards against two overlapping VACUUMs (each purge call would otherwise
  /// queue its own full-file rewrite).
  bool _vacuumRunning = false;

  /// Reclaim free pages after a bulk delete — but only when there is actually
  /// something to reclaim. `PRAGMA freelist_count` reports pages SQLite is
  /// holding spare; below [minFreePages] (2 MB at the default 4 KB page size)
  /// the rewrite would cost seconds of I/O to save nothing, so it is skipped.
  /// Returns the approximate number of bytes reclaimed (0 = no-op).
  Future<int> vacuumIfFragmented({int minFreePages = 512}) async {
    if (_vacuumRunning) return 0;
    _vacuumRunning = true;
    try {
      final db = await database;
      final freePages = await _pragmaInt(db, 'freelist_count');
      if (freePages < minFreePages) return 0;
      final pageSize = await _pragmaInt(db, 'page_size');
      final reclaimableBytes = freePages * (pageSize > 0 ? pageSize : 4096);
      final started = DateTime.now();
      // Cannot run inside a transaction — db.execute on the raw handle is fine.
      await db.execute('VACUUM');
      final ms = DateTime.now().difference(started).inMilliseconds;
      print(
        '[LocalDB] VACUUM reclaimed ~${(reclaimableBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
        '($freePages free pages) in ${ms}ms',
      );
      return reclaimableBytes;
    } catch (e) {
      print('[LocalDB] Error vacuuming database: $e');
      return 0;
    } finally {
      _vacuumRunning = false;
    }
  }

  Future<int> _pragmaInt(Database db, String pragma) async {
    final rows = await db.rawQuery('PRAGMA $pragma');
    if (rows.isEmpty) return 0;
    final value = rows.first.values.first;
    return value is int ? value : int.tryParse('$value') ?? 0;
  }

  /// Retention prune for the durable action log: keep the newest
  /// [keepPerParent] rows per parent and drop the rest. `system_logs` keys its
  /// parent (taskId or enquiryId — both modules ride the same `taskId` column)
  /// and is re-mirrored from the Firestore subcollection on every detail-screen
  /// open, so without a cap a long-lived task grows the table forever and every
  /// row is re-exported into every backup. The Activity log only ever renders
  /// the recent tail, so 50 per parent is far past anything the UI shows.
  /// [keepPerParent] must match FirebaseService's system-log mirror limit, or
  /// the next detail-screen open re-mirrors what this just pruned.
  /// Returns the number of rows deleted.
  Future<int> pruneSystemLogs({int keepPerParent = 50}) async {
    try {
      final db = await database;
      final count = await db.rawDelete(
        'DELETE FROM system_logs WHERE id NOT IN ('
        'SELECT s.id FROM system_logs s '
        'WHERE s.taskId = system_logs.taskId '
        'ORDER BY s.createdAt DESC LIMIT ?)',
        [keepPerParent],
      );
      if (count > 0) {
        print(
          '[LocalDB] Pruned $count system_logs rows beyond the newest '
          '$keepPerParent per parent',
        );
        _notify('system_logs');
        unawaited(vacuumIfFragmented());
      }
      return count;
    } catch (e) {
      print('[LocalDB] Error pruning system_logs: $e');
      return 0;
    }
  }

  /// Get a single task by ID
  Future<TaskModel?> getTaskById(String taskId) async {
    final db = await database;
    final results = await db.query(
      'tasks',
      where: 'id = ?',
      whereArgs: [taskId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return taskFromRow(results.first);
  }

  TaskModel taskFromRow(Map<String, dynamic> row) {
    return TaskModel(
      id: row['id'] as String,
      title: row['title'] as String? ?? '',
      description: row['description'] as String? ?? '',
      createdBy: row['createdBy'] as String,
      createdByName: row['createdByName'] as String?,
      createdByPhone: row['createdByPhone'] as String?,
      assignedTo: row['assignedTo'] as String? ?? '',
      assignedToUid: row['assignedToUid'] as String?,
      assignedToPhone: row['assignedToPhone'] as String?,
      participants: _decodeStringList(row['participants'] as String?),
      participantHistory: _decodeParticipantList(
        row['participantHistory'] as String?,
      ),
      isGroupTask: (row['isGroupTask'] as int) == 1,
      priority: row['priority'] as int? ?? 2,
      isUrgent: (row['isUrgent'] as int) == 1,
      deadline: row['deadline'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deadline'] as int)
          : null,
      progress: (row['progress'] as num).toDouble(),
      tags: _decodeStringList(row['tags'] as String?),
      extraFields: _decodeMap(row['extraFields'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
      startDate: row['startDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['startDate'] as int)
          : null,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updatedAt'] as int),
      isClosed: (row['isClosed'] as int) == 1,
      isCancelled: (row['isCancelled'] as int) == 1,
      rating: row['rating'] as int?,
      template: row['template'] as String?,
      category: row['category'] as String?,
      reminderCount: row['reminderCount'] as int? ?? 0,
      warningCount: row['warningCount'] as int? ?? 0,
      statusRequestCount: row['statusRequestCount'] as int? ?? 0,
      lastMessageText: row['lastMessageText'] as String?,
      lastMessageTime: row['lastMessageTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['lastMessageTime'] as int)
          : null,
      milestones: _decodeMilestoneList(row['milestones'] as String?),
      unreadCounts: _decodeMapStringInt(row['unreadCounts'] as String?),
      displayId: row['displayId'] as int?,
      isDeleted: (row['isDeleted'] as int) == 1,
      deletedAt: row['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deletedAt'] as int)
          : null,
      deletedBy: row['deletedBy'] as String?,
      teamId: row['teamId'] as String?,
      isArchived: (row['isArchived'] as int?) == 1,
      archivedAt: row['archivedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['archivedAt'] as int)
          : null,
      archivedBy: row['archivedBy'] as String?,
      recurrence: row['recurrence'] as String?,
      seriesId: row['seriesId'] as String?,
      nextDue: row['nextDue'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['nextDue'] as int)
          : null,
      clientName: row['clientName'] as String?,
      clientPhone: row['clientPhone'] as String?,
      clientEmail: row['clientEmail'] as String?,
      clientAddress: row['clientAddress'] as String?,
      clientCompany: row['clientCompany'] as String?,
    );
  }

  Map<String, dynamic> taskToRow(TaskModel task) {
    return {
      'id': task.id,
      'title': task.title,
      'description': task.description,
      'createdBy': task.createdBy,
      'createdByName': task.createdByName,
      'createdByPhone': task.createdByPhone,
      'assignedTo': task.assignedTo,
      'assignedToUid': task.assignedToUid,
      'assignedToPhone': task.assignedToPhone,
      'participants': jsonEncode(
        participantsUnion(
          task.participants,
          createdBy: task.createdBy,
          assignedToUid: task.assignedToUid,
          extraFields: task.extraFields,
        ),
      ),
      'participantHistory': jsonEncode(
        task.participantHistory.map((p) => p.toMap()).toList(),
      ),
      'isGroupTask': task.isGroupTask ? 1 : 0,
      'priority': task.priority,
      'isUrgent': task.isUrgent ? 1 : 0,
      'deadline': task.deadline?.millisecondsSinceEpoch,
      'progress': task.progress,
      'tags': jsonEncode(task.tags),
      'extraFields': task.extraFields != null
          ? jsonEncode(task.extraFields)
          : null,
      'createdAt': task.createdAt.millisecondsSinceEpoch,
      'startDate': task.startDate?.millisecondsSinceEpoch,
      'updatedAt': task.updatedAt.millisecondsSinceEpoch,
      'isClosed': task.isClosed ? 1 : 0,
      'isCancelled': task.isCancelled ? 1 : 0,
      'rating': task.rating,
      'template': task.template,
      'category': task.category,
      'reminderCount': task.reminderCount,
      'warningCount': task.warningCount,
      'statusRequestCount': task.statusRequestCount,
      'lastMessageText': task.lastMessageText,
      'lastMessageTime': task.lastMessageTime?.millisecondsSinceEpoch,
      'milestones': jsonEncode(task.milestones.map((m) => m.toMap()).toList()),
      'unreadCounts': jsonEncode(task.unreadCounts),
      'displayId': task.displayId,
      'isDeleted': task.isDeleted ? 1 : 0,
      'deletedAt': task.deletedAt?.millisecondsSinceEpoch,
      'deletedBy': task.deletedBy,
      'teamId': task.teamId,
      'isArchived': task.isArchived ? 1 : 0,
      'archivedAt': task.archivedAt?.millisecondsSinceEpoch,
      'archivedBy': task.archivedBy,
      'recurrence': task.recurrence,
      'seriesId': task.seriesId,
      'nextDue': task.nextDue?.millisecondsSinceEpoch,
      ...task.customerInfo.toRow(),
    };
  }

  // ── Sales Teams ────────────────────────────────────────────────────────

  /// Get sales teams for a user from local DB
  Future<List<SalesTeam>> getTeams(String userId) async {
    final db = await database;
    final results = await db.query(
      'sales_teams',
      where: 'createdBy = ?',
      whereArgs: [userId],
      orderBy: 'createdAt ASC',
    );
    return results.map((row) => teamFromRow(row)).toList();
  }

  /// Save or update a sales team in local DB
  Future<void> saveTeam(SalesTeam team) async {
    final db = await database;
    await db.insert(
      'sales_teams',
      teamToRow(team),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify('sales_teams');
  }

  /// Save multiple sales teams in a batch
  Future<void> saveTeams(List<SalesTeam> teams) async {
    final db = await database;
    final batch = db.batch();
    for (final team in teams) {
      batch.insert(
        'sales_teams',
        teamToRow(team),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _notify('sales_teams');
  }

  SalesTeam teamFromRow(Map<String, dynamic> row) {
    return SalesTeam(
      id: row['id'] as String,
      name: row['name'] as String,
      createdBy: row['createdBy'] as String,
      members: _decodeMembers(row['members']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updatedAt'] as int),
    );
  }

  Map<String, dynamic> teamToRow(SalesTeam team) {
    return {
      'id': team.id,
      'name': team.name,
      'createdBy': team.createdBy,
      'members': jsonEncode(team.members),
      'createdAt': team.createdAt.millisecondsSinceEpoch,
      'updatedAt': team.updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Decode the JSON-encoded members column (may be null on legacy rows).
  List<String> _decodeMembers(Object? raw) {
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  // ── Task Drafts ────────────────────────────────────────────────────────

  /// Get task drafts for a user from local DB
  Future<List<TaskDraft>> getTaskDrafts(String userId) async {
    final db = await database;
    final results = await db.query(
      'task_drafts',
      where: 'createdBy = ?',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return results.map((row) => _draftFromRow(row)).toList();
  }

  /// Save or update a task draft in local DB
  Future<void> saveTaskDraft(
    String draftId,
    String createdBy,
    TaskDraft draft,
  ) async {
    final db = await database;
    final row = _draftToRow(draft, draftId, createdBy);
    await db.insert(
      'task_drafts',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify('task_drafts');
  }

  /// Delete a task draft by ID
  Future<void> deleteTaskDraft(String draftId) async {
    final db = await database;
    await db.delete('task_drafts', where: 'id = ?', whereArgs: [draftId]);
    _notify('task_drafts');
  }

  TaskDraft _draftFromRow(Map<String, dynamic> row) {
    return TaskDraft(
      assignedTo: row['assignedTo'] as String? ?? '',
      assigneeUid: row['assigneeUid'] as String?,
      assigneePhone: row['assigneePhone'] as String?,
      assigneeIsOnApp: (row['assigneeIsOnApp'] as int) == 1,
      title: row['title'] as String? ?? '',
      description: row['description'] as String? ?? '',
      startDate: row['startDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['startDate'] as int)
          : null,
      deadline: row['deadline'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deadline'] as int)
          : null,
      priority: row['priority'] as int? ?? 2,
      isUrgent: (row['isUrgent'] as int) == 1,
      progress: row['progress'] as int? ?? 0,
      activateNow: (row['activateNow'] as int) == 1,
      currentStep: TaskDraftStep.values.firstWhere(
        (s) => s.name == row['currentStep'],
        orElse: () => TaskDraftStep.enteringTitle,
      ),
    );
  }

  Map<String, dynamic> _draftToRow(
    TaskDraft draft,
    String id,
    String createdBy,
  ) {
    return {
      'id': id,
      'createdBy': createdBy,
      'assignedTo': draft.assignedTo,
      'assigneeUid': draft.assigneeUid,
      'assigneePhone': draft.assigneePhone,
      'assigneeIsOnApp': draft.assigneeIsOnApp ? 1 : 0,
      'title': draft.title,
      'description': draft.description,
      'startDate': draft.startDate?.millisecondsSinceEpoch,
      'deadline': draft.deadline?.millisecondsSinceEpoch,
      'priority': draft.priority,
      'isUrgent': draft.isUrgent ? 1 : 0,
      'progress': draft.progress,
      'activateNow': draft.activateNow ? 1 : 0,
      'currentStep': draft.currentStep.name,
      'conversation': jsonEncode(
        draft.conversation
            .map(
              (m) => {
                'isSystem': m.isSystem,
                'text': m.text,
                'step': m.step?.name,
                'canEdit': m.canEdit,
                'createdAt': m.createdAt.millisecondsSinceEpoch,
              },
            )
            .toList(),
      ),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  List<TaskParticipant> _decodeParticipantList(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return list
          .map((p) => TaskParticipant.fromMap(Map<String, dynamic>.from(p)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<MilestoneModel> _decodeMilestoneList(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return MilestoneModel.dedupeById(
        list
            .map(
              (m) => MilestoneModel.fromMap(
                Map<String, dynamic>.from(m),
                m['id'] ?? '',
              ),
            )
            .toList(),
      );
    } catch (_) {
      return [];
    }
  }

  // ── Milestones ──────────────────────────────────────────────────────

  /// Get milestones for a task from local DB
  Future<List<MilestoneModel>> getMilestones(String taskId) async {
    final db = await database;
    final results = await db.query(
      'milestones',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'createdAt ASC',
    );
    return results.map((row) => milestoneFromRow(row)).toList();
  }

  /// Save or update a milestone in local DB
  Future<void> saveMilestone(
    String milestoneId,
    String taskId,
    MilestoneModel milestone,
  ) async {
    final db = await database;
    final row = {
      'id': milestoneId,
      'taskId': taskId,
      'title': milestone.title,
      'isCompleted': milestone.isCompleted ? 1 : 0,
      'completedAt': milestone.completedAt?.millisecondsSinceEpoch,
      'createdAt': milestone.createdAt!.millisecondsSinceEpoch,
    };
    await db.insert(
      'milestones',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify('milestones');
  }

  /// Save multiple milestones in batch
  Future<void> saveMilestones(
    String taskId,
    List<MilestoneModel> milestones,
    List<String> milestoneIds,
  ) async {
    final db = await database;
    final batch = db.batch();
    for (int i = 0; i < milestones.length; i++) {
      final row = {
        'id': i < milestoneIds.length ? milestoneIds[i] : milestones[i].id,
        'taskId': taskId,
        'title': milestones[i].title,
        'isCompleted': milestones[i].isCompleted ? 1 : 0,
        'completedAt': milestones[i].completedAt?.millisecondsSinceEpoch,
        'createdAt': milestones[i].createdAt!.millisecondsSinceEpoch,
      };
      batch.insert(
        'milestones',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _notify('milestones');
  }

  /// Delete a milestone from local DB
  Future<void> deleteMilestone(String milestoneId) async {
    final db = await database;
    await db.delete('milestones', where: 'id = ?', whereArgs: [milestoneId]);
    _notify('milestones');
  }

  /// Convert a DB row to MilestoneModel
  MilestoneModel milestoneFromRow(Map<String, dynamic> row) {
    return MilestoneModel(
      id: row['id'] as String,
      title: row['title'] as String? ?? '',
      isCompleted: (row['isCompleted'] as int) == 1,
      completedAt: row['completedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['completedAt'] as int)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
    );
  }

  // ── System Logs ─────────────────────────────────────────────────────

  /// Get system logs for a task from local DB
  Future<List<SystemLogModel>> getSystemLogs(String taskId) async {
    final db = await database;
    final results = await db.query(
      'system_logs',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'createdAt ASC',
    );
    return results.map((row) => systemLogFromRow(row)).toList();
  }

  /// Delete one action card's durable log mirror (doc id = message id) when
  /// the card is undone within the undo window — the Activity log must agree
  /// with the chat that the action never happened, on this device first
  /// (SQLite) before the Firestore mirror is dropped.
  Future<void> deleteSystemLogLocal(String taskId, String logId) async {
    final db = await database;
    final count = await db.delete(
      'system_logs',
      where: 'id = ? AND taskId = ?',
      whereArgs: [logId, taskId],
    );
    if (count > 0) _notify('system_logs');
  }

  /// Save a system log in local DB
  Future<void> saveSystemLog(
    String logId,
    String taskId,
    SystemLogModel log,
  ) async {
    final db = await database;
    final row = {
      'id': logId,
      'taskId': taskId,
      'action': log.action,
      'performedBy': log.performedBy,
      'details': log.details,
      'createdAt': log.createdAt.millisecondsSinceEpoch,
    };
    await db.insert(
      'system_logs',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify('system_logs');
  }

  /// Save multiple system logs in batch
  Future<void> saveSystemLogs(
    String taskId,
    List<SystemLogModel> logs,
    List<String> logIds,
  ) async {
    final db = await database;
    final batch = db.batch();
    for (int i = 0; i < logs.length; i++) {
      final row = {
        'id': i < logIds.length ? logIds[i] : logs[i].id,
        'taskId': taskId,
        'action': logs[i].action,
        'performedBy': logs[i].performedBy,
        'details': logs[i].details,
        'createdAt': logs[i].createdAt.millisecondsSinceEpoch,
      };
      batch.insert(
        'system_logs',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _notify('system_logs');
  }

  /// Convert a DB row to SystemLogModel
  SystemLogModel systemLogFromRow(Map<String, dynamic> row) {
    return SystemLogModel(
      id: row['id'] as String,
      taskId: row['taskId'] as String? ?? '',
      action: row['action'] as String? ?? '',
      performedBy: row['performedBy'] as String? ?? '',
      details: row['details'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
    );
  }

  // ── Watch Streams (SQLite-backed, for UI) ─────────────────────────────

  /// Stream that re-queries messages from SQLite whenever the messages table changes.
  /// Emits cached data immediately on first subscription, then on every subsequent write.
  Stream<List<MessageModel>> watchMessages(String taskId, {int limit = 10000}) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getMessages(taskId, limit: limit);
      // R6.4 Fix A+B: re-read only when THIS conversation changes, and coalesce
      // a sync burst into one re-read. The raw per-event stream re-read the
      // full 10000-limit conversation on EVERY app-wide 'messages' write (the
      // getMessages ×354 storm). Now:
      //  • debounce collapses N writes in a burst -> one re-read;
      //  • `matches` scopes it to this conversation — message writes carry
      //    their parent taskId in TableChange.ids (see saveMessage/saveMessages),
      //    and an empty-ids (bulk) write still reloads every watcher (fallback).
      // Sent messages render optimistically in the detail screens, so the
      // ≤300ms confirmation latency is invisible; identical payloads are
      // deduped downstream (task_detail hasNewMessages / sales_detail isSameData).
      await for (final _ in tableChangesDebounced(
        'messages',
        matches: (c) => c.ids.isEmpty || c.ids.contains(taskId),
      )) {
        yield await getMessages(taskId, limit: limit);
      }
    }).asBroadcastStream();
  }

  /// Stream that re-queries tasks from SQLite whenever the tasks table changes.
  /// Emits cached data immediately on first subscription, then on every subsequent write.
  Stream<List<TaskModel>> watchTasks(String userId) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getTasks(userId);
      await for (final _ in tableChanges2.where((c) => c.table == 'tasks')) {
        yield await getTasks(userId);
      }
    }).asBroadcastStream();
  }

  /// Stream that re-queries milestones from SQLite whenever the milestones table changes.
  /// Emits cached data immediately on first subscription, then on every subsequent write.
  Stream<List<MilestoneModel>> watchMilestones(String taskId) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getMilestones(taskId);
      await for (final _ in tableChanges2.where(
        (c) => c.table == 'milestones',
      )) {
        yield await getMilestones(taskId);
      }
    }).asBroadcastStream();
  }

  /// Stream that re-queries system logs from SQLite whenever the system_logs table changes.
  /// Emits cached data immediately on first subscription, then on every subsequent write.
  Stream<List<SystemLogModel>> watchSystemLogs(String taskId) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getSystemLogs(taskId);
      await for (final _ in tableChanges2.where(
        (c) => c.table == 'system_logs',
      )) {
        yield await getSystemLogs(taskId);
      }
    }).asBroadcastStream();
  }

  /// Stream that re-queries teams from SQLite whenever the sales_teams table changes.
  /// Emits cached data immediately on first subscription, then on every subsequent write.
  Stream<List<SalesTeam>> watchTeams(String userId) {
    return Stream.fromFuture(Future.value(null)).asyncExpand((_) async* {
      yield await getTeams(userId);
      await for (final _ in tableChanges2.where(
        (c) => c.table == 'sales_teams',
      )) {
        yield await getTeams(userId);
      }
    }).asBroadcastStream();
  }

  // ── Backfill Actions from Existing Messages ───────────────────────────

  /// Scan all existing messages and populate the actions table.
  /// Called once after upgrading to the version that introduced the actions table.
  /// ⚠️ Same Helpers.detectActionType gate as _writeThroughAction — new action
  /// types must be added there before backfill can recognize them.
  Future<int> backfillActionsFromMessages() async {
    final db = await database;
    final messages = await db.query('messages', orderBy: 'createdAt ASC');
    int count = 0;

    // Get all parent info in bulk to avoid repeated queries
    final taskCache = <String, Map<String, dynamic>>{};
    final enquiryCache = <String, Map<String, dynamic>>{};

    final batch = db.batch();
    for (final msgRow in messages) {
      final text = msgRow['text'] as String? ?? '';
      final actionType = Helpers.detectActionType(text);
      if (actionType == null) continue;

      final parentId = msgRow['taskId'] as String;
      final messageId = msgRow['id'] as String;
      final senderId = msgRow['senderId'] as String?;
      final createdAt = msgRow['createdAt'] as int;
      final isReplied = (msgRow['isReplied'] as int?) ?? 0;
      final isFollowUpDone = (msgRow['isFollowUpDone'] as int?) ?? 0;

      // Determine parentType and get display fields
      String parentType;
      String? clientName;
      String? parentTitle;

      if (enquiryCache.containsKey(parentId)) {
        parentType = 'enquiry';
        final e = enquiryCache[parentId]!;
        clientName = e['clientName'] as String?;
        parentTitle = e['title'] as String?;
      } else if (taskCache.containsKey(parentId)) {
        parentType = 'task';
        final t = taskCache[parentId]!;
        clientName = t['createdByName'] as String?;
        parentTitle = t['title'] as String?;
      } else {
        // Check enquiries first (more likely for sales actions)
        final eRows = await db.query(
          'enquiries',
          where: 'id = ?',
          whereArgs: [parentId],
          limit: 1,
        );
        if (eRows.isNotEmpty) {
          parentType = 'enquiry';
          enquiryCache[parentId] = eRows.first;
          clientName = eRows.first['clientName'] as String?;
          parentTitle = eRows.first['title'] as String?;
        } else {
          final tRows = await db.query(
            'tasks',
            where: 'id = ?',
            whereArgs: [parentId],
            limit: 1,
          );
          if (tRows.isNotEmpty) {
            parentType = 'task';
            taskCache[parentId] = tRows.first;
            clientName = tRows.first['createdByName'] as String?;
            parentTitle = tRows.first['title'] as String?;
          } else {
            parentType = 'task'; // default fallback
          }
        }
      }

      // Parse scheduled date
      int? scheduledDate;
      if (actionType == 'followup') {
        final m = RegExp(
          r'for\s+(.+?)(?:\s+by\s+|\s+at\s+|$)',
          caseSensitive: false,
        ).firstMatch(text);
        if (m != null) {
          final parsed = Helpers.parseActionDate(m.group(1)!.trim());
          if (parsed != null) scheduledDate = parsed.millisecondsSinceEpoch;
        }
      } else {
        final dates = Helpers.parseAllActionDates(text);
        if (dates.isNotEmpty)
          scheduledDate = dates.first.millisecondsSinceEpoch;
      }

      batch.insert('actions', {
        'id': messageId,
        'parentId': parentId,
        'parentType': parentType,
        'actionType': actionType,
        'text': text,
        'senderId': senderId,
        'createdAt': createdAt,
        'scheduledDate': scheduledDate,
        'isReplied': isReplied,
        'isDone': isFollowUpDone,
        'clientName': clientName,
        'parentTitle': parentTitle,
        'seqNo': msgRow['sequenceNumber'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Also write enquiry actions to the dedicated sales_actions table
      if (parentType == 'enquiry') {
        final teamId = enquiryCache[parentId]?['teamId'] as String?;
        batch.insert('sales_actions', {
          'id': messageId,
          'parentId': parentId,
          'teamId': teamId,
          'actionType': actionType,
          'text': text,
          'senderId': senderId,
          'createdAt': createdAt,
          'scheduledDate': scheduledDate,
          'isReplied': isReplied,
          'isDone': isFollowUpDone,
          'clientName': clientName,
          'parentTitle': parentTitle,
          'seqNo': msgRow['sequenceNumber'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      count++;
    }
    await batch.commit(noResult: true);
    if (count > 0) {
      _notify('actions');
      _notify('sales_actions');
    }
    return count;
  }

  // ── Users Cache (phone → UID lookup) ──────────────────────────────────────

  /// Get cached UID for a phone number, or null if not cached.
  Future<String?> getCachedUid(String phone) async {
    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['uid'],
      where: 'phone = ?',
      whereArgs: [phone],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['uid'] as String? : null;
  }

  /// Get cached name for a phone number, or null if not cached.
  Future<String?> getCachedName(String phone) async {
    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['name'],
      where: 'phone = ?',
      whereArgs: [phone],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['name'] as String? : null;
  }

  /// Cache a phone → UID mapping. Also caches optional name, plan type and
  /// avatarUrl. Fields passed as null keep any previously cached value
  /// (ConflictAlgorithm.replace would otherwise wipe them).
  Future<void> cacheUser(
    String uid,
    String phone, {
    String? name,
    String? planType,
    String? avatarUrl,
  }) async {
    final db = await database;
    final existing = await db.query(
      'users',
      columns: ['name', 'planType', 'avatarUrl'],
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    final prev = existing.isNotEmpty ? existing.first : const {};
    await db.insert('users', {
      'uid': uid,
      'phone': phone,
      'name': name ?? prev['name'],
      'planType': planType ?? prev['planType'],
      'avatarUrl': avatarUrl ?? prev['avatarUrl'],
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Batch cache multiple phone → UID mappings.
  Future<void> cacheUsers(List<Map<String, dynamic>> users) async {
    if (users.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final user in users) {
      batch.insert('users', {
        'uid': user['uid'],
        'phone': user['phone'],
        'name': user['name'],
        'planType': user['planType'],
        'avatarUrl': user['avatarUrl'],
        'cachedAt': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// All cached users' identity + plan type rows for the in-memory premium
  /// lookup ([PremiumStatusService]). Cheap: small table, three columns.
  Future<List<Map<String, dynamic>>> getCachedUserPlans() async {
    final db = await database;
    return await db.query('users', columns: ['uid', 'phone', 'planType']);
  }

  /// All cached users' identity + avatarUrl rows for the in-memory avatar
  /// lookup ([AvatarCacheService]). Cheap: small table, four columns.
  Future<List<Map<String, dynamic>>> getCachedUserAvatars() async {
    final db = await database;
    return await db.query(
      'users',
      columns: ['uid', 'phone', 'name', 'avatarUrl'],
    );
  }

  /// Replace the persisted phonebook-nickname → avatar url index in a single
  /// batch (delete + insert). Mirrors the in-memory wholesale rebuild in
  /// [AvatarCacheService.applyNicknameIndex]: the incoming map is the complete
  /// current set, so old rows must go. An empty map clears the table.
  Future<void> replaceAvatarNicknames(Map<String, String> entries) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.delete('avatar_nicknames');
    entries.forEach((name, url) {
      batch.insert(
        'avatar_nicknames',
        {'name': name, 'avatarUrl': url, 'cachedAt': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  /// Load the persisted nickname → avatar index so [AvatarCacheService] can
  /// resolve by local contact name at cold start, before contacts reload.
  Future<List<Map<String, dynamic>>> getCachedAvatarNicknames() async {
    final db = await database;
    return await db.query(
      'avatar_nicknames',
      columns: ['name', 'avatarUrl'],
    );
  }

  /// Get UID for phone, checking cache first. Returns null if not found.
  /// Use this as the primary lookup method — checks SQLite cache only.
  Future<String?> lookupUid(String phone) async {
    return getCachedUid(phone);
  }

  // ── Current user plan (local-first paywall gate) ────────────────────────

  /// Persist the signed-in user's plan bundle so paywall gates resolve from
  /// SQLite on the next cold start (including offline) instead of waiting on a
  /// direct Firestore `users/{uid}` read. Mirrors the local-first principle:
  /// the server profile refreshes this row, the app reads it. [modulePlans]
  /// entries carry Firestore [Timestamp] start/expiry dates; those are stored
  /// as epoch millis and rebuilt on read (see [getUserPlan]) so the shapes
  /// handed to [UserModel] / ModulePlanCache keep their `as Timestamp?` parses.
  Future<void> saveUserPlan(
    String uid, {
    required String? planType,
    required DateTime? planExpiry,
    required Map<String, Map<String, dynamic>> modulePlans,
  }) async {
    if (uid.isEmpty) return;
    final db = await database;
    final encoded = <String, Map<String, dynamic>>{};
    modulePlans.forEach((module, entry) {
      encoded[module] = {
        'planType': entry['planType'],
        'startDate': _dateToMillis(entry['startDate']),
        'expiryDate': _dateToMillis(entry['expiryDate']),
      };
    });
    await db.insert(
      'user_plan',
      {
        'uid': uid,
        'planType': planType,
        'planExpiry': planExpiry?.millisecondsSinceEpoch,
        'modulePlans': jsonEncode(encoded),
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Load the cached plan bundle for [uid], or null if never persisted. Dates
  /// come back as Firestore [Timestamp]s so they drop straight into
  /// [UserModel.modulePlans] / ModulePlanCache with parsing unchanged.
  Future<LocalUserPlan?> getUserPlan(String uid) async {
    if (uid.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'user_plan',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final expiryMillis = row['planExpiry'] as int?;
    return LocalUserPlan(
      planType: row['planType'] as String?,
      planExpiry: expiryMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(expiryMillis)
          : null,
      modulePlans: _decodeModulePlans(row['modulePlans'] as String?),
    );
  }

  /// Normalizes a plan date (Timestamp / DateTime / epoch int) to millis for
  /// storage. Returns null for anything unrecognized (stored as SQL NULL).
  int? _dateToMillis(dynamic v) {
    if (v is Timestamp) return v.toDate().millisecondsSinceEpoch;
    if (v is DateTime) return v.millisecondsSinceEpoch;
    if (v is int) return v;
    return null;
  }

  /// Rebuilds a `modulePlans` map from its stored JSON, restoring the start /
  /// expiry dates as [Timestamp]s so consumers' `as Timestamp?` casts work.
  Map<String, Map<String, dynamic>> _decodeModulePlans(String? json) {
    final result = <String, Map<String, dynamic>>{};
    if (json == null || json.isEmpty) return result;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      map.forEach((module, entry) {
        if (entry is Map) {
          final e = Map<String, dynamic>.from(entry);
          result[module] = {
            'planType': e['planType'],
            'startDate': _millisToTimestamp(e['startDate']),
            'expiryDate': _millisToTimestamp(e['expiryDate']),
          };
        }
      });
    } catch (_) {
      // Malformed row -> treat as no cached plans; the next server read rewrites it.
    }
    return result;
  }

  Timestamp? _millisToTimestamp(dynamic v) =>
      v is int ? Timestamp.fromMillisecondsSinceEpoch(v) : null;

  /// Close database connection
  Future<void> close() async {
    _tableChanges2Controller.close();
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  // ── Categories ────────────────────────────────────────────────────────────

  /// Get all categories for a module ('task', 'sales', or 'all').
  /// Returns categories matching the given module OR 'all'.
  Future<List<Map<String, dynamic>>> getCategories(String module) async {
    final db = await database;
    return await db.query(
      'categories',
      where: "module = ? OR module = 'all'",
      whereArgs: [module],
      orderBy: 'name ASC',
    );
  }

  /// Insert a new category.
  Future<void> insertCategory(String id, String name, String module) async {
    final db = await database;
    await db.insert('categories', {
      'id': id,
      'name': name,
      'module': module,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notify('categories');
  }

  /// Update a category name.
  Future<void> updateCategory(String id, String name) async {
    final db = await database;
    await db.update(
      'categories',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify('categories');
  }

  /// Delete a category.
  Future<void> deleteCategory(String id) async {
    final db = await database;
    await db.delete('categories', where: 'id = ?', whereArgs: [id]);
    _notify('categories');
  }

  // ── Module-Aware Methods (for BaseModuleProvider) ──────────────────────────

  /// Get enquiries from a specific table (module-aware).
  Future<List<EnquiryModel>> getModuleEnquiries(
    String userId, {
    String? teamId,
    required String tableName,
  }) async {
    // Shared snapshot keyed by table + revision (see [getTasks]): Sales/CRM
    // Actions and Assignee tabs re-read the same full enquiry scan, so memoize
    // it and hand back a copy until the module table actually changes.
    final cacheKey = '$tableName\u0000$userId\u0000${teamId ?? ''}';
    final cached = _readSnapshot<EnquiryModel>(cacheKey, tableName);
    if (cached != null) return cached;
    final rev = revisionOf(tableName);
    final tr = StartupTrace.instance.begin(
      'getModuleEnquiries',
      caller: 'getModuleEnquiries',
    );
    final w = SyncTelemetry.instance.startTimer();
    final db = await database;
    final results = await db.query(tableName, orderBy: 'updatedAt DESC');
    final tDecode = StartupTrace.instance.begin(
      'getModuleEnquiries:decode',
      kind: StartupTraceKind.ui,
      caller: 'getModuleEnquiries',
    );
    final out = results.map((row) => enquiryFromRow(row)).toList();
    StartupTrace.instance.end(tDecode, rows: out.length);
    SyncTelemetry.instance.recordDb('getModuleEnquiries', w, out.length);
    StartupTrace.instance.end(tr, rows: out.length);
    _writeSnapshot<EnquiryModel>(cacheKey, rev, out);
    return List<EnquiryModel>.of(out);
  }

  /// Change-set (4.1) reader for a module enquiries table: fetch ONLY the given
  /// ids, mirroring [getModuleEnquiries] ordering. Ids absent from the result
  /// were deleted (or never belonged here) so the consumer drops them from its
  /// in-memory list instead of re-scanning the whole table. [tableName] is the
  /// module's enquiries table ('enquiries' / 'crm_enquiries'), so this single
  /// reader is common to Sales and CRM.
  Future<List<EnquiryModel>> getModuleEnquiriesByIds(
    Set<String> ids, {
    required String tableName,
  }) async {
    if (ids.isEmpty) return const <EnquiryModel>[];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final results = await db.rawQuery(
      'SELECT * FROM $tableName WHERE id IN ($placeholders) '
      'ORDER BY updatedAt DESC',
      [...ids],
    );
    return results.map((row) => enquiryFromRow(row)).toList();
  }

  /// Get paginated enquiries from a specific table.
  Future<List<EnquiryModel>> getModuleEnquiriesPaginated(
    String userId, {
    String? teamId,
    int limit = 20,
    int offset = 0,
    required String tableName,
  }) async {
    final db = await database;
    final results = await db.query(
      tableName,
      orderBy: 'updatedAt DESC',
      limit: limit,
      offset: offset,
    );
    return results.map((row) => enquiryFromRow(row)).toList();
  }

  /// Save or update an enquiry in a specific table. [clearAssignee] honors an
  /// intentional unassign through the local-first merge (see
  /// [_mergeLocalFirst]).
  Future<void> saveModuleEnquiry(
    EnquiryModel enquiry, {
    required String tableName,
    bool clearAssignee = false,
  }) => _upsertRowIfChanged(
    tableName,
    enquiryToRow(enquiry),
    clearAssignee: clearAssignee,
  );

  /// Module counterpart of [markTaskAccessRevoked]: applied when the module
  /// participant sync sees an enquiry LEAVE the user's `arrayContains(participants)`
  /// result set (they were just removed as an assignee). The card stays in the
  /// local table (visible) but is blanked to "Unassigned" and stamped
  /// `accessRevoked` so the composer reads frozen/read-only. Firestore rules
  /// deny the removed user's reads/sends, so no server write can correct this
  /// last legitimately-received snapshot. Mirrors across Sales and CRM (shared
  /// screen) — only [tableName] differs.
  Future<void> markModuleEnquiryAccessRevoked(
    String id, {
    required String tableName,
  }) async {
    final enquiry = await getModuleEnquiryById(id, tableName: tableName);
    if (enquiry == null) return;
    if (enquiry.extraFields?['accessRevoked'] == true) return; // idempotent
    final updated = enquiry.copyWith(
      assignedTo: '',
      assignedToUid: '',
      assignedToPhone: '',
      // Bump the watermark so the upsert doesn't skip the row as "unchanged"
      // (this is a local-only transform; the stored copy keeps the old stamp).
      updatedAt: DateTime.now(),
      extraFields: {
        ...?enquiry.extraFields,
        'accessRevoked': true,
        'assigneeNames': <String>[],
        'assigneeUids': <String>[],
        'assigneePhones': <String>[],
      },
    );
    await saveModuleEnquiry(updated, tableName: tableName, clearAssignee: true);
  }

  /// Save multiple enquiries to a specific table (only writes changed rows).
  Future<void> saveModuleEnquiries(
    List<EnquiryModel> enquiries, {
    required String tableName,
  }) async {
    final w = SyncTelemetry.instance.startTimer();
    await _upsertRowsIfChanged(
      tableName,
      enquiries.map(enquiryToRow).toList(),
      caller: 'saveModuleEnquiries',
    );
    SyncTelemetry.instance.recordDb('saveModuleEnquiries', w, enquiries.length);
  }

  /// Delete an enquiry from a specific table.
  Future<void> deleteModuleEnquiry(
    String enquiryId, {
    required String tableName,
  }) => _deleteRowById(tableName, enquiryId);

  /// Bulk-delete enquiries from a specific table — used by the participant
  /// sync to drop rows the local user was just removed from (Sales/CRM).
  Future<void> removeModuleEnquiriesByIds(
    List<String> ids, {
    required String tableName,
  }) => _deleteRowsByIds(tableName, ids);

  /// Batch-load action icons from a specific actions table (module-aware).
  /// Same generous limit as the task variant so pending counts stay exact.
  Future<Map<String, List<Map<String, dynamic>>>>
  getModuleActionIconsForParents(
    List<String> parentIds, {
    required String tableName,
    int limit = 100,
  }) => _actionIconsForParentsFrom(tableName, parentIds, limit);

  /// Get teams from a specific table (module-aware).
  Future<List<SalesTeam>> getModuleTeams(
    String userId, {
    required String tableName,
  }) async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'createdBy = ?',
      whereArgs: [userId],
      orderBy: 'createdAt ASC',
    );
    return results.map((row) => teamFromRow(row)).toList();
  }

  /// Save multiple teams to a specific table.
  Future<void> saveModuleTeams(
    List<SalesTeam> teams, {
    required String tableName,
  }) async {
    if (teams.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final team in teams) {
      batch.insert(
        tableName,
        teamToRow(team),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _notify(tableName);
  }

  /// Delete a team from a specific table.
  Future<void> deleteModuleTeam(
    String teamId, {
    required String tableName,
  }) async {
    final db = await database;
    await db.delete(tableName, where: 'id = ?', whereArgs: [teamId]);
    _notify(tableName);
  }

  /// Re-point every local phone reference of [uid] from the old number to
  /// [newPhone] (phone-number switch). Ownership is UID-keyed so tasks never
  /// move; only the denormalized phone columns and extraFields JSON are
  /// rewritten so phone-based matching keeps working after the change.
  Future<void> migrateUserPhone({
    required String uid,
    required String oldPhone,
    required String newPhone,
  }) async {
    if (uid.isEmpty || newPhone.isEmpty) return;
    final db = await database;
    final newNorm = Helpers.normalizePhone(newPhone) ?? newPhone;
    final oldDigits = oldPhone.replaceAll(RegExp(r'\D'), '');
    final oldSuffix = oldDigits.length >= 10
        ? oldDigits.substring(oldDigits.length - 10)
        : oldDigits;

    bool isOldPhone(String? stored) {
      if (stored == null || stored.isEmpty) return false;
      if (stored == oldPhone) return true;
      final digits = stored.replaceAll(RegExp(r'\D'), '');
      if (digits.isEmpty || oldSuffix.isEmpty) return false;
      return digits.length >= 10 &&
          digits.substring(digits.length - 10) == oldSuffix;
    }

    // Users cache: phone is UNIQUE — drop any stale row holding the new
    // number before moving our own row onto it.
    try {
      await db.delete(
        'users',
        where: 'phone = ? AND uid != ?',
        whereArgs: [newNorm, uid],
      );
      await db.update(
        'users',
        {'phone': newNorm},
        where: 'uid = ?',
        whereArgs: [uid],
      );
    } catch (e) {
      print('[PhoneSwitch] users table migration failed: $e');
    }

    // Denormalized creator/assignee phone columns on card tables.
    for (final table in ['tasks', 'enquiries', 'crm_enquiries']) {
      try {
        await db.rawUpdate(
          'UPDATE $table SET createdByPhone = ? '
          'WHERE createdBy = ? AND createdByPhone IS NOT NULL '
          "AND createdByPhone != '' AND createdByPhone != ?",
          [newNorm, uid, newNorm],
        );
        await db.rawUpdate(
          'UPDATE $table SET assignedToPhone = ? '
          'WHERE assignedToUid = ? AND assignedToPhone IS NOT NULL '
          "AND assignedToPhone != '' AND assignedToPhone != ?",
          [newNorm, uid, newNorm],
        );
      } catch (e) {
        print('[PhoneSwitch] $table column migration failed: $e');
      }
    }

    // extraFields JSON (assigneePhones lists) — rewrite in Dart.
    for (final table in ['tasks', 'enquiries', 'crm_enquiries']) {
      try {
        final rows = await db.query(
          table,
          columns: ['id', 'extraFields'],
          where: 'extraFields IS NOT NULL',
        );
        for (final row in rows) {
          final raw = row['extraFields'] as String?;
          if (raw == null || raw.isEmpty) continue;
          Map<String, dynamic> extra;
          try {
            extra = jsonDecode(raw) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          final phones = extra['assigneePhones'];
          if (phones is! List) continue;
          var changed = false;
          final newPhones = phones.map((p) {
            final s = p?.toString() ?? '';
            if (isOldPhone(s)) {
              changed = true;
              return newNorm;
            }
            return s;
          }).toList();
          if (!changed) continue;
          extra['assigneePhones'] = newPhones;
          await db.update(
            table,
            {'extraFields': jsonEncode(extra)},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      } catch (e) {
        print('[PhoneSwitch] $table extraFields migration failed: $e');
      }
    }

    _notify('users');
    _notify('tasks');
    _notify('enquiries');
    _notify('crm_enquiries');
  }

  /// Write-through: insert/update an action in a module-specific actions table.
  /// ⚠️ Same Helpers.detectActionType gate as _writeThroughAction — a type
  /// missing there is never indexed for sales/CRM either.
  Future<void> writeThroughModuleAction(
    MessageModel message,
    String? teamId, {
    required String actionsTableName,
    required String enquiriesTableName,
    String? clientName,
    String? parentTitle,
    bool parentResolved = false,
  }) async {
    final actionType = Helpers.detectActionType(message.text);
    if (actionType == null) return;
    final db = await database;
    // When the caller already resolved the parent (batch write-through), skip
    // the redundant per-message enquiry query and use the supplied fields.
    if (!parentResolved) {
      final eRows = await db.query(
        enquiriesTableName,
        where: 'id = ?',
        whereArgs: [message.taskId],
        limit: 1,
      );
      if (eRows.isNotEmpty) {
        clientName = eRows.first['clientName'] as String?;
        parentTitle = eRows.first['title'] as String?;
        teamId ??= eRows.first['teamId'] as String?;
      }
    }
    final info = _ActionParentInfo(
      parentType: 'enquiry',
      isCrm: actionsTableName == 'crm_actions',
      found: true,
      teamId: teamId,
      clientName: clientName,
      parentTitle: parentTitle,
    );
    await db.insert(
      actionsTableName,
      _moduleActionRow(message, info, actionType),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify(actionsTableName);
  }

  /// One-time backfill: rebuild a module actions table from existing messages
  /// whose parent enquiry lives in [enquiriesTableName]. Fixes historical
  /// messages that were routed to the shared actions table (or skipped) before
  /// module-aware write-through existed. Idempotent (REPLACE on message id).
  ///
  /// Performance: single lean JOIN query (no blob columns), one batched
  /// insert, and a single notify at the end — must never be awaited on a
  /// UI-blocking path. It still reads EVERY non-deleted message and rewrites
  /// every action row, so callers must latch it (see
  /// `_ensureModuleActionsBackfilled` in BaseModuleProvider) — an in-memory
  /// per-process guard is not enough, it re-ran on every cold launch.
  Future<void> backfillModuleActionsFromMessages({
    required String actionsTableName,
    required String enquiriesTableName,
  }) async {
    final db = await database;
    // Only the columns needed — avoids decoding attachment/blob data.
    final rows = await db.rawQuery(
      'SELECT m.id, m.taskId, m.senderId, m.text, m.createdAt, '
      'm.isReplied, m.isFollowUpDone, m.sequenceNumber, '
      'e.clientName AS eClientName, e.title AS eTitle, e.teamId AS eTeamId '
      'FROM messages m '
      'INNER JOIN $enquiriesTableName e ON m.taskId = e.id '
      'WHERE m.deleted = 0 OR m.deleted IS NULL',
    );
    bool wroteAny = false;
    if (rows.isNotEmpty) {
      final batch = db.batch();
      for (final row in rows) {
        final text = row['text'] as String? ?? '';
        final actionType = Helpers.detectActionType(text);
        if (actionType == null) continue;
        int? scheduledDate;
        if (actionType == 'followup') {
          final followUpDateMatch = RegExp(
            r'for\s+(.+?)(?:\s+by\s+|\s+at\s+|$)',
            caseSensitive: false,
          ).firstMatch(text);
          if (followUpDateMatch != null) {
            final parsed = Helpers.parseActionDate(
              followUpDateMatch.group(1)!.trim(),
            );
            if (parsed != null) scheduledDate = parsed.millisecondsSinceEpoch;
          }
        } else {
          final dates = Helpers.parseAllActionDates(text);
          if (dates.isNotEmpty)
            scheduledDate = dates.first.millisecondsSinceEpoch;
        }
        batch.insert(actionsTableName, {
          'id': row['id'],
          'parentId': row['taskId'],
          'teamId': row['eTeamId'],
          'actionType': actionType,
          'text': text,
          'senderId': row['senderId'],
          'createdAt': row['createdAt'],
          'scheduledDate': scheduledDate,
          'isReplied': row['isReplied'] ?? 0,
          'isDone': row['isFollowUpDone'] ?? 0,
          'clientName': row['eClientName'],
          'parentTitle': row['eTitle'],
          'seqNo': row['sequenceNumber'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        wroteAny = true;
      }
      if (wroteAny) await batch.commit(noResult: true);
    }
    if (wroteAny) _notify(actionsTableName);
  }

  /// Remove enquiry-parented rows that were mis-filed into the SHARED task
  /// `actions` table, so they stop polluting the task Actions screen.
  ///
  /// This is ongoing repair, NOT part of the one-time backfill: write-through
  /// falls back to parentType 'task' whenever a message arrives before its
  /// parent enquiry row has synced (`_resolveActionParentInfo`, found ==
  /// false), so mis-filed rows keep appearing. Kept separate so the caller can
  /// latch the expensive scan above and still run this on every launch — it is
  /// a single DELETE served by `idx_actions_parent`.
  Future<void> purgeMisfiledEnquiryActions({
    required String enquiriesTableName,
  }) async {
    final db = await database;
    final removed = await db.rawDelete(
      'DELETE FROM actions WHERE parentId IN (SELECT id FROM $enquiriesTableName)',
    );
    if (removed > 0) _notify('actions');
  }
}

/// Resolved parent context for an action-message write-through, memoised per
/// batch in [LocalDatabaseService.saveMessages] so a bulk load doesn't re-query
/// the parent row for every message. Captures the routing decision (task vs
/// enquiry, crm vs sales) and the denormalized fields copied onto the action row.
class _ActionParentInfo {
  /// 'task' (shared `actions` table) or 'enquiry' (module `sales_actions` /
  /// `crm_actions` tables).
  final String parentType;

  /// True when [parentType] is 'enquiry' and the parent lives in `crm_enquiries`
  /// (routes to `crm_actions`); false routes to `sales_actions`.
  final bool isCrm;

  /// True when the parent row was actually found. A null-parentType message
  /// whose id is in neither `tasks` nor an enquiry table keeps the historical
  /// 'task' fallback ([found] == false) rather than being mis-filed as an enquiry.
  final bool found;

  /// Denormalized display fields copied onto the action row:
  /// tasks.createdByName / enquiries.clientName, and the parent's title.
  final String? clientName;
  final String? parentTitle;

  /// Enquiry team scope (crm/sales); null for task-parented actions.
  final String? teamId;

  const _ActionParentInfo({
    required this.parentType,
    this.isCrm = false,
    this.found = false,
    this.clientName,
    this.parentTitle,
    this.teamId,
  });
}
