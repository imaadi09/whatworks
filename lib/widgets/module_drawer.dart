import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../services/avatar_cache_service.dart';
import '../services/business_vocabulary.dart';
import '../utils/constants.dart';
import '../utils/paywall_constants.dart';
import 'app_avatar.dart';
import 'sector_picker.dart';
import '../screens/home/home_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../modules/sales/screens/sales_home_screen.dart';
import '../modules/shared/module_config.dart';
import '../modules/crm/screens/crm_home_screen.dart';
import '../modules/vendor/screens/vendor_home_screen.dart';

/// Which module owns the screen currently showing the drawer.
enum AppModule { task, sales, crm, inventory }

/// One in-module view (tab) surfaced at the top of the hamburger menu. The
/// host screen builds these so it can pass live values such as the Actions
/// attention badge, and so selecting one only rebuilds that screen.
class DrawerNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Color color;

  /// Trailing red count pill (0 = hidden). Carries the Actions attention
  /// badge that previously lived on the bottom-nav icon.
  final int badge;

  const DrawerNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.color,
    this.badge = 0,
  });
}

/// Shared hamburger-menu drawer used by every module home screen.
///
/// Module switching uses [Navigator.pushReplacement] so modules never stack:
/// pressing Back inside any module exits the app instead of dropping into
/// the module that opened it. In-module tabs (Assignee / My Tasks / Actions /
/// Dashboard) live at the top of the drawer via [moduleViews].
class ModuleDrawer extends StatelessWidget {
  final AppModule activeModule;

  /// In-module tabs (Assignee / My Tasks / Actions / Dashboard) moved here
  /// from the removed bottom nav. When null the drawer shows module
  /// switching only (screens without a tab bar).
  final List<DrawerNavItem>? moduleViews;

  /// Index of the currently selected entry in [moduleViews].
  final int activeViewIndex;

  /// Called with the tapped view's index after the drawer closes. The host
  /// switches tabs (and lazily builds that tab) in response.
  final ValueChanged<int>? onViewSelected;

  const ModuleDrawer({
    super.key,
    required this.activeModule,
    this.moduleViews,
    this.activeViewIndex = 0,
    this.onViewSelected,
  });

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final userName = authProvider.userModel?.name ?? 'User';
    final userPhone = authProvider.userModel?.phone ?? '';
    final userUid = authProvider.userModel?.uid ?? '';
    // Same resolution chain as the card avatars: contact photo → preset
    // avatar → tinted initials.
    final userAvatarUrl = AvatarCacheService().urlFor(
      uid: userUid,
      phone: userPhone,
      name: userName,
    );

