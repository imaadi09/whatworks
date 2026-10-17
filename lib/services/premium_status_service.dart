import '../models/user.dart';
import '../utils/helpers.dart';
import '../utils/paywall_constants.dart';
import 'local_database_service.dart';

/// In-memory Premium/Basic lookup for badge rendering and paywall gates.
///
/// Populated from two sources:
/// - SQLite users cache at startup ([ensureLoaded]) so badges work offline
/// - Fresh Firestore user list on every contact sync ([updateFromUsers])
///
/// Lookups are synchronous so cards/pickers can query during build.
class PremiumStatusService {
  static final PremiumStatusService _instance =
      PremiumStatusService._internal();
  factory PremiumStatusService() => _instance;
  PremiumStatusService._internal();

  final Set<String> _premiumUids = {};
  final Set<String> _premiumPhones = {};
  bool _loaded = false;

  /// Load premium sets from the SQLite users cache (once per session).
  /// Safe to call repeatedly — subsequent calls are no-ops.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final rows = await LocalDatabaseService().getCachedUserPlans();
      for (final row in rows) {
        final planType = (row['planType'] as String?) ?? '';
        if (!PaywallLimits.isPremiumUser(planType)) continue;
        final uid = (row['uid'] as String?)?.trim() ?? '';
        if (uid.isNotEmpty) _premiumUids.add(uid);
        final phone = Helpers.normalizePhone(row['phone'] as String?) ?? '';
        if (phone.isNotEmpty) _premiumPhones.add(phone);
      }
    } catch (e) {
      print('[PremiumStatus] Failed to load cached plans: $e');
    }
  }

  /// Replace the premium sets from a fresh full user list (contact sync).
  /// getAllUsers returns every user, so replace semantics are correct.
  void updateFromUsers(List<UserModel> users) {
    _loaded = true;
    _premiumUids.clear();
    _premiumPhones.clear();
    for (final user in users) {
      // effectivePlanType, not planType: an expired paid plan must not keep
      // showing a crown to everyone else.
      if (!PaywallLimits.isPremiumUser(user.effectivePlanType)) continue;
      if (user.uid.trim().isNotEmpty) _premiumUids.add(user.uid.trim());
      final phone = Helpers.normalizePhone(user.phone) ?? '';
      if (phone.isNotEmpty) _premiumPhones.add(phone);
    }
  }

  /// True if the person identified by [uid] and/or [phone] is premium.
  bool isPremium({String? uid, String? phone}) {
    final u = uid?.trim() ?? '';
    if (u.isNotEmpty && _premiumUids.contains(u)) return true;
    final p = Helpers.normalizePhone(phone) ?? '';
    return p.isNotEmpty && _premiumPhones.contains(p);
  }
}
