// ignore_for_file: annotate_overrides
// EnquiryModel satisfies the read-only WorkItem contract through its existing
// fields; per-field @override annotations are omitted to keep the data model
// legible (the override relationship is real and verified by the analyzer).
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../models/milestone.dart';
import '../../shared/work_item.dart';
import '../../shared/customer_info.dart';
import '../../shared/recurrence_rule.dart';

export '../../../models/milestone.dart';

/// Sales pipeline stages - preset and ordered.
/// Kept as string constants for backward compatibility.
class SalesStatus {
  static const String active = 'active';
  static const String quotation = 'quotation';
  static const String demo = 'demo';
  static const String negotiation = 'negotiation';
  static const String success = 'success';
  static const String lost = 'lost';
  static const String dropped = 'dropped';
  static const String cancel = 'cancel';

  /// All sales-specific status values, in pipeline order.
  static const List<String> values = [
    active,
    quotation,
    demo,
    negotiation,
    success,
    lost,
    dropped,
    cancel,
  ];

  SalesStatus._(); // prevent instantiation
}

/// Sales enquiry model — independent from TaskModel.
/// Stored in `sales_enquiries` Firestore collection.
class EnquiryModel implements WorkItem {
  final String id;
  final String title;
  final String clientName;
  final String description;
  final String createdBy;
  final String? createdByName;
  final String? createdByPhone;
  final String assignedTo;
  final String? assignedToUid;
  final String? assignedToPhone;

  /// UIDs that can see/sync this enquiry. Invariant: always a superset of
  /// {createdBy} ∪ {assigneeUids} — enforced locally by
  /// `LocalDatabaseService.enquiryToRow` via `participantsUnion`. Drives the
  /// cross-device sync query `where('participants', arrayContains: uid)` and
  /// chat membership. Mirrors `TaskModel.participants`.
  final List<String> participants;
  final String status;
  final List<MilestoneModel> milestones;
  final int priority; // 1=Low, 2=Mid, 3=High
  final bool isUrgent; // Urgency flag (like Task Detail)
  final DateTime? deadline;
  final double progress;
  final List<String> tags;
  final Map<String, dynamic>? extraFields;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isClosed;
  final String? lastMessageText;
  final DateTime? lastMessageTime;
  final Map<String, int> unreadCounts;
  final String? teamId;
  final int? displayId; // Sequential 4-digit ID shown to users
  final int? rating; // 1-5 star closure rating
  final String? clientPhone;
  final String? clientEmail;
  final String? clientAddress;
  final String? clientCompany;
  final String? category; // User-defined category
  final bool
  isArchived; // true = archived, hidden from normal views (never purged)
  final DateTime? archivedAt; // Timestamp when enquiry was archived
  final String? archivedBy; // UID of user who archived the enquiry
  final bool
  isDeleted; // true = soft-deleted, visible only in the Deleted view
  final DateTime? deletedAt; // Timestamp when enquiry was deleted
  final String? deletedBy; // UID of user who deleted the enquiry

  // ── Recurrence (Phase-2A) ───────────────────────────────────────────────
  // Compact JSON rule; non-null only on a series ANCHOR. Generated occurrences
  // carry [seriesId] but a null rule. [nextDue] is anchor-only and indexed so
  // the shared materializer can find due series cheaply. See RecurrenceRule.
  final String? recurrence;
  final String? seriesId;
  final DateTime? nextDue;

  EnquiryModel({
    required this.id,
    this.title = '',
    required this.clientName,
    this.description = '',
    required this.createdBy,
    this.createdByName,
    this.createdByPhone,
    required this.assignedTo,
    this.assignedToUid,
    this.assignedToPhone,
    this.participants = const [],
    this.status = 'active',
    this.milestones = const [],
    this.priority = 2,
    this.isUrgent = false,
    this.deadline,
    this.progress = 0.0,
    this.tags = const [],
    this.extraFields,
    required this.createdAt,
    required this.updatedAt,
    this.isClosed = false,
    this.lastMessageText,
    this.lastMessageTime,
    this.unreadCounts = const {},
    this.teamId,
    this.displayId,
    this.rating,
    this.clientPhone,
    this.clientEmail,
    this.clientAddress,
    this.clientCompany,
    this.category,
    this.isArchived = false,
    this.archivedAt,
    this.archivedBy,
    this.isDeleted = false,
    this.deletedAt,
    this.deletedBy,
    this.recurrence,
    this.seriesId,
    this.nextDue,
  });

