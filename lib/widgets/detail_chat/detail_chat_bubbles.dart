import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/message.dart';
import '../../services/local_storage_service.dart';
import '../../services/storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';

/// Shared WhatsApp-style message bubble suite used by Task Detail (base
/// module) and Sales/CRM Detail. Extracted verbatim from Task Detail;
/// screen-specific data, actions and theming are provided via chat* hooks.
mixin DetailChatBubblesMixin<T extends StatefulWidget> on State<T> {
  // Voice playback state (for voice bubbles)
  String? currentlyPlayingMessageId;
  final AudioPlayer voiceBubblePlayer = AudioPlayer();
  StreamSubscription? voiceCompleteSub; // Cancellable listener

  /// Call from the host screen's dispose().
  void disposeDetailChatBubbles() {
    voiceBubblePlayer.dispose();
    voiceCompleteSub?.cancel();
  }

  // ---- Data hooks (implemented by the host screen) ----
  String get chatCurrentUserId;

  /// Entity (task/enquiry) this chat belongs to.
  String get chatEntityId;

  /// Firestore root collection holding this chat's messages
  /// ('tasks' | 'sales_enquiries' | 'crm_records').
  String get chatMessagesCollection;

  /// Participant set used for the tick (status) icon.
  Set<String> get chatTickParticipants;

  /// Participant set used for "Seen by" dialog and delivery summary.
  Set<String> get chatAllParticipants;

  String chatSenderName(String senderId);
  String chatUserNameById(String uid);
  Map<String, double> get chatUploadProgress;
  Future<String?> chatLocalPathFor(MessageModel message);

  /// Loaded chat messages (also declared by DetailChatAttachmentsMixin;
  /// the host screen implements it once).
  List<MessageModel> get chatMessages;

  /// Synchronous memoized local-path lookup (see DetailChatAttachmentsMixin).
  String? chatCachedLocalPath(MessageModel message);

  // ---- Action hooks ----
  Future<void> chatRetryUpload(MessageModel message);
  void chatOpenImageViewer(String url);
  Future<void> chatOpenDocument(MessageModel message);
  Future<void> chatOpenPendingFile(MessageModel message, String localPath);
  Widget chatBuildSystemMessage(MessageModel message);

  // ---- Theme hooks ----
  Color get chatAccentColor;
  Color get chatTextBubbleMineBg;
  Color get chatMediaBubbleMineBg;
  Color get chatSenderNameColor;
  Color get chatVoiceMineColor;
  Color get chatVoiceOtherColor;
  Color get chatUrgentColor;

  // ---- Feature flags ----
  bool get chatShowInlineTicks;
  bool get chatShowDeliverySummary;

  // ---- Dark-mode bubble inversion helpers (P4d) ----
  /// True when the host theme is dark; bubbles invert to dark bg + light text.
  bool get _chatIsDark => Theme.of(context).brightness == Brightness.dark;

  /// Primary text drawn on a bubble: white in dark mode, near-black in light.
  Color get _bubbleText => _chatIsDark ? Colors.white : AppTheme.primaryText;

  /// Timestamp / duration / meta text drawn on a bubble.
  Color get _bubbleTimeText =>
      _chatIsDark ? Colors.white.withOpacity(0.7) : AppTheme.lightText;

  /// WhatsApp-style canvas behind the bubbles: a soft warm grey in light
  /// mode so white other-side bubbles read clearly; untouched in dark.
  Color get chatCanvasColor =>
      _chatIsDark ? Colors.transparent : const Color(0xFFEFEDE8);

  /// Sender label text: the person's first name ('Me' stays) — bare
  /// initials like "so" were too cryptic to read at a glance.
  String chatSenderLabel(String senderId) {
    final name = chatSenderName(senderId).trim();
    final i = name.indexOf(' ');
    return i == -1 ? name : name.substring(0, i);
  }

  /// Readable deep tone of the host accent for the "Me" label on a tinted
  /// bubble (works for the green task accent and the blue sales accent).
  Color get _chatMineLabel => _chatIsDark
      ? Colors.white70
      : HSLColor.fromColor(chatAccentColor).withLightness(0.30).toColor();

  /// Hairline edge for other-side bubbles in light mode so white-on-canvas
  /// bubbles keep a visible boundary.
  BoxBorder? get _chatOtherBorder => _chatIsDark
      ? null
      : Border.all(color: AppTheme.separator.withOpacity(0.9));

  // ---- Optional overrides (task-only features) ----
  bool chatIsCurrentSearchResult(String messageId) => false;
  void Function(MessageModel message)? get chatSearchInsideDocument => null;

  // Attachments currently being downloaded on tap (message ids).
  final Set<String> downloadingAttachmentIds = {};

  /// Download an attachment on user tap (never automatic). Tracks the
  /// download receipt and lets StorageService delete the server copy once
  /// every recipient has it. Returns the local path, or null on failure.
  Future<String?> downloadAttachmentOnTap(MessageModel message) async {
    if (message.fileUrl == null ||
        message.fileUrl!.isEmpty ||
        message.fileName == null) {
      return null;
    }
    if (downloadingAttachmentIds.contains(message.id)) return null;
    setState(() => downloadingAttachmentIds.add(message.id));
    try {
      final path = await StorageService().downloadAndCacheAttachment(
        chatEntityId,
        message.id,
        message.fileName!,
        message.fileUrl!,
        chatCurrentUserId,
        collection: chatMessagesCollection,
        senderId: message.senderId,
        participants: chatAllParticipants,
      );
      if (path == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Attachment is no longer available on the server'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return path;
    } finally {
      if (mounted) {
        setState(() => downloadingAttachmentIds.remove(message.id));
      }
    }
  }

  // ---- Chat-open server cleanup sweep (minimal-server policy) ----

  bool _chatCleanupSweepScheduled = false;

  /// One-shot background sweep run shortly after a chat opens. Enforces the
  /// minimal-server policy end-to-end:
  ///
  ///  1. Backfills missing `downloadedBy` receipts for attachments already
  ///     cached locally (legacy gap: cached users never wrote a receipt),
  ///     then deletes the Storage object once every recipient has it.
  ///  2. Deletes this user's OWN message docs from the server once every
  ///     other participant has read them (`readBy` receipts) — each device
  ///     keeps its SQLite copy, so history is unaffected. Free plan: after
  ///     a 1-hour safety window (the edit / delete-for-everyone period);
  ///     enterprise plan: 30-day server retention.
  ///
  /// Call from the host screen's initState with the user's plan type.
  void scheduleChatCleanupSweep(String planType) {
    if (_chatCleanupSweepScheduled) return;
    _chatCleanupSweepScheduled = true;
    Future.delayed(const Duration(seconds: 8), () {
      if (!mounted) return;
      _runChatCleanupSweep(planType);
    });
  }

  Future<void> _runChatCleanupSweep(String planType) async {
    final storage = StorageService();
    final me = chatCurrentUserId;
    final collection = chatMessagesCollection;
    final entityId = chatEntityId;
    if (me.isEmpty || entityId.isEmpty) return;
    final participants = chatAllParticipants.where((u) => u.isNotEmpty).toSet();
    if (participants.isEmpty) return;

    final now = DateTime.now();
    // Paid tiers keep a 24-hour server copy; basic cleans once past the
    // 1-hour edit / delete-for-everyone window.
    final minAge = PaywallLimits.isPremium(planType)
        ? const Duration(hours: 24)
        : const Duration(hours: 1);

    // Snapshot — the live list mutates while streams update.
    final messages = List<MessageModel>.from(chatMessages);
    for (final msg in messages) {
      if (!mounted) return;
      try {
        final fileUrl = msg.fileUrl;
        final hasServerFile =
            fileUrl != null &&
            fileUrl.startsWith('http') &&
            msg.fileName != null;
        final recipients = participants.where((u) => u != msg.senderId).toSet();
        var downloadedBy = msg.downloadedBy ?? const <String, bool>{};

        // 1) Attachment receipt backfill + Storage cleanup
        if (hasServerFile && recipients.isNotEmpty) {
          if (msg.senderId != me && downloadedBy[me] != true) {
            final localPath = await chatLocalPathFor(msg);
            if (localPath != null && File(localPath).existsSync()) {
              await storage.trackAttachmentDownload(
                entityId,
                msg.id,
                me,
                collection: collection,
              );
              downloadedBy = {...downloadedBy, me: true};
            }
          }
          if (recipients.every((u) => downloadedBy[u] == true)) {
            await storage.maybeDeleteServerAttachment(
              collection: collection,
              entityId: entityId,
              messageId: msg.id,
              fileUrl: fileUrl,
              senderId: msg.senderId,
              participants: participants,
            );
          }
        }

        // 2) Own-message doc cleanup — Firestore rules only let the sender
        // delete, and only messages every recipient has read qualify
        // (their SQLite copy is the source of truth).
        if (msg.senderId != me || recipients.isEmpty) continue;
        if (msg.isUploadFailed) continue;
        if (now.difference(msg.createdAt) < minAge) continue;
        final readBy = msg.readBy ?? const <String, DateTime>{};
        if (!recipients.every(readBy.containsKey)) continue;
        if (fileUrl != null && fileUrl.isNotEmpty && fileUrl != 'failed') {
          // Attachment still pending upload — keep the doc.
          if (!fileUrl.startsWith('http')) continue;
          // Keep the doc (it carries the URL) until every recipient has
          // downloaded; then drop the server file along with the doc.
          if (!recipients.every((u) => downloadedBy[u] == true)) continue;
          await storage.deleteFile(fileUrl);
        }
        await FirebaseFirestore.instance
            .collection(collection)
            .doc(entityId)
            .collection('messages')
            .doc(msg.id)
            .delete();
        print(
          '[ChatCleanup] Server message removed (all read): '
          '$collection/$entityId/${msg.id}',
        );
      } catch (e) {
        // Per-message failures (permissions, races) never abort the sweep.
        print('[ChatCleanup] Sweep skipped for ${msg.id}: $e');
      }
    }
  }

  Widget buildMessageBubble(
    MessageModel message,
    bool isMe, {
    bool showSenderName = true,
    bool showTimestamp = true,
    bool isSearchMatch = false,
    bool isSelected = false,
  }) {
    // Render tombstone for soft-deleted messages
    if (message.deleted) {
      return buildDeletedMessage(message, isMe);
    }

    Widget bubble;
    switch (message.type) {
      case MessageType.image:
        bubble = buildImageBubble(message, isMe);
        break;
      case MessageType.file:
        bubble = buildFileBubble(message, isMe);
        break;
      case MessageType.voice:
        bubble = buildVoiceBubble(message, isMe);
        break;
      case MessageType.system:
        bubble = Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: chatBuildSystemMessage(message),
        );
        break;
      case MessageType.text:
        bubble = buildTextBubble(
          message,
          isMe,
          showSenderName: showSenderName,
          showTimestamp: showTimestamp,
        );
    }

    // Wrap with search highlight or selection overlay
    if (isSelected) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.blue.withOpacity(0.2),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.blue.withOpacity(0.5), width: 1.5),
        ),
        child: bubble,
      );
    }
    if (isSearchMatch) {
      return Container(
        decoration: BoxDecoration(
          color: chatIsCurrentSearchResult(message.id)
              ? Colors.yellow.withOpacity(0.4)
              : Colors.yellow.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: bubble,
      );
    }
    return bubble;
  }

  /// Tombstone bubble for soft-deleted messages (delete for everyone)
  Widget buildDeletedMessage(MessageModel message, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 16, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              'This message was deleted',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Slack-style text message with left/right alignment
  Widget buildTextBubble(
    MessageModel message,
    bool isMe, {
    bool showSenderName = true,
    bool showTimestamp = true,
  }) {
    final senderName = chatSenderLabel(message.senderId);
    final timeLabel = DateFormat('h:mm a').format(message.createdAt);

    // Dark-mode bubble inversion: dark bubbles + light text (iMessage-style).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bubbleBg = isMe
        ? (isDark ? chatAccentColor : chatTextBubbleMineBg)
        : Theme.of(context).cardColor;
    final Color bubbleText = isDark ? Colors.white : AppTheme.primaryText;
    final Color bubbleSubText = isDark
        ? Colors.white70
        : AppTheme.secondaryText;
    final Color bubbleAccentText = isDark
        ? Colors.white70
        : (isMe ? chatAccentColor : chatSenderNameColor);

    // Message content with visible chat box (iOS-style: rounded, borderless)
    final messageContent = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: BorderRadius.circular(18),
        border: isMe ? null : _chatOtherBorder,
        boxShadow: isMe || isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quoted/replied message preview (WhatsApp-style)
          if (message.replyToMessageText != null)
            Container(
              padding: const EdgeInsets.all(6),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.10)
                    : Colors.grey.withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border(
                  left: BorderSide(
                    color: isDark
                        ? Colors.white54
                        : (isMe ? chatAccentColor : AppTheme.secondaryText),
                    width: 3,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.replyToMessageSender ?? '',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: bubbleAccentText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    message.replyToMessageText!,
                    style: TextStyle(fontSize: 12, color: bubbleSubText),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          // Sender name (only show if first message from sender)
          if (showSenderName)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                senderName,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? Colors.white70
                      : (isMe ? _chatMineLabel : AppTheme.primaryText),
                ),
              ),
            ),
          // Message text with inline timestamp (WhatsApp-style)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: RichText(
                  // Left-aligned, not justify: justified text stretches each
                  // line to the full bubble width and leaves the last line
                  // short, which on a right-aligned (own) bubble reads as an
                  // uneven extra gap on the right. iOS Messages body text is
                  // left-aligned.
                  textAlign: TextAlign.left,
                  text: TextSpan(
                    style: TextStyle(
                      // iOS Messages body size (was 14, WhatsApp-sized).
                      fontSize: 16,
                      color: bubbleText,
                      height: 1.3,
                    ),
                    children: parseRichText(message.text),
                  ),
                ),
              ),
              if (showTimestamp) ...[
                const SizedBox(width: 6),
                Text(
                  timeLabel,
                  style: TextStyle(
                    fontSize: 9,
                    color: isDark
                        ? Colors.white.withOpacity(isMe ? 0.7 : 0.6)
                        : AppTheme.lightText.withOpacity(isMe ? 0.5 : 0.4),
                  ),
                ),
                if (isMe && chatShowInlineTicks) ...[
                  const SizedBox(width: 2),
                  buildMessageStatusIcon(message),
                ],
              ],
            ],
          ),
          // Inline cards (deadline/progress)
          if (hasDeadlineInfo(message)) buildDeadlineCard(message),
          if (hasProgressInfo(message)) buildProgressCard(message),
        ],
      ),
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: messageContent,
    );
  }

  // Parse WhatsApp-style rich text formatting
  // Supports: *bold*, _italic_, ~strikethrough~, `code`
  List<InlineSpan> parseRichText(String text) {
    final spans = <InlineSpan>[];

    if (text.isEmpty) return spans;

    // Combined regex: formatting + URLs
    final pattern = RegExp(
      r'(\*([^*]+)\*)|' // *bold*
      r'(_([^_]+)_)|' // _italic_
      r'(~([^~]+)~)|' // ~strikethrough~
      r'`([^`]+)`|' // `code`
      r'(https?:\/\/[^\s]+)', // URLs
    );

    var lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      // Add plain text before match
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      // Add formatted text
      if (match.group(1) != null) {
        // Bold: *text*
        spans.add(
          TextSpan(
            text: match.group(2),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (match.group(3) != null) {
        // Italic: _text_
        spans.add(
          TextSpan(
            text: match.group(4),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else if (match.group(5) != null) {
        // Strikethrough: ~text~
        spans.add(
          TextSpan(
            text: match.group(6),
            style: const TextStyle(decoration: TextDecoration.lineThrough),
          ),
        );
      } else if (match.group(7) != null) {
        // Code: `text`
        spans.add(
          TextSpan(
            text: match.group(7),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: _chatIsDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.grey[200],
              fontSize: 13,
            ),
          ),
        );
      } else if (match.group(8) != null) {
        // URL: make it tappable
        final url = match.group(8)!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () async {
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  try {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } catch (_) {}
                }
              },
              child: Text(
                url,
                style: TextStyle(
                  color: _chatIsDark ? const Color(0xFF7FB2FF) : Colors.blue,
                  decoration: TextDecoration.underline,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    // Add remaining plain text
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return spans;
  }

  // Check if message contains deadline information
  bool hasDeadlineInfo(MessageModel message) {
    final lower = message.text.toLowerCase();
    return lower.contains('deadline') ||
        lower.contains('due date') ||
        lower.contains('due by');
  }

  // Check if message contains progress information
  bool hasProgressInfo(MessageModel message) {
    final lower = message.text.toLowerCase();
    return lower.contains('progress') && RegExp(r'\d+%').hasMatch(message.text);
  }

  // Extract deadline from message
  DateTime? extractDeadline(MessageModel message) {
    // Try to find date pattern: DD/MM/YYYY or DD-MM-YYYY
    final dateRegex = RegExp(r'(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})');
    final match = dateRegex.firstMatch(message.text);

    if (match != null) {
      try {
        return DateTime(
          int.parse(match.group(3)!),
          int.parse(match.group(2)!),
          int.parse(match.group(1)!),
        );
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  // Extract progress percentage from message
  int? extractProgress(MessageModel message) {
    final progressRegex = RegExp(r'(\d+)%');
    final match = progressRegex.firstMatch(message.text);

    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  // Build inline deadline card
  Widget buildDeadlineCard(MessageModel message) {
    final deadline = extractDeadline(message);
    if (deadline == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final daysRemaining = deadline.difference(now).inDays;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (daysRemaining < 0) {
      statusColor = chatUrgentColor;
      statusText = Helpers.overdueLabel(daysRemaining.abs());
      statusIcon = Icons.warning_rounded;
    } else if (daysRemaining <= 3) {
      statusColor = const Color(0xFFF59F00);
      statusText = daysRemaining == 0
          ? 'Due today'
          : '${Helpers.dayCountLabel(daysRemaining)} remaining';
      statusIcon = Icons.schedule;
    } else {
      statusColor = const Color(0xFF2F9E44);
      statusText = '${Helpers.dayCountLabel(daysRemaining)} remaining';
      statusIcon = Icons.check_circle;
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DateFormat('EEE, MMM d, yyyy').format(deadline),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _bubbleText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 10,
                    color: statusColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Build inline progress card
  Widget buildProgressCard(MessageModel message) {
    final progress = extractProgress(message);
    if (progress == null) return const SizedBox.shrink();

    Color progressColor;
    String statusLabel;

    if (progress >= 80) {
      progressColor = const Color(0xFF2F9E44);
      statusLabel = 'On Track';
    } else if (progress >= 50) {
      progressColor = const Color(0xFF1976D2);
      statusLabel = 'In Progress';
    } else if (progress >= 30) {
      progressColor = const Color(0xFFF59F00);
      statusLabel = 'Behind';
    } else {
      progressColor = chatUrgentColor;
      statusLabel = 'At Risk';
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: progressColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: progressColor.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Progress',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _bubbleText,
                ),
              ),
              Text(
                '$progress%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: progressColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress / 100,
              backgroundColor: progressColor.withOpacity(0.2),
              valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            statusLabel,
            style: TextStyle(
              fontSize: 10,
              color: progressColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // Build pending image preview — shows local cached image with pending badge
  Widget buildPendingImagePreview(MessageModel message) {
    final progress = chatUploadProgress[message.id];
    final hasProgress = progress != null && progress > 0;
    return FutureBuilder<String?>(
      future: chatLocalPathFor(message),
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        final hasLocalFile = localPath != null && File(localPath).existsSync();
        return Stack(
          children: [
            // Image or placeholder
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: hasLocalFile
                  ? Image.file(
                      File(localPath),
                      width: 250,
                      height: 180,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 250,
                      height: 180,
                      color: AppTheme.lightGrey,
                      child: const Center(
                        child: Icon(
                          Icons.image,
                          size: 48,
                          color: AppTheme.lightText,
                        ),
                      ),
                    ),
            ),
            // Pending overlay
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: hasProgress ? Colors.black54 : Colors.orange,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: hasProgress
                    ? Text(
                        '${(progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Pending',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Open a pending attachment from local cache
  Future<void> openPendingAttachment(MessageModel message) async {
    try {
      final localPath = await chatLocalPathFor(message);
      if (localPath != null && File(localPath).existsSync()) {
        // Open local file based on type
        if (message.type == MessageType.image) {
          // Show local image in full-screen viewer
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: const Text(
                    'Pending Upload',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                body: Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.file(File(localPath), fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          );
        } else if (message.type == MessageType.voice) {
          // Voice playback handled in the voice bubble widget
        } else if (message.type == MessageType.file) {
          // Open file with host-specific handler
          await chatOpenPendingFile(message, localPath);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File not available locally'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      print('[DetailChat] Error opening pending attachment: $e');
    }
  }

  // WhatsApp-style image bubble
  Widget buildImageBubble(MessageModel message, bool isMe) {
    final isPending = message.fileUrl == 'pending';
    final isFailed = message.isUploadFailed;
    return wrapBubble(
      isMe: isMe,
      padding: const EdgeInsets.all(3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 4),
              child: buildSenderNameLabel(message.senderId),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              onTap: isFailed
                  ? () => chatRetryUpload(message)
                  : isPending
                  ? () => openPendingAttachment(message)
                  : () async {
                      // Local copy → open viewer; otherwise download on tap
                      // (attachments are never fetched automatically).
                      final lp = await chatLocalPathFor(message);
                      if (lp != null && File(lp).existsSync()) {
                        chatOpenImageViewer(lp);
                      } else {
                        await downloadAttachmentOnTap(message);
                      }
                    },
              child: isFailed
                  ? Container(
                      width: 250,
                      height: 180,
                      color: Colors.red.withOpacity(0.08),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 36,
                              color: Colors.red,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              message.uploadError ?? 'Upload failed',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.red,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Tap to retry',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.blue,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : isPending
                  ? buildPendingImagePreview(message)
                  : _buildLocalFirstImage(message),
            ),
          ),
          if (message.text.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 4),
              child: Text(
                message.text,
                style: TextStyle(fontSize: 14, color: _bubbleText),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 2, top: 2),
            child: buildTimeRow(message, isMe),
          ),
        ],
      ),
    );
  }

  /// Local-first image rendering: synchronous cache hit renders the file
  /// immediately; otherwise resolve the local path async showing a neutral
  /// placeholder, and only fall back to the network when confirmed absent.
  Widget _buildLocalFirstImage(MessageModel message) {
    final cachedPath = chatCachedLocalPath(message);
    if (cachedPath != null) {
      return Image.file(
        File(cachedPath),
        width: 250,
        height: 180,
        fit: BoxFit.cover,
      );
    }

    return FutureBuilder<String?>(
      future: chatLocalPathFor(message),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Still resolving the local path — don't start a network fetch
          return Container(
            width: 250,
            height: 180,
            color: AppTheme.lightGrey,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final imagePath = snapshot.data;
        if (imagePath != null && File(imagePath).existsSync()) {
          return Image.file(
            File(imagePath),
            width: 250,
            height: 180,
            fit: BoxFit.cover,
          );
        }

        // Not cached locally — show a tap-to-download tile instead of
        // auto-fetching from the network (minimal-server policy).
        final isDownloading = downloadingAttachmentIds.contains(message.id);
        return Container(
          width: 250,
          height: 180,
          color: AppTheme.lightGrey,
          child: Center(
            child: isDownloading
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.download_for_offline_outlined,
                        size: 40,
                        color: AppTheme.secondaryText,
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Tap to download',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  // WhatsApp-style file bubble
  Widget buildFileBubble(MessageModel message, bool isMe) {
    final ext = (message.fileName ?? '').split('.').last.toLowerCase();
    final isFailed = message.isUploadFailed;
    IconData icon;
    Color iconColor;
    switch (ext) {
      case 'pdf':
        icon = Icons.picture_as_pdf;
        iconColor = Colors.red;
        break;
      case 'doc':
      case 'docx':
        icon = Icons.description;
        iconColor = Colors.blue;
        break;
      case 'xls':
      case 'xlsx':
        icon = Icons.table_chart;
        iconColor = Colors.green;
        break;
      case 'ppt':
      case 'pptx':
        icon = Icons.slideshow;
        iconColor = Colors.orange;
        break;
      default:
        icon = Icons.insert_drive_file;
        iconColor = AppTheme.secondaryText;
    }

    // Cap to the 240 action-card family: an attachment-only bubble used to
    // stretch to the 75% bubble ceiling and read wider than every card
    // beside it in the feed.
    return wrapBubble(
      isMe: isMe,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) buildSenderNameLabel(message.senderId),
            InkWell(
              onTap: isFailed
                  ? () => chatRetryUpload(message)
                  : message.fileUrl == 'pending'
                  ? () => openPendingAttachment(message)
                  : () => chatOpenDocument(message),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (isFailed ? Colors.red : iconColor).withOpacity(
                        0.1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isFailed ? Icons.error_outline : icon,
                      size: 32,
                      color: isFailed ? Colors.red : iconColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.fileName ?? 'Unknown file',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: _bubbleText,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        if (isFailed)
                          Text(
                            '${message.uploadError ?? 'Upload failed'} \u2022 Tap to retry',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.red,
                            ),
                          )
                        else
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                ext.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _bubbleTimeText,
                                ),
                              ),
                              if (message.searchableContent != null &&
                                  chatSearchInsideDocument != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: chatSenderNameColor.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    'Searchable',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: chatSenderNameColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Upload progress bar for pending file
            if (message.fileUrl == 'pending' && !isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: chatUploadProgress[message.id],
                        minHeight: 4,
                        backgroundColor: Colors.grey.shade300,
                        valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${((chatUploadProgress[message.id] ?? 0) * 100).toInt()}%',
                      style: TextStyle(fontSize: 10, color: iconColor),
                    ),
                  ],
                ),
              ),
            // Search inside document button
            if (message.searchableContent != null &&
                chatSearchInsideDocument != null) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => chatSearchInsideDocument!(message),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: chatSenderNameColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: chatSenderNameColor.withOpacity(0.2),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search, size: 14, color: chatSenderNameColor),
                      const SizedBox(width: 4),
                      Text(
                        'Search inside document',
                        style: TextStyle(
                          fontSize: 11,
                          color: chatSenderNameColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            buildTimeRow(message, isMe),
          ],
        ),
      ),
    );
  }

  // WhatsApp-style voice note bubble
  Widget buildVoiceBubble(MessageModel message, bool isMe) {
    final isPlaying = currentlyPlayingMessageId == message.id;
    final isFailed = message.isUploadFailed;
    return wrapBubble(
      isMe: isMe,
      child: GestureDetector(
        onTap: isFailed
            ? () => chatRetryUpload(message)
            : message.fileUrl == 'pending'
            ? () => toggleVoicePlaybackFromLocal(message)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) buildSenderNameLabel(message.senderId),
            if (isFailed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 20, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${message.uploadError ?? 'Upload failed'} \u2022 Tap to retry',
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
                ],
              )
            else if (message.fileUrl == 'pending')
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic, size: 20, color: _bubbleTimeText),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: chatUploadProgress[message.id],
                          minHeight: 4,
                          backgroundColor: Colors.grey.shade300,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isMe ? chatVoiceMineColor : chatVoiceOtherColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${((chatUploadProgress[message.id] ?? 0) * 100).toInt()}%',
                        style: TextStyle(fontSize: 10, color: _bubbleTimeText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Uploading voice note...',
                    style: TextStyle(fontSize: 10, color: _bubbleTimeText),
                  ),
                ],
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () => toggleVoiceBubblePlayback(message),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: isMe
                          ? chatVoiceMineColor
                          : chatVoiceOtherColor,
                      child: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Waveform bars
                  SizedBox(
                    width: 140,
                    height: 28,
                    child: Row(
                      children: List.generate(28, (i) {
                        final height = 4.0 + (i % 5) * 3.0 + (i % 3) * 2.0;
                        return Container(
                          width: 3,
                          height: height,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color:
                                (isMe
                                        ? chatVoiceMineColor
                                        : chatVoiceOtherColor)
                                    .withOpacity(i < 10 ? 0.8 : 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    Helpers.formatDuration(message.duration ?? 0),
                    style: TextStyle(
                      fontSize: 12,
                      color: _chatIsDark
                          ? Colors.white.withOpacity(0.85)
                          : AppTheme.lightText.withOpacity(0.9),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            buildTimeRow(message, isMe),
          ],
        ),
      ),
    );
  }

  Future<void> toggleVoiceBubblePlayback(MessageModel message) async {
    if (currentlyPlayingMessageId == message.id) {
      // Stop playback
      await voiceBubblePlayer.stop();
      voiceCompleteSub?.cancel();
      if (mounted) setState(() => currentlyPlayingMessageId = null);
      return;
    }
    // Stop any current playback
    await voiceBubblePlayer.stop();
    voiceCompleteSub?.cancel();
    if (message.fileUrl == null ||
        message.fileUrl!.isEmpty ||
        message.fileUrl == 'pending')
      return;
    setState(() => currentlyPlayingMessageId = message.id);
    try {
      // Download to local file first for reliable playback
      final localStorage = LocalStorageService();
      final dir = await localStorage.getAttachmentDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final fileName = 'voice_${message.id}.m4a';
      final localFile = File('${dir.path}/$fileName');

      String playPath;
      if (await localFile.exists()) {
        playPath = localFile.path;
      } else {
        // Download from Firebase Storage (on tap only)
        final ref = FirebaseStorage.instance.refFromURL(message.fileUrl!);
        await ref.writeToFile(localFile);
        playPath = localFile.path;
        // Track receipt and delete the server copy once all recipients have it
        final storageService = StorageService();
        await storageService.trackAttachmentDownload(
          chatEntityId,
          message.id,
          chatCurrentUserId,
          collection: chatMessagesCollection,
        );
        // Fire-and-forget server-side cleanup
        // ignore: unawaited_futures
        storageService.maybeDeleteServerAttachment(
          collection: chatMessagesCollection,
          entityId: chatEntityId,
          messageId: message.id,
          fileUrl: message.fileUrl!,
          senderId: message.senderId,
          participants: chatAllParticipants,
        );
      }

      await voiceBubblePlayer.play(DeviceFileSource(playPath));
      voiceCompleteSub = voiceBubblePlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() => currentlyPlayingMessageId = null);
        }
      });
    } catch (e) {
      print('[DetailChat] Voice playback error: $e');
      if (mounted) {
        setState(() => currentlyPlayingMessageId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not play voice message: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Play voice from local cache for pending uploads
  Future<void> toggleVoicePlaybackFromLocal(MessageModel message) async {
    if (currentlyPlayingMessageId == message.id) {
      await voiceBubblePlayer.stop();
      voiceCompleteSub?.cancel();
      if (mounted) setState(() => currentlyPlayingMessageId = null);
      return;
    }
    await voiceBubblePlayer.stop();
    voiceCompleteSub?.cancel();
    try {
      final localPath = await chatLocalPathFor(message);
      if (localPath == null || !File(localPath).existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Voice file not available locally'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      setState(() => currentlyPlayingMessageId = message.id);
      await voiceBubblePlayer.play(DeviceFileSource(localPath));
      voiceCompleteSub = voiceBubblePlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => currentlyPlayingMessageId = null);
      });
    } catch (e) {
      print('[DetailChat] Voice playback from local error: $e');
      if (mounted) {
        setState(() => currentlyPlayingMessageId = null);
      }
    }
  }

  // Shared bubble wrapper
  Widget wrapBubble({
    required bool isMe,
    required Widget child,
    EdgeInsets? padding,
  }) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: isMe ? 48 : 0,
          right: isMe ? 0 : 48,
        ),
        padding:
            padding ?? const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isMe
              ? (_chatIsDark ? chatAccentColor : chatMediaBubbleMineBg)
              : (_chatIsDark ? Theme.of(context).cardColor : Colors.white),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(8),
            topRight: const Radius.circular(8),
            bottomLeft: Radius.circular(isMe ? 8 : 0),
            bottomRight: Radius.circular(isMe ? 0 : 8),
          ),
          border: isMe ? null : _chatOtherBorder,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  Widget buildSenderNameLabel(String senderId) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        chatSenderLabel(senderId),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: _chatIsDark ? Colors.white70 : AppTheme.primaryText,
        ),
      ),
    );
  }

  Widget buildTimeRow(MessageModel message, bool isMe) {
    return GestureDetector(
      onLongPress: () => showFullTimestamp(message),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (message.isEdited) ...[
            Text(
              'edited',
              style: TextStyle(
                fontSize: 9,
                color: _chatIsDark
                    ? Colors.white54
                    : AppTheme.lightText.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(width: 3),
          ],
          Text(
            Helpers.formatTime(message.createdAt),
            style: TextStyle(
              fontSize: 11,
              color: _chatIsDark
                  ? Colors.white70
                  : AppTheme.lightText.withOpacity(0.8),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 3),
            buildMessageStatusIcon(message),
          ],
        ],
      ),
    );
  }

  // Show full timestamp on long-press
  void showFullTimestamp(MessageModel message) {
    final fullDate = DateFormat(
      'EEEE, MMMM d, yyyy \'at\' h:mm:ss a',
    ).format(message.createdAt);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.all(20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.access_time,
                  size: 20,
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 8),
                Text(
                  'Message Details',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              fullDate,
              style: const TextStyle(fontSize: 14, color: AppTheme.primaryText),
            ),
            if (message.isEdited) ...[
              const SizedBox(height: 8),
              Text(
                'Edited',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.secondaryText,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            // Delivery/read summary for own messages
            if (chatShowDeliverySummary &&
                message.senderId == chatCurrentUserId) ...[
              const SizedBox(height: 12),
              buildDeliverySummary(message),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // Show "Seen by" dialog with per-participant delivery/read status
  void showSeenByDialog(MessageModel message) {
    final participants = chatAllParticipants;
    // Exclude sender
    final otherParticipants = participants
        .where((p) => p != chatCurrentUserId)
        .toList();

    if (otherParticipants.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No other participants'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(
              Icons.visibility,
              size: 20,
              color: AppTheme.secondaryText,
            ),
            const SizedBox(width: 8),
            const Text(
              'Seen by',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final uid in otherParticipants) ...[
              buildSeenByRow(uid, message),
              const Divider(height: 1),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget buildSeenByRow(String uid, MessageModel message) {
    final name = chatUserNameById(uid);
    final readTime = message.readBy?[uid];
    final deliveredTime = message.deliveredTo?[uid];

    String statusText;
    IconData statusIcon;
    Color statusColor;

    if (readTime != null) {
      statusText = 'Read ${Helpers.formatTime(readTime)}';
      statusIcon = Icons.done_all;
      statusColor = Colors.blue;
    } else if (deliveredTime != null) {
      statusText = 'Delivered ${Helpers.formatTime(deliveredTime)}';
      statusIcon = Icons.done_all;
      statusColor = AppTheme.lightText;
    } else {
      statusText = 'Sent';
      statusIcon = Icons.check;
      statusColor = AppTheme.lightText;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppTheme.lightGrey,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 4),
          Text(statusText, style: TextStyle(fontSize: 12, color: statusColor)),
        ],
      ),
    );
  }

  // Build a compact delivery/read summary for the timestamp details dialog
  Widget buildDeliverySummary(MessageModel message) {
    final participants = chatAllParticipants;
    final others = participants.where((p) => p != chatCurrentUserId).toList();
    if (others.isEmpty) return const SizedBox.shrink();

    int readCount = 0;
    int deliveredCount = 0;
    for (final uid in others) {
      if (message.readBy?.containsKey(uid) == true) {
        readCount++;
        deliveredCount++; // read implies delivered
      } else if (message.deliveredTo?.containsKey(uid) == true) {
        deliveredCount++;
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (readCount > 0) ...[
          const Icon(Icons.done_all, size: 14, color: Colors.blue),
          const SizedBox(width: 3),
          Text(
            'Read by $readCount',
            style: const TextStyle(fontSize: 11, color: Colors.blue),
          ),
          const SizedBox(width: 8),
        ],
        if (deliveredCount > 0 && readCount == 0) ...[
          const Icon(Icons.done_all, size: 14, color: AppTheme.lightText),
          const SizedBox(width: 3),
          Text(
            'Delivered to $deliveredCount',
            style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
          ),
        ],
        if (deliveredCount == 0 && readCount == 0)
          Text(
            'Sent to ${others.length}',
            style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
          ),
      ],
    );
  }

  // WhatsApp-style message status icon (ticks)
  Widget buildMessageStatusIcon(MessageModel message) {
    // System messages don't need status icons
    if (message.senderId == 'system') return const SizedBox.shrink();

    // Build participants list from host screen data
    final participants = chatTickParticipants;
    final otherParticipants = participants
        .where((p) => p != chatCurrentUserId)
        .toList();

    // Check read status: any other participant has readBy entry
    final isRead =
        message.readBy != null &&
        otherParticipants.any((p) => message.readBy!.containsKey(p));

    // Check delivery status: any other participant has deliveredTo entry
    final isDelivered =
        message.deliveredTo != null &&
        otherParticipants.any((p) => message.deliveredTo!.containsKey(p));

    // WhatsApp-style icons:
    // - Single tick gray (sent): default
    // - Double tick gray (delivered): deliveredTo has entry
    // - Double tick blue (read): readBy has entry

    if (isRead) {
      // Blue double tick - message read
      return const Icon(Icons.done_all, size: 15, color: Colors.blue);
    } else if (isDelivered) {
      // Gray double tick - message delivered
      return const Icon(Icons.done_all, size: 15, color: AppTheme.lightText);
    } else {
      // Single tick - sent but not yet delivered
      return const Icon(Icons.check, size: 15, color: AppTheme.lightText);
    }
  }
}
