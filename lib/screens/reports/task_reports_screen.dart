import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../models/task.dart';
import '../../services/local_database_service.dart';
import '../../utils/constants.dart';
import '../../utils/export_service.dart';
import '../../utils/paywall_constants.dart';
import '../task_detail/task_detail_screen.dart';
import '../../widgets/report_widgets.dart';

/// Bundle of the data a Task report needs (loaded once).
class _TaskReportData {
  final List<TaskModel> tasks;
  final List<Map<String, dynamic>> actionRows;
  const _TaskReportData(this.tasks, this.actionRows);
}

/// Premium Task analytics: KPI cards + breakdown tables, each section
/// exportable to CSV/Excel/PDF via [ExportService].
class TaskReportsScreen extends StatefulWidget {
  const TaskReportsScreen({super.key});

  @override
  State<TaskReportsScreen> createState() => _TaskReportsScreenState();
}

class _TaskReportsScreenState extends State<TaskReportsScreen> {
  static const Color _accent = AppTheme.headerGreen;
  late Future<_TaskReportData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_TaskReportData> _load() async {
    final userId = context.read<AuthProvider>().userModel?.uid ?? '';
    final tasks = await context.read<TaskProvider>().getAllTasks(userId);
    final visible = tasks.where((t) => !t.isDeleted).toList();
    final actions = await LocalDatabaseService().getAllActions(
      parentType: 'task',
    );
    return _TaskReportData(visible, actions);
  }

  // ── Predicates ────────────────────────────────────────────────────────
  bool _isOpen(TaskModel t) => !t.isClosed && !t.isCancelled;
  bool _isCompleted(TaskModel t) => t.isClosed;
  bool _isCancelled(TaskModel t) => t.isCancelled;

  // Premium = interactive reports: rows tap through to the linked card.
  // Free users still see everything read-only.
  bool get _interactive =>
      PaywallLimits.canInteractReports(
        context.read<AuthProvider>().effectivePlanType,
      );

  /// Export stays a premium affordance inside the free read-only screen.
  void _guardExport(VoidCallback action) {
    if (!PaywallLimits.canExport(
      context.read<AuthProvider>().effectivePlanType,
    )) {
      showPaywallDialog(
        context,
        feature: 'Export is a Premium feature.',
        detail: 'Upgrade to Premium to export reports to CSV, Excel and PDF.',
      );
      return;
    }
    action();
  }

