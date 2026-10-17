# WhatWorks — Sync & Database Architecture

A complete reference for how data moves between the phone, Firestore and the
server jobs: which method does what, when it runs, why it is shaped that way,
what it costs, and where the remaining risk and upside live.

**Status markers used throughout**

- ✅ implemented and shipping
- 🚧 approved, not yet implemented (tracked in §10)
- ⚠️ known weakness to watch (§11)

---

## 1. The model in one paragraph

The phone's SQLite database is the **only permanent store and the only source
of truth for the UI**. Firestore is a **transient relay**: it carries a write
from one device to the others and is then swept away by scheduled Cloud
Functions. Every screen reads SQLite synchronously and renders instantly; every
Firestore listener runs in the background and only ever *writes into* SQLite.
The UI never awaits the network. If the network is unavailable the app is fully
functional — it simply does not receive other people's changes until a listener
re-emits.

```
   ┌──────────────────────────────────────────────────────────────┐
   │                        PHONE (this device)                   │
   │                                                              │
   │  UI / Providers  ◄── reads ──  SQLite (whatworks_local.db)   │
   │       │                            ▲            │            │
   │       │ writes                     │ writes     │ notifies   │
   │       ▼                            │            ▼            │
   │  FirebaseService ──────────────────┘     tableChanges stream │
   │       │      ▲                                             │
   └───────┼──────┼─────────────────────────────────────────────┘
           │      │ listeners (delta, watermark-filtered)
            ▼      │
      ┌───────────────────────┐         ┌──────────────────────────┐
      │  Firestore (transient)│ ──────► │ Cloud Functions (sweeps) │
      │  tasks / *_enquiries  │         │ cleanupMessages    48 h  │
      │  messages subcoll.    │         │ cleanupOldAttachments 24h│
      └───────────────────────┘         └──────────────────────────┘
                 ▲
                 │ Firebase Storage (attachments, 24 h undownloaded)
```

---

## 2. Design rules — local vs Firebase

These are the invariants every change must respect. They are not style
preferences; each one exists because breaking it produced a real bug.

| # | Rule | Why |
|---|------|-----|
| R1 | **SQLite is authoritative.** A screen must be able to render completely with the radio off. | Offline is a normal state, not an error state. |
| R2 | **Firestore is never read by the UI directly.** Listeners write to SQLite; providers read SQLite. | Keeps one code path, so offline and online behave identically. |
| R3 | **A blank incoming value never clears a known local one.** `_keepLocalWhenBlank` + `_mergeLocalFirst`. | Firestore *cache* snapshots arrive partially populated and wiped assignee identity, dropping tasks out of the Assignee tab. |
| R4 | **Time only moves forward locally.** `_upsertRowIfChanged` rejects `incoming.updatedAt <= stored.updatedAt`; `_bumpTaskClockForward` never drags a task's clock back. | Replying to an old query used to re-sort the card and made the next server snapshot look "newer" than the local row. |
| R5 | **Unconfirmed server data is not stored.** Listeners skip docs where `metadata.hasPendingWrites` is true (`_confirmedFrom`). | A pending `serverTimestamp` decodes to `null` and the models substitute `DateTime.now()`, which poisons the delta watermark and then trips R4, so the *real* server row gets rejected. |
| R6 | **Server deletes are a repair net, not the primary path.** Clients delete their own delivered copies; the scheduled sweeps catch what clients missed. | Cheaper, faster, and works when the scheduler is down. |
| R7 | **Never evict local data by age.** `LocalStorageService.cleanupOldMessages()` is a deliberate no-op. | The server *does* delete after 48 h, so the phone is the last copy. |
| R8 | **One live listener per query key.** `_activeSyncs` registry; re-attaching is a bug, not a refresh. | Each re-attach costs a fresh billable result set plus a full cache decode on the UI isolate. |
| R9 | **Heavy CPU work must not run on the UI isolate.** Anything that deflates, encrypts, hashes or JSON-codes megabytes belongs in `Isolate.run`. | There is currently **no** `compute()` / `Isolate.run` anywhere in `lib/` — the single largest remaining source of freezes. |
| R10 | **Defer, stagger, and gate.** No background job runs in the first frames; each has a fixed slot; each is latched so it does not repeat. | See the startup ladder in §3. |

### 2.1 What lives where

| Data | SQLite | Firestore | Storage | Notes |
|---|---|---|---|---|
| Tasks / enquiries / CRM records | permanent | until swept | — | delta-synced by 3–4 listeners per owner |
| Chat messages | **permanent** | **48 h max** | — | after 48 h the phone holds the only copy |
| Action log (`actions`, `sales_actions`, `crm_actions`) | permanent | via `system_logs` subcollection | — | write-through derived from messages |
| Attachments (image/file/voice) | permanent (app docs) | metadata only | **24 h if never downloaded** | client deletes the server copy at download |
| Milestones, system logs | permanent | per-task subcollections | — | full replace-and-delete-missing sync |
| Teams | **local only** | none | — | no Firestore team sync exists |
| Phone contacts | SharedPreferences cache | none | — | 1 h TTL + change listener |
| Settings / prefs | SharedPreferences | none | — | included in backups |

---

## 3. Startup timeline — what runs when

Every deferred job has a fixed slot so no two heavy jobs overlap the
first-frame window. This ladder is the answer to *"the app goes slow after a few
seconds of start"*: nothing is slow at t=0 because nothing runs at t=0; the cost
arrives in a staggered wave between t=5 s and t=20 s.

