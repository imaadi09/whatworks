import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/contact_picker_service.dart';
import '../services/local_database_service.dart';
import '../utils/helpers.dart';

/// Creator-side repair of multi-assignee identity fields — ONE implementation
/// shared by Task and the Sales/CRM base provider so the same proven sweep
/// heals every module identically (no per-module copy to drift).
///
/// Legacy bugs left two kinds of corruption: (1) compressed
/// assigneeUids/assigneePhones lists that lost index alignment with
/// assigneeNames, and (2) creator UIDs / wrong phones seeded into assignee
/// slots and primary fields by the old Manage Assignees dialog. Stored
/// UID/phone values therefore CANNOT be trusted — identity is rebuilt per name
/// from the creator's own contact book and team list (the same sources the
/// assignee picker used), then all resolved UIDs are unioned into participants
/// so the participants sync listener delivers the doc to every assignee's
/// device.
///
/// The concrete provider supplies only model/state adapters (the hooks below);
/// the whole algorithm — contact loading, phone→UID resolution, the session
/// guard, the persisted per-item latch, the per-launch write cap and the
/// remote+local write-back — lives here once. Mirrors the [UnreadCountsMixin]
/// and [ChangeSetConsumerMixin] shared-layer pattern.
mixin AssigneeIdentityRepairMixin<T> on ChangeNotifier {
  // ── Scope + current-user adapters ──────────────────────────────────────

  /// Namespaces the session guard and the persisted per-item latch so Task,
  /// Sales and CRM never collide — e.g. 'tasks' or the module enquiries table.
  @protected
  String get repairScope;

  /// UID of the signed-in user (the repair only runs on the creator's device).
  @protected
  String get repairUserId;

  /// Normalized phone of the signed-in user — used to short-circuit
  /// phone→UID resolution for the current user. May be empty (best effort).
  @protected
  String get repairUserPhone;

  // ── Candidates: items created by the current user ──────────────────────
  @protected
  List<T> get repairCandidates;

  // ── Model field adapters (T has no shared interface) ───────────────────
  @protected
  String repairItemId(T item);

  @protected
  Map<String, dynamic>? repairItemExtraFields(T item);

  @protected
  String repairItemCreatedBy(T item);

  /// Primary assignee display name (used to locate the primary slot).
  @protected
  String repairItemAssignedToName(T item);

  @protected
  String? repairItemAssignedToUid(T item);

  @protected
  String? repairItemAssignedToPhone(T item);

  @protected
  List<String> repairItemParticipants(T item);

  /// Returns a copy of [item] with the repaired identity fields applied.
  /// Implementations should also stamp `updatedAt: DateTime.now()` so the
  /// local mirror reflects the repair time.
  @protected
  T applyIdentityRepair(
    T item, {
    required List<String> participants,
    required Map<String, dynamic> extraFields,
    String? assignedToUid,
    String? assignedToPhone,
  });

  // ── Write-back adapters ────────────────────────────────────────────────

  /// Raw remote field write. [updates] already carries an explicit
  /// `updatedAt` server timestamp so the doc re-delivers to every participant.
  @protected
  Future<void> writeIdentityRepairRemote(
    String itemId,
    Map<String, dynamic> updates,
  );

  /// Mirror the repaired item to SQLite so this device reflects it instantly.
  @protected
  Future<void> writeIdentityRepairLocal(T repairedItem);

  // ── Shared state + scheduling ──────────────────────────────────────────

  /// Session guard, keyed by '<scope>:<userId>' so each module runs at most
  /// once per user per app session (statics in a mixin are shared across all
  /// applications of it).
  static final Set<String> _repairDoneFor = <String>{};

  Timer? _identityRepairTimer;

  /// Re-arm and schedule the repair (e.g. after Manage Assignees saved an item
  /// whose secondary assignee UID could not be resolved — the retry re-resolves
  /// from the contact book and fixes participants). Clears both the session
  /// guard and the persisted per-item latch so the sweep re-examines every item.
  void scheduleIdentityRepair({Duration delay = const Duration(seconds: 3)}) {
    _repairDoneFor.remove('$repairScope:$repairUserId');
    SharedPreferences.getInstance().then(
      (prefs) => prefs.remove('identity_repaired_${repairScope}_$repairUserId'),
    );
    _identityRepairTimer?.cancel();
    _identityRepairTimer = Timer(delay, runIdentityRepair);
  }

  /// Schedule the one-shot startup sweep WITHOUT clearing latches — the
  /// persisted per-item latch makes it converge over several launches instead
  /// of re-walking every item forever.
  void scheduleInitialIdentityRepair({
    Duration delay = const Duration(seconds: 12),
  }) {
    _identityRepairTimer?.cancel();
    _identityRepairTimer = Timer(delay, runIdentityRepair);
  }

  /// Cancel any pending sweep (call from the provider's dispose).
  void cancelIdentityRepair() => _identityRepairTimer?.cancel();

  /// One-shot (per session) creator-side repair. See the mixin doc for the
  /// corruption this heals. Faithful to the original Task-module sweep.
  Future<void> runIdentityRepair() async {
    final userId = repairUserId;
    if (userId.isEmpty) return;
    final sessionKey = '$repairScope:$userId';
    if (_repairDoneFor.contains(sessionKey)) return;
    _repairDoneFor.add(sessionKey);
    try {
      final db = LocalDatabaseService();
      final picker = ContactPickerService();

      // Per-item persisted latch: IDs already repaired or verified-correct on
      // a prior launch are skipped, so the sweep shrinks each launch and a
      // device converges instead of re-walking every item forever. Cleared by
      // scheduleIdentityRepair() when an assignee edit needs a fresh look.
      final prefs = await SharedPreferences.getInstance();
      final latchKey = 'identity_repaired_${repairScope}_$userId';
      final latchedIds = (prefs.getStringList(latchKey) ?? <String>[]).toSet();
      final newlyLatched = <String>{};

      final userPhone = repairUserPhone;

      // Name → (phone, uid) lookup from team members and phone contacts.
      // Contacts are only read when permission is already granted — never
      // trigger a permission prompt from a background timer.
      final identityByName = <String, ({String phone, String uid})>{};
      void addIdentity(String? name, String? rawPhone, String? uid) {
        final key = name?.trim().toLowerCase() ?? '';
        if (key.isEmpty) return;
        final phone = Helpers.normalizePhone(rawPhone) ?? '';
        if (phone.isEmpty && (uid == null || uid.isEmpty)) return;
        identityByName.putIfAbsent(key, () => (phone: phone, uid: uid ?? ''));
      }

      try {
        for (final c in await picker.getTeamMembers()) {
          addIdentity(c.name, c.phone, c.uid);
        }
        if (await picker.hasPermission()) {
          for (final c in await picker.getPhoneContacts()) {
            addIdentity(c.name, c.phone, c.uid);
          }
        }
      } catch (e) {
        print('[$repairScope] identity repair contact load failed: $e');
      }

      Future<String> uidForPhone(String phone) async {
        if (phone.isEmpty) return '';
        if (userPhone.isNotEmpty && phone == userPhone) return userId;
        String? uid = await db.getCachedUid(phone);
        if (uid == null || uid.isEmpty) {
          final snap = await FirebaseFirestore.instance
              .collection('users')
              .where('phone', isEqualTo: phone)
              .limit(1)
              .get();
          if (snap.docs.isNotEmpty) {
            uid = snap.docs.first.id;
            await db.cacheUser(uid, phone);
          }
        }
        return uid ?? '';
      }

      int repaired = 0;
      // Per-launch cap on writes so one background pass can't fire dozens of
      // remote updates (each re-triggers all of the module's sync listeners).
      const int repairCap = 10;
      for (final item in List<T>.from(repairCandidates)) {
        final extra = repairItemExtraFields(item);
        if (extra == null) continue;
        final names = extra['assigneeNames'];
        if (names is! List || names.length < 2) continue;
        final itemId = repairItemId(item);
        if (latchedIds.contains(itemId)) continue;

        final createdBy = repairItemCreatedBy(item);
        final assignedToName = repairItemAssignedToName(item);
        final assignedToUid = repairItemAssignedToUid(item);
        final assignedToPhone = repairItemAssignedToPhone(item);
        final participants = repairItemParticipants(item);

        final nameList = names.map((e) => e?.toString().trim() ?? '').toList();
        final rawUids = extra['assigneeUids'];
        final rawPhones = extra['assigneePhones'];
        final storedUids = rawUids is List
            ? rawUids.map((e) => e?.toString() ?? '').toList()
            : <String>[];
        final storedPhones = rawPhones is List
            ? rawPhones.map((e) => e?.toString().trim() ?? '').toList()
            : <String>[];
        final uidsAligned = storedUids.length == nameList.length;
        final phonesAligned = storedPhones.length == nameList.length;

        // Rebuild identity per name: contact book wins over stored values.
        // A stored creator UID on an assignee slot is the known corruption
        // signature and is never carried over.
        final newUids = List<String>.filled(nameList.length, '');
        final newPhones = List<String>.filled(nameList.length, '');
        for (int i = 0; i < nameList.length; i++) {
          final key = nameList[i].toLowerCase();
          var phone = identityByName[key]?.phone ?? '';
          var uid = identityByName[key]?.uid ?? '';
          if (phone.isEmpty && phonesAligned) phone = storedPhones[i];
          if (uid.isEmpty && phone.isNotEmpty) uid = await uidForPhone(phone);
          if (uid.isEmpty && uidsAligned && storedUids[i] != createdBy) {
            uid = storedUids[i];
          }
          newUids[i] = uid;
          newPhones[i] = phone;
        }

        // Resolution produced nothing at all (e.g. no contacts, offline) —
        // don't overwrite stored lists with empties.
        if (newUids.every((u) => u.isEmpty) &&
            newPhones.every((p) => p.isEmpty)) {
          continue;
        }

        // Fix primary fields when they contradict the rebuilt primary slot
        // (old Manage Assignees wrote another assignee's UID/phone there).
        final primaryIdx = nameList.indexOf(assignedToName.trim());
        String? fixedPrimaryUid;
        String? fixedPrimaryPhone;
        if (primaryIdx >= 0) {
          final pUid = newUids[primaryIdx];
          final pPhone = newPhones[primaryIdx];
          if (pUid.isNotEmpty && pUid != (assignedToUid ?? '')) {
            fixedPrimaryUid = pUid;
          }
          if (pPhone.isNotEmpty &&
              pPhone != (assignedToPhone?.trim() ?? '')) {
            fixedPrimaryPhone = pPhone;
          }
        }

        final allAssigneeUids = newUids.where((u) => u.isNotEmpty).toSet();
        final missingFromParticipants = allAssigneeUids.difference(
          participants.toSet(),
        );
        final uidsChanged = !listEquals(newUids, storedUids);
        final phonesChanged = !listEquals(newPhones, storedPhones);
        if (missingFromParticipants.isEmpty &&
            !uidsChanged &&
            !phonesChanged &&
            fixedPrimaryUid == null &&
            fixedPrimaryPhone == null) {
          // Verified correct — latch so future launches skip the identity
          // rebuild (and any uidForPhone lookups) for this item.
          newlyLatched.add(itemId);
          continue;
        }

        final newParticipants = <String>{
          ...participants,
          ...allAssigneeUids,
        }.toList();
        final updates = <String, dynamic>{
          'participants': newParticipants,
          'extraFields.assigneeUids': newUids,
          'extraFields.assigneePhones': newPhones,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (fixedPrimaryUid != null) {
          updates['assignedToUid'] = fixedPrimaryUid;
        }
        if (fixedPrimaryPhone != null) {
          updates['assignedToPhone'] = fixedPrimaryPhone;
        }
        try {
          await writeIdentityRepairRemote(itemId, updates);
        } catch (e) {
          // Doc missing/offline — skip this item, keep repairing the rest.
          print('[$repairScope] identity repair write failed for $itemId: $e');
          continue;
        }

        // Mirror locally so this device reflects the repair immediately.
        final newExtra = Map<String, dynamic>.from(extra);
        newExtra['assigneeUids'] = newUids;
        newExtra['assigneePhones'] = newPhones;
        await writeIdentityRepairLocal(
          applyIdentityRepair(
            item,
            participants: newParticipants,
            extraFields: newExtra,
            assignedToUid: fixedPrimaryUid ?? assignedToUid,
            assignedToPhone: fixedPrimaryPhone ?? assignedToPhone,
          ),
        );
        repaired++;
        newlyLatched.add(itemId);
        if (repaired >= repairCap) break; // Converge over several launches
      }
      if (newlyLatched.isNotEmpty) {
        await prefs.setStringList(
          latchKey,
          latchedIds.union(newlyLatched).toList(),
        );
      }
      if (repaired > 0) {
        debugPrint(
          '[$repairScope] Repaired assignee identity on $repaired item(s)',
        );
      }
    } catch (e) {
      print('[$repairScope] Error repairing assignee identity: $e');
    }
  }
}
