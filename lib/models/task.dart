import 'package:cloud_firestore/cloud_firestore.dart';
import 'task_participant.dart';
import 'milestone.dart';
import '../modules/shared/customer_info.dart';
import '../modules/shared/recurrence_rule.dart';

class TaskModel {
  final String id;
  final String title;
  final String description;
  final String createdBy; // UID of creator
  final String? createdByName; // Display name of creator (for cards)
  final String? createdByPhone; // Phone of creator (for phonebook lookup)
  final String assignedTo; // Name of assignee (for display)
  final String? assignedToUid; // UID of assignee (for Firebase queries)
  final String?
  assignedToPhone; // Phone of assignee (for matching & notifications)
  final List<String>
  participants; // All users in the task (like WhatsApp group members)
  final List<TaskParticipant>
  participantHistory; // Join/leave history for message visibility
  final bool isGroupTask; // true if multiple participants
  final int priority; // 1=Low, 2=Mid, 3=High
  final bool isUrgent;
  final DateTime? deadline;
  final double progress; // 0.0 to 1.0
  final List<String> tags;
  final Map<String, dynamic>? extraFields;
  final DateTime createdAt;
  final DateTime? startDate; // Nullable - null means use createdAt
  final DateTime updatedAt;
  final bool isClosed;
  final bool isCancelled; // true = cancelled, hidden from home cards
  final int? rating;
  final String? template;
  final int reminderCount;
  final int warningCount;
  final int statusRequestCount;
  final String? lastMessageText; // Snapshot updated on every message send
  final DateTime? lastMessageTime; // Snapshot updated on every message send
  final List<MilestoneModel> milestones; // Up to 5 milestones
  final Map<String, int>
  unreadCounts; // Per-user unread message count {userId: count}
  final int? displayId; // Sequential 4-digit ID shown to users
  final String? category; // User-defined category
  final bool isDeleted; // true = soft-deleted, hidden from normal views
  final DateTime? deletedAt; // Timestamp when task was deleted
  final String? deletedBy; // UID of user who deleted the task
  final String? teamId; // Creator's team this task belongs to (personal teams)
  final bool
  isArchived; // true = archived, hidden from normal views (never purged)
  final DateTime? archivedAt; // Timestamp when task was archived
  final String? archivedBy; // UID of user who archived the task

  // ── Customer / contact details (shared across modules via CustomerInfo) ──
  // Optional; blank for items with no customer. Exposed together as a single
  // [customerInfo] value object so shared widgets stay model-agnostic.
  final String? clientName;
  final String? clientPhone;
  final String? clientEmail;
  final String? clientAddress;
  final String? clientCompany;

  // ── Recurrence (Phase-2A) ───────────────────────────────────────────────
  // Compact JSON rule; non-null only on a series ANCHOR. Generated occurrences
  // carry [seriesId] but a null rule. [nextDue] is anchor-only and indexed so
  // the shared materializer can find due series cheaply. See RecurrenceRule.
  final String? recurrence;
  final String? seriesId;
  final DateTime? nextDue;

  TaskModel({
    required this.id,
    required this.title,
    required this.description,
    required this.createdBy,
    this.createdByName,
    this.createdByPhone,
    required this.assignedTo,
    this.assignedToUid,
    this.assignedToPhone,
    this.participants = const [],
    this.participantHistory = const [],
    this.isGroupTask = false,
    this.priority = 2,
    this.isUrgent = false,
    this.deadline,
    this.progress = 0.0,
    this.tags = const [],
    this.extraFields,
    required this.createdAt,
    this.startDate,
    required this.updatedAt,
    this.isClosed = false,
    this.isCancelled = false,
    this.rating,
    this.template,
    this.reminderCount = 0,
    this.warningCount = 0,
    this.statusRequestCount = 0,
    this.lastMessageText,
    this.lastMessageTime,
    this.milestones = const [],
    this.unreadCounts = const {},
    this.displayId,
    this.category,
    this.isDeleted = false,
    this.deletedAt,
    this.deletedBy,
    this.teamId,
    this.isArchived = false,
    this.archivedAt,
    this.archivedBy,
    this.clientName,
    this.clientPhone,
    this.clientEmail,
    this.clientAddress,
    this.clientCompany,
    this.recurrence,
    this.seriesId,
    this.nextDue,
  });