  factory EnquiryModel.fromMap(Map<String, dynamic> map, String id) {
    return EnquiryModel(
      id: id,
      title: map['title'] ?? '',
      clientName: map['clientName'] ?? '',
      description: map['description'] ?? '',
      createdBy: map['createdBy'] ?? '',
      createdByName: map['createdByName'] as String?,
      createdByPhone: map['createdByPhone'] as String?,
      assignedTo: map['assignedTo'] ?? '',
      assignedToUid: map['assignedToUid'],
      assignedToPhone: map['assignedToPhone'],
      participants: List<String>.from(map['participants'] ?? []),
      status: (map['status'] as String?) ?? 'active',
      milestones: MilestoneModel.dedupeById(
        (map['milestones'] as List?)?.asMap().entries.map((entry) {
          final m = entry.value;
          final mMap = Map<String, dynamic>.from(m);
          final mId = (m['id'] != null && (m['id'] as String).isNotEmpty)
              ? m['id'] as String
              : 'milestone_${m['order'] ?? entry.key}';
          return MilestoneModel.fromMap(mMap, mId);
        }).toList() ??
        [],
      ),
      priority: map['priority'] ?? 2,
      isUrgent: map['isUrgent'] ?? false,
      deadline: (map['deadline'] as Timestamp?)?.toDate(),
      progress: (map['progress'] ?? 0.0).toDouble(),
      tags: List<String>.from(map['tags'] ?? []),
      extraFields: map['extraFields'] as Map<String, dynamic>?,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isClosed: map['isClosed'] ?? false,
      lastMessageText: map['lastMessageText'] as String?,
      lastMessageTime: (map['lastMessageTime'] as Timestamp?)?.toDate(),
      unreadCounts: map['unreadCounts'] != null
          ? Map<String, int>.from(map['unreadCounts'])
          : const {},
      teamId: map['teamId'] as String?,
      displayId: map['displayId'],
      rating: map['rating'] as int?,
      clientPhone: map['clientPhone'] as String?,
      clientEmail: map['clientEmail'] as String?,
      clientAddress: map['clientAddress'] as String?,
      clientCompany: map['clientCompany'] as String?,
      category: map['category'] as String?,
      isArchived: map['isArchived'] ?? false,
      archivedAt: (map['archivedAt'] as Timestamp?)?.toDate(),
      archivedBy: map['archivedBy'] as String?,
      isDeleted: map['isDeleted'] ?? false,
      deletedAt: (map['deletedAt'] as Timestamp?)?.toDate(),
      deletedBy: map['deletedBy'] as String?,
      recurrence: map['recurrence'] as String?,
      seriesId: map['seriesId'] as String?,
      nextDue: (map['nextDue'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'clientName': clientName,
      'description': description,
      'createdBy': createdBy,
      'createdByName': createdByName,
      'createdByPhone': createdByPhone,
      'assignedTo': assignedTo,
      'assignedToUid': assignedToUid,
      'assignedToPhone': assignedToPhone,
      'participants': participants,
      'status': status,
      'milestones': milestones.map((m) => m.toMap()).toList(),
      'priority': priority,
      'isUrgent': isUrgent,
      'deadline': deadline?.toUtc(),
      'progress': progress,
      'tags': tags,
      'extraFields': extraFields,
      'createdAt': createdAt.toUtc(),
      'updatedAt': updatedAt.toUtc(),
      'isClosed': isClosed,
      'unreadCounts': unreadCounts,
      'teamId': teamId,
      'displayId': displayId,
      'rating': rating,
      'clientPhone': clientPhone,
      'clientEmail': clientEmail,
      'clientAddress': clientAddress,
      'clientCompany': clientCompany,
      'category': category,
      'isArchived': isArchived,
      'archivedAt': archivedAt?.toUtc(),
      'archivedBy': archivedBy,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toUtc(),
      'deletedBy': deletedBy,
      'recurrence': recurrence,
      'seriesId': seriesId,
      'nextDue': nextDue?.toUtc(),
    };
  }

  EnquiryModel copyWith({
    String? id,
    String? title,
    String? clientName,
    String? description,
    String? createdBy,
    String? createdByName,
    String? createdByPhone,
    String? assignedTo,
    String? assignedToUid,
    String? assignedToPhone,
    List<String>? participants,
    String? status,
    List<MilestoneModel>? milestones,
    int? priority,
    bool? isUrgent,
    DateTime? deadline,
    double? progress,
    List<String>? tags,
    Map<String, dynamic>? extraFields,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isClosed,
    String? lastMessageText,
    DateTime? lastMessageTime,
    Map<String, int>? unreadCounts,
    String? teamId,
    int? displayId,
    int? rating,
    String? clientPhone,
    String? clientEmail,
    String? clientAddress,
    String? clientCompany,
    String? category,
    bool? isArchived,
    DateTime? archivedAt,
    String? archivedBy,
    bool? isDeleted,
    DateTime? deletedAt,
    String? deletedBy,
    String? recurrence,
    String? seriesId,
    DateTime? nextDue,
    bool clearRecurrence = false,
  }) {
    return EnquiryModel(
      id: id ?? this.id,
      title: title ?? this.title,
      clientName: clientName ?? this.clientName,
      description: description ?? this.description,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdByPhone: createdByPhone ?? this.createdByPhone,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToUid: assignedToUid ?? this.assignedToUid,
      assignedToPhone: assignedToPhone ?? this.assignedToPhone,
      participants: participants ?? this.participants,
      status: status ?? this.status,
      milestones: milestones ?? this.milestones,
      priority: priority ?? this.priority,
      isUrgent: isUrgent ?? this.isUrgent,
      deadline: deadline ?? this.deadline,
      progress: progress ?? this.progress,
      tags: tags ?? this.tags,
      extraFields: extraFields ?? this.extraFields,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isClosed: isClosed ?? this.isClosed,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCounts: unreadCounts ?? this.unreadCounts,
      teamId: teamId ?? this.teamId,
      displayId: displayId ?? this.displayId,
      rating: rating ?? this.rating,
      clientPhone: clientPhone ?? this.clientPhone,
      clientEmail: clientEmail ?? this.clientEmail,
      clientAddress: clientAddress ?? this.clientAddress,
      clientCompany: clientCompany ?? this.clientCompany,
      category: category ?? this.category,
      isArchived: isArchived ?? this.isArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      archivedBy: archivedBy ?? this.archivedBy,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedBy: deletedBy ?? this.deletedBy,
      recurrence: clearRecurrence ? null : (recurrence ?? this.recurrence),
      seriesId: clearRecurrence ? null : (seriesId ?? this.seriesId),
      nextDue: clearRecurrence ? null : (nextDue ?? this.nextDue),
    );
  }

  /// Time-driven recurrence rule (Phase-2B), parsed from the [recurrence]
  /// column. Non-null only on a series ANCHOR; generated occurrences carry a
  /// [seriesId] but a null rule. Enquiries never stored the legacy
  /// completion-driven extraFields rule (that was Task-only), so there is no
  /// fallback here — see RecurrenceRule.tryParse.
  RecurrenceRule? get recurrenceRule => RecurrenceRule.tryParse(recurrence);

  /// Customer/contact details as a shared, model-agnostic value object.
  /// [clientName] is required/non-null; the rest are optional and collapse to
  /// empty strings (see [CustomerInfo]).
  CustomerInfo get customerInfo => CustomerInfo(
    name: clientName,
    phone: clientPhone ?? '',
    email: clientEmail ?? '',
    address: clientAddress ?? '',
    company: clientCompany ?? '',
  );

  /// Return a copy with all customer fields replaced from [info] — the single
  /// write path used by the shared CustomerEditDialog across every module.
  EnquiryModel withCustomerInfo(CustomerInfo info) => copyWith(
    clientName: info.name,
    clientPhone: info.phone,
    clientEmail: info.email,
    clientAddress: info.address,
    clientCompany: info.company,
  );

  bool get isOverdue {
    if (deadline == null) return false;
    return DateTime.now().isAfter(deadline!) && !isClosed;
  }

  // ── Multi-assignee helpers ──────────────────────────────────────────────

  /// Whether this enquiry has multiple assignees (premium feature).
  bool get isGroupEnquiry {
    final uids = assigneeUids;
    return uids.length > 1;
  }

  /// All assignee UIDs from extraFields (multi-assignee).
  List<String> get assigneeUids {
    final raw = extraFields?['assigneeUids'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    // Fallback to single assignee
    if (assignedToUid != null && assignedToUid!.isNotEmpty) {
      return [assignedToUid!];
    }
    return [];
  }

  /// All assignee names from extraFields (multi-assignee).
  List<String> get assigneeNames {
    final raw = extraFields?['assigneeNames'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    // Fallback to single assignee
    if (assignedTo.isNotEmpty) return [assignedTo];
    return [];
  }

  /// All assignee phones from extraFields (multi-assignee).
  List<String> get assigneePhones {
    final raw = extraFields?['assigneePhones'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (assignedToPhone != null && assignedToPhone!.isNotEmpty) {
      return [assignedToPhone!];
    }
    return [];
  }

  /// Display string for assignee(s): "Name" or "Name +2 others"
  String get assigneeDisplay {
    final names = assigneeNames;
    if (names.isEmpty) return assignedTo.isNotEmpty ? assignedTo : 'Unassigned';
    if (names.length == 1) return names.first;
    return '${names.first} +${names.length - 1} other${names.length > 2 ? 's' : ''}';
  }

  String get statusLabel {
    if (status.isEmpty) return 'Unknown';
    // Handle camelCase: "inProgress" → "In Progress"
    final formatted = status.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    return formatted[0].toUpperCase() + formatted.substring(1);
  }

  int get completedMilestoneCount =>
      milestones.where((m) => m.isCompleted).length;

  double get milestoneProgress {
    if (milestones.isEmpty) return 0.0;
    return completedMilestoneCount / milestones.length;
  }
}