| t | Job | Entry point | Cost | Status |
|---|-----|-------------|------|--------|
| 0 | `Firebase.initializeApp`, Firestor e `CACHE_SIZE_UNLIMITED`, `runApp` | `main()` | small | ✅ |
| 0 | `MilestoneSettingsService.warmCache()` × 3 modules | `main()` | 3 prefs reads | ✅ |
| 0 | `UploadRetryService().startPeriodicRetry()` | `main()` | **every 30 s forever** | ⚠️ 🚧 |
| 0 | SQLite open + first `getTasks` + icon preload | `TaskProvider.loadTasks` | full scan + sort | ✅ |
| first frame | theme, app-lock gate, contacts cache warm | `HomeScreen.initState` | small | ✅ |
| **5 s** | 4 task listeners attach | `startTaskSync` | 4 delta queries | ✅ no longer re-attaches on resume |
| **6 s** | FCM init: `requestPermission` (modal dialog) + `tz.initializeTimeZones()` + `getToken()` + Firestore token write | `NotificationService.initialize` | modal + network | ⚠️ stalls offline |
| **8 s** | `preLoadContacts()` — whole phonebook over the platform channel, map + sort, then `getTeamMembers()` | `HomeScreen` | 0.3–1.5 s UI block on a large book | 🚧 cache-first |
| **9 s** | `_backfillActionsIfNeeded()` | `main()` | **2 cheap queries when latched**; full messages scan only on a fresh install | ✅ correctly gated |
| **12 s** | `LocalStorageService.cleanupOldMessages()` | `HomeScreen` | **no-op by design** (R7) | ✅ |
| **12 s** | `_repairAssigneeIdentityFields()` | `TaskProvider` | all contacts + per-task `users.where(phone)` + writes that re-trigger all 4 listeners | ⚠️ 🚧 needs latch + cap |
| **15 s** | `_recoverMissingMessages()` | `TaskProvider` | unbounded history per task, 5 in parallel | ⚠️ 🚧 `limitToLast(200)`, 2 at a time |
| **20 s** | `BackupService().runAutoBackupIfDue()` | `HomeScreen` | all 14 tables + base64 attachments + deflate + PBKDF2 100 000 + AES — **all on the UI isolate** | ⚠️ 🚧 isolate + fingerprint skip |
| every resume | `loadTasks(force: true)` | `HomeScreen.didChangeAppLifecycleState` | full SQLite reload + full rebuild | 🚧 gate on elapsed background time |

**Recurring jobs**

| Cadence | Job | Note |
|---|---|---|
| 30 s | `UploadRetryService.retryPendingUploads` | `SELECT *` over pending/failed uploads. Index added (v22); polling itself still needs replacing. |
| 300 ms debounce | `tableChanges` → `_reloadTasksFromSQLite` | now coalesced, one trailing pass |
| 300 ms debounce | `tableChanges('actions')` → `_reloadActionIcons` | now suppresses no-op notifies |
| daily | `cleanupOldAttachments` (server) | repair net |
| every 48 h | `cleanupMessages` (server) | the real deletion path |

---

## 4. The database layer — `LocalDatabaseService`

A singleton over `sqflite`, file `whatworks_local.db`, **version 22**. All
schema evolution goes through `_onCreate` (fresh install) *and* `_onUpgrade`
(existing install) — an index or column added only to `_onCreate` silently never
reaches existing users.

### 4.1 How a write becomes a pixel (the chain)

Understanding this chain is the key to understanding every performance problem
in the app. **One row written to SQLite can rebuild the entire home screen.**

```
 any write (user action, listener, retry, repair)
   │
   ├─ db.insert / db.update / batch.commit
   │
   └─ _notify('tasks' | 'messages' | 'actions')      ← broadcast stream
        │
        ├─ tableChangesDebounced('tasks', 300 ms)
        │     └─ TaskProvider._reloadTasksFromSQLite()
        │           ├─ getTasks(userId)              ← full scan + sort
        │           ├─ split into byMe / toMe / participant
        │           ├─ _preloadActionIcons()         ← batched LIMIT queries
        │           └─ notifyListeners()
        │                 └─ context.watch<TaskProvider>() at the ROOT of
        │                    HomeScreen.build → the whole ~3370-line screen
        │                    rebuilds and re-runs filter + sort
        │
        └─ tableChangesDebounced('actions', 300 ms)
              └─ _reloadActionIcons() → reloadActionIconsFor()
                    └─ notifyListeners() only if rows actually changed ✅
```

Two amplifiers make this expensive:

1. `_bumpTaskClockForward` notifies `'tasks'` — so **every incoming chat
   message** walks the whole chain above, even though only `lastMessageTime`
   changed.
2. `context.watch<TaskProvider>()` sits at the top of `HomeScreen.build`, so
   there is no widget-level isolation: a single notify rebuilds every card.

Mitigations shipped: reload coalescing (§6.2) and no-op notify suppression
(§6.3). Mitigation still open: replacing the root `watch` with `Selector`s.

### 4.2 Change notification

| Method | Behaviour | Efficiency |
|---|---|---|
| `_notify(table)` | pushes the table name onto a broadcast `StreamController` | O(1), fire-and-forget |
| `tableChanges` | raw stream — **every** write emits | a burst of 500 inserts = 500 events |
| `tableChangesDebounced(table, window: 300 ms)` | per-table controller that restarts a timer on each event and emits once after 300 ms of quiet | a burst collapses to **one** event. This is what providers subscribe to. |

Design note: the debounce is **trailing-only** with no max-wait. A write stream
that never goes quiet for 300 ms postpones the reload indefinitely. In practice
sync bursts are short, so this is acceptable; a `maxWait` would be the fix if
that ever changes.

### 4.3 Write path — entities

`saveTasks(list)` → `_upsertRowsIfChanged('tasks', rows)`;
`saveEnquiries` / `saveModuleEnquiries` follow the same shape.

```
_upsertRowsIfChanged(table, rows)
  1. rows.isEmpty → return                                  (no write, no notify)
  2. ONE query: SELECT * FROM table WHERE id IN (…)           (batch read)
  3. per row:
       stored == null                → write (new on device)
       incoming.updatedAt <= stored  → SKIP  (R4: unchanged or stale)
       otherwise                     → _mergeLocalFirst(row, stored) → write (R3)
  4. batch.commit  → _notify(table)
```

Why it is efficient: one read for the whole batch, and rows that did not change
produce neither a write nor a notification. This is the difference between a
listener emission costing 200 writes and costing 0.

Why `_mergeLocalFirst` exists (R3): an offline cache snapshot carries
`createdBy`, `assignedToUid`, `assignedTo`, `lastMessageText`, … as blank or
partial. A plain `INSERT OR REPLACE` wiped them and the task vanished from the
Assignee tab until a restart re-synced it. The merge copies stored values back
over blank incoming ones — only for keys present in **both** maps, so the module
enquiry tables (different column sets) stay safe.

`_upsertRowIfChanged` (singular) does the same for one row, used by
`saveTask`.

### 4.4 Write path — messages

