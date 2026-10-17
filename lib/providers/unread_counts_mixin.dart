import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../services/local_database_service.dart';
import '../utils/helpers.dart';

/// Shared unread-count logic (roadmap G2 / duplication item D4) for the
/// list+detail providers.
///
/// Both tasks and enquiries store a per-user `unreadCounts` JSON map (a local
/// SQLite column AND a Firestore field). The two algorithms — bump every
/// recipient when a message is posted, and reset the opener's count when they
/// open the thread — are IDENTICAL across modules, but were duplicated per
/// provider. Worse, the Sales/CRM reset had DIVERGED: it wrote only to
/// Firestore, so the local badge never cleared (the unread write doesn't bump
/// `updatedAt`, so watermarked delta sync won't echo it back to SQLite).
///
/// This is a COMMON resource: written once and mixed into both `TaskProvider`
/// and `BaseModuleProvider` (which Sales and CRM extend), so all three modules
/// share one correct implementation. A module supplies only two hooks — which
/// local table holds the row, and the raw transport that writes unread fields
/// to that module's Firestore collection — the same hook pattern
/// `ModuleCachesMixin` and `ChangeSetConsumerMixin` already use.
mixin UnreadCountsMixin on ChangeNotifier {
  /// The local table whose `unreadCounts` column backs the badge
  /// (e.g. `tasks`, `enquiries`, `crm_enquiries`).
  @protected
  String get unreadTableName;

  /// Write raw `unreadCounts.*` field updates to the module's Firestore doc.
  /// MUST NOT bump `updatedAt`: the watermarked delta sync keys off it, and a
  /// bump on every chat-open would churn the whole row back to every device.
  @protected
  Future<void> writeUnreadFields(String itemId, Map<String, dynamic> updates);

  /// Field updates that bump every recipient's unread count by 1 and clear the
  /// sender's, in the dot-path shape Firestore needs. Single source of truth
  /// for the map, shared by all three modules.
  ///
  /// Applied as part of the SAME Firestore `update()` that moves the parent's
  /// `updatedAt` (FirebaseService.sendMessage / BaseModuleService.sendMessage),
  /// never as a follow-up write. A separate `updatedAt`-silent write cannot win
  /// that race: a device whose delta sync fires on the clock bump reads the
  /// pre-increment count, and since the increment bumps nothing no later sync
  /// is ever triggered to correct it — the recipient's badge then stays absent
  /// until some unrelated edit happens to touch the parent. Merging them makes
  /// "saw the new message" and "saw its count" one atomic read.
  static Map<String, dynamic> unreadFieldUpdates(
    String senderId,
    Iterable<String> recipientUids,
  ) {
    final updates = <String, dynamic>{};
    for (final uid in recipientUids) {
      if (uid.isEmpty || uid == senderId) continue;
      updates['unreadCounts.$uid'] = FieldValue.increment(1);
    }
    if (updates.isEmpty) return const {};
    // The sender has, by definition, read their own message.
    updates['unreadCounts.$senderId'] = 0;
    return updates;
  }

  /// Whether a freshly sent message should raise an unread badge for the
  /// people it went to.
  ///
  /// Ordinary chat always does. A system row only when it is an action that
  /// awaits the recipient (query / approval / extension / blocker / follow-up /
  /// call) — deliberately the SAME definition the card action chips and the
  /// bell pending count use, so a card never shows a chip without also counting
  /// the message, or the reverse. Informational lines (progress, status, the
  /// "Card created" entry, assignee changes) stay quiet, which is the rule the
  /// Task detail screen applied before this moved into the send path.
  static bool awaitsRecipientRead(MessageType type, String text) =>
      type != MessageType.system || Helpers.awaitsClosure(text);

  /// Reset the current user's unread count to 0 when they open the thread.
  ///
  /// Written to SQLite FIRST, then Firestore. The remote unread write doesn't
  /// bump `updatedAt`, so watermarked delta sync won't echo it back — without
  /// the local write the badge would never clear. This is exactly the bug the
  /// mixin fixes for Sales/CRM (Task already did the local write).
  void resetMyUnreadCount(String itemId, String userId) {
    LocalDatabaseService()
        .resetUnreadCountLocal(unreadTableName, itemId, userId)
        .catchError((e) {
          print('Error resetting local unread count: $e');
        });
    writeUnreadFields(itemId, {'unreadCounts.$userId': 0}).catchError((e) {
      print('Error resetting unread count: $e');
    });
  }
}