  void _openTask(TaskModel task) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.lightGrey,
      appBar: AppBar(
        title: const Text('Task Reports'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<_TaskReportData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final tasks = snap.data?.tasks ?? [];
          final actionRows = snap.data?.actionRows ?? [];
          if (tasks.isEmpty) {
            return const Center(
              child: Text(
                'No tasks to report',
                style: TextStyle(color: AppTheme.secondaryText),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _overviewSection(tasks),
              _byAssigneeSection(tasks),
              _prioritySection(tasks),
              _deadlinesSection(tasks),
              _milestonesSection(tasks),
              _actionsSection(actionRows),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  // ── 1. Overview ─────────────────────────────────────────────────────────
  Widget _overviewSection(List<TaskModel> tasks) {
    final total = tasks.length;
    final open = tasks.where(_isOpen).length;
    final completed = tasks.where(_isCompleted).length;
    final cancelled = tasks.where(_isCancelled).length;
    final overdue = tasks.where((t) => t.isOverdue).length;
    final rate = total == 0 ? 0 : (completed / total * 100).round();

    return ReportSection(
      title: 'Overview',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Metric', 'Value'],
          rows: [
            ['Total Tasks', '$total'],
            ['Open', '$open'],
            ['Completed', '$completed'],
            ['Cancelled', '$cancelled'],
            ['Overdue', '$overdue'],
            ['Completion Rate', '$rate%'],
          ],
          title: 'Task Report - Overview',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(label: 'Total', value: '$total', accent: _accent),
            ReportStatCard(label: 'Open', value: '$open', accent: _accent),
            ReportStatCard(
              label: 'Completed',
              value: '$completed',
              accent: _accent,
            ),
            ReportStatCard(
              label: 'Cancelled',
              value: '$cancelled',
              accent: _accent,
            ),
            ReportStatCard(
              label: 'Overdue',
              value: '$overdue',
              accent: AppTheme.urgent,
            ),
            ReportStatCard(
              label: 'Completion',
              value: '$rate%',
              accent: _accent,
            ),
          ],
        ),
      ],
    );
  }

  // ── 2. By Assignee ────────────────────────────────────────────────────
  Widget _byAssigneeSection(List<TaskModel> tasks) {
    final map = <String, List<TaskModel>>{};
    for (final t in tasks) {
      final name = t.assignedTo.trim().isEmpty ? 'Unassigned' : t.assignedTo;
      map.putIfAbsent(name, () => []).add(t);
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    final rows = entries.map((e) {
      final list = e.value;
      return [
        e.key,
        '${list.length}',
        '${list.where(_isOpen).length}',
        '${list.where(_isCompleted).length}',
        '${list.where((t) => t.isOverdue).length}',
      ];
    }).toList();

    return ReportSection(
      title: 'By Assignee',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Assignee', 'Total', 'Open', 'Completed', 'Overdue'],
          rows: rows,
          title: 'Task Report - By Assignee',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportBreakdownTable(
          headers: const ['Assignee', 'Total', 'Open', 'Done', 'Overdue'],
          rows: rows,
          accent: _accent,
          flex: const [3, 1, 1, 1, 1],
        ),
      ],
    );
  }

  // ── 3. Priority & Urgency ───────────────────────────────────────────────
  Widget _prioritySection(List<TaskModel> tasks) {
    final high = tasks.where((t) => t.priority == 3).length;
    final med = tasks.where((t) => t.priority == 2).length;
    final low = tasks.where((t) => t.priority == 1).length;
    final urgent = tasks.where((t) => t.isUrgent).length;

    return ReportSection(
      title: 'Priority & Urgency',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Metric', 'Count'],
          rows: [
            ['High Priority', '$high'],
            ['Medium Priority', '$med'],
            ['Low Priority', '$low'],
            ['Urgent', '$urgent'],
          ],
          title: 'Task Report - Priority',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(
              label: 'High',
              value: '$high',
              accent: AppTheme.highPriority,
            ),
            ReportStatCard(
              label: 'Medium',
              value: '$med',
              accent: AppTheme.midPriority,
            ),
            ReportStatCard(
              label: 'Low',
              value: '$low',
              accent: AppTheme.lowPriority,
            ),
            ReportStatCard(
              label: 'Urgent',
              value: '$urgent',
              accent: AppTheme.urgent,
            ),
          ],
        ),
      ],
    );
  }

  // ── 4. Deadlines ────────────────────────────────────────────────────────
  Widget _deadlinesSection(List<TaskModel> tasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    bool isDueToday(TaskModel t) =>
        t.deadline != null &&
        !t.isClosed &&
        DateTime(t.deadline!.year, t.deadline!.month, t.deadline!.day) == today;
    bool isDueSoon(TaskModel t) =>
        t.deadline != null &&
        !t.isClosed &&
        !t.isOverdue &&
        t.daysUntilDeadline >= 0 &&
        t.daysUntilDeadline <= 2;

    final overdueList = tasks.where((t) => t.isOverdue).toList()
      ..sort((a, b) => a.deadline!.compareTo(b.deadline!));
    final dueToday = tasks.where(isDueToday).length;
    final dueSoon = tasks.where(isDueSoon).length;
    final noDeadline = tasks.where((t) => t.deadline == null).length;

    final overdueRows = overdueList.map((t) {
      final days = now.difference(t.deadline!).inDays;
      return [
        t.title,
        t.assignedTo.trim().isEmpty ? 'Unassigned' : t.assignedTo,
        '$days',
      ];
    }).toList();

    return ReportSection(
      title: 'Deadlines',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Task', 'Assignee', 'Days Overdue'],
          rows: overdueRows,
          title: 'Task Report - Overdue',
          filterLabel: 'Overdue',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(
              label: 'Overdue',
              value: '${overdueList.length}',
              accent: AppTheme.urgent,
            ),
            ReportStatCard(
              label: 'Due Today',
              value: '$dueToday',
              accent: AppTheme.deadlineNearing,
            ),
            ReportStatCard(
              label: 'Due < 2d',
              value: '$dueSoon',
              accent: AppTheme.deadlineNearing,
            ),
            ReportStatCard(
              label: 'No Deadline',
              value: '$noDeadline',
              accent: _accent,
            ),
          ],
        ),
        if (overdueRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Overdue tasks',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.secondaryText,
            ),
          ),
          const SizedBox(height: 6),
          ReportBreakdownTable(
            headers: const ['Task', 'Assignee', 'Days'],
            rows: overdueRows,
            accent: _accent,
            flex: const [3, 2, 1],
            onRowTap: _interactive ? (i) => _openTask(overdueList[i]) : null,
          ),
        ],
      ],
    );
  }

  // ── 5. Milestone Progress ─────────────────────────────────────────────
  Widget _milestonesSection(List<TaskModel> tasks) {
    final withMs = tasks.where((t) => t.milestones.isNotEmpty).toList();
    var notStarted = 0, inProgress = 0, complete = 0;
    for (final t in withMs) {
      final done = t.milestones.where((m) => m.isCompleted).length;
      if (done == 0) {
        notStarted++;
      } else if (done == t.milestones.length) {
        complete++;
      } else {
        inProgress++;
      }
    }

    return ReportSection(
      title: 'Milestone Progress',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Metric', 'Count'],
          rows: [
            ['Tasks with Milestones', '${withMs.length}'],
            ['Not Started', '$notStarted'],
            ['In Progress', '$inProgress'],
            ['Complete', '$complete'],
          ],
          title: 'Task Report - Milestones',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(
              label: 'With Milestones',
              value: '${withMs.length}',
              accent: _accent,
            ),
            ReportStatCard(
              label: 'Not Started',
              value: '$notStarted',
              accent: AppTheme.secondaryText,
            ),
            ReportStatCard(
              label: 'In Progress',
              value: '$inProgress',
              accent: AppTheme.deadlineNearing,
            ),
            ReportStatCard(
              label: 'Complete',
              value: '$complete',
              accent: AppTheme.onTime,
            ),
          ],
        ),
      ],
    );
  }

  // ── 6. Actions Summary ────────────────────────────────────────────────
  Widget _actionsSection(List<Map<String, dynamic>> rows) {
    // Ignore "deadline updated" noise, mirroring the Actions tab.
    final items = rows.where((r) {
      final text = (r['text'] as String? ?? '').toLowerCase();
      return !text.contains('deadline updated');
    }).toList();

    int countType(String type) =>
        items.where((r) => r['actionType'] == type).length;

    final reminders = countType('reminder');
    final warnings = countType('warning');
    final followUps = items
        .where((r) => r['actionType'] == 'followup')
        .toList();
    final followDone = followUps
        .where((r) => (r['isDone'] as int? ?? 0) == 1)
        .length;
    final followPending = followUps.length - followDone;
    final queries = items.where((r) => r['actionType'] == 'query').toList();
    final queriesReplied = queries
        .where((r) => (r['isReplied'] as int? ?? 0) == 1)
        .length;
    final queriesPending = queries.length - queriesReplied;

    return ReportSection(
      title: 'Actions Summary',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Action', 'Total', 'Pending', 'Done/Replied'],
          rows: [
            ['Reminders', '$reminders', '-', '-'],
            [
              'Follow-ups',
              '${followUps.length}',
              '$followPending',
              '$followDone',
            ],
            ['Warnings', '$warnings', '-', '-'],
            [
              'Queries',
              '${queries.length}',
              '$queriesPending',
              '$queriesReplied',
            ],
          ],
          title: 'Task Report - Actions',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(
              label: 'Reminders',
              value: '$reminders',
              accent: AppTheme.deadlineNearing,
            ),
            ReportStatCard(
              label: 'Follow-ups',
              value: '${followUps.length}',
              accent: _accent,
            ),
            ReportStatCard(
              label: 'Warnings',
              value: '$warnings',
              accent: AppTheme.urgent,
            ),
            ReportStatCard(
              label: 'Queries',
              value: '${queries.length}',
              accent: AppTheme.onTime,
            ),
          ],
        ),
        const SizedBox(height: 12),
        ReportBreakdownTable(
          headers: const ['Action', 'Total', 'Pending', 'Done'],
          rows: [
            [
              'Follow-ups',
              '${followUps.length}',
              '$followPending',
              '$followDone',
            ],
            [
              'Queries',
              '${queries.length}',
              '$queriesPending',
              '$queriesReplied',
            ],
          ],
          accent: _accent,
          flex: const [2, 1, 1, 1],
        ),
      ],
    );
  }
}
