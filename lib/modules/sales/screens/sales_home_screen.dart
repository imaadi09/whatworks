// Sales/CRM module home (CRM runs this same screen with ModuleConfig.crm).
// ⚠️ PARITY RULE: this module must mirror the Task module (the reference
// implementation). Every correction/enhancement made in the Task module
// must be ported here — swipe actions, 3-dot filters, dialogs,
// multi-select, navigation. See BaseModuleProvider's doc comment.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/enquiry.dart';
import '../models/sales_team.dart';
import '../providers/sales_provider.dart';
import '../widgets/sales_card.dart';
import '../../../providers/auth_provider.dart';
import '../../../utils/constants.dart';
import '../../../utils/helpers.dart';
import '../../../utils/paywall_constants.dart';
import '../../../utils/export_service.dart';
import '../../../services/contact_picker_service.dart';
import 'sales_dashboard_screen.dart';
import 'sales_detail_screen.dart';
import 'sales_actions_screen.dart';
import 'assignee_sales_screen.dart';
import 'sales_team_settings_screen.dart';
import 'sales_milestone_settings_screen.dart';
import '../services/milestone_settings_service.dart';
import '../../../screens/home/home_screen.dart';
import '../../../screens/settings/categories_screen.dart';
import 'sales_reports_screen.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../../../widgets/module_drawer.dart';
import '../../crm/providers/crm_provider.dart';

class SalesHomeScreen extends StatefulWidget {
  /// The module this home operates in (Sales or CRM). Required — forgetting
  /// it used to silently fall back to Sales mode, so CRM writes landed in
  /// Sales storage. The compiler now refuses any push that omits it.
  final ModuleConfig moduleConfig;
  const SalesHomeScreen({super.key, required this.moduleConfig});

  @override
  State<SalesHomeScreen> createState() => _SalesHomeScreenState();
}