```
saveMessages(list, {parentType})
  1. empty → return
  2. SELECT id, sequenceNumber FROM messages WHERE id IN (…)   (one query)
  3. keep only rows whose sequenceNumber differs or is new     (skip-if-unchanged)
  4. nothing left → return                                     (no write, no notify)
  5. batch insert (ConflictAlgorithm.replace) → _notify('messages')
  6. _bumpTaskClockForward(latest message)                     → may _notify('tasks')
  7. for EACH written message: write-through into the actions table
```

Step 7 is the expensive tail and is worth understanding precisely:

- `Helpers.detectActionType(message.text)` runs first. For ordinary chat text it
  returns `null` and the loop body exits immediately — **plain messages cost
  nothing here**.
- For an *action* message (task, follow-up, reminder, query, …) with
  `parentType == null` — which is what the task message listener passes — the
  write-through resolves the parent type with **up to 3 sequential queries**
  (`tasks`, then `enquiries`, then `crm_enquiries`), then one more query for the
  denormalised `clientName` / `parentTitle`, then an insert. That is 4–5 round
  trips **per action message**, awaited one after another.
- A bulk history load of 200 messages containing 50 actions therefore issues
  ~250 sequential queries. 🚧 Passing the correct `parentType` from the caller
  removes the first 3 queries for free; memoising parent
  `(clientName, parentTitle, type)` per `taskId` for the duration of the batch
  removes the rest.

`_bumpTaskClockForward(db, taskId, stamp)` reads the task's current
`updatedAt` / `lastMessageTime` and writes only the columns that are actually
behind `stamp`. If both are already at or ahead, it writes nothing and emits
nothing. This is R4 applied to the message path: loading a year of chat history
must not drag the card to the bottom of the home list.

`saveMessage` (singular) is the interactive send path — it always writes, always
notifies, always bumps and always writes through, because a message the user just
sent must appear immediately.

### 4.5 Read path

| Method | Query | Efficiency |
|---|---|---|
| `getTasks(userId)` | `SELECT * FROM tasks WHERE createdBy = ? OR assignedToUid = ? OR participants LIKE '%"uid"%' ORDER BY updatedAt DESC` | ⚠️ **Full scan + temp sort.** The `OR` across three columns defeats any single index, and `LIKE '%…%'` on the JSON-encoded `participants` array can never use one. Cost grows with *all* tasks on the device, not the user's. Proper fix: a `task_participants(taskId, uid)` join table (§10). |
| `getActionIconsForParents(ids, limit: 100)` | per parent: `WHERE parentId = ? ORDER BY createdAt DESC LIMIT ?`, all inside **one batch**, chunked at 100 parents | ✅ Now an index range scan with early termination (`idx_actions_parent_createdAt`). Previously selected **every** action row of **every** parent including the `text` column, sorted the lot in a temp B-tree and sliced down to 100 in Dart — thousands of decoded rows per card refresh. |
| `getMaxUpdatedAt(table)` | `SELECT MAX(updatedAt)` | ⚠️ Whole-table MAX with no index on `updatedAt`. Used for the sync watermark, so a single row with a future timestamp used to poison every delta query — now clamped in `_watermarkFor` (§5.2). |
| `getMessages(taskId, limit)` | `WHERE taskId = ?` ordered by `createdAt` | ✅ served by `idx_messages_taskId` |
| `getMessagesBefore(taskId, before, limit: 30)` | `WHERE taskId = ? AND createdAt < ?` DESC | ✅ local pagination for chat scroll-up |
| `getRetryableUploadMessages()` | `SELECT * … WHERE fileUrl IN ('pending','failed') ORDER BY createdAt ASC` | ✅ index-served since v22 (`idx_messages_fileUrl_createdAt`); ⚠️ still returns **all columns** including `text` and `searchableContent`. 🚧 gate on `SELECT COUNT(*)` first. |
| `getTaskIdsWithMessages()` | distinct `taskId` from messages | used once per fresh install |
| `getActionCount()` / `getTotalMessageCount()` | `COUNT(*)` | cheap gates for the backfill latch |

### 4.6 Indexes and what each one serves

Added in **v22** (both `_onCreate` and an `if (oldVersion < 22)` branch in
`_onUpgrade`, with `IF NOT EXISTS`):

| Index | Serves |
|---|---|
| `idx_messages_fileUrl_createdAt (fileUrl, createdAt)` | the 30 s upload-retry poll and `cleanupStalePendingMessages` — both were full scans |
| `idx_actions_parent_createdAt (parentId, createdAt DESC)` | task card icon strips |
| `idx_sales_actions_parent_createdAt` | sales card icon strips |
| `idx_crm_actions_parent_createdAt` | CRM card icon strips |

⚠️ **Platform constraint:** `android/app/build.gradle.kts` uses
`flutter.minSdkVersion`, so the system SQLite may be older than 3.25. **Window
functions (`ROW_NUMBER() OVER (…)`) are not safe** and must not be introduced.
The batched per-parent `LIMIT` pattern in `_actionIconsForParentsFrom` is the
portable equivalent.

### 4.7 Deletion locally

Nothing is ever aged out. The only local deletes are:

- explicit user delete (`deleteTask`, `deleteMessage`) — which also removes the
  matching `actions` row,
- `purgeDeletedTasks(daysThreshold: 30)` — soft-deleted tasks older than 30 days,
  gated to one Firestore purge query per day,
- `cleanupStalePendingMessages(maxAgeMinutes: 30)` — flips `pending` uploads to
  `failed` (does not delete),
- `clearSessionData()` on logout.

`LocalStorageService.cleanupOldMessages()` prints
`"Cleanup disabled — phone is permanent storage"` and returns. **Keep it that
way** (R7) — the server deletes messages at 48 h, so an aged-out local copy is
unrecoverable.

---

## 5. The sync layer — `FirebaseService`

A singleton wrapping `FirebaseFirestore.instance`. It owns the listener
registry, the delta watermark, and every read/write to Firestore.

### 5.1 Listener registry

```dart
final Map<String, StreamSubscription> _activeSyncs = {};

void _cancelSync(String key);                       // remove + cancel
void _setSync(String key, sub);                     // cancel old, attach new
bool _isSyncActive(String key);                     // ✅ registry check
void _setSyncIfAbsent(String key, () => sub);       // ✅ attach only if free
void stopAllSync();                                 // logout
```

Keys are structured and stable, which is what makes deduplication possible:

