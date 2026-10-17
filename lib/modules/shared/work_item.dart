import '../../models/milestone.dart';

/// Read-only contract for a module work item (a Sales enquiry, a CRM record,
/// and — in a future migration — a Task). Captures ONLY the members common to
/// `EnquiryModel` and `TaskModel` so a generic provider engine can list, page,
/// filter, cache and identity-repair items without knowing the concrete type.
///
/// Deliberately minimal and read-only:
/// - No `copyWith`: the concrete models' `copyWith` signatures diverge
///   (`EnquiryModel` has clientName/status; `TaskModel` has isCancelled, etc.),
///   so mutations stay in the concrete provider layer.
/// - No Enquiry-only fields (clientName, clientEmail, clientPhone, status) and
///   no Task-only fields (participantHistory, reminderCount, startDate, ...):
///   those remain concrete-specific.
///
/// `EnquiryModel` implements this today. `TaskModel` already exposes every
/// member below (verified by inspection) but is intentionally NOT modified, so
/// the Task module carries zero risk from this generalization.
abstract class WorkItem {
  String get id;
  String get title;
  String get description;

  String get createdBy;
  String get assignedTo;
  String? get assignedToUid;
  String? get assignedToPhone;
  List<String> get participants;

  List<MilestoneModel> get milestones;
  Map<String, dynamic>? get extraFields;

  int get priority;
  bool get isUrgent;
  DateTime? get deadline;
  double get progress;
  List<String> get tags;
  String? get category;
  int? get rating;

  DateTime get createdAt;
  DateTime get updatedAt;
  bool get isClosed;
  bool get isOverdue;

  String? get lastMessageText;
  DateTime? get lastMessageTime;
  Map<String, int> get unreadCounts;

  String? get teamId;
  int? get displayId;

  bool get isArchived;
  DateTime? get archivedAt;
  bool get isDeleted;
  DateTime? get deletedAt;
}

// ── Render signatures (no-op notify suppression) ───────────────────────────
// A list reload that produces an identical signature would rebuild every card
// for exactly the same pixels, so the providers compare before/after and skip
// the notify. These cover every field a list card renders — including the ones
// written WITHOUT bumping `updatedAt` (unreadCounts and the lastMessage*
// snapshot, see UnreadCountsMixin), which a plain id+updatedAt check would
// swallow. Text and map fields ride their hashCode to keep the signature short;
// both sides are always computed in the same process, so hashCode equality is
// sound here. TaskProvider keeps its own twin because TaskModel deliberately
// does not implement WorkItem — the two lists must stay in step.

String milestoneSignature(MilestoneModel m) =>
    '${m.id}:${m.order}:${m.isCompleted ? 1 : 0}:${m.title.hashCode}:'
    '${m.deadline?.millisecondsSinceEpoch ?? 0}';

String workItemSignature(WorkItem e) {
  final unread = e.unreadCounts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [
    e.id,
    e.updatedAt.millisecondsSinceEpoch,
    e.title.hashCode,
    e.description.hashCode,
    e.createdBy,
    e.assignedTo,
    e.assignedToUid ?? '',
    e.assignedToPhone ?? '',
    e.priority,
    e.isUrgent ? 1 : 0,
    e.progress,
    e.isClosed ? 1 : 0,
    e.isArchived ? 1 : 0,
    e.isDeleted ? 1 : 0,
    e.deadline?.millisecondsSinceEpoch ?? 0,
    e.teamId ?? '',
    e.displayId ?? 0,
    e.category ?? '',
    e.rating ?? 0,
    e.tags.join(','),
    e.participants.join(','),
    e.extraFields?.toString().hashCode ?? 0,
    unread.map((x) => '${x.key}:${x.value}').join(','),
    e.lastMessageText?.hashCode ?? 0,
    e.lastMessageTime?.millisecondsSinceEpoch ?? 0,
    e.milestones.map(milestoneSignature).join(','),
  ].join('|');
}

String workItemListSignature(List<WorkItem> items) =>
    items.map(workItemSignature).join('#');
