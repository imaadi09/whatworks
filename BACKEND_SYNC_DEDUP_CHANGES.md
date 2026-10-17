# WhatWorks — Backend, Sync & Deduplication Engineering Changelog

A comprehensive record of every **back-end / persistence**, **cloud-sync**, and
**de-duplication (shared-layer)** change made to the WhatWorks app, together with
the concrete advantage each one produced.

- **Scope:** server-facing logic, local persistence, cloud sync, and the
  cross-module shared layer. Pure visual/UX work is excluded.
- **Grounding:** every entry is tied to a real commit and verified against the
  code on disk (SQLite schema `v23`, 21 Firestore composite indexes, 10 shared
  mixins/services).
- **Modules:** **Task** (the bespoke reference implementation), **Sales**, and
  **CRM**. CRM *is* Sales + a `ModuleConfig`, so any fix landed in the shared
  layer reaches all three at once.

---

## 0. Architecture foundation (the invariant everything below protects)

WhatWorks is a **local-first** Flutter app.

| Principle | Meaning | Why it matters |
|---|---|---|
| **SQLite is the source of truth** | `whatworks_local.db` (schema **v23**) is the authoritative, durable store the UI reads from. | The UI never waits on the network; the app is fully functional offline. |
| **Firestore is a sync layer** | Writes hit SQLite first (`await`), then dispatch to Firestore with `.then()/.catchError()` — **never awaited by the UI** (design rule *R2*). | Instant, optimistic UX; network latency and failures can't block or blank the screen. |
| **Watermark delta sync** | Each listener pulls only rows with `updatedAt > watermark`, where the watermark is `MAX(updatedAt)` read from the local table (5-minute clock-skew tolerance). | Re-sync reads a handful of changed docs instead of whole collections → far fewer Firestore reads. |
| **Task = reference, shared layer = delivery** | Fixes are proven on Task, then extracted into a shared mixin/service so Sales + CRM inherit them. | One implementation, three modules, zero drift. |

---

## 1. Back-end & persistence changes

### 1.1 Direction-aware, identity-preserving SQLite upserts
- **Problem:** Offline, a Firestore *cache* snapshot (with a pending local write
  whose `serverTimestamp` decodes to `null` → `DateTime.now()`) could be written
  **over** the authoritative SQLite row, blanking `assignedTo`/`assignedToUid`
  and even dragging `updatedAt` backwards. A task would silently vanish from the
  Assignee tab until restart.
- **Change:** `_upsertRowIfChanged` / `_upsertRowsIfChanged` became
  **direction-aware** (skip incoming rows whose `updatedAt <= stored`) and
  **merge-preserve** local-only identity/last-message columns when the incoming
  row blanks them. `saveMessage` now bumps the task clock through
  `_bumpTaskClockForward`, which compares before writing so history replay can
  never regress `updatedAt`.
- **Advantage:** Offline cache snapshots can no longer corrupt or blank the
  authoritative row; assignee identity and card ordering stay stable across
  reconnects. *(commits `389f4f4`, `d3b679b`)*

### 1.2 `participants` membership invariant (DB v22 → v23)
- **Problem:** Task enforced a participants set (`participants ⊇ {createdBy} ∪
  {assigneeUids}`); Sales/CRM had no such field, so multi-assignee access
  control and Firestore queries weren't provable for enquiries.
- **Change:** A single top-level `participantsUnion(existing, {createdBy,
  assignedToUid, extraFields})` is now called from **both** `taskToRow` and
  `enquiryToRow`. Added a `participants` field to `EnquiryModel`, the column to
  the `enquiries` + `crm_enquiries` CREATE statements, a guarded **v22→v23
  ALTER**, and a table-parameterized **backfill**; seeded at enquiry creation
  for Firestore parity.
- **Advantage:** One invariant guarantees identical membership semantics for
  tasks and enquiries; enables `(participants CONTAINS, updatedAt)` Firestore
  indexes for all three collections; existing installs migrate safely.
  *(commits `16147c3`, `e709660`)*

### 1.3 Generic soft-delete purge (`purgeDeletedRows`)
- **Problem:** Only Task hard-deleted soft-deleted rows older than 30 days;
  Sales/CRM soft-deleted enquiries accumulated forever in SQLite and Firestore.