| Key pattern | Listener |
|---|---|
| `tasks_byCreator_<uid>` | tasks I created |
| `tasks_byAssigneeUid_<uid>` | tasks assigned to my UID |
| `tasks_byParticipant_<uid>` | tasks where I am in `participants` |
| `tasks_byAssigneePhone_<phone>` | tasks assigned to my phone (non-app assignee) |
| `task_<taskId>` | single task (detail screen) |
| `messages_<taskId>` | one chat |
| `milestones_<taskId>`, `systemLogs_<taskId>` | task subcollections |
| `enquiries_by{Creator,Assignee,Participant}_<uid>` | sales |
| `enquiryMessages_<enquiryId>` | one sales chat |
| `module_<collection>_by{Creator,Assignee,Participant}_<uid>` | CRM / generic |
| `moduleMessages_<collection>_<enquiryId>` | one CRM chat |

**Why R8 matters:** `_setSync` cancels and re-subscribes. A re-subscribed query
does not resume from where it left off — Firestore sends the **entire current
result set** again (billable reads) and the client decodes every cached doc on
the UI isolate. `HomeScreen.didChangeAppLifecycleState` calls
`loadTasks(force: true)` on *every* resume, so unlocking the phone used to tear
down and rebuild four queries. `startTaskSync` now early-returns when all of its
keys are already live ✅; the six per-entity listeners still need the same
treatment 🚧.

### 5.2 Watermark delta sync

```dart
static const Duration _watermarkOverlap = Duration(minutes: 5);

Future<Timestamp?> _watermarkFor(String table) async {
  final maxMs = await LocalDatabaseService().getMaxUpdatedAt(table);
  if (maxMs == null) return null;                 // empty table → full first sync
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final anchorMs = maxMs > nowMs ? nowMs : maxMs; // ✅ never anchor in the future
  return Timestamp.fromMillisecondsSinceEpoch(anchorMs - _watermarkOverlap.inMilliseconds);
}

Query _afterWatermark(Query q, Timestamp? w) =>
    w == null ? q : q.where('updatedAt', isGreaterThan: w);
```

Design: the watermark is derived from **`MAX(updatedAt)` in SQLite**, not from a
SharedPreferences timestamp. That makes it self-healing — it cannot drift from
the data actually on the device, and restoring a backup automatically rewinds
it. The 5-minute overlap absorbs clock skew and the gap between a message's
`createdAt` (used for the local bump) and the parent's `serverTimestamp`
`updatedAt`.

The clamp ✅ exists because `getMaxUpdatedAt` is a whole-table MAX: one row with
a future `updatedAt` (device clock ahead, or a pre-R5 pending-write row that
decoded `null` to `now()`) pushed the watermark past the present, every later
delta query matched nothing, and **sync silently stopped delivering while
looking healthy**.

Composite Firestore indexes for all four delta queries already exist in
`firestore.indexes.json` — a delta query without a matching index fails at
runtime, not at build time.

⚠️ Consequence of delta sync worth remembering: the listeners only ever see
*changed* docs. They therefore **cannot detect remote deletes**. A task deleted
on another device stays in local SQLite until `purgeDeletedTasks` or an explicit
soft-delete flag arrives as a change.

### 5.3 The pending-write filter (R5)

```dart
List<T> _confirmedFrom<T>(QuerySnapshot snap, T Function(Map<String,dynamic>, String) build) {
  final out = <T>[];
  for (final doc in snap.docs) {
    if (doc.metadata.hasPendingWrites) continue;   // not yet server-confirmed
    out.add(build(doc.data() as Map<String,dynamic>, doc.id));
  }
  return out;
}
```

Offline — and for a moment after every local write — Firestore emits straight
from its cache with `hasPendingWrites == true`. `serverTimestamp` fields are
still `null`, and both `TaskModel.fromMap` and `MessageModel.fromMap` fall back
to `DateTime.now()`. Storing those rows caused two separate failures:

1. the row's `updatedAt` became the device clock, poisoning
   `getMaxUpdatedAt` and hence the watermark;
2. when the server-confirmed emission arrived seconds later with the *real*
   (often slightly older) timestamp, R4's direction check rejected it — so the
   authoritative row never landed.

The confirmed emission always follows, so nothing is lost by waiting.

**Not applied** to `startMilestoneSync` and `startSystemLogSync`: those pass the
complete doc-id list to a replace-and-delete-missing save, where filtering would
delete locally created rows.

Applied to: the 4 task listeners ✅. Still to apply: the message, enquiry and
module listeners 🚧.

### 5.4 Listener inventory

| Method | Query | Watermark | Reuse-if-active | Pending filter |
|---|---|---|---|---|
| `startTaskSync` | 3–4 filtered task queries | ✅ | ✅ | ✅ |
| `startTaskDetailSync` | `tasks.doc(id).snapshots()` | n/a (single doc) | 🚧 | ✅ (has its own guard) |
| `startMessageSync` | `messages.orderBy('createdAt').snapshots()` — **no limit** | ❌ | 🚧 | 🚧 |
| `startMilestoneSync` | `milestones.orderBy('dueDate')` | ❌ | 🚧 | intentionally none |
| `startSystemLogSync` | `system_logs.orderBy('createdAt')` | ❌ | 🚧 | intentionally none |
| `startEnquirySync` | 3 filtered sales queries | ✅ | 🚧 | 🚧 |
| `startEnquiryMessageSync` | enquiry messages, no limit | ❌ | 🚧 | 🚧 |
| `startModuleEnquirySync` | 3 filtered CRM queries | ✅ | 🚧 | 🚧 |
| `startModuleMessageSync` | module messages, no limit | ❌ | 🚧 | 🚧 |

⚠️ **Message listeners have no watermark and no limit.** Opening a chat
re-reads the *entire conversation* every time. Worse, opening a task detail
screen runs `fetchMessagesOnce` **and** `startMessageSync` for the same task —
the same history read twice in the same second.

⚠️ **Adding `limitToLast()` to the live listener is not a drop-in change.**
Pagination in `task_detail_screen._loadMoreMessages` and
`base_module_provider.loadOlderMessages` is **local-only** — they slice SQLite /
`messagesCache`, and neither issues a Firestore `startAfter`. Truncating the
listener without first adding a server-side older-history fetch would
permanently cap on-device history.

