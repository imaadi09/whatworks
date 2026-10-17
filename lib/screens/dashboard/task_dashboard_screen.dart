import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/task.dart';
import '../../providers/task_provider.dart';
import '../../services/local_database_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../widgets/app_avatar.dart';
import '../task_detail/task_detail_screen.dart';

// Palette shared across the dashboard cards (mirrors the mockup).
const Color _kRed = Color(0xFFE03131);
const Color _kOrange = Color(0xFFF59F00);
const Color _kPurple = Color(0xFF9C36B5);
const Color _kBlue = Color(0xFF1976D2);
const Color _kGreen = Color(0xFF2F9E44);

/// Human label for a pending closure-type action row.
const Map<String, String> _pendingLabels = {
  'query': 'Query pending',
  'followup': 'Follow-up pending',
  'approval': 'Approval pending',
  'extension': 'Extension requested',
  'blocker': 'Blocker raised',
  'call': 'Call pending',
};

/// Per-person workload stats for the Team At a Glance section.
class _MemberStat {
  final String name;
  int open = 0;
  int overdue = 0;
  int blocked = 0;
  int onTrack = 0;
  final List<TaskModel> tasks = [];
  _MemberStat(this.name);
}

/// A Top Priority Items entry with its reason chip.
class _PriorityItem {
  final TaskModel task;
  final String kind; // 'Overdue' | 'Blocked' | 'Approval'
  final String reason;
  final String? note;
  _PriorityItem(this.task, this.kind, this.reason, this.note);
}

class TaskDashboardScreen extends StatefulWidget {
  /// When true, renders without Scaffold/AppBar for embedding in the home
  /// bottom-nav DASHBOARD tab.
  final bool embedded;

  /// Whether this tab is the currently-visible one. The home [IndexedStack]
  /// keeps every visited tab mounted, so a hidden Dashboard must NOT rebuild
  /// its chart sections on every TaskProvider notification for a tab nobody
  /// sees. When inactive, [build] returns an empty placeholder. Defaults to
  /// true so a full-screen push always renders.
  final bool isActive;
  const TaskDashboardScreen({
    super.key,
    this.embedded = false,
    this.isActive = true,
  });

  @override
  State<TaskDashboardScreen> createState() => _TaskDashboardScreenState();
}

class _TaskDashboardScreenState extends State<TaskDashboardScreen> {
  bool _isLoading = true;

  // In-place expansion toggles (More Insights starts collapsed).
  // Needs Attention stays OPEN by default (user rule) — it's the dashboard's
  // primary triage section, so it should never load folded.
  bool _xAttention = true;
  bool _xDeadline = false;
  bool _xTeam = false;
  bool _xHealth = false;
  bool _xMore = false;

  // Deadline / status buckets (active tasks).
  List<TaskModel> _overdueList = [];
  List<TaskModel> _dueTodayList = [];
  List<TaskModel> _dueThisWeekList = [];
  List<TaskModel> _dueNextWeekList = [];
  List<TaskModel> _dueThisMonthList = [];
  List<TaskModel> _noDeadlineList = [];
  List<TaskModel> _blockedList = [];

  // Action-driven buckets (active tasks with pending rows).
  List<TaskModel> _needActionList = [];
  List<TaskModel> _queryList = [];
  List<TaskModel> _followupTodayList = [];
  List<TaskModel> _approvalList = [];
  List<TaskModel> _warningList = [];
  int _queryCount = 0;
  int _followupCount = 0;
  int _approvalCount = 0;
  int _warningCount = 0;

  // My Tasks
  List<TaskModel> _byMeList = [];
  List<TaskModel> _toMeList = [];
  int _byMeAttention = 0;
  int _toMeDueToday = 0;

  // Top Priority Items
  List<_PriorityItem> _priority = [];

  // Team At a Glance
  List<_MemberStat> _team = [];

  // Task Health
  List<TaskModel> _behindList = [];
  List<TaskModel> _onTrackList = [];
  List<TaskModel> _aheadList = [];

