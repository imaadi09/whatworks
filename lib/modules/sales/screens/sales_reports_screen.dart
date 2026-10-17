import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../services/local_database_service.dart';
import '../../../utils/constants.dart';
import '../../../utils/export_service.dart';
import '../../../utils/paywall_constants.dart';
import '../../../widgets/report_widgets.dart';
import '../models/enquiry.dart';
import '../providers/sales_provider.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../../crm/providers/crm_provider.dart';
import 'sales_detail_screen.dart';

/// Bundle of the data a Sales report needs (loaded once).
class _SalesReportData {
  final List<EnquiryModel> enquiries;
  final List<Map<String, dynamic>> actionRows;
  const _SalesReportData(this.enquiries, this.actionRows);
}

/// Premium Sales analytics: pipeline funnel, workload, deadlines, milestones
/// and actions, presented as KPI cards + tables and exportable per section.
class SalesReportsScreen extends StatefulWidget {
  final ModuleConfig? moduleConfig;
  const SalesReportsScreen({super.key, this.moduleConfig});

  @override
  State<SalesReportsScreen> createState() => _SalesReportsScreenState();
}

class _SalesReportsScreenState extends State<SalesReportsScreen> {
  ModuleConfig get _config => widget.moduleConfig ?? ModuleConfig.sales;
  bool get _isCrm => _config.type == ModuleType.crm;
  BaseModuleProvider _readProvider(BuildContext ctx) =>
      _isCrm ? ctx.read<CrmProvider>() : ctx.read<SalesProvider>();
  Color get _accent => _config.themeColor;

  late Future<_SalesReportData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_SalesReportData> _load() async {
    final userId = context.read<AuthProvider>().userModel?.uid ?? '';
    final salesProvider = _readProvider(context);
    final teamId = salesProvider.currentTeamId;
    final enquiries = await salesProvider.getAllEnquiries(
      userId,
      teamId: teamId,
    );
    final actions = teamId != null
        ? await LocalDatabaseService().getSalesActions(
            teamId,
            table: _config.actionsTableName,
          )
        : <Map<String, dynamic>>[];
    return _SalesReportData(enquiries, actions);
  }

  int _count(List<EnquiryModel> list, String s) =>
      list.where((e) => e.status == s).length;

  /// Enquiries still moving through the pipeline (any open stage), so the new
  /// mid-funnel stages (quotation/demo/negotiation) are not lost from the
  /// "Active" totals.
  int _countOpen(List<EnquiryModel> list) =>
      list.where((e) => _config.isOpenStatus(e.status)).length;

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

