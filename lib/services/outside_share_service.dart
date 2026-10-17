import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../utils/app_links.dart';
import '../widgets/outside_share_card.dart';
import 'external_notification_service.dart';

/// One chat entry inside an outside share, already flattened to plain text so
/// neither the composer nor the card widget has to know about MessageModel.
class ShareEntry {
  final String senderName;
  final String timeLabel;
  final String text;

  const ShareEntry({
    required this.senderName,
    required this.timeLabel,
    required this.text,
  });

  /// Long posts are pointless in a WhatsApp/SMS body — cap them here so every
  /// caller gets the same truncation for free.
  factory ShareEntry.of({
    required String senderName,
    required String timeLabel,
    required String text,
  }) {
    final trimmed = text.trim();
    return ShareEntry(
      senderName: senderName,
      timeLabel: timeLabel,
      text: trimmed.length <= maxEntryChars
          ? trimmed
          : '${trimmed.substring(0, maxEntryChars)}…',
    );
  }

  static const int maxEntryChars = 300;
}

/// Everything the composer and the card need about the item being shared.
///
/// Built by each detail screen from its own model (TaskModel / EnquiryModel),
/// which is what keeps Task, Sales and CRM output identical.
class OutsideSharePayload {
  /// `'Task'`, `'Enquiry'` or `'Ticket'` — the module's item name.
  final String itemLabel;
  final String title;
  final int? displayId;

  /// Creator / assignee display names, e.g. "From: Rahul  To: Meera".
  final String byName;
  final String toName;

  /// Already-formatted deadline badge (`Helpers.formatDeadlineBadge`).
  final String? deadlineLabel;

  /// Already-formatted status summary, e.g. `'Active · Progress 40%'`.
  final String? statusLine;

  /// Oldest → newest.
  final List<ShareEntry> entries;

  /// Who the share is addressed to (pre-filled with the assignee, changeable).
  final String recipientName;
  final String? recipientPhone;

  /// Current user's phone, used for the `Reply to <by>` deep link.
  final String? replyPhone;

  final Color themeColor;

  const OutsideSharePayload({
    required this.itemLabel,
    required this.title,
    this.displayId,
    required this.byName,
    required this.toName,
    this.deadlineLabel,
    this.statusLine,
    required this.entries,
    required this.recipientName,
    this.recipientPhone,
    this.replyPhone,
    required this.themeColor,
  });

  String get idLabel => displayId != null ? '  (#$displayId)' : '';
}

/// Outcome of one send attempt. The sheet returns `null` when the user backed
/// out without sending, so [channel] is always a real channel here.
class OutsideShareResult {
  /// `'whatsapp' | 'sms' | 'apps'`.
  final String channel;
  final String recipientName;
  final String? recipientPhone;
  final int postCount;

  /// False when the channel could not be opened (app not installed, share sheet
  /// dismissed). The caller shows a red SnackBar and skips the chat log.
  final bool success;

  const OutsideShareResult({
    required this.channel,
    required this.recipientName,
    required this.recipientPhone,
    required this.postCount,
    required this.success,
  });

  /// Human label used in both the SnackBar and the 📤 system message.
  String get channelLabel => switch (channel) {
    'whatsapp' => 'WhatsApp',
    'sms' => 'SMS',
    _ => 'More apps',
  };
}

/// Shares chat posts + item details with people who are NOT on WhatWorks.
///
/// Three jobs, all shared between modules:
///  1. [composeText] — WhatsApp-friendly `*bold*` summary of the item + posts.
///  2. [captureCardImage] — renders [OutsideShareCard] off-screen to a PNG.
///  3. Send wrappers — thin delegates over the existing WhatsApp/SMS deep links
///     and the system share sheet, so number normalisation stays in one place.
class OutsideShareService {
  static final OutsideShareService _instance = OutsideShareService._internal();
  factory OutsideShareService() => _instance;
  OutsideShareService._internal();

