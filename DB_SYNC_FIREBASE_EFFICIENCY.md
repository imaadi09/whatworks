# DB / Sync / Firebase Efficiency — Status & Roadmap

**Scope:** SQLite (`whatworks_local.db`, schema **v23**), the Firestore sync layer, and the
provider/rebuild path — for **all three modules at once** (Task, Sales, CRM), because they run
on one shared substrate.

**Approach (conservative):** *measure first, optimize second.* Rather than apply risky
read/write reductions blind, we shipped an **in-app diagnostics tool** so the real db/sync/
Firebase load can be observed on a device during normal testing, and only then change the
hot paths that the numbers justify. End-user output must stay byte-identical, so anything
that could truncate history or drop an edit is deferred until it can be done safely.

---

## 1. How to measure (shipped this task)

A hidden, purely-observational telemetry layer. It **never** changes sync/read/write behaviour;
every recorder short-circuits on one boolean when disabled, so production cost is nil.

**Unlock:** Settings ▸ **About** row → tap the version row **5 times quickly** → a *Developer*
section appears with a **Diagnostics** tile. (Persisted; works on release APKs.)

**Two views:**
- **Diagnostics panel** (`DiagnosticsScreen`) — full breakdown, polls at 1 Hz.
- **Floating badge** (`DiagnosticsBadge`) — draggable glance overlay on every screen:
  `R<reads> W<writes> L<listeners> N<notifies>`, edge/dot colored by worst severity.
  Tap it to open the panel.

**Controls in the panel:** `Record telemetry` (master switch), `Floating badge`, `Reset counters`.

### Metrics collected (shared layer → covers Task + Sales + CRM together)

| Area | Metric | Where recorded |
|---|---|---|
| Firestore | active listeners (gauge) | `FirebaseService._setSyncIfAbsent` / `_cancelSync` |
| Firestore | per-listener **attaches**, emissions, **initialDocs** (attach cost), deltaDocs, **maxInitialDocs** | `_telEmit` on the message/enquiry/module-message listeners |
| Firestore | writes (docs) | `sendMessage` (=2), `updateMessage`, `deleteMessage`, `markMessageRead`, `markMessagesDelivered` (=chunk) |
| SQLite | per-op count / avg ms / max ms / rows | `getMessages`, `saveMessages` (incl. the no-op diff path), `getTasks`, `saveTasks`, `getModuleEnquiries`, `saveModuleEnquiries` |
| Provider | reload invoked / executed / coalesced | `TaskProvider._reloadTasksFromSQLite` |
| Provider | notifyListeners count | override in `TaskProvider` **and** `WorkItemProvider` (Sales+CRM) |
| Provider | change-set patches (rows) vs full reloads | `ChangeSetConsumerMixin` |

**Severity color coding** (green = ok, amber = warn, red = crit) — heuristic "worth a look"
thresholds, not hard limits:

| Metric | warn | crit |
|---|---|---|
| `getTasks` / `getModuleEnquiries` avg ms | > 40 | > 100 |
| `getMessages` avg ms | > 20 | > 60 |
| `saveMessages` / `saveTasks` / `saveModuleEnquiries` avg ms | > 50 | > 150 |
| listener `maxInitialDocs` | > 150 | > 400 |
| active listeners | > 10 | > 16 |
| notifies / min | > 90 | > 180 |
| reloads / min | > 60 | > 120 |
| writes / min | > 60 | > 150 |

> **Reading the panel:** a chat listener key like `messages_<taskId>` with a large **maxInit**
> (red) is the signature of the unbounded full-conversation read (see R1). A high **reloads/min**
> with a high **coalesced** count means bursts are being absorbed correctly. A high
> **change-set full reloads** vs **patches** means bursts are exceeding the 40-row patch threshold.

---

## 2. Changes DONE

### 2A. Freeze / leak fixes (this task)
The reported symptom — *"screen stuck after a while; taps on Action tab / menu don't respond"* —
traced to two leaked periodic timers that keep firing (and re-notifying) after their screen is gone.