### 5.5 One-shot fetches

| Method | Purpose | Note |
|---|---|---|
| `fetchMessagesOnceFor(taskId)` | fresh-install history recovery | leaves **no** persistent listener behind; `saveMessages` write-through rebuilds the actions index as a side effect. 🚧 add `limitToLast(200)`. |
| `fetchModuleMessagesOnceFor(enquiryId, collection)` | same for sales/CRM | same shape |
| `get()` with `Source.serverAndCache` | prefetch helpers | non-blocking when offline |

### 5.6 Write path to Firestore

| Method | Behaviour |
|---|---|
| `sendMessage` | writes the message doc with `createdAt: serverTimestamp()` and bumps the parent's `updatedAt` |
| `updateTask` | awaits any in-flight create for the same id (`_pendingCreates`) before writing |
| `updateTaskField` | partial update; used by the identity repair |
| `createTask` | registers a `Future` in `_pendingCreates` keyed by doc id |
| `writeSystemLog` | `set(merge: true)` with doc id = message id, so rewrites from any device are idempotent |

`_pendingCreates` exists because an activation update that landed *before* the
create `set()` was clobbered by it — the task snapped back to draft on the next
sync. Any new "create then immediately update" flow must go through it.

⚠️ Every `updateTaskField` from the identity repair bumps `updatedAt`, which
re-triggers **all four** task listeners, which write to SQLite, which notifies,
which reloads and rebuilds. A repair pass over 50 tasks is 50 full reload cycles.

---

## 6. Provider layer

`TaskProvider` is the base; `SalesProvider` and `CrmProvider` extend
`BaseModuleProvider`, which mixes in `ModuleCachesMixin` — so the caching and
reload logic is shared, and a fix in the mixin lands in all three modules.

### 6.1 Caches owned by `ModuleCachesMixin`

| Cache | Shape | Filled by |
|---|---|---|
| `messagesCache` | `parentId → List<MessageModel>` | `loadCachedMessages`, `fetchMessagesOnce`, `prefetchMessagesInto` |
| `actionIconsCache` | `parentId → List<Map>` (actionType, isReplied, isDone, createdAt, id, text) | `preloadActionIconsFor`, `reloadActionIconsFor` |

Three module hooks keep the mixin generic: `fetchActionIcons(ids)` (which actions
table), `startMessageSyncFor(id)` (which collection), `prefetchMessageLimit`.

`prefetchMessagesInto` starts a **persistent Firestore listener per parent** —
that would leak listeners badly, but it currently has **zero call sites**. It is
dead code. ⚠️ Do not wire it up without converting it to one-shot fetches.

### 6.2 Reload coalescing ✅

```dart
bool _reloadInFlight = false;
bool _reloadQueued   = false;

void _reloadTasksFromSQLite() {
  if (_reloadInFlight) { _reloadQueued = true; return; }   // collapse
  _reloadInFlight = true; _reloadQueued = false;
  LocalDatabaseService().getTasks(_currentUserId)
    .then(… split lists, preload icons, notifyListeners …)
    .catchError(…)
    .whenComplete(() {
      _reloadInFlight = false;
      if (_reloadQueued) { _reloadQueued = false; /* one trailing pass, 150 ms */ }
    });
}
```

Before this, a burst of writes produced *concurrent* full reloads: two
`getTasks` full scans, two icon preloads and two `notifyListeners` overlapping
on the UI isolate. Now overlapping calls collapse into exactly one trailing
pass.

### 6.3 No-op notify suppression ✅

`reloadActionIconsFor` compares the freshly fetched rows against
`actionIconsCache` row by row (`_iconRowsEqual` — Maps have no deep equality)
and calls `notifyListeners()` **only when something the cards render actually
changed**. Action writes that leave the visible strips identical are common
during the startup backfill and on every chat-message clock bump; each one used
to rebuild the entire home screen.

### 6.4 The remaining amplifier ⚠️

`context.watch<TaskProvider>()` at the top of `HomeScreen.build` means every
notify rebuilds the whole screen and re-runs filter + sort. The correct shape is
`Selector<TaskProvider, …>` per slice (counts, visible page, filter state) so a
change to one card does not rebuild the other nineteen.

`BaseModuleProvider.refresh(userId)` has the same re-attach problem as
`loadTasks`: it calls `startEnquirySync` / `startModuleEnquirySync`, which
currently cancel and re-subscribe three queries each.

---

## 7. Server side — `functions/index.js`

One `CHAT_COLLECTIONS = ['tasks', 'sales_enquiries', 'crm_records']` list drives
every sweep, so all three modules share identical retention behaviour. Deployed
to `whatworks-68786`.

### 7.1 `cleanupMessages` — cron `0 3 */2 * *` (03:00 UTC, every 2nd day)

```
for each collection in CHAT_COLLECTIONS:
  entities = collection.where('updatedAt', '>', now - 168 h).get()
  for each entity:
    participants = entityParticipants(entity)          // creator + assignees + participants
    if none -> skip entity
    for each message in entity.messages.get():         // <- whole subcollection
      if message.deleted -> skip
      age = now - message.createdAt
      if age > 48 h            -> DELETE (force)        // MESSAGE_MAX_RETENTION_HOURS
      else if every participant has readBy[uid] -> DELETE (early)
```

`SWEEP_LOOKBACK_HOURS = 168` windows the *entity* scan, which is what keeps the
job cheap at scale. It is safe because every `sendMessage` bumps the parent's
`updatedAt`, so an entity with live messages always sits inside the window; the
7-day size tolerates multi-day scheduler outages.

⚠️ **The early-delete branch is effectively dead code.** `allRead` requires a
`readBy` receipt from *every* participant **including the sender**, and the
client only marks messages *from other people* as read
(`detail_chat_plumbing`). The sender's own receipt is never written, so
`allParticipants.every(...)` can never be true. In practice **all** deletion
happens through the 48-hour force branch. This does not lose data — it means
retention is a flat 48 h rather than "as soon as everyone has read it".

⚠️ The inner `messages.get()` is unbounded per entity — a task with 10 000
messages reads 10 000 docs every sweep. Reads are billed.

### 7.2 `cleanupOldAttachments` — `every 24 hours`

`RETENTION_HOURS = { free: 24, paid: 24 }` — the tiers are currently identical.
Rules, in order:

