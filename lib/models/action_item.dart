import 'package:flutter/material.dart';

// ⚠️ Task-module enum. It carries the actions the Task chat can raise —
// including the dated commitments call / meeting / siteVisit (surfaced on the
// Actions tab since the Needs Attention / Overdue filters must be able to list
// them). Other sales-cycle actions (quotation, payment, sample, negotiation,
// won, lost) are NOT represented here; they use string keys via
// ModuleConfig/Helpers.detectActionType. The typeColor/typeIcon/typeLabel
// getters below are legacy fallbacks — card strips and log rows use
// CardActionIcons.visualFor and Helpers.detectLastAction as visual sources of
// truth, so keep those in sync rather than these getters.
enum ActionType {
  reminder,
  followUp,
  warning,
  query,
  blocker,
  approval,
  extension,
  progressReport,
  cash,
  // Dated commitments the Task chat can raise (📞/🤝/🛠️). Widened in so they
  // surface under the Actions-tab Needs Attention / Overdue filters instead of
  // being dropped by the loader's `default: continue`.
  call,
  meeting,
  siteVisit,
}

/// Canonical actions-table key for the shared pending predicate
/// ([Helpers.isActionPending]). The Task enum names do not all match the
/// string keys the actions table stores (e.g. [ActionType.followUp] is
/// stored as `followup`), so normalize through this getter instead of
/// re-hard-coding the mapping at every Actions-tab call site.
extension ActionTypeKey on ActionType {
  String get key => switch (this) {
    ActionType.reminder => 'reminder',
    ActionType.followUp => 'followup',
    ActionType.warning => 'warning',
    ActionType.query => 'query',
    ActionType.blocker => 'blocker',
    ActionType.approval => 'approval',
    ActionType.extension => 'extension',
    ActionType.progressReport => 'progress',
    ActionType.cash => 'cash',
    ActionType.call => 'call',
    ActionType.meeting => 'meeting',
    ActionType.siteVisit => 'sitevisit',
  };
}

class ActionItem {
  final String id;
  final String taskId;
  final String taskTitle;
  final ActionType type;
  final String message;
  final DateTime scheduledDate;

  /// Whether [scheduledDate] is a genuine committed/scheduled date or just the
  /// message write date (loaders fall back to `createdAt` when the actions row
  /// carries no `scheduledDate`). Overdue only ever means "past a real
  /// scheduled date", so it must never fire on undated actions that merely age
  /// on their write date. Defaults true for legacy/Firestore-mapped items.
  final bool hasScheduledDate;
  final DateTime createdAt;
  final String createdBy;
  final String assignedTo;
  final bool isCompleted;
  final DateTime? completedAt;
  final String? messageId;

  // Query-specific fields
  final bool isReplied;
  final String? queryReply;

  // Follow-up specific fields
  final bool isFollowUpDone;

  /// The occurrence number baked onto the originating message at send time
  /// (`MessageModel.sequenceNumber`, mirrored onto the SQLite actions index).
  /// The Actions tabs prefer this over their recomputed family counter so the
  /// shown `#N` matches the chat card and stays stable under filtering. Null
  /// for legacy/Firestore-mapped items, where the recomputed counter is used.
  final int? seqNo;

  ActionItem({
    required this.id,
    required this.taskId,
    required this.taskTitle,
    required this.type,
    required this.message,
    required this.scheduledDate,
    this.hasScheduledDate = true,
    required this.createdAt,
    required this.createdBy,
    required this.assignedTo,
    this.isCompleted = false,
    this.completedAt,
    this.messageId,
    this.isReplied = false,
    this.queryReply,
    this.isFollowUpDone = false,
    this.seqNo,
  });