- **Change:** Added `purgeDeletedRows(table, {daysThreshold = 30})` — one generic
  routine; `purgeDeletedTasks` now delegates to it. On the cloud side,
  `BaseModuleService.purgeDeletedEnquiries()` mirrors it, wired into
  `loadEnquiries` behind a **module-specific** throttle key
  (`last_firestore_purge_ms_<table>`) so Task/Sales/CRM never suppress each
  other.
- **Advantage:** Storage stays bounded on both tiers for all modules from a
  single implementation; the throttle prevents redundant daily work.
  *(commit `777a79b` + indexes `dc7a304`)*

### 1.4 SQLite performance indexes (DB v22)
- **Change:** Added covering/composite indexes including
  `messages(fileUrl, createdAt)`, `actions(parentId, createdAt DESC)`,
  `sales_actions(...)`, `crm_actions(...)`, plus per-table `updatedAt`,
  `createdBy`, `assignedToUid`, `teamId` and `*_active` composite indexes on
  `tasks` / `enquiries` / `crm_enquiries`.
- **Advantage:** The `MAX(updatedAt)` watermark read resolves to
  `SEARCH … USING COVERING INDEX idx_<table>_updatedAt` (SQLite's MIN/MAX
  optimization — a single rightmost-leaf seek, **O(log n)**) instead of a full
  table scan; icon-strip and list queries are index-backed. Verified empirically
  with `EXPLAIN QUERY PLAN`. *(commit `d3b679b`)*

### 1.5 Backup integrity & off-UI-thread export
- **Change:** Backup ZIP/PBKDF2/AES moved off the UI thread via `Isolate.run`
  (static `_createZip`/`_encrypt`/`_deriveKey`); attachments stored as raw
  `Uint8List` (not base64); a `_computeDataFingerprint` (row counts + newest
  timestamps + attachment bytes + pref keys) lets an unchanged DB skip the
  export entirely. Auto-backup was later **owned at the app root** so Sales/CRM
  users get it too, and scheduled via `SchedulerBinding.scheduleTask` at
  `Priority.idle` (+ opportunistic run on app pause).
- **Advantage:** No startup/interaction jank from encryption; redundant backups
  eliminated; every module's data is protected, not just Task's.
  *(commits `d3b679b`, `9307d99`, `4c1a318`)*

---

## 2. Cloud-sync changes

### 2.1 Pending-write filtering + listener re-use
- **Problem:** Listeners saved *every* snapshot (including pending-write ones)
  and repeatedly cancelled/re-attached subscriptions, causing churn and the
  identity-blanking bug above.
- **Change:** `_confirmedFrom(snapshot, builder)` **skips** docs with
  `metadata.hasPendingWrites`; a generic `_isSyncActive` / `_setSyncIfAbsent`
  lets every listener **reuse an active subscription** instead of re-attaching.
  Applied across task / task-detail / message / enquiry / module-message
  listeners.
- **Advantage:** Eliminates redundant listener teardown/reattach and stops
  unconfirmed local echoes from poisoning SQLite. *(commit `d3b679b`)*

### 2.2 Watermark clamp to `now`
- **Problem:** A pending-write snapshot's `null` serverTimestamp decodes to
  `DateTime.now()`, which could push the whole-table `MAX(updatedAt)` watermark
  **into the future** — silently matching nothing while the listener looked
  healthy.
- **Change:** `_watermarkFor('tasks')` (and enquiry equivalents) clamp the
  MAX-based anchor to `min(maxMs, nowMs)`.
- **Advantage:** The delta window can never be corrupted by a device-clock
  timestamp; remote updates are never silently skipped. *(commit `d3b679b`)*

### 2.3 Deferred startup sync
- **Change:** Firestore sync is deferred ~3 seconds past first-frame work in
  provider startup; heavy message fetches are capped (`limitToLast(200)`),
  message recovery limited to parallelism 2 with a microtask between batches,
  and identity repair latched per task / capped to 10 per launch.
- **Advantage:** First frame renders from SQLite immediately; the network burst
  happens after the UI is interactive → no multi-second startup hang.
  *(commit `33b066e`)*

