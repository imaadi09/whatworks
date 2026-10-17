import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/constants.dart';
import '../../utils/paywall_constants.dart';

/// B2C upgrade screen: shows Premium benefits and sends the user to the
/// billing website to purchase. No payment processing happens in the app;
/// the plan lands on users/{uid}.planType after purchase.
class UpgradeScreen extends StatelessWidget {
  const UpgradeScreen({super.key});

  /// Derived from [PaywallLimits] rather than typed out, because the two drifted
  /// apart once already: this list advertised "500 MB" while the enforced quota
  /// was 1 GB. The website quotes the same numbers, so they must come from the
  /// limits that are actually applied.
  static List<String> get _benefits => [
    'Up to ${PaywallLimits.maxActiveTasks('premium', module: 'task', asCreator: true)} active cards created by you',
    'Multiple assignees (up to ${PaywallLimits.maxAssignees('premium')}) with switching',
    'Up to ${PaywallLimits.maxTeams('premium')} teams per module',
    'Auto backup',
    'Dashboard & Reports',
    'Export to CSV/PDF',
  ];

  Future<void> _openBillingWebsite(BuildContext context) async {
    final uri = Uri.parse(PaywallLimits.upgradeUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the upgrade page.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Upgrade to Premium'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Go Premium',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Premium is a per-user plan — ₹149 per module per month, or '
                  '₹1,188 per module per year (+GST extra). Business adds '
                  'larger team limits (up to 20 teams) at ₹249 per module '
                  'per month.',
                  style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
                ),
                const Divider(height: 24),
                ..._benefits.map(
                  (b) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: AppTheme.primaryGreen,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            b,
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppTheme.primaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () => _openBillingWebsite(context),
              icon: const Icon(Icons.open_in_new, size: 20),
              label: const Text(
                'Upgrade on our website',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
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
                    'Your plan activates automatically after purchase.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
