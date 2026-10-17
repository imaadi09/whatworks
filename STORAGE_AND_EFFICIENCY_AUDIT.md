# Storage, Cloud & Performance Efficiency — Audit and Implementation

This document records two efficiency audits of WhatWorks (device/backup storage
and cloud cost) plus the startup/list performance work, and the concrete changes
that were implemented in response. Everything below is SQLite-first: Firestore is
a transient relay, and the local database remains the canonical store.

Scope of the batch:

| ID | Area | Change |
|----|------|--------|
| s1 | Backup | Auto-backup keeps newest 2, excludes attachments |
| s2 | Cloud | Firestore on-device cache bounded to 50 MB |
| s3 | Storage | Downsample images on save (1600 px / JPEG q80, isolate) |
| s3b | Storage | Wire downsample into the real pick/upload paths |
| s4 | Storage | Temp prune: delete voice temp after copy; startup sweep > 7 days |
| d1 | DB hygiene | Freelist-gated `VACUUM` + `system_logs` retention prune |
| d2 | Visibility | Show `backups/` dir size in the in-app Storage dialog |
| n1 | Performance | No-op `notifyListeners()` suppression (Task + Sales/CRM) |
| t1 | Performance | Shared table-snapshot cache + idle prewarm |
| r1 | Cloud | Superseded-object delete on upload retry |
| r2 | Cloud | Downsample avatar before upload |

---

## Audit A — Backup & device-storage efficiency

### Findings

1. **Auto-backups retained too much and included attachments.** Every scheduled
   auto-backup wrote a full `.whatworksbackup` bundle including attachment
   blobs, and old bundles were never pruned. Auto-backup's real job is
   *database + preferences recovery*, not media archival (media already lives in
   `documents/attachments` and in cloud storage). This was the single largest
   reclaimable win (~30–50 MB immediately).
2. **Firestore's on-device cache was unbounded.** The persistent disk cache grows
   without limit on a long-lived install. Eviction never touches SQLite rows, so
   bounding it is safe.
3. **Full-resolution photos were cached and uploaded.** A picked image
   (3–8 MB) was stored and uploaded as-is, inflating both the attachment cache
   and cloud storage egress.
4. **Temp/scratch files were never reclaimed.** Voice recordings, share targets,
   screenshots and export files written into the system cache dir persisted
   forever, so Android's "Cache" line only grew.
5. **A dead-code trap.** The image downsample helper initially landed inside
   `saveAttachmentLocally`, which had **zero callers** — so the optimization did
   nothing at runtime until it was wired into the actual pick/upload paths (s3b).

### Fixes

**s1 — Auto-backup: keep 2, exclude attachments.** `BackupService` gained an
`includeAttachments` flag; scheduled auto-backups pass `false` (DB + prefs only),
while a manual export still includes attachments. After a successful auto-backup
the service prunes to the newest 2 bundles.

**s2 — Bound the Firestore cache.** `main.dart` configures
`cacheSizeBytes: 50 * 1024 * 1024` on the `Settings` used to initialize
Firestore. Safe because eviction only drops cached cloud documents; SQLite rows
are untouched and remain the source of truth.

**s3 / s3b — Downsample before upload.** In `LocalStorageService`:
- Pure-Dart `image: ^4.3.0` (promoted from a transitive dependency).
- `_downsampleToJpeg(bytes)`: `img.decodeImage` → `img.copyResize` (long edge
  `_maxImageEdge = 1600`) → `img.encodeJpg(quality: _jpegQuality = 80)`, run via
  `Isolate.run` so the UI thread is never blocked. The result is adopted only
  when `out.length < bytes.length` (never enlarge).
- **Recompression is gated to JPEG-named files** (`_recompressExtensions =
  {'jpg','jpeg'}`, `_isRecompressibleImage`). Rationale: the cached name must
  stay `${entityId}_$fileName` because `UploadRetryService._retrySingleUpload`
  rebuilds that exact path from the message row. Re-encoding a `.png` into JPEG
  bytes under a `.png` name would leave the payload disagreeing with the
  extension the OS opener trusts, and would corrupt the retry path.
