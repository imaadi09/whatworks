/// Represents a step in the task creation conversation flow.
enum TaskDraftStep {
  assigneeSelected,
  enteringTitle,
  enteringDescription,
  enteringDeadline,
  enteringPriority,
  enteringUrgency,
  enteringProgress,
  scheduling,
  complete,
}

/// A message in the task creation conversation.
class ConversationMessage {
  final bool isSystem; // true = system prompt, false = user response
  final String text;
  final TaskDraftStep? step; // which field this relates to
  final bool canEdit; // whether this message can be tapped to edit
  final DateTime createdAt;

  ConversationMessage({
    required this.isSystem,
    required this.text,
    this.step,
    this.canEdit = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

/// Temporary model that tracks the draft task during the conversational flow.
class TaskDraft {
  String assignedTo; // Changed to mutable for editing
  String? assigneeUid; // Firebase UID of assignee (for on-app users)
  String? assigneePhone;
  bool assigneeIsOnApp;

  String title;
  String description;
  DateTime? startDate; // When task becomes active (null = now)
  DateTime? deadline;
  int priority; // 1=Low, 2=Mid, 3=High
  bool isUrgent;
  int progress; // 0-100 percentage
  bool activateNow;

  TaskDraftStep currentStep;
  final List<ConversationMessage> conversation;

  TaskDraft({
    required this.assignedTo,
    this.assigneeUid,
    this.assigneePhone,
    this.assigneeIsOnApp = true,
    this.title = '',
    this.description = '',
    this.startDate,
    this.deadline,
    this.priority = 2,
    this.isUrgent = false,
    this.progress = 0,
    this.activateNow = true,
    this.currentStep = TaskDraftStep.enteringTitle,
    List<ConversationMessage>? conversation,
  }) : conversation = conversation ?? [];

  /// Get a user-friendly name for the step
  String getStepName(TaskDraftStep step) {
    switch (step) {
      case TaskDraftStep.enteringTitle:
        return 'Title';
      case TaskDraftStep.enteringDescription:
        return 'Description';
      case TaskDraftStep.enteringDeadline:
        return 'Deadline';
      case TaskDraftStep.enteringPriority:
        return 'Priority';
      case TaskDraftStep.enteringUrgency:
        return 'Urgency';
      case TaskDraftStep.enteringProgress:
        return 'Progress';
      case TaskDraftStep.scheduling:
        return 'Activation';
      default:
        return '';
    }
  }

  /// Check if a step has been completed
  bool isStepComplete(TaskDraftStep step) {
    switch (step) {
      case TaskDraftStep.enteringTitle:
        return title.isNotEmpty;
      case TaskDraftStep.enteringDescription:
        return true; // description is optional
      case TaskDraftStep.enteringDeadline:
        return deadline != null;
      case TaskDraftStep.enteringPriority:
        return true; // has default
      case TaskDraftStep.enteringUrgency:
        return true; // has default
      case TaskDraftStep.scheduling:
        return true; // has default
      default:
        return false;
    }
  }

  /// Convert to Map for Firestore storage
  Map<String, dynamic> toMap() {
    return {
      'assignedTo': assignedTo,
      'assigneeUid': assigneeUid,
      'assigneePhone': assigneePhone,
      'assigneeIsOnApp': assigneeIsOnApp,
      'title': title,
      'description': description,
      'startDate': startDate?.millisecondsSinceEpoch,
      'deadline': deadline?.millisecondsSinceEpoch,
      'priority': priority,
      'isUrgent': isUrgent,
      'progress': progress,
      'activateNow': activateNow,
      'currentStep': currentStep.name,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Create from Map (Firestore document)
  factory TaskDraft.fromMap(Map<String, dynamic> map, String id) {
    TaskDraftStep parseStep(String? stepName) {
      try {
        return TaskDraftStep.values.byName(stepName ?? 'enteringTitle');
      } catch (e) {
        return TaskDraftStep.enteringTitle;
      }
    }

    return TaskDraft(
      assignedTo: map['assignedTo'] as String? ?? '',
      assigneeUid: map['assigneeUid'] as String?,
      assigneePhone: map['assigneePhone'] as String?,
      assigneeIsOnApp: map['assigneeIsOnApp'] as bool? ?? true,
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
      startDate: map['startDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['startDate'] as int)
          : null,
      deadline: map['deadline'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['deadline'] as int)
          : null,
      priority: map['priority'] as int? ?? 2,
      isUrgent: map['isUrgent'] as bool? ?? false,
      progress: map['progress'] as int? ?? 0,
      activateNow: map['activateNow'] as bool? ?? true,
      currentStep: parseStep(map['currentStep'] as String?),
    );
  }
}
