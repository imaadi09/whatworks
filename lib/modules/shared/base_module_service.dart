import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../modules/sales/models/enquiry.dart';
import '../../../models/message.dart';
import '../../../services/local_database_service.dart';
import '../../providers/unread_counts_mixin.dart';
import '../../services/sync_telemetry.dart';
import '../../utils/helpers.dart';

/// Base service class for module-specific Firestore CRUD operations.
/// Both SalesService and CrmService extend this with their collection names.
class BaseModuleService {
  final String collectionName;
  final String teamsCollectionName;
  final String logTag;
  final String enquiriesTableName;
  final String teamsTableName;

  BaseModuleService({
    required this.collectionName,
    required this.teamsCollectionName,
    required this.logTag,
    required this.enquiriesTableName,
    required this.teamsTableName,
  });

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Cap for the denormalized `lastMessageText` preview written onto the parent
  /// enquiry doc — the same 80 chars FirebaseService.sendMessage uses for
  /// tasks. Exposed so BaseModuleProvider can apply it to the in-memory card
  /// too, otherwise the list would show the full body until the next reload
  /// replaced it with the truncated server value.
  static const int kLastMessageSnippetChars = 80;

  /// Truncate a message body to the card-preview length.
  static String lastMessageSnippet(String text) =>
      text.length > kLastMessageSnippetChars
      ? '${text.substring(0, kLastMessageSnippetChars)}…'
      : text;

  /// Stable action label for a durable system-log row.
  ///
  /// Single source of truth on purpose: both the write-through in
  /// BaseModuleProvider.sendMessage and the detail screen's one-time backfill
  /// build a log doc for the same message id, and the Firestore rules only
  /// permit a re-write that changes nothing. Deriving the label in two places
  /// would make the second write a denied update.
  static String systemLogAction(String text) =>
      Helpers.detectActionType(text) ?? 'system';

  CollectionReference _enquiries() => _firestore.collection(collectionName);

  // ── Teams (SQLite-only — teams never touch Firestore) ─────────────────────

  // Team CRUD lives in TeamService + TeamManagementMixin (shared by Tasks,
  // Sales and CRM). This service only keeps the deletion-guard count below.

