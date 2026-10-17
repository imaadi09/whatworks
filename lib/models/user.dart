import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String name;
  final String email;
  final String phone; // Required - primary identifier for task assignment
  final String? avatarUrl;
  final String? organization;
  final String? designation;
  final String? mobileNumber; // Deprecated - use 'phone' instead
  final DateTime createdAt;
  final bool isOnApp; // Whether the user is active on the WhatWorks app
  final String
  planType; // 'basic', 'premium', 'business', 'enterprise' (legacy 'free' also accepted)
  final DateTime? planExpiry; // Paid plan expiry date (null = none/lifetime)
  final String?
  orgId; // Organization the user belongs to (drives effective plan)
  // Per-module subscriptions: moduleId -> { planType, startDate, expiryDate }.
  // Each module is bought and renewed on its own dates; written only by the
  // billing webhook (Admin SDK).
  final Map<String, Map<String, dynamic>> modulePlans;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone, // Now required
    this.avatarUrl,
    this.organization,
    this.designation,
    this.mobileNumber,
    required this.createdAt,
    this.isOnApp = true,
    this.planType = 'basic', // Default to basic (free) plan
    this.planExpiry,
    this.orgId,
    this.modulePlans = const {},
  });

  // Create from Firestore document
  factory UserModel.fromMap(Map<String, dynamic> map, String uid) {
    return UserModel(
      uid: uid,
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      phone:
          map['phone'] ??
          map['mobileNumber'] ??
          '', // Fallback to mobileNumber for backward compatibility
      avatarUrl: map['avatarUrl'],
      organization: map['organization'],
      designation: map['designation'],
      mobileNumber: map['mobileNumber'],
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isOnApp: map['isOnApp'] ?? true,
      planType: map['planType'] ?? 'basic',
      planExpiry: (map['planExpiry'] as Timestamp?)?.toDate(),
      orgId: map['orgId'],
      modulePlans: _parseModulePlans(map['modulePlans']),
    );
  }

  /// Parses the `modulePlans` map from Firestore into a typed map, tolerating
  /// missing or malformed entries.
  static Map<String, Map<String, dynamic>> _parseModulePlans(dynamic raw) {
    final result = <String, Map<String, dynamic>>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is Map) {
          result[key.toString()] = Map<String, dynamic>.from(value);
        }
      });
    }
    return result;
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'phone': phone, // Always save phone number
      'avatarUrl': avatarUrl,
      'organization': organization,
      'designation': designation,
      'mobileNumber':
          mobileNumber ?? phone, // Keep mobileNumber for backward compatibility
      'createdAt': createdAt.toUtc(),
      'isOnApp': isOnApp,
      'planType': planType,
      'planExpiry': planExpiry?.toUtc(),
      'orgId': orgId,
      'modulePlans': modulePlans,
    };
  }

  /// The only fields a client may write after the profile exists.
  ///
  /// [toMap] is for CREATE. Using it for an update sends `planType`,
  /// `planExpiry` and `orgId` back from whatever this (possibly stale) instance
  /// holds — a paying user editing their name could overwrite their own
  /// subscription with `'free'`. Billing and seat fields belong to the payment
  /// webhook and `joinOrganization` (Admin SDK), and firestore.rules now rejects
  /// a client update that changes them.
  Map<String, dynamic> toProfileUpdateMap() {
    return {
      'name': name,
      'email': email,
      'phone': phone,
      'avatarUrl': avatarUrl,
      'organization': organization,
      'designation': designation,
      'mobileNumber': mobileNumber ?? phone,
      'isOnApp': isOnApp,
    };
  }

  /// Premium is a *dated* grant, so [planType] alone is not the answer: a month
  /// that has run out still reads `'enterprise'` in Firestore until the nightly
  /// `expirePremiumPlans` sweep rewrites the doc. Checking the date locally
  /// means expiry bites immediately and keeps working offline.
  bool get isPlanExpired =>
      planExpiry != null && planExpiry!.isBefore(DateTime.now());

  /// The plan that should gate features. Anything deciding what a user may do
  /// reads this, never [planType]. Legacy 'free' is treated as 'basic'.
  String get effectivePlanType {
    if (isPlanExpired) return 'basic';
    final p = planType.trim().toLowerCase();
    if (p == 'free') return 'basic';
    const valid = {'basic', 'premium', 'business', 'enterprise'};
    return valid.contains(p) ? p : 'basic';
  }

  /// The effective plan for ONE module ('task', 'sale', 'crm', 'inventory').
  /// Subscriptions are bought per module and each keeps its own expiry under
  /// [modulePlans], so an active Sales subscription must not unlock Task
  /// limits. A module with no subscription, or one whose `expiryDate` has
  /// passed, reads 'basic'.
  String effectivePlanTypeFor(String module) {
    final entry = modulePlans[module];
    if (entry != null) {
      final expiry = (entry['expiryDate'] as Timestamp?)?.toDate();
      if (expiry != null && expiry.isAfter(DateTime.now())) {
        final p = (entry['planType'] as String? ?? '').trim().toLowerCase();
        if (p == 'free') return 'basic';
        const valid = {'basic', 'premium', 'business', 'enterprise'};
        if (valid.contains(p)) return p;
      }
    }
    return 'basic';
  }

  // Copy with method for updates
  UserModel copyWith({
    String? name,
    String? email,
    String? phone,
    String? avatarUrl,
    String? organization,
    String? designation,
    String? mobileNumber,
    bool? isOnApp,
    String? planType,
    DateTime? planExpiry,
    String? orgId,
    Map<String, Map<String, dynamic>>? modulePlans,
  }) {
    return UserModel(
      uid: uid,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      organization: organization ?? this.organization,
      designation: designation ?? this.designation,
      mobileNumber: mobileNumber ?? this.mobileNumber,
      createdAt: createdAt,
      isOnApp: isOnApp ?? this.isOnApp,
      planType: planType ?? this.planType,
      planExpiry: planExpiry ?? this.planExpiry,
      orgId: orgId ?? this.orgId,
      modulePlans: modulePlans ?? this.modulePlans,
    );
  }
}