- Scratch is written to `.recompress_${taskId}_$fileName` then deleted.
- **Wiring (s3b):** in `detail_chat_attachments.dart` the gallery, camera and
  document paths now call `saveAttachmentLocally(...)` and upload the returned
  (downsampled) `uploadPath`; the originals never leave the device. Voice uploads
  the permanent cached copy (`voice_${msgId}.m4a`) and then deletes the temp
  recording; `cancelRecording()` deletes the discarded take.

**s4 — Temp prune.** `LocalStorageService.pruneStaleTempFiles({olderThanDays =
7})` sweeps top-level files in the temp dir matching app-owned prefixes
(`voice_`, `ww_share_`, `task_screenshot_`) and export extensions
(`csv/xlsx/pdf`) older than the cutoff, plus unconditionally clears any leftover
`.recompress_*` scratch in the attachment dir. Plugin-owned subdirectories are
never touched.

---

## Audit B — Cloud cost efficiency

### Findings

1. **Unbounded system-log mirroring.** Both Firestore system-log listeners
   (`startSystemLogSync`, `startModuleSystemLogSync`) were *ascending and
   unbounded*, re-pulling the entire activity history on every detail-screen
   open. That is read cost with no user-visible benefit (only the recent tail is
   ever shown), and it would immediately refill any local prune.
