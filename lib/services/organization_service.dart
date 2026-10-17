import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/organization.dart';
import '../models/org_member.dart';
import '../models/payment_record.dart';

/// Reads organization/subscription data and wraps the seat-management
/// Cloud Functions.
///
/// The website (Admin SDK) owns the subscription fields; the app reads them
/// and joins/leaves seats through callable functions that enforce the seat
/// cap atomically.
class OrganizationService {
  OrganizationService();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  CollectionReference<Map<String, dynamic>> _orgs() =>
      _firestore.collection('organizations');

  DocumentReference<Map<String, dynamic>> _orgDoc(String orgId) =>
      _orgs().doc(orgId);

  // ── Reads ───────────────────────────────────────────────────────────────

  Future<OrganizationModel?> getOrganization(String orgId) async {
    final doc = await _orgDoc(orgId).get();
    if (!doc.exists || doc.data() == null) return null;
    return OrganizationModel.fromMap(doc.data()!, doc.id);
  }

  Stream<OrganizationModel?> streamOrganization(String orgId) {
    return _orgDoc(orgId).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) return null;
      return OrganizationModel.fromMap(doc.data()!, doc.id);
    });
  }

  Future<OrgMemberModel?> getMember(String orgId, String uid) async {
    final doc = await _orgDoc(orgId).collection('members').doc(uid).get();
    if (!doc.exists || doc.data() == null) return null;
    return OrgMemberModel.fromMap(doc.data()!, doc.id);
  }

  Stream<List<OrgMemberModel>> streamMembers(String orgId) {
    return _orgDoc(orgId)
        .collection('members')
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => OrgMemberModel.fromMap(d.data(), d.id))
            .toList());
  }

  /// Payment history (admin only per security rules).
  Stream<List<PaymentRecord>> streamPayments(String orgId) {
    return _orgDoc(orgId)
        .collection('payments')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => PaymentRecord.fromMap(d.data(), d.id))
            .toList());
  }

  // ── Writes: app-owned org fields ─────────────────────────────────────────

  /// Update the org display name (admins only, enforced by rules).
  Future<void> updateName(String orgId, String name) async {
    await _orgDoc(orgId).update({
      'name': name,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Cloud Function wrappers ──────────────────────────────────────────────

  /// Join an organization by its short code. Occupies a seat atomically.
  /// Returns the resolved orgId on success. Throws [OrganizationException]
  /// with a friendly message on failure (seat full, expired, not found).
  Future<String> joinByCode(String orgCode) async {
    try {
      final callable = _functions.httpsCallable('joinOrganization');
      final result = await callable.call<Map<String, dynamic>>({
        'orgCode': orgCode.trim(),
      });
      final data = result.data;
      final orgId = data['orgId']?.toString();
      if (orgId == null || orgId.isEmpty) {
        throw const OrganizationException('Could not join the organization.');
      }
      return orgId;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationException(_messageFor(e));
    }
  }

  /// Revoke a member's seat (admin only). Frees the seat for reuse.
  Future<void> revokeSeat(String orgId, String uid) async {
    try {
      final callable = _functions.httpsCallable('revokeMember');
      await callable.call<Map<String, dynamic>>({
        'orgId': orgId,
        'uid': uid,
      });
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationException(_messageFor(e));
    }
  }

  String _messageFor(FirebaseFunctionsException e) {
    // Prefer the server-provided message when present.
    if (e.message != null && e.message!.isNotEmpty) return e.message!;
    switch (e.code) {
      case 'not-found':
        return 'No organization found with that code.';
      case 'resource-exhausted':
        return 'All seats are currently in use. Ask an admin to free a seat.';
      case 'failed-precondition':
        return 'This subscription is not active.';
      case 'already-exists':
        return 'You are already a member of this organization.';
      case 'permission-denied':
        return 'You are not allowed to perform this action.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}

/// User-facing error from an organization operation.
class OrganizationException implements Exception {
  final String message;
  const OrganizationException(this.message);

  @override
  String toString() => message;
}
