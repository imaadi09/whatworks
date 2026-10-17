import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/enquiry.dart';
import '../providers/sales_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../utils/constants.dart';
import '../../../utils/helpers.dart';
import '../../../utils/paywall_constants.dart';
import '../../../utils/export_service.dart';
import '../../../services/firebase_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/avatar_cache_service.dart';
import '../../../widgets/app_avatar.dart';
import '../../../widgets/card_action_icons.dart';
import '../../../widgets/actions_filter_ui.dart';
import '../../../widgets/dashed_progress_bar.dart';
import '../../../widgets/visibility_gated_tab.dart';
import 'sales_detail_screen.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../../crm/providers/crm_provider.dart';

/// Handle so the home screen can clear the Actions tab's bell view when
/// the user navigates away (attention mode is session-only).
class SalesActionsController {
  _SalesActionsScreenState? _state;

  /// Clear the bell/attention view (called when leaving the Actions tab).
  void resetAttentionMode() => _state?._resetAttentionMode();
}

/// Full actions list for the module, pushed from the home AppBar or
/// embedded in the home bottom-nav ACTIONS tab.
class SalesActionsScreen extends StatefulWidget {
  /// The module this screen operates in (Sales or CRM). Required so a
  /// missing config can never silently fall back to Sales mode.
  final ModuleConfig moduleConfig;

  /// When true, renders without its own AppBar (home provides the chrome).
  final bool embedded;

  /// Optional handle so the home screen can reset the bell view.
  final SalesActionsController? controller;

  /// Whether this tab is the currently-visible one. The home [IndexedStack]
  /// keeps every visited tab mounted, so a hidden tab must NOT re-run its
  /// expensive enquiries scan on every sync notification — that is what froze
  /// the UI when several tabs were alive at once. A hidden tab only flags
  /// [_SalesActionsScreenState._pendingRefresh] and catches up once on becoming
  /// visible again. Defaults to true so a full-screen push always stays live.
  final bool isActive;
  const SalesActionsScreen({
    super.key,
    required this.moduleConfig,
    this.embedded = false,
    this.controller,
    this.isActive = true,
  });

  @override
  State<SalesActionsScreen> createState() => _SalesActionsScreenState();
}

