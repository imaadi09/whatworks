import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/organization.dart';
import '../models/org_member.dart';
import '../models/payment_record.dart';
import '../services/organization_service.dart';

/// Holds the current organization, its members and payment history for the
/// Organization settings screen. Subscription fields are website-owned and
/// read-only here; this provider only manages joining/leaving seats.
class OrganizationProvider extends ChangeNotifier {
  final OrganizationService _service = OrganizationService();

  String? _orgId;
  String? _currentUid;
  OrganizationModel? _organization;
  List<OrgMemberModel> _members = const [];
  List<PaymentRecord> _payments = const [];
  bool _isLoading = false;
  bool _isBusy = false; // join/revoke in flight
  String? _errorMessage;

  StreamSubscription? _orgSub;
  StreamSubscription? _membersSub;
  StreamSubscription? _paymentsSub;

  String? get orgId => _orgId;
  OrganizationModel? get organization => _organization;
  List<OrgMemberModel> get members => _members;
  List<PaymentRecord> get payments => _payments;
  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get errorMessage => _errorMessage;
  bool get hasOrg => _orgId != null && _organization != null;

  /// True when the current user is an owner/admin of the loaded org.
  bool get isAdmin {
    final uid = _currentUid;
    final org = _organization;
    if (uid == null || org == null) return false;
    return org.isAdmin(uid);
  }

  /// Start listening to an organization's data. Safe to call repeatedly.
  void load(String orgId, String currentUid) {
    if (_orgId == orgId && _organization != null) {
      _currentUid = currentUid;
      return;
    }
    _clearSubscriptions();
    _orgId = orgId;
    _currentUid = currentUid;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    _orgSub = _service.streamOrganization(orgId).listen((org) {
      _organization = org;
      _isLoading = false;
      notifyListeners();
    }, onError: (e) {
      _errorMessage = 'Failed to load organization.';
      _isLoading = false;
      notifyListeners();
    });

    _membersSub = _service.streamMembers(orgId).listen((members) {
      members.sort((a, b) => a.displayName
          .toLowerCase()
          .compareTo(b.displayName.toLowerCase()));
      _members = members;
      notifyListeners();
    }, onError: (_) {});

    // Payments are admin-only; a permission error simply yields no data.
    _paymentsSub = _service.streamPayments(orgId).listen((payments) {
      _payments = payments;
      notifyListeners();
    }, onError: (_) {
      _payments = const [];
    });
  }

  /// Join an organization by code. Returns the orgId on success, or null on
  /// failure (with [errorMessage] set).
  Future<String?> join(String orgCode, String currentUid) async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final newOrgId = await _service.joinByCode(orgCode);
      _isBusy = false;
      notifyListeners();
      load(newOrgId, currentUid);
      return newOrgId;
    } on OrganizationException catch (e) {
      _errorMessage = e.message;
      _isBusy = false;
      notifyListeners();
      return null;
    } catch (_) {
      _errorMessage = 'Something went wrong. Please try again.';
      _isBusy = false;
      notifyListeners();
      return null;
    }
  }

  /// Revoke a member's seat (admin only). Returns true on success.
  Future<bool> revoke(String uid) async {
    final orgId = _orgId;
    if (orgId == null) return false;
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _service.revokeSeat(orgId, uid);
      _isBusy = false;
      notifyListeners();
      return true;
    } on OrganizationException catch (e) {
      _errorMessage = e.message;
      _isBusy = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Something went wrong. Please try again.';
      _isBusy = false;
      notifyListeners();
      return false;
    }
  }

  /// Update the organization display name (admin only).
  Future<bool> rename(String name) async {
    final orgId = _orgId;
    if (orgId == null || name.trim().isEmpty) return false;
    try {
      await _service.updateName(orgId, name.trim());
      return true;
    } catch (_) {
      _errorMessage = 'Failed to update name.';
      notifyListeners();
      return false;
    }
  }

  /// Clear all state (e.g. on sign-out).
  void clear() {
    _clearSubscriptions();
    _orgId = null;
    _currentUid = null;
    _organization = null;
    _members = const [];
    _payments = const [];
    _isLoading = false;
    _isBusy = false;
    _errorMessage = null;
    notifyListeners();
  }

  void _clearSubscriptions() {
    _orgSub?.cancel();
    _membersSub?.cancel();
    _paymentsSub?.cancel();
    _orgSub = null;
    _membersSub = null;
    _paymentsSub = null;
  }

  @override
  void dispose() {
    _clearSubscriptions();
    super.dispose();
  }
}
