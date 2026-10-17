import 'package:cloud_firestore/cloud_firestore.dart';

enum MessageType { text, image, file, voice, system }

// System message subtypes for special handling
enum SystemMessageType {
  regular,
  reminder,
  warning,
  query, // Status query/request
  followUp,
  call, // Scheduled call (carries scheduledAt for reminders)
  statusChange,
  assigneeChange,
  progressChange,
  blocker, // Assignee raised a blocker
  approval, // Assignee requested approval
  extension, // Assignee requested deadline extension
  progressReport, // Assignee reported progress
}

class MessageModel {
  final String id;
  final String taskId;
  final String senderId;
  final String text;
  final MessageType type;
  final String? fileUrl;
  final String? fileName;
  final int? duration; // For voice notes (in seconds)
  final DateTime createdAt;
  final String? searchableContent; // Extracted text from PDFs/docs for search
  final String?
  deliveryMethod; // How this message was delivered: 'in-app', 'whatsapp', 'sms', 'failed'
  final bool isEdited; // Whether this message has been edited
  final bool deleted; // Soft-delete for everyone (tombstone)
  final List<String> deletedFor; // UIDs of users who deleted this message for themselves
  final Map<String, bool>?
  downloadedBy; // Track which users have downloaded attachments {userId: true}
  final DateTime? deliveredAt; // When message was delivered to recipient (legacy single-timestamp)
  final Map<String, DateTime>? deliveredTo; // Per-user delivery tracking {userId: timestamp}
  final String? uploadError; // Error message when upload fails (null when OK)
  final Map<String, DateTime>? readBy; // Track who read the message and when {userId: timestamp}
  
  bool get isUploadFailed => fileUrl == 'failed' || uploadError != null;
  
  // System message metadata
  final SystemMessageType systemType; // Type of system message
  final int? sequenceNumber; // For reminder #1, warning #2, etc.
  
  // Query/Status fields
  final String? queryReply; // Reply text to a query
  final String? repliedBy; // UID of user who replied
  final DateTime? repliedAt; // When the reply was sent
  final bool isReplied; // Whether the query has been replied to
  
  // Follow-up fields
  final bool isFollowUpDone; // Whether the follow-up is marked as done
  final String? followUpDoneBy; // UID of user who marked it done
  final DateTime? followUpDoneAt; // When it was marked done

  // Scheduled-call reminder time (server sweep pushes FCM to the other side
  // at this moment; the scheduler's own device uses a local notification).
  final DateTime? scheduledAt;

  // WhatsApp-style reply fields
  final String? replyToMessageId; // ID of the message being replied to
  final String? replyToMessageText; // Denormalized text of the quoted message
  final String? replyToMessageSender; // Sender name of the quoted message

  MessageModel({
    required this.id,
    required this.taskId,
    required this.senderId,
    required this.text,
    this.type = MessageType.text,
    this.fileUrl,
    this.fileName,
    this.duration,
    required this.createdAt,
    this.searchableContent,
    this.deliveryMethod,
    this.isEdited = false,
    this.deleted = false,
    this.deletedFor = const [],
    this.downloadedBy,
    this.deliveredAt,
    this.deliveredTo,
    this.uploadError,
    this.readBy,
    this.systemType = SystemMessageType.regular,
    this.sequenceNumber,
    this.queryReply,
    this.repliedBy,
    this.repliedAt,
    this.isReplied = false,
    this.isFollowUpDone = false,
    this.followUpDoneBy,
    this.followUpDoneAt,
    this.scheduledAt,
    this.replyToMessageId,
    this.replyToMessageText,
    this.replyToMessageSender,
  });

