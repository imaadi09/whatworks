import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/action_item.dart';
import '../../models/task.dart';
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../services/avatar_cache_service.dart';
import '../../services/local_database_service.dart';
import '../../utils/constants.dart';
import '../../utils/export_service.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';
import '../../widgets/dashed_progress_bar.dart';
import '../../widgets/card_action_icons.dart';
import '../../widgets/actions_filter_ui.dart';
import '../../modules/shared/module_config.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/visibility_gated_tab.dart';
import '../task_detail/task_detail_screen.dart';

/// Handle so the home screen can clear the Actions tab's bell view when
/// the user navigates away (attention mode is session-only).
class TaskActionsController {
  _TaskActionsScreenState? _state;

  /// Clear the bell/attention view (called when leaving the Actions tab).
  void resetAttentionMode() => _state?._resetAttentionMode();
}

/// Full-screen Actions view for the Task module.
/// Pushed on demand, or embedded in the home bottom-nav ACTIONS tab.
class TaskActionsScreen extends StatefulWidget {
  /// When true, renders without its own AppBar (home provides the chrome).
  final bool embedded;

  /// Optional handle so the home screen can reset the bell view.
  final TaskActionsController? controller;

  /// Whether this tab is the currently-visible one. The home [IndexedStack]
  /// keeps every visited tab mounted, so a hidden tab must NOT re-run its
  /// expensive actions/tasks queries on every sync notification — that is what
  /// froze the UI when several tabs were alive at once. A hidden tab only flags
  /// [_TaskActionsScreenState._pendingRefresh] and catches up once on becoming
  /// visible again. Defaults to true so a full-screen push always stays live.
  final bool isActive;
  const TaskActionsScreen({
    super.key,
    this.embedded = false,
    this.controller,
    this.isActive = true,
  });

  @override
  State<TaskActionsScreen> createState() => _TaskActionsScreenState();
}