  void _openEnquiry(EnquiryModel enquiry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SalesDetailScreen(enquiry: enquiry, moduleConfig: _config),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.lightGrey,
      appBar: AppBar(
        title: const Text('Sales Reports'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<_SalesReportData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final enquiries = snap.data?.enquiries ?? [];
          final actionRows = snap.data?.actionRows ?? [];
          if (enquiries.isEmpty) {
            return const Center(
              child: Text(
                'No enquiries to report',
                style: TextStyle(color: AppTheme.secondaryText),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _pipelineSection(enquiries),
              _byAssigneeSection(enquiries),
              _prioritySection(enquiries),
              _deadlinesSection(enquiries),
              _milestonesSection(enquiries),
              _actionsSection(actionRows),
              _winLossSection(actionRows),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  // ── 1. Pipeline Overview ────────────────────────────────────────────────
  Widget _pipelineSection(List<EnquiryModel> list) {
    final total = list.length;
    final active = _countOpen(list);
    final success = _count(list, SalesStatus.success);
    final lost = _count(list, SalesStatus.lost);
    final dropped = _count(list, SalesStatus.dropped);
    final cancel = _count(list, SalesStatus.cancel);
    final decided = success + lost + dropped;
    final winRate = decided == 0 ? 0 : (success / decided * 100).round();

    return ReportSection(
      title: 'Pipeline Overview',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Metric', 'Value'],
          rows: [
            ['Total Enquiries', '$total'],
            ['Active', '$active'],
            ['Success', '$success'],
            ['Lost', '$lost'],
            ['Dropped', '$dropped'],
            ['Cancelled', '$cancel'],
            ['Win Rate', '$winRate%'],
          ],
          title: 'Sales Report - Pipeline',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(label: 'Total', value: '$total', accent: _accent),
            ReportStatCard(label: 'Active', value: '$active', accent: _accent),
            ReportStatCard(
              label: 'Success',
              value: '$success',
              accent: AppTheme.onTime,
            ),
            ReportStatCard(
              label: 'Lost',
              value: '$lost',
              accent: AppTheme.urgent,
            ),
            ReportStatCard(
              label: 'Dropped',
              value: '$dropped',
              accent: AppTheme.secondaryText,
            ),
            ReportStatCard(
              label: 'Cancelled',
              value: '$cancel',
              accent: AppTheme.secondaryText,
            ),
            ReportStatCard(
              label: 'Win Rate',
              value: '$winRate%',
              accent: AppTheme.onTime,
            ),
          ],
        ),
      ],
    );
  }

  // ── 2. By Assignee ────────────────────────────────────────────────────
  Widget _byAssigneeSection(List<EnquiryModel> list) {
    final map = <String, List<EnquiryModel>>{};
    for (final e in list) {
      final name = e.assignedTo.trim().isEmpty ? 'Unassigned' : e.assignedTo;
      map.putIfAbsent(name, () => []).add(e);
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    final rows = entries.map((e) {
      final v = e.value;
      final success = _count(v, SalesStatus.success);
      final lost = _count(v, SalesStatus.lost);
      final dropped = _count(v, SalesStatus.dropped);
      final decided = success + lost + dropped;
      final win = decided == 0 ? 0 : (success / decided * 100).round();
      return [
        e.key,
        '${v.length}',
        '${_countOpen(v)}',
        '$success',
        '$lost',
        '$win%',
      ];
    }).toList();

    return ReportSection(
      title: 'By Assignee',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const [
            'Assignee',
            'Total',
            'Active',
            'Success',
            'Lost',
            'Win Rate',
          ],
          rows: rows,
          title: 'Sales Report - By Assignee',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportBreakdownTable(
          headers: const ['Assignee', 'Total', 'Active', 'Won', 'Lost', 'Win%'],
          rows: rows,
          accent: _accent,
          flex: const [3, 1, 1, 1, 1, 1],
        ),
      ],
    );
  }

  // ── 3. Priority & Urgency ───────────────────────────────────────────────
  Widget _prioritySection(List<EnquiryModel> list) {
    final high = list.where((e) => e.priority == 3).length;
    final med = list.where((e) => e.priority == 2).length;
    final low = list.where((e) => e.priority == 1).length;
    final urgent = list.where((e) => e.isUrgent).length;

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
          title: 'Sales Report - Priority',
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
  Widget _deadlinesSection(List<EnquiryModel> list) {
    final now = DateTime.now();

    bool isOverdue(EnquiryModel e) =>
        e.deadline != null && !e.isClosed && now.isAfter(e.deadline!);
    bool isDueSoon(EnquiryModel e) {
      if (e.deadline == null || e.isClosed || isOverdue(e)) return false;
      final days = e.deadline!.difference(now).inDays;
      return days >= 0 && days <= 2;
    }

    final overdueList = list.where(isOverdue).toList()
      ..sort((a, b) => a.deadline!.compareTo(b.deadline!));
    final dueSoon = list.where(isDueSoon).length;
    final noDeadline = list.where((e) => e.deadline == null).length;

    final overdueRows = overdueList.map((e) {
      final days = now.difference(e.deadline!).inDays;
      return [
        e.title.trim().isEmpty ? e.clientName : e.title,
        e.assignedTo.trim().isEmpty ? 'Unassigned' : e.assignedTo,
        '$days',
      ];
    }).toList();

    return ReportSection(
      title: 'Deadlines',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Enquiry', 'Assignee', 'Days Overdue'],
          rows: overdueRows,
          title: 'Sales Report - Overdue',
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
            'Overdue enquiries',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.secondaryText,
            ),
          ),
          const SizedBox(height: 6),
          ReportBreakdownTable(
            headers: const ['Enquiry', 'Assignee', 'Days'],
            rows: overdueRows,
            accent: _accent,
            flex: const [3, 2, 1],
            onRowTap: _interactive ? (i) => _openEnquiry(overdueList[i]) : null,
          ),
        ],
      ],
    );
  }