  // Create from Firestore document
  factory MessageModel.fromMap(Map<String, dynamic> map, String id) {
    return MessageModel(
      id: id,
      taskId: map['taskId'] ?? '',
      senderId: map['senderId'] ?? '',
      text: map['text'] ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.toString() == 'MessageType.${map['type']}',
        orElse: () => MessageType.text,
      ),
      fileUrl: map['fileUrl'],
      fileName: map['fileName'],
      duration: map['duration'],
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      searchableContent: map['searchableContent'],
      deliveryMethod: map['deliveryMethod'],
      isEdited: map['isEdited'] == true,
      deleted: map['deleted'] == true,
      deletedFor: map['deletedFor'] != null
          ? List<String>.from(map['deletedFor'] as List)
          : const [],
      downloadedBy: map['downloadedBy'] != null
          ? Map<String, bool>.from(map['downloadedBy'])
          : null,
      deliveredAt: map['deliveredAt'] != null
          ? (map['deliveredAt'] as Timestamp).toDate()
          : null,
      deliveredTo: map['deliveredTo'] != null
          ? Map<String, DateTime>.fromEntries(
              (map['deliveredTo'] as Map).entries.map(
                (e) => MapEntry(
                  e.key.toString(),
                  (e.value as Timestamp).toDate(),
                ),
              ),
            )
          : null,
      uploadError: map['uploadError'],
      readBy: map['readBy'] != null
          ? Map<String, DateTime>.fromEntries(
              (map['readBy'] as Map).entries.map(
                (e) => MapEntry(
                  e.key.toString(),
                  (e.value as Timestamp).toDate(),
                ),
              ),
            )
          : null,
      systemType: SystemMessageType.values.firstWhere(
        (e) => e.toString() == 'SystemMessageType.${map['systemType'] ?? 'regular'}',
        orElse: () => SystemMessageType.regular,
      ),
      sequenceNumber: map['sequenceNumber'],
      queryReply: map['queryReply'],
      repliedBy: map['repliedBy'],
      repliedAt: map['repliedAt'] != null
          ? (map['repliedAt'] as Timestamp).toDate()
          : null,
      isReplied: map['isReplied'] == true,
      isFollowUpDone: map['isFollowUpDone'] == true,
      followUpDoneBy: map['followUpDoneBy'],
      followUpDoneAt: map['followUpDoneAt'] != null
          ? (map['followUpDoneAt'] as Timestamp).toDate()
          : null,
      scheduledAt: map['scheduledAt'] != null
          ? (map['scheduledAt'] as Timestamp).toDate()
          : null,
      replyToMessageId: map['replyToMessageId'],
      replyToMessageText: map['replyToMessageText'],
      replyToMessageSender: map['replyToMessageSender'],
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'taskId': taskId,
      'senderId': senderId,
      'text': text,
      'type': type.toString().split('.').last,
      'fileUrl': fileUrl,
      'fileName': fileName,
      'duration': duration,
      'createdAt': createdAt.toUtc(),
      'searchableContent': searchableContent,
      'deliveryMethod': deliveryMethod,
      'isEdited': isEdited,
      'deleted': deleted,
      'deletedFor': deletedFor,
      'downloadedBy': downloadedBy,
      'deliveredAt': deliveredAt != null ? Timestamp.fromDate(deliveredAt!) : null,
      'deliveredTo': deliveredTo != null
          ? deliveredTo!.map((key, value) => MapEntry(key, Timestamp.fromDate(value)))
          : null,
      'uploadError': uploadError,
      'readBy': readBy != null
          ? readBy!.map((key, value) => MapEntry(key, Timestamp.fromDate(value)))
          : null,
      'systemType': systemType.toString().split('.').last,
      'sequenceNumber': sequenceNumber,
      'queryReply': queryReply,
      'repliedBy': repliedBy,
      'repliedAt': repliedAt != null ? Timestamp.fromDate(repliedAt!) : null,
      'isReplied': isReplied,
      'isFollowUpDone': isFollowUpDone,
      'followUpDoneBy': followUpDoneBy,
      'followUpDoneAt': followUpDoneAt != null ? Timestamp.fromDate(followUpDoneAt!) : null,
      'scheduledAt': scheduledAt != null ? Timestamp.fromDate(scheduledAt!) : null,
      'replyToMessageId': replyToMessageId,
      'replyToMessageText': replyToMessageText,
      'replyToMessageSender': replyToMessageSender,
    };
  }

  MessageModel copyWith({
    String? id,
    String? taskId,
    String? senderId,
    String? text,
    MessageType? type,
    String? fileUrl,
    String? fileName,
    int? duration,
    DateTime? createdAt,
    String? searchableContent,
    String? deliveryMethod,
    bool? isEdited,
    bool? deleted,
    List<String>? deletedFor,
    Map<String, bool>? downloadedBy,
    DateTime? deliveredAt,
    Map<String, DateTime>? deliveredTo,
    String? uploadError,
    Map<String, DateTime>? readBy,
    SystemMessageType? systemType,
    int? sequenceNumber,
    String? queryReply,
    String? repliedBy,
    DateTime? repliedAt,
    bool? isReplied,
    bool? isFollowUpDone,
    String? followUpDoneBy,
    DateTime? followUpDoneAt,
    DateTime? scheduledAt,
    String? replyToMessageId,
    String? replyToMessageText,
    String? replyToMessageSender,
  }) {
    return MessageModel(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      senderId: senderId ?? this.senderId,
      text: text ?? this.text,
      type: type ?? this.type,
      fileUrl: fileUrl ?? this.fileUrl,
      fileName: fileName ?? this.fileName,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      searchableContent: searchableContent ?? this.searchableContent,
      deliveryMethod: deliveryMethod ?? this.deliveryMethod,
      isEdited: isEdited ?? this.isEdited,
      deleted: deleted ?? this.deleted,
      deletedFor: deletedFor ?? this.deletedFor,
      downloadedBy: downloadedBy ?? this.downloadedBy,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      deliveredTo: deliveredTo ?? this.deliveredTo,
      uploadError: uploadError ?? this.uploadError,
      readBy: readBy ?? this.readBy,
      systemType: systemType ?? this.systemType,
      sequenceNumber: sequenceNumber ?? this.sequenceNumber,
      queryReply: queryReply ?? this.queryReply,
      repliedBy: repliedBy ?? this.repliedBy,
      repliedAt: repliedAt ?? this.repliedAt,
      isReplied: isReplied ?? this.isReplied,
      isFollowUpDone: isFollowUpDone ?? this.isFollowUpDone,
      followUpDoneBy: followUpDoneBy ?? this.followUpDoneBy,
      followUpDoneAt: followUpDoneAt ?? this.followUpDoneAt,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToMessageText: replyToMessageText ?? this.replyToMessageText,
      replyToMessageSender: replyToMessageSender ?? this.replyToMessageSender,
    );
  }
}
