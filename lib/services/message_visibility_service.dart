import '../models/message.dart';
import '../models/task_participant.dart';

/// Service to handle message visibility based on participant join/leave history
class MessageVisibilityService {
  /// Filter messages that a user can see based on when they joined/left
  /// 
  /// Simplified logic:
  /// - If user is in currentParticipants list, show ALL messages
  /// - Otherwise, filter based on participantHistory timestamps
  static List<MessageModel> getVisibleMessages({
    required List<MessageModel> allMessages,
    required List<TaskParticipant> participantHistory,
    String? viewerId, // null = current user
    List<String>? currentParticipants, // Current participants list
  }) {
    final currentUserId = viewerId ?? '';

    // If user is currently a participant, show ALL messages
    if (currentParticipants != null && currentParticipants.contains(currentUserId)) {
      return allMessages;
    }

    // If no participant history exists, show all messages (task has no participant tracking)
    if (participantHistory.isEmpty) {
      return allMessages;
    }

    // Find the viewer's participation record
    final viewerRecord = _findParticipantRecord(
      participantHistory,
      currentUserId,
    );

    // If no participation record found but history exists, still show all messages
    // (user might be the creator who was never formally added as participant)
    if (viewerRecord == null) {
      return allMessages;
    }

    return allMessages.where((message) {
      // ALL system messages are always visible (reminders, warnings, status updates, etc.)
      if (message.type == MessageType.system || message.senderId == 'system') {
        return true;
      }

      // Check if message was sent during viewer's participation period
      final messageTime = message.createdAt;

      // Can see messages from join time onwards
      if (messageTime.isBefore(viewerRecord.joinedAt)) {
        return false;
      }

      // If user left, can only see messages before they left
      if (viewerRecord.leftAt != null &&
          messageTime.isAfter(viewerRecord.leftAt!)) {
        return false;
      }

      return true;
    }).toList();
  }

  /// Find a participant's record (current or past)
  static TaskParticipant? _findParticipantRecord(
    List<TaskParticipant> history,
    String userName,
  ) {
    // First try to find active participant
    final active = history
        .where(
          (p) =>
              (p.userId == userName || p.userName == userName) &&
              p.leftAt == null,
        )
        .firstOrNull;

    if (active != null) return active;

    // If not active, find the most recent past participation
    final pastParticipants = history
        .where((p) => p.userId == userName || p.userName == userName)
        .toList();

    if (pastParticipants.isEmpty) return null;

    // Return the most recent one (latest joinedAt)
    pastParticipants.sort((a, b) => b.joinedAt.compareTo(a.joinedAt));
    return pastParticipants.first;
  }

  /// Create a join event message
  static MessageModel createJoinMessage({
    required String taskId,
    required String addedBy,
    required String newUserName,
    DateTime? timestamp,
  }) {
    return MessageModel(
      id: 'msg_join_${DateTime.now().millisecondsSinceEpoch}',
      taskId: taskId,
      senderId: 'system',
      text: '👥 $addedBy added $newUserName to the task',
      type: MessageType.system,
      createdAt: timestamp ?? DateTime.now(),
    );
  }

  /// Create a leave event message
  static MessageModel createLeaveMessage({
    required String taskId,
    required String userName,
    DateTime? timestamp,
  }) {
    return MessageModel(
      id: 'msg_leave_${DateTime.now().millisecondsSinceEpoch}',
      taskId: taskId,
      senderId: 'system',
      text: '👤 $userName left the task',
      type: MessageType.system,
      createdAt: timestamp ?? DateTime.now(),
    );
  }

  /// Create a remove event message
  static MessageModel createRemoveMessage({
    required String taskId,
    required String removedBy,
    required String removedUserName,
    DateTime? timestamp,
  }) {
    return MessageModel(
      id: 'msg_remove_${DateTime.now().millisecondsSinceEpoch}',
      taskId: taskId,
      senderId: 'system',
      text: '🚫 $removedBy removed $removedUserName from the task',
      type: MessageType.system,
      createdAt: timestamp ?? DateTime.now(),
    );
  }

  /// Check if a specific message is visible to a user
  static bool isMessageVisible({
    required MessageModel message,
    required String viewerName,
    required List<TaskParticipant> participantHistory,
  }) {
    // If no participant history, show all messages
    if (participantHistory.isEmpty) return true;

    final viewerRecord = _findParticipantRecord(participantHistory, viewerName);

    // If no record found but history exists, still show (creator may not be tracked)
    if (viewerRecord == null) return true;

    // ALL system messages are always visible (reminders, warnings, status updates, etc.)
    if (message.type == MessageType.system || message.senderId == 'system') {
      return true;
    }

    final messageTime = message.createdAt;

    // Before join = not visible
    if (messageTime.isBefore(viewerRecord.joinedAt)) {
      return false;
    }

    // After leave = not visible
    if (viewerRecord.leftAt != null &&
        messageTime.isAfter(viewerRecord.leftAt!)) {
      return false;
    }

    return true;
  }
}