  // Create from Firestore document
  factory TaskModel.fromMap(Map<String, dynamic> map, String id) {
    return TaskModel(
      id: id,
      title: map['title'] ?? '',
      description: map['description'] ?? '',
      createdBy: map['createdBy'] ?? '',
      createdByName: map['createdByName'] as String?,
      createdByPhone: map['createdByPhone'] as String?,
      assignedTo: map['assignedTo'] ?? '',
      assignedToUid: map['assignedToUid'],
      assignedToPhone:
          map['assignedToPhone'] ??
          (map['extraFields'] as Map<String, dynamic>?)?['assigneePhone'],
      participants: List<String>.from(map['participants'] ?? []),
      participantHistory:
          (map['participantHistory'] as List?)
              ?.map(
                (p) => TaskParticipant.fromMap(Map<String, dynamic>.from(p)),
              )
              .toList() ??
          [],
      isGroupTask: map['isGroupTask'] ?? false,
      priority: map['priority'] ?? 2,
      isUrgent: map['isUrgent'] ?? false,
      deadline: (map['deadline'] as Timestamp?)?.toDate(),
      progress: (map['progress'] ?? 0.0).toDouble(),
      tags: List<String>.from(map['tags'] ?? []),
      extraFields: map['extraFields'] as Map<String, dynamic>?,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      startDate: (map['startDate'] as Timestamp?)?.toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isClosed: map['isClosed'] ?? false,
      isCancelled: map['isCancelled'] ?? false,
      rating: map['rating'],
      template: map['template'],
      reminderCount: map['reminderCount'] ?? 0,
      warningCount: map['warningCount'] ?? 0,
      statusRequestCount: map['statusRequestCount'] ?? 0,
      lastMessageText: map['lastMessageText'] as String?,
      lastMessageTime: (map['lastMessageTime'] as Timestamp?)?.toDate(),
      milestones:
          (map['milestones'] as List?)
              ?.map(
                (m) => MilestoneModel.fromMap(
                  Map<String, dynamic>.from(m),
                  m['id'] ?? '',
                ),
              )
              .toList() ??
          [],
      unreadCounts: map['unreadCounts'] != null
          ? Map<String, int>.from(map['unreadCounts'])
          : const {},
      displayId: map['displayId'],
      category: map['category'] as String?,
      isDeleted: map['isDeleted'] ?? false,
      deletedAt: (map['deletedAt'] as Timestamp?)?.toDate(),
      deletedBy: map['deletedBy'] as String?,
      teamId: map['teamId'] as String?,
      isArchived: map['isArchived'] ?? false,
      archivedAt: (map['archivedAt'] as Timestamp?)?.toDate(),
      archivedBy: map['archivedBy'] as String?,
      clientName: map['clientName'] as String?,
      clientPhone: map['clientPhone'] as String?,
      clientEmail: map['clientEmail'] as String?,
      clientAddress: map['clientAddress'] as String?,
      clientCompany: map['clientCompany'] as String?,
      recurrence: map['recurrence'] as String?,
      seriesId: map['seriesId'] as String?,
      nextDue: (map['nextDue'] as Timestamp?)?.toDate(),
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'id': id, // Store ID as field for consistency
      'title': title,
      'description': description,
      'createdBy': createdBy,
      'createdByName': createdByName,
      'createdByPhone': createdByPhone,
      'assignedTo': assignedTo,
      'assignedToUid': assignedToUid,
      'assignedToPhone': assignedToPhone,
      'participants': participants,
      'participantHistory': participantHistory.map((p) => p.toMap()).toList(),
      'isGroupTask': isGroupTask,
      'priority': priority,
      'isUrgent': isUrgent,
      'deadline': deadline?.toUtc(),
      'progress': progress,
      'tags': tags,
      'extraFields': extraFields,
      'createdAt': createdAt.toUtc(),
      'startDate': startDate?.toUtc(),
      'updatedAt': updatedAt.toUtc(),
      'isClosed': isClosed,
      'isCancelled': isCancelled,
      'rating': rating,
      'template': template,
      'reminderCount': reminderCount,
      'warningCount': warningCount,
      'statusRequestCount': statusRequestCount,
      'milestones': milestones.map((m) => m.toMap()).toList(),
      'unreadCounts': unreadCounts,
      'displayId': displayId,
      'category': category,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toUtc(),
      'deletedBy': deletedBy,
      'teamId': teamId,
      'isArchived': isArchived,
      'archivedAt': archivedAt?.toUtc(),
      'archivedBy': archivedBy,
      'clientName': clientName,
      'clientPhone': clientPhone,
      'clientEmail': clientEmail,
      'clientAddress': clientAddress,
      'clientCompany': clientCompany,
      'recurrence': recurrence,
      'seriesId': seriesId,
      'nextDue': nextDue?.toUtc(),
      // Note: lastMessageText/lastMessageTime are set via sendMessage update, not in toMap()
    };
  }

