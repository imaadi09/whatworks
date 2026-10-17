import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';
import '../models/user.dart';
import '../utils/helpers.dart';

/// Service for sending notifications to users who are NOT on the WhatWorks app.
/// Falls back to SMS or WhatsApp when the assignee doesn't have the app installed.
class ExternalNotificationService {
  static final ExternalNotificationService _instance =
      ExternalNotificationService._internal();
  factory ExternalNotificationService() => _instance;
  ExternalNotificationService._internal();

  /// Delivery method used for the last notification
  String? lastDeliveryMethod;

  /// Check if the assignee is on the app
  bool isAssigneeOnApp(UserModel? assignee) {
    return assignee?.isOnApp ?? true;
  }

  /// Resolve a card's assignee into an [ExternalRecipient] using only the
  /// fields the card already persists — no team-list lookup.
  ///
  /// [isOnAppFlag] is the explicit value recorded when the assignee was picked
  /// (TaskModel `extraFields['assigneeIsOnApp']`). When a card never stored one,
  /// the app-wide convention applies: a resolved UID means the person is on the
  /// app (see task_detail_screen's `isOnApp: uid != null && uid.isNotEmpty`).
  ///
  /// Returns null when the card has no assignee at all.
  ExternalRecipient? resolveRecipient({
    required String assignedToName,
    String? assignedToUid,
    String? assignedToPhone,
    bool? isOnAppFlag,
  }) {
    final name = assignedToName.trim();
    if (name.isEmpty) return null;
    final isOnApp =
        isOnAppFlag ?? (assignedToUid != null && assignedToUid.trim().isNotEmpty);
    return ExternalRecipient(
      name: name,
      phone: assignedToPhone?.trim() ?? '',
      isOnApp: isOnApp,
    );
  }

