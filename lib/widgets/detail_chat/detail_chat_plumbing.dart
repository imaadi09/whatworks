import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../services/external_notification_service.dart';
import '../../utils/constants.dart';

/// Shared chat plumbing for detail screens: connectivity monitoring and
/// read/delivered receipt bookkeeping.
///
/// Extracted verbatim from the task detail screen (the base module) so that
/// task and sales detail screens share one implementation.
mixin DetailChatPlumbingMixin<T extends StatefulWidget> on State<T> {
  // ---- Owned state ----
  bool isOffline = false;
  Timer? connectivityTimer;
  final Set<String> markedAsReadIds =
      {}; // Track which messages we've already marked as read
  final Set<String> markedAsDeliveredIds =
      {}; // Track which messages we've already marked as delivered

  // ---- Hooks the host screen must provide ----
  String get chatCurrentUserId;

  /// Mark a single message as read on the backend.
  void chatMarkMessageRead(String messageId);

  /// Batch-mark messages as delivered on the backend.
  void chatMarkMessagesDelivered(List<String> messageIds);

  /// Reset the current user's unread count on the parent document.
  void chatResetMyUnreadCount();

  /// Start connectivity monitoring: check immediately, then every 15 seconds.
  void startConnectivityMonitor() {
    checkConnectivity();
    connectivityTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      checkConnectivity();
    });
  }

  /// Check internet connectivity and update offline banner
  Future<void> checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 5));
      final isOnline = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      final nowOffline = !isOnline;
      if (mounted && isOffline != nowOffline) {
        setState(() {
          isOffline = nowOffline;
        });
      }
    } catch (_) {
      if (mounted && !isOffline) {
        setState(() {
          isOffline = true;
        });
      }
    }
  }

  // Mark messages as read and delivered when chat is opened
  void markChatMessagesAsRead(List<MessageModel> messages) {
    bool hasNewReads = false;
    final deliveredIds = <String>[];

    for (final message in messages) {
      // Only mark messages from others (not your own, not system)
      if (message.senderId != chatCurrentUserId &&
          message.senderId != 'system') {
        // Mark as delivered (if not already)
        if (!markedAsDeliveredIds.contains(message.id)) {
          if (message.deliveredTo == null ||
              !message.deliveredTo!.containsKey(chatCurrentUserId)) {
            deliveredIds.add(message.id);
            markedAsDeliveredIds.add(message.id);
          } else {
            markedAsDeliveredIds.add(message.id);
          }
        }

        // Mark as read (if not already)
        if (markedAsReadIds.contains(message.id)) continue;
        if (message.readBy == null ||
            !message.readBy!.containsKey(chatCurrentUserId)) {
          chatMarkMessageRead(message.id);
          markedAsReadIds.add(message.id);
          hasNewReads = true;
        }
      }
    }

    // Batch-mark delivered
    if (deliveredIds.isNotEmpty) {
      chatMarkMessagesDelivered(deliveredIds);
    }

    // Only reset unread count if we actually marked new messages as read
    if (hasNewReads) {
      chatResetMyUnreadCount();
    }
  }

  /// Tear down plumbing resources owned by this mixin.
  void disposeDetailChatPlumbing() {
    connectivityTimer?.cancel();
  }

  // ---- WhatsApp-style reply (quote) composer ----

  /// Reply-preview bar shown above the text input while a message is quoted.
  ///
  /// Shared so the quote looks identical in Task and Sales/CRM; [accent]
  /// carries the module theme colour (Task green, Sales/CRM their own hue).
  /// The host screen owns the "which message am I replying to" state.
  Widget buildChatReplyPreview(
    MessageModel target, {
    required String senderName,
    required Color accent,
    required VoidCallback onCancel,
  }) {
    final previewText = target.text.length > 80
        ? '${target.text.substring(0, 80)}...'
        : target.text;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          // Accent left-border indicator
          Container(
            width: 3,
            height: 32,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Quoted content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  previewText,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Close button
          GestureDetector(
            onTap: onCancel,
            child: const Icon(Icons.close, size: 18, color: AppTheme.lightText),
          ),
        ],
      ),
    );
  }

  // ---- Out-of-app delivery (WhatsApp / SMS nudge) ----

  /// Route a message to the card's assignee, offering WhatsApp/SMS when they
  /// are not on the WhatWorks app.
  ///
  /// Shared so Task and Sales/CRM prompt identically. [onSent] receives
  /// 'in-app', 'whatsapp', 'sms' or 'failed' — the host screen stamps it onto
  /// the persisted message's `deliveryMethod`. It is deliberately NOT called
  /// when the user cancels: the composer still holds the text, so cancelling
  /// loses nothing.
  Future<void> chatDeliverToRecipient({
    required ExternalRecipient recipient,
    required String title,
    required String message,
    required ValueChanged<String> onSent,
    required Color accent,
  }) async {
    // On the app (or no phone number to reach them on) — send in-app silently.
    if (!recipient.needsExternalNudge) {
      onSent('in-app');
      return;
    }
    if (!mounted) return;

    final externalService = ExternalNotificationService();
    final chosenMethod = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.send, color: accent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${recipient.name} is not on the WhatWorks app.',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Send notification via:',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.chat, color: Color(0xFF25D366)),
              ),
              title: const Text(
                'WhatsApp',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(recipient.phone),
              onTap: () => Navigator.pop(ctx, 'whatsapp'),
              contentPadding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.sms, color: Colors.blue),
              ),
              title: const Text(
                'SMS',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(recipient.phone),
              onTap: () => Navigator.pop(ctx, 'sms'),
              contentPadding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (chosenMethod == null || chosenMethod == 'cancel') return;

    final success = chosenMethod == 'whatsapp'
        ? await externalService.sendWhatsApp(recipient.phone, message)
        : await externalService.sendSMS(recipient.phone, message);
    onSent(success ? chosenMethod : 'failed');
  }
}