2. **Full-resolution media in cloud storage** (see Audit A #3) inflated storage
   bytes and download egress.

### Fixes

1. **Cap the log mirror to match the local retention window.** In
   `firebase_service.dart`, `_systemLogMirrorLimit = 200` and both listeners now
   query `orderBy('createdAt', descending: true).limit(_systemLogMirrorLimit)`.
   This mirrors the newest 200 per parent, aligning exactly with the local
   `pruneSystemLogs(keepPerParent: 200)`. `saveSystemLogs` only inserts (it
   performs no delete pass), and nothing deletes server documents — the cap
   reduces *reads*, not server data. Shared tables key parents in the `taskId`
   column (an enquiry id rides it).
2. **Downsample-before-upload** (Audit A s3/s3b) directly reduces stored bytes
   and egress per photo.

Trade-off (documented in code): the local Activity log now shows at most the
newest 200 entries per parent; the server retains more.

---

## DB hygiene (d1, d2)

### d1 — Freelist-gated `VACUUM` + `system_logs` retention

In `local_database_service.dart` (a "Disk Hygiene" section):

- **`vacuumIfFragmented({int minFreePages = 512})`** reads
  `PRAGMA freelist_count` and `PRAGMA page_size`, computes reclaimable bytes, and
  runs `VACUUM` **only** when free pages ≥ the threshold. `VACUUM` cannot run
  inside a transaction, so it executes on the raw handle via `db.execute`. A
  `_vacuumRunning` guard prevents re-entrancy, and it logs reclaimed MB and
  elapsed time.
- **Hooks (fire-and-forget via `unawaited`):**
  - `purgeDeletedRows` → after a bulk delete that removed rows (`count > 0`).
  - `clearSessionData` → with a lower `minFreePages: 128`.
- **`pruneSystemLogs({int keepPerParent = 200})`** runs a correlated delete
  keeping the newest N per parent:
  ```sql
  DELETE FROM system_logs WHERE id NOT IN (
    SELECT s.id FROM system_logs s
    WHERE s.taskId = system_logs.taskId
    ORDER BY s.createdAt DESC LIMIT ?)
  ```
  On a non-zero delete it notifies `system_logs` and fires
  `vacuumIfFragmented()`.

**Scheduling (`main.dart`, `_runStorageHygiene` at t=+12 s):** the temp sweep
runs every launch (cheap); `pruneSystemLogs` is daily-gated on the prefs key
`db_hygiene_last_run_ms`, and the stamp is written **only after** a successful
prune so a failed run retries next launch.

### d2 — Backups size visible in-app

In `settings_screen.dart`, the Storage dialog measures `documents/backups`
alongside attachments and temp cache, adds a **"Backups: X"** row plus a
conditional caption ("Backups holds the 2 newest auto-backups — database and
settings only."), and wraps the dialog content in a `SingleChildScrollView` so
the added rows can't overflow at a large font scale.

---

## Performance efficiency (n1, t1)

### The "app refreshes a few seconds after start" symptom

Startup timeline: **t=0** SQLite paint → **t≈5 s** a deferred `Timer` arms
`startTaskSync` → the first Firestore snapshot writes → `tableChanges` →
`_reloadTasksFromSQLite` → an **unconditional `notifyListeners()`**. The visible
"refresh" was that first sync burst landing and forcing a full rebuild even when
nothing the UI renders had actually changed.

### n1 — No-op notify suppression

Compare a render-relevant **signature** before and after a reload, and notify
only when it moved.

- `work_item.dart`: `milestoneSignature`, `workItemSignature`,
  `workItemListSignature`. Text/map fields contribute via `hashCode`.
- The signature deliberately includes fields written **without** bumping
  `updatedAt` (`unreadCounts`, `lastMessageText/Time`) — otherwise real badge
  updates would be swallowed.
- `work_item_provider.dart`: `currentItemsSignature()`;
  `base_module_provider.dart`: signature-gated `fullReload()` / `refresh()`.
- `module_caches_mixin.dart`: `preloadActionIconsFor(...)` now returns
  `Future<bool>` (reusing `_iconRowsEqual`) so an icon-only change can still
  justify a notify.
- `task_provider.dart`: `_reloadTasksFromSQLite` notifies only on
  `wasLoading || hadError || iconsChanged || signature changed`, using
  `_taskSignature` / `_bucketSignature` over the three ownership buckets.
  `TaskModel` intentionally does **not** implement `WorkItem`, so Task keeps a
  twin signature (`milestoneSignature` is shared and imported from
  `work_item.dart`).

### t1 — Shared snapshot cache + idle prewarm

**Problem:** the home `IndexedStack` keeps every visited tab mounted. Although
hidden tabs are already gated by `VisibilityGatedTabState`, the residual waste
was *duplicate scanning*: several always-mounted tabs (Task Actions, Assignee,
Sales/CRM Actions) each independently re-ran the **same** heavy full-table scan
(`getTasks` / `getModuleEnquiries`) on every reload.

**Fix — change-revision snapshot cache (`local_database_service.dart`):**
- A per-table monotonic counter `_tableRevisions` is bumped inside `_notify`,
  exposed as `revisionOf(table)`. Every write path routes through `_notify`
  (`_upsertRowIfChanged`, `_upsertRowsIfChanged`, `_deleteRowById`, the explicit
  enquiry delete, `purgeDeletedRows`, `clearSessionData`), so the revision is a
  reliable invalidation signal.
- `getTasks` and `getModuleEnquiries` memoize their deserialized rows in
  `_snapshotCache` keyed by `table + params`, validated against the revision
  captured **before** the query ran (a mid-query write leaves the entry stale →
  next reader re-scans, never caching pre-write rows as fresh). Readers get a
  shallow copy (`List.of`) so no caller can mutate the shared snapshot.
- **Correctness with n1:** the cache can never mask a real change — a genuine
  write bumps the revision, forcing a cache miss and a fresh scan, so the n1
  signature differs and the notify fires. It only short-circuits when nothing
  moved, which is exactly the intended suppression. t1 removes duplicate
  *scans*; n1 removes duplicate *rebuilds*.

**Fix — idle prewarm (`main.dart`):** at **t=+15 s** (past the t=5 s sync burst,
so it warms the *post-sync* state), `LocalDatabaseService().prewarmListSnapshots(uid)`
runs at `Priority.idle` via `SchedulerBinding.scheduleTask` — filling the tasks
and both module-enquiry snapshots so the first tab open hits warm memory. No-op
when signed out.

---

## Verification (gate)

- `flutter analyze --no-pub` → **0 errors, 0 warnings**, 955 infos (baseline).
- `flutter build apk --release --target-platform android-arm64` → **Built
  app-release.apk (29.1 MB)**.
- Copied to project root and verified byte-identical (MD5
  `347B41CC83F2D7191D6ACDBDF2991443`, 30,519,256 bytes, fresh timestamp),
  superseding the prior stale root APK.

No commit was made (commits happen only on explicit request).

---

## Upload retry & avatar efficiency (r1, r2)

### r1 — Superseded-object delete on retry

**Problem.** `StorageService._uploadFile` names every object
`tasks/$taskId/$folder/${generateId()}_$file` — a *fresh random id per attempt*.
If an earlier attempt uploaded an object **and** delivered its URL to Firestore
while the **local** row stayed `pending`/`failed` (process killed before
`updateMessageFileUrl`, or that local write failed), the row remains retryable.
The retry then uploads a **second** object and records a new URL, orphaning the
first: nothing else holds its URL, so the all-recipients-downloaded sweep
(`maybeDeleteServerAttachment`, which deletes by the recorded `fileUrl`) can
never reclaim it.

**Fix (`upload_retry_service.dart`).** `_retrySingleUpload` now resolves the
parent collection once, then best-effort reads the current Firestore message doc
and captures any real (`http…`) `fileUrl` as `supersededUrl`. After the new
upload is recorded locally **and** the Firestore `.set()` delivery succeeds, it
deletes `supersededUrl` via `StorageService.deleteFile` (tolerant of
object-not-found). The delete is gated on `delivered` — if Firestore delivery
failed, the doc still points at the old object, so deleting it would break the
link for every other device; that rare edge is left to a future retry.

**Residual (documented, not addressed):** an object whose URL was never recorded
*anywhere* (upload succeeded but neither the local row nor Firestore was written)
is still unrecoverable by URL. Eliminating that class entirely would require a
deterministic per-message storage path so a retry overwrites instead of
duplicating — a larger change deliberately not taken here.

### r2 — Avatar downsample

Avatar uploads (`auth_provider.dart`, both the registration path and
`updateProfile`) previously called `putFile` with the picked full-resolution
image. They now call the shared `LocalStorageService.compressImageForUpload(file)`
(1600 px long edge / JPEG q80, off the UI isolate) and `putData` the compressed
bytes, falling back to `putFile` when compression isn't smaller. Unlike the
attachment path, the avatar target is always `profile_images/${uid}.jpg`, so the
JPEG re-encode is correct regardless of the source extension and there is no
name-stability constraint (and the fixed path means re-uploads overwrite — no
orphan).

---

## Deferred / open items (need a decision)

- **Deterministic per-message storage path** would remove the last orphan class
  in r1 (an object whose URL was never recorded anywhere); larger change, not
  taken.
- **Delete-for-everyone 60-minute limit** bug: never root-caused.

---

## Files touched

- `lib/services/local_storage_service.dart` — downsample helper,
  `compressImageForUpload`, recompression gating, `pruneStaleTempFiles`.
- `lib/services/upload_retry_service.dart` — superseded-object delete on retry.
- `lib/providers/auth_provider.dart` — avatar downsample before upload.
- `lib/widgets/detail_chat/detail_chat_attachments.dart` — downsample wiring,
  voice temp delete, cancel cleanup.
- `lib/services/backup_service.dart` — `includeAttachments`, keep-2 prune.
- `lib/services/local_database_service.dart` — Disk Hygiene (VACUUM,
  `pruneSystemLogs`), snapshot cache + `prewarmListSnapshots`.
- `lib/services/firebase_service.dart` — bounded/descending system-log
  listeners.
- `lib/main.dart` — Firestore cache bound, `_runStorageHygiene` (t+12 s), idle
  prewarm (t+15 s).
- `lib/screens/settings/settings_screen.dart` — Backups size row + scrollable
  dialog.
- `lib/modules/shared/work_item.dart`, `work_item_provider.dart`,
  `base_module_provider.dart`, `lib/providers/module_caches_mixin.dart`,
  `lib/providers/task_provider.dart` — no-op notify suppression.
- `pubspec.yaml` / `pubspec.lock` — `image: ^4.3.0`.
