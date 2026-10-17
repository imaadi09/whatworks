import 'package:cloud_firestore/cloud_firestore.dart';

/// A member of an organization, holding (or having held) a seat.
/// Stored in `organizations/{orgId}/members/{uid}`.
///
/// App-owned via Cloud Functions: members are created on join and their
/// seatStatus is flipped to 'revoked' when an admin frees the seat.
class OrgMemberModel {
  final String uid;
  final String displayName;
  final String phone;
  final String role; // 'owner' | 'admin' | 'member'
  final String seatStatus; // 'active' | 'invited' | 'revoked'
  final DateTime joinedAt;

  OrgMemberModel({
    required this.uid,
    required this.displayName,
    required this.phone,
    required this.role,
    required this.seatStatus,
    required this.joinedAt,
  });

  factory OrgMemberModel.fromMap(Map<String, dynamic> map, String id) {
    return OrgMemberModel(
      uid: map['uid'] ?? id,
      displayName: map['displayName'] ?? '',
      phone: map['phone'] ?? '',
      role: map['role'] ?? 'member',
      seatStatus: map['seatStatus'] ?? 'active',
      joinedAt: (map['joinedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  bool get isActiveSeat => seatStatus == 'active';
  bool get isAdmin => role == 'owner' || role == 'admin';
}