  // Get color based on action type
  Color get typeColor {
    switch (type) {
      case ActionType.reminder:
        return const Color(0xFFF59F00); // Orange
      case ActionType.followUp:
        return const Color(0xFF1976D2); // Blue
      case ActionType.warning:
        return const Color(0xFFE03131); // Red
      case ActionType.query:
        return const Color(0xFF2F9E44); // Green
      case ActionType.blocker:
        return const Color(0xFFC92A2A); // Dark red
      case ActionType.approval:
        return const Color(0xFF0B7285); // Teal
      case ActionType.extension:
        return const Color(0xFF3B5BDB); // Indigo
      case ActionType.progressReport:
        return const Color(0xFF7048E8); // Purple
      case ActionType.cash:
        return const Color(0xFF099268); // Teal green
      case ActionType.call:
        return const Color(0xFF0C8599); // Cyan
      case ActionType.meeting:
        return const Color(0xFF3B5BDB); // Indigo
      case ActionType.siteVisit:
        return const Color(0xFF1098AD); // Teal cyan
    }
  }

  // Get icon based on action type
  IconData get typeIcon {
    switch (type) {
      case ActionType.reminder:
        return Icons.notifications_active;
      case ActionType.followUp:
        return Icons.calendar_today;
      case ActionType.warning:
        return Icons.warning_amber_rounded;
      case ActionType.query:
        return Icons.summarize;
      case ActionType.blocker:
        return Icons.block;
      case ActionType.approval:
        return Icons.fact_check;
      case ActionType.extension:
        return Icons.more_time;
      case ActionType.progressReport:
        return Icons.trending_up;
      case ActionType.cash:
        return Icons.account_balance_wallet;
      case ActionType.call:
        return Icons.call;
      case ActionType.meeting:
        return Icons.groups;
      case ActionType.siteVisit:
        return Icons.handyman;
    }
  }

  // Get type label
  String get typeLabel {
    switch (type) {
      case ActionType.reminder:
        return 'Reminder';
      case ActionType.followUp:
        return 'Follow-up';
      case ActionType.warning:
        return 'Warning';
      case ActionType.query:
        return 'Query';
      case ActionType.blocker:
        return 'Blocker';
      case ActionType.approval:
        return 'Approval';
      case ActionType.extension:
        return 'Extension';
      case ActionType.progressReport:
        return 'Progress';
      case ActionType.cash:
        return 'Cash';
      case ActionType.call:
        return 'Call';
      case ActionType.meeting:
        return 'Meeting';
      case ActionType.siteVisit:
        return 'Visit';
    }
  }

  // Is this task assigned to me?
  bool get isToMe => assignedTo == createdBy ? false : true;

  // Convert to Map for Firestore
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'taskId': taskId,
      'taskTitle': taskTitle,
      'type': type.name,
      'message': message,
      'scheduledDate': scheduledDate.toIso8601String(),
      'hasScheduledDate': hasScheduledDate,
      'createdAt': createdAt.toIso8601String(),
      'createdBy': createdBy,
      'assignedTo': assignedTo,
      'isCompleted': isCompleted,
      'completedAt': completedAt?.toIso8601String(),
      'messageId': messageId,
      'isReplied': isReplied,
      'queryReply': queryReply,
      'isFollowUpDone': isFollowUpDone,
    };
  }

  // Create from Map (Firestore)
  factory ActionItem.fromMap(Map<String, dynamic> map) {
    return ActionItem(
      id: map['id'] as String,
      taskId: map['taskId'] as String,
      taskTitle: map['taskTitle'] as String,
      type: ActionType.values.byName(map['type'] as String),
      message: map['message'] as String,
      scheduledDate: DateTime.parse(map['scheduledDate'] as String),
      hasScheduledDate: map['hasScheduledDate'] as bool? ?? true,
      createdAt: DateTime.parse(map['createdAt'] as String),
      createdBy: map['createdBy'] as String,
      assignedTo: map['assignedTo'] as String,
      isCompleted: map['isCompleted'] as bool? ?? false,
      completedAt: map['completedAt'] != null
          ? DateTime.parse(map['completedAt'] as String)
          : null,
      messageId: map['messageId'] as String?,
      isReplied: map['isReplied'] as bool? ?? false,
      queryReply: map['queryReply'] as String?,
      isFollowUpDone: map['isFollowUpDone'] as bool? ?? false,
    );
  }
}