### 2.4 Change-set notifications + shared consumer (typed `tableChanges2`)
- **Problem:** Any SQLite write broadcast a coarse table-name string, so every
  mounted screen re-ran a **full-scan** reload — hidden tabs included — causing
  visible freezes during sync bursts.
- **Change:** Added `TableChange` / `ChangeKind` and a **typed `tableChanges2`**
  stream that carries the changed **row ids** through the three shared write
  primitives (`_upsertRowIfChanged` / `_upsertRowsIfChanged` / `_deleteRowById`)
  — covering tasks, enquiries and crm_enquiries at once. A shared
  **`ChangeSetConsumerMixin`** coalesces bursts, patches only changed rows in
  memory, removes deleted/absent ids, and falls back to a full reload for
  id-less / bulk / over-threshold / error cases.
- **Advantage:** Sync updates patch a few rows instead of rescanning the table;
  no more hidden-tab freezes; identical behavior in all three modules.
  *(commit `83e38f1`)*

### 2.5 Debounce `maxWait` cap
- **Change:** `tableChangesDebounced` gained an optional `maxWait` (default 2s)
  so a continuous write burst can't starve watchers indefinitely (purely
  additive; same stream type).
- **Advantage:** Guarantees the UI converges within a bounded time even under
  sustained writes. *(commit `9307d99`)*

### 2.6 Phone-based enquiry sync parity (G4)
- **Problem:** Task synced by phone; Sales/CRM enquiry listeners didn't, so
  assignee-side enquiries could miss remote updates.
- **Change:** Brought phone-based Firestore sync to enquiries in the shared
  layer, backed by new `(assignedToPhone, updatedAt)` composite indexes for
  `sales_enquiries` + `crm_records`.
- **Advantage:** Sales/CRM now sync with the same provability and coverage as
  Task. *(commits `f4e2780`, `6f68758`)*

### 2.7 Message-delete persistence to SQLite (audit G)
- **Problem:** `BaseModuleProvider.updateMessage` omitted `deletedFor` /
  `deleted` / `text` from the local `copyWith`, so **Sales/CRM message deletes
  never reached SQLite** — deleted messages reappeared on reload.
- **Change:** The shared `updateMessage` now handles all three (mirroring
  `TaskProvider`); callers pass `deletedForUid` alongside `FieldValue.arrayUnion`
  so the local row can be updated. `sales_detail_screen` aligned
  (`deleteAction`, `_rebuildDisplayMessages`).
- **Advantage:** "Delete for me / everyone" now persists correctly for Sales and
  CRM, matching Task — fixed once in the shared provider. *(commit `777a79b`)*

### 2.8 Event-driven upload retry
- **Change:** Replaced a forever `Timer.periodic` with one startup pass then a
  **debounced listen** on `tableChanges` filtered to `'messages'`, with
  30s→60s→120s→5min backoff and pause/resume lifecycle awareness, gated by a
  `SELECT COUNT(*)`.
- **Advantage:** Retries fire only when relevant, respect app lifecycle, and
  stop burning cycles when there's nothing to retry. *(commit `33b066e`)*

---

## 3. De-duplication / shared-layer changes

The governing rule: **fix the shared layer, never patch a single module.** Each
item below removed a parallel implementation so Task, Sales and CRM run one copy.