  // More Insights
  List<TaskModel> _noUpdateList = [];
  List<TaskModel> _repeatFollowupList = [];
  List<TaskModel> _completedWeekList = [];
  int _createdThisWeek = 0;
  int _onTimeCount = 0;
  String _avgCompletionTime = '-';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _computeMetrics());
  }

  Future<void> _computeMetrics() async {
    final taskProvider = context.read<TaskProvider>();
    final userId = taskProvider.currentUserId;
    if (userId.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final allTasks = await taskProvider.getAllTasks(userId);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final tasks = allTasks.where((t) => !t.isDeleted).toList();
    final byId = {for (final t in tasks) t.id: t};

    final active = tasks.where((t) => !t.isClosed && !t.isCancelled).toList();

    // Deadline buckets (mutually exclusive).
    DateTime? dayOf(TaskModel t) =>
        t.deadline == null ? null : DateTime(t.deadline!.year, t.deadline!.month, t.deadline!.day);
    final overdue = active.where((t) => t.isOverdue).toList()
      ..sort((a, b) => (a.deadline ?? now).compareTo(b.deadline ?? now));
    final dueToday = active.where((t) => dayOf(t) == today).toList();
    final dueThisWeek = active
        .where((t) => dayOf(t) != null && dayOf(t)!.isAfter(today) && !dayOf(t)!.isAfter(today.add(const Duration(days: 7))))
        .toList();
    final dueNextWeek = active
        .where((t) => dayOf(t) != null && dayOf(t)!.isAfter(today.add(const Duration(days: 7))) && !dayOf(t)!.isAfter(today.add(const Duration(days: 14))))
        .toList();
    final dueThisMonth = active
        .where((t) => dayOf(t) != null && dayOf(t)!.isAfter(today.add(const Duration(days: 14))) && dayOf(t)!.year == now.year && dayOf(t)!.month == now.month)
        .toList();
    final noDeadline = active.where((t) => t.deadline == null).toList();
    final blocked = active.where((t) => t.extraFields?['isBlocked'] == true).toList();

    // Action rows: one query, grouped in Dart.
    final db = LocalDatabaseService();
    final rows = await db.getAllActions(parentType: 'task');
    final todayStart = today.millisecondsSinceEpoch;
    final todayEnd = today.add(const Duration(days: 1)).millisecondsSinceEpoch;
    final pendingByTask = <String, List<Map<String, dynamic>>>{};
    final queryTasks = <String>{};
    final followupTodayTasks = <String>{};
    final approvalTasks = <String>{};
    final warningTasks = <String>{};
    final followupRowCount = <String, int>{};
    int queryCount = 0, followupCount = 0, approvalCount = 0, warningCount = 0;
    for (final r in rows) {
      final pid = r['parentId'] as String? ?? '';
      final t = byId[pid];
      if (t == null || t.isClosed || t.isCancelled) continue;
      final type = r['actionType'] as String? ?? '';
      final replied = (r['isReplied'] as int? ?? 0) == 1;
      final done = (r['isDone'] as int? ?? 0) == 1;
      // Unified pending rule: done closes everything; a reply closes
      // queries/requests/extensions; follow-ups, blockers and calls stay
      // open until marked done — same as the bell, chips and strips.
      final pending = !done &&
          ((type == 'followup' || type == 'blocker' || type == 'call') ||
              ((type == 'query' || type == 'approval' || type == 'extension') &&
                  !replied));
      if (pending) {
        (pendingByTask[pid] ??= []).add(r);
      }
      if (type == 'query' && !replied) {
        queryCount++;
        queryTasks.add(pid);
      }
      if (type == 'followup') {
        followupRowCount[pid] = (followupRowCount[pid] ?? 0) + 1;
        if (!done) {
          final sd = r['scheduledDate'] as int?;
          if (sd != null && sd >= todayStart && sd < todayEnd) {
            followupCount++;
            followupTodayTasks.add(pid);
          }
        }
      }
      if (type == 'approval' && !replied && !done) {
        approvalCount++;
        approvalTasks.add(pid);
      }
      if (type == 'warning' && !done) {
        warningCount++;
        warningTasks.add(pid);
      }
    }
    final needAction = pendingByTask.keys.map((id) => byId[id]!).toList();
    final attentionSet = <String>{
      ...needAction.map((t) => t.id),
      ...overdue.map((t) => t.id),
      ...blocked.map((t) => t.id),
    };

    // My Tasks
    final byMe = tasks.where((t) => t.createdBy == userId && t.assignedToUid != userId).toList();
    final toMe = tasks.where((t) => t.assignedToUid == userId).toList();
    final byMeAttention = byMe.where((t) => attentionSet.contains(t.id)).length;
    final toMeDueToday = toMe.where((t) => dayOf(t) == today && !t.isClosed && !t.isCancelled).length;

    // Top Priority Items: overdue → blocked → approval.
    final priority = <_PriorityItem>[];
    final seen = <String>{};
    for (final t in overdue) {
      final days = today.difference(dayOf(t)!).inDays;
      priority.add(_PriorityItem(t, 'Overdue', Helpers.overdueLabel(days), _noteFor(pendingByTask[t.id])));
      seen.add(t.id);
    }
    for (final t in blocked) {
      if (!seen.add(t.id)) continue;
      priority.add(_PriorityItem(t, 'Blocked', 'Blocked', _noteFor(pendingByTask[t.id])));
    }
    for (final id in approvalTasks) {
      final t = byId[id];
      if (t == null || !seen.add(t.id)) continue;
      priority.add(_PriorityItem(t, 'Approval', 'Approval pending', null));
    }

    // Team At a Glance + Task Health (expected-progress ratio).
    final teamMap = <String, _MemberStat>{};
    final behind = <TaskModel>[];
    final onTrack = <TaskModel>[];
    final ahead = <TaskModel>[];
    for (final t in active) {
      final stat = teamMap[t.assignedTo.isNotEmpty ? t.assignedTo : 'Unassigned'] ??=
          _MemberStat(t.assignedTo.isNotEmpty ? t.assignedTo : 'Unassigned');
      stat.open++;
      stat.tasks.add(t);
      if (t.isOverdue) stat.overdue++;
      if (t.extraFields?['isBlocked'] == true) stat.blocked++;
      if (t.deadline != null) {
        final expected = Helpers.getExpectedProgress(t.createdAt, t.deadline);
        if (expected > 0.0) {
          final ratio = t.progress / expected;
          if (ratio < 0.9) {
            behind.add(t);
          } else if (ratio > 1.1) {
            ahead.add(t);
          } else {
            onTrack.add(t);
            stat.onTrack++;
          }
        }
      }
    }
    final team = teamMap.values.toList()..sort((a, b) => b.open.compareTo(a.open));

    // More Insights
    final noUpdate = active
        .where((t) => now.difference(t.updatedAt).inDays >= 3)
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final repeatFollowup = followupRowCount.entries
        .where((e) => e.value >= 3)
        .map((e) => byId[e.key])
        .whereType<TaskModel>()
        .toList();
    final completedWeek = tasks.where((t) => t.isClosed && t.updatedAt.isAfter(startOfWeek)).toList();
    final onTime = completedWeek
        .where((t) => t.deadline == null || !t.updatedAt.isAfter(DateTime(t.deadline!.year, t.deadline!.month, t.deadline!.day).add(const Duration(days: 1))))
        .length;
    final createdWeek = tasks.where((t) => t.createdAt.isAfter(startOfWeek)).length;
    String avgTime = '-';
    final closedTasks = tasks.where((t) => t.isClosed).toList();
    if (closedTasks.isNotEmpty) {
      final totalDays = closedTasks.fold<int>(0, (s, t) => s + t.updatedAt.difference(t.createdAt).inDays);
      avgTime = '${(totalDays / closedTasks.length).round()}d';
    }

    setState(() {
      _overdueList = overdue;
      _dueTodayList = dueToday;
      _dueThisWeekList = dueThisWeek;
      _dueNextWeekList = dueNextWeek;
      _dueThisMonthList = dueThisMonth;
      _noDeadlineList = noDeadline;
      _blockedList = blocked;
      _needActionList = needAction;
      _queryList = queryTasks.map((id) => byId[id]!).whereType<TaskModel>().toList();
      _followupTodayList = followupTodayTasks.map((id) => byId[id]!).whereType<TaskModel>().toList();
      _approvalList = approvalTasks.map((id) => byId[id]!).whereType<TaskModel>().toList();
      _warningList = warningTasks.map((id) => byId[id]!).whereType<TaskModel>().toList();
      _queryCount = queryCount;
      _followupCount = followupCount;
      _approvalCount = approvalCount;
      _warningCount = warningCount;
      _byMeList = byMe;
      _toMeList = toMe;
      _byMeAttention = byMeAttention;
      _toMeDueToday = toMeDueToday;
      _priority = priority;
      _team = team;
      _behindList = behind;
      _onTrackList = onTrack;
      _aheadList = ahead;
      _noUpdateList = noUpdate;
      _repeatFollowupList = repeatFollowup;
      _completedWeekList = completedWeek;
      _createdThisWeek = createdWeek;
      _onTimeCount = onTime;
      _avgCompletionTime = avgTime;
      _isLoading = false;
    });
  }

  String? _noteFor(List<Map<String, dynamic>>? pending) {
    if (pending == null || pending.isEmpty) return null;
    const order = ['followup', 'query', 'approval', 'blocker', 'extension', 'call'];
    for (final k in order) {
      if (pending.any((r) => r['actionType'] == k)) return _pendingLabels[k];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Hidden in the home IndexedStack: render nothing so the chart sections
    // don't rebuild on every TaskProvider notification for a tab nobody sees.
    if (!widget.isActive) return const SizedBox.shrink();
    final content = _isLoading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _computeMetrics,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildNeedsAttention(),
                const SizedBox(height: 16),
                _buildTopPriority(),
                const SizedBox(height: 16),
                _buildMyTasks(),
                const SizedBox(height: 16),
                _buildDeadlineInsights(),
                const SizedBox(height: 16),
                _buildTeamGlance(),
                const SizedBox(height: 16),
                _buildTaskHealth(),
                const SizedBox(height: 16),
                _buildMoreInsights(),
                const SizedBox(height: 32),
              ],
            ),
          );
    if (widget.embedded) {
      return Container(color: Colors.white, child: content);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Task Dashboard'),
        backgroundColor: AppTheme.headerGreen,
      ),
      body: content,
    );
  }

  // ── Section 1: Needs Attention ────────────────────────────────────────────

  Widget _buildNeedsAttention() {
    return _card(
      title: 'Needs Attention',
      expanded: _xAttention,
      onToggle: () => setState(() => _xAttention = !_xAttention),
      child: Column(
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              _statCard('Overdue', _overdueList.length, _kRed, Icons.warning_amber_rounded,
                  () => _showTaskSheet('Overdue Tasks', _overdueList)),
              _statCard('Due Today', _dueTodayList.length, _kOrange, Icons.event,
                  () => _showTaskSheet('Due Today', _dueTodayList)),
              _statCard('Need Action', _needActionList.length, _kPurple, Icons.assignment_late,
                  () => _showTaskSheet('Need Action', _needActionList)),
              _statCard('Blocked', _blockedList.length, _kBlue, Icons.block,
                  () => _showTaskSheet('Blocked Tasks', _blockedList)),
            ],
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline, size: 12, color: AppTheme.lightText),
              SizedBox(width: 4),
              Text(
                'These are tasks that need your attention',
                style: TextStyle(fontSize: 10, color: AppTheme.lightText),
              ),
            ],
          ),
          if (_xAttention) ...[
            const Divider(height: 16),
            _drillRow(Icons.chat_bubble_outline, _kRed, 'Queries awaiting reply', _queryCount,
                () => _showTaskSheet('Queries Awaiting Reply', _queryList)),
            const Divider(height: 1),
            _drillRow(Icons.follow_the_signs, _kOrange, 'Follow-ups due today', _followupCount,
                () => _showTaskSheet('Follow-ups Due Today', _followupTodayList)),
            const Divider(height: 1),
            _drillRow(Icons.verified_outlined, _kOrange, 'Approvals pending', _approvalCount,
                () => _showTaskSheet('Approvals Pending', _approvalList)),
            const Divider(height: 1),
            _drillRow(Icons.gpp_maybe_outlined, _kOrange, 'Unresolved Warnings', _warningCount,
                () => _showTaskSheet('Unresolved Warnings', _warningList)),
            const Divider(height: 1),
            _drillRow(Icons.block, _kBlue, 'Blocked tasks', _blockedList.length,
                () => _showTaskSheet('Blocked Tasks', _blockedList)),
            const SizedBox(height: 8),
            _link('View all actions', () => _showTaskSheet('Needs Attention', _attentionUnion())),
          ],
        ],
      ),
    );
  }

  List<TaskModel> _attentionUnion() {
    final seen = <String>{};
    final out = <TaskModel>[];
    for (final t in [..._overdueList, ..._needActionList, ..._blockedList]) {
      if (seen.add(t.id)) out.add(t);
    }
    return out;
  }

  // ── Section 2: Top Priority Items ─────────────────────────────────────────

  Widget _buildTopPriority() {
    if (_priority.isEmpty) return const SizedBox.shrink();
    final top = _priority.take(3).toList();
    return _card(
      title: 'Top Priority Items',
      trailing: _link('View all (${_priority.length})',
          () => _showTaskSheet('Top Priority Items', _priority.map((p) => p.task).toList()),
          color: _kBlue),
      child: Column(
        children: [
          for (final p in top) ...[
            InkWell(
              onTap: () => _openTask(p.task),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    AppAvatar(
                      avatarUrl: null,
                      initials: Helpers.getInitials(p.task.assignedTo.isNotEmpty ? p.task.assignedTo : '?'),
                      radius: 16,
                      color: _kGreen,
                      fontSize: 12,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.task.title.isNotEmpty ? p.task.title : '(untitled task)',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primaryText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  p.task.assignedTo.isNotEmpty ? p.task.assignedTo : 'Unassigned',
                                  style: const TextStyle(fontSize: 11, color: AppTheme.secondaryText),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(' • ', style: TextStyle(fontSize: 11, color: _chipColor(p.kind))),
                              Flexible(
                                child: Text(
                                  p.reason,
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _chipColor(p.kind)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (p.note != null)
                            Text(
                              p.note!,
                              style: const TextStyle(fontSize: 10, color: AppTheme.lightText),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _chip(p.kind),
                    const Icon(Icons.chevron_right, size: 16, color: AppTheme.lightText),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  Color _chipColor(String kind) =>
      kind == 'Overdue' ? _kRed : kind == 'Blocked' ? _kBlue : _kOrange;

  Widget _chip(String kind) {
    final c = _chipColor(kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(kind, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c)),
    );
  }

  // ── Section 3: Track All ──────────────────────────────────────────────────

  Widget _buildMyTasks() {
    return _card(
      // Matches the drawer label for the same by-me/to-me view.
      title: 'Track All',
      child: Row(
        children: [
          Expanded(
            child: _myTile('Assigned by Me', _byMeList.length, Icons.north_east, _kGreen,
                '$_byMeAttention need attention', () => _showTaskSheet('Assigned by Me', _byMeList)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _myTile('Assigned to Me', _toMeList.length, Icons.south_west, _kBlue,
                '$_toMeDueToday due today', () => _showTaskSheet('Assigned to Me', _toMeList)),
          ),
        ],
      ),
    );
  }

  Widget _myTile(String label, int count, IconData icon, Color color, String sub, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
              ],
            ),
            const SizedBox(height: 6),
            Text('$count', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(fontSize: 10, color: _kOrange)),
          ],
        ),
      ),
    );
  }

  // ── Section 4: Deadline Insights ──────────────────────────────────────────

  Widget _buildDeadlineInsights() {
    return _card(
      title: 'Deadline Insights',
      expanded: _xDeadline,
      onToggle: () => setState(() => _xDeadline = !_xDeadline),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: _statCard('Overdue', _overdueList.length, _kRed, Icons.error_outline,
                      () => _showTaskSheet('Overdue Tasks', _overdueList))),
              const SizedBox(width: 10),
              Expanded(
                  child: _statCard('Due Today', _dueTodayList.length, _kOrange, Icons.today,
                      () => _showTaskSheet('Due Today', _dueTodayList))),
              const SizedBox(width: 10),
              Expanded(
                  child: _statCard('Due This Week', _dueThisWeekList.length, _kOrange, Icons.date_range,
                      () => _showTaskSheet('Due This Week', _dueThisWeekList))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${_noDeadlineList.length} tasks have no deadline',
                style: const TextStyle(fontSize: 10, color: AppTheme.lightText),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.info_outline, size: 12, color: AppTheme.lightText),
            ],
          ),
          if (_xDeadline) ...[
            const Divider(height: 16),
            _drillRow(Icons.error_outline, _kRed, 'Overdue', _overdueList.length,
                () => _showTaskSheet('Overdue Tasks', _overdueList)),
            const Divider(height: 1),
            _drillRow(Icons.today, _kOrange, 'Due Today', _dueTodayList.length,
                () => _showTaskSheet('Due Today', _dueTodayList)),
            const Divider(height: 1),
            _drillRow(Icons.date_range, _kOrange, 'Due This Week', _dueThisWeekList.length,
                () => _showTaskSheet('Due This Week', _dueThisWeekList)),
            const Divider(height: 1),
            _drillRow(Icons.calendar_month, _kBlue, 'Due Next Week', _dueNextWeekList.length,
                () => _showTaskSheet('Due Next Week', _dueNextWeekList)),
            const Divider(height: 1),
            _drillRow(Icons.calendar_view_month, _kGreen, 'Due This Month', _dueThisMonthList.length,
                () => _showTaskSheet('Due This Month', _dueThisMonthList)),
            const Divider(height: 1),
            _drillRow(Icons.info_outline, AppTheme.secondaryText, 'No Deadline', _noDeadlineList.length,
                () => _showTaskSheet('No Deadline', _noDeadlineList)),
            const SizedBox(height: 8),
            _link('View all tasks by deadline', () => _showTaskSheet(
                'Tasks by Deadline',
                [..._overdueList, ..._dueTodayList, ..._dueThisWeekList, ..._dueNextWeekList, ..._dueThisMonthList])),
          ],
        ],
      ),
    );
  }

  // ── Section 5: Team At a Glance ───────────────────────────────────────────

  Widget _buildTeamGlance() {
    if (_team.isEmpty) return const SizedBox.shrink();
    final maxOpen = _team.first.open;
    return _card(
      title: 'Team At a Glance',
      expanded: _xTeam,
      onToggle: () => setState(() => _xTeam = !_xTeam),
      child: Column(
        children: [
          if (!_xTeam)
            for (final m in _team.take(3)) _teamRow(m, maxOpen),
          if (_xTeam) ...[
            _tableHeader(),
            const Divider(height: 1),
            for (final m in _team) _tableRow(m),
            const SizedBox(height: 8),
            _link('View full team workload', _showTeamSheet),
          ] else ...[
            const SizedBox(height: 8),
            _link('View all team members', () => setState(() => _xTeam = true), color: _kBlue),
          ],
        ],
      ),
    );
  }

  Widget _teamRow(_MemberStat m, int maxOpen) {
    final barColor = m.overdue > 0 ? _kRed : m.blocked > 0 ? _kOrange : _kGreen;
    final tail = m.overdue > 0
        ? '${m.overdue} overdue'
        : m.blocked > 0
            ? '${m.blocked} blocked'
            : 'On track';
    final tailColor = m.overdue > 0 ? _kRed : m.blocked > 0 ? _kBlue : _kGreen;
    return InkWell(
      onTap: () => _showTaskSheet('${m.name} — Open Tasks', m.tasks),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            AppAvatar(avatarUrl: null, initials: Helpers.getInitials(m.name), radius: 14, color: _kGreen, fontSize: 11),
            const SizedBox(width: 8),
            SizedBox(
              width: 92,
              child: Text(m.name,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.primaryText),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: maxOpen > 0 ? m.open / maxOpen : 0,
                  backgroundColor: AppTheme.lightGrey,
                  color: barColor,
                  minHeight: 8,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${m.open} open • ', style: const TextStyle(fontSize: 11, color: AppTheme.secondaryText)),
            Flexible(
              child: Text(tail,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tailColor),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tableHeader() {
    return const Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text('Name', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryText))),
          SizedBox(width: 38, child: Text('Open', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryText))),
          SizedBox(width: 52, child: Text('Overdue', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryText))),
          SizedBox(width: 52, child: Text('Blocked', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryText))),
          SizedBox(width: 52, child: Text('On Track', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryText), textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _tableRow(_MemberStat m) {
    return InkWell(
      onTap: () => _showTaskSheet('${m.name} — Open Tasks', m.tasks),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(m.name,
                  style: const TextStyle(fontSize: 12, color: AppTheme.primaryText),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            SizedBox(width: 38, child: Text('${m.open}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kBlue))),
            SizedBox(width: 52, child: Text('${m.overdue}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: m.overdue > 0 ? _kRed : AppTheme.secondaryText))),
            SizedBox(width: 52, child: Text('${m.blocked}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: m.blocked > 0 ? _kOrange : AppTheme.secondaryText))),
            SizedBox(width: 52, child: Text('${m.onTrack}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kGreen), textAlign: TextAlign.right)),
          ],
        ),
      ),
    );
  }

  void _showTeamSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            _sheetHeader('Team Workload'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  _tableHeader(),
                  const Divider(height: 1),
                  for (final m in _team) _tableRow(m),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section 6: Task Health ────────────────────────────────────────────────

  Widget _buildTaskHealth() {
    final total = _behindList.length + _onTrackList.length + _aheadList.length;
    if (total == 0) return const SizedBox.shrink();
    return _card(
      title: 'Task Health',
      expanded: _xHealth,
      onToggle: () => setState(() => _xHealth = !_xHealth),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: _statCard('Behind', _behindList.length, _kRed, Icons.trending_up,
                      () => _showTaskSheet('Behind Schedule', _behindList))),
              const SizedBox(width: 10),
              Expanded(
                  child: _statCard('On Track', _onTrackList.length, _kGreen, Icons.check_circle_outline,
                      () => _showTaskSheet('On Track', _onTrackList))),
              const SizedBox(width: 10),
              Expanded(
                  child: _statCard('Ahead', _aheadList.length, _kBlue, Icons.compare_arrows,
                      () => _showTaskSheet('Ahead of Plan', _aheadList))),
            ],
          ),
          if (_xHealth) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 170,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      sections: [
                        if (_behindList.length > 0)
                          PieChartSectionData(value: _behindList.length.toDouble(), color: _kRed, radius: 26, showTitle: false),
                        if (_onTrackList.length > 0)
                          PieChartSectionData(value: _onTrackList.length.toDouble(), color: _kGreen, radius: 26, showTitle: false),
                        if (_aheadList.length > 0)
                          PieChartSectionData(value: _aheadList.length.toDouble(), color: _kBlue, radius: 26, showTitle: false),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$total', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.primaryText)),
                      const Text('Total Tasks', style: TextStyle(fontSize: 9, color: AppTheme.secondaryText)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _healthLegend('Behind', 'Due or progress behind plan', _behindList.length, total, _kRed,
                () => _showTaskSheet('Behind Schedule', _behindList)),
            const Divider(height: 1),
            _healthLegend('On Track', 'Progress as per plan', _onTrackList.length, total, _kGreen,
                () => _showTaskSheet('On Track', _onTrackList)),
            const Divider(height: 1),
            _healthLegend('Ahead', 'Ahead of plan', _aheadList.length, total, _kBlue,
                () => _showTaskSheet('Ahead of Plan', _aheadList)),
            const SizedBox(height: 8),
            _link('View all tasks',
                () => _showTaskSheet('Task Health', [..._behindList, ..._onTrackList, ..._aheadList])),
          ],
        ],
      ),
    );
  }

  Widget _healthLegend(String label, String sub, int count, int total, Color color, VoidCallback onTap) {
    final pct = total > 0 ? ((count / total) * 100).round() : 0;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryText)),
                  Text(sub, style: const TextStyle(fontSize: 10, color: AppTheme.lightText)),
                ],
              ),
            ),
            Text('$count ($pct%)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }

  // ── Section 7: More Insights (collapsible) ────────────────────────────────

  Widget _buildMoreInsights() {
    return _card(
      title: 'More Insights',
      expanded: _xMore,
      onToggle: () => setState(() => _xMore = !_xMore),
      child: !_xMore
          ? const SizedBox.shrink()
          : Column(
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.15,
                  children: [
                    _insightCard(Icons.sync_problem, const Color(0xFF0CA678), 'No Update',
                        '${_noUpdateList.length} tasks', 'no update ≥ 3 days',
                        () => _showTaskSheet('No Update ≥ 3 Days', _noUpdateList)),
                    _insightCard(Icons.repeat, const Color(0xFFE8590C), 'Repeated Follow-ups',
                        '${_repeatFollowupList.length} tasks', '3+ reminders',
                        () => _showTaskSheet('Repeated Follow-ups', _repeatFollowupList)),
                    _insightCard(
                        Icons.check_circle,
                        _kGreen,
                        'Completion This Week',
                        '${_completedWeekList.length} closed',
                        '${_completedWeekList.isEmpty ? 0 : ((_onTimeCount / _completedWeekList.length) * 100).round()}% on time',
                        () => _showTaskSheet('Completed This Week', _completedWeekList)),
                    _insightCard(Icons.bar_chart, _kPurple, 'Productivity This Week',
                        'Created $_createdThisWeek', 'Completed ${_completedWeekList.length} • avg $_avgCompletionTime', null),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _insightCard(IconData icon, Color color, String title, String line1, String line2, VoidCallback? onTap) {
    final inner = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primaryText),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(line1, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          Text(line2, style: const TextStyle(fontSize: 9, color: AppTheme.lightText), textAlign: TextAlign.center),
        ],
      ),
    );
    if (onTap == null) return inner;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: inner);
  }

  // ── Shared helpers ────────────────────────────────────────────────────────

  void _openTask(TaskModel task) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)));
  }

  void _showTaskSheet(String title, List<TaskModel> list) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            _sheetHeader('$title (${list.length})'),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('Nothing here', style: TextStyle(color: AppTheme.lightText)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final t = list[i];
                        return InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            _openTask(t);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                AppAvatar(
                                    avatarUrl: null,
                                    initials: Helpers.getInitials(t.assignedTo.isNotEmpty ? t.assignedTo : '?'),
                                    radius: 16,
                                    color: _kGreen,
                                    fontSize: 12),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t.title.isNotEmpty ? t.title : '(untitled task)',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primaryText),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${t.assignedTo.isNotEmpty ? t.assignedTo : 'Unassigned'} • ${_deadlineLabel(t)}',
                                        style: const TextStyle(fontSize: 11, color: AppTheme.secondaryText),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 16, color: AppTheme.lightText),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.primaryText)),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  String _deadlineLabel(TaskModel t) {
    if (t.deadline == null) return 'No deadline';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.deadline!.year, t.deadline!.month, t.deadline!.day);
    final days = d.difference(today).inDays;
    if (days < 0) return Helpers.overdueLabel(-days);
    if (days == 0) return 'Due today';
    return 'Due in ${Helpers.dayCountLabel(days)}';
  }

  Widget _link(String text, VoidCallback onTap, {Color color = AppTheme.primaryGreen}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ),
    );
  }

  Widget _drillRow(IconData icon, Color color, String label, int count, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.primaryText)),
            ),
            Text(
              '$count',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: count > 0 ? color : AppTheme.lightText),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 16, color: AppTheme.lightText),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, int count, Color color, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text('$count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: AppTheme.secondaryText),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _card({
    required String title,
    bool? expanded,
    VoidCallback? onToggle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primaryText)),
                ),
                if (trailing != null) trailing,
                if (onToggle != null)
                  InkWell(
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: expanded == true
                          ? const Icon(Icons.close, size: 16, color: AppTheme.secondaryText)
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Expand', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kGreen)),
                                Icon(Icons.expand_less, size: 14, color: _kGreen),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }
}
