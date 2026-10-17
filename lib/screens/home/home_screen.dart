// Task module home — the app's REFERENCE IMPLEMENTATION.
// ⚠️ PARITY RULE: every correction and enhancement made here (and anywhere
// else in the Task module) MUST be replicated in the other modules
// (Sales, CRM, Inventory) — swipe actions, filters, dialogs, multi-select,
// navigation, log formatting, etc. See BaseModuleProvider's doc comment.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../services/contact_picker_service.dart';
import '../../services/avatar_cache_service.dart';
import '../../services/local_storage_service.dart';
import '../../services/premium_status_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';
import '../../utils/export_service.dart';
import '../../widgets/task_card.dart';
import '../../widgets/module_drawer.dart';
import '../../widgets/card_action_icons.dart';
import '../../widgets/card_widgets.dart';
import '../../services/item_links_service.dart';
import '../../modules/sales/services/milestone_settings_service.dart';
import '../../models/message.dart';
import '../dashboard/task_dashboard_screen.dart';
import '../../models/task.dart';
import '../task_detail/task_detail_screen.dart';
import '../reports/task_reports_screen.dart';
import '../../modules/sales/screens/sales_home_screen.dart';
import '../../modules/shared/module_config.dart';
import '../../modules/crm/screens/crm_home_screen.dart';
import '../settings/categories_screen.dart';
import '../task_detail/assignee_tasks_screen.dart';
import 'task_actions_screen.dart';
import 'task_team_settings_screen.dart';
import '../../modules/sales/screens/sales_milestone_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  /// When false, the startup "reopen last module" restore is skipped — used
  /// when this screen is pushed from the module drawer, otherwise the stale
  /// last_home_module pref would immediately bounce back to Sales/CRM.
  final bool restoreLastModule;
  const HomeScreen({super.key, this.restoreLastModule = true});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  late AuthProvider _authProvider;
  // Cached so dispose() can stop Task's Firestore list listeners when the
  // screen is replaced on a module switch — calling context.read here would
  // throw (element already deactivated).
  TaskProvider? _taskProvider;
  // Bottom nav: 0=Assignee, 1=My Tasks (BY ME/TO ME), 2=Actions, 3=Dashboard
  int _navIndex = 0;
  // Bell (attention mode) on the My Tasks tab: narrows the list to the last 2
  // open tasks that still have a pending action.
  bool _myTasksAttentionMode = false;
  // Tabs build lazily on first visit — only the Assignee landing tab is
  // built at startup. My Tasks / Actions / Dashboard build the first time
  // they are picked from the hamburger menu, so their lists never decode on
  // a cold start.
  final Set<int> _builtNavTabs = {0};
  // Bumped on each Dashboard visit so metrics recompute fresh
  int _dashboardEpoch = 0;
  bool get _showMyTabs => _navIndex == 1;
  final TextEditingController _searchController = TextEditingController();
  String _currentSort = 'Last Action'; // Default sort
  String _statusFilter = 'All'; // Default: show all statuses
  bool _hasLoadedTasks = false; // Prevent reloading
  String? _loadedTaskUserId; // Tracks which UID the active streams belong to
  String? _loadedTaskUserPhone; // Re-load when profile refresh adds a phone
  bool _showSearchBar = false; // Control search bar visibility

  /// When the app last left the foreground. A resume force-reload is skipped
  /// for brief unlocks (the SQLite change listeners keep the lists fresh while
  /// the process lives) and only paid after a long background.
  DateTime? _pausedAt;

  // Scroll controllers for By Me and To Me tabs (for scroll-to-task on back navigation)
  final ScrollController _byMeScrollController = ScrollController();
  final ScrollController _toMeScrollController = ScrollController();
  final Map<String, GlobalKey> _taskCardKeys = {};

  // WhatsApp-style multi-select state
  bool _isSelectionMode = false;
  Set<String> _selectedTaskIds = {};

  // Forwards 3-dot menu VIEW/SORT selections to the embedded assignee view
  final AssigneeTasksController _assigneeController = AssigneeTasksController();

  // Resets the embedded Actions tab's bell view when navigating away.
  final TaskActionsController _actionsController = TaskActionsController();

  // Menu expanded sections state
  Set<String> _menuExpandedSections = {
    'view',
  }; // Default: VIEW section expanded

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // Add lifecycle observer
    _tabController = TabController(
      length: 2,
      vsync: this,
    ); // By Me, To Me (My Tasks mode)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTasksForCurrentUser();
      // Warm the Premium/Basic and avatar lookups from SQLite right away so
      // card/picker crowns + avatars render before the delayed contact sync
      // refreshes the data
      PremiumStatusService().ensureLoaded();
      AvatarCacheService().ensureLoaded();
      // Pre-load contacts for faster picker opening — pushed past the
      // Firestore sync burst so phonebook deserialization never overlaps
      // the startup-critical window
      Future.delayed(const Duration(seconds: 8), () {
        if (mounted) ContactPickerService().preLoadContacts();
      });
      // Run local storage cleanup in background (once per day) — staggered
      // past the startup-critical window to avoid overlapping heavy work
      Future.delayed(const Duration(seconds: 12), () {
        if (mounted) LocalStorageService().cleanupOldMessages();
      });
      // NOTE: auto-backup is owned by the app root (_WhatWorksAppState in
      // main.dart), NOT here. This screen is replaced via pushReplacement for
      // Sales/CRM-primary users, so a trigger here would be disposed before it
      // fires for them; the root trigger is module-agnostic and always alive.
      // Reopen the module home that was on top when the app last closed
      // (Sales/CRM), instead of always landing on the Tasks home.
      // pushReplacement: modules never stack, so Back exits the app instead
      // of dropping into the Task module. Skipped for drawer switches.
      if (widget.restoreLastModule) {
        SharedPreferences.getInstance().then((prefs) {
          if (!mounted) return;
          final last =
              prefs.getString('last_home_module') ??
              // No explicit last module yet (fresh install / post-onboarding):
              // land on the business type's front-door module (Service Teams
              // for field service, Sales Teams for distribution, etc.).
              prefs.getString('preferred_home_module');
          if (last == 'sales') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const SalesHomeScreen(moduleConfig: ModuleConfig.sales),
              ),
            );
          } else if (last == 'crm') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const CrmHomeScreen()),
            );
          }
        });
      }
    });
  }

  // NOTE: no didChangeDependencies override — it fires BEFORE the first
  // build, so loading tasks there ran the whole SQLite pipeline pre-frame
  // and froze cold start. The post-frame callback above handles the initial
  // load; the guard in build() reschedules when the auth user changes.

  void _loadTasksForCurrentUser({bool force = false}) {
    _authProvider = context.read<AuthProvider>();
    final userId = _authProvider.userModel?.uid.trim() ?? '';
    final userPhone =
        Helpers.normalizePhone(_authProvider.userModel?.phone) ?? '';
    if (userId.isEmpty) return;
    if (!force &&
        _hasLoadedTasks &&
        _loadedTaskUserId == userId &&
        _loadedTaskUserPhone == userPhone) {
      return;
    }
    _hasLoadedTasks = true;
    _loadedTaskUserId = userId;
    _loadedTaskUserPhone = userPhone;
    final taskProvider = context.read<TaskProvider>();
    _taskProvider = taskProvider;
    taskProvider.loadTasks(userId, userPhone: userPhone);
    // Keep the default team name identical across modules: Task must carry the
    // same "My Team" default that Sales/CRM auto-create, otherwise the home
    // AppBar falls back to "Team One" here while those show "My Team".
    // Mirrors sales_home_screen._loadData (loadTeams restores the selection,
    // then ensureDefaultTeam creates "My Team" once per session).
    final planType = _authProvider.effectivePlanTypeFor('task');
    unawaited(
      taskProvider.loadTeams(userId).then(
        (_) => taskProvider.ensureDefaultTeam(userId, planType: planType),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh tasks on resume — but skip the full SQLite re-scan for brief
    // unlocks. The change listeners keep the lists fresh while the process
    // lives, so only a long background (where sync may have been suspended)
    // warrants the forced reload.
    if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt == null ||
          DateTime.now().difference(pausedAt) >=
              const Duration(seconds: 60)) {
        _loadTasksForCurrentUser(force: true);
      }
    }
    // Remember which module home was on top at closure so the next launch
    // can reopen it.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pausedAt = DateTime.now();
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString('last_home_module', 'task'),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // Remove lifecycle observer
    _tabController.dispose();
    _searchController.dispose();
    _byMeScrollController.dispose();
    _toMeScrollController.dispose();
    // Leaving the Task module (module switch uses pushReplacement, so this
    // dispose fires): drop its 4 list listeners. Only the visible module keeps
    // list sync alive — re-attach on return is a cheap watermark delta read.
    _taskProvider?.stopListSync();
    super.dispose();
  }

  // Show dialog for deleted tasks with Restore / Delete Permanently options
  void _showDeletedTaskDialog(TaskModel task, TaskProvider taskProvider) {
    final deletedDate = task.deletedAt != null
        ? Helpers.formatDate(task.deletedAt!)
        : 'unknown date';
    final myUid = _authProvider.userModel?.uid ?? '';
    // Restore / permanent-delete allowed for the creator OR the person who
    // deleted the task (an assignee can undo their own delete).
    final canManage = task.createdBy == myUid || task.deletedBy == myUid;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Deleted Task'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
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
              'Deleted tasks are permanently removed 30 days after deletion.',
              style: TextStyle(fontSize: 12, color: AppTheme.lightText),
            ),
            if (!canManage) ...[
              const SizedBox(height: 8),
              const Text(
                'Only the task creator or the person who deleted it can restore or permanently remove it.',
                style: TextStyle(fontSize: 12, color: AppTheme.lightText),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (canManage)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await taskProvider.restoreTask(task.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Task restored'),
                      backgroundColor: AppTheme.primaryGreen,
                    ),
                  );
                }
              },
              child: const Text(
                'Restore',
                style: TextStyle(color: AppTheme.primaryGreen),
              ),
            ),
          if (canManage)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await taskProvider.permanentlyDeleteTask(task.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Task permanently deleted'),
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
  }

  // Show dialog for archived tasks with Unarchive / Open options
  void _showArchivedTaskDialog(TaskModel task, TaskProvider taskProvider) {
    final archivedDate = task.archivedAt != null
        ? Helpers.formatDate(task.archivedAt!)
        : 'unknown date';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Archived Task'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
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
              'Archived tasks are kept forever — nothing is ever purged.',
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
              _navigateToTaskDetail(task);
            },
            child: const Text('Open'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await taskProvider.unarchiveTask(task.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Task unarchived'),
                    backgroundColor: AppTheme.primaryGreen,
                  ),
                );
              }
            },
            child: const Text(
              'Unarchive',
              style: TextStyle(color: AppTheme.primaryGreen),
            ),
          ),
        ],
      ),
    );
  }

  /// Archive all currently selected tasks (selection mode).
  Future<void> _archiveSelectedTasks() async {
    final taskProvider = context.read<TaskProvider>();
    final ids = List<String>.from(_selectedTaskIds);
    for (final id in ids) {
      await taskProvider.archiveTask(id);
    }
    _exitSelectionMode();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${ids.length} ${ids.length == 1 ? 'task' : 'tasks'} archived',
          ),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  /// Archive every completed (closed) task — TOOLS → Archive Completed.
  Future<void> _archiveCompletedTasks() async {
    final taskProvider = context.read<TaskProvider>();
    final completed = taskProvider.allTasks
        .where((t) => t.isClosed && !t.isDeleted && !t.isArchived)
        .toList();
    if (completed.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No completed tasks to archive')),
        );
      }
      return;
    }
    for (final t in completed) {
      await taskProvider.archiveTask(t.id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${completed.length} completed ${completed.length == 1 ? 'task' : 'tasks'} archived',
          ),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Navigate to Task Detail and refresh on return
  void _navigateToTaskDetail(
    TaskModel task, {
    String? scrollToMessageId,
  }) async {
    // Pre-fetch messages in background before navigation for faster loading
    if (mounted) {
      final taskProvider = context.read<TaskProvider>();
      taskProvider.fetchMessagesOnce(task.id);
    }
    await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TaskDetailScreen(task: task, scrollToMessageId: scrollToMessageId),
      ),
    );
    // Scroll position is preserved automatically by the ScrollController
    // No need to force reload or scroll-to-task — TaskProvider listens to SQLite changes
  }

  // ── Module Drawer (Hamburger Menu) — moved to widgets/module_drawer.dart

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    final authProvider = context.watch<AuthProvider>();
    _authProvider = authProvider;
    final userId = authProvider.userModel?.uid.trim() ?? '';
    final userPhone =
        Helpers.normalizePhone(authProvider.userModel?.phone) ?? '';
    if (userId.isNotEmpty &&
        (!_hasLoadedTasks ||
            _loadedTaskUserId != userId ||
            _loadedTaskUserPhone != userPhone)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadTasksForCurrentUser();
      });
    }

    final scaffold = Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        // Selection mode or normal mode
        title: _isSelectionMode
            ? Text(
                '${_selectedTaskIds.length} selected',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Line 1: module name headline ("WorkTracker") + premium
                  // badge — matches the Sales/CRM two-line home format.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          taskProvider.moduleAppBarName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 20,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (PaywallLimits.isPremium(
                        _authProvider.effectivePlanType,
                      )) ...[
                        const SizedBox(width: 8),
                        _buildProBadge(),
                      ],
                    ],
                  ),
                  // Line 2: current team (tappable → switcher), "Team One"
                  // when the team is unnamed.
                  GestureDetector(
                    onTap: () => _showTeamSwitcher(context, taskProvider),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.groups_outlined,
                          size: 12,
                          color: Colors.white.withOpacity(0.8),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            taskProvider.teamAppBarName,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.85),
                              fontWeight: FontWeight.w400,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (taskProvider.teams.length > 1)
                          const Icon(
                            Icons.arrow_drop_down,
                            color: Colors.white,
                            size: 18,
                          ),
                      ],
                    ),
                  ),
                  // Show active filter subtitle
                  if (_statusFilter != 'All')
                    Text(
                      'Filter: ${_statusFilter == 'Unassigned' ? 'Assign later' : _statusFilter}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.85),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
        // Selection mode actions - Delete + Archive + Quick Actions
        actions: _isSelectionMode
            ? [
                // Archive selected tasks (no purge, reversible)
                IconButton(
                  icon: const Icon(Icons.archive_outlined),
                  onPressed: _selectedTaskIds.isEmpty
                      ? null
                      : _archiveSelectedTasks,
                  tooltip: 'Archive',
                ),
                // Delete selected tasks (direct access)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _selectedTaskIds.isEmpty
                      ? null
                      : _confirmAndDeleteSelectedTasks,
                  tooltip: 'Delete',
                  color: Colors.red,
                ),
                // Quick Actions menu
                IconButton(
                  icon: const Icon(Icons.bolt_outlined),
                  onPressed: _selectedTaskIds.isEmpty
                      ? null
                      : _showQuickActionsDialog,
                  tooltip: 'Quick Actions',
                ),
                // Cancel selection
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelectionMode,
                  tooltip: 'Cancel',
                ),
              ]
            : [
                // Bell (attention mode) — My Tasks only: narrows the list to
                // the last 2 open tasks that still have a pending action.
                if (_navIndex == 1)
                  IconButton(
                    icon: Icon(
                      _myTasksAttentionMode
                          ? Icons.notifications_active
                          : Icons.notifications_active_outlined,
                    ),
                    color: _myTasksAttentionMode
                        ? const Color(0xFFC92A2A)
                        : Colors.white,
                    tooltip: _myTasksAttentionMode
                        ? 'Attention mode on — tap to turn off'
                        : 'Needs attention',
                    onPressed: () => setState(
                      () => _myTasksAttentionMode = !_myTasksAttentionMode,
                    ),
                  ),
                // Search icon (task list views only)
                if (_navIndex <= 1)
                  IconButton(
                    icon: Icon(_showSearchBar ? Icons.close : Icons.search),
                    onPressed: () {
                      setState(() {
                        _showSearchBar = !_showSearchBar;
                        if (!_showSearchBar) {
                          _searchController.clear();
                          taskProvider.setSearchQuery('');
                        }
                      });
                    },
                  ),
                // More options
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {
                    _showOptionsMenu(context);
                  },
                ),
              ],
      ),
      drawer: ModuleDrawer(
        activeModule: AppModule.task,
        activeViewIndex: _navIndex,
        onViewSelected: _onNavSelected,
        moduleViews: [
          DrawerNavItem(
            icon: Icons.assignment_ind_outlined,
            selectedIcon: Icons.assignment_ind,
            label: 'Assignee',
            color: AppTheme.headerGreen,
          ),
          DrawerNavItem(
            icon: Icons.people_alt_outlined,
            selectedIcon: Icons.people_alt,
            label: 'Track All',
            color: AppTheme.headerGreen,
          ),
          DrawerNavItem(
            icon: Icons.checklist,
            selectedIcon: Icons.checklist,
            label: 'Actions',
            color: AppTheme.headerGreen,
            badge: _attentionCount(taskProvider),
          ),
          DrawerNavItem(
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: 'Dashboard',
            color: AppTheme.headerGreen,
          ),
        ],
      ),
      body: Column(
          children: [
            // BY ME / TO ME tab bar (only in My Tasks mode)
            if (_showMyTabs)
              Container(
                color: Colors.white,
                child: TabBar(
                  controller: _tabController,
                  onTap: _isSelectionMode ? null : (index) {},
                  indicatorColor: AppTheme.primaryGreen,
                  indicatorWeight: 3,
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: AppTheme.primaryGreen,
                  unselectedLabelColor: AppTheme.secondaryText,
                  labelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                  tabs: const [
                    Tab(text: 'BY ME'),
                    Tab(text: 'TO ME'),
                  ],
                ),
              ),
            // Sync status indicator (visible in all builds when loading/errored)
            _buildSyncStatusIndicator(taskProvider),
            // Search bar and filters (WhatsApp style) - Only show when search is active
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
                      child: Column(
                        children: [
                          // WhatsApp-style search bar
                          Container(
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
                                hintText: 'Search tasks...',
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
                                          taskProvider.setSearchQuery('');
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
                                taskProvider.setSearchQuery(value);
                              },
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(), // Empty widget when search is hidden
            ),

            // Divider
            Container(height: 1, color: AppTheme.dividerColor),

            // Task list: assignee landing, or BY ME / TO ME in My Tasks mode
            Expanded(
              child: ColoredBox(
                color: Colors.white,
                child: IndexedStack(
                  index: _navIndex,
                  children: [
                    // ASSIGNEE: Person-scoped tasks with searchable picker
                    AssigneeTasksScreen(
                      embedded: true,
                      isActive: _navIndex == 0,
                      controller: _assigneeController,
                      // Chip-bar clears on the Assignee tab must also drop
                      // this screen's AppBar 'Filter:' subtitle.
                      onLocalFiltersCleared: () {
                        if (mounted) setState(() => _statusFilter = 'All');
                      },
                      // Same long-press selection behavior as the By Me tab
                      selectionMode: _isSelectionMode,
                      selectedTaskIds: _selectedTaskIds,
                      onLongPressTask: (task) {
                        if (task.isDeleted) {
                          _showDeletedTaskDialog(
                            task,
                            context.read<TaskProvider>(),
                          );
                        } else if (task.isArchived) {
                          _showArchivedTaskDialog(
                            task,
                            context.read<TaskProvider>(),
                          );
                        } else if (!_isSelectionMode) {
                          _enterSelectionMode(task.id);
                        }
                      },
                      onToggleSelection: (task) =>
                          _toggleTaskSelection(task.id),
                    ),
                    // MY TASKS: built lazily on first visit. It was eager
                    // before, so both full task lists decoded on every
                    // Assignee-tab frame even though only one tab shows.
                    _builtNavTabs.contains(1)
                        ? TabBarView(
                            controller: _tabController,
                            children: [
                              // BY ME: current user is the creator/assigner
                              _buildTaskList(
                                taskProvider.byMeTasks,
                                taskProvider,
                                showAssigner: true,
                                scrollController: _byMeScrollController,
                              ),
                              // TO ME: current user is an assignee
                              _buildTaskList(
                                taskProvider.toMeTasks,
                                taskProvider,
                                showAssigner: true,
                                showAssigneeName: false,
                                scrollController: _toMeScrollController,
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                    // ACTIONS: built lazily on first visit
                    _builtNavTabs.contains(2)
                        ? TaskActionsScreen(
                            embedded: true,
                            isActive: _navIndex == 2,
                            controller: _actionsController,
                          )
                        : const SizedBox.shrink(),
                    // DASHBOARD: built lazily, re-keyed per visit for fresh metrics
                    _builtNavTabs.contains(3)
                        ? TaskDashboardScreen(
                            key: ValueKey('dash$_dashboardEpoch'),
                            embedded: true,
                            isActive: _navIndex == 3,
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
              onPressed: () async {
                final taskProvider = context.read<TaskProvider>();
                final authProvider = context.read<AuthProvider>();

                // Parity with Sales: always let the user pick the assignee
                // from the contact picker (including "Unassigned - assign
                // later"), even when adding from the ASSIGNEE tab. The old
                // behaviour silently locked the new card to the currently
                // selected person with no chance to change it.
                  final contactPicker = ContactPickerService();
                  final contact = await contactPicker.showContactPicker(
                    context,
                    allowUnassigned: true,
                  );
                  if (contact != null && context.mounted) {
                    final bool unassigned = contact.isUnassigned;
                    try {
                      final scaffoldTask = TaskModel(
                        id: '',
                        title: '',
                        description: '',
                        createdBy: authProvider.userModel!.uid,
                        createdByName: authProvider.userModel!.name,
                        createdByPhone: authProvider.userModel?.phone,
                        assignedTo: unassigned ? '' : contact.name,
                        assignedToUid: unassigned ? null : contact.uid,
                        assignedToPhone: unassigned
                            ? null
                            : Helpers.normalizePhone(contact.phone),
                        participants: [
                          authProvider.userModel!.uid,
                          if (!unassigned &&
                              contact.uid != null &&
                              contact.uid!.isNotEmpty)
                            contact.uid!,
                        ],
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                        extraFields: {'isDraft': true},
                      );
                      final realId = await taskProvider.createTask(
                        scaffoldTask,
                        planType: authProvider.effectivePlanTypeFor('task'),
                      );
                      if (realId == null)
                        throw Exception('Failed to create task');
                      // Reload from SQLite so the detail screen sees applied
                      // default milestones / team stamp.
                      final realTask = await taskProvider.persistedTask(
                        scaffoldTask,
                        realId,
                      );
                      if (!context.mounted) return;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              TaskDetailScreen(task: realTask),
                        ),
                      );
                      // TaskProvider already listens to SQLite changes, no force reload needed
                    } on PlanLimitException catch (e) {
                      if (context.mounted) {
                        await showPaywallDialog(
                          context,
                          feature: e.feature,
                          detail: e.message,
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Failed to create task: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  }
              },
              foregroundColor: Colors.white,
              elevation: 3,
              highlightElevation: 5,
              backgroundColor: AppTheme.headerGreen,
              child: const Icon(Icons.add, color: Colors.white),
            ),
    );

    // Back button: exit selection → close search → clear filter → return to
    // Assignee tab → leave
    final bool hasActiveFilter = _statusFilter != 'All';
    return PopScope(
      canPop:
          !_isSelectionMode &&
          !_showSearchBar &&
          !hasActiveFilter &&
          _navIndex == 0,
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
          context.read<TaskProvider>().setSearchQuery('');
          return;
        }
        if (hasActiveFilter) {
          // Reset to the unfiltered view (also clears the Assignee tab)
          setState(() => _statusFilter = 'All');
          _assigneeController.setStatusFilter('All');
          return;
        }
        if (_navIndex != 0) {
          setState(() => _navIndex = 0);
        }
      },
      child: scaffold,
    );
  }

  /// Compact sync status chip shown below AppBar (all builds)
  Widget _buildSyncStatusIndicator(TaskProvider taskProvider) {
    final debug = taskProvider.debugInfo;
    final isLoading = debug['isLoading'] as bool? ?? false;
    final syncError = debug['syncError'] as String? ?? 'none';
    final lastSync = debug['lastSyncTime'] as String? ?? 'never';
    final rawByMe = debug['rawByMeCount'] as int? ?? 0;
    final rawToMe = debug['rawToMeCount'] as int? ?? 0;
    final useMock = debug['useMockData'] as bool? ?? false;

    // Don't show anything if synced and has data
    if (!isLoading &&
        syncError == 'none' &&
        lastSync != 'never' &&
        (rawByMe > 0 || rawToMe > 0)) {
      return const SizedBox.shrink();
    }

    // Don't show if never loaded yet and not loading (initial state)
    if (lastSync == 'never' && !isLoading && rawByMe == 0 && rawToMe == 0) {
      return const SizedBox.shrink();
    }

    // If we have data but also an error, show synced status (error is non-critical)
    if (!isLoading && (rawByMe > 0 || rawToMe > 0) && syncError != 'none') {
      // Silently ignore partial sync errors if we have data
      return const SizedBox.shrink();
    }

    Color bgColor;
    Color textColor;
    IconData icon;
    String text;

    if (syncError != 'none' && rawByMe == 0 && rawToMe == 0) {
      // Only show error if NO data loaded
      bgColor = Colors.red.shade50;
      textColor = Colors.red.shade700;
      icon = Icons.cloud_off;
      text = 'Sync failed - pull down to retry';
    } else if (isLoading) {
      bgColor = Colors.orange.shade50;
      textColor = Colors.orange.shade700;
      icon = Icons.cloud_sync;
      text = 'Syncing tasks...';
    } else if (useMock) {
      bgColor = Colors.blue.shade50;
      textColor = Colors.blue.shade700;
      icon = Icons.developer_mode;
      text = 'Demo mode - no cloud sync';
    } else {
      bgColor = Colors.grey.shade100;
      textColor = Colors.grey.shade700;
      icon = Icons.cloud_done;
      text = 'Synced: $rawByMe BY ME, $rawToMe TO ME';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (syncError != 'none')
            TextButton.icon(
              onPressed: () {
                if (_authProvider.userModel != null) {
                  _loadTasksForCurrentUser(force: true);
                }
              },
              icon: const Icon(Icons.refresh, size: 12),
              label: const Text('Retry', style: TextStyle(fontSize: 10)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  /// Get the currently filtered and sorted task list for export
  List<TaskModel> _getFilteredSortedTasks(List tasks) {
    List filteredTasks;
    if (_statusFilter == 'Deleted' || _statusFilter == 'Archived') {
      return [];
    }
    filteredTasks = tasks.where((task) {
      switch (_statusFilter) {
        case 'All':
          return true;
        case 'Active':
          return !task.isClosed &&
              !task.isCancelled &&
              task.extraFields?['isDraft'] != true &&
              task.extraFields?['isBlocked'] != true;
        case 'Blocked':
          return task.extraFields?['isBlocked'] == true;
        case 'Scheduled':
          return task.extraFields?['scheduledDate'] != null;
        case 'Completed':
          return task.isClosed;
        case 'Cancelled':
          return task.isCancelled;
        case 'Overdue':
          if (task.deadline == null || task.isClosed || task.isCancelled)
            return false;
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final deadlineDate = DateTime(
            task.deadline!.year,
            task.deadline!.month,
            task.deadline!.day,
          );
          return deadlineDate.isBefore(today);
        case 'High Priority':
          return task.priority == 3;
        case 'Urgent':
          return task.isUrgent == true;
        case 'Unassigned':
          // My own tasks still waiting to be assigned (assign-later).
          return task.createdBy == (_authProvider.userModel?.uid ?? '') &&
              task.assignedTo.isEmpty;
        default:
          return true;
      }
    }).toList();

    final sortedTasks = List<TaskModel>.from(filteredTasks);
    sortedTasks.sort((a, b) {
      switch (_currentSort) {
        case 'Last Action':
          return (b.updatedAt).compareTo(a.updatedAt);
        case 'Due Date':
        case 'Deadline':
          final dateA = a.deadline ?? DateTime(9999);
          final dateB = b.deadline ?? DateTime(9999);
          return dateA.compareTo(dateB);
        case 'Priority':
          return b.priority.compareTo(a.priority);
        case 'Created':
          return b.createdAt.compareTo(a.createdAt);
        case 'Name':
          return a.title.compareTo(b.title);
        case 'Progress':
          return a.progress.compareTo(b.progress);
        default:
          return 0;
      }
    });
    return sortedTasks;
  }

  /// Export the currently visible task list
  void _exportCurrentView(List tasks) {
    final filteredTasks = _getFilteredSortedTasks(tasks);
    if (filteredTasks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No tasks to export')));
      return;
    }

    final headers = [
      '#',
      'Title',
      'Status',
      'Priority',
      'Created By',
      'Assigned To',
      'Deadline',
      'Progress',
      'Created',
      'Last Activity',
    ];
    final rows = filteredTasks.map((task) {
      final status = task.isClosed
          ? 'Completed'
          : task.isCancelled
          ? 'Cancelled'
          : task.extraFields?['isBlocked'] == true
          ? 'Blocked'
          : 'Active';
      final priority = task.priority == 3
          ? 'High'
          : task.priority == 2
          ? 'Medium'
          : 'Low';
      final progress = '${(task.progress * 100).toInt()}%';
      final deadline = task.deadline != null
          ? DateFormat('dd/MM/yyyy').format(task.deadline!)
          : '';
      final created = DateFormat('dd/MM/yyyy').format(task.createdAt);
      final lastActivity = task.lastMessageTime != null
          ? DateFormat('dd/MM/yyyy').format(task.lastMessageTime!)
          : '';
      return [
        task.displayId?.toString() ?? '',
        task.title,
        status,
        priority,
        task.createdByName ?? '',
        task.assignedTo,
        deadline,
        progress,
        created,
        lastActivity,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Tasks',
      filterLabel: _statusFilter == 'All'
          ? 'All'
          : (_statusFilter == 'Unassigned' ? 'Assign later' : _statusFilter),
    );
  }

  /// Count of pending closure-type actions on a task — mirrors the
  /// Assignee screen's bell logic. A reply closes queries/requests/
  /// extensions; follow-ups and blockers stay open until marked done, so
  /// chips, the Pending line and this count can never disagree.
  int _pendingActionCount(String taskId, TaskProvider taskProvider) {
    try {
      final rows = taskProvider.getActionIcons(taskId);
      if (rows == null || rows.isEmpty) return 0;
      return rows
          .where(
            (r) => Helpers.isActionPending(
              r['actionType'] as String?,
              isDone: ((r['isDone'] as int?) ?? 0) != 0,
              isReplied: ((r['isReplied'] as int?) ?? 0) != 0,
            ),
          )
          .length;
    } catch (_) {
      return 0;
    }
  }

  Widget _buildTaskList(
    List tasks,
    TaskProvider taskProvider, {
    required bool showAssigner,
    bool showAssigneeName = true, // Default to showing assignee name
    bool showAllTasks = false,
    ScrollController? scrollController,
  }) {
    // Don't block UI with loading spinner — show existing data or empty state
    // Data arrives silently from Firestore streams in the background

    // The Deleted/Archived views source from taskProvider.deletedTasks /
    // archivedTasks, so they must be reachable even when the regular list
    // is empty
    if (tasks.isEmpty &&
        _statusFilter != 'Deleted' &&
        _statusFilter != 'Archived') {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: AppTheme.lightText.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? 'No matching tasks'
                  : 'No tasks yet',
              style: const TextStyle(
                fontSize: 18,
                color: AppTheme.secondaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? 'Try a different search'
                  : 'Tap the message icon to create your first task',
              style: const TextStyle(fontSize: 14, color: AppTheme.lightText),
            ),
          ],
        ),
      );
    }

    // Apply status filtering
    List filteredTasks;
    if (_statusFilter == 'Deleted') {
      // Show soft-deleted tasks from provider
      filteredTasks = taskProvider.deletedTasks;
    } else if (_statusFilter == 'Archived') {
      // Show archived tasks from provider (never purged)
      filteredTasks = taskProvider.archivedTasks;
    } else {
      filteredTasks = tasks.where((task) {
        switch (_statusFilter) {
          case 'All':
            // Show all tasks including completed and cancelled (deleted already excluded by provider)
            return true;
          case 'Active':
            // Active = not closed, not cancelled, not draft, not blocked
            return !task.isClosed &&
                !task.isCancelled &&
                task.extraFields?['isDraft'] != true &&
                task.extraFields?['isBlocked'] != true;
          case 'Blocked':
            // Blocked = an open blocker was raised on the task
            return task.extraFields?['isBlocked'] == true;
          case 'Scheduled':
            // Scheduled = has scheduledDate in extraFields
            return task.extraFields?['scheduledDate'] != null;
          case 'Completed':
            // Show only completed tasks
            return task.isClosed;
          case 'Cancelled':
            // Show only cancelled tasks
            return task.isCancelled;
          case 'Overdue':
            // Overdue = deadline passed and not closed
            if (task.deadline == null || task.isClosed || task.isCancelled)
              return false;
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            final deadlineDate = DateTime(
              task.deadline!.year,
              task.deadline!.month,
              task.deadline!.day,
            );
            return deadlineDate.isBefore(today);
          case 'High Priority':
            return task.priority == 3;
          case 'Urgent':
            return task.isUrgent == true;
          case 'Unassigned':
            // My own tasks still waiting to be assigned (assign-later).
            return task.createdBy == (_authProvider.userModel?.uid ?? '') &&
                task.assignedTo.isEmpty;
          default:
            return true;
        }
      }).toList();
    }

    // Apply sorting
    final sortedTasks = List.from(filteredTasks);
    sortedTasks.sort((a, b) {
      switch (_currentSort) {
        case 'Last Action':
          // Most recent activity first
          return (b.updatedAt ?? DateTime.now()).compareTo(
            a.updatedAt ?? DateTime.now(),
          );

        case 'Due Date':
          // Earliest deadline first
          final dateA = a.deadline ?? DateTime(9999);
          final dateB = b.deadline ?? DateTime(9999);
          return dateA.compareTo(dateB);

        case 'Priority':
          // Highest priority first (3 > 2 > 1)
          return (b.priority ?? 0).compareTo(a.priority ?? 0);

        case 'Created':
          // Newest first
          return (b.createdAt ?? DateTime.now()).compareTo(
            a.createdAt ?? DateTime.now(),
          );

        case 'Name':
          // Alphabetical by title
          return (a.title ?? '').compareTo(b.title ?? '');

        case 'Progress':
          // Lowest progress first
          return (a.progress ?? 0.0).compareTo(b.progress ?? 0.0);

        case 'Deadline':
          // Earliest deadline first (tasks without deadline at end)
          final dateA = a.deadline ?? DateTime(9999);
          final dateB = b.deadline ?? DateTime(9999);
          return dateA.compareTo(dateB);

        case 'Start Date':
          // Earliest start date first (tasks without start date at end)
          final startDateA = (a.extraFields?['startDate'] != null)
              ? DateTime.parse(a.extraFields!['startDate'])
              : DateTime(9999);
          final startDateB = (b.extraFields?['startDate'] != null)
              ? DateTime.parse(b.extraFields!['startDate'])
              : DateTime(9999);
          return startDateA.compareTo(startDateB);

        default:
          return 0;
      }
    });

    // Bell (attention mode) on My Tasks: narrow to EVERY open task that still
    // has a pending action (most recent first, per the active sort). No cap —
    // the bell promises "all tasks needing action", so hiding any would lie.
    List displayTasks = sortedTasks;
    if (_myTasksAttentionMode && !showAllTasks) {
      displayTasks = sortedTasks
          .where((t) =>
              !t.isClosed &&
              !t.isCancelled &&
              !t.isDeleted &&
              !t.isArchived &&
              _pendingActionCount(t.id, taskProvider) > 0)
          .toList();
    }

    final taskListView = RefreshIndicator(
      onRefresh: () async {
        if (_authProvider.userModel != null) {
          _loadTasksForCurrentUser(force: true);
        }
      },
      color: AppTheme.primaryGreen,
      child: ListView.builder(
        key: PageStorageKey(
          'taskList_${showAllTasks
              ? 'all'
              : showAssigner
              ? 'byMe'
              : 'toMe'}',
        ),
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        cacheExtent: 500, // Pre-build ~3 cards ahead for smoother scroll
        padding: EdgeInsets.zero,
        itemCount:
            displayTasks.length +
            (!_myTasksAttentionMode && taskProvider.hasMoreTasks ? 1 : 0),
        itemBuilder: (context, index) {
          // Load more indicator at the end
          if (index >= displayTasks.length) {
            // Trigger lazy loading when this widget builds
            if (!taskProvider.isLoadingMore) {
              taskProvider.loadMoreTasks();
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

          final task = displayTasks[index];

          // For ALL tab, show assignee name and avatar
          if (showAllTasks) {
            return _buildAllTaskCard(task);
          }

          final currentUid = _authProvider.userModel?.uid ?? '';
          final currentName = _authProvider.userModel?.name ?? '';
          final currentPhone = _authProvider.userModel?.phone ?? '';
          final isNewDraft = task.extraFields?['isDraft'] == true;
          final isDeletedTask = task.isDeleted;
          final isArchivedTask = task.isArchived;

          Widget card = TaskCard(
            task: task,
            showAssigner: showAssigner,
            showAssigneeName: showAssigneeName,
            currentUid: currentUid,
            currentName: currentName,
            currentPhone: currentPhone,
            pendingActions: _myTasksAttentionMode,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleTaskSelection(task.id);
              } else if (isDeletedTask) {
                // Show restore dialog for deleted tasks
                _showDeletedTaskDialog(task, taskProvider);
              } else if (isArchivedTask) {
                // Show unarchive dialog for archived tasks
                _showArchivedTaskDialog(task, taskProvider);
              } else {
                _navigateToTaskDetail(task);
              }
            },
            onLongPress: () {
              if (isDeletedTask) {
                // Long press on a deleted task offers Restore / Delete Forever
                _showDeletedTaskDialog(task, taskProvider);
              } else if (isArchivedTask) {
                _showArchivedTaskDialog(task, taskProvider);
              } else if (!_isSelectionMode) {
                _enterSelectionMode(task.id);
              }
            },
            isSelected: _isSelectionMode && _selectedTaskIds.contains(task.id),
          );

          // Deleted view purges first — a deleted task may still carry the
          // isDraft flag, and soft-deleting it again would snap the card back.
          if (isDeletedTask) {
            // Deleted view: swipe purges the card permanently.
            card = Dismissible(
              key: Key(task.id),
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
                  await context
                      .read<TaskProvider>()
                      .permanentlyDeleteTask(task.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Task deleted forever'),
                        backgroundColor: Color(0xFFC92A2A),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to delete task: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          } else if (isNewDraft) {
            // Wrap new draft tasks in Dismissible for swipe-to-remove.
            // (Checked AFTER the purge branch so deleted drafts purge too.)
            card = Dismissible(
              key: Key(task.id),
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
                  await context.read<TaskProvider>().deleteTask(task.id);
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
          } else if (isArchivedTask) {
            // Archived view: swipe unarchives the card back to normal views.
            card = Dismissible(
              key: Key(task.id),
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
                  await context.read<TaskProvider>().unarchiveTask(task.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Task unarchived'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to unarchive task: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          } else {
            // Real (non-draft) tasks swipe away to archive.
            card = Dismissible(
              key: Key(task.id),
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
                  await context.read<TaskProvider>().archiveTask(task.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Task archived'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to archive task: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: card,
            );
          }

          // Add GlobalKey for scroll-to-task
          _taskCardKeys[task.id] = GlobalKey();
          return KeyedSubtree(key: _taskCardKeys[task.id], child: card);
        },
      ),
    );

    // Purge notice banner for the Deleted view
    if (_statusFilter == 'Deleted') {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.grey.withOpacity(0.08),
            child: const Row(
              children: [
                Icon(
                  Icons.auto_delete_outlined,
                  size: 14,
                  color: AppTheme.lightText,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Swipe a card to delete it forever. Unused deletes are purged after 30 days.',
                    style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: taskListView),
        ],
      );
    }

    // Info banner for the Archived view
    if (_statusFilter == 'Archived') {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: AppTheme.primaryGreen.withOpacity(0.08),
            child: const Row(
              children: [
                Icon(
                  Icons.archive_outlined,
                  size: 14,
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Swipe a card to unarchive it, or tap it for more options.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: taskListView),
        ],
      );
    }
    return taskListView;
  }

  /// Returns true if [s] looks like a Firebase UID (20+ chars, no spaces, alphanumeric)
  bool _looksLikeUid(String s) => Helpers.looksLikeUid(s);

  Widget _buildAllTaskCard(dynamic task) {
    // Determine if current user created this task or was assigned
    final currentUid = _authProvider.userModel?.uid ?? '';
    final currentName = _authProvider.userModel?.name ?? '';
    // Unread message count for current user (WhatsApp-style badge)
    final int unreadCount = currentUid.isEmpty
        ? 0
        : (task.unreadCounts[currentUid] ?? 0);
    final isCreatedByUser =
        task.createdBy == currentUid || task.createdBy == currentName;
    final creatorDisplay = isCreatedByUser
        ? 'Me'
        : (task.createdByName?.isNotEmpty == true &&
                  task.createdByName!.toLowerCase() != 'user'
              ? task.createdByName!
              : (_looksLikeUid(task.createdBy) ? 'Someone' : task.createdBy));
    final assignedDisplay =
        task.assignedToUid == currentUid ||
            task.assignedTo == currentUid ||
            task.assignedTo == currentName ||
            task.assignedTo.toLowerCase() == 'me'
        ? 'Me'
        : task.assignedTo;
    final displayName = isCreatedByUser ? creatorDisplay : assignedDisplay;
    final displayInitials = Helpers.getInitials(displayName);

    // Avatar of the shown person (photo or preset) — synchronous lookup;
    // own avatar for 'Me'
    final shownAvatarUrl = displayName == 'Me'
        ? AvatarCacheService().urlFor(uid: currentUid, name: currentName)
        : isCreatedByUser
        ? AvatarCacheService().urlFor(
            uid: task.assignedToUid,
            name: displayName,
          )
        : AvatarCacheService().urlFor(uid: task.createdBy, name: displayName);

    // Get status-based color (same as TaskCard)
    final directionColor = _getTaskStatusColor(task);
    final directionIcon = isCreatedByUser
        ? Icons.call_made
        : Icons.call_received;

    // Milestone chip — same rule as TaskCard (visible only while
    // milestones are enabled in Tools → Milestone Settings).
    final showMilestoneChip =
        task.milestones.isNotEmpty &&
        MilestoneSettingsService.isEnabledSync('task');
    final completedMilestones = task.completedMilestoneCount;

    // Line-2 state tiles, hoisted so line 1 can reserve a strip at least as
    // wide as the one they render (user rule: the tile strip must never
    // outdent the line-1 chip on the left).
    final urgencyState = CardFlagTile.stateFor(
      isUrgent: task.isUrgent,
      isBlocked: task.extraFields?['isBlocked'] == true,
      urgencyState: task.extraFields?['urgencyState'] as String?,
    );
    final hasLinks = ItemLinksService()
        .linksOf(task.extraFields as Map<String, dynamic>?)
        .isNotEmpty;
    final tilesStrip = CardStateTiles.stripWidth(
      urgency: urgencyState != 'none',
      links: hasLinks,
      milestone: showMilestoneChip,
    );

    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () {
            if (task.isDeleted) {
              // Long press on a deleted task offers Restore / Delete Forever
              _showDeletedTaskDialog(task, context.read<TaskProvider>());
            } else if (task.isArchived) {
              _showArchivedTaskDialog(task, context.read<TaskProvider>());
            } else if (!_isSelectionMode) {
              _enterSelectionMode(task.id);
            }
          },
          child: InkWell(
            onTap: () {
              if (_isSelectionMode) {
                _toggleTaskSelection(task.id);
              } else if (task.isDeleted) {
                final taskProvider = context.read<TaskProvider>();
                _showDeletedTaskDialog(task, taskProvider);
              } else if (task.isArchived) {
                final taskProvider = context.read<TaskProvider>();
                _showArchivedTaskDialog(task, taskProvider);
              } else {
                _navigateToTaskDetail(task);
              }
            },
            child: Container(
              color: _isSelectionMode && _selectedTaskIds.contains(task.id)
                  ? AppTheme.primaryGreen.withOpacity(0.08)
                  : Colors.transparent,
              height: 96,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 0,
                ),
                child: Row(
                  children: [
                    // Avatar with direction badge — shared (CardWidgets)
                    CardAvatarBadge(
                      initials: displayInitials,
                      avatarColor: AppTheme.primaryGreen,
                      badgeColor: directionColor,
                      badgeIcon: directionIcon,
                      avatarUrl: shownAvatarUrl,
                    ),
                    const SizedBox(width: 12),

                    // Content - Clean 3 lines
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Line 1: Name + draft badge
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                    color: AppTheme.secondaryText,
                                    height: 1.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (task.extraFields?['isDraft'] == true) ...[
                                const SizedBox(width: 4),
                                const DraftChip(),
                              ],
                              const SizedBox(width: 6),
                              CardChipsRow(
                                chips: CardActionIcons.taskChips(
                                  context,
                                  task.id,
                                  task.lastMessageText,
                                  baseColor: AppTheme.primaryGreen,
                                  // Fill the reserved strip: the pill's left
                                  // edge then IS the strip's left edge, and the
                                  // line-2 tiles below can never outdent it.
                                  fill: true,
                                ),
                                // The pill fills a strip at least as wide as
                                // the line-2 tile group below (user rule); 68
                                // matches TaskCard's slot width.
                                width: tilesStrip > 68 ? tilesStrip : 68,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),

                          // Line 2: title with the right-aligned
                          // state tiles (milestone / urgency flag / links) moved
                          // up from line 3 so the last-message line owns the
                          // full width — parity with the redesigned TaskCard.
                          // No #number here (user rule, task module only).
                          Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        task.title.length > 50
                                            ? '${task.title.substring(0, 50)}...'
                                            : task.title,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.primaryTextOn(
                                            context,
                                          ),
                                          height: 1.2,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              CardStateTiles(
                                urgencyState: urgencyState,
                                hasLinks: hasLinks,
                                accentColor: AppTheme.primaryGreen,
                                milestoneLabel: showMilestoneChip
                                    ? 'M$completedMilestones'
                                    : null,
                                // Fixed slot so the rendered strip matches
                                // stripWidth() reserved on line 1.
                                trailingSlotWidth: cardTrailingSlotWidth,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),

                          // Line 3: meta | side Row 3 flag/link tiles
                          Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                              // Last message preview · relative time (parity
                              // with TaskCard): leads with "<Action>: <details>"
                              // via the shared Helpers.cardPreviewText, text
                              // EXPANDED so the time
                              // pins flush right regardless of length.
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        Helpers.cardPreviewText(
                                          task.lastMessageText,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.secondaryText,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (Helpers.cardPreviewText(
                                      task.lastMessageText,
                                    ).isNotEmpty)
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        child: Text(
                                          '·',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: AppTheme.secondaryText,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      Helpers.getRelativeTime(
                                        task.lastMessageTime ?? task.updatedAt,
                                      ),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.secondaryText,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Pending-read count in the Task module green —
                              // hidden for deleted tasks
                              CardUnreadPill(
                                count: task.isDeleted ? 0 : unreadCount,
                                color: AppTheme.primaryGreen,
                              ),
                                  ],
                                ),
                              ),
                              // State tiles moved up to line 2 so the
                              // last-message line now spans the full width.
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Vertical progress bar — dashed, right-aligned, matching
                    // TaskCard. The unread pill rides the timestamp line, so the
                    // bar is never covered and the action icons keep their
                    // flush-right slot
                    CardProgressStack(
                      progress: task.progress,
                      isClosed: task.isClosed,
                      createdAt: task.createdAt,
                      deadline: task.deadline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1, indent: 76),
      ],
    );
  }

  /// Get color based on task status (shared — cardStatusColor)
  Color _getTaskStatusColor(dynamic task) => cardStatusColor(
    isCancelled: task.isCancelled,
    isClosed: task.isClosed,
    extraFields: task.extraFields,
  );

  // WhatsApp-style selection mode methods

  // Enter selection mode
  void _enterSelectionMode(String taskId) {
    setState(() {
      _isSelectionMode = true;
      _selectedTaskIds.add(taskId);
    });
  }

  // Exit selection mode
  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedTaskIds.clear();
    });
  }

  // ── Bottom navigation ────────────────────────────────────────

  /// R3: memoize the badge count on the provider [revision] so pure rebuilds
  /// (scroll, tab switch) reuse the last number instead of re-merging
  /// byMe+toMe and re-scanning action icons on every frame. It recomputes
  /// exactly once per data change (each notify bumps [revision]).
  int _attRevision = -1;
  int _attCache = 0;

  /// Pending closure-action count across all open tasks — the red badge on
  /// the hamburger menu's Actions entry.
  int _attentionCount(TaskProvider p) {
    if (p.revision == _attRevision) return _attCache;
    int n = 0;
    final seen = <String>{};
    for (final t in [...p.byMeTasks, ...p.toMeTasks]) {
      if (!seen.add(t.id)) continue;
      if (t.isClosed || t.isCancelled || t.isDeleted || t.isArchived) continue;
      final rows = p.getActionIcons(t.id);
      if (rows == null) continue;
      for (final r in rows) {
        // Same shared rule as _pendingActionCount / chips / Actions tab
        // (Helpers.isActionPending): done closes everything, a reply closes
        // queries/requests/extensions, other closure types stay open.
        if (Helpers.isActionPending(
          r['actionType'] as String?,
          isDone: ((r['isDone'] as int?) ?? 0) != 0,
          isReplied: ((r['isReplied'] as int?) ?? 0) != 0,
        )) {
          n++;
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
        _selectedTaskIds.clear();
      }
      if (clearSearch) {
        _showSearchBar = false;
        _searchController.clear();
      }
      // Tapping a nav button drops the 3-dot menu filter (and its AppBar
      // subtitle) so every tab opens on its unfiltered view.
      _statusFilter = 'All';
      _navIndex = index;
      _builtNavTabs.add(index);
      if (index == 3) _dashboardEpoch++;
    });
    // Leaving the Actions tab clears its bell/attention view.
    if (index != 2) _actionsController.resetAttentionMode();
    // Keep the embedded Assignee tab in sync with the cleared filter.
    _assigneeController.setStatusFilter('All');
    if (clearSearch) context.read<TaskProvider>().setSearchQuery('');
  }

  // Toggle task selection
  void _toggleTaskSelection(String taskId) {
    setState(() {
      if (_selectedTaskIds.contains(taskId)) {
        _selectedTaskIds.remove(taskId);
        // If no tasks selected, exit selection mode
        if (_selectedTaskIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedTaskIds.add(taskId);
      }
    });
  }

  // Show Quick Actions dialog for selected tasks
  void _showQuickActionsDialog() {
    if (_selectedTaskIds.isEmpty) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Quick Actions for ${_selectedTaskIds.length} task${_selectedTaskIds.length > 1 ? 's' : ''}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(height: 1),
            // 1. Cancel
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.red.withOpacity(0.1),
                radius: 18,
                child: const Icon(
                  Icons.cancel_outlined,
                  color: Colors.red,
                  size: 20,
                ),
              ),
              title: const Text(
                'Cancel',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                'Mark tasks as cancelled',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _updateSelectedTasksStatus(isClosed: false, isCancelled: true);
              },
            ),
            const Divider(height: 1),
            // 2. Complete
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.green.withOpacity(0.1),
                radius: 18,
                child: const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 20,
                ),
              ),
              title: const Text(
                'Complete',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                'Mark tasks as completed',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _updateSelectedTasksStatus(isClosed: true, isCancelled: false);
              },
            ),
            const Divider(height: 1),
            // 3. Remind
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.blue.withOpacity(0.1),
                radius: 18,
                child: const Icon(
                  Icons.notifications_active,
                  color: Colors.blue,
                  size: 20,
                ),
              ),
              title: const Text(
                'Remind',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                'Send reminder to assignees',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _sendRemindersForSelectedTasks();
              },
            ),
            const Divider(height: 1),
            // 4. Follow Up Today
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.orange.withOpacity(0.1),
                radius: 18,
                child: const Icon(Icons.today, color: Colors.orange, size: 20),
              ),
              title: const Text(
                'Follow Up Today',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                'Schedule follow-up for today',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _scheduleFollowUpForSelectedTasks(DateTime.now());
              },
            ),
            const Divider(height: 1),
            // 5. Follow Up Tomorrow
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.purple.withOpacity(0.1),
                radius: 18,
                child: const Icon(
                  Icons.calendar_today,
                  color: Colors.purple,
                  size: 20,
                ),
              ),
              title: const Text(
                'Follow Up Tomorrow',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                'Schedule follow-up for tomorrow',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _scheduleFollowUpForSelectedTasks(
                  DateTime.now().add(const Duration(days: 1)),
                );
              },
            ),
            // 6. Delete
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.red.withOpacity(0.1),
                radius: 18,
                child: const Icon(
                  Icons.delete_outline,
                  color: Colors.red,
                  size: 20,
                ),
              ),
              title: const Text(
                'Delete',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.red,
                ),
              ),
              subtitle: const Text(
                'Permanently delete selected tasks',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAndDeleteSelectedTasks();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Update status for selected tasks
  Future<void> _updateSelectedTasksStatus({
    required bool isClosed,
    required bool isCancelled,
  }) async {
    final taskProvider = context.read<TaskProvider>();
    final authProvider = context.read<AuthProvider>();
    final currentUserId = authProvider.userModel?.uid ?? '';
    final currentUserName = authProvider.userModel?.name ?? '';

    int updatedCount = 0;

    // Combine both task lists to find selected tasks
    final allTasks = [...taskProvider.byMeTasks, ...taskProvider.toMeTasks];

    for (final taskId in _selectedTaskIds) {
      try {
        // Find the task
        final matchingTasks = allTasks.where((t) => t.id == taskId).toList();
        if (matchingTasks.isEmpty) continue;
        final task = matchingTasks.first;

        // Update the task
        final updatedTask = task.copyWith(
          isClosed: isClosed,
          isCancelled: isCancelled,
          extraFields: isCancelled || isClosed
              ? (task.extraFields
                  ?..remove('isDraft')
                  ..remove('scheduledDate'))
              : task.extraFields,
          updatedAt: DateTime.now(),
        );

        await taskProvider.updateTask(taskId, updatedTask);

        // Send system message for status change (same format as Task Detail screen)
        final timestamp = Helpers.formatDateTime(DateTime.now());
        final statusName = isCancelled ? 'Cancelled' : 'Completed';
        final statusMessage = MessageModel(
          id: Helpers.generateId(),
          taskId: taskId,
          senderId: currentUserId, // Use actual user ID, not 'system'
          text:
              '📊 Status changed: Active → $statusName by $currentUserName at $timestamp',
          type: MessageType.system,
          createdAt: DateTime.now(),
          deliveryMethod: 'in-app',
        );

        await taskProvider.sendMessage(taskId, statusMessage);

        updatedCount++;
      } catch (e) {
        print('[HomeScreen] Error updating task $taskId: $e');
      }
    }

    // Exit selection mode
    _exitSelectionMode();

    // Small delay to ensure Firebase stream emits updated tasks
    // TaskProvider will filter out closed/cancelled tasks automatically
    await Future.delayed(const Duration(milliseconds: 300));

    // Show confirmation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$updatedCount task${updatedCount > 1 ? 's' : ''} ${isCancelled ? 'cancelled' : 'completed'}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: isCancelled
              ? const Color(0xFFE03131)
              : const Color(0xFF1976D2),
        ),
      );
    }
  }

  // Confirm and delete selected tasks (only for creator)
  Future<void> _confirmAndDeleteSelectedTasks() async {
    if (_selectedTaskIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Tasks'),
        content: Text(
          'Are you sure you want to permanently delete ${_selectedTaskIds.length} task${_selectedTaskIds.length > 1 ? 's' : ''}? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final taskProvider = context.read<TaskProvider>();
    int deletedCount = 0;
    int failedCount = 0;

    for (final taskId in List<String>.from(_selectedTaskIds)) {
      try {
        await taskProvider.deleteTask(taskId);
        deletedCount++;
      } catch (e) {
        failedCount++;
        print('[HomeScreen] Error deleting task $taskId: $e');
      }
    }

    _exitSelectionMode();

    if (mounted) {
      final message = failedCount > 0
          ? '$deletedCount deleted, $failedCount failed'
          : '$deletedCount task${deletedCount > 1 ? 's' : ''} deleted';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          backgroundColor: failedCount > 0
              ? Colors.orange
              : const Color(0xFFE03131),
        ),
      );
    }
  }

  // Send reminders for selected tasks
  Future<void> _sendRemindersForSelectedTasks() async {
    final taskProvider = context.read<TaskProvider>();
    final authProvider = context.read<AuthProvider>();
    final currentUserId = authProvider.userModel?.uid ?? '';
    final currentUserName = authProvider.userModel?.name ?? '';

    int remindedCount = 0;

    // Combine both task lists to find selected tasks
    final allTasks = [
      ...taskProvider.byMeTasks,
      ...taskProvider.toMeTasks,
      ...taskProvider.participantTasks,
    ];
    final selectedTasks = allTasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList();

    for (final task in selectedTasks) {
      try {
        // Send reminder message to task chat
        final timestamp = Helpers.formatDateTime(DateTime.now());
        final reminderMsg = MessageModel(
          id: Helpers.generateId(),
          taskId: task.id,
          senderId: currentUserId,
          text: '🔔 Reminder sent by $currentUserName at $timestamp',
          type: MessageType.system,
          createdAt: DateTime.now(),
          deliveryMethod: 'in-app',
        );

        context.read<TaskProvider>().sendMessage(task.id, reminderMsg);
        remindedCount++;
      } catch (e) {
        print('Error sending reminder for task ${task.id}: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reminder sent to $remindedCount task${remindedCount > 1 ? 's' : ''}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.blue,
        ),
      );
    }

    _exitSelectionMode();
  }

  // Schedule follow-up for selected tasks
  Future<void> _scheduleFollowUpForSelectedTasks(DateTime followUpDate) async {
    final taskProvider = context.read<TaskProvider>();
    final authProvider = context.read<AuthProvider>();
    final currentUserId = authProvider.userModel?.uid ?? '';
    final currentUserName = authProvider.userModel?.name ?? '';

    int scheduledCount = 0;
    final dateLabel = followUpDate.day == DateTime.now().day
        ? 'today'
        : 'tomorrow';

    // Combine both task lists to find selected tasks
    final allTasks = [
      ...taskProvider.byMeTasks,
      ...taskProvider.toMeTasks,
      ...taskProvider.participantTasks,
    ];
    final selectedTasks = allTasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList();

    for (final task in selectedTasks) {
      try {
        // Send follow-up message to task chat
        final timestamp = Helpers.formatDateTime(DateTime.now());
        final followUpDateStr = Helpers.formatDate(followUpDate);
        final followUpMsg = MessageModel(
          id: Helpers.generateId(),
          taskId: task.id,
          senderId: currentUserId,
          text:
              '📅 Follow-up scheduled for $followUpDateStr ($dateLabel) by $currentUserName at $timestamp',
          type: MessageType.system,
          createdAt: DateTime.now(),
          deliveryMethod: 'in-app',
        );

        context.read<TaskProvider>().sendMessage(task.id, followUpMsg);

        // Update task's updatedAt to move it to top of list
        final updatedTask = task.copyWith(updatedAt: DateTime.now());
        await taskProvider.updateTask(task.id, updatedTask);

        scheduledCount++;
      } catch (e) {
        print('Error scheduling follow-up for task ${task.id}: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Follow-up scheduled for $scheduledCount task${scheduledCount > 1 ? 's' : ''} $dateLabel',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.orange,
        ),
      );
    }

    _exitSelectionMode();
  }

  /// Premium badge shown next to the AppBar title.
  Widget _buildProBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withOpacity(0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium, size: 12, color: Colors.amber.shade800),
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
    );
  }

  /// Show team switcher bottom sheet.
  void _showTeamSwitcher(BuildContext context, TaskProvider provider) {
    final teams = provider.teams;
    final currentTeamId = provider.currentTeamId;
    final auth = context.read<AuthProvider>();
    // Gate on the TASK module plan — a Business subscription bought for
    // another module must not unlock multi-team here (and vice versa).
    final planType = auth.effectivePlanTypeFor('task');
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
                  Icon(
                    Icons.group_work,
                    color: AppTheme.primaryGreen,
                    size: 20,
                  ),
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
                  activeColor: AppTheme.primaryGreen,
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
                    ? Icon(Icons.check, color: AppTheme.primaryGreen, size: 20)
                    : null,
                onTap: isLocked
                    ? () {
                        Navigator.pop(ctx);
                        showPaywallDialog(
                          context,
                          feature: 'Switch between multiple task teams.',
                          detail: 'Premium unlocks up to ${PaywallLimits.maxTeams('premium')} teams per module.',
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
              leading: Icon(Icons.settings, color: AppTheme.primaryGreen),
              title: Text(
                'Manage Teams',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: AppTheme.primaryGreen,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TaskTeamSettingsScreen(),
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
    TaskProvider provider,
    String teamId,
    String planType,
  ) async {
    final success = await provider.switchTeam(teamId, planType: planType);
    if (!success) {
      showPaywallDialog(
        context,
        feature: 'Switch between multiple task teams.',
        detail: 'Premium unlocks up to ${PaywallLimits.maxTeams('premium')} teams per module.',
      );
    }
  }

  void _showOptionsMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
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
                _buildExpandableSection(
                  icon: Icons.visibility_outlined,
                  title: 'VIEW',
                  isExpanded: _menuExpandedSections.contains('view'),
                  onToggle: () {
                    setModalState(() {
                      if (_menuExpandedSections.contains('view')) {
                        _menuExpandedSections.remove('view');
                      } else {
                        _menuExpandedSections.add('view');
                      }
                    });
                  },
                  children: [
                    _buildCompactFilterOption(
                      setModalState,
                      'All Tasks',
                      Icons.folder_outlined,
                      'All',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Active',
                      Icons.play_circle_outline,
                      'Active',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Scheduled',
                      Icons.calendar_today,
                      'Scheduled',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Completed',
                      Icons.check_circle_outline,
                      'Completed',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Cancelled',
                      Icons.cancel_outlined,
                      'Cancelled',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Blocked',
                      Icons.block,
                      'Blocked',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Deleted',
                      Icons.delete_outline,
                      'Deleted',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Archived',
                      Icons.archive_outlined,
                      'Archived',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Overdue',
                      Icons.warning_amber_rounded,
                      'Overdue',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'High Priority',
                      Icons.star,
                      'High Priority',
                    ),
                    _buildCompactFilterOption(
                      setModalState,
                      'Urgent',
                      Icons.local_fire_department,
                      'Urgent',
                    ),
                    // Creator's own tasks with no assignee yet (assign-later).
                    _buildCompactFilterOption(
                      setModalState,
                      'Unassigned',
                      Icons.person_off_outlined,
                      'Assign later',
                    ),
                  ],
                ),
                // SORT BY section (expandable)
                _buildExpandableSection(
                  icon: Icons.sort,
                  title: 'SORT BY',
                  isExpanded: _menuExpandedSections.contains('sort'),
                  onToggle: () {
                    setModalState(() {
                      if (_menuExpandedSections.contains('sort')) {
                        _menuExpandedSections.remove('sort');
                      } else {
                        _menuExpandedSections.add('sort');
                      }
                    });
                  },
                  children: [
                    _buildCompactSortOption(
                      setModalState,
                      'Last Action',
                      Icons.update,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Due Date',
                      Icons.calendar_today,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Priority',
                      Icons.star,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Created',
                      Icons.access_time,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Name',
                      Icons.person,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Progress',
                      Icons.trending_up,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Deadline',
                      Icons.calendar_today,
                    ),
                    _buildCompactSortOption(
                      setModalState,
                      'Start Date',
                      Icons.event_note,
                    ),
                  ],
                ),
                // TOOLS section (expandable)
                _buildExpandableSection(
                  icon: Icons.build_outlined,
                  title: 'TOOLS',
                  isExpanded: _menuExpandedSections.contains('tools'),
                  onToggle: () {
                    setModalState(() {
                      if (_menuExpandedSections.contains('tools')) {
                        _menuExpandedSections.remove('tools');
                      } else {
                        _menuExpandedSections.add('tools');
                      }
                    });
                  },
                  children: [
                    _buildCompactMenuOption(
                      'Archive Completed',
                      Icons.archive_outlined,
                      onTap: () {
                        Navigator.pop(context);
                        _archiveCompletedTasks();
                      },
                    ),
                    _buildCompactMenuOption(
                      'Category Settings',
                      Icons.category_outlined,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const CategoriesScreen(initialModule: 'task'),
                          ),
                        );
                      },
                    ),
                    _buildCompactMenuOption(
                      'Milestone Settings',
                      Icons.flag_outlined,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SalesMilestoneSettingsScreen(
                              isTaskModule: true,
                            ),
                          ),
                        );
                      },
                    ),
                    _buildCompactMenuOption(
                      'Manage Teams',
                      Icons.groups_outlined,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const TaskTeamSettingsScreen(),
                          ),
                        );
                      },
                    ),
                    _buildCompactMenuOption(
                      'Export Current View',
                      Icons.download_outlined,
                      subtitle:
                          PaywallLimits.canExport(
                            _authProvider.effectivePlanType,
                          )
                          ? 'CSV / Excel / PDF'
                          : 'Premium',
                      onTap: () {
                        final planType = _authProvider.effectivePlanType;
                        if (!PaywallLimits.canExport(planType)) {
                          Navigator.pop(context);
                          showPaywallDialog(
                            context,
                            feature: 'Export is a Premium feature.',
                            detail:
                                'Upgrade to Premium to export tasks to CSV, Excel and PDF.',
                          );
                          return;
                        }
                        Navigator.pop(context);
                        final taskProvider = context.read<TaskProvider>();
                        _exportCurrentView(taskProvider.allTasks);
                      },
                    ),
                    _buildCompactMenuOption(
                      'Reports',
                      Icons.analytics_outlined,
                      subtitle:
                          PaywallLimits.canInteractReports(
                            _authProvider.effectivePlanType,
                          )
                          ? 'View reports'
                          : 'View only',
                      onTap: () {
                        Navigator.pop(context);
                        // Open the Task Reports screen for every plan: free is
                        // read-only, premium adds tap-through + export.
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const TaskReportsScreen(),
                          ),
                        );
                      },
                    ),
                    _buildCompactMenuOption(
                      'Help & Support',
                      Icons.help_outline,
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Help center coming soon'),
                            duration: Duration(seconds: 2),
                            backgroundColor: AppTheme.primaryGreen,
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

  // Expandable section header
  Widget _buildExpandableSection({
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
                Icon(icon, color: AppTheme.headerGreen, size: 18),
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

  // Compact filter option (no subtitle)
  Widget _buildCompactFilterOption(
    StateSetter setModalState,
    String label,
    IconData icon,
    String filterValue,
  ) {
    final isSelected = _statusFilter == filterValue;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? AppTheme.primaryGreen : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? AppTheme.primaryGreen : AppTheme.primaryText,
        ),
      ),
      trailing: isSelected
          ? const Icon(
              Icons.check_circle,
              size: 16,
              color: AppTheme.primaryGreen,
            )
          : null,
      onTap: () {
        setModalState(() {
          _statusFilter = filterValue;
        });
        setState(() {
          _statusFilter = filterValue;
        });
        // Keep the assignee landing view in sync with the same filter
        _assigneeController.setStatusFilter(filterValue);
        Navigator.pop(context);
      },
    );
  }

  // Compact sort option (no subtitle)
  Widget _buildCompactSortOption(
    StateSetter setModalState,
    String label,
    IconData icon,
  ) {
    final isSelected = _currentSort == label;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? AppTheme.primaryGreen : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? AppTheme.primaryGreen : AppTheme.primaryText,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, size: 16, color: AppTheme.primaryGreen)
          : null,
      onTap: () {
        setModalState(() {
          _currentSort = label;
        });
        setState(() {
          _currentSort = label;
        });
        // Keep the assignee landing view in sync with the same sort
        _assigneeController.setSortBy(label);
        Navigator.pop(context);
      },
    );
  }

  // Compact menu option (minimal subtitle)
  Widget _buildCompactMenuOption(
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