  /// Local count of cards stamped with [teamId].
  Future<int> getTeamEnquiryCount(String teamId) async {
    try {
      final db = await LocalDatabaseService().database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM $enquiriesTableName WHERE teamId = ?',
        [teamId],
      );
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      print('[$logTag] Failed to count team enquiries locally: $e');
      return 0;
    }
  }

  // ── Enquiries / Records ────────────────────────────────────────────────────

  Future<String> createEnquiry(
    EnquiryModel enquiry, {
    String? enquiryId,
  }) async {
    final id = enquiryId ?? _enquiries().doc().id;
    final enquiryWithId = enquiry.copyWith(id: id);
    await _enquiries().doc(id).set(enquiryWithId.toMap());
    return id;
  }

  Future<void> updateEnquiry(String id, Map<String, dynamic> data) async {
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _enquiries().doc(id).update(data);
  }

  /// Lightweight field update on an enquiry document (e.g. unreadCounts).
  /// Does NOT bump updatedAt — mirrors FirebaseService.updateTaskField so the
  /// watermarked delta sync won't churn the whole row back on unread-only
  /// writes. The unread algorithm itself lives in UnreadCountsMixin (shared
  /// with TaskProvider); this is just the raw transport.
  Future<void> updateEnquiryFields(
    String id,
    Map<String, dynamic> updates,
  ) async {
    await _enquiries().doc(id).update(updates);
  }

  Future<void> deleteEnquiry(String id) async {
    await _enquiries().doc(id).delete();
  }

  /// Purge soft-deleted enquiries older than [daysThreshold] days from
  /// Firestore. Mirrors FirebaseService.purgeDeletedTasks for this module's
  /// collection; needs the (isDeleted, deletedAt) composite index. Returns the
  /// number of enquiries purged.
  Future<int> purgeDeletedEnquiries({int daysThreshold = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: daysThreshold));
    final snapshot = await _enquiries()
        .where('isDeleted', isEqualTo: true)
        .where('deletedAt', isLessThan: Timestamp.fromDate(cutoff))
        .get();
    int count = 0;
    for (final doc in snapshot.docs) {
      try {
        await doc.reference.delete();
        count++;
      } catch (e) {
        print('[$logTag] Failed to purge enquiry ${doc.id}: $e');
      }
    }
    if (count > 0) {
      print(
        '[$logTag] Purged $count soft-deleted enquiries older than $daysThreshold days',
      );
    }
    return count;
  }

  Future<EnquiryModel?> getEnquiry(String id) async {
    final doc = await _enquiries().doc(id).get();
    if (!doc.exists) return null;
    return EnquiryModel.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  Future<List<EnquiryModel>> getEnquiriesFromLocal(
    String userId, {
    String? teamId,
  }) async {
    try {
      return await LocalDatabaseService().getModuleEnquiries(
        userId,
        teamId: teamId,
        tableName: enquiriesTableName,
      );
    } catch (e) {
      print('[$logTag] Failed to get enquiries from local DB: $e');
      return [];
    }
  }

  // ── Messages subcollection ─────────────────────────────────────────────────

  CollectionReference _messages(String enquiryId) =>
      _enquiries().doc(enquiryId).collection('messages');

  /// Write a message and touch its parent enquiry in one round trip.
  ///
  /// Task parity ([FirebaseService.sendMessage]): [unreadRecipientUids] are
  /// merged into the same parent `update()` that bumps `updatedAt`, so a device
  /// can never delta-sync the new message without also syncing its count. See
  /// [UnreadCountsMixin.unreadFieldUpdates].
  Future<String> sendMessage(
    String enquiryId,
    MessageModel message, {
    String? messageId,
    Iterable<String> unreadRecipientUids = const [],
  }) async {
    final id = messageId ?? _messages(enquiryId).doc().id;
    final msgWithId = message.copyWith(id: id);
    await _messages(enquiryId).doc(id).set(msgWithId.toMap());

    // B7 parity with FirebaseService.sendMessage: cap the denormalized preview.
    // This wrote the whole body into the enquiry doc, so one long message
    // bloated the parent document (re-delivered to every device by delta sync)
    // and every card that renders lastMessageText.
    await _enquiries().doc(enquiryId).update({
      'lastMessageText': lastMessageSnippet(message.text),
      'lastMessageTime': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      ...UnreadCountsMixin.unreadFieldUpdates(
        message.senderId,
        unreadRecipientUids,
      ),
    });

    // B3 parity: the message set + the parent-enquiry lastMessage update.
    // This service recorded no telemetry at all, so the diagnostics write
    // counter only ever reflected Task traffic and a Sales/CRM-heavy session
    // looked artificially quiet. No-op unless diagnostics are enabled.
    SyncTelemetry.instance.recordWrite(2);

    return id;
  }

  Future<List<MessageModel>> getRecentMessages(
    String enquiryId, {
    int limit = 50,
  }) async {
    final snapshot = await _messages(
      enquiryId,
    ).orderBy('createdAt', descending: true).limit(limit).get();
    final msgs = snapshot.docs
        .map(
          (doc) =>
              MessageModel.fromMap(doc.data() as Map<String, dynamic>, doc.id),
        )
        .toList();
    return msgs.reversed.toList();
  }

  Future<List<MessageModel>> getOlderMessages(
    String enquiryId,
    DateTime before, {
    int limit = 30,
  }) async {
    final snapshot = await _messages(enquiryId)
        .orderBy('createdAt', descending: true)
        .where('createdAt', isLessThan: Timestamp.fromDate(before))
        .limit(limit)
        .get();
    final msgs = snapshot.docs
        .map(
          (doc) =>
              MessageModel.fromMap(doc.data() as Map<String, dynamic>, doc.id),
        )
        .toList();
    return msgs.reversed.toList();
  }

  Future<List<MessageModel>> getMessages(String enquiryId) async {
    try {
      final snapshot = await _messages(enquiryId)
          .orderBy('createdAt', descending: false)
          .get(const GetOptions(source: Source.cache));
      return snapshot.docs
          .map(
            (doc) => MessageModel.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .toList();
    } catch (_) {
      final snapshot = await _messages(enquiryId)
          .orderBy('createdAt', descending: false)
          .get(const GetOptions(source: Source.serverAndCache));
      return snapshot.docs
          .map(
            (doc) => MessageModel.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .toList();
    }
  }

  Future<void> updateMessage(
    String enquiryId,
    String messageId,
    Map<String, dynamic> data,
  ) async {
    await _messages(enquiryId).doc(messageId).update(data);
    SyncTelemetry.instance.recordWrite();
  }

  Future<void> markMessageRead(
    String enquiryId,
    String messageId,
    String userId,
  ) async {
    try {
      await _messages(
        enquiryId,
      ).doc(messageId).update({'readBy.$userId': FieldValue.serverTimestamp()});
      SyncTelemetry.instance.recordWrite();
    } catch (e) {
      print('[$logTag] Error marking read: $e');
    }
  }

  Future<void> markMessagesDelivered(
    String enquiryId,
    List<String> messageIds,
    String userId,
  ) async {
    if (messageIds.isEmpty) return;
    try {
      for (int i = 0; i < messageIds.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final chunk = messageIds.sublist(
          i,
          (i + 400).clamp(0, messageIds.length),
        );
        for (final msgId in chunk) {
          final ref = _messages(enquiryId).doc(msgId);
          batch.update(ref, {
            'deliveredTo.$userId': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        SyncTelemetry.instance.recordWrite(chunk.length);
      }
    } catch (e) {
      print('[$logTag] Error marking delivered: $e');
    }
  }

  Future<void> markAllMessagesRead(String enquiryId, String userId) async {
    try {
      // Unread IDs come from SQLite — avoids reading the entire Firestore
      // messages subcollection on every chat open just to write receipts
      final unreadIds = await LocalDatabaseService().getUnreadMessageIds(
        enquiryId,
        userId,
      );
      if (unreadIds.isEmpty) return;

      for (int i = 0; i < unreadIds.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final chunk = unreadIds.sublist(
          i,
          (i + 400).clamp(0, unreadIds.length),
        );
        for (final msgId in chunk) {
          batch.update(_messages(enquiryId).doc(msgId), {
            'readBy.$userId': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        SyncTelemetry.instance.recordWrite(chunk.length);
      }
    } catch (e) {
      print('[$logTag] Error marking all read: $e');
    }
  }

  Future<List<MessageModel>> getMessagesFromLocal(
    String enquiryId, {
    int limit = 50,
  }) async {
    try {
      return await LocalDatabaseService().getMessages(enquiryId, limit: limit);
    } catch (e) {
      print('[$logTag] Failed to get messages from local DB: $e');
      return [];
    }
  }
}
