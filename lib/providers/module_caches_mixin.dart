import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';
import '../services/local_database_service.dart';

/// Shared per-card caches for list providers (TaskProvider is the base;
/// BaseModuleProvider reuses the same logic for sales/CRM enquiries).
///
/// Owns the message cache and the action-icons cache plus the common
/// preload/reload/prefetch flows, and the one-shot fresh-install message
/// recovery sweep that repopulates them. Module differences are limited to
/// hooks: which actions table to batch-read, how to kick the background
/// message sync, the prefetch page size, and the recovery adapters.
mixin ModuleCachesMixin on ChangeNotifier {
  /// Cache of messages per parent (task/enquiry id).
  final Map<String, List<MessageModel>> messagesCache = {};

  /// Action icons cache: parentId -> list of {actionType, isReplied, isDone, text}
  final Map<String, List<Map<String, dynamic>>> actionIconsCache = {};

  /// Bumped every time [actionIconsCache] actually changes content (a strip
  /// appeared / disappeared / flipped done). The enquiry list screens gate
  /// their rebuild on an ENQUIRY-signature fingerprint so a burst of
  /// unread-count / clock-bump notifies can't re-decode every card — but that
  /// gate also swallows the icon-only `notifyListeners()` that the late
  /// backfill / message-recovery / sync path fires, so cards built from an
  /// empty cache (the actions index populated AFTER the initial preload) never
  /// refreshed their chips while the Actions tab (an independent live stream
  /// on the actions table) showed the actions fine. Consumers that gate on the
  /// enquiry signature must ALSO watch this counter.
  int actionIconsVersion = 0;

  /// Batch-read action icon rows for the given parents from the module's
  /// actions table (1 DB call instead of N).
  @protected
  Future<Map<String, List<Map<String, dynamic>>>> fetchActionIcons(
    List<String> parentIds,
  );

  /// Start the Firestore -> SQLite background message sync for one parent.
  @protected
  void startMessageSyncFor(String parentId);

  /// Message page size used by [prefetchMessagesInto].
  @protected
  int get prefetchMessageLimit;

  /// Get cached action icons for a parent (synchronous, for card rendering).
  List<Map<String, dynamic>>? getActionIcons(String parentId) {
    return actionIconsCache[parentId];
  }

  /// Get cached messages for a parent (used by Actions tab / cards).
  List<MessageModel>? getCachedMessages(String parentId) {
    return messagesCache[parentId];
  }

  /// Load messages from SQLite into the cache.
  Future<List<MessageModel>> loadCachedMessages(
    String parentId, {
    int limit = 10,
  }) async {
    final msgs = await LocalDatabaseService().getMessages(
      parentId,
      limit: limit,
    );
    if (msgs.isNotEmpty) {
      messagesCache[parentId] = msgs;
      notifyListeners();
    }
    return msgs;
  }

  /// Preload action icons for the given parents (called before
  /// notifyListeners to avoid double rebuild). Returns whether any icon strip
  /// actually changed, so the caller can skip a notify that would rebuild every
  /// card for identical strips.
  @protected
  Future<bool> preloadActionIconsFor(List<String> parentIds) async {
    if (parentIds.isEmpty) return false;
    final batchResult = await fetchActionIcons(parentIds);
    var changed = false;
    for (final entry in batchResult.entries) {
      if (!_iconRowsEqual(actionIconsCache[entry.key], entry.value)) {
        changed = true;
        break;
      }
    }
    actionIconsCache.addAll(batchResult);
    if (changed) actionIconsVersion++;
    return changed;
  }

  /// Reload action icons for the given parents from the actions table.
  /// If [skipNotify] is true, don't call notifyListeners().
  ///
  /// Even without [skipNotify] the notification is skipped when the fetched
  /// rows are identical to what is already cached: each notify rebuilds the
  /// whole list screen (filter + sort + every card), and action writes that
  /// leave the visible strips untouched are common during the startup
  /// backfill and every chat-message clock bump.
  @protected
  void reloadActionIconsFor(List<String> parentIds, {bool skipNotify = false}) {
    if (parentIds.isEmpty) return;
    fetchActionIcons(parentIds).then((batchResult) {
      if (batchResult.isEmpty) return;
      var changed = false;
      for (final entry in batchResult.entries) {
        if (!_iconRowsEqual(actionIconsCache[entry.key], entry.value)) {
          changed = true;
          break;
        }
      }
      actionIconsCache.addAll(batchResult);
      if (changed) actionIconsVersion++;
      if (!skipNotify && changed) notifyListeners();
    });
  }

  /// Row-by-row comparison of two icon strips (Maps have no deep equality).
  bool _iconRowsEqual(
    List<Map<String, dynamic>>? cached,
    List<Map<String, dynamic>> fresh,
  ) {
    if (cached == null || cached.length != fresh.length) return false;
    for (int i = 0; i < fresh.length; i++) {
      final a = cached[i];
      final b = fresh[i];
      if (a.length != b.length) return false;
      for (final entry in b.entries) {
        if (a[entry.key] != entry.value) return false;
      }
    }
    return true;
  }

  /// Prefetch messages for multiple parents in parallel from SQLite (used by
  /// the Actions tab). Also triggers background syncs to warm the cache.
  /// Only parents not already cached are fetched.
  @protected
  Future<void> prefetchMessagesInto(List<String> parentIds) async {
    if (parentIds.isEmpty) return;

    final idsToFetch = <String>[];
    for (final id in parentIds) {
      if (!messagesCache.containsKey(id)) {
        idsToFetch.add(id);
      }
    }
    if (idsToFetch.isEmpty) return;

    // Start background syncs to warm Firestore -> SQLite pipeline
    for (final id in idsToFetch) {
      startMessageSyncFor(id);
    }

    // Fetch all parents in PARALLEL from SQLite
    final futures = <Future<void>>[];
    for (final id in idsToFetch) {
      futures.add(
        LocalDatabaseService()
            .getMessages(id, limit: prefetchMessageLimit)
            .then((messages) {
              messagesCache[id] = messages;
            })
            .catchError((e) {
              print('[ModuleCaches] Error fetching messages for $id: $e');
              messagesCache[id] = [];
            }),
      );
    }

    await Future.wait(futures);
    notifyListeners();
  }

  // ── Fresh-install message recovery (shared one-shot sweep) ─────────────
  // A fresh install syncs the parent docs (tasks/enquiries) but NOT their
  // messages — message sync is per-parent on chat open — so the actions index
  // that drives the card icon strips and Actions tabs stays empty until every
  // chat is opened. This pulls the history for parents with no local messages
  // once, then latches; saveMessages' write-through rebuilds the index and its
  // table-change notify re-fires the icon reload. Written ONCE here and shared
  // by TaskProvider + BaseModuleProvider (Sales/CRM) so the sweep can't drift;
  // the module surface is just the hooks below.

  Timer? _messageRecoveryTimer;

  /// Schedule the one-shot recovery [delay] after sync settles. Idempotent:
  /// re-arming cancels any pending sweep, so a user switch (which re-runs
  /// loadTasks/loadEnquiries) simply retargets it at the now-current user —
  /// the latch key and candidate IDs are read live when it fires.
  void scheduleMessageRecovery({
    Duration delay = const Duration(seconds: 15),
  }) {
    _messageRecoveryTimer?.cancel();
    _messageRecoveryTimer = Timer(delay, recoverMissingMessages);
  }

  /// Cancel any pending recovery sweep (call from the provider's dispose).
  void cancelMessageRecovery() => _messageRecoveryTimer?.cancel();

  /// Log tag for recovery messages (e.g. 'tasks' or the module table name).
  @protected
  String get recoveryScope;

  /// SharedPreferences latch key. MUST be stable per user (+module) so the
  /// sweep runs at most once and retries on the next launch only if it never
  /// latched (i.e. sync hadn't settled / no parents were present to check).
  @protected
  String get recoveryLatchKey;

  /// IDs of all currently-loaded parents to check for missing local messages.
  @protected
  Set<String> get recoveryCandidateIds;

  /// Parallel fetch batch size (module-tuned: task histories are larger).
  @protected
  int get recoveryBatchSize;

  /// One-shot history fetch for a single parent — routes to the module's
  /// Firestore message collection.
  @protected
  Future<void> fetchMessagesForRecovery(String id);

  /// The shared recovery algorithm. A no-op if already latched or if
  /// [recoveryCandidateIds] is still empty (sync not settled — retries next
  /// launch). Best-effort: any failure just means icons fill in on chat open.
  Future<void> recoverMissingMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final flagKey = recoveryLatchKey;
      if (prefs.getBool(flagKey) ?? false) return;

      final candidateIds = recoveryCandidateIds;
      if (candidateIds.isEmpty) return; // Sync not settled — retry next launch

      final withMessages =
          await LocalDatabaseService().getTaskIdsWithMessages();
      final missing = candidateIds.difference(withMessages).toList();

      // Small parallel batches — each fetch decodes a full chat history. The
      // yield between batches lets pending frames and listener callbacks run
      // so the sweep never monopolises the UI isolate.
      final size = recoveryBatchSize;
      for (var i = 0; i < missing.length; i += size) {
        final slice = missing.skip(i).take(size);
        await Future.wait(
          slice.map(
            (id) => fetchMessagesForRecovery(id).catchError((e) {
              print('[$recoveryScope] message recovery failed for $id: $e');
            }),
          ),
        );
        await Future.delayed(Duration.zero);
      }
      await prefs.setBool(flagKey, true);
    } catch (e) {
      // Best-effort — icons still fill in as chats are opened.
      print('[$recoveryScope] message recovery failed: $e');
    }
  }
}