class _TaskActionsScreenState extends State<TaskActionsScreen>
    with VisibilityGatedTabState {
  // Action items state (moved from home_screen.dart)
  // Two-axis filter (mirrors the assignee Actions tab): a time chip row
  // plus an optional action type picked from the sheet.
  String _timeFilter = kActionTimeToday;
  String? _typeFilter;
  static const _timeOptions = kActionTimeOptions;
  // Derive the Type filter from Task's OWN action catalog (ModuleConfig.task)
  // so the dropdown lists exactly the actions Task offers, with canonical
  // labels. Warning / Extension / Progress are no longer Task actions (the
  // Visit tile replaced Warning; extension/progress were never on the sheet),
  // so they drop out — any legacy row of those types still shows under
  // 'All types'. Values are the catalog keys, resolved to ActionType by
  // [_typeFilterToActionType] below.
  List<ActionFilterOption> get _typeOptions =>
      actionTypeFilterOptions(ModuleConfig.task.actionTypes);
  final Set<String> _hiddenActionIds = {}; // Track hidden action items
  final Set<String> _expandedActionCards = {};
  // Attention mode (bell toggle): shows the pending-actions summary strip AND
  // selects the 'Needs Attention' time chip, so the bell genuinely filters the
  // list instead of only annotating it. Session-only: the home screen clears
  // it when leaving the Actions tab.
  bool _attentionMode = false;

  /// Shared bell handler (embedded header + AppBar): flip the mode and drive
  /// the time filter to match — off restores the default Today chip.
  void _toggleAttention() {
    setState(() {
      _attentionMode = !_attentionMode;
      _timeFilter = _attentionMode ? 'Needs Attention' : kActionTimeToday;
    });
  }

  /// Clear the bell view; called via [TaskActionsController] when the home
  /// screen navigates away from the Actions tab.
  void _resetAttentionMode() {
    if (_attentionMode) {
      setState(() {
        _attentionMode = false;
        _timeFilter = kActionTimeToday;
      });
    }
  }

  List<ActionItem> _currentActionItems =
      []; // Currently visible actions (for export)
  Future<List<Map<String, dynamic>>>?
  _actionsFuture; // Cache actions query future
  // R6.2: cache the all-tasks lookup-map future. It was created inline in the
  // builder (future: taskProvider.getAllTasks(userId)), so it re-ran a full
  // getTasks on EVERY rebuild of the actions list. The cached future is stable
  // between rebuilds and invalidated ONLY on real data-change events — the
  // tasks-table listener below (task edits/deletes/creates), plus tab-active and
  // time-filter — never "load once for the screen lifetime".
  Future<List<TaskModel>>? _allTasksFuture;
  StreamSubscription? _actionsTableSub; // Listen for actions table changes
  StreamSubscription?
  _tasksTableSub; // R6.2: invalidate _allTasksFuture on task-row changes

  // Visibility gating (see [VisibilityGatedTabState]): a hidden tab defers its
  // full-scan reload and catches up once when shown again.
  @override
  bool get isActiveTab => widget.isActive;
  @override
  void onTabBecameActive() => setState(() {
    _actionsFuture = null;
    _allTasksFuture = null;
  });

  // Pagination: render at most this many task cards, growing as the user
  // scrolls near the bottom (keeps huge action sets responsive).
  static const int _actionCardsPageSize = 50;
  int _visibleActionCards = _actionCardsPageSize;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    // Listen for actions table changes to refresh the list. Debounced so a
    // burst of writes (e.g. startup backfill) triggers a single reload.
    _actionsTableSub = LocalDatabaseService()
        .tableChangesDebounced('actions')
        .listen((_) {
          if (!mounted) return;
          // Hidden tab: don't re-fetch (the reload is a full tasks scan); just
          // remember to catch up when the tab is shown again.
          if (isTabHidden) {
            deferRefresh();
            return;
          }
          // Invalidate cached future so FutureBuilder re-fetches
          setState(() {
            _actionsFuture = null;
            _allTasksFuture = null;
          });
        });
    // R6.2: _allTasksFuture reads the TASKS table, so it must also refresh when
    // task rows genuinely change — title/assignee edits, deletes, or new tasks
    // that don't touch the actions table. Without this the cached map goes stale
    // until the tab is re-activated. Mirrors the actions listener: debounced,
    // hidden-tab deferral, invalidate-on-change (future stays stable between
    // rebuilds). _actionsFuture is left alone — action ROWS come from the
    // actions table, and the joined view reads task fields from this map.
    _tasksTableSub = LocalDatabaseService()
        .tableChangesDebounced('tasks')
        .listen((_) {
          if (!mounted) return;
          if (isTabHidden) {
            deferRefresh();
            return;
          }
          setState(() {
            _allTasksFuture = null;
          });
        });
  }

  /// SQL pre-filter for the current chip. Returns a superset of what the Dart
  /// filter keeps (the Dart re-filter below stays the source of truth), so
  /// results never change — this only shrinks the rows loaded from SQLite.
  /// Only provably-equivalent predicates are pushed down: date ranges (via the
  /// scheduledDate→createdAt fallback) and single-actionType chips. Keyword
  /// chips (Reminders / Follow Up) and the ⚠️-aware Warning chip stay broad.
  Future<List<Map<String, dynamic>>> _loadActionRows() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int startMs(DateTime d) =>
        DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
    int endMs(DateTime d) => DateTime(
      d.year,
      d.month,
      d.day,
      23,
      59,
      59,
      999,
    ).millisecondsSinceEpoch;

    int? dateFrom;
    int? dateTo;
    switch (_timeFilter) {
      case 'Overdue':
        dateTo = startMs(today) - 1; // before today
        break;
      case 'Today':
        dateFrom = startMs(today);
        dateTo = endMs(today);
        break;
      case 'Upcoming':
        dateFrom = startMs(today.add(const Duration(days: 1)));
        break;
      // 'Needs Attention' and 'All' both keep a broad query (narrowed in Dart
      // below — 'All' by nothing but the optional type axis).
    }

    return LocalDatabaseService().getAllActions(
      parentType: 'task',
      dateFrom: dateFrom,
      dateTo: dateTo,
      dateUsesCreatedFallback: true,
    );
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _actionsTableSub?.cancel();
    _tasksTableSub?.cancel();
    super.dispose();
  }

  /// Pending-actions summary by type (mirrors the assignee screen strip).
  Widget _buildNeedsAttentionStrip() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _actionsFuture,
      builder: (context, snap) {
        // One shared pending rule (Helpers.isActionPending) + the module-agnostic
        // label map, so this banner can never drift from the Needs Attention
        // filter or the nav badge. Reads raw actions-table rows (canonical keys).
        final counts = <String, int>{};
        for (final r in snap.data ?? const <Map<String, dynamic>>[]) {
          final type = r['actionType'] as String? ?? '';
          if (!Helpers.actionClosureTypes.contains(type)) continue;
          if (!Helpers.isActionPending(
            type,
            isDone: (r['isDone'] as int? ?? 0) == 1,
            isReplied: (r['isReplied'] as int? ?? 0) == 1,
          )) {
            continue;
          }
          counts[type] = (counts[type] ?? 0) + 1;
        }
        final parts = Helpers.actionAttentionLabels.entries
            .where((e) => (counts[e.key] ?? 0) > 0)
            .map((e) => '${counts[e.key]} ${e.value}')
            .toList();
        if (parts.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: AppTheme.lightGrey.withOpacity(0.25),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.pending_actions,
                size: 13,
                color: Color(0xFFC92A2A),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Needs Attention: ${parts.join(' · ')}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.secondaryText,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Returns true if [s] looks like a Firebase UID (20+ chars, no spaces, alphanumeric)
  bool _looksLikeUid(String s) =>
      s.length >= 20 &&
      !s.contains(' ') &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

  // Navigate to Task Detail (pre-fetch messages for faster loading)
  void _navigateToTaskDetail(
    TaskModel task, {
    String? scrollToMessageId,
  }) async {
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
  }

  /// Export the currently visible action items (paywall-guarded)
  void _exportActionsGuarded() {
    final authProvider = context.read<AuthProvider>();
    final planType = authProvider.effectivePlanType;
    if (!PaywallLimits.canExport(planType)) {
      showPaywallDialog(
        context,
        feature: 'Export is a Premium feature.',
        detail: 'Upgrade to Premium to export actions to CSV, Excel and PDF.',
      );
      return;
    }
    _exportActions();
  }

  /// Export the currently visible action items
  void _exportActions() {
    final items = List<ActionItem>.from(_currentActionItems);
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No actions to export')));
      return;
    }

    String typeLabel(ActionItem a) {
      switch (a.type) {
        case ActionType.reminder:
          return 'Reminder';
        case ActionType.followUp:
          return a.isFollowUpDone ? 'Follow-up (Done)' : 'Follow-up';
        case ActionType.warning:
          return 'Warning';
        case ActionType.query:
          return a.isReplied ? 'Query (Replied)' : 'Query';
        case ActionType.blocker:
          return a.isFollowUpDone ? 'Blocker (Resolved)' : 'Blocker';
        case ActionType.approval:
          return a.isReplied ? 'Request - Actioned' : 'Request Action';
        case ActionType.extension:
          return a.isReplied ? 'Extension (Actioned)' : 'Extension Request';
        case ActionType.progressReport:
          return 'Progress Report';
        case ActionType.cash:
          return 'Cash';
        case ActionType.call:
          return a.isFollowUpDone ? 'Call (Done)' : 'Call';
        case ActionType.meeting:
          return a.isFollowUpDone ? 'Meeting (Done)' : 'Meeting';
        case ActionType.siteVisit:
          return a.isFollowUpDone ? 'Visit (Done)' : 'Visit';
      }
    }

    final headers = [
      '#',
      'Type',
      'Task',
      'Detail',
      'Scheduled',
      'Created By',
      'Assigned To',
      'Status',
    ];
    final df = DateFormat('dd/MM/yyyy hh:mm a');
    var i = 1;
    final rows = items.map((a) {
      final status = a.type == ActionType.query
          ? (a.isReplied ? 'Replied' : 'Pending')
          : a.type == ActionType.followUp
          ? (a.isFollowUpDone ? 'Done' : 'Pending')
          : (a.isCompleted ? 'Done' : 'Pending');
      return [
        '${i++}',
        typeLabel(a),
        a.taskTitle,
        a.message,
        df.format(a.scheduledDate),
        a.createdBy,
        a.assignedTo,
        status,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Actions',
      filterLabel: _typeFilter != null
          ? '$_timeFilter / ${ModuleConfig.task.actionFor(_typeFilter!)?.label ?? _typeFilter!}'
          : _timeFilter,
    );
  }

  /// Create a self-assigned draft task (was the home ACTIONS-tab FAB)
  Future<void> _createSelfTask() async {
    final taskProvider = context.read<TaskProvider>();
    final authProvider = context.read<AuthProvider>();
    final currentUser = authProvider.userModel;
    if (currentUser != null && context.mounted) {
      try {
        final scaffoldTask = TaskModel(
          id: '',
          title: '',
          description: '',
          createdBy: currentUser.uid,
          createdByName: currentUser.name,
          assignedTo: currentUser.name,
          assignedToUid: currentUser.uid,
          assignedToPhone: Helpers.normalizePhone(currentUser.phone),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          extraFields: {'isDraft': true},
        );
        final realId = await taskProvider.createTask(
          scaffoldTask,
          planType: authProvider.effectivePlanTypeFor('task'),
        );
        if (realId == null) throw Exception('Failed to create task');
        // Reload from SQLite so the detail screen sees applied default
        // milestones / team stamp.
        final realTask = await taskProvider.persistedTask(scaffoldTask, realId);
        if (!context.mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TaskDetailScreen(task: realTask),
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
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    if (widget.embedded) {
      // Embedded in the home bottom-nav tab: slim header instead of AppBar
      return Scaffold(
        backgroundColor: Colors.white,
        body: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Text(
                    'Actions',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _attentionMode
                          ? Icons.notifications_active
                          : Icons.notifications_active_outlined,
                      size: 20,
                      color: _attentionMode
                          ? const Color(0xFFC92A2A)
                          : AppTheme.secondaryText,
                    ),
                    tooltip: 'Needs Attention',
                    onPressed: _toggleAttention,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.download_outlined,
                      color: AppTheme.secondaryText,
                    ),
                    tooltip: 'Export Current View',
                    onPressed: _exportActionsGuarded,
                  ),
                ],
              ),
            ),
            Expanded(child: _buildActionItemsTab(taskProvider)),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _createSelfTask,
          backgroundColor: AppTheme.headerGreen,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Actions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _attentionMode
                  ? Icons.notifications_active
                  : Icons.notifications_active_outlined,
              color: Colors.white,
            ),
            tooltip: 'Needs Attention',
            onPressed: _toggleAttention,
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined, color: Colors.white),
            tooltip: 'Export',
            onPressed: _exportActionsGuarded,
          ),
        ],
      ),
      body: _buildActionItemsTab(taskProvider),
      floatingActionButton: FloatingActionButton(
        onPressed: _createSelfTask,
        backgroundColor: AppTheme.headerGreen,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildActionItemsTab(TaskProvider taskProvider) {
    final authProvider = context.read<AuthProvider>();
    final userId = authProvider.userModel?.uid ?? '';

    // Cache the future so it's only created once (per chip/filter selection)
    _actionsFuture ??= _loadActionRows();
    // R6.2: cache the all-tasks map future too (was inline in the builder).
    _allTasksFuture ??= taskProvider.getAllTasks(userId);

    // Filter row outside FutureBuilder — never rebuilds on data changes
    return Column(
      children: [
        // Pending-actions summary shows only while the bell is on.
        if (_attentionMode) _buildNeedsAttentionStrip(),
        _buildActionsFilterRow(),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _actionsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                print(
                  '[TaskActionsScreen] Error loading actions: ${snapshot.error}',
                );
              }

              final actionRows = snapshot.data ?? [];

              // Load all tasks for action items (not just paginated first page)
              return FutureBuilder<List<TaskModel>>(
                future: _allTasksFuture,
                builder: (context, taskSnapshot) {
                  if (!taskSnapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // Build task map from ALL tasks
                  final allTasks = <dynamic>[];
                  final seenIds = <String>{};
                  final taskMap = <String, dynamic>{};
                  for (final task in taskSnapshot.data!) {
                    if (!seenIds.contains(task.id)) {
                      allTasks.add(task);
                      seenIds.add(task.id);
                      taskMap[task.id] = task;
                    }
                  }

                  // Convert action rows to ActionItem objects
                  final allActionItems = <ActionItem>[];
                  for (final row in actionRows) {
                    final parentId = row['parentId'] as String;
                    final task = taskMap[parentId];
                    // Skip actions for tasks not in our list
                    if (task == null) continue;

                    final actionTypeStr = row['actionType'] as String;
                    final messageText = row['text'] as String;

                    // Skip "deadline updated" actions - not relevant for Actions view
                    if (messageText.toLowerCase().contains('deadline updated'))
                      continue;

                    final ActionType actionType;
                    switch (actionTypeStr) {
                      case 'reminder':
                        actionType = ActionType.reminder;
                        break;
                      case 'followup':
                        actionType = ActionType.followUp;
                        break;
                      case 'warning':
                        actionType = ActionType.warning;
                        break;
                      case 'query':
                        actionType = ActionType.query;
                        break;
                      case 'blocker':
                        actionType = ActionType.blocker;
                        break;
                      case 'approval':
                        actionType = ActionType.approval;
                        break;
                      case 'extension':
                        actionType = ActionType.extension;
                        break;
                      case 'progress':
                        actionType = ActionType.progressReport;
                        break;
                      case 'cash':
                      // 💳 receivable cards ride the Cash tile (Sales parity).
                      case 'payment':
                        actionType = ActionType.cash;
                        break;
                      case 'call':
                        actionType = ActionType.call;
                        break;
                      case 'meeting':
                        actionType = ActionType.meeting;
                        break;
                      case 'sitevisit':
                        actionType = ActionType.siteVisit;
                        break;
                      default:
                        continue;
                    }

                    final scheduledDateMs = row['scheduledDate'] as int?;
                    final createdAtMs = row['createdAt'] as int;
                    final scheduledDate = scheduledDateMs != null
                        ? DateTime.fromMillisecondsSinceEpoch(scheduledDateMs)
                        : DateTime.fromMillisecondsSinceEpoch(createdAtMs);

                    allActionItems.add(
                      ActionItem(
                        id: row['id'] as String,
                        taskId: parentId,
                        taskTitle:
                            row['parentTitle'] as String? ?? task.title ?? '',
                        type: actionType,
                        message: row['text'] as String,
                        scheduledDate: scheduledDate,
                        hasScheduledDate: scheduledDateMs != null,
                        createdAt: DateTime.fromMillisecondsSinceEpoch(
                          createdAtMs,
                        ),
                        createdBy: task.createdBy,
                        assignedTo: task.assignedTo,
                        isCompleted: false,
                        messageId: row['id'] as String,
                        isReplied: (row['isReplied'] as int) == 1,
                        isFollowUpDone: (row['isDone'] as int) == 1,
                        seqNo: row['seqNo'] as int?,
                      ),
                    );
                  }

                  // No action items yet
                  if (allActionItems.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 64,
                            color: AppTheme.lightText,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No action items yet',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Actions scheduled in tasks will appear here',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.lightText,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final now = DateTime.now();
                  final today = DateTime(now.year, now.month, now.day);

                  // Time axis, then optional type axis (mirrors assignee tab).
                  List<ActionItem> filteredItems;
                  switch (_timeFilter) {
                    case 'Overdue':
                      filteredItems = allActionItems.where((item) {
                        final d = DateTime(
                          item.scheduledDate.year,
                          item.scheduledDate.month,
                          item.scheduledDate.day,
                        );
                        // Overdue = a still-PENDING action whose REAL scheduled
                        // date passed. Requires a genuine committed date
                        // (hasScheduledDate) so undated actions can never pile
                        // here on their write date, and gates on the shared
                        // predicate to keep informational logs out.
                        return item.hasScheduledDate &&
                            d.isBefore(today) &&
                            _isPendingAction(item);
                      }).toList();
                    case 'Today':
                      filteredItems = allActionItems.where((item) {
                        final d = DateTime(
                          item.scheduledDate.year,
                          item.scheduledDate.month,
                          item.scheduledDate.day,
                        );
                        return d == today;
                      }).toList();
                    case 'Upcoming':
                      filteredItems = allActionItems.where((item) {
                        final d = DateTime(
                          item.scheduledDate.year,
                          item.scheduledDate.month,
                          item.scheduledDate.day,
                        );
                        return d.isAfter(today);
                      }).toList();
                    // No time filter — the type axis below still applies.
                    case kActionTimeAll:
                      filteredItems = allActionItems;
                    default:
                      filteredItems = allActionItems
                          .where(_isPendingAction)
                          .toList();
                  }
                  final type = _typeFilterToActionType(_typeFilter);
                  if (type != null) {
                    filteredItems = filteredItems
                        .where((item) => item.type == type)
                        .toList();
                  }

                  // Filter out hidden items
                  final visibleItems = filteredItems
                      .where((item) => !_hiddenActionIds.contains(item.id))
                      .toList();

                  // Sort descending by creation time: latest first
                  visibleItems.sort(
                    (a, b) => CardActionIcons.compareActions(
                      a.scheduledDate,
                      a.createdAt,
                      b.scheduledDate,
                      b.createdAt,
                    ),
                  );

                  // Cache for export
                  _currentActionItems = visibleItems;

                  return visibleItems.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.check_circle_outline,
                                size: 64,
                                color: AppTheme.lightText,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No action items',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppTheme.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        )
                      : _buildGroupedActionList(visibleItems, taskProvider);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  ActionType? _typeFilterToActionType(String? filter) {
    // The Type dropdown values are Task's catalog keys (see [_typeOptions]),
    // so map each key straight to its ActionType enum for the type-axis
    // filter. Warning / Extension / Progress have no case: they are no longer
    // Task actions, so they can never be selected from the dropdown.
    switch (filter) {
      case 'reminder':
        return ActionType.reminder;
      case 'followup':
        return ActionType.followUp;
      case 'query':
        return ActionType.query;
      case 'blocker':
        return ActionType.blocker;
      case 'approval':
        return ActionType.approval;
      case 'cash':
        return ActionType.cash;
      case 'call':
        return ActionType.call;
      case 'meeting':
        return ActionType.meeting;
      case 'sitevisit':
        return ActionType.siteVisit;
      default:
        return null;
    }
  }

  bool _isPendingAction(ActionItem i) => Helpers.isActionPending(
    i.type.key,
    isDone: i.isFollowUpDone,
    isReplied: i.isReplied,
  );

  // Reusable filter row: time chips + type bar (mirrors assignee Actions tab)
  Widget _buildActionsFilterRow() {
    return buildActionFilterDropdowns(
      timeOptions: _timeOptions,
      selectedTime: _timeFilter,
      onTimeChanged: (v) => setState(() {
        _timeFilter = v;
        // Time drives the SQL pre-filter, so drop the cached future.
        _actionsFuture = null;
        _allTasksFuture = null;
        _visibleActionCards = _actionCardsPageSize;
      }),
      typeOptions: _typeOptions,
      selectedType: _typeFilter,
      onTypeChanged: (v) => setState(() {
        _typeFilter = v;
        _visibleActionCards = _actionCardsPageSize;
      }),
    );
  }

  // Builds the task-grouped action list (one card per task)
  Widget _buildGroupedActionList(
    List<ActionItem> items,
    TaskProvider taskProvider,
  ) {
    // Group actions by task
    final taskActions = <String, List<ActionItem>>{};
    final taskMap = <String, dynamic>{};
    final allAvailableTasks = [
      ...taskProvider.byMeTasks,
      ...taskProvider.toMeTasks,
    ];
    for (final task in allAvailableTasks) {
      taskMap[task.id] = task;
    }
    for (final item in items) {
      taskActions.putIfAbsent(item.taskId, () => []).add(item);
    }
    // Sort tasks by most recent action first
    final sortedTaskIds = taskActions.keys.toList();
    sortedTaskIds.sort((a, b) {
      final actionsA = taskActions[a]!;
      final actionsB = taskActions[b]!;
      final keyA = actionsA
          .map(
            (x) =>
                CardActionIcons.actionSortTuple(x.scheduledDate, x.createdAt),
          )
          .reduce(CardActionIcons.minActionTuple);
      final keyB = actionsB
          .map(
            (x) =>
                CardActionIcons.actionSortTuple(x.scheduledDate, x.createdAt),
          )
          .reduce(CardActionIcons.minActionTuple);
      final cmp = keyA.$1.compareTo(keyB.$1);
      return cmp != 0 ? cmp : keyA.$2.compareTo(keyB.$2);
    });

    // Pagination: render only the first N task cards, growing on scroll.
    final visibleCount = _visibleActionCards.clamp(0, sortedTaskIds.length);
    final hasMore = visibleCount < sortedTaskIds.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (hasMore &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 600 &&
            mounted) {
          setState(
            () => _visibleActionCards = (visibleCount + _actionCardsPageSize)
                .clamp(0, sortedTaskIds.length),
          );
        }
        return false;
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        cacheExtent: 500, // Pre-build cards ahead for smoother scroll
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: visibleCount + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= visibleCount) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final taskId = sortedTaskIds[index];
          final actions = taskActions[taskId]!;
          final task = taskMap[taskId];
          if (task == null) return const SizedBox.shrink();
          return _buildTaskActionCard(task, actions, taskProvider);
        },
      ),
    );
  }

  // Format action date/time for display
  String _formatActionDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final actionDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    // Check if it's today
    if (actionDate == today) {
      // Show time only for today
      final time = DateFormat('hh:mm a').format(dateTime);
      return 'Today $time';
    }

    // Check if it's yesterday
    final yesterday = today.subtract(const Duration(days: 1));
    if (actionDate == yesterday) {
      final time = DateFormat('hh:mm a').format(dateTime);
      return 'Yesterday $time';
    }

    // Check if it's within the last 7 days
    final difference = today.difference(actionDate).inDays;
    if (difference < 7 && difference > 1) {
      return '${difference}d ago';
    }

    // For older dates, show date and time
    return DateFormat('MMM dd, hh:mm a').format(dateTime);
  }

  // Returns color for the scheduled time badge — single consistent color
  Color _getScheduledDateColor(DateTime scheduledDate) {
    return AppTheme.lightText;
  }

  String _editActionLabel(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('status changed')) return 'Status Changed';
    if (lower.contains('progress updated')) return 'Progress Updated';
    if (lower.contains('priority changed')) return 'Priority Changed';
    if (lower.contains('urgency changed')) return 'Urgency Changed';
    if (lower.contains('deadline updated')) return 'Deadline Changed';
    if (lower.contains('start date updated')) return 'Start Date Changed';
    if (lower.contains('title updated') ||
        (lower.contains('title:') && message.contains('→'))) {
      return 'Title Changed';
    }
    if (lower.contains('description updated') ||
        (lower.contains('description:') && message.contains('→'))) {
      return 'Description Changed';
    }
    if (lower.contains('assignee added')) return 'Assignee Added';
    if (lower.contains('assignee removed')) return 'Assignee Removed';
    if (lower.contains('assignee updated')) return 'Assignee Updated';
    return 'Edit';
  }

  // Build consolidated task action card (one card per task with all actions listed)
  Widget _buildTaskActionCard(
    dynamic task,
    List<ActionItem> actions,
    TaskProvider taskProvider,
  ) {
    final authProvider = context.read<AuthProvider>();
    final currentUid = authProvider.userModel?.uid ?? '';
    final currentName = authProvider.userModel?.name ?? '';
    final extraFields = task.extraFields ?? const <String, dynamic>{};
    bool listContainsCurrentUid(Object? value) {
      if (currentUid.isEmpty || value is! List) return false;
      return value.any((item) => item?.toString().trim() == currentUid);
    }

    final isAssigneeMe =
        task.assignedTo == currentUid ||
        task.assignedToUid == currentUid ||
        task.assignedTo == currentName ||
        task.assignedTo.toLowerCase() == 'me' ||
        listContainsCurrentUid(extraFields['assigneeUids']) ||
        listContainsCurrentUid(extraFields['participantUids']);
    final isByMe =
        task.createdBy == currentUid ||
        task.createdBy == currentName ||
        extraFields['createdByUid']?.toString() == currentUid ||
        extraFields['creatorUid']?.toString() == currentUid;
    final creatorName = isByMe
        ? 'Me'
        : (task.createdByName?.isNotEmpty == true &&
                  task.createdByName!.toLowerCase() != 'user'
              ? task.createdByName!
              : (_looksLikeUid(task.createdBy) ? 'Someone' : task.createdBy));
    final displayInitials = Helpers.getInitials(
      isAssigneeMe ? creatorName : task.assignedTo,
    );
    // Avatar of the same person the initials above come from, resolved through
    // the shared cache so this card matches the task list instead of always
    // painting a letter circle. 'Me' is looked up by the current user's own
    // identity (the cache has no entry under the literal string 'Me').
    final shownName = isAssigneeMe ? creatorName : task.assignedTo;
    // Prefer the index-aligned multi-assignee identity for the shown assignee:
    // the primary assignedToUid/Phone can be blank on a group task, so the same
    // person could show a photo on one card and initials on another (matches
    // the task-card / assignee-actions-tab fix).
    String? assigneeUid = task.assignedToUid;
    String? assigneePhone = task.assignedToPhone;
    final aNames = extraFields['assigneeNames'];
    if (aNames is List) {
      final names = aNames.map((e) => e?.toString().trim() ?? '').toList();
      final idx = names.indexOf(task.assignedTo.trim());
      if (idx >= 0) {
        final aUids = extraFields['assigneeUids'];
        final aPhones = extraFields['assigneePhones'];
        if (aUids is List && aUids.length == names.length) {
          final u = aUids[idx]?.toString().trim() ?? '';
          if (u.isNotEmpty) assigneeUid = u;
        }
        if (aPhones is List && aPhones.length == names.length) {
          final p = aPhones[idx]?.toString().trim() ?? '';
          if (p.isNotEmpty) assigneePhone = p;
        }
      }
    }
    final shownAvatarUrl = shownName == 'Me'
        ? AvatarCacheService().urlFor(uid: currentUid, name: currentName)
        : isAssigneeMe
        ? AvatarCacheService().urlFor(
            uid: task.createdBy,
            phone: task.createdByPhone,
            name: creatorName,
          )
        : AvatarCacheService().urlFor(
            uid: assigneeUid,
            phone: assigneePhone,
            name: task.assignedTo,
          );
    final accentColor = isAssigneeMe
        ? const Color(0xFF2F9E44)
        : const Color(0xFF1976D2);

    // Deadline calculation matching TaskCard format
    String daysToDeadline = '';
    Color deadlineColor = AppTheme.lightText;
    String daysFromStart = '';
    int totalDays = 0;
    if (task.deadline != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final deadlineDate = DateTime(
        task.deadline!.year,
        task.deadline!.month,
        task.deadline!.day,
      );
      final startDate = DateTime(
        task.createdAt.year,
        task.createdAt.month,
        task.createdAt.day,
      );
      final difference = deadlineDate.difference(today).inDays;
      totalDays = deadlineDate.difference(startDate).inDays;
      final elapsedDays = today.difference(startDate).inDays;
      daysFromStart = elapsedDays >= 0 ? '${elapsedDays}d' : '0d';

      if (difference < 0) {
        daysToDeadline = '-${difference.abs()}d';
        deadlineColor = Colors.red;
      } else if (difference == 0) {
        final hoursLeft = task.deadline!.difference(now).inHours;
        daysToDeadline = hoursLeft > 0 && hoursLeft < 24
            ? '${hoursLeft}h'
            : '0d';
        deadlineColor = AppTheme.deadlineNearing;
      } else if (difference == 1) {
        daysToDeadline = '1d';
        deadlineColor = AppTheme.deadlineNearing;
      } else {
        daysToDeadline = '${difference}d';
        deadlineColor = AppTheme.onTime;
      }
    }

    final visibleActions = actions
        .where((a) => !_hiddenActionIds.contains(a.id))
        .toList();
    if (visibleActions.isEmpty) return const SizedBox.shrink();
    final expanded = _expandedActionCards.contains(task.id);
    visibleActions.sort(
      (a, b) => CardActionIcons.compareActions(
        a.scheduledDate,
        a.createdAt,
        b.scheduledDate,
        b.createdAt,
      ),
    );

    // Running "#N" per base type (chronological) for the one-line rows.
    bool isEditOf(ActionItem a) {
      final l = a.message.toLowerCase();
      return l.contains('status changed') ||
          l.contains('progress updated') ||
          l.contains('priority changed') ||
          l.contains('urgency changed') ||
          l.contains('deadline updated') ||
          l.contains('start date updated') ||
          l.contains('title updated') ||
          l.contains('description updated') ||
          l.contains('assignee added') ||
          l.contains('assignee removed') ||
          l.contains('assignee updated');
    }

    final chrono = List<ActionItem>.from(visibleActions)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final seq = <String, int>{};
    final actionNumbers = <ActionItem, int>{};
    for (final a in chrono) {
      final base = CardActionIcons.actionBaseLabel(
        typeName: a.type.name,
        message: a.message,
        overrideBase: isEditOf(a) ? _editActionLabel(a.message) : null,
      );
      // Cash/Payment sub-types share one family counter (cards-numbering
      // parity) — see CardActionIcons.numberingGroupKey.
      final group = CardActionIcons.numberingGroupKey(base);
      final n = (seq[group] ?? 0) + 1;
      seq[group] = n;
      actionNumbers[a] = n;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => TaskDetailScreen(task: task),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  AppAvatar(
                    avatarUrl: shownAvatarUrl,
                    initials: displayInitials,
                    radius: 24,
                    color: accentColor,
                    fontSize: 17,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1: Task title + deadline + priority flag
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                task.title,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (task.deadline != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: deadlineColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: totalDays > 0
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 18,
                                            child: Text(
                                              daysFromStart,
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: const Color(0xFF2F9E44),
                                              ),
                                            ),
                                          ),
                                          Text(
                                            ' | ',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: deadlineColor,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 18,
                                            child: Text(
                                              '${totalDays}d',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      )
                                    : Text(
                                        daysToDeadline,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: deadlineColor,
                                        ),
                                      ),
                              ),
                            ],
                            if (task.isUrgent) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.flag,
                                size: 14,
                                color: Colors.red,
                              ),
                            ],
                          ],
                        ),
                        // Line 2: From → To
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              creatorName,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.secondaryText,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward,
                              size: 10,
                              color: AppTheme.lightText,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                isAssigneeMe
                                    ? 'Me'
                                    : (task.assignedToUid == currentUid ||
                                              task.assignedTo == currentUid ||
                                              task.assignedTo == currentName ||
                                              task.assignedTo.toLowerCase() ==
                                                  'me'
                                          ? 'Me'
                                          : task.assignedTo),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: accentColor,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Vertical progress bar (right side, matching TaskCard)
                  DashedProgressBar(
                    progress: (task.progress as double).clamp(0.0, 1.0),
                    color: AppTheme.primaryGreen,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ...(expanded ? visibleActions : visibleActions.take(3)).map((action) {
            final lower = action.message.toLowerCase();
            final isWarning =
                lower.startsWith('warning') || lower.contains('warning');
            final isStatus = lower.startsWith('status report');
            final isFollowup =
                lower.contains('follow-up') ||
                lower.contains('followup') ||
                lower.contains('follow up');
            // Detect query by type OR by text pattern
            final isQuery =
                action.type == ActionType.query ||
                lower.startsWith('query') ||
                lower.contains('query #') ||
                lower.contains('status request') ||
                lower.contains('asked for an update');
            final isEdit =
                lower.contains('status changed') ||
                lower.contains('progress updated') ||
                lower.contains('priority changed') ||
                lower.contains('urgency changed') ||
                lower.contains('deadline updated') ||
                lower.contains('start date updated') ||
                lower.contains('title updated') ||
                lower.contains('description updated') ||
                lower.contains('assignee added') ||
                lower.contains('assignee removed') ||
                lower.contains('assignee updated');
            // ⚠️ Icon chain parses ActionType + message text — a type missing
            // here falls to the generic Reminder bell (this was the cash icon
            // bug). Keep in sync with the twin chain in
            // assignee_tasks_screen.dart _buildCompactActionRow.
            IconData icon;
            Color iconColor;
            String label; // ignore: unused_local_variable
            if (isWarning) {
              icon = Icons.warning_amber_rounded;
              iconColor = const Color(0xFFE03131);
              label = 'Warning';
            } else if (isQuery) {
              // Check query BEFORE status report and follow-up to prevent misclassification
              icon = Icons.summarize;
              iconColor = action.isReplied
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = action.isReplied ? 'Query - Replied' : 'Query';
            } else if (isStatus) {
              icon = Icons.summarize;
              iconColor = const Color(0xFF2F9E44);
              label = 'Status Report';
            } else if (isFollowup) {
              icon = Icons.event_repeat;
              iconColor = action.isFollowUpDone
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = action.isFollowUpDone ? 'Follow-up - Done' : 'Follow-up';
            } else if (action.type == ActionType.blocker) {
              icon = Icons.block;
              iconColor = action.isFollowUpDone
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFFC92A2A);
              label = action.isFollowUpDone ? 'Blocker - Resolved' : 'Blocker';
            } else if (action.type == ActionType.approval) {
              icon = Icons.fact_check;
              iconColor = action.isReplied
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF0B7285);
              label = action.isReplied
                  ? 'Request - Actioned'
                  : 'Request Action';
            } else if (action.type == ActionType.extension) {
              icon = Icons.more_time;
              iconColor = action.isReplied
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF3B5BDB);
              label = action.isReplied
                  ? 'Extension - Actioned'
                  : 'Extension Requested';
            } else if (action.type == ActionType.progressReport) {
              icon = Icons.trending_up;
              iconColor = const Color(0xFF7048E8);
              label = 'Progress Report';
            } else if (action.message.contains('💳') ||
                lower.startsWith('payment')) {
              // 💳 receivable card (Cash/Payment dialog) — checked before
              // the wallet catch since payment rows carry ActionType.cash.
              icon = Icons.payments;
              iconColor = const Color(0xFF7048E8);
              final payFirstLine = action.message.split('\n').first;
              label = payFirstLine.contains('Due')
                  ? 'Payment - Due'
                  : payFirstLine.contains('Collected')
                  ? 'Payment - Collected'
                  : 'Payment';
            } else if (action.type == ActionType.cash ||
                action.message.contains('💵') ||
                lower.startsWith('cash')) {
              icon = Icons.account_balance_wallet;
              iconColor = const Color(0xFF099268);
              if (action.message.contains('Cash Added')) {
                label = 'Cash Added';
              } else if (action.message.contains('Cash Expense')) {
                label = 'Cash Expense';
              } else if (action.message.contains('Cash Refund')) {
                label = 'Cash Refund';
              } else if (action.message.contains('Cash Settled')) {
                label = 'Cash Settled';
              } else {
                label = 'Cash';
              }
            } else if (action.type == ActionType.call) {
              icon = Icons.call;
              iconColor = const Color(0xFF0C8599);
              label = action.isFollowUpDone ? 'Call - Done' : 'Call';
            } else if (action.type == ActionType.meeting) {
              icon = Icons.groups;
              iconColor = const Color(0xFF3B5BDB);
              label = action.isFollowUpDone ? 'Meeting - Done' : 'Meeting';
            } else if (action.type == ActionType.siteVisit) {
              icon = Icons.handyman;
              iconColor = const Color(0xFF1098AD);
              label = action.isFollowUpDone ? 'Visit - Done' : 'Visit';
            } else if (isEdit) {
              icon = Icons.edit_note;
              iconColor = const Color(0xFFF59F00);
              label = _editActionLabel(action.message);
            } else {
              icon = Icons.notifications_active;
              iconColor = const Color(0xFFF59F00);
              label = 'Reminder';
              final qm = RegExp(r'"([^"]+)"').firstMatch(action.message);
              if (qm != null) label = 'Reminder "${qm.group(1)!}"';
            }
            final timeStr = _formatActionDateTime(action.scheduledDate);
            final dateColor = _getScheduledDateColor(action.scheduledDate);

            // One-line description: "Query Replied#1 | <summary>" + date badge.
            final detail = CardActionIcons.compactDetail(
              action.message,
              typeName: action.type.name,
            );
            final closed = action.isReplied || action.isFollowUpDone;
            final base = CardActionIcons.actionBaseLabel(
              typeName: action.type.name,
              message: action.message,
              overrideBase: isEdit ? _editActionLabel(action.message) : null,
            );
            final statusWord = closed
                ? const {
                        'query': ' Replied',
                        'followUp': ' Done',
                        'extension': '',
                        'approval': ' Actioned',
                        'blocker': ' Resolved',
                        'call': ' Done',
                        'meeting': ' Done',
                        'siteVisit': ' Done',
                      }[action.type.name] ??
                      ''
                : '';
            // Prefer the baked occurrence number (matches the chat card and is
            // stable under filtering); fall back to the recomputed family
            // counter for legacy rows without a seqNo.
            final number = action.seqNo ?? (actionNumbers[action] ?? 1);
            final lineText = detail.isNotEmpty
                ? '$base$statusWord#$number | $detail'
                : '$base$statusWord#$number';

            return InkWell(
              onTap: () {
                _navigateToTaskDetail(
                  task,
                  scrollToMessageId: action.messageId,
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // Icon — done/replied actions keep their icon + ✓ badge
                    CardActionIcons.withDoneBadge(
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: iconColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(icon, size: 13, color: iconColor),
                      ),
                      done: action.isReplied || action.isFollowUpDone,
                    ),
                    const SizedBox(width: 8),
                    // Label (condensed, single line)
                    Expanded(
                      child: Text(
                        lineText,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.primaryText,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Date badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: dateColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: dateColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Chevron
                    const Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: AppTheme.lightText,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
          if (visibleActions.length > 3)
            InkWell(
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedActionCards.remove(task.id);
                  } else {
                    _expandedActionCards.add(task.id);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text(
                    expanded
                        ? 'Show less'
                        : '... ${visibleActions.length - 3} more',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryGreen,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