- **Leak A — `sales_detail_screen.dart`:** `dispose()` now calls `disposeDetailChatPlumbing()`.
  The 15 s connectivity (DNS) monitor timer was never stopped on this screen. **This one fix
  covers Sales *and* CRM**, since they share the same detail screen via `ModuleConfig`.
- **Leak B — `task_detail_screen.dart`:** `_onTaskCreated` now calls `_autoActivateTimer?.cancel()`
  **before** reassigning it, so the old 1-minute periodic timer can't be orphaned.

### 2B. In-app diagnostics / telemetry (this task)
New files: `lib/services/sync_telemetry.dart` (singleton), `lib/screens/settings/diagnostics_screen.dart`,
`lib/widgets/diagnostics/diagnostics_badge.dart`.
Instrumented (shared layers): `firebase_service.dart`, `local_database_service.dart`,
`change_set_consumer_mixin.dart`, `task_provider.dart`, `work_item_provider.dart`.
Wired: `main.dart` (restore prefs before `runApp`; badge mounted in `MaterialApp.builder` above the
Navigator via a root `navigatorKey`) and `settings_screen.dart` (hidden 5-tap unlock + Developer tile).

### 2C. Already landed earlier (committed `33b066e`) — recap
- **Watermark delta sync for tasks/enquiries:** `_watermarkFor(table)` = `getMaxUpdatedAt` minus a
  5-min overlap, clamped to now; `_afterWatermark` adds `.where('updatedAt', isGreaterThan: …)`.
  List listeners therefore pull only changed rows, not the whole collection.