class _SalesHomeScreenState extends State<SalesHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;

  /// Module config (required — no silent Sales fallback).
  ModuleConfig get _config => widget.moduleConfig;
  bool get _isCrm => _config.type == ModuleType.crm;

  /// Read the module provider (non-listening).
  BaseModuleProvider _readProvider(BuildContext ctx) =>
      _isCrm ? ctx.read<CrmProvider>() : ctx.read<SalesProvider>();

  /// Watch the module provider (listening for rebuilds).
  BaseModuleProvider _watchProvider(BuildContext ctx) =>
      _isCrm ? ctx.watch<CrmProvider>() : ctx.watch<SalesProvider>();

  /// Theme color for the module.
  Color get _themeColor => _config.themeColor;

  /// "Enquiries" / "Tickets" — plural of the module's item name.
  String _pluralItemName() {
    final n = _config.itemName;
    return n.endsWith('y') ? '${n.substring(0, n.length - 1)}ies' : '${n}s';
  }

  /// Icons for the config-driven status VIEW options (by status index).
  static const List<IconData> _statusFilterIcons = [
    Icons.play_circle_outline,
    Icons.check_circle_outline,
    Icons.close,
    Icons.remove_circle_outline,
    Icons.cancel_outlined,
  ];

  /// Icon for a status in the VIEW filter, matched by status NAME so the new
  /// mid-pipeline sales stages get sensible icons and the existing Sales/CRM
  /// icons stay exactly as the prior positional mapping produced them.
  /// The positional list remains the fallback for any unknown status.
  IconData _statusIconFor(String statusName, int index) {
    switch (statusName) {
      // Sales pipeline
      case 'active':
        return Icons.play_circle_outline;
      case 'quotation':
        return Icons.request_quote;
      case 'demo':
        return Icons.inventory_2_outlined;
      case 'negotiation':
        return Icons.local_offer_outlined;
      case 'success':
        return Icons.check_circle_outline;
      case 'lost':
        return Icons.close;
      case 'dropped':
        return Icons.remove_circle_outline;
      case 'cancel':
        return Icons.cancel_outlined;
      // CRM pipeline (icons preserved from the prior positional mapping)
      case 'open':
        return Icons.play_circle_outline;
      case 'inProgress':
        return Icons.check_circle_outline;
      case 'resolved':
        return Icons.close;
      case 'closed':
        return Icons.remove_circle_outline;
      case 'escalated':
        return Icons.cancel_outlined;
      default:
        return _statusFilterIcons[index % _statusFilterIcons.length];
    }
  }

  // Bottom nav: 0=Assignee, 1=My Enquiries (BY ME/TO ME), 2=Actions, 3=Dashboard
  int _navIndex = 0;
  // Tabs build lazily on first visit — only the Assignee landing tab is
  // built at startup. My Enquiries/Tickets / Actions / Dashboard build the
  // first time they are picked from the hamburger menu.
  final Set<int> _builtNavTabs = {0};
  // Bumped on each Dashboard visit so metrics recompute fresh
  int _dashboardEpoch = 0;
  bool get _showMyTabs => _navIndex == 1;
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;

  // WhatsApp-style multi-select state
  bool _isSelectionMode = false;
  Set<String> _selectedEnquiryIds = {};

  // Data loading guards
  bool _hasLoadedData = false;
  String _loadedDataUserId = '';

  /// When the app last left the foreground. A resume force-reload is skipped
  /// for brief unlocks (the SQLite change listeners keep the lists fresh while
  /// the process lives) and only paid after a long background.
  DateTime? _pausedAt;

  // Menu expanded sections state
  Set<String> _menuExpandedSections = {
    'view',
  }; // Default: VIEW section expanded

  /// Milestone titles for the Milestone filter submenu — loaded lazily from
  /// the module's milestone templates the first time the menu opens.
  List<String> _milestoneTitles = const [];

  /// Provider captured once so dispose() can drop any leftover 3-dot menu
  /// filter without touching a deactivated context.
  BaseModuleProvider? _homeProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this); // By Me, To Me
    _homeProvider = _readProvider(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadData();
  }

  void _loadData({bool force = false}) async {
    final auth = context.read<AuthProvider>();
    final userId = auth.userModel?.uid ?? '';
    if (userId.isEmpty) return;
    final isFirstLoad = !_hasLoadedData || _loadedDataUserId != userId;
    if (!force && _hasLoadedData && _loadedDataUserId == userId) return;
    _hasLoadedData = true;
    _loadedDataUserId = userId;

    final provider = _readProvider(context);
    // Gate on this module's own subscription (sale vs crm), not the global plan.
    final planType = auth.effectivePlanTypeFor(_isCrm ? 'crm' : 'sale');
    // Load teams first (SQLite-first, fast) so the team selection is restored
    await provider.loadTeams(userId);
    // Load enquiries immediately — don't gate the first paint on the
    // Firestore default-team check (network round-trip)
    if (mounted) {
      if (isFirstLoad) {
        provider.loadEnquiries(userId);
      } else {
        // Silent reload — no loading spinner
        provider.refresh(userId);
      }
    }
    // Ensure a default team exists in the background (Firestore)
    unawaited(provider.ensureDefaultTeam(userId, planType: planType));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    // Leaving the module drops any 3-dot menu filter/sort so the next visit
    // always opens on the unfiltered view.
    _homeProvider?.setStatusFilter('All');
    _homeProvider?.setSortBy('Last Action');
    // Module switch uses pushReplacement, so this dispose fires: drop this
    // module's 4 list Firestore listeners so only the visible module keeps
    // list sync alive (re-attach on return is a cheap watermark delta read).
    _homeProvider?.stopListSync();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Reload data on resume — but skip the full re-scan for brief unlocks.
    // The change listeners keep the lists fresh while the process lives, so
    // only a long background (where sync may have been suspended) warrants
    // the forced reload.
    if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt == null ||
          DateTime.now().difference(pausedAt) >= const Duration(seconds: 60)) {
        _loadData(force: true);
      }
    }
    // Remember which module home was on top at closure so the next launch
    // can reopen it.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pausedAt = DateTime.now();
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString('last_home_module', _config.sequentialIdKey),
      );
    }
  }

  // ── Selection Mode ──────────────────────────────────────────────────────

  void _enterSelectionMode(String enquiryId) {
    setState(() {
      _isSelectionMode = true;
      _selectedEnquiryIds.add(enquiryId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedEnquiryIds.clear();
    });
  }

  // ── Bottom navigation ────────────────────────────────────────

  /// Resets the embedded Actions tab's bell view when navigating away.
  final SalesActionsController _salesActionsController =
      SalesActionsController();

  /// R3: memoize the badge count on the provider [revision] so pure rebuilds
  /// (scroll, tab switch) reuse the last number instead of re-scanning the
  /// enquiries and their action icons on every frame. It recomputes exactly
  /// once per data change (each notify bumps [revision]).
  int _attRevision = -1;
  int _attCache = 0;

  /// Pending closure-action count across all open enquiries — the red badge
  /// on the hamburger menu's Actions entry.
  int _attentionCount(BaseModuleProvider p) {
    if (p.revision == _attRevision) return _attCache;
    int n = 0;
    final seen = <String>{};
    for (final e in p.enquiries) {
      if (!seen.add(e.id)) continue;
      if (e.isClosed || e.isDeleted || e.isArchived) continue;
      final rows = p.getActionIcons(e.id);
      if (rows == null) continue;
      for (final r in rows) {
        // Same per-type rule as the bell/chips: done closes everything,
        // a reply closes queries/requests/extensions, follow-ups/blockers/
        // calls stay open until marked done.
        if ((r['isDone'] as int? ?? 0) != 0) continue;
        switch (r['actionType'] as String? ?? '') {
          case 'query':
          case 'approval':
          case 'extension':
            if ((r['isReplied'] as int? ?? 0) == 0) n++;
            break;
          case 'followup':
          case 'blocker':
          case 'call':
            n++;
            break;
        }
      }
    }
    _attRevision = p.revision;
    _attCache = n;
    return n;
  }

  void _onNavSelected(int index) {
    final clearSearch = index >= 2 && _showSearchBar;
    setState(() {
      if (_isSelectionMode) {
        _isSelectionMode = false;
        _selectedEnquiryIds.clear();
      }
      if (clearSearch) {
        _showSearchBar = false;
        _searchController.clear();
      }
      _navIndex = index;
      _builtNavTabs.add(index);
      if (index == 3) _dashboardEpoch++;
    });
    // Leaving the Actions tab clears its bell/attention view.
    if (index != 2) _salesActionsController.resetAttentionMode();
    // Tapping a nav button drops the 3-dot menu filter (and its AppBar
    // label) so every tab opens on its unfiltered view. The provider filter
    // also feeds the Assignee tab, so one clear covers both.
    _readProvider(context).setStatusFilter('All');
    _readProvider(context).setSortBy('Last Action');
    if (clearSearch) _readProvider(context).setSearchQuery('');
  }

  void _toggleEnquirySelection(String enquiryId) {
    setState(() {
      if (_selectedEnquiryIds.contains(enquiryId)) {
        _selectedEnquiryIds.remove(enquiryId);
        if (_selectedEnquiryIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedEnquiryIds.add(enquiryId);
      }
    });
  }

  /// Check if all selected enquiries are created by the current user.
  bool _canDeleteSelected(BaseModuleProvider provider) {
    final auth = context.read<AuthProvider>();
    final currentUid = auth.userModel?.uid ?? '';
    return _selectedEnquiryIds.every((id) {
      final enquiry = provider.enquiries.firstWhere(
        (e) => e.id == id,
        orElse: () => EnquiryModel(
          id: '',
          createdBy: '',
          assignedTo: '',
          clientName: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      return enquiry.createdBy == currentUid;
    });
  }

  /// Delete all selected enquiries with confirmation — soft delete, so the
  /// cards move to the Deleted view and can still be restored from there.
  void _deleteSelectedEnquiries(BaseModuleProvider provider) {
    final count = _selectedEnquiryIds.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Cards'),
        content: Text(
          'Delete $count ${count == 1 ? 'card' : 'cards'}? They move to the Deleted view, where you can restore or permanently remove them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ids = List<String>.from(_selectedEnquiryIds);
              for (final id in ids) {
                await provider.softDeleteEnquiry(id);
              }
              _exitSelectionMode();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '$count ${count == 1 ? 'card' : 'cards'} moved to Deleted',
                    ),
                  ),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Archive all selected enquiries (no purge, reversible).
  void _archiveSelectedEnquiries(BaseModuleProvider provider) {
    final count = _selectedEnquiryIds.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archive Cards'),
        content: Text(
          'Archive $count ${count == 1 ? 'card' : 'cards'}? Archived cards are kept forever and can be unarchived anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ids = List<String>.from(_selectedEnquiryIds);
              for (final id in ids) {
                await provider.archiveEnquiry(id);
              }
              _exitSelectionMode();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '$count ${count == 1 ? 'card' : 'cards'} archived',
                    ),
                    backgroundColor: _themeColor,
                  ),
                );
              }
            },
            child: const Text('Archive'),
          ),
        ],
      ),
    );
  }

  /// Dialog for archived cards: Unarchive or Open.
  void _showArchivedEnquiryDialog(
    EnquiryModel enquiry,
    BaseModuleProvider provider,
  ) {
    final archivedDate = enquiry.archivedAt != null
        ? Helpers.formatDate(enquiry.archivedAt!)
        : 'unknown date';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Archived Card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              enquiry.clientName.isNotEmpty
                  ? enquiry.clientName
                  : enquiry.title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Archived on $archivedDate',
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryText,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Archived cards are kept forever — nothing is ever purged.',
              style: TextStyle(fontSize: 12, color: AppTheme.lightText),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SalesDetailScreen(
                    enquiry: enquiry,
                    moduleConfig: _config,
                  ),
                ),
              );
            },
            child: const Text('Open'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await provider.unarchiveEnquiry(enquiry.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Card unarchived'),
                    backgroundColor: _themeColor,
                  ),
                );
              }
            },
            child: Text('Unarchive', style: TextStyle(color: _themeColor)),
          ),
        ],
      ),
    );
  }

  /// Dialog for deleted cards: Restore or Delete Permanently (parity with
  /// the Task module's deleted-task dialog).
  void _showDeletedEnquiryDialog(
    EnquiryModel enquiry,
    BaseModuleProvider provider,
  ) {
    final deletedDate = enquiry.deletedAt != null
        ? Helpers.formatDate(enquiry.deletedAt!)
        : 'unknown date';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Deleted Card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              enquiry.clientName.isNotEmpty
                  ? enquiry.clientName
                  : enquiry.title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Deleted on $deletedDate',
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryText,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Deleted cards can be restored anytime from the Deleted view, or removed permanently.',
              style: TextStyle(fontSize: 12, color: AppTheme.lightText),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Confirm before purging — this is irreversible.
              if (!mounted) return;
              showDialog(
                context: context,
                builder: (confirmCtx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: const Text('Delete Permanently?'),
                  content: const Text(
                    'This card will be removed forever. This cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(confirmCtx),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(confirmCtx);
                        await provider.deleteEnquiry(enquiry.id);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Card permanently deleted'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Delete Forever'),
                    ),
                  ],
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete Forever'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await provider.restoreEnquiry(enquiry.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Card restored'),
                    backgroundColor: _themeColor,
                  ),
                );
              }
            },
            child: Text('Restore', style: TextStyle(color: _themeColor)),
          ),
        ],
      ),
    );
  }

  /// Show team switcher bottom sheet.
  void _showTeamSwitcher(BuildContext context, BaseModuleProvider provider) {
    final teams = provider.teams;
    final currentTeamId = provider.currentTeamId;
    final auth = context.read<AuthProvider>();
    final planType = auth.effectivePlanTypeFor(_isCrm ? 'crm' : 'sale');
    final canMultiTeam = PaywallLimits.maxTeams(planType) > 1;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.group_work, color: _themeColor, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'SWITCH TEAM',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...teams.map((team) {
              final isCurrent = team.id == currentTeamId;
              final isLocked = !isCurrent && !canMultiTeam && teams.length > 1;
              return ListTile(
                leading: Radio<String>(
                  value: team.id,
                  groupValue: currentTeamId,
                  activeColor: _themeColor,
                  onChanged: isLocked
                      ? null
                      : (value) {
                          Navigator.pop(ctx);
                          if (value != null && value != currentTeamId) {
                            _trySwitchTeam(provider, value, planType);
                          }
                        },
                ),
                title: Row(
                  children: [
                    Text(
                      team.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                        color: isLocked ? Colors.grey : Colors.black,
                      ),
                    ),
                    if (isLocked) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.lock_outline,
                        size: 14,
                        color: Colors.grey,
                      ),
                    ],
                  ],
                ),
                trailing: isCurrent
                    ? Icon(Icons.check, color: _themeColor, size: 20)
                    : null,
                onTap: isLocked
                    ? () {
                        Navigator.pop(ctx);
                        showPaywallDialog(
                          context,
                          feature: 'Switch between multiple teams.',
                          detail:
                              'Premium unlocks up to ${PaywallLimits.maxTeams('premium')} teams per module.',
                        );
                      }
                    : () {
                        Navigator.pop(ctx);
                        if (team.id != currentTeamId) {
                          _trySwitchTeam(provider, team.id, planType);
                        }
                      },
              );
            }),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.settings, color: _themeColor),
              title: Text(
                'Manage Teams',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: _themeColor,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SalesTeamSettingsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Attempt to switch team, showing paywall dialog if not business.
  void _trySwitchTeam(
    BaseModuleProvider provider,
    String teamId,
    String planType,
  ) async {
    final success = await provider.switchTeam(teamId, planType: planType);
    if (!success) {
      // Show paywall dialog if switch was blocked
      showPaywallDialog(
        context,
        feature: 'Switch between multiple teams.',
        detail:
            'Premium unlocks up to ${PaywallLimits.maxTeams('premium')} teams per module.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final salesProvider = _watchProvider(context);
    // Watch AuthProvider so rebuilds fire when auth session restores
    context.watch<AuthProvider>();

    final scaffold = Scaffold(
      backgroundColor: Colors.white,
      // Hamburger menu like the Task module — modules never stack, so there
      // is never a back arrow here. The in-module tabs (moved off the bottom
      // nav) live at the top of the drawer.
      drawer: ModuleDrawer(
        activeModule: _isCrm ? AppModule.crm : AppModule.sales,
        activeViewIndex: _navIndex,
        onViewSelected: _onNavSelected,
        moduleViews: [
          DrawerNavItem(
            icon: Icons.assignment_ind_outlined,
            selectedIcon: Icons.assignment_ind,
            label: 'Assignee',
            color: _themeColor,
          ),
          DrawerNavItem(
            icon: Icons.people_alt_outlined,
            selectedIcon: Icons.people_alt,
            label: _isCrm ? 'All Tickets' : 'All Enquiries',
            color: _themeColor,
          ),
          DrawerNavItem(
            icon: Icons.checklist,
            selectedIcon: Icons.checklist,
            label: 'Actions',
            color: _themeColor,
            badge: _attentionCount(salesProvider),
          ),
          DrawerNavItem(
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: 'Dashboard',
            color: _themeColor,
          ),
        ],
      ),
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => Scaffold.of(context).openDrawer(),
            tooltip: 'Menu',
          ),
        ),
        title: _isSelectionMode
            ? Text(
                '${_selectedEnquiryIds.length} selected',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              )
            : GestureDetector(
                onTap: () => _showTeamSwitcher(context, salesProvider),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Line 1: module display name ("Sales Teams"/"Service
                    // Teams") as the headline, matching the Task home format.
                    Flexible(
                      child: Text(
                        salesProvider.appBarModuleName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Line 2: current team ("Team One" when unnamed) + switch
                    // chevron.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            salesProvider.appBarTeamName,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.85),
                              fontWeight: FontWeight.w400,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (salesProvider.teams.length > 1)
                          const Icon(
                            Icons.arrow_drop_down,
                            color: Colors.white,
                            size: 18,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
        actions: _isSelectionMode
            ? [
                // Archive button (only if all selected are created by current user)
                if (_canDeleteSelected(salesProvider))
                  IconButton(
                    icon: const Icon(
                      Icons.archive_outlined,
                      color: Colors.white,
                    ),
                    onPressed: () => _archiveSelectedEnquiries(salesProvider),
                    tooltip: 'Archive',
                  ),
                // Delete button (only if all selected are created by current user)
                if (_canDeleteSelected(salesProvider))
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white),
                    onPressed: () => _deleteSelectedEnquiries(salesProvider),
                    tooltip: 'Delete',
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _exitSelectionMode,
                  tooltip: 'Cancel',
                ),
              ]
            : [
                // Search icon — always available on the module home, matching
                // the Task home AppBar (was hidden whenever the tab row was
                // off, so single-team/CRM layouts lost it).
                IconButton(
                  icon: Icon(
                    _showSearchBar ? Icons.close : Icons.search,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _showSearchBar = !_showSearchBar;
                      if (!_showSearchBar) {
                        _searchController.clear();
                        salesProvider.setSearchQuery('');
                      }
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  onPressed: () => _showFilterMenu(context),
                ),
              ],
      ),
      body: Column(
        children: [
          // Search bar
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            height: _showSearchBar ? null : 0,
            clipBehavior: Clip.hardEdge,
            decoration: const BoxDecoration(),
            child: _showSearchBar
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: Colors.white,
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.lightGrey,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        maxLength: 100,
                        decoration: InputDecoration(
                          hintText: 'Search enquiries...',
                          counterText: '',
                          hintStyle: const TextStyle(
                            color: AppTheme.secondaryText,
                            fontSize: 15,
                          ),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: AppTheme.secondaryText,
                            size: 22,
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    _searchController.clear();
                                    salesProvider.setSearchQuery('');
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 0,
                            horizontal: 16,
                          ),
                        ),
                        onChanged: (value) {
                          salesProvider.setSearchQuery(value);
                        },
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // BY ME / TO ME tab bar (only in My Enquiries mode)
          if (_showMyTabs)
            Container(
              color: Colors.white,
              child: TabBar(
                controller: _tabController,
                // Switching BY ME / TO ME also drops the 3-dot filter so
                // the other side never inherits a stale filtered view.
                onTap: _isSelectionMode
                    ? null
                    : (index) {
                        final provider = _readProvider(context);
                        provider.setStatusFilter('All');
                        provider.setSortBy('Last Action');
                      },
                indicatorColor: _themeColor,
                indicatorWeight: 3,
                labelColor: _themeColor,
                unselectedLabelColor: AppTheme.secondaryText,
                labelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                tabs: [
                  _buildUnreadTab(
                    'BY ME',
                    _unreadTotal(salesProvider, byMe: true),
                  ),
                  _buildUnreadTab(
                    'TO ME',
                    _unreadTotal(salesProvider, byMe: false),
                  ),
                ],
              ),
            ),
          // Active filter chips (enquiry list views: My Enquiries + Assignee)
          if ((_showMyTabs || _navIndex == 0) && salesProvider.hasActiveFilters)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: _themeColor.withOpacity(0.05),
              child: Row(
                children: [
                  if (salesProvider.statusFilter != 'All')
                    _buildFilterChip(
                      label: salesProvider.statusFilter == 'Unassigned'
                          ? 'Assign later'
                          : salesProvider.statusFilter,
                      onClear: () => salesProvider.setStatusFilter('All'),
                    ),
                  if (salesProvider.sortBy != 'Last Action') ...[
                    const SizedBox(width: 6),
                    _buildFilterChip(
                      label: '↕ ${salesProvider.sortBy}',
                      onClear: () => salesProvider.setSortBy('Last Action'),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: () => salesProvider.clearFilters(),
                    child: const Text(
                      'Clear all',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          // Tab content (IndexedStack preserves assignee tab state)
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: IndexedStack(
                index: _navIndex,
                children: [
                  AssigneeSalesScreen(
                    embedded: true,
                    isActive: _navIndex == 0,
                    moduleConfig: widget.moduleConfig,
                    // Same long-press selection behavior as the My Cards tab
                    selectionMode: _isSelectionMode,
                    selectedEnquiryIds: _selectedEnquiryIds,
                    onLongPressEnquiry: (enquiry) {
                      if (enquiry.isDeleted) {
                        _showDeletedEnquiryDialog(enquiry, salesProvider);
                      } else if (enquiry.isArchived) {
                        _showArchivedEnquiryDialog(enquiry, salesProvider);
                      } else if (!_isSelectionMode) {
                        _enterSelectionMode(enquiry.id);
                      }
                    },
                    onToggleSelection: (enquiry) =>
                        _toggleEnquirySelection(enquiry.id),
                  ),
                  // MY ENQUIRIES/TICKETS: built lazily on first visit.
                  _builtNavTabs.contains(1)
                      ? TabBarView(
                          controller: _tabController,
                          children: [
                            _buildSalesTab(salesProvider, byMe: true),
                            _buildSalesTab(salesProvider, byMe: false),
                          ],
                        )
                      : const SizedBox.shrink(),
                  // ACTIONS: built lazily on first visit
                  _builtNavTabs.contains(2)
                      ? SalesActionsScreen(
                          embedded: true,
                          isActive: _navIndex == 2,
                          moduleConfig: widget.moduleConfig,
                          controller: _salesActionsController,
                        )
                      : const SizedBox.shrink(),
                  // DASHBOARD: built lazily, re-keyed per visit for fresh metrics
                  _builtNavTabs.contains(3)
                      ? SalesDashboardScreen(
                          key: ValueKey('dash$_dashboardEpoch'),
                          embedded: true,
                          isActive: _navIndex == 3,
                          moduleConfig: widget.moduleConfig,
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: (_isSelectionMode || _navIndex >= 2)
          ? null
          : FloatingActionButton(
              onPressed: () => _createNewEnquiry(),
              backgroundColor: _themeColor,
              child: const Icon(Icons.add, color: Colors.white),
            ),
    );

    // Back button: exit selection → close search → clear filter → Assignee
    // tab → Task home. Sales/CRM never own the back button's last stop.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelectionMode) {
          _exitSelectionMode();
          return;
        }
        if (_showSearchBar) {
          setState(() {
            _showSearchBar = false;
            _searchController.clear();
          });
          _readProvider(context).setSearchQuery('');
          return;
        }
        if (salesProvider.hasActiveFilters) {
          // Reset to the unfiltered view (also applies to Assignee tab)
          _readProvider(context).clearFilters();
          return;
        }
        if (_navIndex != 0) {
          setState(() => _navIndex = 0);
          return;
        }
        // Nothing left to unwind in this module, so Back returns to the Task
        // home instead of closing the app. Replace, never push, so exactly one
        // module home is ever on the stack (same rule the drawer follows), and
        // persist the switch so the "reopen last module" restore agrees with
        // what is actually on screen.
        SharedPreferences.getInstance().then(
          (prefs) => prefs.setString('last_home_module', 'task'),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const HomeScreen(restoreLastModule: false),
          ),
        );
      },
      child: scaffold,
    );
  }

  Widget _buildFilterChip({
    required String label,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _themeColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _themeColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: _themeColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onClear,
            child: Icon(Icons.close, size: 12, color: _themeColor),
          ),
        ],
      ),
    );
  }

  // ── Sales Tab ────────────────────────────────────────────────────────────

  /// Total unread messages for the current user across a tab's enquiries.
  int _unreadTotal(BaseModuleProvider salesProvider, {required bool byMe}) {
    final auth = context.read<AuthProvider>();
    final currentUid = auth.userModel?.uid ?? '';
    if (currentUid.isEmpty) return 0;
    final currentNameLower = (auth.userModel?.name ?? '').toLowerCase();
    int total = 0;
    for (final e in salesProvider.filteredEnquiries) {
      final matches = byMe
          ? e.createdBy == currentUid
          : e.assignedToUid == currentUid ||
                e.assigneeUids.contains(currentUid) ||
                (currentNameLower.isNotEmpty &&
                    (e.assignedTo.toLowerCase() == currentNameLower ||
                        e.assigneeNames.any(
                          (n) => n.toLowerCase() == currentNameLower,
                        )));
      if (matches) total += e.unreadCounts[currentUid] ?? 0;
    }
    return total;
  }

  /// Tab label with a WhatsApp-style unread count badge when [count] > 0.
  Tab _buildUnreadTab(String label, int count) {
    if (count <= 0) return Tab(text: label);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF25D366),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesTab(
    BaseModuleProvider salesProvider, {
    required bool byMe,
  }) {
    final auth = context.read<AuthProvider>();
    final currentUid = auth.userModel?.uid ?? '';
    final currentName = auth.userModel?.name ?? '';
    final currentPhone = auth.userModel?.phone ?? '';

    // Don't block UI with loading spinner — show existing data or empty state
    // Data arrives silently from Firestore in the background

    final currentNameLower = currentName.toLowerCase();
    final enquiries = salesProvider.filteredEnquiries.where((e) {
      if (byMe) return e.createdBy == currentUid;
      return e.assignedToUid == currentUid ||
          e.assigneeUids.contains(currentUid) ||
          (currentNameLower.isNotEmpty &&
              (e.assignedTo.toLowerCase() == currentNameLower ||
                  e.assigneeNames.any(
                    (n) => n.toLowerCase() == currentNameLower,
                  )));
    }).toList();

    if (enquiries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.handshake_outlined,
              size: 80,
              color: AppTheme.lightText.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              salesProvider.searchQuery.isNotEmpty
                  ? 'No matching enquiries'
                  : salesProvider.hasActiveFilters
                  ? 'No enquiries matching filter'
                  : byMe
                  ? 'No enquiries created by you'
                  : 'No enquiries assigned to you',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.lightText.withOpacity(0.6),
              ),
            ),
            if (byMe &&
                !salesProvider.hasActiveFilters &&
                salesProvider.searchQuery.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Tap + to create your first enquiry',
                style: TextStyle(fontSize: 13, color: AppTheme.lightText),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        final auth = context.read<AuthProvider>();
        await salesProvider.refresh(auth.userModel?.uid ?? '');
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Pre-render beyond the viewport so flings never hit a blank slot
        // (parity with the Task module).
        cacheExtent: 800,
        itemCount: enquiries.length + (salesProvider.hasMoreEnquiries ? 1 : 0),
        itemBuilder: (context, index) {
          // Load more indicator at the end
          if (index >= enquiries.length) {
            if (!salesProvider.isLoadingMore) {
              final auth = context.read<AuthProvider>();
              salesProvider.loadMoreEnquiries(auth.userModel?.uid ?? '');
            }
            return const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          final enquiry = enquiries[index];
          Widget card = SalesCard(
            enquiry: enquiry,
            currentUid: currentUid,
            currentName: currentName,
            currentPhone: currentPhone,
            onTap: () {
              if (_isSelectionMode) {
                _toggleEnquirySelection(enquiry.id);
              } else if (enquiry.isDeleted) {
                // Deleted cards offer Restore / Delete Forever
                _showDeletedEnquiryDialog(enquiry, salesProvider);
              } else if (enquiry.isArchived) {
                // Archived cards offer Unarchive / Open
                _showArchivedEnquiryDialog(enquiry, salesProvider);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SalesDetailScreen(
                      enquiry: enquiry,
                      moduleConfig: _config,
                    ),
                  ),
                );
              }
            },
            onLongPress: () {
              if (enquiry.isDeleted) {
                _showDeletedEnquiryDialog(enquiry, salesProvider);
              } else if (enquiry.isArchived) {
                _showArchivedEnquiryDialog(enquiry, salesProvider);
              } else if (!_isSelectionMode) {
                _enterSelectionMode(enquiry.id);
              }
            },
            isSelected:
                _isSelectionMode && _selectedEnquiryIds.contains(enquiry.id),
          );

          // Swipe parity with the Task module: deleted cards swipe to purge
          // permanently (restore lives in the tap dialog), archived cards
          // swipe back to normal views, draft cards swipe away to delete,
          // every other card swipes away to archive.
          final bool isDraftEnquiry =
              (enquiry.extraFields?['isDraft'] == true) &&
              enquiry.title.trim().isEmpty;
          if (enquiry.isDeleted) {
            // Deleted view: swipe purges the card permanently.
            card = Dismissible(
              key: Key(enquiry.id),
              direction: DismissDirection.endToStart,
              // Less sensitive: require ~75% of the width dragged before the
              // swipe fires (default 0.4 archived cards on a short flick).
              dismissThresholds: const {DismissDirection.endToStart: 0.75},
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: const Color(0xFFC92A2A),
                child: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              onDismissed: (_) async {
                try {
                  await salesProvider.deleteEnquiry(enquiry.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Card deleted forever'),
                        backgroundColor: Color(0xFFC92A2A),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to delete card: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          } else if (enquiry.isArchived) {
            card = Dismissible(
              key: Key(enquiry.id),
              direction: DismissDirection.endToStart,
              // Less sensitive: require ~75% of the width dragged before the
              // swipe fires (default 0.4 archived cards on a short flick).
              dismissThresholds: const {DismissDirection.endToStart: 0.75},
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: AppTheme.primaryGreen,
                child: const Icon(
                  Icons.unarchive_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              onDismissed: (_) async {
                try {
                  await salesProvider.unarchiveEnquiry(enquiry.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Card unarchived'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to unarchive card: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          } else if (isDraftEnquiry) {
            // Draft cards swipe away to delete — same as draft tasks.
            card = Dismissible(
              key: Key(enquiry.id),
              direction: DismissDirection.endToStart,
              // Less sensitive: require ~75% of the width dragged before the
              // swipe fires (default 0.4 archived cards on a short flick).
              dismissThresholds: const {DismissDirection.endToStart: 0.75},
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: const Color(0xFFE03131),
                child: const Icon(
                  Icons.delete_outline,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              onDismissed: (_) async {
                try {
                  await salesProvider.softDeleteEnquiry(enquiry.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Draft moved to Deleted'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to delete draft: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          } else {
            card = Dismissible(
              key: Key(enquiry.id),
              direction: DismissDirection.endToStart,
              // Less sensitive: require ~75% of the width dragged before the
              // swipe fires (default 0.4 archived cards on a short flick).
              dismissThresholds: const {DismissDirection.endToStart: 0.75},
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: const Color(0xFFF59F00),
                child: const Icon(
                  Icons.archive_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              onDismissed: (_) async {
                try {
                  await salesProvider.archiveEnquiry(enquiry.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Card archived'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to archive card: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          }
          return card;
        },
      ),
    );
  }

  // ── Create New Enquiry ─────────────────────────────────────────────────

  Future<void> _createNewEnquiry() async {
    final auth = context.read<AuthProvider>();
    final user = auth.userModel;
    if (user == null) return;

    // Pick the assignee. "Unassigned — assign later" is offered so a ticket
    // can be created without an assignee (picked up later from the filter).
    final contact = await ContactPickerService().showContactPicker(
      context,
      allowUnassigned: true,
    );
    if (contact == null || !mounted) return;
    final bool isUnassigned = contact.isUnassigned;

    // Milestone templates are applied centrally in createEnquiry.
    final now = DateTime.now();

    final salesProvider = _readProvider(context);
    final teamId = salesProvider.currentTeamId;

    final enquiry = EnquiryModel(
      id: '',
      title: '',
      clientName: '',
      createdBy: user.uid,
      createdByName: user.name,
      createdByPhone: user.phone,
      assignedTo: isUnassigned ? '' : contact.name,
      assignedToUid: isUnassigned ? null : contact.uid,
      assignedToPhone: isUnassigned
          ? null
          : (Helpers.normalizePhone(contact.phone ?? '') ?? contact.phone),
      createdAt: now,
      updatedAt: now,
      teamId: teamId,
      extraFields: {
        'isDraft': true,
        'assigneeNames': isUnassigned ? <String>[] : <String>[contact.name],
        'assigneeUids': isUnassigned ? <String>[] : <String>[contact.uid ?? ''],
        'assigneePhones': isUnassigned
            ? <String>[]
            : <String>[
                Helpers.normalizePhone(contact.phone ?? '') ??
                    contact.phone ??
                    '',
              ],
      },
    );

    try {
      final id = await salesProvider.createEnquiry(enquiry);
      if (!mounted) return;
      if (id == null) return; // Blocked by plan limit (dialog already shown)

      // Navigate with the persisted row (milestones applied in the provider).
      final persisted = await salesProvider.persistedEnquiry(enquiry, id);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SalesDetailScreen(enquiry: persisted, moduleConfig: _config),
        ),
      );
    } on PlanLimitException catch (e) {
      if (!mounted) return;
      await showPaywallDialog(context, feature: e.feature, detail: e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to create enquiry: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Export the currently filtered sales enquiries
  void _exportCurrentView() {
    final salesProvider = _readProvider(context);
    final enquiries = salesProvider.filteredEnquiries;
    if (enquiries.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No enquiries to export')));
      return;
    }

    final headers = [
      '#',
      'Title',
      'Client',
      'Status',
      'Priority',
      'Created By',
      'Assigned To',
      'Deadline',
      'Progress',
      'Team',
      'Created',
    ];
    final rows = enquiries.map((e) {
      final status = e.status[0].toUpperCase() + e.status.substring(1);
      final priority = e.priority == 3
          ? 'High'
          : e.priority == 2
          ? 'Medium'
          : 'Low';
      final progress = '${(e.progress * 100).toInt()}%';
      final deadline = e.deadline != null
          ? DateFormat('dd/MM/yyyy').format(e.deadline!)
          : '';
      final created = DateFormat('dd/MM/yyyy').format(e.createdAt);
      final teamName = e.teamId != null
          ? (salesProvider.teams
                .firstWhere(
                  (t) => t.id == e.teamId,
                  orElse: () => SalesTeam(
                    id: '',
                    name: 'Unknown',
                    createdBy: '',
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                  ),
                )
                .name)
          : '';
      return [
        e.displayId?.toString() ?? '',
        e.title,
        e.clientName,
        status,
        priority,
        e.createdByName ?? '',
        e.assignedTo,
        deadline,
        progress,
        teamName,
        created,
      ];
    }).toList();

    final filterLabel = salesProvider.statusFilter == 'All'
        ? 'All'
        : (salesProvider.statusFilter == 'Unassigned'
              ? 'Assign later'
              : salesProvider.statusFilter);
    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Enquiries',
      filterLabel: filterLabel,
    );
  }

  // ── Filter Menu ────────────────────────────────────────────────────────

  void _showFilterMenu(BuildContext context) async {
    final authProvider = context.read<AuthProvider>();
    // Load the module's milestone templates before opening so the Milestone
    // submenu lists the actual pipeline steps.
    if (_milestoneTitles.isEmpty) {
      try {
        final templates = await MilestoneSettingsService(
          module: _isCrm ? 'crm' : 'sales',
        ).getEffectiveTemplates();
        if (!mounted) return;
        setState(() {
          _milestoneTitles = templates
              .map((t) => t.title)
              .where((t) => t.trim().isNotEmpty)
              .toList();
        });
      } catch (_) {
        // Submenu simply stays empty.
      }
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Compact header with drag handle
                Container(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.lightGrey,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // VIEW section (expandable)
                _buildSalesExpandableSection(
                  icon: Icons.visibility_outlined,
                  title: 'VIEW',
                  isExpanded: _menuExpandedSections.contains('view'),
                  onToggle: () {
                    setSheetState(() {
                      if (_menuExpandedSections.contains('view')) {
                        _menuExpandedSections.remove('view');
                      } else {
                        _menuExpandedSections.add('view');
                      }
                    });
                  },
                  children: [
                    _buildSalesCompactFilterOption(
                      setSheetState,
                      'All ${_pluralItemName()}',
                      Icons.folder_outlined,
                      'All',
                    ),
                    // Status options come from the module config so CRM shows
                    // Open/In Progress/Resolved/… instead of the Sales labels
                    // (hard-coded labels made CRM status filters silent no-ops).
                    for (var i = 0; i < _config.statusLabels.length; i++)
                      _buildSalesCompactFilterOption(
                        setSheetState,
                        _config.statusLabels[i],
                        _statusIconFor(_config.statusNames[i], i),
                        _config.statusLabels[i],
                      ),
                    _buildSalesCompactFilterOption(
                      setSheetState,
                      'Overdue',
                      Icons.warning_amber_rounded,
                      'Overdue',
                    ),
                    // Creator's own cards with no assignee yet (assign-later).
                    _buildSalesCompactFilterOption(
                      setSheetState,
                      'Unassigned',
                      Icons.person_off_outlined,
                      'Assign later',
                    ),
                    // Money & fulfilment views off the payment/delivery-tagged
                    // milestones (tagged in Milestone Settings, ticked by hand).
                    // CRM tickets carry no such kinds by default, so these
                    // stay in the Sales menu only.
                    if (!_isCrm) ...[
                      _buildSalesCompactFilterOption(
                        setSheetState,
                        'Payments Received',
                        Icons.payments,
                        'Payments Received',
                      ),
                      _buildSalesCompactFilterOption(
                        setSheetState,
                        'Payments Pending',
                        Icons.payments_outlined,
                        'Payments Pending',
                      ),
                      _buildSalesCompactFilterOption(
                        setSheetState,
                        'Delivered',
                        Icons.local_shipping,
                        'Delivered',
                      ),
                      _buildSalesCompactFilterOption(
                        setSheetState,
                        'Delivery Pending',
                        Icons.local_shipping_outlined,
                        'Delivery Pending',
                      ),
                    ],
                    // Milestone filter expands into a submenu listing each
                    // pipeline milestone — picking one shows cards where that
                    // step is still pending.
                    Builder(
                      builder: (menuCtx) {
                        final menuProvider = _readProvider(menuCtx);
                        final milestoneActive = menuProvider.statusFilter
                            .startsWith('Milestone: ');
                        return ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(
                            horizontal: 0,
                            vertical: -2,
                          ),
                          leading: Icon(
                            Icons.flag_outlined,
                            size: 18,
                            color: milestoneActive
                                ? _themeColor
                                : AppTheme.secondaryText,
                          ),
                          title: Text(
                            'Milestone',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: milestoneActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: milestoneActive
                                  ? _themeColor
                                  : AppTheme.primaryText,
                            ),
                          ),
                          trailing: Icon(
                            _menuExpandedSections.contains('milestone')
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 18,
                            color: AppTheme.secondaryText,
                          ),
                          onTap: () {
                            setSheetState(() {
                              if (_menuExpandedSections.contains('milestone')) {
                                _menuExpandedSections.remove('milestone');
                              } else {
                                _menuExpandedSections.add('milestone');
                              }
                            });
                          },
                        );
                      },
                    ),
                    if (_menuExpandedSections.contains('milestone'))
                      ..._milestoneTitles.map(
                        (title) => Padding(
                          padding: const EdgeInsets.only(left: 24),
                          child: _buildSalesCompactFilterOption(
                            setSheetState,
                            title,
                            Icons.radio_button_unchecked,
                            'Milestone: $title',
                          ),
                        ),
                      ),
                    _buildSalesCompactFilterOption(
                      setSheetState,
                      'Deleted',
                      Icons.delete_outline,
                      'Deleted',
                    ),
                    _buildSalesCompactFilterOption(
                      setSheetState,
                      'Archived',
                      Icons.archive_outlined,
                      'Archived',
                    ),
                  ],
                ),
                // SORT BY section (expandable)
                _buildSalesExpandableSection(
                  icon: Icons.sort,
                  title: 'SORT BY',
                  isExpanded: _menuExpandedSections.contains('sort'),
                  onToggle: () {
                    setSheetState(() {
                      if (_menuExpandedSections.contains('sort')) {
                        _menuExpandedSections.remove('sort');
                      } else {
                        _menuExpandedSections.add('sort');
                      }
                    });
                  },
                  children: [
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Last Action',
                      Icons.update,
                    ),
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Due Date',
                      Icons.calendar_today,
                    ),
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Priority',
                      Icons.star,
                    ),
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Created',
                      Icons.access_time,
                    ),
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Client',
                      Icons.sort_by_alpha,
                    ),
                    _buildSalesCompactSortOption(
                      setSheetState,
                      'Progress',
                      Icons.trending_up,
                    ),
                  ],
                ),
                // TOOLS section (expandable)
                _buildSalesExpandableSection(
                  icon: Icons.build_outlined,
                  title: 'TOOLS',
                  isExpanded: _menuExpandedSections.contains('tools'),
                  onToggle: () {
                    setSheetState(() {
                      if (_menuExpandedSections.contains('tools')) {
                        _menuExpandedSections.remove('tools');
                      } else {
                        _menuExpandedSections.add('tools');
                      }
                    });
                  },
                  children: [
                    _buildSalesCompactMenuOption(
                      'Manage Teams',
                      Icons.group,
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SalesTeamSettingsScreen(),
                          ),
                        );
                      },
                    ),
                    _buildSalesCompactMenuOption(
                      'Milestone Settings',
                      Icons.flag_outlined,
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SalesMilestoneSettingsScreen(
                              moduleConfig: _config,
                            ),
                          ),
                        );
                      },
                    ),
                    _buildSalesCompactMenuOption(
                      'Category Settings',
                      Icons.category_outlined,
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CategoriesScreen(
                              initialModule: _isCrm ? 'crm' : 'sales',
                            ),
                          ),
                        );
                      },
                    ),
                    _buildSalesCompactMenuOption(
                      'Export Current View',
                      Icons.download_outlined,
                      subtitle:
                          PaywallLimits.canExport(
                            authProvider.effectivePlanType,
                          )
                          ? 'CSV / Excel / PDF'
                          : 'Premium',
                      onTap: () {
                        final planType = authProvider.effectivePlanType;
                        if (!PaywallLimits.canExport(planType)) {
                          Navigator.pop(ctx);
                          showPaywallDialog(
                            context,
                            feature: 'Export is a Premium feature.',
                            detail:
                                'Upgrade to Premium to export enquiries to CSV, Excel and PDF.',
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        _exportCurrentView();
                      },
                    ),
                    _buildSalesCompactMenuOption(
                      'Reports',
                      Icons.analytics_outlined,
                      subtitle:
                          PaywallLimits.canInteractReports(
                            authProvider.effectivePlanType,
                          )
                          ? 'View reports'
                          : 'View only',
                      onTap: () {
                        Navigator.pop(ctx);
                        // Open the reports screen for every plan: free is
                        // read-only, premium adds tap-through + export.
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SalesReportsScreen(),
                          ),
                        );
                      },
                    ),
                    _buildSalesCompactMenuOption(
                      'Help & Support',
                      Icons.help_outline,
                      onTap: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Help center coming soon'),
                            duration: Duration(seconds: 2),
                            backgroundColor: _themeColor,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Expandable section header for sales
  Widget _buildSalesExpandableSection({
    required IconData icon,
    required String title,
    required bool isExpanded,
    required VoidCallback onToggle,
    required List<Widget> children,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: _themeColor, size: 18),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const Spacer(),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: AppTheme.secondaryText,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...children,
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  // Compact filter option for sales (no subtitle)
  Widget _buildSalesCompactFilterOption(
    StateSetter setSheetState,
    String label,
    IconData icon,
    String filterValue,
  ) {
    final salesProvider = _readProvider(context);
    final isSelected = salesProvider.statusFilter == filterValue;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? _themeColor : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? _themeColor : AppTheme.primaryText,
        ),
      ),
      trailing: isSelected
          ? Icon(Icons.check_circle, size: 16, color: _themeColor)
          : null,
      onTap: () {
        salesProvider.setStatusFilter(filterValue);
        Navigator.pop(context);
      },
    );
  }

  // Compact sort option for sales (no subtitle)
  Widget _buildSalesCompactSortOption(
    StateSetter setSheetState,
    String label,
    IconData icon,
  ) {
    final salesProvider = _readProvider(context);
    final isSelected = salesProvider.sortBy == label;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? _themeColor : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? _themeColor : AppTheme.primaryText,
        ),
      ),
      trailing: isSelected
          ? Icon(Icons.check, size: 16, color: _themeColor)
          : null,
      onTap: () {
        salesProvider.setSortBy(label);
        Navigator.pop(context);
      },
    );
  }

  // Compact menu option for sales (minimal subtitle)
  Widget _buildSalesCompactMenuOption(
    String label,
    IconData icon, {
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(icon, size: 18, color: AppTheme.secondaryText),
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppTheme.primaryText,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
            )
          : null,
      onTap: onTap,
    );
  }
}