  /// Plain-text summary. Every optional line is dropped when empty so the body
  /// never shows `*Deadline:* —` noise.
  String composeText(OutsideSharePayload payload) {
    final b = StringBuffer();
    b.writeln('📋 *WhatWorks — ${payload.itemLabel} Update*');
    b.writeln();
    b.writeln(
      '*${payload.itemLabel}:* ${payload.title.isEmpty ? 'Untitled' : payload.title}'
      '${payload.idLabel}',
    );

    final people = <String>[];
    if (payload.byName.trim().isNotEmpty) people.add('*From:* ${payload.byName}');
    if (payload.toName.trim().isNotEmpty) people.add('*To:* ${payload.toName}');
    if (people.isNotEmpty) b.writeln(people.join('    '));

    final deadline = payload.deadlineLabel?.trim() ?? '';
    if (deadline.isNotEmpty) b.writeln('*Deadline:* $deadline');

    final status = payload.statusLine?.trim() ?? '';
    if (status.isNotEmpty) b.writeln('*Status:* $status');

    for (final entry in payload.entries) {
      b.writeln();
      b.writeln('—— ${entry.senderName}, ${entry.timeLabel} ——');
      b.writeln(entry.text);
    }

    b.writeln();
    final replyTo = payload.replyPhone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    if (replyTo.isNotEmpty) {
      b.writeln(
        '*Reply to ${payload.byName.trim().isEmpty ? 'us' : payload.byName}:* '
        'https://wa.me/$replyTo',
      );
    }
    b.write('Get WhatWorks: ${AppLinks.invite}');
    return b.toString();
  }

  /// Short caption that rides along with the image card (the card itself carries
  /// the full detail block, so repeating all of it would be noise).
  String composeCaption(OutsideSharePayload payload) {
    final b = StringBuffer();
    b.writeln('📋 *WhatWorks — ${payload.itemLabel} Update*');
    b.writeln(
      '*${payload.itemLabel}:* ${payload.title.isEmpty ? 'Untitled' : payload.title}'
      '${payload.idLabel}',
    );
    b.write('Get WhatWorks: ${AppLinks.invite}');
    return b.toString();
  }

  /// Renders [OutsideShareCard] to a PNG at 2x and returns the temp file.
  ///
  /// The card is parked off-screen inside an Overlay entry rather than hidden:
  /// `Visibility(visible: false)` never paints, and an unpainted boundary has no
  /// layer for `toImage` to rasterise. Returns null on any failure — the caller
  /// shows the same red SnackBar as the screenshot path.
  Future<File?> captureCardImage(
    BuildContext context,
    OutsideSharePayload payload, {
    String? appVersion,
  }) async {
    OverlayEntry? entry;
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      final cardKey = GlobalKey();
      entry = OverlayEntry(
        builder: (_) => Positioned(
          left: -4000,
          top: 0,
          child: RepaintBoundary(
            key: cardKey,
            child: OutsideShareCard(payload: payload, appVersion: appVersion),
          ),
        ),
      );
      overlay.insert(entry);

      // Two frames: the first lays out, the second guarantees the boundary's
      // layer exists before it is rasterised.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;

      final boundary =
          cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/ww_share_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(byteData.buffer.asUint8List());
      return file;
    } catch (e) {
      debugPrint('[OutsideShare] captureCardImage failed: $e');
      return null;
    } finally {
      entry?.remove();
    }
  }

  /// WhatsApp deep link. `wa.me` cannot pre-attach a file, which is why the
  /// image format always goes through the system sheet instead.
  Future<bool> sendWhatsApp(String phone, String text) =>
      ExternalNotificationService().sendWhatsApp(phone, text);

  /// Device SMS app with the body prefilled.
  Future<bool> sendSMS(String phone, String text) =>
      ExternalNotificationService().sendSMS(phone, text);

  /// System share sheet with the rendered card attached (WhatsApp / SMS / any
  /// other app the user has). Returns false when the sheet was dismissed.
  Future<bool> shareImage(File file, String caption) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: caption),
      );
      return result.status != ShareResultStatus.dismissed;
    } catch (e) {
      debugPrint('[OutsideShare] shareImage failed: $e');
      return false;
    }
  }

  /// System share sheet with text only — the "More apps" channel.
  Future<bool> shareText(String text) async {
    try {
      final result = await SharePlus.instance.share(ShareParams(text: text));
      return result.status != ShareResultStatus.dismissed;
    } catch (e) {
      debugPrint('[OutsideShare] shareText failed: $e');
      return false;
    }
  }

  /// `📤 Shared via …` chat-log line, shared by every module so the wording can
  /// never drift between Task, Sales and CRM. Starts with 📤 which
  /// `Helpers.detectActionType` deliberately does not match — it renders as a
  /// generic neutral System card, no action-catalog change needed.
  String systemMessageFor({
    required OutsideShareResult result,
    required String byName,
    required String atLabel,
  }) {
    final phone = result.recipientPhone?.trim() ?? '';
    final who = phone.isEmpty
        ? result.recipientName
        : '${result.recipientName} ($phone)';
    final posts = result.postCount == 1 ? '1 post' : 'last ${result.postCount} posts';
    return '📤 Shared via ${result.channelLabel} with $who — $posts by $byName at $atLabel';
  }
}