| # | Shared artifact | Replaced duplication in | Advantage | Commit |
|---|---|---|---|---|
| 3.1 | **`ModuleCachesMixin`** (action-icon mapping + caches) | Per-module icon maps & cache logic | One icon/catalog source; no per-module drift | `83e38f1` era |
| 3.2 | **`ChangeSetConsumerMixin`** | Hand-written reload-on-notify in each provider | Row-patching sync shared by all modules | `83e38f1` |
| 3.3 | **`VisibilityGatedTabState`** mixin (`visibility_gated_tab.dart`) | `_pendingRefresh` + `didUpdateWidget` copy-pasted in 4 list screens | Hidden tabs defer reload; single catch-up on activation | `018975e` |
| 3.4 | **`UnreadCountsMixin`** (G2) | Separate unread increment/reset per family; `resetTaskUnreadCountLocal` | Generalized to `resetUnreadCountLocal(table,id,uid)`; **fixed Sales/CRM badge that never cleared** | `197587d` |
| 3.5 | **`AssigneeIdentityRepairMixin`** (G3) | Task-only identity repair | Sales/CRM gained identical multi-assignee repair | `8c80a1c` |
| 3.6 | **Message recovery in `ModuleCachesMixin`** (D2) | Duplicated fresh-install recovery | One recovery path for all modules | `e8cedc3` |
| 3.7 | **`ModulePlanCache.effectivePlanForModule`** static (A) | `_effectivePlanForModule` duplicated in both providers | Single plan-gate helper; creation no longer awaits Firestore | `777a79b` |
| 3.8 | **`PaginationMixin<T>`** (B) | Near-identical `loadMore*` + `resetPagination` in both providers | One pagination engine; modules supply only `fetchPage`/`appendPage`/`canLoadMore` | `44d492d` |
| 3.9 | **`TeamManagementMixin` / `TeamService`** | Per-module team state & CRUD | Teams local-only in SQLite, shared by all modules | earlier |
| 3.10 | **`BaseModuleProvider` / `BaseModuleService` / `ModuleConfig`** | A whole second Sales-like module for CRM | CRM = Sales + config; every shared fix lands twice for free | earlier |

### 3.8 `PaginationMixin<T>` — detail (most recent)
- **Extracted:** page cursor, `_hasMore` / `_isLoadingMore` flags, the
  `loadMoreItems()` algorithm (rollback-on-error), `resetPagination()` and
  `markFirstPage(n)` into one `mixin PaginationMixin<T> on ChangeNotifier`.
- **Each provider supplies only:** `fetchPage` (its SQLite read), `appendPage`
  (its list splice + icon preload) and an optional `canLoadMore` guard (Task
  requires a signed-in uid).
- **Public API preserved** as thin wrappers, so no call site changed:
  `hasMoreTasks` / `loadMoreTasks` / `isLoadingMore`; `hasMoreEnquiries` /
  `loadMoreEnquiries` / `isLoadingMore`. Change-set paths set `hasMoreItems`
  directly; initial loads call `markFirstPage(n)`.
- **Advantage:** The infinite-scroll state machine exists **once** instead of
  twice — future pagination fixes (e.g. a new guard or a page-size change) apply
  to Task, Sales and CRM simultaneously.

### 3.11 `WorkItemProvider<T>` single-list engine + the Step 5a Task-divergence decision

- **Step 3 (generalization, commits `2ef8f3f` + `23608af`):** extracted
  `WorkItemProvider<T extends WorkItem>` (`lib/modules/shared/work_item_provider.dart`)
  holding the type-generic SINGLE-`items` list engine - list + loading/error +
  filter/sort state, pagination + change-set plumbing, message/action-icon
  caches, fresh-install recovery sweep, teams wiring and identity-repair
  adapters - applying the 6 mixins once against `T`. `BaseModuleProvider extends
  WorkItemProvider<EnquiryModel>` keeps only the EnquiryModel CRUD/hooks, and the
  read-only `WorkItem` interface (`work_item.dart`) is implemented by
  `EnquiryModel`. **Advantage:** the Sales/CRM list engine is typed once.