class _SalesActionsScreenState extends State<SalesActionsScreen>
    with VisibilityGatedTabState {
  ModuleConfig get _config => widget.moduleConfig;
  bool get _isCrm => _config.type == ModuleType.crm;

  BaseModuleProvider _watchProvider(BuildContext ctx) =>
      _isCrm ? ctx.watch<CrmProvider>() : ctx.watch<SalesProvider>();

  BaseModuleProvider _readProvider(BuildContext ctx) =>
      _isCrm ? ctx.read<CrmProvider>() : ctx.read<SalesProvider>();

  Color get _themeColor => _config.themeColor;

  // Two-axis filter (mirrors the assignee Actions tab): a time chip row
  // plus an optional action type picked from the sheet.
  String _timeFilter = kActionTimeToday;
  String? _typeFilter;
  static const _timeOptions = kActionTimeOptions;
  // Derive the Type filter from THIS module's action catalog (Sales or CRM via
  // _config) so each module lists only its own actions with canonical labels —
  // CRM's 'quotation' reads 'Estimate', and neither surface leaks the other's
  // types or the never-creatable generic types (blocker/extension/progress).
  // Sales/CRM rows store `followup` but expose it as `followUp` in
  // _actionsFromRows, so map the value to match the type-axis comparison.
  List<ActionFilterOption> get _typeOptions => actionTypeFilterOptions(
    _config.actionTypes,
    valueFor: (k) => k == 'followup' ? 'followUp' : k,
  );
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

  /// Clear the bell view; called via [SalesActionsController] when the home
  /// screen navigates away from the Actions tab.
  void _resetAttentionMode() {
    if (_attentionMode) {
      setState(() {
        _attentionMode = false;
        _timeFilter = kActionTimeToday;
      });
    }
  }

  final Set<String> _hiddenActionIds = {};
  final Set<String> _expandedEnquiryCards = {};

  List<_SalesActionItem> _currentActionItems =
      []; // Currently visible actions (for export)

  // Enquiries cached once (and on table changes) so the actions list paints
  // immediately — previously a per-build FutureBuilder showed a spinner on
  // every rebuild
  List<EnquiryModel> _allEnquiries = [];
  StreamSubscription<TableChange>? _enquiriesTableSub;
  Timer? _reloadDebounce;

  // Visibility gating (see [VisibilityGatedTabState]): a hidden tab defers its
  // full-scan reload and catches up once when shown again.
  @override
  bool get isActiveTab => widget.isActive;
  @override
  void onTabBecameActive() => _loadEnquiries();

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEnquiries());
    _enquiriesTableSub = LocalDatabaseService().tableChanges2
        .where((c) => c.table == _config.enquiriesTableName)
        .listen((_) {
          if (!mounted) return;
          // Hidden tab: don't re-run the full enquiries scan; just remember to
          // catch up when the tab is shown again.
          if (isTabHidden) {
            deferRefresh();
            return;
          }
          _reloadDebounce?.cancel();
          _reloadDebounce = Timer(
            const Duration(milliseconds: 300),
            _loadEnquiries,
          );
        });
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _enquiriesTableSub?.cancel();
    _reloadDebounce?.cancel();
    super.dispose();
  }

  /// Pending-actions summary by type (mirrors the Task Actions strip).
  Widget _buildNeedsAttentionStrip(BaseModuleProvider provider) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: LocalDatabaseService().watchSalesActions(
        provider.currentTeamId,
        table: _config.actionsTableName,
      ),
      builder: (context, snap) {
        // Shared pending rule + module-agnostic label map (raw actions-table
        // rows use canonical keys) so this banner can't drift from the Needs
        // Attention filter or the nav badge.
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

  Future<void> _loadEnquiries() async {
    if (!mounted) return;
    final userId = context.read<AuthProvider>().userModel?.uid ?? '';
    if (userId.isEmpty) return;
    final provider = _readProvider(context);
    final result = await provider.getAllEnquiries(
      userId,
      teamId: provider.currentTeamId,
    );
    if (!mounted) return;
    setState(() => _allEnquiries = result);
  }

  @override
  Widget build(BuildContext context) {
    final salesProvider = _watchProvider(context);
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
            Expanded(child: _buildActionsTab(salesProvider)),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 1,
        title: const Text(
          'Actions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Export',
            onPressed: _exportActionsGuarded,
          ),
        ],
      ),
      body: _buildActionsTab(salesProvider),
    );
  }

  Widget _buildActionsTab(BaseModuleProvider salesProvider) {
    return Column(
      children: [
        // Pending-actions summary shows only while the bell is on.
        if (_attentionMode) _buildNeedsAttentionStrip(salesProvider),
        _buildActionsFilterRow(), // Filter row outside StreamBuilder - doesn't rebuild on stream changes
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: LocalDatabaseService().watchSalesActions(
              salesProvider.currentTeamId,
              table: _config.actionsTableName,
            ),
            builder: (context, snapshot) {
              final actionRows = snapshot.data ?? [];
              final items = _actionsFromRows(actionRows);
              final filtered = _applyActionFilter(items);

              // Sort by scheduled date descending (latest first)
              filtered.sort(
                (a, b) => CardActionIcons.compareActions(
                  a.scheduledDate,
                  a.createdAt,
                  b.scheduledDate,
                  b.createdAt,
                ),
              );

              // Cache for export
              _currentActionItems = filtered;

              // Group by enquiry
              final enquiryActions = <String, List<_SalesActionItem>>{};
              for (final item in filtered) {
                enquiryActions.putIfAbsent(item.enquiryId, () => []).add(item);
              }

              // Sort enquiry groups by most recent action first
              final sortedEnquiryIds = enquiryActions.keys.toList();
              sortedEnquiryIds.sort((a, b) {
                final actionsA = enquiryActions[a]!;
                final actionsB = enquiryActions[b]!;
                final keyA = actionsA
                    .map(
                      (x) => CardActionIcons.actionSortTuple(
                        x.scheduledDate,
                        x.createdAt,
                      ),
                    )
                    .reduce(CardActionIcons.minActionTuple);
                final keyB = actionsB
                    .map(
                      (x) => CardActionIcons.actionSortTuple(
                        x.scheduledDate,
                        x.createdAt,
                      ),
                    )
                    .reduce(CardActionIcons.minActionTuple);
                final cmp = keyA.$1.compareTo(keyB.$1);
                return cmp != 0 ? cmp : keyA.$2.compareTo(keyB.$2);
              });

              // Get all unique enquiry IDs that have actions
              final enquiryIdsWithActions = enquiryActions.keys.toSet();

              if (items.isEmpty) {
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
                      const Text(
                        'No action items yet',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Actions scheduled in enquiries will appear here',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.lightText,
                        ),
                      ),
                    ],
                  ),
                );
              } else if (sortedEnquiryIds.isEmpty) {
                return const Center(
                  child: Text(
                    'No actions matching filter',
                    style: TextStyle(fontSize: 14, color: AppTheme.lightText),
                  ),
                );
              } else {
                // Build enquiry map from the cached enquiry list — loaded in
                // initState and refreshed on SQLite table changes, so the
                // list paints without a per-build FutureBuilder spinner
                final enquiryMap = <String, EnquiryModel>{};
                for (final e in _allEnquiries) {
                  if (enquiryIdsWithActions.contains(e.id)) {
                    enquiryMap[e.id] = e;
                  }
                }

                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 500,
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  itemCount: sortedEnquiryIds.length,
                  itemBuilder: (context, index) {
                    final enquiryId = sortedEnquiryIds[index];
                    final actions = enquiryActions[enquiryId]!;
                    final enquiry = enquiryMap[enquiryId];
                    if (enquiry == null) return const SizedBox.shrink();
                    return _buildEnquiryActionCard(
                      enquiry,
                      actions,
                      salesProvider,
                    );
                  },
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildActionsFilterRow() {
    return buildActionFilterDropdowns(
      timeOptions: _timeOptions,
      selectedTime: _timeFilter,
      onTimeChanged: (v) => setState(() => _timeFilter = v),
      typeOptions: _typeOptions,
      selectedType: _typeFilter,
      onTypeChanged: (v) => setState(() => _typeFilter = v),
    );
  }

  // ── Action Items from Actions Table ─────────────────────────────────────

  /// Convert action table rows to _SalesActionItem list.
  List<_SalesActionItem> _actionsFromRows(List<Map<String, dynamic>> rows) {
    final items = <_SalesActionItem>[];
    for (final row in rows) {
      final messageText = row['text'] as String? ?? '';
      // Skip "deadline updated" actions - not relevant for Actions tab
      if (messageText.toLowerCase().contains('deadline updated')) continue;

      final actionType = row['actionType'] as String;
      final type = actionType == 'followup' ? 'followUp' : actionType;
      final scheduledMs = row['scheduledDate'] as int?;
      final createdMs = row['createdAt'] as int;
      items.add(
        _SalesActionItem(
          enquiryId: row['parentId'] as String,
          clientName: row['clientName'] as String? ?? '',
          enquiryTitle: row['parentTitle'] as String? ?? '',
          type: type,
          message: messageText,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
          scheduledDate: scheduledMs != null
              ? DateTime.fromMillisecondsSinceEpoch(scheduledMs)
              : DateTime.fromMillisecondsSinceEpoch(createdMs),
          hasScheduledDate: scheduledMs != null,
          isReplied: (row['isReplied'] as int) == 1,
          isFollowUpDone: (row['isDone'] as int) == 1,
          messageId: row['id'] as String? ?? '',
          seqNo: row['seqNo'] as int?,
        ),
      );
    }
    return items;
  }

  bool _isPendingAction(_SalesActionItem i) => Helpers.isActionPending(
    Helpers.actionKeyFromDisplay(i.type),
    isDone: i.isFollowUpDone ?? false,
    isReplied: i.isReplied ?? false,
  );

  List<_SalesActionItem> _applyActionFilter(List<_SalesActionItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

    // Time axis, then optional type axis (mirrors assignee Actions tab).
    List<_SalesActionItem> out;
    switch (_timeFilter) {
      case 'Overdue':
        out = items
            .where(
              (i) =>
                  // Overdue = a still-PENDING action past a REAL scheduled
                  // date (hasScheduledDate), so undated actions aging on their
                  // write date (and informational logs) never pile here.
                  i.hasScheduledDate &&
                  dayOf(i.scheduledDate).isBefore(today) &&
                  _isPendingAction(i),
            )
            .toList();
      case 'Today':
        out = items.where((i) => dayOf(i.scheduledDate) == today).toList();
      case 'Upcoming':
        out = items
            .where((i) => dayOf(i.scheduledDate).isAfter(today))
            .toList();
      // No time filter — the type axis below still applies.
      case kActionTimeAll:
        out = items;
      default:
        out = items.where(_isPendingAction).toList();
    }
    if (_typeFilter != null) {
      out = out.where((i) => i.type == _typeFilter).toList();
    }
    return out;
  }

  Widget _buildEnquiryActionCard(
    EnquiryModel enquiry,
    List<_SalesActionItem> actions,
    BaseModuleProvider salesProvider,
  ) {
    final currentUid = context.read<AuthProvider>().userModel?.uid ?? '';
    final currentName = context.read<AuthProvider>().userModel?.name ?? '';
    final currentPhone = context.read<AuthProvider>().userModel?.phone ?? '';
    final isCreatedByMe =
        enquiry.createdBy == currentUid ||
        (enquiry.createdByName?.trim() == currentName);
    final isAssignedToMe =
        enquiry.assignedToUid == currentUid ||
        enquiry.assignedTo == currentName ||
        enquiry.assignedTo.toLowerCase() == 'me' ||
        enquiry.assigneeUids.contains(currentUid);

    final creatorName = isCreatedByMe
        ? 'Me'
        : (enquiry.createdByName?.trim().isNotEmpty == true &&
                  enquiry.createdByName!.trim().toLowerCase() != 'user'
              ? enquiry.createdByName!.trim()
              : 'Someone');
    final assigneeName = isAssignedToMe
        ? 'Me'
        : (enquiry.assignedTo.isNotEmpty &&
                  enquiry.assignedTo != 'Someone' &&
                  enquiry.assignedTo.toLowerCase() != 'user'
              ? enquiry.assignedTo
              : (enquiry.clientName.isNotEmpty
                    ? enquiry.clientName
                    : 'Someone'));
    final displayInitials = Helpers.getInitials(
      isAssignedToMe ? creatorName : assigneeName,
    );
    final accentColor = isAssignedToMe ? _themeColor : const Color(0xFF1976D2);

    // Avatar of the shown person (photo or preset) — same resolution as the
    // Task Actions tab so both tabs render real profile pictures. Prefer the
    // index-aligned multi-assignee identity: the primary assignedToUid can be
    // blank on a group enquiry, so the same person could show a photo on one
    // card and initials on another (matches the task-card / task-actions fix).
    final shownName = isAssignedToMe ? creatorName : assigneeName;
    String? assigneeUid = enquiry.assignedToUid;
    String? assigneePhone = enquiry.assignedToPhone;
    final aNames = enquiry.assigneeNames;
    final aIdx = aNames.indexOf(assigneeName.trim());
    if (aIdx >= 0) {
      final uids = enquiry.assigneeUids;
      final phones = enquiry.assigneePhones;
      if (uids.length == aNames.length) {
        final u = uids[aIdx].trim();
        if (u.isNotEmpty) assigneeUid = u;
      }
      if (phones.length == aNames.length) {
        final p = phones[aIdx].trim();
        if (p.isNotEmpty) assigneePhone = p;
      }
    }
    final shownAvatarUrl = shownName == 'Me'
        ? AvatarCacheService().urlFor(
            uid: currentUid,
            phone: currentPhone,
            name: currentName,
          )
        : isAssignedToMe
        ? AvatarCacheService().urlFor(uid: enquiry.createdBy, name: creatorName)
        : AvatarCacheService().urlFor(
            uid: assigneeUid,
            phone: assigneePhone,
            name: assigneeName,
          );

    // Deadline calculation matching SalesCard format
    String daysToDeadline = '';
    Color deadlineColor = AppTheme.lightText;
    String daysFromStart = '';
    int totalDays = 0;
    if (enquiry.deadline != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final deadlineDate = DateTime(
        enquiry.deadline!.year,
        enquiry.deadline!.month,
        enquiry.deadline!.day,
      );
      final startDate = DateTime(
        enquiry.createdAt.year,
        enquiry.createdAt.month,
        enquiry.createdAt.day,
      );
      final difference = deadlineDate.difference(today).inDays;
      totalDays = deadlineDate.difference(startDate).inDays;
      final elapsedDays = today.difference(startDate).inDays;
      daysFromStart = elapsedDays >= 0 ? '${elapsedDays}d' : '0d';

      if (difference < 0) {
        daysToDeadline = '-${difference.abs()}d';
        deadlineColor = Colors.red;
      } else if (difference == 0) {
        final hoursLeft = enquiry.deadline!.difference(now).inHours;
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

    // Milestone count
    final completedMilestones = enquiry.completedMilestoneCount;
    final totalMilestones = enquiry.milestones.length;

    final visibleActions = actions
        .where(
          (a) => !_hiddenActionIds.contains(
            '${enquiry.id}_${a.type}_${a.createdAt.millisecondsSinceEpoch}',
          ),
        )
        .toList();
    final expanded = _expandedEnquiryCards.contains(enquiry.id);
    if (visibleActions.isEmpty) return const SizedBox.shrink();
    visibleActions.sort(
      (a, b) => CardActionIcons.compareActions(
        a.scheduledDate,
        a.createdAt,
        b.scheduledDate,
        b.createdAt,
      ),
    );

    // Running "#N" per base type (chronological) for the one-line rows.
    String baseOfAction(_SalesActionItem a) {
      const keys = {
        'quotation',
        'meeting',
        'sitevisit',
        'repaired',
        'verified',
        'call',
        'payment',
        'sample',
        'delivery',
        'collect',
        'negotiation',
        'won',
        'lost',
        'dropped',
        'cash',
      };
      if (keys.contains(a.type)) {
        final def = _config.actionFor(a.type);
        if (def != null) return def.label;
      }
      final lower = a.message.toLowerCase();
      if (a.type == 'warning' ||
          lower.contains('warning') ||
          lower.contains('escalation')) {
        return 'Escalation';
      }
      return CardActionIcons.actionBaseLabel(
        typeName: a.type,
        message: a.message,
      );
    }

    final chrono = List<_SalesActionItem>.from(visibleActions)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final seq = <String, int>{};
    final actionNumbers = <_SalesActionItem, int>{};
    for (final a in chrono) {
      final b = baseOfAction(a);
      // Cash/Payment sub-types share one family counter (cards-numbering
      // parity) — see CardActionIcons.numberingGroupKey.
      final group = CardActionIcons.numberingGroupKey(b);
      final n = (seq[group] ?? 0) + 1;
      seq[group] = n;
      actionNumbers[a] = n;
    }

    final enquiryTitle = enquiry.title.isNotEmpty ? enquiry.title : 'Enquiry';

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
                builder: (context) =>
                    SalesDetailScreen(enquiry: enquiry, moduleConfig: _config),
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
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1: Enquiry title + milestone chip + days badge + priority flag
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                enquiryTitle,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (totalMilestones > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _themeColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'M$completedMilestones',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _themeColor.withOpacity(0.7),
                                  ),
                                ),
                              ),
                            ],
                            if (enquiry.deadline != null) ...[
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
                            // Urgency flag slot (fixed width) — always
                            // reserved so the chips keep a constant position
                            // whether or not the enquiry is urgent
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: enquiry.isUrgent
                                  ? const Icon(
                                      Icons.flag,
                                      size: 14,
                                      color: Colors.red,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                        // Line 2: From → To (matches Task Action Card)
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
                                assigneeName,
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
                        // Line 3: Client name
                        if (enquiry.clientName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 10,
                                color: _themeColor.withOpacity(0.7),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  enquiry.clientName,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: _themeColor.withOpacity(0.8),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Vertical progress bar (right side, matching SalesCard)
                  DashedProgressBar(
                    progress: enquiry.progress.clamp(0.0, 1.0),
                    color: _themeColor,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ...(expanded ? visibleActions : visibleActions.take(3)).map((action) {
            final lower = action.message.toLowerCase();
            // Exact-type catalog lookup for sales-cycle actions (checked first
            // — their details may mention generic keywords like 'follow up')
            const newTypeKeys = {
              'quotation',
              'meeting',
              'sitevisit',
              'repaired',
              'verified',
              'call',
              'payment',
              'sample',
              'delivery',
              'collect',
              'negotiation',
              'won',
              'lost',
              'dropped',
              'cash',
            };
            final catalogDef = newTypeKeys.contains(action.type)
                ? _config.actionFor(action.type)
                : null;
            final isWarning =
                action.type == 'warning' ||
                (catalogDef == null &&
                    (lower.contains('warning') ||
                        lower.contains('escalation')));
            final isFollowup =
                catalogDef == null &&
                (action.type == 'followUp' ||
                    lower.contains('follow-up') ||
                    lower.contains('followup') ||
                    lower.contains('follow up'));
            final isQuery =
                catalogDef == null &&
                (action.type == 'query' ||
                    lower.startsWith('query') ||
                    lower.contains('status request'));

            IconData icon;
            Color iconColor;
            String label; // ignore: unused_local_variable

            if (catalogDef != null) {
              icon = catalogDef.icon;
              iconColor = catalogDef.color;
              label = catalogDef.label;
            } else if (isWarning) {
              icon = Icons.report_gmailerrorred;
              iconColor = const Color(0xFFE03131);
              label = 'Escalation';
            } else if (isQuery) {
              icon = Icons.summarize;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = (action.isReplied ?? false) ? 'Query - Replied' : 'Query';
            } else if (isFollowup) {
              icon = Icons.event_repeat;
              iconColor = (action.isFollowUpDone ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = (action.isFollowUpDone ?? false)
                  ? 'Follow-up - Done'
                  : 'Follow-up';
            } else if (action.type == 'blocker') {
              icon = Icons.block;
              iconColor = (action.isFollowUpDone ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFFC92A2A);
              label = (action.isFollowUpDone ?? false)
                  ? 'Blocker - Resolved'
                  : 'Blocker';
            } else if (action.type == 'approval') {
              icon = Icons.fact_check;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF0B7285);
              label = (action.isReplied ?? false)
                  ? 'Request - Actioned'
                  : 'Request Action';
            } else if (action.type == 'extension') {
              icon = Icons.more_time;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF3B5BDB);
              label = (action.isReplied ?? false)
                  ? 'Extension - Actioned'
                  : 'Extension Requested';
            } else if (action.type == 'progressReport') {
              icon = Icons.trending_up;
              iconColor = const Color(0xFF7048E8);
              label = 'Progress Report';
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
              typeName: action.type,
            );
            final closed =
                (action.isReplied ?? false) || (action.isFollowUpDone ?? false);
            final base = catalogDef != null
                ? catalogDef.label
                : (isWarning
                      ? 'Escalation'
                      : CardActionIcons.actionBaseLabel(
                          typeName: action.type,
                          message: action.message,
                        ));
            // Same status suffixes as the Task module's compact action rows.
            final statusWord = closed
                ? const {
                        'query': ' Replied',
                        'followUp': ' Done',
                        'extension': '',
                        'approval': ' Actioned',
                        'blocker': ' Resolved',
                      }[action.type] ??
                      ''
                : '';
            // Prefer the baked occurrence number (matches the chat card and is
            // stable under filtering); fall back to the recomputed family
            // counter for legacy rows without a seqNo.
            final number = action.seqNo ?? (actionNumbers[action] ?? 1);
            final lineText = detail.isNotEmpty
                ? '$base$statusWord $number | $detail'
                : '$base$statusWord $number';

            return InkWell(
              onTap: () {
                // Warm Firestore → SQLite so the target message is on device
                // when the chat opens (Task module fetchMessagesOnce parity)
                FirebaseService().fetchModuleMessagesOnceFor(
                  enquiry.id,
                  _config.firestoreCollection,
                );
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SalesDetailScreen(
                      enquiry: enquiry,
                      moduleConfig: _config,
                      scrollToMessageId: action.messageId.isEmpty
                          ? null
                          : action.messageId,
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // Done/replied actions keep their icon + ✓ badge
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
                      done: closed,
                    ),
                    const SizedBox(width: 8),
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
                    _expandedEnquiryCards.remove(enquiry.id);
                  } else {
                    _expandedEnquiryCards.add(enquiry.id);
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
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _themeColor,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatActionDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final actionDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
    if (actionDate == today) {
      return 'Today ${DateFormat('hh:mm a').format(dateTime)}';
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (actionDate == yesterday) {
      return 'Yesterday ${DateFormat('hh:mm a').format(dateTime)}';
    }
    final difference = today.difference(actionDate).inDays;
    if (difference < 7 && difference > 1) return '${difference}d ago';
    return DateFormat('MMM dd, hh:mm a').format(dateTime);
  }

  Color _getScheduledDateColor(DateTime scheduledDate) {
    return AppTheme.lightText;
  }

  /// Export the currently visible action items (paywall-guarded).
  void _exportActionsGuarded() {
    final planType = context.read<AuthProvider>().effectivePlanType;
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
    final items = List<_SalesActionItem>.from(_currentActionItems);
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No actions to export')));
      return;
    }

    String typeLabel(_SalesActionItem a) {
      switch (a.type) {
        case 'reminder':
          return 'Reminder';
        case 'followUp':
          return (a.isFollowUpDone ?? false) ? 'Follow-up (Done)' : 'Follow-up';
        case 'warning':
          return 'Escalation';
        case 'query':
          return (a.isReplied ?? false) ? 'Query (Replied)' : 'Query';
        default:
          return _config.actionFor(a.type)?.label ?? a.type;
      }
    }

    final headers = [
      '#',
      'Type',
      'Enquiry',
      'Client',
      'Detail',
      'Scheduled',
      'Status',
    ];
    final df = DateFormat('dd/MM/yyyy hh:mm a');
    var i = 1;
    final rows = items.map((a) {
      final status = a.type == 'query'
          ? ((a.isReplied ?? false) ? 'Replied' : 'Pending')
          : a.type == 'followUp'
          ? ((a.isFollowUpDone ?? false) ? 'Done' : 'Pending')
          : '';
      return [
        '${i++}',
        typeLabel(a),
        a.enquiryTitle,
        a.clientName,
        a.message,
        df.format(a.scheduledDate),
        status,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Sales Actions',
      filterLabel: _typeFilter == null
          ? _timeFilter
          : '$_timeFilter / ${_typeOptions.firstWhere((o) => o.value == _typeFilter).label}',
    );
  }
}

/// Lightweight action item for the Actions list.
class _SalesActionItem {
  final String enquiryId;
  final String clientName;
  final String enquiryTitle;
  final String type; // reminder, followUp, warning, query
  final String message;
  final DateTime createdAt;
  final DateTime scheduledDate;

  /// Whether [scheduledDate] is a real committed date or the write-date
  /// fallback. Overdue must never fire on an undated action aging on its
  /// creation date, so the Overdue filter gates on this. Defaults true.
  final bool hasScheduledDate;
  final bool? isReplied;
  final bool? isFollowUpDone;

  /// Id of the originating chat message (`actions.id` IS the message id) —
  /// lets rows deep-link into the conversation (Task module parity).
  final String messageId;

  /// Baked occurrence number from the message (via the actions index `seqNo`).
  /// Preferred over the recomputed family counter; null falls back to it.
  final int? seqNo;

  _SalesActionItem({
    required this.enquiryId,
    required this.clientName,
    this.enquiryTitle = '',
    required this.type,
    required this.message,
    required this.createdAt,
    required this.scheduledDate,
    this.hasScheduledDate = true,
    this.isReplied,
    this.isFollowUpDone,
    this.messageId = '',
    this.seqNo,
  });
}