- **Pending-write filter:** `_confirmedFrom(snapshot)` skips `metadata.hasPendingWrites` docs (a
  cache snapshot's null `serverTimestamp` otherwise poisons the `MAX(updatedAt)` watermark).
- **Listener reuse:** `_setSyncIfAbsent` / `_isSyncActive` reuse an active subscription instead of
  cancel-and-re-attach.
- **Bounded one-shot history:** `fetchMessagesOnceFor` / `fetchModuleMessagesOnceFor` capped at
  `limitToLast(200)`.
- **Direction-aware upserts:** `_upsertRow(s)IfChanged` skip rows whose incoming `updatedAt` ≤ stored
  and preserve local-only identity columns; `saveMessages` **already diff-skips unchanged writes**.
- **Reload coalescing:** `_reloadInFlight` / `_reloadQueued` collapse bursts into one trailing pass;
  **no-op notify suppression** in `reloadActionIconsFor`.
- **Indexes (schema v22→v23):** `messages(fileUrl, createdAt)`, `actions/sales_actions/crm_actions(parentId, createdAt DESC)`,
  `tasks(updatedAt)`, `enquiries(updatedAt)`; batched per-parent icon-strip fetch.

### 2D. Gate (this task)
`flutter analyze --no-pub` → **0 errors, 0 warnings**, 973 info (baseline unchanged).
`flutter build apk --release --target-platform android-arm64` → **Built app-release.apk (28.2 MB)**, EXIT=0.

---

## 3. Findings — where the load actually is

1. **Firestore reads — dominant cost is the unbounded message listener.**
   `startMessageSync` (`messages(taskId).orderBy('createdAt').snapshots()`) and the enquiry/module
   equivalents have **no `limit` and no watermark**. Because the detail screen's `dispose()` stops
   the listener, **every chat re-open re-attaches and Firestore re-bills the entire conversation**
   (`initialDocs` grows with thread length). Task/enquiry *list* listeners are watermarked and cheap;
   message listeners are not.
2. **Firestore writes** are already lean: a send is 2 writes (message doc + task `lastMessage` bump);
   delivery/read use batches.
3. **SQLite — `getTasks` is the one structural hot spot.**
   `SELECT * FROM tasks WHERE createdBy = ? OR assignedToUid = ? OR participants LIKE '%"uid"%'
   ORDER BY updatedAt DESC` — the leading-wildcard `LIKE` on the JSON `participants` array cannot use
   an index, and it loads **all** tasks (not paginated) on every full reload. `saveMessages` already
   diff-skips; `getMessages` / `getMessagesBefore` are paginated (50 / 30).
4. **Provider / rebuild churn.** Reload coalescing + change-set patching are in place. Remaining cost is
   the **home rebuild**: `_attentionCount` eagerly allocates `[...byMeTasks, ...toMeTasks]` on every
   build for the drawer badge (mirrored in `sales_home_screen`).

---

## 4. REMAINING / DEFERRED (conservative — not actioned)

Each item lists the proper fix, why it's deferred, and how to validate it with the diagnostics tool.

### R1 — Bound the message conversation read  · **highest value · HIGH risk**
- **Problem:** §3.1 — full-conversation re-read on every chat open.
- **Why it can't just be watermarked today:** the `messages` table has **no `updatedAt` column**
  (verified: `createdAt`, `isEdited`, `deleted`, `deletedFor`, `readBy`, `repliedAt`, … but no
  `updatedAt`). Messages **are** edited / deleted / read-receipted, and none of those bump a queryable
  timestamp — so an `updatedAt` delta would silently miss them. Scroll-up history reads **SQLite only**
  (`getMessagesBefore`), with no Firestore "fetch older" path to fall back on. Naively adding
  `limitToLast` would truncate history and break byte-identical output.
- **Safe options (pick one, in increasing effort):**
  - **(c) LRU keep-alive — IMPLEMENTED (Phase 2).** `FirebaseService` keeps the most-recent
    `_maxWarmChatListeners = 3` closed chat listeners alive instead of cancelling on detail `dispose()`;
    re-opening a recent chat reuses the live subscription via `_setSyncIfAbsent` (no attach, no full
    re-read). LRU eviction cancels the least-recently-closed chat beyond the bound; `stopAllSync()`
    (logout) clears the warm set. **Query unchanged** — same `orderBy('createdAt')`, same SQLite writes
    — so message semantics are byte-identical. Applies to all three families (`messages_`,
    `enquiryMessages_`, `moduleMessages_`); task-list/detail/milestone/log listeners still cancel
    immediately. Expected on-device delta: re-open **attaches 5 → 1** (4 warm reuses) for a chat within
    the bound, and **maxInit** billed only on cold open / post-eviction.
  - **(b) Fetch-older pagination** — add a real Firestore "load older" (`limitToLast` + cursor) behind
    scroll-up, then bound the live listener to a recent window.
  - **(a) Add `updatedAt`** to messages (column + index + Firestore field + **backfill** + composite
    index), then watermark the listener like tasks. Biggest win, largest migration.
- **Measure first:** enable diagnostics, open a few long chats, read `messages_<taskId>` → **maxInit**
  and **attaches**. That quantifies the prize before any schema change.

### R2 — Normalize `participants` into a join table  · **HIGH risk**
- **Problem:** §3.3 — `participants LIKE '%..%'` full scan in `getTasks`.
- **Fix:** a `task_participants(taskId, uid)` (and enquiry equivalent) join table, dual-written at the
  existing `participantsUnion` invariant point, backfilled in a **schema v23 → v24** migration; rewrite
  `getTasks` as an indexed join.
- **Why deferred:** migration + dual-write + backfill is high-risk for a query that is currently
  "fast enough" on typical task counts. **Measure first:** watch `getTasks` avg/max ms and rows on a
  device with a large task list.

### R3 — Cut home rebuild cost (Amplifier C)  · **DONE (Phase 1 of this program)**
- **Fix (implemented):** `TaskProvider` and `WorkItemProvider` now advance an `int revision` on every
  `notifyListeners()`. `home_screen._attentionCount` and `sales_home_screen._attentionCount` memoize
  their result on `p.revision`, so the drawer badge recomputes **once per data change** instead of on
  every rebuild; pure rebuilds (scroll, tab switch, drawer repaint) reuse the cached number and skip
  re-merging `[...byMe, ...toMe]` and re-scanning `getActionIcons` per open task.
- **Behavior:** identical output. The badge still refreshes on the build that follows any notify —
  real action-icon changes notify (only no-op icon reloads are suppressed, and those changed nothing).
- **Measure:** `notifies/min` is **unchanged** by R3 (reducing notifies is R4, deferred). The win is
  CPU/GC per rebuild — fewer frame hitches while scrolling with a large open-task set.

### R4 — Broader no-op notify suppression  · **MED risk**
- Suppression exists for `reloadActionIconsFor`. Extending it (skip `notifyListeners` when a change-set
  produced no real diff) risks **silent UI staleness** if ever unpaired — deferred until R3's measurements
  show notifies are actually the bottleneck.

### R5 — Coalesce the task `lastMessage` bump during rapid sending  · **MED risk**
- A send is 2 writes; the second (task clock bump) could be debounced across a rapid burst. Deferred —
  ordering/last-write semantics need care, and writes are already lean (§3.2).

---

## 5. Recommended sequencing (value vs risk)

1. **Measure** with diagnostics during real testing — confirm which of R1/R2/R3 actually dominates on
   target devices. *(zero risk — telemetry already shipped)*
2. **R3** home rebuild memoization — **DONE** (see §4 R3).
3. **R1(c)** LRU chat keep-alive — removes most re-attach reads without touching the schema. *(Phase 2)*
4. **R1(a)** message `updatedAt` + watermark — the structural fix, **only if** R1(c)'s numbers still
   show material chat-listener cost. *(Phase 4, conditional)*
5. **R2** participants join table — **only if** `getTasks` ms is red on large lists. *(Phase 5, conditional)*

---

## 6. Baseline & phase log (measurement-gated program)

**Execution rules:** optimize only measured bottlenecks · preserve behavior exactly · never combine
architectural cleanup with performance work · after every phase compare before/after diagnostics and
**stop if the gain is small** (prevents unnecessary complexity).

**Step 5 (`TaskProvider` → `WorkItemProvider<TaskModel>` migration) is CLOSED — not a pending perf
item.** Aborted at Stage 5a (docs-only commit `fbb1bf5`) on three-list divergence: `TaskProvider` owns
`_byMe/_toMe/_participant` partitions while the engine owns a single `items` list, and Task already
applies the same 6 generic mixins directly, so inheritance buys ~zero dedup at real parity risk. It is
an architectural item and is therefore explicitly **out of scope** for this performance program.

### Baseline — code-level before-values (pre-Phase-1)
Structural facts from the shipped code; the on-device Diagnostics panel turns them into numbers.

| Path | Baseline behavior (before) | Expected diagnostics signature |
|---|---|---|
| Chat listener `startMessageSync` / enquiry / module | `messages(taskId).orderBy('createdAt').snapshots()`, no limit, no watermark; detail `dispose()` cancels | every chat re-open = 1 **attach** + `initialDocs` = whole thread; `messages_<taskId>` **maxInit** grows with thread length (R1) |
| `getTasks` | `WHERE createdBy=? OR assignedToUid=? OR participants LIKE '%"uid"%' ORDER BY updatedAt DESC`, all rows, no page | leading-wildcard LIKE = full scan; `getTasks` rows = whole table, avg/max ms rises with task count (R2) |
| Home Actions badge | `_attentionCount` recomputed **every build**: allocates `[...byMe, ...toMe]` + `getActionIcons` per open task | CPU/GC per rebuild; `notifies/min` unaffected (R3 targets rebuild cost, not notify count) |
| Hidden tabs | home `IndexedStack` keeps visited tabs mounted → each re-runs its reload query on every provider notify | `reloads/min` includes hidden-tab reloads |

### On-device capture procedure (the "Measure" step)
Settings ▸ About ▸ tap the version row **5×** ▸ Developer ▸ **Diagnostics** → enable *Record telemetry*
and *Floating badge* → **Reset counters** → run a script → read the panel:
1. **Chat script (R1):** open the same long chat, close, re-open ×5 → read `messages_<taskId>`
   **attaches** (expect 5 pre-R1(c)) and **maxInit** (expect = thread length).
2. **Home scroll script (R3):** scroll home + open/close the drawer ×20 on a large open-task set →
   watch frame hitches; `notifies/min` should be flat (R3 does not change notifies).
3. **Large-list script (R2 gate):** on the biggest task list, trigger full reloads → read `getTasks`
   **avg/max ms** and **rows**. Only red (>40 / >100 ms) justifies R2.

### Phase log
| Phase | Action | Status | Before → After |
|---|---|---|---|
| 1 | Close Step 5 · baseline · **R3** badge memoization | R3 implemented (gated) | badge recompute: every build → once per notify; on-device Δ pending capture |
| 2 | **R1(c)** bounded LRU keep-alive for recent chat listeners | **implemented (gated)** | re-open attaches 5 → 1 (4 warm reuses) for a chat within the bound; maxInit billed only on cold open / post-eviction; on-device Δ pending capture |
| 3 | re-measure · compare · stop if gain small | **device capture done (§8)** | see §8 |
| 4 | R1(a) message `updatedAt` watermarking (**R1(b) rejected**) | **STOPPED by device data (§8)** — Firestore reads 18 docs total, `maxInit` ≤ 3 (warn >150); chat-listener read cost not material | R1(a) v25 migration NOT justified |
| 5 | R2 participants join table | **STOPPED by device data (§8)** — `getTasks` rows = 48 (not a large list); cost is call-count (345×), not the LIKE plan | R2 join table NOT justified |
| — | R4 broader no-op notify suppression · R5 `lastMessage`-bump coalescing | **deferred** — implement only if telemetry shows them material | — |

### Phase 3 outcome (code-level Δ; on-device capture pending)
The Diagnostics panel is a runtime instrument, so the numeric before/after must be captured on a
device (procedure above). The deterministic code-level deltas are:
- **R1(c) — large gain.** Re-opening a chat within the warm bound (last 3 closed) goes from 1 attach +
  full-conversation `initialDocs` to **0 attaches / 0 re-read** (live listener reused). The 5-reopen
  script drops from **5 attaches → 1**, `maxInit` billed once instead of five times. §3.1 identifies
  this as the dominant Firestore read cost, so the gain is not small.
- **R3 — modest but free.** Badge recompute drops from once-per-build to once-per-notify: a
  scroll/drawer session with B builds and N notifies goes B → N full `[...byMe,...toMe]` merges +
  action-icon scans (N ≪ B), larger on big open-task sets. Near-zero risk, retained regardless.

**Decision (per the stop-if-gain-small and measure-only rules):**
- **Phase 4 (R1(a) / R1(b)) — HELD.** Conditional on device numbers showing chat-listener cost still
  material *after* R1(c). R1(c) already removes re-attach reads for recent chats; the residual is
  cold-open / evicted threads only. No measurement ⇒ do not implement.
- **Phase 5 (R2) — HELD.** Conditional on `getTasks` avg/max ms reading red (>40 / >100) on a large
  task list. No measurement ⇒ do not implement.
- **R4 / R5 — DEFERRED** as instructed.

The program stops here pending the on-device Phase 3 capture; Phases 4–5 remain at their measurement
gates and are not actioned.

---

## 7. Phase 4 design — R1(a) message `updatedAt` watermarking (DECIDED)

**Decision: implement R1(a). R1(b) is rejected on the retention model.**
R1(b)'s "Firestore older-history pagination" is non-viable: Firestore is a *transient relay* and
`cleanupMessages` hard-deletes every message doc at **48 h** (R7; SYNC_AND_DATABASE_ARCHITECTURE §7.1 /
§8). There is no server history older than 48 h to paginate, and SQLite is already the authoritative
history source (`getMessagesBefore`; scroll-up is SQLite-only by design). Bounding the live listener to
`limitToLast(N)` with no server history fallback risks silently missing messages that arrive while
detached and fall outside the window — a byte-identical-output violation. R1(a) instead reuses the
proven task/enquiry watermark machinery and makes even a cold re-attach a delta read. **R1(c) and R1(a)
compose:** R1(c) removes most attaches; R1(a) makes the residual attaches cheap.

### Design (decision-complete)
1. **Schema v24 → v25** (`local_database_service`): bump `_dbVersion`; in `_onUpgrade`
   `if (oldVersion < 25)` run `ALTER TABLE messages ADD COLUMN updatedAt INTEGER`, then
   `UPDATE messages SET updatedAt = createdAt WHERE updatedAt IS NULL` (backfill anchor; existing rows
   are already synced), then `CREATE INDEX idx_messages_updatedAt ON messages(updatedAt)`. The index is
   **mandatory** — `getMaxUpdatedAt` does `MAX(updatedAt)` and degrades to a per-launch full scan
   without it (see its doc comment). Add the column + index to `_onCreate` too (fresh installs), and
   thread `updatedAt` through the message row mappers (save + getMessages/getMessagesBefore).
2. **`MessageModel`**: add `DateTime? updatedAt`; toMap → ms-since-epoch, fromMap ← parse, copyWith
   carries it.
3. **Server bump points** (correctness-critical: every mutation must advance `updatedAt` or it stops
   propagating cross-device, since there is no longer a full re-read to recover it):
   - `sendMessage`: `set({...message.toMap(), 'updatedAt': FieldValue.serverTimestamp()})`.
   - `updateMessage` — **CENTRALIZED**: merge `'updatedAt': FieldValue.serverTimestamp()` into `updates`
     before `doc.update(...)`. This one edit covers *every* partial-update mutation (edit/isEdited,
     queryReply/isReplied, followUpDone, deleted-flag, fileUrl/uploadError attachment retry, replyTo*),
     so none can be missed individually.
   - `markMessageRead`: add `updatedAt` alongside `readBy.$uid`.
   - `markMessagesDelivered`: add `updatedAt` to each batched update.
   - `deleteMessage`: hard `.delete()` — no bump; removal emits as a `removed` change.
   - **AUDIT before implementing:** grep for any raw `messages(...).doc(...).update/set` that bypasses
     these four methods; server-side (functions) only deletes, never edits.
4. **Listener change (3 families):** `startMessageSync` / `startEnquiryMessageSync` /
   `startModuleMessageSync` become async; `final w = await _watermarkFor('messages');` then attach
   `_afterWatermark(messages(taskId).orderBy('updatedAt'), w)`. Server orderBy moves createdAt →
   updatedAt (a Firestore inequality on `updatedAt` must orderBy `updatedAt` first). Safe because the
   listener already re-sorts client-side by createdAt and SQLite reads order independently. A
   single-field index on `updatedAt` serves the range+orderBy; no composite index needed.
5. **Watermark semantics:** `getMaxUpdatedAt('messages')` is a whole-table MAX (global across tasks);
   per-task listeners filter `updatedAt > globalWatermark − 5 min`. A task whose messages are all older
   than the watermark returns an empty initial snapshot — correct, since SQLite already holds them and
   the live query still delivers any doc whose `updatedAt` later advances past the watermark. The 5-min
   overlap + `saveMessages` diff-skip absorb re-delivered unchanged rows as no-ops; the existing
   now-clamp and pending-write filter block the future-dated-row and null-serverTimestamp classes.

### Risk register / behavior preservation
- **Bump-set completeness** is the single correctness risk; centralizing in `updateMessage` reduces it
  to 4 enumerable methods + an audit grep. A missed path = that mutation never propagates cross-device.
- Read/delivery receipts are high-frequency and now each advance `updatedAt`, so receipt churn re-enters
  the delta window — correct (real changes) and still far cheaper than re-reading the thread; watch
  `messages_<id>` deltaDocs after rollout.
- Output byte-identical: chat render reads SQLite (queries/order unchanged); the listener delivers the
  same change set, only as a delta instead of a full snapshot. Migration is additive (nullable column +
  backfill + index), no data rewrite.

### Phase 4 gate
- analyze 0/0 + arm64 build EXIT 0; migration exercised on an upgraded DB and a fresh install.
- On-device: `messages_<taskId>` **initialDocs/maxInit** collapses from thread-length to the delta;
  verify edit / read-receipt / delete still propagate to a **second device** (the completeness check).
- **Stop-if-gain-small caveat:** R1(c) already removed most re-attaches, so R1(a)'s marginal gain may be
  small on a device where recent chats stay warm. Capture `initialDocs` post-R1(c) before committing to
  the migration; implement R1(a) only if cold-open/evicted-thread reads are still material.

---

## 8. Phase 3 device capture (2026-09-11) — results & re-direction

**Capture:** Diagnostics panel, uptime 234 s, overall **WARN**. Reported symptom: *"app hangs in
between."*

**Firestore load — trivial ⇒ R1 gate STOP.** Active listeners **11** = 4 task-list + 4 module + **3
warm chats** (R1(c) LRU bound confirmed working). Total reads **18 docs**, reads/min 5, writes/min 5.
Every `messages_<id>` shows **maxInit ≤ 3**, most **init 0** — warm re-opens delivered 0 initial docs
(R1(c) reuse). Concern threshold is `maxInit > 150`. ⇒ **Phase 4 (R1(a)/R1(b)) STOPPED**: the
unbounded-conversation-read prize is ~zero here (short / 48h-aged-out threads + keep-alive). A v25
schema migration touching every message write path is not justified.

**SQLite — the real bottleneck (new recommendation R6).**
- `getTasks`: **count 345** in 234 s (≈1.5/s), avg 28 ms, **max 108 ms**, rows **48**.
- `getMessages`: count 170, avg 21 ms, max 73 ms, rows 25. `saveTasks`: count 60 (each chat send bumps
  the task clock → a `tasks` table change).
- Provider churn is **low** (reloads 6, notifies 64, coalesced 0, patches 25, full reloads 0) — so the
  345 `getTasks` are **not** the provider reload path (6). They are independent per-event / per-rebuild
  re-reads of the whole 48-row table on the UI isolate (R9: no `Isolate.run` anywhere):
  - `taskStream()` re-runs `getTasks(all)` on **every** `tasks` change to yield **one** task (~1 per
    saveTasks ≈ 60 while a detail screen is open).
  - `assignee_tasks_screen._loadTasks()` (always-mounted default tab) re-runs `getAllTasks` on a 300 ms
    debounce per provider change.
  - `task_actions_screen` builds `FutureBuilder(future: getAllTasks(userId))` **inline in build** →
    re-runs on every rebuild.
  - `watchTasks()` has the same per-event full-read shape (no callers — dead code).
- 345 × 28 ms ≈ **9.7 s** of UI-isolate DB work in 234 s, in bursts; one 108 ms `getTasks` ≈ 6 dropped
  frames. **This is the hang.**
- ⇒ **Phase 5 (R2) STOPPED**: 48 rows is not a large list; cost is deserialize × call-count, not the
  `participants LIKE` plan. A join-table migration buys nothing here.

**R6 — collapse redundant full-table task re-reads (the measured fix for the hang):**
- **R6.1** `taskStream` → `getTaskById(taskId)` (PK lookup) instead of `getTasks(all)+firstWhere`;
  O(table)→O(1) per event. Edge: yields the task even if it leaves the user's ownership filter (old code
  yielded null) — identical in practice for a detail screen watching its own task.
