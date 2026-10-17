/// Represents a participant in a task with join/leave history
class TaskParticipant {
  final String userId; // User name or ID
  final String userName; // Display name
  final DateTime joinedAt; // When they joined the task
  final DateTime? leftAt; // null if still active
  final String addedBy; // Who added them
  final bool isMainAssignee; // true if this is the primary assignee

  TaskParticipant({
    required this.userId,
    required this.userName,
    required this.joinedAt,
    this.leftAt,
    required this.addedBy,
    this.isMainAssignee = false,
  });

  bool get isActive => leftAt == null;

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'joinedAt': joinedAt.toUtc(),
      'leftAt': leftAt?.toUtc(),
      'addedBy': addedBy,
      'isMainAssignee': isMainAssignee,
    };
  }

  factory TaskParticipant.fromMap(Map<String, dynamic> map) {
    return TaskParticipant(
      userId: map['userId'] ?? '',
      userName: map['userName'] ?? '',
      joinedAt: (map['joinedAt'] as DateTime?) ?? DateTime.now(),
      leftAt: map['leftAt'] as DateTime?,
      addedBy: map['addedBy'] ?? '',
      isMainAssignee: map['isMainAssignee'] ?? false,
    );
  }

  TaskParticipant copyWith({
    String? userId,
    String? userName,
    DateTime? joinedAt,
    DateTime? leftAt,
    String? addedBy,
    bool? isMainAssignee,
  }) {
    return TaskParticipant(
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      joinedAt: joinedAt ?? this.joinedAt,
      leftAt: leftAt ?? this.leftAt,
      addedBy: addedBy ?? this.addedBy,
      isMainAssignee: isMainAssignee ?? this.isMainAssignee,
    );
  }
}

/// Message visibility rules
class MessageVisibility {
  /// Check if a user can see a specific message
  static bool canUserSeeMessage({
    required String viewerId,
    required DateTime messageTime,
    required List<TaskParticipant> participants,
  }) {
    // Find when the viewer joined
    final viewerParticipant = participants
        .where((p) => p.userId == viewerId && p.leftAt == null)
        .firstOrNull;

    if (viewerParticipant == null) {
      // User is not currently in the task
      // Check if they were a participant when the message was sent
      final pastParticipant = participants
          .where((p) => p.userId == viewerId)
          .firstOrNull;

      if (pastParticipant == null) {
        return false; // Never been in the task
      }

      // Can see messages from when they were in the task
      final canSee =
          messageTime.isAfter(pastParticipant.joinedAt) &&
          (pastParticipant.leftAt == null ||
              messageTime.isBefore(pastParticipant.leftAt!));

      return canSee;
    }

    // User is currently in the task
    // Can only see messages from when they joined onwards
    return messageTime.isAfter(viewerParticipant.joinedAt) ||
        messageTime.isAtSameMomentAs(viewerParticipant.joinedAt);
  }

  /// Filter messages visible to a specific user
  static List<Map<String, dynamic>> filterVisibleMessages({
    required String viewerId,
    required List<Map<String, dynamic>> allMessages,
    required List<TaskParticipant> participants,
  }) {
    return allMessages.where((message) {
      final messageTime = message['createdAt'] as DateTime;
      return canUserSeeMessage(
        viewerId: viewerId,
        messageTime: messageTime,
        participants: participants,
      );
    }).toList();
  }

  /// Get system message for participant join
  static Map<String, dynamic> createJoinMessage({
    required String taskId,
    required String addedUserName,
    required String newUserName,
    required DateTime timestamp,
  }) {
    return {
      'id': 'msg_join_${timestamp.millisecondsSinceEpoch}',
      'taskId': taskId,
      'senderId': 'system',
      'text': '👥 $addedUserName added $newUserName to the task',
      'type': 'system',
      'createdAt': timestamp,
      'visibleToAll': true, // Everyone can see this
    };
  }

  /// Get system message for participant leave
  static Map<String, dynamic> createLeaveMessage({
    required String taskId,
    required String userName,
    required DateTime timestamp,
  }) {
    return {
      'id': 'msg_leave_${timestamp.millisecondsSinceEpoch}',
      'taskId': taskId,
      'senderId': 'system',
      'text': '👤 $userName left the task',
      'type': 'system',
      'createdAt': timestamp,
      'visibleToAll': true,
    };
  }

  /// Get system message for participant removed by someone
  static Map<String, dynamic> createRemoveMessage({
    required String taskId,
    required String removedBy,
    required String removedUser,
    required DateTime timestamp,
  }) {
    return {
      'id': 'msg_remove_${timestamp.millisecondsSinceEpoch}',
      'taskId': taskId,
      'senderId': 'system',
      'text': '🚫 $removedBy removed $removedUser from the task',
      'type': 'system',
      'createdAt': timestamp,
      'visibleToAll': true,
    };
  }
}
