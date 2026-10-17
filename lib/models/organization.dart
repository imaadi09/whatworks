import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/paywall_constants.dart';

/// Model for an organization / subscription account.
/// Stored in the `organizations` Firestore collection.
///
/// Ownership split:
/// - Billing WEBSITE owns (writes via Admin SDK, app treats read-only):
///   planType, status, seatsTotal, subscriptionCode, billingCycle,
///   startDate, renewalDate, expiryDate, and all payment records.
/// - APP owns (writes): name, adminUids, and member join/leave (seatsUsed is
///   maintained by a Cloud Function).
class OrganizationModel {
  final String id;
  final String name;
  final String orgCode; // Short unique join code, e.g. "ACME-7X2K"
  final String subscriptionCode; // License key from the billing website
  final String ownerUid;
  final List<String> adminUids;
  final String
  planType; // 'basic' | 'premium' | 'business' | 'enterprise' (legacy 'free' accepted)
  final String status; // 'active' | 'expired' | 'cancelled' | 'trialing'
  final int seatsTotal;
  final int seatsUsed;
  final String billingCycle; // 'monthly' | 'annual'
  final DateTime? startDate;
  final DateTime? renewalDate;
  final DateTime? expiryDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  OrganizationModel({
    required this.id,
    required this.name,
    required this.orgCode,
    required this.subscriptionCode,
    required this.ownerUid,
    required this.adminUids,
    required this.planType,
    required this.status,
    required this.seatsTotal,
    required this.seatsUsed,
    required this.billingCycle,
    this.startDate,
    this.renewalDate,
    this.expiryDate,
    required this.createdAt,
    required this.updatedAt,
  });

  factory OrganizationModel.fromMap(Map<String, dynamic> map, String id) {
    return OrganizationModel(
      id: id,
      name: map['name'] ?? '',
      orgCode: map['orgCode'] ?? '',
      subscriptionCode: map['subscriptionCode'] ?? '',
      ownerUid: map['ownerUid'] ?? '',
      adminUids:
          (map['adminUids'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      planType: map['planType'] ?? 'basic',
      status: map['status'] ?? 'expired',
      seatsTotal: (map['seatsTotal'] as num?)?.toInt() ?? 0,
      seatsUsed: (map['seatsUsed'] as num?)?.toInt() ?? 0,
      billingCycle: map['billingCycle'] ?? 'monthly',
      startDate: (map['startDate'] as Timestamp?)?.toDate(),
      renewalDate: (map['renewalDate'] as Timestamp?)?.toDate(),
      expiryDate: (map['expiryDate'] as Timestamp?)?.toDate(),
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  /// App-owned fields only. Website-owned fields (planType/status/seats/dates/
  /// subscriptionCode) must NOT be written by the client.
  Map<String, dynamic> toAppMap() {
    return {
      'name': name,
      'adminUids': adminUids,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// Whether the subscription is currently active and not expired.
  bool get isActive {
    if (status != 'active' && status != 'trialing') return false;
    if (expiryDate == null) return true;
    return DateTime.now().isBefore(expiryDate!);
  }

  /// Whether the subscription grants premium-or-higher features.
  bool get grantsPremium => isActive && PaywallLimits.isPremium(planType);

  /// Seats still available to be filled (never negative).
  int get seatsAvailable {
    final available = seatsTotal - seatsUsed;
    return available < 0 ? 0 : available;
  }

  /// Days until renewal (or expiry). Null when no renewal/expiry set.
  int? get daysUntilRenewal {
    final target = renewalDate ?? expiryDate;
    if (target == null) return null;
    return target.difference(DateTime.now()).inDays;
  }

  bool isAdmin(String uid) => uid == ownerUid || adminUids.contains(uid);

  OrganizationModel copyWith({String? name, List<String>? adminUids}) {
    return OrganizationModel(
      id: id,
      name: name ?? this.name,
      orgCode: orgCode,
      subscriptionCode: subscriptionCode,
      ownerUid: ownerUid,
      adminUids: adminUids ?? this.adminUids,
      planType: planType,
      status: status,
      seatsTotal: seatsTotal,
      seatsUsed: seatsUsed,
      billingCycle: billingCycle,
      startDate: startDate,
      renewalDate: renewalDate,
      expiryDate: expiryDate,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