- **R6.2** `task_actions_screen` — hoist the `getAllTasks` future out of `build` so it stops re-running
  per rebuild.
- **R6.3** `assignee_tasks_screen._loadTasks` — reuse the provider's in-memory lists instead of a fresh
  full-table read (needs care with team/person predicates), or add per-caller telemetry to size it first.
- **R6.4 (defer)** move heavy list reads off the UI isolate (R9) — larger change.

---

## Appendix — key source anchors
- Telemetry singleton: `lib/services/sync_telemetry.dart`
- Message listeners (unbounded): `lib/services/firebase_service.dart` — `startMessageSync`,
  `startEnquiryMessageSync`, `startModuleMessageSync`; one-shot `fetchMessagesOnceFor` (`limitToLast(200)`).
- `messages` schema (no `updatedAt`) and `getTasks` query: `lib/services/local_database_service.dart`.
- Change-set patch vs reload: `lib/providers/change_set_consumer_mixin.dart`.
- Provider notify/reload counters: `lib/providers/task_provider.dart`, `lib/modules/shared/work_item_provider.dart`.
- UI: `lib/screens/settings/diagnostics_screen.dart`, `lib/widgets/diagnostics/diagnostics_badge.dart`.
- Wiring: `lib/main.dart` (badge + `rootNavigatorKey`), `lib/screens/settings/settings_screen.dart` (5-tap unlock).
- Prior hardening: commit `33b066e`.
