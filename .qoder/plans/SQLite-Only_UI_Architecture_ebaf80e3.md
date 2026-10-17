# SQLite-Only UI Architecture

## Current Architecture (Problem)

```
Firebase stream --> UI (direct read) --> also saves to SQLite (side effect)
```

The UI directly consumes Firestore streams in:
- `task_detail_screen.dart` lines 805-807 (message stream), 1029-1031 (task stream)
- `sales_detail_screen.dart` line 135 (message stream)
- `task_provider.dart` lines 357-421 (3 task query streams)
- `sales_provider.dart` line 81 (getTeams fetches from Firestore)

## Target Architecture

```
Firebase sync (background) --> SQLite --> UI reads only from SQLite
```

Firebase's role reduced to:
1. **Send** data for delivery to others (write operations)
2. **Receive** data from others --> immediately write to SQLite
3. **Never** read by the UI directly

---

## Phase 1: SQLite Change Notification System

### `local_database_service.dart`

Add a broadcast `StreamController` that fires after every write. This lets the UI "watch" SQLite for changes without polling:

```dart
final _tableChangesController = StreamController<String>.broadcast();
Stream<String> get tableChanges => _tableChangesController.stream;

// In every save/delete method, after the write:
_tableChangesController.add('messages');  // or 'tasks', 'milestones', etc.
```

Affected methods: `saveMessage`, `saveMessages`, `deleteMessage`, `saveTask`, `saveTasks`, `deleteTask`, `saveEnquiry`, `saveTeam`, `saveTeams`, `saveMilestone`, `saveMilestones`, `deleteMilestone`, `saveSystemLog`, `saveSystemLogs`, `saveTaskDraft`, `deleteTaskDraft`.

---

## Phase 2: Background Sync Service

### `firebase_service.dart` -- Transform from "stream provider" to "sync service"

**Remove** all public stream-returning methods:
- `messageStream(taskId)` -- remove
- `taskStream(taskId)` -- remove
- `tasksByCreator(userId)` -- remove
- `tasksByAssignee(userId)` -- remove
- `tasksByParticipant(userId)` -- remove
- `_mergeTaskStreams()` -- remove
- `_taskQueryStream()` -- remove
- `milestoneStream(taskId)` -- remove
- `systemLogStream(taskId)` -- remove
- `userStream(uid)` -- remove
- `getMessagesFromCache()` -- remove (SQLite replaces this)

**Add** background sync methods that listen to Firestore and write to SQLite only:

```dart
// Start all background sync -- called once at app startup after login
void startBackgroundSync(String userId) {
  _syncTasks(userId);
  // Other syncs can be started on-demand when screens open
}

// Sync tasks for home screen
void _syncTasks(String userId) {
  // Listen to Firestore queries, write results to SQLite, done.
  // No stream returned to caller.
}

// Sync messages for a specific task chat
void startMessageSync(String taskId) {
  // Listen to messages collection, write to SQLite, done.
}

// Sync single task for detail screen
void startTaskSync(String taskId) {
  // Listen to task doc, write to SQLite, done.
}

// Sync milestones, system_logs for a task
void startMilestoneSync(String taskId) { ... }
void startSystemLogSync(String taskId) { ... }
```