1. delete when **all recipients** have a `downloadedBy` receipt (client-driven,
   the normal path),
2. delete on retention expiry — **24 h for an undownloaded file, both tiers**,
3. delete once the parent entity is closed,
4. orphan sweep: Storage objects under `tasks/` and `sales/` older than 24 h
   that no live message doc references.

The client is the primary deleter: `trackAttachmentDownload` (callable, accepts
`entityId` + `collection`, falls back to `tasks`) records the receipt, and
`StorageService.maybeDeleteServerAttachment` deletes the server copy at download
time. The scheduled job is only the repair net.

### 7.3 Storage triggers

`onMessageSoftDeleted_<coll>` and `onMessageDeleted_<coll>` are registered per
collection. The legacy tasks-only `onMessageSoftDeleted` /
`onMessageDeletedForEveryone` and the old `cleanupReadMessages` /
`cleanupSalesMessages` were removed with
`firebase functions:delete --force` before the redeploy — **non-interactive
deploys abort on orphaned functions unless they are deleted first.**

### 7.4 Client-side sweep

`_runChatCleanupSweep(planType)` runs ~8 s after a chat is opened
(`detail_chat_bubbles`). It deletes this device's own message docs once all
*recipients* have read them, with a minimum age of **24 h for premium** and
**1 h for basic** (the 1 h floor preserves the edit / delete-for-everyone
window). `maybeDeleteServerAttachment` re-reads the doc fresh and compares
`fileUrl` before deleting, so it cannot delete a re-uploaded attachment.

This is the path that actually keeps Firestore small; the server sweeps are the
safety net.

---

## 8. Deletion audit — *"is delivered data being deleted?"*

### 8.1 Locally: never

No time-based eviction exists. `cleanupOldMessages()` is a no-op, attachments
are never purged, and the only deletes are explicit user actions, the 30-day
soft-delete purge, and logout. **The phone keeps everything forever** (R7).
This is correct and must stay correct, because of 8.2.

### 8.2 Server-side: yes, aggressively

| Object | Deleted after | Trigger |
|---|---|---|
| Message doc | **48 h**, regardless of read status | `cleanupMessages`, every 2nd day |
| Message doc | as soon as all *recipients* read it | client sweep (`_runChatCleanupSweep`) |
| Attachment | when all recipients have `downloadedBy` | client at download time |
| Attachment | **24 h if never downloaded**, both tiers | `cleanupOldAttachments`, daily |
| Attachment | on entity close | `cleanupOldAttachments` |
| Orphan Storage object | 24 h unreferenced | `cleanupOldAttachments` |

**Net effect:** a device that stays offline for more than 48 h after a message
was sent will **never** receive that message — it is gone from the relay before
the device reconnects. Same for an attachment after 24 h. This is the accepted
trade-off of the minimal-server strategy: the phone is the only guarantee, and
delivery is only assured while devices come online within the window.

Because the sweep runs every 48 h and the force-delete threshold is 48 h, real
message lifetimes are 48–96 h (a message created just after a sweep survives
until the one two days later).

### 8.3 The latent hazard ⚠️

Both the early-delete branch and the attachment "all recipients downloaded"
rule derive their recipient set from the entity's **`participants` array**. If a
recipient is missing from `participants` — exactly the corruption
`_repairAssigneeIdentityFields` exists to fix — the sweep concludes everyone has
read/downloaded and **deletes the doc before that person ever received it**.
Their copy is then unrecoverable, because R7 only protects data that actually
arrived.

This makes the identity repair a *data-integrity* job, not a cosmetic one. It
also means: never weaken the repair, and never let `participants` be written
from a partial source.

### 8.4 Sync efficiency verdict

| Aspect | Verdict |
|---|---|
| Reads when nothing changed | ✅ near zero — delta watermark + reuse-if-active |
| Reads on app resume | ✅ fixed for tasks (`startTaskSync` early-return); 🚧 modules still re-attach |
| Reads on chat open | ⚠️ full conversation, twice (`fetchMessagesOnce` + `startMessageSync`) |
| Writes -> UI rebuilds | ✅ coalesced + no-op suppressed; ⚠️ root `context.watch` still rebuilds everything |
| Fresh install | ⚠️ unbounded history download for every task, 5-way parallel |
| Steady-state background | ⚠️ 30 s poll forever, including while backgrounded |
| CPU on UI isolate | ⚠️ backup (deflate + PBKDF2 100 k + AES), contacts (jsonEncode MBs) |
| Correctness | ✅ R3/R4/R5 close the offline cache-snapshot class of bugs |

---

## 9. Background jobs — deep dive

### 9.1 `UploadRetryService` ⚠️ 🚧

**Today:** `Timer.periodic(30 s)` started in `main()`. Each tick runs
`getRetryableUploadMessages()` (`SELECT *` over pending/failed), then per row
re-uploads from the attachments directory, updates `fileUrl`, and re-delivers
the message doc to Firestore after resolving the parent collection with up to 3
more queries (`tasks` -> `enquiries` -> `crm_enquiries`).

`_isRetrying` prevents overlap. The index added in v22 removed the full scan.

**What is still excess:** the poll runs forever, including while the app is
paused, on devices that have never had a pending upload.

**Approved replacement:** event-driven. One pass at startup; then subscribe to
`tableChanges` filtered to `'messages'` with a ~10 s debounce; each pass first
runs an index-only `SELECT COUNT(*)` and returns immediately when it is zero;
when work exists, reschedule with backoff 30 s -> 60 s -> 120 s -> cap 5 min,
resetting on a successful upload; cancel the timer entirely while paused and
re-arm on resume via `WidgetsBindingObserver`.

### 9.2 Actions backfill ✅ (already correct)

`_backfillActionsIfNeeded()` at t=9 s:

```
prefs.getBool('actions_backfill_done')      -> return if latched
db.getActionCount() > 0                     -> latch and return
db.getTotalMessageCount() == 0              -> return WITHOUT latching
db.backfillActionsFromMessages()            -> latch
```

The third step is the subtle one: on a fresh install messages have not synced
yet, and latching on an empty database would permanently prevent indexing the
messages that arrive later through non-write-through routes. So a normal launch
costs two cheap queries and nothing else.

⚠️ The latch key is device-global, not per-user. A second account signed in on
the same device never gets its own backfill.

### 9.3 Message recovery ⚠️ 🚧