  /// Get the assignee user from the team members list by phone number
  UserModel? getAssigneeUser(
    List<UserModel> teamMembers,
    String assignedToName, {
    String? assignedToPhone,
  }) {
    try {
      // Primary: Match by phone number (reliable, normalized)
      if (assignedToPhone != null && assignedToPhone.isNotEmpty) {
        final normalizedTarget = Helpers.normalizePhone(assignedToPhone) ?? assignedToPhone;
        return teamMembers.firstWhere((u) {
          final normalizedUser = Helpers.normalizePhone(u.phone) ?? u.phone;
          return normalizedUser == normalizedTarget;
        });
      }

      // Fallback: Match by name (less reliable, kept for backward compatibility)
      return teamMembers.firstWhere(
        (u) => u.name.toLowerCase() == assignedToName.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Format a task summary for external messages
  String formatTaskSummary(TaskModel task, String senderName) {
    final buffer = StringBuffer();
    buffer.writeln('📋 *WhatWorks Task Update*');
    buffer.writeln('');
    buffer.writeln('*Task:* ${task.title}');
    if (task.description.isNotEmpty) {
      buffer.writeln('*Details:* ${_truncate(task.description, 150)}');
    }
    buffer.writeln('*Assigned by:* $senderName');
    if (task.deadline != null) {
      buffer.writeln(
        '*Deadline:* ${Helpers.formatDeadlineBadge(task.deadline)}',
      );
    }
    buffer.writeln(
      '*Priority:* ${'★' * task.priority}${'☆' * (3 - task.priority)}',
    );
    if (task.isUrgent) {
      buffer.writeln('*Status:* 🔴 URGENT');
    }
    return buffer.toString().trimRight();
  }

  /// Format a reminder message for external delivery
  String formatReminderMessage(
    TaskModel task,
    String senderName,
    int reminderNumber,
  ) => formatReminderForTitle(
    cardTitle: task.title,
    senderName: senderName,
    reminderNumber: reminderNumber,
    // formatDeadlineBadge returns '' for a null deadline, which the generic
    // formatter already skips.
    deadlineLabel: Helpers.formatDeadlineBadge(task.deadline),
    progressPercent: (task.progress * 100).toInt(),
  );

  /// Format a warning message for external delivery
  String formatWarningMessage(
    TaskModel task,
    String senderName,
    int warningNumber,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('⚠️ *FORMAL WARNING #$warningNumber*');
    buffer.writeln('');
    buffer.writeln('*From:* $senderName');
    buffer.writeln('*Task:* ${task.title}');
    if (task.deadline != null) {
      buffer.writeln(
        '*Deadline:* ${Helpers.formatDeadlineBadge(task.deadline)}',
      );
    }
    buffer.writeln('*Progress:* ${(task.progress * 100).toInt()}%');
    buffer.writeln('');
    buffer.writeln('This is a formal warning regarding task performance.');
    buffer.writeln('Please take immediate action.');
    return buffer.toString();
  }

  /// Format a status request message for external delivery
  String formatStatusRequestMessage(
    TaskModel task,
    String senderName,
    int requestNumber,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('📋 *STATUS REPORT REQUESTED #$requestNumber*');
    buffer.writeln('');
    buffer.writeln('*From:* $senderName');
    buffer.writeln('*Task:* ${task.title}');
    if (task.deadline != null) {
      buffer.writeln(
        '*Deadline:* ${Helpers.formatDeadlineBadge(task.deadline)}',
      );
    }
    buffer.writeln('*Current Progress:* ${(task.progress * 100).toInt()}%');
    buffer.writeln('');
    buffer.writeln('Please provide a detailed status update on this task.');
    return buffer.toString();
  }

  /// Format a text message for external delivery
  String formatTextMessage(
    TaskModel task,
    String senderName,
    String messageText,
  ) => formatTextMessageForTitle(task.title, senderName, messageText);

  /// Module-agnostic twin of [formatTextMessage]: Task, Sales and CRM all keep
  /// a differently-typed card model but the same "who is this about" line.
  String formatTextMessageForTitle(
    String cardTitle,
    String senderName,
    String messageText,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('💬 *Message from $senderName*');
    buffer.writeln('*Regarding:* $cardTitle');
    buffer.writeln('');
    buffer.writeln(messageText);
    return buffer.toString();
  }

  /// Module-agnostic twin of [formatReminderMessage]. [deadlineLabel] and
  /// [progressPercent] are optional because only the Task card tracks progress.
  String formatReminderForTitle({
    required String cardTitle,
    required String senderName,
    required int reminderNumber,
    String? deadlineLabel,
    int? progressPercent,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('⏰ *REMINDER #$reminderNumber*');
    buffer.writeln('');
    buffer.writeln('*From:* $senderName');
    buffer.writeln('*Task:* $cardTitle');
    if (deadlineLabel != null && deadlineLabel.isNotEmpty) {
      buffer.writeln('*Deadline:* $deadlineLabel');
    }
    if (progressPercent != null) {
      buffer.writeln('*Progress:* $progressPercent%');
    }
    buffer.writeln('');
    buffer.writeln('Please update your progress on this task.');
    return buffer.toString();
  }

  /// Send notification via SMS (using device SMS app)
  Future<bool> sendSMS(String phone, String message) async {
    final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(message)}');
    try {
      final launched = await launchUrl(uri);
      lastDeliveryMethod = launched ? 'SMS' : null;
      return launched;
    } catch (e) {
      lastDeliveryMethod = null;
      return false;
    }
  }

  /// Send notification via WhatsApp (using WhatsApp deep link)
  Future<bool> sendWhatsApp(String phone, String message) async {
    // Format phone number - add country code if not present
    String formattedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (!formattedPhone.startsWith('91') && formattedPhone.length == 10) {
      formattedPhone = '91$formattedPhone'; // Default to India country code
    }

    final uri = Uri.parse(
      'https://wa.me/$formattedPhone?text=${Uri.encodeComponent(message)}',
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      lastDeliveryMethod = launched ? 'WhatsApp' : null;
      return launched;
    } catch (e) {
      lastDeliveryMethod = null;
      return false;
    }
  }

  /// Send notification via preferred method (WhatsApp first, then SMS fallback)
  Future<DeliveryResult> sendExternalNotification({
    required UserModel assignee,
    required String message,
    NotificationType type = NotificationType.message,
    bool preferWhatsApp = true,
  }) async {
    final phone = assignee.phone;
    if (phone.isEmpty) {
      return DeliveryResult(
        success: false,
        method: DeliveryMethod.none,
        reason: 'No phone number available for ${assignee.name}',
      );
    }

    // Try WhatsApp first (preferred for Indian SMB teams)
    if (preferWhatsApp) {
      final whatsappSuccess = await sendWhatsApp(phone, message);
      if (whatsappSuccess) {
        return DeliveryResult(
          success: true,
          method: DeliveryMethod.whatsapp,
          reason: 'Sent via WhatsApp to ${assignee.name} ($phone)',
        );
      }
    }

    // Fallback to SMS
    final smsSuccess = await sendSMS(phone, message);
    if (smsSuccess) {
      return DeliveryResult(
        success: true,
        method: DeliveryMethod.sms,
        reason: 'Sent via SMS to ${assignee.name} ($phone)',
      );
    }

    // Neither worked
    return DeliveryResult(
      success: false,
      method: DeliveryMethod.none,
      reason: 'Could not send to ${assignee.name}. Please check phone number.',
    );
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}

/// Model-agnostic description of whoever a card is assigned to.
///
/// Task, Sales and CRM each persist the assignee differently (TaskModel keeps
/// `assignedTo` + `extraFields['assigneePhone']` + `extraFields['assigneeIsOnApp']`,
/// EnquiryModel has first-class `assignedTo` / `assignedToPhone` / `assignedToUid`),
/// but the "reachable in-app, or do we need WhatsApp/SMS" decision is identical.
/// This is that decision in one place, built by
/// [ExternalNotificationService.resolveRecipient].
class ExternalRecipient {
  final String name;
  final String phone;
  final bool isOnApp;

  const ExternalRecipient({
    required this.name,
    required this.phone,
    this.isOnApp = true,
  });

  /// True when an out-of-app nudge is both needed and actually possible —
  /// a person who is not on the app but has no stored phone number can only
  /// be reached in-app (i.e. not at all), so the chooser must not be offered.
  bool get needsExternalNudge => !isOnApp && phone.isNotEmpty;
}

/// Type of notification being sent
enum NotificationType {
  message,
  reminder,
  warning,
  statusRequest,
  taskAssignment,
}

/// Delivery method used
enum DeliveryMethod { whatsapp, sms, inApp, none }

/// Result of a notification delivery attempt
class DeliveryResult {
  final bool success;
  final DeliveryMethod method;
  final String reason;

  DeliveryResult({
    required this.success,
    required this.method,
    required this.reason,
  });

  /// Get a user-friendly icon for the delivery method
  String get methodIcon {
    switch (method) {
      case DeliveryMethod.whatsapp:
        return '📱 WhatsApp';
      case DeliveryMethod.sms:
        return '💬 SMS';
      case DeliveryMethod.inApp:
        return '🔔 In-App';
      case DeliveryMethod.none:
        return '❌ Failed';
    }
  }
}
