import 'package:cloud_firestore/cloud_firestore.dart';

class SystemLogModel {
  final String id;
  final String taskId;
  final String action; // "priority_changed", "person_added", "warning_issued", etc.
  final String performedBy;
  final String details;
  final DateTime createdAt;

  SystemLogModel({
    required this.id,
    required this.taskId,
    required this.action,
    required this.performedBy,
    required this.details,
    required this.createdAt,
  });

  // Create from Firestore document
  factory SystemLogModel.fromMap(Map<String, dynamic> map, String id) {
    return SystemLogModel(
      id: id,
      taskId: map['taskId'] ?? '',
      action: map['action'] ?? '',
      performedBy: map['performedBy'] ?? '',
      details: map['details'] ?? '',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'taskId': taskId,
      'action': action,
      'performedBy': performedBy,
      'details': details,
      'createdAt': createdAt.toUtc(),
    };
  }
}