    return Drawer(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: const BoxDecoration(color: AppTheme.headerGreen),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppAvatar(
                    avatarUrl: userAvatarUrl,
                    initials: userName.isNotEmpty
                        ? userName[0].toUpperCase()
                        : '?',
                    radius: 28,
                    color: Colors.white,
                    fontSize: 22,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    userName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  // Premium badge in drawer
                  if (PaywallLimits.isPremium(authProvider.effectivePlanType))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
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
                              size: 13,
                              color: Colors.amber.shade200,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Premium Plan',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.amber.shade200,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (userPhone.isNotEmpty)
                    Text(
                      userPhone,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.8),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ── In-module views (moved here from the bottom nav) ──
            // Only the Assignee landing tab is built at startup; the others
            // build lazily the first time they are picked here.
            if (moduleViews != null && moduleViews!.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 4),
                child: Text(
                  'VIEWS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppTheme.lightText,
                  ),
                ),
              ),
              for (int i = 0; i < moduleViews!.length; i++)
                _ViewNavItem(
                  item: moduleViews![i],
                  isActive: i == activeViewIndex,
                  onTap: () {
                    // Capture the navigator BEFORE popping: the drawer's own
                    // context is deactivated the moment it closes.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    onViewSelected?.call(i);
                  },
                ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              const SizedBox(height: 4),
            ],
            // Module items
            _ModuleItem(
              icon: Icons.task_alt,
              label: ModuleConfig.task.displayName,
              subtitle: 'Track Tasks',
              color: AppTheme.headerGreen,
              isActive: activeModule == AppModule.task,
              onTap: () => _switchModule(context, AppModule.task),
            ),
            _ModuleItem(
              icon: Icons.handshake_outlined,
              label: 'Sales Teams',
              subtitle: 'Enquiries & pipeline',
              color: const Color(0xFF1971C2),
              isActive: activeModule == AppModule.sales,
              onTap: () => _switchModule(context, AppModule.sales),
            ),
            _ModuleItem(
              icon: Icons.people_outline,
              label: 'Service Teams',
              subtitle: 'Customer Support',
              color: const Color(0xFF0C8599),
              isActive: activeModule == AppModule.crm,
              onTap: () => _switchModule(context, AppModule.crm),
            ),
            _ModuleItem(
              icon: Icons.local_shipping_outlined,
              label: 'Inventory',
              subtitle: 'Stock, Buy & Sell',
              color: const Color(0xFF7048E8),
              isActive: activeModule == AppModule.inventory,
              onTap: () => _switchModule(context, AppModule.inventory),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            const SizedBox(height: 4),
            // Sector (business type) — promoted to a top-level item so it gets
            // focus: unless a non-General sector is chosen, the sector
            // vocabulary, milestone pipelines and front-door landing all stay
            // dormant. Opens the SAME shared picker as Settings → Business
            // type; on a real change it rebuilds the active module home so
            // every label re-resolves at once. Hidden when the feature is off.
            if (kSectorTemplatesEnabled)
              _ModuleItem(
                icon: Icons.storefront_outlined,
                label: 'Sector',
                subtitle: BusinessVocabulary.current?.label ?? 'General / Other',
                color: AppTheme.headerGreen,
                isActive: false,
                onTap: () {
                  // Capture the navigator + active module BEFORE popping: the
                  // drawer's context is deactivated the moment it closes.
                  final navigator = Navigator.of(context);
                  final module = activeModule;
                  navigator.pop();
                  _openSectorPicker(navigator, module);
                },
              ),
            _ModuleItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
              subtitle: '',
              color: AppTheme.secondaryText,
              isActive: false,
              onTap: () {
                // Capture the navigator BEFORE popping: the drawer's own
                // context is deactivated once the drawer closes.
                final navigator = Navigator.of(context);
                navigator.pop();
                navigator.push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            const Spacer(),
            // Logout
            _ModuleItem(
              icon: Icons.logout,
              label: 'Sign Out',
              subtitle: '',
              color: Colors.red,
              isActive: false,
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                _confirmSignOut(navigator);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _switchModule(BuildContext context, AppModule target) {
    if (target == activeModule) {
      Navigator.pop(context); // Just close the drawer.
      return;
    }
    // Capture the navigator BEFORE popping: the drawer's own context is
    // deactivated the moment the drawer closes, so any navigation through it
    // silently does nothing.
    final navigator = Navigator.of(context);
    navigator.pop();
    // Persist the switch immediately so the startup "reopen last module"
    // restore (and any app-pause write) stays consistent with what's on top.
    final prefValue = switch (target) {
      AppModule.task => 'task',
      AppModule.sales => 'sales',
      AppModule.crm => 'crm',
      AppModule.inventory => 'inventory',
    };
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('last_home_module', prefValue),
    );
    final Widget screen = switch (target) {
      // restoreLastModule: false — otherwise the stale last_home_module pref
      // would bounce HomeScreen straight back to Sales/CRM.
      AppModule.task => const HomeScreen(restoreLastModule: false),
      AppModule.sales => const SalesHomeScreen(moduleConfig: ModuleConfig.sales),
      AppModule.crm => const CrmHomeScreen(),
      AppModule.inventory => const VendorHomeScreen(),
    };
    // Replace, never push: exactly one module home sits on the stack, so Back
    // from a module returns to the Task home instead of unwinding module
    // history the user already left behind.
    navigator.pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  /// Open the shared sector picker off the captured [navigator] — the drawer's
  /// own context is dead after pop, the same reason [_confirmSignOut] hosts its
  /// dialog off navigator.context. When the sector actually changes, rebuild the
  /// active module home via pushReplacement so every AppBar/card re-resolves its
  /// sector vocabulary immediately: the ModuleConfig getters read the in-memory
  /// cache synchronously, but already-built widgets won't repaint until rebuilt.
  /// Mirrors the onboarding front-door bounce and [_switchModule]'s replace
  /// model. No last_home_module write — the user stays in this same module.
  Future<void> _openSectorPicker(
    NavigatorState navigator,
    AppModule module,
  ) async {
    final appliedId = await showSectorPicker(navigator.context);
    if (appliedId == null) return;
    final Widget screen = switch (module) {
      AppModule.task => const HomeScreen(restoreLastModule: false),
      AppModule.sales => const SalesHomeScreen(moduleConfig: ModuleConfig.sales),
      AppModule.crm => const CrmHomeScreen(),
      AppModule.inventory => const VendorHomeScreen(),
    };
    navigator.pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  void _confirmSignOut(NavigatorState navigator) {
    // The drawer's own context is already deactivated — host the dialog off
    // the captured navigator instead.
    showDialog(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out?'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ctx.read<AuthProvider>().signOut();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }
}

/// A single in-module view row (Assignee / My Tasks / Actions / Dashboard).
/// Mirrors [_ModuleItem]'s look but shows an optional trailing count badge
/// and uses the module theme color for the active state.
class _ViewNavItem extends StatelessWidget {
  final DrawerNavItem item;
  final bool isActive;
  final VoidCallback onTap;

  const _ViewNavItem({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = item.color;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: isActive ? color.withOpacity(0.08) : Colors.transparent,
        child: Row(
          children: [
            Icon(
              isActive ? item.selectedIcon : item.icon,
              color: isActive ? color : AppTheme.secondaryText,
              size: 22,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive ? color : AppTheme.primaryText,
                ),
              ),
            ),
            if (item.badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFC92A2A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${item.badge}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModuleItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final bool isActive;
  final VoidCallback onTap;

  const _ModuleItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: isActive ? color.withOpacity(0.08) : Colors.transparent,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive ? color : AppTheme.primaryText,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.lightText,
                      ),
                    ),
                ],
              ),
            ),
            if (isActive)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