- **Step 5a (Task migration evaluated -> ABORTED):** the target was
  `TaskProvider extends WorkItemProvider<TaskModel>`. Compatibility analysis
  established a **legitimate architectural divergence, not a gap.**
  `TaskProvider` is a THREE-list model partitioned by ownership (`_byMeTasks` /
  `_toMeTasks` / `_participantTasks`, surfaced as the byMe/toMe/participant/
  deleted/archived views), and even its generic hooks are three-list shaped:
  `appendPage` splices 3 ways, `recoveryCandidateIds` unions all 3,
  `repairCandidates = _byMeTasks`, filter/sort defaults differ (`'Latest
  Activity'` vs the engine's `'Last Action'`), and `canLoadMore` keys off
  `_currentUserId`. A single `items` list cannot represent this without changing
  Task semantics; inheriting would force overriding ~7 generic members and leave
  ~6 inherited fields dead - a larger diff, real parity risk and ~zero dedup on
  the app's most critical provider.
- **Decision (Step 5 CLOSED):** Task stays bespoke. `TaskModel` is intentionally
  NOT `implements WorkItem` (no nominal convergence). Shared Task vs Sales/CRM
  behavior is ALREADY deduplicated one layer down, at the 6 generic `<T>` mixins
  (rows 3.1-3.9) that BOTH `TaskProvider` and `BaseModuleProvider` apply
  directly - so aborting the migration loses no convergence. The true
  cross-module convergence boundary is the **mixin/service layer, NOT
  `WorkItemProvider<T>`** (which is Sales/CRM-only). Reopen only if a concrete
  future duplication problem justifies redesigning the base to be
  list-shape-agnostic. *(docs-only; no Task or Dart behavior change)*
- **Advantage:** records the boundary so a future engineer does not re-attempt a
  blocked, value-negative migration, and confirms Task's three-list provider is
  a deliberate design rather than drift.

---

## 4. Dead-code & legacy retirement

| Item | What was removed | Advantage | Commit |
|---|---|---|---|
| **D1** | Dead legacy enquiry APIs | Smaller surface, no confusing unused paths | `c942e4b` |
| **H** | Unused `TaskRepository` / `MessageRepository` | Removed misleading "repository" layer that nothing called | `777a79b` |
| **p3e** | Legacy `tableChanges` **String** stream | Single typed `tableChanges2` stream; no dual-maintenance of two notification channels | `01bb84e` |
| — | App-wide dead/unused code sweep | Leaner binary, clearer codebase | `5e88853` |

---

## 5. Index inventory (verified on disk)

### 5.1 Firestore composite indexes — 21 total (`firestore.indexes.json`)
Grouped by collection (all back watermark delta sync and access control):

- **tasks:** `(assignedToPhone,isClosed)`, `(assignedToPhone,createdAt↓)`,
  `(createdBy,assignedToPhone)`, `(createdBy,updatedAt)`,
  `(assignedToUid,updatedAt)`, `(participants⊆,updatedAt)`,
  `(assignedToPhone,updatedAt)`, `(isDeleted,deletedAt)`
- **sales_enquiries:** `(createdBy,updatedAt)`, `(assignedToUid,updatedAt)`,
  `(participants⊆,updatedAt)`, `(assignedToPhone,updatedAt)`,
  `(isDeleted,deletedAt)`
- **crm_records:** same five as sales_enquiries
- **users:** `(phone,isOnApp)`, `(planType,planExpiry)` · **payments:**
  `(uid,createdAt↓)`

> `(participants⊆,updatedAt)` = `arrayConfig: CONTAINS`. The `(isDeleted,
> deletedAt)` trio backs §1.3's cloud purge; the `(assignedToPhone,updatedAt)`
> pair backs §2.6 (G4).

### 5.2 SQLite indexes (schema v23)
`tasks`, `enquiries`, `crm_enquiries`: `updatedAt` (watermark covering index),
`createdBy`, `assignedToUid`, `teamId`, and `*_active` composites;
`messages(taskId)`, `messages(createdAt)`, `messages(fileUrl,createdAt)`;
`actions/sales_actions/crm_actions(parentId, createdAt DESC)`.

---

## 6. Resultant advantages (consolidated)

**Correctness & data integrity**
- Offline cache snapshots can no longer blank assignee identity or regress
  clocks (§1.1, §2.1, §2.2).
- Sales/CRM message deletes now persist; unread badges now clear; multi-assignee
  identity repair and participants membership match Task exactly (§1.2, §2.7,
  §3.4, §3.5).
- One `participants` invariant and one purge routine guarantee identical
  semantics across all three modules.

**Performance & responsiveness**
- Instant, offline-first UI: SQLite answers every read; Firestore is never
  awaited (§0, §2.3).
- Watermark delta sync + covering indexes turn re-syncs into O(log n) reads of
  only-changed rows (§1.4, §2.2).
- Change-set row patching + visibility-gated tabs + bounded debounce removed the
  hidden-tab freezes and full-table rescans (§2.4, §2.5, §3.3).
- Backup, icon strips and retries moved off the UI thread / became event-driven
  (§1.5, §2.8).

**Maintainability & cost**
- Ten shared mixins/services mean a fix lands once and reaches Task, Sales and
  CRM together — eliminating drift (§3).
- Dead APIs, the unused repository layer and the legacy string stream are gone
  (§4).
- Fewer, index-backed Firestore reads lower cloud cost; bounded storage via
  30-day purge (§1.3, §5).

---

## 7. Commit ledger (chronological)

| Date | Commit | Area | Summary |
|---|---|---|---|
| 2026-09-05 | `464913b` | backend | Sign-out wipes local session, resets providers/teams |
| 2026-09-07 | `389f4f4` | sync | Local-first hardening: stale/blank cache can't blank identity offline |
| 2026-09-07 | `5e88853` | dedup | App-wide dead/unused code removal |
| 2026-09-08 | `d3b679b` | sync/perf | Batch A+B: SQLite perf indexes (db v22), batched icon queries, reload coalescing + notify suppression, re-attach/pending-write/watermark fixes |
| 2026-09-08 | `33b066e` | sync/perf | Write-through memoisation + cached module plan tier (`module_plan_cache.dart`) |
| 2026-09-08 | `334d0b8` | perf | Lazy-load nav tabs until selected (Task+Sales+CRM) |
| 2026-09-08 | `018975e` | dedup | `VisibilityGatedTabState` shared mixin — stop hidden-tab freezes |
| 2026-09-08 | `9307d99` | sync/backup | Debounce `maxWait` cap + defer auto-backup off UI path |
| 2026-09-08 | `4c1a318` | backup | Own auto-backup at app root so Sales/CRM get it too |
| 2026-09-08 | `83e38f1` | sync/dedup | Change-set notifications + `ChangeSetConsumerMixin` (all modules) |
| 2026-09-09 | `197587d` | dedup (G2) | Shared `UnreadCountsMixin` — Sales/CRM badge now clears |
| 2026-09-09 | `16147c3` | backend (G1) | `participants` parity via common-layer invariant (db v23) |
| 2026-09-09 | `e709660` | backend (G1) | Seed `participants` at enquiry creation (Firestore parity) |
| 2026-09-09 | `c942e4b` | dedup (D1) | Remove dead legacy enquiry APIs |
| 2026-09-09 | `8c80a1c` | dedup (G3) | Assignee-identity repair parity via shared mixin |
| 2026-09-09 | `e8cedc3` | dedup (D2) | Dedup fresh-install message recovery into `ModuleCachesMixin` |
| 2026-09-09 | `f4e2780` | sync (G4) | Phone-based enquiry sync parity for Sales/CRM |
| 2026-09-09 | `6f68758` | index (G4) | `(assignedToPhone,updatedAt)` index for sales_enquiries + crm_records |
| 2026-09-09 | `01bb84e` | dedup (p3e) | Retire legacy `tableChanges` String stream |
| 2026-09-09 | `777a79b` | sync/dedup (G/A/H/E) | Msg-delete persistence, plan-gate dedup, dead repos removed, enquiry purge parity |
| 2026-09-09 | `dc7a304` | index (E) | `(isDeleted,deletedAt)` indexes for tasks/sales_enquiries/crm_records |
| 2026-09-09 | `44d492d` | dedup (B) | Extract shared `PaginationMixin<T>` for Task + Sales/CRM |

---

## 8. Outstanding items

1. **Firestore index deploy (owner: you).** The composite indexes in
   `firestore.indexes.json` — notably the `(isDeleted,deletedAt)` trio (§1.3/E)
   and the `(assignedToPhone,updatedAt)` pair (§2.6/G4) — must be deployed for
   the *cloud-side* purge and phone-sync queries to run. Until then those
   queries silently no-op (local SQLite behavior is unaffected):
   ```powershell
   & "$env:APPDATA\npm\firebase.cmd" deploy --only firestore:indexes --project whatworks-68786
   ```
2. **Audit item C (filter/sort/search setters) — intentionally deferred.** The
   setters look duplicated but the predicates genuinely differ (Task tab
   ownership vs the enquiry status pipeline), so unifying them would add
   abstraction without removing real duplication. Low value; left as-is unless
   requested.

---

*Generated from verified git history (`git log`), on-disk schema/index files, and
the current shared-layer source. HEAD at time of writing: `44d492d`.*
