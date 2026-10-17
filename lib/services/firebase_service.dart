import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/task.dart';
import '../models/task_draft.dart';
import '../models/message.dart';
import '../models/milestone.dart';
import '../models/system_log.dart';
import '../models/user.dart';
import '../modules/sales/models/enquiry.dart';
import '../providers/unread_counts_mixin.dart';
import 'sequential_id_service.dart';
import 'local_database_service.dart';
import 'sync_telemetry.dart';
import 'startup_trace.dart';

/// Firebase service — reduced to a dumb delivery pipe.
///
/// Role: Send data for delivery to others, receive data from others → write to SQLite.
/// The UI NEVER reads from Firebase directly. All reads come from SQLite.
class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // In-flight Firestore create writes keyed by doc id. updateTask must wait
  // on these — otherwise an activation update that lands before the create
  // set() gets clobbered by it (task snaps back to draft on the next sync).
  final Map<String, Future<void>> _pendingCreates = {};

  // ── Active background sync subscriptions ──────────────────────────────
  final Map<String, StreamSubscription> _activeSyncs = {};

  // Diagnostics: listener keys that have already delivered their first (full)
  // snapshot. Cleared on _cancelSync so a re-attach re-counts the attach read.
  final Set<String> _telFirstEmission = {};

  /// Record one Firestore snapshot delivery for the in-app diagnostics
  /// indicator. The first emission after a (re)attach sizes the full
  /// result-set read; later emissions only bill the changed docs. No-op unless
  /// telemetry is enabled, so the production cost is a single boolean check.
  void _telEmit(String key, QuerySnapshot snapshot) {
    // Chronological startup trace: mark the FIRST (full result-set) snapshot a
    // listener delivers, independent of SyncTelemetry's enabled flag.
    if (StartupTrace.instance.isActive &&
        StartupTrace.instance.isFirstForKey(key)) {
      StartupTrace.instance.instant(
        'fs first snapshot: $key',
        StartupTraceKind.fs,
        detail: '${snapshot.docs.length} docs',
        rows: snapshot.docs.length,
      );
    }
    final tel = SyncTelemetry.instance;
    if (!tel.enabled) return;
    final isFirst = _telFirstEmission.add(key);
    tel.recordEmission(
      key,
      snapshot.docs.length,
      snapshot.docChanges.length,
      isFirst,
    );
  }

  /// [DocumentSnapshot] counterpart of [_telEmit], for the single-doc listeners
  /// (`task_`, `moduleDetail_`). A doc snapshot has no docChanges — the
  /// delivery IS the one document — so a server-confirmed snapshot bills one
  /// read and a locally-pending one bills none.
  void _telEmitDoc(String key, DocumentSnapshot snapshot) {
    final tel = SyncTelemetry.instance;
    if (!tel.enabled) return;
    final isFirst = _telFirstEmission.add(key);
    tel.recordEmission(
      key,
      snapshot.exists ? 1 : 0,
      snapshot.metadata.hasPendingWrites ? 0 : 1,
      isFirst,
    );
  }

  // ── Delta-sync watermark ───────────────────────────────────────────────
  // Listeners only fetch docs with updatedAt newer than the freshest row
  // already in SQLite, so re-attaching sync on app start doesn't re-read
  // the whole result set. Overlap window absorbs clock skew and the gap
  // between a message's createdAt (used for the local bump) and the
  // parent's serverTimestamp updatedAt.
  static const Duration _watermarkOverlap = Duration(minutes: 5);

  /// Grace window subtracted from the local chat high-water mark when bounding
  /// the chat-open listener to recent messages. Set to 24h so it comfortably
  /// exceeds BOTH the 60-minute delete-for-everyone eligibility window and the
  /// paid-tier 24h receipt retention: any message still eligible for a
  /// for-everyone soft-delete (or a late readBy/downloadedBy receipt) is at most
  /// that old, so it always falls inside the fetched range. Bounding therefore
  /// never hides a delete-for-everyone or a receipt from a returning device.
  static const Duration _chatBackfillGrace = Duration(hours: 24);

  /// Safety cap on a Sales/CRM chat's very first download (no local cache yet).
  /// The shared module detail screen paginates older messages straight from
  /// Firestore on scroll-up ([BaseModuleService.getOlderMessages]), so capping
  /// the initial snapshot here is lossless. Task is deliberately left uncapped:
  /// its scroll-up only reveals already-cached SQLite rows, so a cap there
  /// would strand any history beyond the cap forever.
  static const int _chatInitialFetchCap = 500;

  Future<Timestamp?> _watermarkFor(String tableName) async {
    try {
      final maxMs = await LocalDatabaseService().getMaxUpdatedAt(tableName);
      if (maxMs == null) return null; // Empty table — full first sync
      // getMaxUpdatedAt is a whole-table MAX, so a single row carrying an
      // updatedAt in the future (device clock ahead of the server, or the
      // rows written before the pending-write filter below decoded a null
      // serverTimestamp to now()) pushed the watermark past the present.
      // Every later delta query then matched nothing and sync silently
      // stopped delivering. Never anchor past "now".
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final anchorMs = maxMs > nowMs ? nowMs : maxMs;
      return Timestamp.fromMillisecondsSinceEpoch(
        anchorMs - _watermarkOverlap.inMilliseconds,
      );
    } catch (e) {
      print('[FirebaseService] Watermark lookup failed for $tableName: $e');
      return null; // Fall back to full sync
    }
  }

  Query _afterWatermark(Query query, Timestamp? watermark) {
    if (watermark == null) return query;
    return query.where('updatedAt', isGreaterThan: watermark);
  }

  /// Whether the last-received copy of a doc still lists [userId] as a
  /// participant. Used to disambiguate the two reasons a doc can produce a
  /// `removed` change on an `arrayContains(participants)` listener:
  ///
  /// 1. Genuine membership loss — the local user was actually taken off the
  ///    assignee/participant list, so their access really is revoked.
  /// 2. A transient drop out of the delta-sync window — a pending
  ///    `serverTimestamp()` write reads as `null` locally, so the doc briefly
  ///    fails the `updatedAt > watermark` filter (the parent-task touch a
  ///    Close / Reply / Mark-Done send performs is exactly this), or clock
  ///    skew puts its `updatedAt` under the watermark. The user is still a
  ///    participant; treating this as a revocation wrongly freezes the
  ///    composer with "You're no longer assigned…".
  ///
  /// The `!hasPendingWrites` guard alone does not cover case 2, because the
  /// transient removal and its re-add can be reported across different
  /// cache/server snapshots (and a `removed` may still land on a later
  /// confirmed emission near the watermark boundary). Only case 1 should
  /// revoke, so callers skip removals where membership is still present.
  bool _docStillHasMember(DocumentSnapshot doc, String userId) {
    final data = doc.data();
    if (data is! Map) return false;
    final participants = data['participants'];
    return participants is List && participants.contains(userId);
  }

  void _cancelSync(String key) {
    _activeSyncs.remove(key)?.cancel();
    _telFirstEmission.remove(key);
    final tel = SyncTelemetry.instance;
    if (tel.enabled) tel.setActiveListeners(_activeSyncs.length);
  }

  /// True when a listener is already attached under [key].
  bool _isSyncActive(String key) => _activeSyncs.containsKey(key);

  /// Attach the listener produced by [build] under [key] only when nothing is
  /// streaming there yet. Re-attaching a live query costs a fresh result set
  /// (billable reads) plus a decode of every doc on the UI isolate, and the
  /// detail/chat screens used to do it each time they were re-opened.
  void _setSyncIfAbsent(String key, StreamSubscription Function() build) {
    if (_isSyncActive(key)) return;
    _activeSyncs[key] = build();
    if (StartupTrace.instance.isActive) {
      StartupTrace.instance.instant('fs attach: $key', StartupTraceKind.fs);
    }
    final tel = SyncTelemetry.instance;
    if (tel.enabled) {
      tel.recordAttach(key);
      tel.setActiveListeners(_activeSyncs.length);
    }
  }

  // ── R1(c): bounded LRU keep-alive for recent chat + system-log listeners ─
  // Chat listeners (task / sales / crm messages) and the durable system-log
  // listeners are the dominant Firestore read cost: chat is bounded only by the
  // 168h retention clock (still a large initial read that grows with thread
  // length), and system_logs was uncapped until _systemLogMirrorLimit — a busy
  // enquiry's moduleSystemLogs initial load hit ~70 docs in diagnostics. The
  // detail screen's dispose() also used to cancel them, so every re-open
  // re-attached and re-billed the whole result set.
  // Instead of cancelling on close we keep the most-recent
  // [_maxWarmChatListeners] chat and [_maxWarmLogListeners] system-log
  // subscriptions alive; re-opening a recent detail reuses the live listener —
  // no attach, no full re-read. The queries themselves are UNCHANGED (same
  // orderBy('createdAt'), same writes to SQLite), so message/log semantics stay
  // byte-identical; only the listener lifetime is bounded-kept.
  // Least-recently-closed entries beyond each bound are evicted (cancelled) to
  // cap memory and the live-listener count. Chats and logs keep SEPARATE warm
  // pools so a burst of one can never evict the other. Task-list / moduleDetail
  // / milestone listeners are still NOT kept warm — they cancel immediately
  // (moduleDetail is a single-doc read; task-list/milestone are cheap).
  // Bounds raised 3 → 5: diagnostics showed several chat/systemLogs keys at
  // `attach 2` within one session — a 3-slot pool evicted a still-relevant
  // detail, so returning to it re-attached and re-billed the full result set.
  // 5 covers a realistic working set of recently-opened tasks/enquiries. A kept
  // warm listener is idle-billed (only document CHANGES cost a read), so this
  // trades a little memory for fewer costly re-attach reads.
  static const int _maxWarmChatListeners = 5;
  static const int _maxWarmLogListeners = 5;

  /// Chat-listener keys that are closed-but-kept-warm, least-recently-closed
  /// first. A key whose screen is currently open is not in this list, so it can
  /// never be evicted while in use.
  final List<String> _warmChatKeys = [];

  /// System-log-listener keys (`systemLogs_` / `moduleSystemLogs_`) kept warm on
  /// the same bounded-LRU basis as [_warmChatKeys], in a separate pool.
  final List<String> _warmLogKeys = [];

  /// A chat screen opened: drop the key from the warm list (it is in use again)
  /// so [_releaseChatListener] will not evict it. The matching
  /// [_setSyncIfAbsent] reuses the still-live subscription when it is warm.
  void _markChatInUse(String key) => _warmChatKeys.remove(key);

  /// A chat screen closed: keep the listener warm instead of cancelling, then
  /// evict the least-recently-closed chats beyond [_maxWarmChatListeners].
  void _releaseChatListener(String key) =>
      _releaseWarm(key, _warmChatKeys, _maxWarmChatListeners);

  /// System-log counterparts of [_markChatInUse] / [_releaseChatListener].
  void _markLogInUse(String key) => _warmLogKeys.remove(key);
  void _releaseLogListener(String key) =>
      _releaseWarm(key, _warmLogKeys, _maxWarmLogListeners);

  /// Shared bounded-LRU park: keep [key]'s live subscription, mark it the
  /// most-recently-closed in [warm], and cancel the least-recently-closed
  /// entries once [warm] exceeds [max]. No-op when nothing is live under [key].
  void _releaseWarm(String key, List<String> warm, int max) {
    if (!_isSyncActive(key)) return; // nothing live to keep
    warm.remove(key);
    warm.add(key); // most-recently-closed at the end
    while (warm.length > max) {
      _cancelSync(warm.removeAt(0)); // least-recently-closed
    }
  }

  /// Decode [snapshot] through [build], skipping docs the server hasn't
  /// confirmed yet.
  ///
  /// Offline — and for a moment after every local write — Firestore emits
  /// straight from its cache with `hasPendingWrites`: serverTimestamps are
  /// still null, so the models substitute `DateTime.now()`. Storing those
  /// rows poisons the delta watermark and, because the upsert path only moves
  /// time forward, makes the later server-confirmed row look stale so it gets
  /// rejected. The confirmed emission always follows, so nothing is lost by
  /// waiting for it.
  ///
  /// Not applied to the milestone/system-log listeners: those pass the full
  /// doc-id list to a replace-and-delete-missing save, where filtering would
  /// drop locally created rows.
  List<T> _confirmedFrom<T>(
    QuerySnapshot snapshot,
    T Function(Map<String, dynamic> data, String id) build,
  ) {
    final tr = StartupTrace.instance.begin(
      'fs snapshot decode',
      kind: StartupTraceKind.ui,
    );
    final out = <T>[];
    for (final doc in snapshot.docs) {
      if (doc.metadata.hasPendingWrites) continue;
      out.add(build(doc.data() as Map<String, dynamic>, doc.id));
    }
    StartupTrace.instance.end(tr, rows: out.length);
    return out;
  }

  /// Cancel all active syncs (call on logout).
  void stopAllSync() {
    for (final sub in _activeSyncs.values) {
      sub.cancel();
    }
    _activeSyncs.clear();
    _warmChatKeys.clear();
    _warmLogKeys.clear();
  }

  // ── Users Collection ──────────────────────────────────────────────────

  CollectionReference users() {
    return _firestore.collection('users');
  }

  Future<UserModel?> getUser(String uid) async {
    final doc = await users().doc(uid).get();
    if (doc.exists) {
      return UserModel.fromMap(doc.data() as Map<String, dynamic>, doc.id);
    }
    return null;
  }

  // ── Tasks Collection ──────────────────────────────────────────────────

  CollectionReference tasks() {
    return _firestore.collection('tasks');
  }

  Future<String> createTask(TaskModel task, {String? taskId}) async {
    final id = taskId ?? tasks().doc().id;

    int? displayId = task.displayId;
    final isDraft = task.extraFields?['isDraft'] == true;
    if (!isDraft && displayId == null) {
      displayId = await SequentialIdService().getNextId('task');
    }

    final taskWithId = task.copyWith(id: id, displayId: displayId);
    final write = tasks().doc(id).set(taskWithId.toMap());
    _pendingCreates[id] = write;
    try {
      await write;
    } finally {
      if (identical(_pendingCreates[id], write)) _pendingCreates.remove(id);
    }
    return id;
  }

  /// Lightweight field update on a task document (e.g. unreadCounts).
  Future<void> updateTaskField(
    String taskId,
    Map<String, dynamic> updates,
  ) async {
    await tasks().doc(taskId).update(updates);
  }

  Future<void> updateTask(String taskId, TaskModel task, {bool clearAssignee = false}) async {
    // Wait for any in-flight create write on this doc so a fast
    // follow-up update (e.g. draft activation) can't race it.
    final pending = _pendingCreates[taskId];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final docRef = tasks().doc(taskId);
    final data = task.toMap();
    final snapshot = await docRef.get();
    final existing = snapshot.data() as Map<String, dynamic>?;
    if (existing != null) {
      for (final field in [
        'createdBy',
        'createdByName',
        'createdByPhone',
        'assignedTo',
        'assignedToUid',
        'assignedToPhone',
        'extraFields',
        'startDate',
        'rating',
        'template',
      ]) {
        // Blank means "this copy doesn't know the value" — never "clear it".
        // A partial/offline TaskModel used to write assignedTo: '' to the
        // server, after which the task dropped out of the Assignee bucket on
        // every device until the identity repair ran.
        final incoming = data[field];
        final stored = existing[field];
        final incomingBlank =
            incoming == null || (incoming is String && incoming.isEmpty);
        final storedBlank =
            stored == null || (stored is String && stored.isEmpty);
        // An explicit unassign (clearAssignee) means the emptied assignee
        // fields are INTENTIONAL — let them reach the server so the card flips
        // to Unassigned everywhere instead of reverting to the stored assignee.
        final intentionalClear =
            clearAssignee &&
            (field == 'assignedTo' ||
                field == 'assignedToUid' ||
                field == 'assignedToPhone');
        if (incomingBlank && !storedBlank && !intentionalClear) {
          data[field] = stored;
        }
      }

      final existingExtraFields = existing['extraFields'];
      final updatedExtraFields = data['extraFields'];
      if (existingExtraFields is Map && updatedExtraFields is Map) {
        data['extraFields'] = <String, dynamic>{
          ...Map<String, dynamic>.from(existingExtraFields),
          ...Map<String, dynamic>.from(updatedExtraFields),
        };
      }
    }

    // Firestore rejects null values inside nested maps, so a payload like
    // extraFields: {isDraft: null} makes the ENTIRE update throw and the
    // change never reaches the server (draft then "stays draft" after sync).
    // Callers signal "clear this flag" with a null entry — strip the nulls
    // and translate them into FieldValue.delete() dot-paths.
    final extraFieldsData = data['extraFields'];
    if (extraFieldsData is Map<String, dynamic>) {
      final nullKeys = extraFieldsData.entries
          .where((e) => e.value == null)
          .map((e) => e.key)
          .toList();
      if (nullKeys.isNotEmpty) {
        data['extraFields'] = Map<String, dynamic>.from(extraFieldsData)
          ..removeWhere((k, v) => v == null);
        if (existing != null) {
          for (final key in nullKeys) {
            data['extraFields.$key'] = FieldValue.delete();
          }
        }
      }
    }

    // Always bump updatedAt server-side — watermarked delta sync only
    // delivers docs whose updatedAt moved past other devices' watermarks
    data['updatedAt'] = FieldValue.serverTimestamp();

    if (existing == null) {
      // The initial fire-and-forget create hasn't landed (or failed) —
      // update() would throw not-found and the change would be lost
      // silently, so create the document from this full task map instead.
      await docRef.set(data);
    } else {
      await docRef.update(data);
    }
  }

  /// Pin a task's draft flag to false with a targeted dot-path write so the
  /// activation survives even if a concurrent full-map merge lands later.
  Future<void> markTaskActive(String taskId) async {
    await tasks().doc(taskId).update({
      'extraFields.isDraft': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Soft-delete a task in Firestore (marks isDeleted=true).
  /// For hard-delete (purge), use tasks().doc(id).delete() directly.
  Future<void> deleteTask(String taskId, {String? deletedBy}) async {
    await tasks().doc(taskId).update({
      'isDeleted': true,
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy': deletedBy,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    // Also update local DB
    final task = await LocalDatabaseService().getTaskById(taskId);
    if (task != null) {
      LocalDatabaseService()
          .saveTask(
            task.copyWith(
              isDeleted: true,
              deletedAt: DateTime.now(),
              deletedBy: deletedBy,
            ),
          )
          .catchError((e) {
            print(
              '[FirebaseService] Failed to soft-delete task in local DB: $e',
            );
          });
    }
  }

  /// Purge soft-deleted tasks older than [daysThreshold] days from Firestore.
  /// Returns the number of tasks purged.
  Future<int> purgeDeletedTasks({int daysThreshold = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: daysThreshold));
    final snapshot = await tasks()
        .where('isDeleted', isEqualTo: true)
        .where('deletedAt', isLessThan: Timestamp.fromDate(cutoff))
        .get();
    int count = 0;
    for (final doc in snapshot.docs) {
      try {
        await doc.reference.delete();
        count++;
      } catch (e) {
        print('[FirebaseService] Failed to purge task ${doc.id}: $e');
      }
    }
    if (count > 0) {
      print(
        '[FirebaseService] Purged $count soft-deleted tasks older than $daysThreshold days',
      );
    }
    return count;
  }

  // ── Background Sync: Tasks ────────────────────────────────────────────

  /// Start syncing tasks for the home screen.
  /// Listens to Firestore queries and writes results to SQLite.
  /// Only fetches docs changed since the local watermark (delta sync).
  Future<void> startTaskSync(String userId, {String? userPhone}) async {
    final tr = StartupTrace.instance.begin(
      'fs startTaskSync (attach)',
      kind: StartupTraceKind.fs,
    );
    final hasPhone = userPhone != null && userPhone.isNotEmpty;
    final creatorKey = 'tasks_byCreator_$userId';
    final assigneeKey = 'tasks_byAssigneeUid_$userId';
    final participantKey = 'tasks_byParticipant_$userId';
    final phoneKey = 'tasks_byAssigneePhone_$userPhone';

    // Already streaming for this owner? Re-attaching costs one fresh result
    // set per listener (billable reads, plus a decode of every cached doc on
    // the UI isolate) for data SQLite already holds. loadTasks(force: true)
    // runs on every app resume, so four queries used to be torn down and
    // re-subscribed on each return from background — landing right on top of
    // the staggered startup jobs and the reload storm they trigger.
    if (_isSyncActive(creatorKey) &&
        _isSyncActive(assigneeKey) &&
        _isSyncActive(participantKey) &&
        (!hasPhone || _isSyncActive(phoneKey))) {
      StartupTrace.instance.end(tr, detail: 'already attached');
      return;
    }

    final watermark = await _watermarkFor('tasks');

    // Sync tasks created by user
    _setSyncIfAbsent(
      creatorKey,
      () => _afterWatermark(
        tasks().where('createdBy', isEqualTo: userId),
        watermark,
      ).snapshots().listen((snapshot) {
        _telEmit(creatorKey, snapshot);
        final queryTasks = _confirmedFrom(snapshot, TaskModel.fromMap);
        queryTasks.sort((a, b) {
          final timeA = a.lastMessageTime ?? a.updatedAt;
          final timeB = b.lastMessageTime ?? b.updatedAt;
          return timeB.compareTo(timeA);
        });
        LocalDatabaseService().saveTasks(queryTasks);
      }),
    );

    // Sync tasks assigned to user (by UID)
    _setSyncIfAbsent(
      assigneeKey,
      () => _afterWatermark(
        tasks().where('assignedToUid', isEqualTo: userId),
        watermark,
      ).snapshots().listen((snapshot) {
        _telEmit(assigneeKey, snapshot);
        final queryTasks = _confirmedFrom(snapshot, TaskModel.fromMap);
        LocalDatabaseService().saveTasks(queryTasks);
      }),
    );

    // Sync tasks where user is in participants
    _setSyncIfAbsent(
      participantKey,
      () => _afterWatermark(
        tasks().where('participants', arrayContains: userId),
        watermark,
      ).snapshots().listen((snapshot) {
        _telEmit(participantKey, snapshot);
        // A doc LEAVING this result set means the local user was just removed
        // as an assignee/participant. We deliberately DO NOT delete the row —
        // the card must stay visible (WhatsApp-group semantics). Instead mark
        // it Unassigned + accessRevoked locally so it reads frozen and the
        // composer goes read-only. The Firestore rules independently revoke
        // their access (non-participant can't read the doc/messages or send),
        // so no further server content arrives to correct the local row; this
        // last legitimately-received snapshot stays as read-only history.
        // Only fires while the listener is live (online); an offline removal
        // has no signal here and is accepted as a known limitation.
        for (final c in snapshot.docChanges) {
          if (c.type == DocumentChangeType.removed &&
              !c.doc.metadata.hasPendingWrites &&
              !_docStillHasMember(c.doc, userId)) {
            LocalDatabaseService().markTaskAccessRevoked(c.doc.id);
          }
        }
        final queryTasks = _confirmedFrom(snapshot, TaskModel.fromMap);
        LocalDatabaseService().saveTasks(queryTasks);
      }),
    );

    // Phone-based sync for non-app assignees
    if (hasPhone) {
      _setSyncIfAbsent(
        phoneKey,
        () => _afterWatermark(
          tasks().where('assignedToPhone', isEqualTo: userPhone),
          watermark,
        ).snapshots().listen((snapshot) {
          _telEmit(phoneKey, snapshot);
          final queryTasks = _confirmedFrom(snapshot, TaskModel.fromMap);
          LocalDatabaseService().saveTasks(queryTasks);
        }),
      );
    }
    StartupTrace.instance.end(tr);
  }

  void stopTaskSync(String userId, {String? userPhone}) {
    _cancelSync('tasks_byCreator_$userId');
    _cancelSync('tasks_byAssigneeUid_$userId');
    _cancelSync('tasks_byParticipant_$userId');
    if (userPhone != null && userPhone.isNotEmpty) {
      _cancelSync('tasks_byAssigneePhone_$userPhone');
    }
  }

  // ── Background Sync: Single Task (for detail screen) ──────────────────

  void startTaskDetailSync(String taskId) {
    _setSyncIfAbsent(
      'task_$taskId',
      () => tasks().doc(taskId).snapshots().listen((snapshot) {
        _telEmitDoc('task_$taskId', snapshot);
        // Skip snapshots this device hasn't confirmed yet. Offline they come
        // from the cache with pending serverTimestamps (which decode to now())
        // and partially-known fields, and saving them overwrote the
        // authoritative local row — the task then vanished from the Assignee
        // list until a restart re-synced it. The write that follows the flush
        // is server-confirmed and still lands.
        if (snapshot.exists && !snapshot.metadata.hasPendingWrites) {
          final task = TaskModel.fromMap(
            snapshot.data() as Map<String, dynamic>,
            snapshot.id,
          );
          LocalDatabaseService().saveTask(task);
        }
      }),
    );
  }

  void stopTaskDetailSync(String taskId) {
    _cancelSync('task_$taskId');
  }

  // ── Messages Subcollection ────────────────────────────────────────────

  CollectionReference messages(String taskId) {
    return tasks().doc(taskId).collection('messages');
  }

  /// Write a message and touch its parent in one round trip.
  ///
  /// [unreadRecipientUids] are the people who should now see this card as
  /// unread. Their counts are merged into the parent `update()` below rather
  /// than sent as a separate write — see
  /// [UnreadCountsMixin.unreadFieldUpdates] for why that distinction is the
  /// whole difference between a badge arriving and never arriving.
  Future<String> sendMessage(
    String taskId,
    MessageModel message, {
    String? messageId,
    Iterable<String> unreadRecipientUids = const [],
  }) async {
    print('[FirebaseService] sendMessage called');
    print('[FirebaseService] taskId: $taskId');
    print('[FirebaseService] Full path: tasks/$taskId/messages');
    try {
      final id = messageId ?? messages(taskId).doc().id;
      await messages(taskId).doc(id).set(message.toMap());
      print('[FirebaseService] Message saved with doc ID: $id');

      final snippet = message.text.length > 80
          ? '${message.text.substring(0, 80)}…'
          : message.text;
      await tasks().doc(taskId).update({
        'lastMessageText': snippet,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        ...UnreadCountsMixin.unreadFieldUpdates(
          message.senderId,
          unreadRecipientUids,
        ),
      });
      // Diagnostics: the message set + the parent-task lastMessage update.
      SyncTelemetry.instance.recordWrite(2);
      return id;
    } catch (e) {
      print('[FirebaseService] FAILED to save message: $e');
      print('[FirebaseService] Error type: ${e.runtimeType}');
      rethrow;
    }
  }

  Future<void> updateMessage(
    String taskId,
    String messageId,
    Map<String, dynamic> updates,
  ) async {
    try {
      print('[FirebaseService] Updating message $messageId in task $taskId');
      await messages(taskId).doc(messageId).update(updates);
      SyncTelemetry.instance.recordWrite();
      print('[FirebaseService] Message updated successfully');
    } catch (e) {
      print('[FirebaseService] FAILED to update message: $e');
      rethrow;
    }
  }

  Future<void> deleteMessage(String taskId, String messageId) async {
    try {
      print('[FirebaseService] Deleting message $messageId from task $taskId');
      await messages(taskId).doc(messageId).delete();
      SyncTelemetry.instance.recordWrite();
      print('[FirebaseService] Message deleted successfully');
    } catch (e) {
      print('[FirebaseService] FAILED to delete message: $e');
      rethrow;
    }
  }

  // Mark message as delivered to recipient
  // Mark message as read by user
  Future<void> markMessageRead(
    String taskId,
    String messageId,
    String userId,
  ) async {
    try {
      await messages(
        taskId,
      ).doc(messageId).update({'readBy.$userId': FieldValue.serverTimestamp()});
      SyncTelemetry.instance.recordWrite();
    } catch (e) {
      print('[FirebaseService] Error marking read: $e');
    }
  }

  /// Batch-mark messages as delivered to a user (writes deliveredTo.$userId).
  /// Uses Firestore batch writes, capped at 400 per batch.
  Future<void> markMessagesDelivered(
    String taskId,
    List<String> messageIds,
    String userId,
  ) async {
    if (messageIds.isEmpty) return;
    try {
      // Process in batches of 400 (Firestore limit is 500)
      for (int i = 0; i < messageIds.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final chunk = messageIds.sublist(
          i,
          (i + 400).clamp(0, messageIds.length),
        );
        for (final msgId in chunk) {
          final ref = messages(taskId).doc(msgId);
          batch.update(ref, {
            'deliveredTo.$userId': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        SyncTelemetry.instance.recordWrite(chunk.length);
      }
    } catch (e) {
      print('[FirebaseService] Error marking delivered: $e');
    }
  }

  // ── Background Sync: Messages ─────────────────────────────────────────

  /// Start syncing messages for a task chat.
  /// Listens to Firestore and writes to SQLite. UI reads from SQLite.
  ///
  /// Bounded to a delta (see [_startBoundedChatSync]) so a returning user does
  /// not re-download the whole retained history on every open.
  void startMessageSync(String taskId) {
    _startBoundedChatSync(
      key: 'messages_$taskId',
      resolveBound: () => _chatLowerBound(taskId),
      parentType: null,
      resolveDoc: (id) => messages(taskId).doc(id),
      buildQuery: (after) => _boundedChatQuery(
        messages(taskId),
        after,
        capWhenNoLocal: false,
      ),
    );
  }

  /// Local high-water mark minus [_chatBackfillGrace], as a Firestore Timestamp,
  /// or null when the conversation has nothing cached yet (→ full first fetch).
  Future<Timestamp?> _chatLowerBound(String parentId) async {
    try {
      final maxMs = await LocalDatabaseService().getMaxMessageCreatedAt(parentId);
      if (maxMs == null) return null;
      // Never anchor past "now" (same guard as [_watermarkFor]): a row whose
      // serverTimestamp decoded to a future now() would push the bound ahead
      // of the present and the range query would silently match nothing.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final anchorMs = maxMs > nowMs ? nowMs : maxMs;
      return Timestamp.fromMillisecondsSinceEpoch(
        anchorMs - _chatBackfillGrace.inMilliseconds,
      );
    } catch (e) {
      print(
        '[FirebaseService] Chat lower-bound lookup failed for $parentId: $e',
      );
      return null; // Fall back to a full fetch.
    }
  }

  /// Chat-open query with the delta bound applied. When [after] is set (the
  /// device already holds history) only messages newer than the local mark
  /// minus grace are streamed — everything older is already in SQLite. When
  /// [after] is null (a fresh chat) the retained window is fetched, capped only
  /// where [capWhenNoLocal] guarantees a Firestore older-pagination fallback.
  Query _boundedChatQuery(
    CollectionReference base,
    Timestamp? after, {
    required bool capWhenNoLocal,
  }) {
    if (after != null) {
      // Range field (createdAt) equals the orderBy field, so no composite
      // Firestore index is required.
      return base.where('createdAt', isGreaterThan: after).orderBy('createdAt');
    }
    final ordered = base.orderBy('createdAt');
    return capWhenNoLocal
        ? ordered.limitToLast(_chatInitialFetchCap)
        : ordered;
  }

  /// Shared attach for both chat listener families. Resolves the delta bound
  /// asynchronously, then attaches through [_setSyncIfAbsent] so the warm-LRU
  /// reuse path still applies. A synchronous [_isSyncActive] pre-check keeps a
  /// warm re-open from paying for the bound lookup at all, and the same check is
  /// re-run after the await to absorb a double-open that raced the read.
  ///
  /// [resolveDoc] maps a message id to its Firestore document so the listener
  /// can re-pull an action CARD that an incoming notice references — a card's
  /// own Done/Reply update keeps its original `createdAt` and therefore sits
  /// outside the bounded (`createdAt > after`) stream, so without this the
  /// other participant's copy never reflects a Done/Reply/Resolve. See the
  /// heal loop in the snapshot callback.
  void _startBoundedChatSync({
    required String key,
    required Future<Timestamp?> Function() resolveBound,
    required Query Function(Timestamp? after) buildQuery,
    required DocumentReference Function(String id) resolveDoc,
    required String? parentType,
  }) {
    _markChatInUse(key);
    if (_isSyncActive(key)) return; // Warm listener already streaming this chat.
    () async {
      final after = await resolveBound();
      if (_isSyncActive(key)) return; // Another open attached while awaiting.
      // Card ids already re-pulled on this listener — fetch each at most once
      // so a long-lived open chat doesn't re-read on every snapshot emission.
      final healedCards = <String>{};
      _setSyncIfAbsent(
        key,
        () => buildQuery(after).snapshots().listen((snapshot) async {
          _telEmit(key, snapshot);
          final msgs = _confirmedFrom(snapshot, MessageModel.fromMap);
          msgs.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          await LocalDatabaseService().saveMessages(
            msgs,
            parentType: parentType,
          );
          // Cross-side card heal (see [resolveDoc]): Done / Reply / Resolve
          // post a NEW notice whose replyToMessageId points at the OLDER card
          // they closed. That card's own flag update is invisible to this
          // bounded stream, so pull it directly (server-authoritative) — this
          // is what makes the card flip to Done/Replied on the other device,
          // not just on the actor's. Runs only for server-confirmed notices
          // (_confirmedFrom already drops locally-pending docs).
          for (final m in msgs) {
            final ref = m.replyToMessageId;
            if (ref == null || ref.isEmpty || !healedCards.add(ref)) continue;
            try {
              final doc = await resolveDoc(ref).get();
              if (!doc.exists) continue;
              final card = MessageModel.fromMap(
                doc.data() as Map<String, dynamic>,
                doc.id,
              );
              await LocalDatabaseService().saveMessage(
                card,
                parentType: parentType,
              );
            } catch (e) {
              print('[FirebaseService] Chat card heal failed for $ref: $e');
            }
          }
        }),
      );
    }();
  }

  void stopMessageSync(String taskId) {
    _releaseChatListener('messages_$taskId');
  }

  /// One-shot download of a task's most recent 200 messages into SQLite.
  /// Used by the fresh-install message recovery — unlike startMessageSync
  /// this leaves no persistent listener behind. saveMessages' write-through
  /// rebuilds the actions index as a side effect. Capped at the newest 200
  /// so a fresh install never downloads every conversation in full; older
  /// actions get indexed when that chat is opened.
  Future<void> fetchMessagesOnceFor(String taskId) async {
    final snapshot =
        await messages(taskId).orderBy('createdAt').limitToLast(200).get();
    if (snapshot.docs.isEmpty) return;
    final msgs = snapshot.docs
        .map(
          (doc) =>
              MessageModel.fromMap(doc.data() as Map<String, dynamic>, doc.id),
        )
        .toList();
    await LocalDatabaseService().saveMessages(msgs);
  }

  // ── Milestones Subcollection ──────────────────────────────────────────

  CollectionReference milestones(String taskId) {
    return tasks().doc(taskId).collection('milestones');
  }

  // ── Background Sync: Milestones ───────────────────────────────────────

  void startMilestoneSync(String taskId) {
    _setSyncIfAbsent(
      'milestones_$taskId',
      () => milestones(
        taskId,
      ).orderBy('dueDate', descending: false).snapshots().listen((snapshot) {
        _telEmit('milestones_$taskId', snapshot);
        final items = snapshot.docs
            .map(
              (doc) => MilestoneModel.fromMap(
                doc.data() as Map<String, dynamic>,
                doc.id,
              ),
            )
            .toList();
        final ids = snapshot.docs.map((d) => d.id).toList();
        LocalDatabaseService().saveMilestones(taskId, items, ids);
      }),
    );
  }

  void stopMilestoneSync(String taskId) {
    _cancelSync('milestones_$taskId');
  }

  // ── System Logs Subcollection ─────────────────────────────────────────

  /// Cap on how much of the durable action log a device mirrors. The
  /// subcollection is append-only and never swept server-side, so an unbounded
  /// listener re-read (and re-stored) the whole history on every detail-screen
  /// open — the Activity log only ever renders the recent tail. Must match
  /// [LocalDatabaseService.pruneSystemLogs]'s keepPerParent, otherwise the local
  /// retention prune and this pull disagree and the table refills on next open.
  /// Lowered 200 → 50: systemLogs attaches were ~70% of a session's Firestore
  /// reads (each detail open pulled up to 200 log docs). 50 still sits far past
  /// what the Activity section shows, and _backfillSystemLogs recreates older
  /// entries from the local chat messages, so the trail stays complete in
  /// practice while the attach read mass roughly quarters.
  static const int _systemLogMirrorLimit = 50;

  CollectionReference systemLogs(String taskId) {
    return tasks().doc(taskId).collection('system_logs');
  }

  // ── Background Sync: System Logs ──────────────────────────────────────

  void startSystemLogSync(String taskId) {
    _markLogInUse('systemLogs_$taskId');
    _setSyncIfAbsent(
      'systemLogs_$taskId',
      () => systemLogs(taskId)
          .orderBy('createdAt', descending: true)
          .limit(_systemLogMirrorLimit)
          .snapshots()
          .listen((snapshot) {
            _telEmit('systemLogs_$taskId', snapshot);
            final items = snapshot.docs
                .map(
                  (doc) => SystemLogModel.fromMap(
                    doc.data() as Map<String, dynamic>,
                    doc.id,
                  ),
                )
                .toList();
            final ids = snapshot.docs.map((d) => d.id).toList();
            LocalDatabaseService().saveSystemLogs(taskId, items, ids);
          }),
    );
  }

  void stopSystemLogSync(String taskId) {
    _releaseLogListener('systemLogs_$taskId');
  }

  /// Write-through for the durable action log: one doc per action message
  /// (doc id = message id, so rewrites from any device are idempotent).
  /// Chat messages can be swept by retention, but this subcollection keeps
  /// the action history so a device that lost its chat data recovers the
  /// log via [startSystemLogSync].
  Future<void> writeSystemLog({
    required String taskId,
    required String messageId,
    required String action,
    required String performedBy,
    required String details,
    required DateTime createdAt,
  }) async {
    try {
      await systemLogs(taskId).doc(messageId).set(
        {
          'taskId': taskId,
          'action': action,
          'performedBy': performedBy,
          'details': details,
          'createdAt': Timestamp.fromDate(createdAt.toUtc()),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      print('[FirebaseService] writeSystemLog failed: $e');
    }
  }

  /// Remove a task's durable action-log mirror row (doc id = message id).
  /// Called by the sender's undo of a just-sent action card so the deleted
  /// action does not survive in the Activity log or re-sync to a device that
  /// lost its chat data. Rules allow only the row's author to delete it.
  Future<void> deleteSystemLog(String taskId, String messageId) async {
    try {
      await systemLogs(taskId).doc(messageId).delete();
      SyncTelemetry.instance.recordWrite();
    } catch (e) {
      print('[FirebaseService] deleteSystemLog failed: $e');
    }
  }

  // ── Task Drafts Collection ────────────────────────────────────────────

  CollectionReference taskDrafts() {
    return _firestore.collection('task_drafts');
  }

  Future<String> saveTaskDraft(TaskDraft draft) async {
    final docRef = await taskDrafts().add(draft.toMap());
    return docRef.id;
  }

  // Teams are local-only (SQLite) — no Firestore team sync exists.

  // ── Background Sync: Sales Enquiries ──────────────────────────────────

  CollectionReference salesEnquiries() {
    return _firestore.collection('sales_enquiries');
  }

  // ── Background Sync: Enquiry Messages ─────────────────────────────────

  // REMOVED: enquiryMessages() / startEnquiryMessageSync() /
  // stopEnquiryMessageSync(). All three hardcoded the `sales_enquiries`
  // collection, so the CRM detail screen — which is the SAME widget,
  // sales_detail_screen.dart, parameterized by ModuleConfig — attached a
  // listener to a `sales_enquiries/{crmRecordId}` document that never exists.
  // Its chat only appeared to work because the list screen's prefetch had
  // already started the correct listener for the same id. Use the module-aware
  // pair below instead, passing config.firestoreCollection:
  //   startModuleMessageSync(enquiryId, collection)
  //   stopModuleMessageSync(enquiryId, collection)

  // ── Module-Aware Background Sync (for CRM / generic modules) ─────────
  // Teams are local-only (SQLite) — no Firestore team sync exists.

  /// Start syncing enquiries/records for any module.
  /// [collection] is the Firestore collection (e.g. 'crm_records').
  /// [enquiriesTableName] is the SQLite table (e.g. 'crm_enquiries').
  /// Delta sync: only fetches docs changed since the local watermark.
  /// Always syncs the user's full superset — team narrowing is a local-read
  /// concern (and would need extra composite indexes here).
  Future<void> startModuleEnquirySync(
    String userId,
    String collection,
    String enquiriesTableName, {
    String? userPhone,
  }) async {
    final hasPhone = userPhone != null && userPhone.isNotEmpty;
    // Reuse the live listeners when a module refresh re-attaches them.
    if (_isSyncActive('module_${collection}_byCreator_$userId') &&
        _isSyncActive('module_${collection}_byAssignee_$userId') &&
        _isSyncActive('module_${collection}_byParticipant_$userId') &&
        (!hasPhone ||
            _isSyncActive('module_${collection}_byAssigneePhone_$userPhone'))) {
      return;
    }

    final watermark = await _watermarkFor(enquiriesTableName);

    void _saveSnapshot(String key, QuerySnapshot snapshot) {
      _telEmit(key, snapshot);
      final enquiries = _confirmedFrom(snapshot, EnquiryModel.fromMap);
      LocalDatabaseService().saveModuleEnquiries(
        enquiries,
        tableName: enquiriesTableName,
      );
    }

    // Sync enquiries created by user
    _setSyncIfAbsent(
      'module_${collection}_byCreator_$userId',
      () => _afterWatermark(
        _firestore.collection(collection).where('createdBy', isEqualTo: userId),
        watermark,
      ).snapshots().listen(
        (s) => _saveSnapshot('module_${collection}_byCreator_$userId', s),
      ),
    );

    // Sync enquiries assigned to user
    _setSyncIfAbsent(
      'module_${collection}_byAssignee_$userId',
      () => _afterWatermark(
        _firestore
            .collection(collection)
            .where('assignedToUid', isEqualTo: userId),
        watermark,
      ).snapshots().listen(
        (s) => _saveSnapshot('module_${collection}_byAssignee_$userId', s),
      ),
    );

    // Sync enquiries where user is in participants
    _setSyncIfAbsent(
      'module_${collection}_byParticipant_$userId',
      () => _afterWatermark(
        _firestore
            .collection(collection)
            .where('participants', arrayContains: userId),
        watermark,
      ).snapshots().listen((s) {
        // A doc LEAVING this arrayContains(participants) result set means the
        // local user was just removed as a Sales/CRM assignee. Keep the row
        // (the card stays visible) but mark it Unassigned + accessRevoked so
        // it reads frozen and the composer goes read-only — mirrors the Task
        // participant listener. Rules deny the removed user's further reads/
        // sends, so this local row is their last legitimate snapshot. Only
        // fires online (live listener); offline removal has no signal here.
        for (final c in s.docChanges) {
          if (c.type == DocumentChangeType.removed &&
              !c.doc.metadata.hasPendingWrites &&
              !_docStillHasMember(c.doc, userId)) {
            LocalDatabaseService().markModuleEnquiryAccessRevoked(
              c.doc.id,
              tableName: enquiriesTableName,
            );
          }
        }
        _saveSnapshot('module_${collection}_byParticipant_$userId', s);
      }),
    );

    // Phone-based sync for non-app / UID-unresolved assignees — parity with
    // startTaskSync's 4th listener, so a Sales/CRM enquiry assigned to someone
    // by phone (their UID not yet resolved into assignedToUid/participants)
    // still delivers to their device. Needs the composite index
    // (assignedToPhone, updatedAt) on the module collection — see
    // firestore.indexes.json. onError degrades gracefully (logs, no zone error)
    // if that index isn't deployed yet; it never fires once it is.
    if (hasPhone) {
      _setSyncIfAbsent(
        'module_${collection}_byAssigneePhone_$userPhone',
        () => _afterWatermark(
          _firestore
              .collection(collection)
              .where('assignedToPhone', isEqualTo: userPhone),
          watermark,
        ).snapshots().listen(
          (s) => _saveSnapshot(
            'module_${collection}_byAssigneePhone_$userPhone',
            s,
          ),
          onError: (e) {
            print('[$collection] phone enquiry sync failed (needs index?): $e');
          },
        ),
      );
    }
  }

  void stopModuleEnquirySync(
    String userId,
    String collection, {
    String? userPhone,
  }) {
    _cancelSync('module_${collection}_byCreator_$userId');
    _cancelSync('module_${collection}_byAssignee_$userId');
    _cancelSync('module_${collection}_byParticipant_$userId');
    if (userPhone != null && userPhone.isNotEmpty) {
      _cancelSync('module_${collection}_byAssigneePhone_$userPhone');
    }
  }

  /// Start syncing ONE enquiry/record document (module detail screen).
  ///
  /// Parity with [startTaskDetailSync]. Without it a Sales/CRM chat opened
  /// straight from a deep link (notification tap, forward target, linked item)
  /// renders the header from whatever row SQLite already had — a status or
  /// assignee changed elsewhere stays stale until the list screen re-syncs.
  /// [tableName] is the module's SQLite table ([ModuleConfig.enquiriesTableName]).
  void startModuleDetailSync(
    String enquiryId,
    String collection, {
    required String tableName,
  }) {
    _setSyncIfAbsent(
      'moduleDetail_${collection}_$enquiryId',
      () => _firestore
          .collection(collection)
          .doc(enquiryId)
          .snapshots()
          .listen((snapshot) {
            _telEmitDoc('moduleDetail_${collection}_$enquiryId', snapshot);
            // Same guard as startTaskDetailSync: skip snapshots this device
            // hasn't confirmed yet. Offline they come from the cache with
            // pending serverTimestamps (which decode to now()) and
            // partially-known fields, and saving them overwrote the
            // authoritative local row.
            if (snapshot.exists && !snapshot.metadata.hasPendingWrites) {
              final enquiry = EnquiryModel.fromMap(
                snapshot.data() as Map<String, dynamic>,
                snapshot.id,
              );
              LocalDatabaseService().saveModuleEnquiry(
                enquiry,
                tableName: tableName,
              );
            }
          }),
    );
  }

  void stopModuleDetailSync(String enquiryId, String collection) {
    _cancelSync('moduleDetail_${collection}_$enquiryId');
  }

  /// Start syncing messages for an enquiry in any module collection.
  /// Bounded to a delta like [startMessageSync]; a fresh enquiry is capped at
  /// [_chatInitialFetchCap] because the module detail screen paginates older
  /// messages from Firestore on scroll-up.
  void startModuleMessageSync(String enquiryId, String collection) {
    _startBoundedChatSync(
      key: 'moduleMessages_${collection}_$enquiryId',
      resolveBound: () => _chatLowerBound(enquiryId),
      parentType: 'enquiry',
      resolveDoc: (id) =>
          _firestore.collection(collection).doc(enquiryId).collection(
                'messages',
              ).doc(id),
      buildQuery: (after) => _boundedChatQuery(
        _firestore
            .collection(collection)
            .doc(enquiryId)
            .collection('messages'),
        after,
        capWhenNoLocal: true,
      ),
    );
  }

  void stopModuleMessageSync(String enquiryId, String collection) {
    _releaseChatListener('moduleMessages_${collection}_$enquiryId');
  }

  /// One-shot pull of an enquiry's most recent 200 messages (fresh-install
  /// recovery). The streaming sync above is per-enquiry on chat open, so a
  /// fresh install has enquiries but no messages — and therefore no action
  /// index to draw card icon strips from. saveMessages' write-through
  /// repopulates the module actions table. Capped at the newest 200 so a
  /// fresh install never downloads every conversation in full.
  Future<void> fetchModuleMessagesOnceFor(
    String enquiryId,
    String collection,
  ) async {
    final snapshot = await _firestore
        .collection(collection)
        .doc(enquiryId)
        .collection('messages')
        .orderBy('createdAt')
        .limitToLast(200)
        .get();
    if (snapshot.docs.isEmpty) return;
    final msgs = snapshot.docs
        .map((doc) => MessageModel.fromMap(doc.data(), doc.id))
        .toList();
    await LocalDatabaseService().saveMessages(msgs, parentType: 'enquiry');
  }

  // ── Module System Logs (durable action log for Sales/CRM) ────────────
  // Parity with the task system_logs subcollection. Chat messages can be swept
  // by retention (and a fresh install starts with none), so the action history
  // that drives the detail screen's Activity log needs its own durable copy.
  // Doc id = the source message id, so rewrites from any device are idempotent.

  CollectionReference moduleSystemLogs(String enquiryId, String collection) {
    return _firestore
        .collection(collection)
        .doc(enquiryId)
        .collection('system_logs');
  }

  void startModuleSystemLogSync(String enquiryId, String collection) {
    _markLogInUse('moduleSystemLogs_${collection}_$enquiryId');
    _setSyncIfAbsent(
      'moduleSystemLogs_${collection}_$enquiryId',
      () => moduleSystemLogs(enquiryId, collection)
          .orderBy('createdAt', descending: true)
          .limit(_systemLogMirrorLimit)
          .snapshots()
          .listen((snapshot) {
            _telEmit('moduleSystemLogs_${collection}_$enquiryId', snapshot);
            final items = snapshot.docs
                .map(
                  (doc) => SystemLogModel.fromMap(
                    doc.data() as Map<String, dynamic>,
                    doc.id,
                  ),
                )
                .toList();
            final ids = snapshot.docs.map((d) => d.id).toList();
            // The shared SQLite system_logs table keys rows by parent id in its
            // `taskId` column — the same trick the shared `messages` table uses —
            // so an enquiryId rides it unchanged and no migration is needed.
            LocalDatabaseService().saveSystemLogs(enquiryId, items, ids);
          }),
    );
  }

  void stopModuleSystemLogSync(String enquiryId, String collection) {
    _releaseLogListener('moduleSystemLogs_${collection}_$enquiryId');
  }

  /// Write-through twin of [writeSystemLog] for module enquiries.
  Future<void> writeModuleSystemLog({
    required String enquiryId,
    required String collection,
    required String messageId,
    required String action,
    required String performedBy,
    required String details,
    required DateTime createdAt,
  }) async {
    try {
      await moduleSystemLogs(enquiryId, collection).doc(messageId).set(
        {
          'taskId': enquiryId,
          'action': action,
          'performedBy': performedBy,
          'details': details,
          'createdAt': Timestamp.fromDate(createdAt.toUtc()),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      print('[FirebaseService] writeModuleSystemLog failed: $e');
    }
  }

  /// Twin of [deleteSystemLog] for module enquiries (Sales / CRM).
  Future<void> deleteModuleSystemLog(
    String enquiryId,
    String collection,
    String messageId,
  ) async {
    try {
      await moduleSystemLogs(enquiryId, collection).doc(messageId).delete();
      SyncTelemetry.instance.recordWrite();
    } catch (e) {
      print('[FirebaseService] deleteModuleSystemLog failed: $e');
    }
  }

  /// Test Firebase connectivity and permissions
  Future<Map<String, dynamic>> testFirebaseConnection(String userId) async {
    final results = <String, dynamic>{};

    try {
      final taskSnapshot = await tasks().limit(1).get();
      results['tasks_read'] = 'OK (${taskSnapshot.docs.length} docs)';
    } catch (e) {
      results['tasks_read'] = 'FAILED: $e';
    }

    try {
      final querySnapshot = await tasks()
          .where('createdBy', isEqualTo: userId)
          .limit(1)
          .get();
      results['tasks_query'] = 'OK (${querySnapshot.docs.length} docs)';
    } catch (e) {
      results['tasks_query'] = 'FAILED: $e';
    }

    try {
      final taskSnapshot = await tasks().limit(1).get();
      if (taskSnapshot.docs.isNotEmpty) {
        final taskId = taskSnapshot.docs.first.id;
        final testPath = 'tasks/$taskId/messages';
        try {
          final docRef = await _firestore.collection(testPath).add({
            'test': true,
            'text': 'Firebase write test',
            'createdAt': FieldValue.serverTimestamp(),
          });
          await docRef.delete();
          results['messages_write'] = 'OK (write + delete succeeded)';
        } catch (e) {
          results['messages_write'] = 'FAILED: $e';
        }
      } else {
        results['messages_write'] = 'SKIPPED (no tasks exist)';
      }
    } catch (e) {
      results['messages_write'] = 'FAILED (task lookup): $e';
    }

    try {
      final userSnapshot = await users().limit(1).get();
      results['users_read'] = 'OK (${userSnapshot.docs.length} docs)';
    } catch (e) {
      results['users_read'] = 'FAILED: $e';
    }

    return results;
  }
}