**Keep** all write operations (these are Firebase's job):
- `sendMessage()`, `updateMessage()`, `deleteMessage()`
- `createTask()`, `updateTask()`, `deleteTask()`
- `addMilestone()`, `updateMilestone()`, `deleteMilestone()`
- `addSystemLog()`
- `saveTaskDraft()`, `deleteTaskDraft()`

**Keep** local DB getters (for providers to read from SQLite):
- `getTasksFromLocal()`, `getTaskDraftsFromLocal()`
- `getMilestonesFromLocal()`, `getSystemLogsFromLocal()`
- `getAllTaskIdsFromLocal()`

---

## Phase 3: SQLite-Backed Streams for UI

### `local_database_service.dart` -- Add stream helpers

```dart
/// Stream that re-queries SQLite whenever a watched table changes.
Stream<List<MessageModel>> watchMessages(String taskId) {
  return tableChanges
    .where((table) => table == 'messages')
    .transform(StreamTransformer.fromHandlers(
      handleData: (_, sink) {
        getMessages(taskId, limit: 10000).then(sink.add);
      },
    ));
}

Stream<List<TaskModel>> watchTasks(String userId, {String? field, Object? value}) { ... }
Stream<List<MilestoneModel>> watchMilestones(String taskId) { ... }
Stream<List<SystemLogModel>> watchSystemLogs(String taskId) { ... }
```

These return SQLite-backed streams. The UI subscribes to these instead of Firestore.

---

## Phase 4: Update Providers

### `task_provider.dart`

**Before:** Loads from SQLite first, then subscribes to Firestore streams which overwrite the data.

**After:** Only reads from SQLite. Calls `_firebaseService.startSync(userId)` to trigger background sync. The sync writes to SQLite, which triggers `tableChanges`, which re-queries SQLite.

```dart
Future<void> loadTasks(String userId) async {
  // Start background sync (writes Firestore data to SQLite)
  _firebaseService.startBackgroundSync(userId);
  
  // Read from SQLite only -- data arrives via tableChanges stream
  _byMeTasks = await LocalDatabaseService().getTasks(userId)
    .then((tasks) => tasks.where((t) => t.createdBy == userId).toList());
  // ... same for _toMeTasks, _participantTasks
  notifyListeners();
}

// Expose SQLite-backed stream instead of Firestore stream
Stream<List<MessageModel>> messageStream(String taskId) {
  return LocalDatabaseService().watchMessages(taskId);
}
```

### `sales_provider.dart`

**Before:** Loads teams from SQLite first, then fetches from Firestore.

**After:** Only reads from SQLite. Background sync writes to SQLite.

```dart
Future<void> loadTeams(String userId) async {
  _firebaseService.startTeamSync(userId);
  _teams = await _service.getTeamsFromLocal(userId);
  // ... restore selected team
  notifyListeners();
}
```

---

## Phase 5: Update Screens

### `task_detail_screen.dart`

**Before:** `_loadMessagesFromFirebase()` loads from SQLite, then subscribes to Firestore stream which processes all messages.

**After:** Subscribes to SQLite-backed stream only. Calls `_firebaseService.startMessageSync(taskId)` to start background sync.

```dart
void _loadMessages() {
  // Start background sync
  _firebaseService.startMessageSync(_currentTask.id);
  _firebaseService.startTaskSync(_currentTask.id);
  _firebaseService.startMilestoneSync(_currentTask.id);
  _firebaseService.startSystemLogSync(_currentTask.id);
  
  // Subscribe to SQLite-backed stream
  _messagesSubscription = taskProvider
    .messageStream(_currentTask.id)  // now returns SQLite stream
    .listen((messages) {
      // Process messages from SQLite (same logic as before)
    });
}
```

### `sales_detail_screen.dart`

**Before:** `_subscribeToMessages()` loads from SQLite, then subscribes to Firestore stream.

**After:** Subscribes to SQLite-backed stream only.

```dart
void _subscribeToMessages() {
  _firebaseService.startEnquiryMessageSync(_enquiry.id);
  _messageSub = LocalDatabaseService().watchMessages(_enquiry.id).listen((msgs) {
    // Process messages from SQLite
  });
}
```

---

## Phase 6: Cleanup

- Remove `_loadFromLocalDatabase()` from screens (no longer needed -- the stream IS SQLite)
- Remove `isSameData` deduplication checks (no longer needed -- single source of truth)
- Remove `_loadedFromLocalDb` / `_loadedMessageIds` flags
- Remove `getMessagesFromCache()` from firebase_service (SQLite replaces it)
- Remove `cloud_firestore` imports from screens/providers (they should never touch Firestore)

---

## Sync Lifecycle Management

Each `start*Sync()` method returns a `StreamSubscription` that can be cancelled:

```dart
// In firebase_service.dart
final Map<String, StreamSubscription> _activeSyncs = {};

void startMessageSync(String taskId) {
  _activeSyncs['messages_$taskId']?.cancel();
  _activeSyncs['messages_$taskId'] = messages(taskId)
    .snapshots()
    .listen((snapshot) {
      final msgs = snapshot.docs.map(...).toList();
      LocalDatabaseService().saveMessages(msgs);
    });
}

void stopMessageSync(String taskId) {
  _activeSyncs.remove('messages_$taskId')?.cancel();
}
```

Screens call `stopMessageSync()` in `dispose()` to clean up.

---

## Files Changed

| File | Change |
|------|--------|
| `local_database_service.dart` | Add `tableChanges` stream + `watch*()` helpers |
| `firebase_service.dart` | Remove all public streams, add `start*Sync()` / `stop*Sync()` methods |
| `task_provider.dart` | Read from SQLite only, use `startBackgroundSync()` |
| `sales_provider.dart` | Read from SQLite only, use `startTeamSync()` |
| `task_detail_screen.dart` | Subscribe to SQLite stream, remove local DB load + dedup logic |
| `sales_detail_screen.dart` | Subscribe to SQLite stream, remove local DB load + dedup logic |
| `sales_service.dart` | Remove `streamMessages()` (replaced by SQLite watch) |
