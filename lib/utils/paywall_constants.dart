import 'package:flutter/material.dart';

import '../models/task.dart';
import '../modules/sales/models/enquiry.dart';
import '../screens/settings/upgrade_screen.dart';
import 'app_links.dart';

/// Result of a plan-limit check.
class PlanLimitResult {
  final bool allowed;
  final String feature;
  final String message;
  final int current;
  final int limit;

  const PlanLimitResult({
    required this.allowed,
    required this.feature,
    required this.message,
    this.current = 0,
    this.limit = 0,
  });

  static const PlanLimitResult ok = PlanLimitResult(
    allowed: true,
    feature: '',
    message: '',
  );
}

/// Thrown when a hard plan limit blocks an action.
class PlanLimitException implements Exception {
  final String feature;
  final String message;

  const PlanLimitException(this.feature, this.message);

  @override
  String toString() => 'PlanLimitException: $message';
}

/// Paywall feature gating based on user plan type.
///
/// Two tiers, applied independently per module (task / sale / crm / inventory):
///   * basic (free)  — the default for every new account
///   * premium       — any paid plan
/// Legacy higher tiers are normalized down so existing documents and billing
/// keep working: 'business' and 'enterprise' both read as 'premium'.
/// 'free' / null / unknown read as 'basic'.
class PaywallLimits {
  PaywallLimits._();

  /// Anything that is not basic counts as a paid (premium) plan.
  static bool isPremium(String planType) =>
      normalizePlanType(planType) != 'basic';

  /// Alias used by [PremiumStatusService] and counterpart-plan gating.
  static bool isPremiumUser(String planType) => isPremium(planType);

  /// Normalize a stored plan type to one of the two gating tiers.
  static String normalizePlanType(String? planType) {
    final p = planType?.trim().toLowerCase() ?? '';
    if (p == 'premium' || p == 'business' || p == 'enterprise') return 'premium';
    return 'basic';
  }

  /// Billing website page where an individual user upgrades to Premium.
  /// Canonical URL lives in [AppLinks] with every other outward link.
  static const String upgradeUrl = AppLinks.upgrade;

  // ── Active card limits ───────────────────────────────────────────────────
  // Identical across every module; the per-module separation comes from HOW
  // the count is taken (countActiveTasks(module:)), not from a different value.
  static const Map<String, Map<String, int>> _activeTaskLimits = {
    'toAssignee': {'basic': 10, 'premium': 500},
    'byCreator': {'basic': 100, 'premium': 500},
  };

  static const Map<String, int> _maxAssigneesByTier = {
    'basic': 3,
    'premium': 10,
  };

  static const Map<String, int> _maxTeamsByTier = {
    'basic': 1,
    'premium': 5,
  };

  /// Max active cards for the given direction.
  ///
  /// [module] is retained for call-site compatibility (task/sale/crm/inventory)
  /// — every module shares the same caps; the per-module separation lives in
  /// the counting, not the limit.
  /// [asCreator] true = cards created by the user, false = cards assigned to
  /// the user.
  static int maxActiveTasks(
    String planType, {
    required String module,
    required bool asCreator,
  }) {
    final tier = normalizePlanType(planType);
    final direction = asCreator ? 'byCreator' : 'toAssignee';
    return _activeTaskLimits[direction]![tier] ?? 0;
  }

  /// Max assignees per task.
  static int maxAssignees(String planType) =>
      _maxAssigneesByTier[normalizePlanType(planType)] ?? 1;

  /// Max teams allowed per module (task/sales/CRM). Basic gets a single
  /// default team; Premium unlocks up to 5 teams.
  static int maxTeams(String planType) =>
      _maxTeamsByTier[normalizePlanType(planType)] ?? 1;

  /// Backwards-compatible alias for [maxTeams].
  static int maxSalesTeams(String planType) => maxTeams(planType);

  /// Max assignees per sales enquiry.
  static int maxSalesAssignees(String planType) => maxAssignees(planType);

  /// Whether user can export tasks.
  static bool canExport(String planType) => isPremium(planType);

  /// Whether the Reports screens are interactive. Every plan can open
  /// Reports read-only (KPI cards + breakdown tables); premium adds
  /// tap-through to the linked cards and per-section export (see [canExport]).
  static bool canInteractReports(String planType) => isPremium(planType);

  /// Plan display label.
  static String planLabel(String planType) =>
      normalizePlanType(planType) == 'premium' ? 'Premium' : 'Free';

  // ── Limit checks (used by providers) ─────────────────────────────────────