  // Copy with method for updates
  TaskModel copyWith({
    String? id,
    String? title,
    String? description,
    String? createdBy,
    String? createdByName,
    String? createdByPhone,
    String? assignedTo,
    String? assignedToUid,
    String? assignedToPhone,
    List<String>? participants,
    List<TaskParticipant>? participantHistory,
    bool? isGroupTask,
    int? priority,
    bool? isUrgent,
    DateTime? deadline,
    double? progress,
    List<String>? tags,
    Map<String, dynamic>? extraFields,
    DateTime? createdAt,
    DateTime? startDate,
    DateTime? updatedAt,
    bool? isClosed,
    bool? isCancelled,
    int? rating,
    String? template,
    int? reminderCount,
    int? warningCount,
    int? statusRequestCount,
    String? lastMessageText,
    DateTime? lastMessageTime,
    List<MilestoneModel>? milestones,
    Map<String, int>? unreadCounts,
    int? displayId,
    String? category,
    bool? isDeleted,
    DateTime? deletedAt,
    String? deletedBy,
    String? teamId,
    bool? isArchived,
    DateTime? archivedAt,
    String? archivedBy,
    String? clientName,
    String? clientPhone,
    String? clientEmail,
    String? clientAddress,
    String? clientCompany,
    String? recurrence,
    String? seriesId,
    DateTime? nextDue,
    // Nulls recurrence + seriesId + nextDue as a unit (copyWith's `?? this.x`
    // can't clear them otherwise). Used when a deadline edit picks "Does not
    // repeat", which ends the series.
    bool clearRecurrence = false,
    // Nulls assignedToPhone (copyWith's `?? this.x` can't clear a nullable
    // otherwise). Used when unassigning the last assignee: a stale phone would
    // keep the removed person a participant via the rules' phone match.
    bool clearAssigneePhone = false,
  }) {
    return TaskModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdByPhone: createdByPhone ?? this.createdByPhone,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToUid: assignedToUid ?? this.assignedToUid,
      assignedToPhone: clearAssigneePhone ? null : (assignedToPhone ?? this.assignedToPhone),
      participants: participants ?? this.participants,
      participantHistory: participantHistory ?? this.participantHistory,
      isGroupTask: isGroupTask ?? this.isGroupTask,
      priority: priority ?? this.priority,
      isUrgent: isUrgent ?? this.isUrgent,
      deadline: deadline ?? this.deadline,
      progress: progress ?? this.progress,
      tags: tags ?? this.tags,
      extraFields: extraFields ?? this.extraFields,
      createdAt: createdAt ?? this.createdAt,
      startDate: startDate ?? this.startDate,
      updatedAt: updatedAt ?? this.updatedAt,
      isClosed: isClosed ?? this.isClosed,
      isCancelled: isCancelled ?? this.isCancelled,
      rating: rating ?? this.rating,
      template: template ?? this.template,
      reminderCount: reminderCount ?? this.reminderCount,
      warningCount: warningCount ?? this.warningCount,
      statusRequestCount: statusRequestCount ?? this.statusRequestCount,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      milestones: milestones ?? this.milestones,
      unreadCounts: unreadCounts ?? this.unreadCounts,
      displayId: displayId ?? this.displayId,
      category: category ?? this.category,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedBy: deletedBy ?? this.deletedBy,
      teamId: teamId ?? this.teamId,
      isArchived: isArchived ?? this.isArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      archivedBy: archivedBy ?? this.archivedBy,
      clientName: clientName ?? this.clientName,
      clientPhone: clientPhone ?? this.clientPhone,
      clientEmail: clientEmail ?? this.clientEmail,
      clientAddress: clientAddress ?? this.clientAddress,
      clientCompany: clientCompany ?? this.clientCompany,
      recurrence: clearRecurrence ? null : (recurrence ?? this.recurrence),
      seriesId: clearRecurrence ? null : (seriesId ?? this.seriesId),
      nextDue: clearRecurrence ? null : (nextDue ?? this.nextDue),
    );
  }

  /// The effective recurrence rule, converging the new time-driven `recurrence`
  /// column with any LEGACY completion-driven rule still sitting in
  /// `extraFields` (Task-only, pre-Phase-2B). Null when the task does not
  /// repeat. Read-compat only — the deferred migration persists the column and
  /// strips the legacy key, after which this just parses `recurrence`.
  RecurrenceRule? get recurrenceRule {
    final direct = RecurrenceRule.tryParse(recurrence);
    if (direct != null) return direct;
    final legacy = extraFields?['recurrence'];
    if (legacy is Map && deadline != null) {
      return RecurrenceRule.fromLegacyMap(
        Map<String, dynamic>.from(legacy),
        anchor: deadline!,
      );
    }
    return null;
  }

  /// Customer/contact details as a shared, model-agnostic value object.
  /// Blank fields collapse to empty strings (see [CustomerInfo]).
  CustomerInfo get customerInfo => CustomerInfo(
    name: clientName ?? '',
    phone: clientPhone ?? '',
    email: clientEmail ?? '',
    address: clientAddress ?? '',
    company: clientCompany ?? '',
  );

  /// Return a copy with all customer fields replaced from [info] — the single
  /// write path used by the shared CustomerEditDialog across every module.
  TaskModel withCustomerInfo(CustomerInfo info) => copyWith(
    clientName: info.name,
    clientPhone: info.phone,
    clientEmail: info.email,
    clientAddress: info.address,
    clientCompany: info.company,
  );

  // Get priority label display (H/M/L)
  String get priorityLabel {
    switch (priority) {
      case 3:
        return 'H';
      case 2:
        return 'M';
      case 1:
      default:
        return 'L';
    }
  }

  // Check if deadline is nearing (within 2 days)
  bool get isDeadlineNearing {
    if (deadline == null) return false;
    final now = DateTime.now();
    final difference = deadline!.difference(now);
    return difference.inDays <= 2 && difference.inDays >= 0;
  }

  // Check if overdue
  bool get isOverdue {
    if (deadline == null) return false;
    return DateTime.now().isAfter(deadline!) && !isClosed;
  }

  // Get days until deadline
  int get daysUntilDeadline {
    if (deadline == null) return -1;
    return deadline!.difference(DateTime.now()).inDays;
  }

  int get completedMilestoneCount =>
      milestones.where((m) => m.isCompleted).length;

  // Get participant count (excluding creator)
  int get participantCount {
    final uniqueParticipants = participants.toSet();
    uniqueParticipants.remove(createdBy);
    return uniqueParticipants.length;
  }

  // Check if user is a participant
  bool isParticipant(String userId) {
    return participants.contains(userId) || createdBy == userId;
  }

  // Get display name for task (shows if it's a group)
  String get displayName {
    if (isGroupTask && participantCount > 1) {
      return '$assignedTo + ${participantCount - 1} other${participantCount > 2 ? 's' : ''}';
    }
    return assignedTo;
  }
}