`_recoverMissingMessages()` at t=15 s: set-difference between all known task ids
and `getTaskIdsWithMessages()`, then `fetchMessagesOnceFor` for each missing
task, 5 at a time, latched per user in prefs (`messages_recovered_<uid>`). If
the task list is empty the latch is **not** set, so it retries next launch.

**Why it exists:** message sync is per-task on chat open, so a fresh install has
tasks but no messages and therefore no actions index — card icon strips and the
Actions tabs stay empty until the user manually opens every chat.

**Approved trim:** `limitToLast(200)` per task, parallelism 5 -> 2, and a yield
between batches. Accepted trade-off: on a fresh install, actions older than the
newest ~200 messages of a task are not indexed until that chat is opened.

### 9.4 Identity repair ⚠️ 🚧

`_repairAssigneeIdentityFields()` at t=12 s, once per session per user
(`_identityRepairDoneFor`). Builds a name -> (phone, uid) map from team members
plus the phonebook (only if permission is already granted — never prompts from a
background timer), then for each of *my* tasks with 2+ assignees rebuilds
`assigneeUids` / `assigneePhones` per name, unions the resolved uids into
`participants`, fixes contradicting primary fields, and writes via
`updateTaskField`.

Guards already in place: `uidForPhone` consults `db.getCachedUid` before
querying Firestore; a resolution that produced nothing at all does not overwrite
stored values with empties; a stored **creator** uid in an assignee slot is
treated as the corruption signature and never carried over.

**What is still excess:** it walks *every* one of my tasks on *every* launch,
and each write re-triggers all four task listeners. 🚧 Add a per-task latch and
a per-launch cap (e.g. 10 repairs), so a device converges over a few launches
instead of paying the full sweep forever.

### 9.5 Auto backup ⚠️ 🚧

`runAutoBackupIfDue()` at t=20 s: gated on `auto_backup_enabled`, a stored
password, and `auto_backup_frequency` (daily / weekly / monthly) vs
`auto_backup_last_run`. Keeps the 5 newest `whatworks_auto_*` files.

`exportBackup` then, **on the UI isolate**: reads all 14 tables into memory,
`base64Encode`s every attachment into the manifest, `_createZip`
(`ZipEncoder().encode`, then `base64Decode` per file on the way back in),
`_encrypt` (PBKDF2 **100 000 iterations** + AES-256-CBC), and writes the file.

**Approved trims:** (a) run zip + PBKDF2 + AES inside `Isolate.run` — the crypto
strength is unchanged, it just stops freezing the UI; (b) skip the whole export
when a cheap fingerprint (per-table row count + `MAX(updatedAt|createdAt)`, plus
attachment count/bytes) matches the fingerprint stored with the last run;
(c) pass raw `Uint8List` for attachments and drop the base64 round-trip, which
saves ~33 % peak memory and two full passes over the data.

Note: `_exportSharedPreferences()` currently includes **every** pref, including
the multi-megabyte `phone_contacts_cache` blob. Excluding derived caches was
considered and **not** selected — they stay in the archive for now.

### 9.6 Contacts preload ⚠️ 🚧

`preLoadContacts()` at t=8 s warms `PremiumStatusService` and
`AvatarCacheService` from SQLite, then — if permission is already granted —
calls `FlutterContacts.getContacts(withProperties: true)`, builds
`_phonebookNameLookup` (phone -> name) for every number of every contact, maps
all of them to `AssignableContact`, sorts, calls `getTeamMembers()` (Firestore)
and starts the contact-change listener.

Separately, `getPhoneContacts()` calls `_savePhoneContactsCache()` whenever
there is no search query, which `jsonEncode`s **all** contacts into a single
SharedPreferences string and rewrites the prefs XML.

Two mechanisms already exist but are not used by the startup path:
`_loadPhoneContactsCache()` (with `_phoneContactsLastSync`) and the 1-hour
staleness rule the picker applies. `FlutterContacts.addListener` ->
`_onContactsChanged()` invalidates both caches the moment the phonebook changes,
which is what makes a warm cache trustworthy while the process lives.

**Approved trim:** cache-first startup — a warm cache builds the lookup from the
persisted `AssignableContact` list with **zero** platform-channel traffic; only
a cold or stale cache does the full fetch, and the persist step is gated on an
order-independent fingerprint (count + commutative hash of normalised phone,
name and uid) so an unchanged phonebook costs a short string compare instead of
a megabyte write. The 1-hour TTL and the "never prompt for permission at
startup" behaviour are preserved.

---

## 10. Future efficiency improvements (ranked)

Ordered by (user-visible impact) ÷ (risk + effort).

| # | Change | Payoff | Risk |
|---|---|---|---|
| 1 | **Isolate offload** for backup zip/PBKDF2/AES (R9) | removes the largest single freeze in the app | none — pure relocation |
| 2 | **Backup fingerprint skip** | most scheduled backups become free | none |
| 3 | **Contacts cache-first + fingerprint-gated persist** | removes 0.3–1.5 s of UI-isolate deserialization and a MB-scale prefs write per launch | low — TTL and change listener already exist |
| 4 | **Reuse-if-active for the 6 remaining listeners** | halves chat-open reads; stops module refresh re-attaching 3 queries | low |
| 5 | **Pending-write filter on message/enquiry listeners** | closes the last of the R5 bug class | low |
| 6 | **Event-driven upload retry + COUNT gate** | removes a forever-30 s poll | low — needs pause/resume handling |
| 7 | **`limitToLast(200)` recovery, 2 at a time** | fresh install stops downloading everything | medium — older actions unindexed until chat open |
| 8 | **Resume gate** on `loadTasks(force: true)` | unlocking the phone stops costing a full reload | low |
| 9 | **Identity-repair latch + cap** | stops a full sweep every launch | medium — must still converge |
| 10 | **Pass `parentType` into `saveMessages` + memoise parent fields per batch** | removes ~4 sequential queries per action message during bulk loads | low |
| 11 | **`Selector` instead of root `context.watch` in HomeScreen** | a single card change stops rebuilding 20 cards | medium — large widget, needs careful slicing |
| 12 | **Real chat pagination** (`limitToLast` listener + Firestore `startAfter` older-history fetch) | chat open becomes O(window) instead of O(conversation) | medium — 3 files, new UI state |
| 13 | **`task_participants` join table** | replaces the `LIKE '%uid%'` full scan in `getTasks` with an indexed join | high — migration + every write path |
| 14 | **Index `updatedAt`** on tasks/enquiries | makes `getMaxUpdatedAt` O(log n) instead of a full scan | low |
| 15 | **Fix the server early-delete branch** (exclude the sender from `allRead`) | retention becomes "as soon as everyone read it" instead of a flat 48 h | server change — deferred by decision |
| 16 | **Bound the server sweep's inner `messages.get()`** | cuts scheduled-function read bills | server change — deferred by decision |

