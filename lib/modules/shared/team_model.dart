import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared team model used across the Task, Sales and CRM modules.
///
/// Teams are PERSONAL (not WhatsApp-style shared groups): each user builds and
/// sees only their own teams. The [members] list stores UIDs of the contacts
/// the creator added to the team — it organizes the CREATOR's view and drives
/// each counterpart's viewer-side placement, but members never see the team
/// itself.
///
/// Stored in the per-module Firestore collections: `task_teams`, `sales_teams`
/// and `crm_teams` (all creator-owned, `createdBy == uid`).
class TeamModel {
  final String id;
  final String name;
  final String createdBy; // UID of creator (owner)
  final List<String> members; // UIDs of contacts added by the creator
  final DateTime createdAt;
  final DateTime updatedAt;

  TeamModel({
    required this.id,
    required this.name,
    required this.createdBy,
    this.members = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isDefault => name == 'My Team';

  /// Prefix for phone-keyed members (contacts added straight from the
  /// phonebook who are not on the app yet).
  static const String phonePrefix = 'phone:';

  /// True if [uid] is one of the members the creator added to this team.
  bool hasMember(String uid) => members.contains(uid);

  /// True if [normalizedPhone] is stored as a phone-keyed member.
  bool hasMemberPhone(String normalizedPhone) =>
      members.contains('$phonePrefix$normalizedPhone');

  factory TeamModel.fromMap(Map<String, dynamic> map, String id) {
    return TeamModel(
      id: id,
      name: map['name'] ?? '',
      createdBy: map['createdBy'] ?? '',
      members: List<String>.from(map['members'] ?? []),
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'createdBy': createdBy,
      'members': members,
      'createdAt': createdAt.toUtc(),
      'updatedAt': updatedAt.toUtc(),
    };
  }

  TeamModel copyWith({
    String? id,
    String? name,
    String? createdBy,
    List<String>? members,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TeamModel(
      id: id ?? this.id,
      name: name ?? this.name,
      createdBy: createdBy ?? this.createdBy,
      members: members ?? this.members,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