  /// Hard-block check for creating a task.
  ///
  /// Requires the current user's effective plan and the task about to be
  /// created. Checks the creator limit, each assignee's "to assignee" limit,
  /// and the max-assignee count. Returns [PlanLimitResult.ok] if allowed.
  static Future<PlanLimitResult> checkCreateTaskLimit({
    required String planType,
    required TaskModel task,
    required Future<int> Function({
      required String userId,
      bool asCreator,
      String module,
      String? creatorId,
    })
    countActiveTasks,
  }) async {
    final tier = normalizePlanType(planType);

    // Creator limit.
    final creatorLimit = maxActiveTasks(tier, module: 'task', asCreator: true);
    final creatorCount = await countActiveTasks(
      userId: task.createdBy,
      asCreator: true,
      module: 'task',
    );
    if (creatorCount >= creatorLimit) {
      return PlanLimitResult(
        allowed: false,
        feature: 'Active tasks created by you',
        current: creatorCount,
        limit: creatorLimit,
        message:
            'Your active card limit has reached. Your ${planLabel(tier)} plan allows $creatorLimit active cards created by you. Delete or change the status of active cards to make room.',
      );
    }

    // Assignee count limit.
    final assigneeUids = _taskAssigneeUids(task);
    final maxAssigneeCount = maxAssignees(tier);
    if (assigneeUids.length > maxAssigneeCount) {
      return PlanLimitResult(
        allowed: false,
        feature: 'Assignees per task',
        current: assigneeUids.length,
        limit: maxAssigneeCount,
        message:
            'This task has ${assigneeUids.length} assignees. Your ${planLabel(tier)} plan allows $maxAssigneeCount.',
      );
    }

    // Per-assignee "to assignee" limit — counted per creator (an assignee
    // may hold up to [assigneeLimit] active cards from this creator).
    for (final uid in assigneeUids) {
      if (uid.isEmpty || uid == task.createdBy) continue;
      final assigneeLimit = maxActiveTasks(
        tier,
        module: 'task',
        asCreator: false,
      );
      final assigneeCount = await countActiveTasks(
        userId: uid,
        asCreator: false,
        module: 'task',
        creatorId: task.createdBy,
      );
      if (assigneeCount >= assigneeLimit) {
        return PlanLimitResult(
          allowed: false,
          feature: 'Active tasks assigned to this user',
          current: assigneeCount,
          limit: assigneeLimit,
          message:
              'This assignee''s active card limit from you has reached ($assigneeCount of $assigneeLimit on your ${planLabel(tier)} plan). Delete or change the status of active cards to make room.',
        );
      }
    }

    return PlanLimitResult.ok;
  }

  /// Hard-block check for creating a sales/CRM enquiry.
  static Future<PlanLimitResult> checkCreateEnquiryLimit({
    required String planType,
    required EnquiryModel enquiry,
    required String module,
    required Future<int> Function({
      required String userId,
      bool asCreator,
      String module,
      String? creatorId,
    })
    countActiveTasks,
  }) async {
    final tier = normalizePlanType(planType);
    final moduleKey = module.toLowerCase();

    // Creator limit.
    final creatorLimit = maxActiveTasks(
      tier,
      module: moduleKey,
      asCreator: true,
    );
    final creatorCount = await countActiveTasks(
      userId: enquiry.createdBy,
      asCreator: true,
      module: moduleKey,
    );
    if (creatorCount >= creatorLimit) {
      return PlanLimitResult(
        allowed: false,
        feature: 'Active ${moduleKey.toUpperCase()} cards created by you',
        current: creatorCount,
        limit: creatorLimit,
        message:
            'Your active card limit has reached. Your ${planLabel(tier)} plan allows $creatorLimit active $moduleKey cards created by you. Delete or change the status of active cards to make room.',
      );
    }

    // Assignee limit (single primary assignee for enquiries) — counted per
    // creator (assignee may hold up to the limit of active cards from you).
    final assigneeUid = enquiry.assignedToUid?.trim() ?? '';
    if (assigneeUid.isNotEmpty && assigneeUid != enquiry.createdBy) {
      final assigneeLimit = maxActiveTasks(
        tier,
        module: moduleKey,
        asCreator: false,
      );
      final assigneeCount = await countActiveTasks(
        userId: assigneeUid,
        asCreator: false,
        module: moduleKey,
        creatorId: enquiry.createdBy,
      );
      if (assigneeCount >= assigneeLimit) {
        return PlanLimitResult(
          allowed: false,
          feature: 'Active $moduleKey cards assigned to this user',
          current: assigneeCount,
          limit: assigneeLimit,
          message:
              'This assignee''s active card limit from you has reached ($assigneeCount of $assigneeLimit on your ${planLabel(tier)} plan). Delete or change the status of active cards to make room.',
        );
      }
    }

    return PlanLimitResult.ok;
  }

  static List<String> _taskAssigneeUids(TaskModel task) {
    final uids = <String>{};
    if (task.assignedToUid != null && task.assignedToUid!.isNotEmpty) {
      uids.add(task.assignedToUid!);
    }
    final extraUids = task.extraFields?['assigneeUids'];
    if (extraUids is List) {
      for (final uid in extraUids) {
        if (uid is String && uid.isNotEmpty) uids.add(uid);
      }
    }
    final participantUids = task.participants;
    for (final uid in participantUids) {
      if (uid.isNotEmpty && uid != task.createdBy) uids.add(uid);
    }
    return uids.toList();
  }
}

/// Show an upgrade dialog when a user hits a paywall limit.
///
/// The wording is intentionally neutral (no payment URL) to stay within Google
/// Play's external-billing policy: the app only says the limit is reached and
/// that a paid plan unlocks more. The actual upgrade path is in Settings.
Future<bool> showPaywallDialog(
  BuildContext context, {
  required String feature,
  String? detail,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.workspace_premium,
              color: Colors.amber,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Plan Limit Reached',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            feature,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.amber, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Upgrade your plan in Settings to unlock more.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not Now'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('Upgrade'),
        ),
      ],
    ),
  );
  // Take the user to the upgrade screen when they tap Upgrade.
  if (result == true && context.mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UpgradeScreen()),
    );
  }
  return result == true;
}

/// Convenience wrapper that shows the dialog from a [PlanLimitResult].
Future<bool> showPlanLimitDialog(
  BuildContext context,
  PlanLimitResult result,
) =>
    showPaywallDialog(context, feature: result.feature, detail: result.message);