Items 1–11 are the approved local batch. Items 15–16 are server-side and were
explicitly deferred ("don't touch the server").

---

## 11. Potential issues to watch for

**Sync correctness**

1. **Future-dated `updatedAt` anywhere.** One row poisons `getMaxUpdatedAt`, and
   because it is a whole-table MAX the effect is global. The clamp in
   `_watermarkFor` contains the damage; the source (device clock skew, or any
   code path that writes `DateTime.now()` into `updatedAt`) is not eliminated.
   Never remove the clamp.
2. **Any new listener that stores cache snapshots.** If it writes without the
   `hasPendingWrites` filter it reopens the R5 bug class: the row lands with a
   device-clock timestamp, then the real server row is rejected by R4 and the
   data silently never updates.
3. **`_keepLocalWhenBlank` coverage.** Adding a new identity-bearing column to
   `tasks` without adding it to that list means an offline cache snapshot can
   blank it again.
4. **Delta sync cannot see remote deletes.** A task deleted on another device
   stays in local SQLite forever. Any future "delete everywhere" feature needs a
   tombstone field, not a Firestore delete.
5. **`participants` is the recipient set for server deletion.** A missing
   participant causes premature, unrecoverable deletion (§8.3). Treat every
   write to `participants` as safety-critical.
6. **The 48 h window vs an offline device.** A user on a long flight, or a
   secondary device that is off for a weekend, loses messages permanently. This
   is by design; it becomes a support issue as the user base grows.

**Database**

7. **Schema changes must be made twice** — `_onCreate` *and* `_onUpgrade`. An
   index added only to `_onCreate` never reaches existing installs, and the
   symptom is "slow for some users, fast for others".
8. **No window functions.** `minSdkVersion` is the Flutter default, so the
   system SQLite may be < 3.25. `ROW_NUMBER() OVER (...)` and friends can crash
   at runtime on older devices. Use the batched per-parent `LIMIT` pattern.
9. **`getTasks` cost grows with the whole table**, not the user's share, because
   of the `LIKE`. On a device with many teams this becomes the dominant reload
   cost — and the reload runs on every write.
10. **`tableChangesDebounced` has no max-wait.** A write stream that never goes
    quiet for 300 ms starves the UI of updates entirely.
11. **`prefetchMessagesInto` leaks a persistent listener per parent.** Dead code
    today. Wiring it up as-is would attach hundreds of Firestore listeners.

**Performance**

12. **No isolates anywhere.** Every future feature that hashes, zips, encrypts,
    decodes JSON at scale, or processes images will freeze the UI unless R9 is
    enforced in review.
13. **Root `context.watch<TaskProvider>()`.** Any new `notifyListeners()` call
    added anywhere in the provider costs a full home-screen rebuild. Prefer
    notifying only when rendered state actually changed (as
    `reloadActionIconsFor` now does).
14. **`_bumpTaskClockForward` notifies `'tasks'`.** Every incoming message
    triggers a full task reload. If message volume grows, consider a dedicated
    `lastMessageTime`-only path that patches the in-memory list instead of
    re-reading SQLite.
15. **The startup ladder has fixed slots, not a queue.** Adding a new job at
    t=8 s silently collides with contacts. Keep §3 as the single registry of
    slots, and prefer "run when idle" over "run at t=N".

**Server**

16. **`RETENTION_HOURS.free === RETENTION_HOURS.paid === 24`.** Premium users
    get no extra attachment grace despite the tiering being wired up.
17. **The early-delete branch never fires** (§7.1), so retention is a flat 48 h.
    If it is ever fixed, message lifetimes drop sharply — verify clients can
    still fetch history they expect to have.
18. **Non-interactive function deploys abort on orphaned functions.** Deleting
    or renaming an exported function requires
    `firebase functions:delete --force <name>` first.

---

## 12. Quick reference — where to change what

| I want to… | Touch |
|---|---|
| add a table/column/index | `local_database_service.dart` — `_onCreate` **and** `_onUpgrade`, bump `_dbVersion` |
| change what a listener stores | `firebase_service.dart` — use `_confirmedFrom`, never a raw `snapshot.docs.map` |
| add a new background sync | `firebase_service.dart` — stable key, `_setSyncIfAbsent`, add to the matching `stop...` |
| change delta-sync reach | `_watermarkFor` / `_watermarkOverlap` |
| change how often the UI reloads | `tableChangesDebounced` window, `_reloadTasksFromSQLite`, `reloadActionIconsFor` |
| change what a card renders | `ModuleCachesMixin` caches + `getActionIconsForParents` |
| change retention/deletion | `functions/index.js` (**server — currently frozen by decision**) |
| change startup ordering | `main.dart` + `HomeScreen.initState` — then update §3 |
| change backup contents | `backup_service.dart` — `_exportTable` list, `_collectAttachmentFiles`, `_backupVersion` |
| change contact caching | `contact_picker_service.dart` — `_savePhoneContactsCache`, `_loadPhoneContactsCache`, `preLoadContacts`, `_onContactsChanged` |
| change upload retries | `upload_retry_service.dart` + `getRetryableUploadMessages` |

---

### Related documents in this repository

- `MINIMAL_SERVER_STRATEGY.md` — the original rationale for treating Firestore
  as a transient relay.
- `LOCAL_STORAGE_INTEGRATION.md` — the SQLite integration design.
- `FIRESTORE_INDEXES_GUIDE.md` — composite index requirements for the delta
  queries; a delta query without a matching index fails at runtime.
- `FCM_SETUP_GUIDE.md` — the notification path that runs at t=6 s.
- `WHATSAPP_FEATURES_SPEC.md`, `TASK_EDIT_MESSAGE_SPEC.md` — feature-level specs
  that generate the messages this pipeline carries.