  // ── 5. Milestone Progress ─────────────────────────────────────────────
  Widget _milestonesSection(List<EnquiryModel> list) {
    final withMs = list.where((e) => e.milestones.isNotEmpty).toList();
    var notStarted = 0, inProgress = 0, complete = 0;
    for (final e in withMs) {
      final done = e.milestones.where((m) => m.isCompleted).length;
      if (done == 0) {
        notStarted++;
      } else if (done == e.milestones.length) {
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
            ['Enquiries with Milestones', '${withMs.length}'],
            ['Not Started', '$notStarted'],
            ['In Progress', '$inProgress'],
            ['Complete', '$complete'],
          ],
          title: 'Sales Report - Milestones',
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

    // Per-type counts for the sales-cycle actions (catalog-driven; the 4
    // classic types above already have dedicated cards)
    final cycleTypes = _config.actionTypes
        .where(
          (a) => !const {
            'reminder',
            'followup',
            'query',
            'warning',
          }.contains(a.key),
        )
        .toList();
    final cycleCounts = {for (final a in cycleTypes) a.key: countType(a.key)};

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
            ['Escalations', '$warnings', '-', '-'],
            [
              'Queries',
              '${queries.length}',
              '$queriesPending',
              '$queriesReplied',
            ],
            for (final a in cycleTypes)
              [a.label, '${cycleCounts[a.key]}', '-', '-'],
          ],
          title: 'Sales Report - Actions',
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
              label: 'Escalations',
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
            for (final a in cycleTypes)
              [a.label, '${cycleCounts[a.key]}', '-', '-'],
          ],
          accent: _accent,
          flex: const [2, 1, 1, 1],
        ),
      ],
    );
  }

  // ── 7. Win / Loss Reasons ─────────────────────────────────────────────
  /// Extract the reason from a Won/Lost message, e.g.
  /// '🏆 Won — Price: notes' → 'Price'.
  String _parseWinLossReason(String text) {
    final idx = text.indexOf('— ');
    if (idx == -1) return 'Unspecified';
    var reason = text.substring(idx + 2);
    final colon = reason.indexOf(':');
    if (colon != -1) reason = reason.substring(0, colon);
    reason = reason.trim();
    return reason.isEmpty ? 'Unspecified' : reason;
  }

  Widget _winLossSection(List<Map<String, dynamic>> rows) {
    final wonRows = rows.where((r) => r['actionType'] == 'won').toList();
    final lostRows = rows.where((r) => r['actionType'] == 'lost').toList();
    if (wonRows.isEmpty && lostRows.isEmpty) return const SizedBox.shrink();

    Map<String, int> reasonCounts(List<Map<String, dynamic>> list) {
      final counts = <String, int>{};
      for (final r in list) {
        final reason = _parseWinLossReason(r['text'] as String? ?? '');
        counts[reason] = (counts[reason] ?? 0) + 1;
      }
      return counts;
    }

    final wonReasons = reasonCounts(wonRows);
    final lostReasons = reasonCounts(lostRows);
    final tableRows = <List<String>>[
      for (final e in wonReasons.entries) ['Won', e.key, '${e.value}'],
      for (final e in lostReasons.entries) ['Lost', e.key, '${e.value}'],
    ];

    return ReportSection(
      title: 'Win / Loss Reasons',
      accent: _accent,
      onExport: () => _guardExport(() {
        ExportService.showExportDialog(
          context: context,
          headers: const ['Outcome', 'Reason', 'Count'],
          rows: tableRows,
          title: 'Sales Report - Win Loss Reasons',
          filterLabel: 'All',
        );
      }),
      children: [
        ReportStatRow(
          cards: [
            ReportStatCard(
              label: 'Won',
              value: '${wonRows.length}',
              accent: ModuleActions.won.color,
            ),
            ReportStatCard(
              label: 'Lost',
              value: '${lostRows.length}',
              accent: ModuleActions.lost.color,
            ),
          ],
        ),
        const SizedBox(height: 12),
        ReportBreakdownTable(
          headers: const ['Outcome', 'Reason', 'Count'],
          rows: tableRows,
          accent: _accent,
          flex: const [1, 2, 1],
        ),
      ],
    );
  }
}
