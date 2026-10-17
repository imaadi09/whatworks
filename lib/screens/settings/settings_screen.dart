import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:io';
import '../../providers/auth_provider.dart';
import '../../services/notification_service.dart';
import '../../services/business_vocabulary.dart';
import '../../services/sync_telemetry.dart';
import '../../utils/app_links.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/sector_picker.dart';
import 'profile_edit_screen.dart';
import 'change_phone_screen.dart';
import 'backup_restore_screen.dart';
import 'organization_screen.dart';
import 'upgrade_screen.dart';
import 'security_screen.dart';
import 'diagnostics_screen.dart';

/// Temporary kill-switch for the hidden Developer settings section and its
/// version-row 5-tap unlock (mirrors `kSectorTemplatesEnabled`). Set to true to
/// restore the diagnostics entry point — no other change is needed and no
/// persisted state is involved, so the unlock keeps working on re-enable.
const bool kDeveloperMenuEnabled = false;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _taskReminders = true;
  bool _deadlineAlerts = true;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;

  // Per-type message/reminder push toggles. Mirrored to the user's Firestore
  // notifPrefs map so the push Cloud Function can suppress a disabled type even
  // while the app is closed (the client toggle alone only gates foreground).
  bool _taskMsgs = true;
  bool _salesMsgs = true;
  bool _crmMsgs = true;
  bool _callReminds = true;

  // Active "business type" (sector archetype) shown on its Preferences tile.
  // Resolved synchronously from the startup-loaded [BusinessVocabulary] cache.
  String _businessTypeLabel = 'General / Other';

  // Hidden developer-diagnostics unlock: tap the version row 5x in quick
  // succession. The burst is debounced so the modal About dialog doesn't
  // swallow the rapid taps (a lone tap still opens About, after the window).
  int _diagTapCount = 0;
  Timer? _diagTapTimer;

  // Real version off the installed bundle, so About and bug reports can never
  // drift from what the user actually has. Empty until the async load lands.
  String _appVersion = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadNotificationPrefs();
    _loadAppVersion();
    _loadBusinessType();
  }

  void _loadBusinessType() {
    if (!mounted) return;
    setState(
      () =>
          _businessTypeLabel =
              BusinessVocabulary.current?.label ?? 'General / Other',
    );
  }

  /// Sector-archetype chooser. The picker UI + apply logic live in the shared
  /// [showSectorPicker] (also used by the drawer's top-level "Sector" item) so
  /// the two entry points can't drift; this only refreshes the tile label and
  /// confirms the change. Changing the sector re-labels module vocabularies and
  /// re-seeds milestone TEMPLATES (only NEW cards pick them up) — existing
  /// items keep their milestones, so it is always safe to change.
  Future<void> _showBusinessTypeDialog() async {
    final appliedId = await showSectorPicker(context);
    if (appliedId == null || !mounted) return;
    setState(
      () =>
          _businessTypeLabel =
              BusinessVocabulary.current?.label ?? 'General / Other',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Business type set to $_businessTypeLabel. New items use it; '
          'existing ones keep their setup.',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _diagTapTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _appVersion = info.version;
      _buildNumber = info.buildNumber;
    });
  }

  /// "1.0.0 (3)" once loaded. The build number matters in bug reports — two
  /// APKs can share a version name but behave differently.
  String get _versionLabel {
    if (_appVersion.isEmpty) return '…';
    return _buildNumber.isEmpty ? _appVersion : '$_appVersion ($_buildNumber)';
  }

  Future<void> _loadNotificationPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled =
          prefs.getBool(NotificationService.prefPushEnabled) ?? true;
      _taskReminders =
          prefs.getBool(NotificationService.prefTaskReminders) ?? true;
      _deadlineAlerts =
          prefs.getBool(NotificationService.prefDeadlineAlerts) ?? true;
      _soundEnabled = prefs.getBool(NotificationService.prefSound) ?? true;
      _vibrationEnabled =
          prefs.getBool(NotificationService.prefVibration) ?? true;
      _taskMsgs = prefs.getBool(NotificationService.prefTaskMessages) ?? true;
      _salesMsgs = prefs.getBool(NotificationService.prefSalesMessages) ?? true;
      _crmMsgs = prefs.getBool(NotificationService.prefCrmMessages) ?? true;
      _callReminds =
          prefs.getBool(NotificationService.prefCallReminders) ?? true;
    });
  }

  Future<void> _saveNotificationPref(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Names of the user-defined header fields shown under the urgency
  /// badge on task and enquiry cards (blank name = field hidden).
  Future<void> _editCustomFieldLabels() async {
    final prefs = await SharedPreferences.getInstance();
    final c1 = TextEditingController(
      text: prefs.getString('customFieldLabel1') ?? '',
    );
    final c2 = TextEditingController(
      text: prefs.getString('customFieldLabel2') ?? '',
    );
    final c3 = TextEditingController(
      text: prefs.getString('customFieldLabel3') ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom fields'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Name the extra fields shown under the urgency badge on task and enquiry cards. Values are typed on each card; leave a name blank to hide that field.',
              style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c1,
              maxLength: 20,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Field 1 name',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c2,
              maxLength: 20,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Field 2 name',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c3,
              maxLength: 20,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Field 3 name',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    await prefs.setString('customFieldLabel1', c1.text.trim());
    await prefs.setString('customFieldLabel2', c2.text.trim());
    await prefs.setString('customFieldLabel3', c3.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.userModel;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Settings'),
            // Premium badge
            if (PaywallLimits.isPremium(authProvider.effectivePlanType)) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.amber.withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.workspace_premium,
                      size: 12,
                      color: Colors.amber.shade800,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'PRO',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber.shade800,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        children: [
          // Profile Section
          _buildProfileSection(user),

          const SizedBox(height: 12),

          // Account Section
          _buildCategory(
            icon: Icons.person_outline,
            title: 'Account',
            summary: 'Profile, workspace, security, storage & fields',
            initiallyExpanded: true,
            children: [
            _buildSettingTile(
              icon: Icons.person_outline,
              title: 'Edit Profile',
              subtitle: 'Update your personal information',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ProfileEditScreen(),
                  ),
                );
              },
            ),
            _buildSettingTile(
              icon: Icons.swap_horiz,
              title: 'Change Phone Number',
              subtitle: 'Switch login number — all data moves with you',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ChangePhoneScreen(),
                  ),
                );
              },
            ),
            // B2C upgrade entry — only for Basic users.
            if (!PaywallLimits.isPremiumUser(authProvider.effectivePlanType))
              _buildSettingTile(
                icon: Icons.workspace_premium,
                iconColor: Colors.amber,
                title: 'Upgrade to Premium',
                subtitle: 'Unlock exports, reports & more',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const UpgradeScreen(),
                    ),
                  );
                },
              ),
            _buildSettingTile(
              icon: Icons.business_outlined,
              title: 'Workspace',
              subtitle: 'Team members & join code',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const OrganizationScreen(),
                  ),
                );
              },
            ),
            // Categories are managed per module from each module's
            // 3-dot menu → TOOLS → Category Settings.
            _buildSettingTile(
              icon: Icons.security,
              title: 'Security',
              subtitle: 'App lock (PIN)',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SecurityScreen(),
                  ),
                );
              },
            ),
            _buildSettingTile(
              icon: Icons.storage,
              title: 'Storage',
              subtitle: 'View device storage usage, clear cache',
              onTap: () {
                _showStorageDialog();
              },
            ),
            _buildSettingTile(
              icon: Icons.backup_outlined,
              title: 'Backup & Restore',
              subtitle: 'Export or import encrypted backup',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const BackupRestoreScreen(),
                  ),
                );
              },
            ),
            const Divider(height: 1),
            // Relocated from the old Preferences section (user request) — these
            // are real feature entry points, so they live under Account now.
            _buildSettingTile(
              icon: Icons.text_fields,
              title: 'Custom fields',
              subtitle: 'Name two extra fields on task & enquiry headers',
              onTap: _editCustomFieldLabels,
            ),
            if (kSectorTemplatesEnabled) ...[
              const Divider(height: 1),
              _buildSettingTile(
                icon: Icons.storefront_outlined,
                title: 'Business type',
                subtitle: _businessTypeLabel,
                onTap: _showBusinessTypeDialog,
              ),
            ],
            ],
          ),

          // Notifications Section
          _buildCategory(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            summary: 'Push, reminders, alerts, sound & vibration',
            children: [
            _buildSwitchTile(
              icon: Icons.notifications_outlined,
              title: 'Push Notifications',
              subtitle: 'Receive task notifications',
              value: _notificationsEnabled,
              onChanged: (value) {
                setState(() {
                  _notificationsEnabled = value;
                });
                _saveNotificationPref(
                  NotificationService.prefPushEnabled,
                  value,
                );
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.task_alt,
              title: 'Task messages',
              subtitle: 'Notify on new Task chat messages',
              value: _taskMsgs,
              onChanged: (value) {
                setState(() {
                  _taskMsgs = value;
                });
                _saveNotificationPref(
                  NotificationService.prefTaskMessages,
                  value,
                );
                NotificationService().syncNotifPrefsToFirestore();
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.storefront_outlined,
              title: 'Sales messages',
              subtitle: 'Notify on new Sales chat messages',
              value: _salesMsgs,
              onChanged: (value) {
                setState(() {
                  _salesMsgs = value;
                });
                _saveNotificationPref(
                  NotificationService.prefSalesMessages,
                  value,
                );
                NotificationService().syncNotifPrefsToFirestore();
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.support_agent_outlined,
              title: 'CRM messages',
              subtitle: 'Notify on new Service/CRM chat messages',
              value: _crmMsgs,
              onChanged: (value) {
                setState(() {
                  _crmMsgs = value;
                });
                _saveNotificationPref(
                  NotificationService.prefCrmMessages,
                  value,
                );
                NotificationService().syncNotifPrefsToFirestore();
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.phone_enabled,
              title: 'Scheduled calls',
              subtitle: 'Notify when a scheduled call is due',
              value: _callReminds,
              onChanged: (value) {
                setState(() {
                  _callReminds = value;
                });
                _saveNotificationPref(
                  NotificationService.prefCallReminders,
                  value,
                );
                NotificationService().syncNotifPrefsToFirestore();
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.access_alarm,
              title: 'Task Reminders',
              subtitle: 'Get reminded about pending tasks',
              value: _taskReminders,
              onChanged: (value) {
                setState(() {
                  _taskReminders = value;
                });
                _saveNotificationPref(
                  NotificationService.prefTaskReminders,
                  value,
                );
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.event_busy,
              title: 'Deadline Alerts',
              subtitle: 'Alerts for upcoming deadlines',
              value: _deadlineAlerts,
              onChanged: (value) {
                setState(() {
                  _deadlineAlerts = value;
                });
                _saveNotificationPref(
                  NotificationService.prefDeadlineAlerts,
                  value,
                );
              },
            ),
            const Divider(height: 1),
            // Relocated from the old Preferences section — sound & vibration
            // are notification behaviours, so they belong here.
            _buildSwitchTile(
              icon: Icons.volume_up_outlined,
              title: 'Sound',
              subtitle: 'Play sound for notifications',
              value: _soundEnabled,
              onChanged: (value) {
                setState(() {
                  _soundEnabled = value;
                });
                _saveNotificationPref(NotificationService.prefSound, value);
              },
            ),
            const Divider(height: 1),
            _buildSwitchTile(
              icon: Icons.vibration,
              title: 'Vibration',
              subtitle: 'Vibrate for notifications',
              value: _vibrationEnabled,
              onChanged: (value) {
                setState(() {
                  _vibrationEnabled = value;
                });
                _saveNotificationPref(NotificationService.prefVibration, value);
              },
            ),
            ],
          ),

          // Support Section
          _buildCategory(
            icon: Icons.help_outline,
            title: 'Support',
            summary: 'Help center, bug reports & about',
            children: [
            _buildSettingTile(
              icon: Icons.help_outline,
              title: 'Help Center',
              subtitle: 'FAQs and guides',
              onTap: _openHelpCenter,
            ),
            const Divider(height: 1),
            _buildSettingTile(
              icon: Icons.bug_report_outlined,
              title: 'Report a Bug',
              subtitle: 'Help us improve',
              onTap: _reportBug,
            ),
            const Divider(height: 1),
            _buildSettingTile(
              icon: Icons.lightbulb_outline,
              title: 'Submit Feature Request',
              subtitle: 'Tell us what to build next',
              onTap: _requestFeature,
            ),
            const Divider(height: 1),
            _buildSettingTile(
              icon: Icons.chat,
              iconColor: const Color(0xFF25D366),
              title: 'WhatsApp Us',
              subtitle: 'Quick response: ${AppLinks.supportWhatsAppDisplay}',
              onTap: _chatOnWhatsApp,
            ),
            const Divider(height: 1),
            _buildSettingTile(
              icon: Icons.info_outline,
              title: 'About',
              subtitle: 'Version $_versionLabel',
              onTap: _onAboutTap,
            ),
            ],
          ),

          // Privacy & Legal Section — surfaces the data-minimisation and
          // liability declarations. The full text lives on whatworks.pro (the
          // same pages the login footer links to); these tiles open them.
          _buildCategory(
            icon: Icons.shield_outlined,
            title: 'Privacy & Legal',
            summary: 'How your data is handled & our liability',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  'Your tasks, messages and files live on your own devices. We '
                  'act only as a delivery channel — server copies are deleted '
                  'automatically after delivery, and our liability for data '
                  'loss is limited. Read the full policy and terms below.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.secondaryText,
                    height: 1.35,
                  ),
                ),
              ),
              const Divider(height: 1),
              _buildSettingTile(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy Policy',
                subtitle: 'What we collect — and what we never store',
                onTap: _openPrivacyPolicy,
              ),
              const Divider(height: 1),
              _buildSettingTile(
                icon: Icons.description_outlined,
                title: 'Terms of Use',
                subtitle: 'Your agreement & our limitation of liability',
                onTap: _openTermsOfUse,
              ),
            ],
          ),

          // Developer Section — hidden until the version row is tapped 5x, and
          // fully suppressed while kDeveloperMenuEnabled is false.
          if (kDeveloperMenuEnabled && SyncTelemetry.instance.unlocked)
            _buildCategory(
              icon: Icons.speed,
              title: 'Developer',
              summary: 'Live DB / sync / Firestore load telemetry',
              children: [
                _buildSettingTile(
                  icon: Icons.speed,
                  title: 'Diagnostics',
                  subtitle: 'Live DB / sync / Firestore load telemetry',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DiagnosticsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),

          // Sign Out Section
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _buildSettingTile(
              icon: Icons.logout,
              title: 'Sign Out',
              titleColor: Colors.red,
              onTap: () {
                _showSignOutDialog();
              },
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildProfileSection(user) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              // Profile Avatar
              GestureDetector(
                onTap: () {
                  // TODO: Change profile picture
                },
                child: Stack(
                  children: [
                    // Preset `avatar:<id>` / photo URL / initials fallback
                    AppAvatar(
                      avatarUrl: user?.avatarUrl,
                      initials:
                          user?.name?.substring(0, 1).toUpperCase() ?? 'U',
                      radius: 35,
                      color: AppTheme.headerGreen,
                      fontSize: 32,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: AppTheme.primaryGreen,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // User Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.name ?? 'User',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user?.email ?? '',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                    if (user?.designation != null ||
                        user?.organization != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (user?.designation != null) user!.designation,
                          if (user?.organization != null)
                            'at ${user!.organization}',
                        ].join(' '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Edit Button
              IconButton(
                icon: const Icon(Icons.edit, color: AppTheme.headerGreen),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ProfileEditScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          _buildPlanStatus(user),
        ],
      ),
    );
  }

  Widget _buildPlanStatus(user) {
    final authProvider = context.read<AuthProvider>();
    final planType = authProvider.effectivePlanType;
    final isPremium = PaywallLimits.isPremiumUser(planType);
    final label = PaywallLimits.planLabel(planType);
    final DateTime? expiry = user?.planExpiry;

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isPremium
            ? Colors.amber.withValues(alpha: 0.12)
            : AppTheme.headerGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPremium
              ? Colors.amber.withValues(alpha: 0.4)
              : AppTheme.headerGreen.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isPremium ? Icons.workspace_premium : Icons.star_border,
            color: isPremium ? Colors.amber[700] : AppTheme.headerGreen,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPremium ? '$label Membership' : '$label Plan',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  expiry != null
                      ? 'Valid till ${Helpers.formatDate(expiry)}'
                      : (isPremium
                            ? 'Active'
                            : 'Upgrade to unlock premium features'),
                  style: TextStyle(
                    fontSize: 12,
                    color: expiry != null && expiry.isBefore(DateTime.now())
                        ? Colors.red
                        : AppTheme.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _openUpgradeWebsite,
            style: ElevatedButton.styleFrom(
              backgroundColor: isPremium
                  ? Colors.amber[700]
                  : AppTheme.headerGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(isPremium ? 'Extend' : 'Upgrade'),
          ),
        ],
      ),
    );
  }

  Future<void> _openUpgradeWebsite() async {
    final uri = Uri.parse(PaywallLimits.upgradeUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the upgrade page.')),
      );
    }
  }

  Future<void> _openHelpCenter() async {
    final ok = await AppLinks.open(AppLinks.help);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the Help Center.')),
      );
    }
  }

  /// Opens the mail app with diagnostics pre-filled. Version, OS build and UID
  /// are what make a report actionable and no user can be expected to dig them
  /// out; the separator line asks them not to delete it. A device with no mail
  /// app gets the address on the clipboard rather than a dead tap.
  Future<void> _reportBug() async {
    final user = context.read<AuthProvider>().userModel;
    final body = StringBuffer()
      ..writeln('Describe what went wrong:')
      ..writeln()
      ..writeln()
      ..writeln('--- please keep the details below ---')
      ..writeln('App: ${AppConstants.appName} $_versionLabel')
      ..writeln(
        'Device: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln('User: ${user?.uid ?? 'not signed in'}')
      ..writeln('Phone: ${user?.phone ?? '-'}');

    final ok = await AppLinks.openSupportEmail(
      subject: 'Bug report — ${AppConstants.appName} $_versionLabel',
      body: body.toString(),
    );
    if (ok || !mounted) return;

    await Clipboard.setData(const ClipboardData(text: AppLinks.supportEmail));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No mail app found — ${AppLinks.supportEmail} copied to clipboard',
        ),
      ),
    );
  }

  /// Ideas ride the same mailbox as bugs (one queue to read) but get their own
  /// subject so the inbox can filter them, and a body that asks for the desired
  /// outcome instead of reproduction steps. No device diagnostics — a feature
  /// request is actionable without them.
  Future<void> _requestFeature() async {
    final body = StringBuffer()
      ..writeln('What should the app do?')
      ..writeln()
      ..writeln()
      ..writeln('Where would you use it (WorkTracker / Sales / CRM / Service)?')
      ..writeln();

    final ok = await AppLinks.openSupportEmail(
      subject: 'Feature request — ${AppConstants.appName} $_versionLabel',
      body: body.toString(),
    );
    if (ok || !mounted) return;

    await Clipboard.setData(const ClipboardData(text: AppLinks.supportEmail));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No mail app found — ${AppLinks.supportEmail} copied to clipboard',
        ),
      ),
    );
  }

  /// Chat is the quickest way to reach support, so the prefilled note carries
  /// just enough to act on (app version + account) without a mail round-trip.
  /// If WhatsApp is missing the number itself is already visible in the tile
  /// subtitle, so the failure path only has to say what went wrong.
  Future<void> _chatOnWhatsApp() async {
    final user = context.read<AuthProvider>().userModel;
    final message =
        '${AppConstants.appName} $_versionLabel\n'
        'Account: ${user?.phone ?? user?.uid ?? 'not signed in'}\n'
        'I need help with: ';

    final ok = await AppLinks.openSupportWhatsApp(message);
    if (ok || !mounted) return;

    await Clipboard.setData(
      const ClipboardData(text: AppLinks.supportWhatsAppDisplay),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'WhatsApp not available — ${AppLinks.supportWhatsAppDisplay} copied',
        ),
      ),
    );
  }

  /// A collapsible settings category. Shows a single header row (icon + title +
  /// one-line summary) that expands in place to reveal its sub-menu items. This
  /// turns the long, exhaustive flat list into tap-to-open groups so only the
  /// categories are visible at a glance.
  Widget _buildCategory({
    required IconData icon,
    required String title,
    required String summary,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        // Drop the default ExpansionTile dividers so the group reads as one
        // rounded card.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon, color: AppTheme.headerGreen),
          title: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.primaryText,
            ),
          ),
          subtitle: Text(
            summary,
            style: const TextStyle(fontSize: 12, color: AppTheme.secondaryText),
          ),
          children: children,
        ),
      ),
    );
  }

  Widget _buildSettingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? titleColor,
    Color? iconColor,
    VoidCallback? onTap,
    bool premiumLocked = false,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AppTheme.headerGreen),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                color: titleColor ?? AppTheme.primaryText,
                fontWeight: titleColor != null
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
          if (premiumLocked) _buildPremiumTag(),
        ],
      ),
      subtitle: subtitle != null
          ? Text(subtitle, style: const TextStyle(fontSize: 13))
          : null,
      trailing: const Icon(Icons.chevron_right, color: AppTheme.lightText),
      onTap: onTap,
    );
  }

  /// Small amber "Premium" pill shown on settings rows whose full capability is
  /// gated behind the paywall (only rendered for non-premium users).
  Widget _buildPremiumTag() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium, size: 11, color: Colors.amber.shade800),
          const SizedBox(width: 3),
          Text(
            'Premium',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Colors.amber.shade800,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.headerGreen),
      title: Text(
        title,
        style: const TextStyle(fontSize: 16, color: AppTheme.primaryText),
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.primaryGreen,
      ),
    );
  }

  /// Opens the outward legal pages. Reuses [AppLinks] so the domain lives in
  /// one place; both fall back to the same graceful "couldn't open" toast as
  /// every other external link in the app.
  Future<void> _openPrivacyPolicy() => _openLegalLink(AppLinks.privacy);
  Future<void> _openTermsOfUse() => _openLegalLink(AppLinks.terms);

  Future<void> _openLegalLink(String url) async {
    final ok = await AppLinks.open(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the page.')),
      );
    }
  }

  /// Recursively sum file sizes; returns 0 if the directory is missing.
  Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showStorageDialog() async {
    // Measure real on-device usage before opening the dialog
    final docsDir = await getApplicationDocumentsDirectory();
    final dbFile = File('${docsDir.path}/whatworks_local.db');
    final dbSize = await dbFile.exists() ? await dbFile.length() : 0;
    final attachmentsSize = await _dirSize(
      Directory('${docsDir.path}/attachments'),
    );
    // Auto-backups live inside app data (documents/backups) and count towards
    // Android's "Data" line, so surface them here — otherwise that number grows
    // with every backup and nothing in the app explains it.
    final backupsSize = await _dirSize(Directory('${docsDir.path}/backups'));
    final tempDir = await getTemporaryDirectory();
    final cacheSize = await _dirSize(tempDir);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Storage'),
        // Scrollable: the size breakdown now has one row per storage bucket,
        // and at a large accessibility font scale a fixed Column would overflow
        // the dialog on a small phone.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On this device',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text('Local database: ${_formatBytes(dbSize)}'),
              const SizedBox(height: 4),
              Text('Attachments: ${_formatBytes(attachmentsSize)}'),
              const SizedBox(height: 4),
              Text('Backups: ${_formatBytes(backupsSize)}'),
              const SizedBox(height: 4),
              Text('Temporary cache: ${_formatBytes(cacheSize)}'),
              const SizedBox(height: 8),
              const Text(
                'Clearing cache removes temporary files (exports, previews) but keeps your tasks and attachments.',
                style: TextStyle(fontSize: 13),
              ),
              if (backupsSize > 0) ...[
                const SizedBox(height: 4),
                const Text(
                  'Backups holds the 2 newest auto-backups (database and settings only).',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // Delete temp-dir contents only — user data is untouched
              var freed = 0;
              try {
                await for (final entity in tempDir.list(followLinks: false)) {
                  try {
                    if (entity is File) {
                      freed += await entity.length();
                      await entity.delete();
                    } else if (entity is Directory) {
                      freed += await _dirSize(entity);
                      await entity.delete(recursive: true);
                    }
                  } catch (_) {}
                }
              } catch (_) {}
              if (!mounted) return;
              ScaffoldMessenger.of(this.context).showSnackBar(
                SnackBar(
                  content: Text('Cache cleared (${_formatBytes(freed)} freed)'),
                ),
              );
            },
            child: const Text(
              'Clear Cache',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  /// Hidden unlock for the developer diagnostics panel: five quick taps on the
  /// version row reveal the Developer ▸ Diagnostics tile (persisted, so it
  /// works on release builds too). A single/slow tap still opens About — the
  /// burst is debounced so the modal About dialog can't swallow the rapid taps.
  void _onAboutTap() {
    // With the Developer section suppressed, the version row is a plain About
    // row — otherwise the 5-tap burst would toast "unlocked" for a section that
    // is never rendered.
    if (!kDeveloperMenuEnabled) {
      _showAboutDialog();
      return;
    }
    final tel = SyncTelemetry.instance;
    if (tel.unlocked) {
      _showAboutDialog();
      return;
    }
    _diagTapCount++;
    _diagTapTimer?.cancel();
    if (_diagTapCount >= 5) {
      _diagTapCount = 0;
      tel.setUnlocked(true);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Developer diagnostics unlocked — see Developer section',
          ),
        ),
      );
      return;
    }
    _diagTapTimer = Timer(const Duration(milliseconds: 400), () {
      _diagTapCount = 0;
      if (mounted) _showAboutDialog();
    });
  }

  void _showAboutDialog() {
    showAboutDialog(
      context: context,
      applicationName: 'WhatWorks',
      applicationVersion: _versionLabel,
      applicationIcon: Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          color: AppTheme.headerGreen,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.task_alt, size: 36, color: Colors.white),
      ),
      children: [
        const Text('WhatsApp-style task management for Indian SMB teams'),
        const SizedBox(height: 8),
        const Text('© 2024 WhatWorks. All rights reserved.'),
      ],
    );
  }

  void _showSignOutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final navigator = Navigator.of(context);
              await context.read<AuthProvider>().signOut();
              // Drop every stacked route so the login screen (rendered by
              // AuthenticationWrapper at the root) is revealed instantly.
              navigator.popUntil((route) => route.isFirst);
            },
            child: const Text('Sign Out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
