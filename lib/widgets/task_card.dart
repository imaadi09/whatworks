import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/message.dart';
import '../../models/task.dart';
import '../../providers/task_provider.dart';
import '../../services/avatar_cache_service.dart';
import '../../services/customer_comms_service.dart';
import '../../services/item_links_service.dart';
import '../../services/premium_status_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import 'card_action_icons.dart';
import 'card_widgets.dart';
import 'shared_detail_widgets.dart';
import '../modules/sales/services/milestone_settings_service.dart';

class TaskCard extends StatefulWidget {
  final TaskModel task;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool showAssigner; // true to show createdBy, false to show assignedTo
  final bool
  showAssigneeName; // true to show assignee, false to show assigner (for To Me tab)
  final String? currentUid;
  final String? currentName;
  final String? currentPhone; // Normalized phone for UID-less identity matching
  final bool isSelected; // WhatsApp-style selection mode
  // Attention mode: show PENDING (undone/unreplied) actions in the bottom
  // strip instead of the most recent ones.
  final bool pendingActions;

  const TaskCard({
    super.key,
    required this.task,
    required this.onTap,
    this.onLongPress,
    this.showAssigner = false,
    this.showAssigneeName = true, // Default to showing assignee
    this.currentUid,
    this.currentName,
    this.currentPhone,
    this.isSelected = false,
    this.pendingActions = false,
  });

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  /// Whether the customer/contact section is expanded. Cards stay compact
  /// (96px) until the person affordance is tapped; only tasks that carry
  /// customer info can expand, so every other card stays pixel-identical.
  bool _expanded = false;

  // The identity used to resolve this card's avatar and the URL it last
  // rendered. The AvatarCacheService listener re-resolves [_avatarIdentity]
  // and only rebuilds when the URL actually changes, so a contact sync does
  // not repaint the whole visible list (initials→photo fill is the only
  // change worth a frame).
  ({String? uid, String? phone, String? name})? _avatarIdentity;
  String? _lastAvatarUrl;

  @override
  void initState() {
    super.initState();
    // Repaint the moment the avatar index resolves a person this card was
    // showing as initials (cold-start load / contact sync / nickname rebuild)
    // instead of waiting for the next scroll-driven rebuild. Only the handful
    // of currently-visible cards hold this listener at once.
    AvatarCacheService().addListener(_onAvatarCacheChanged);
  }

  void _onAvatarCacheChanged() {
    if (!mounted) return;
    final id = _avatarIdentity;
    if (id == null) {
      setState(() {});
      return;
    }
    final next = AvatarCacheService().urlFor(
      uid: id.uid,
      phone: id.phone,
      name: id.name,
    );
    // Skip the rebuild when this card still resolves to the same URL — the
    // repaint only matters for the initials→photo transition or a changed
    // photo, not for every unrelated cache update.
    if (next != _lastAvatarUrl) setState(() {});
  }

  @override
  void dispose() {
    AvatarCacheService().removeListener(_onAvatarCacheChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Local aliases so the (large) build body keeps referring to the widget
    // fields verbatim after the StatelessWidget → StatefulWidget conversion.
    final task = widget.task;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final currentUid = widget.currentUid;
    final currentName = widget.currentName;
    final currentPhone = widget.currentPhone;
    final isSelected = widget.isSelected;
    final showAssigneeName = widget.showAssigneeName;
    final hasCustomer = task.customerInfo.hasAny;
    // Determine which name to show
    // createdBy and assignedTo may store UIDs or names
    // For display, try to resolve to a readable name
    final rawCreatedBy = task.createdBy.trim();
    final rawAssignedTo = task.assignedTo.trim();
    final extraFields = task.extraFields ?? const <String, dynamic>{};

    bool listContainsCurrentUid(Object? value) {
      if (currentUid == null || currentUid.isEmpty || value is! List) {
        return false;
      }
      return value.any((item) => item?.toString().trim() == currentUid);
    }

    final normalizedCurrentPhone = currentPhone?.trim() ?? '';
    bool matchesCurrentPhone(Object? value) {
      if (normalizedCurrentPhone.isEmpty) return false;
      if (value is String) return value.trim() == normalizedCurrentPhone;
      if (value is List) {
        return value.any(
          (item) => item?.toString().trim() == normalizedCurrentPhone,
        );
      }
      return false;
    }

    final isCreatedByMe =
        rawCreatedBy == currentUid ||
        rawCreatedBy == currentName ||
        extraFields['createdByUid']?.toString() == currentUid ||
        extraFields['creatorUid']?.toString() == currentUid;
    // NOTE: participantUids is NOT checked here — it includes the creator,
    // which would wrongly mark tasks I created as "assigned to me".
    final isAssignedToMe =
        rawAssignedTo == currentUid ||
        rawAssignedTo == currentName ||
        rawAssignedTo.toLowerCase() == 'me' ||
        task.assignedToUid == currentUid ||
        listContainsCurrentUid(extraFields['assigneeUids']) ||
        matchesCurrentPhone(task.assignedToPhone) ||
        matchesCurrentPhone(extraFields['assigneePhones']);

    // Get assignee name (person task is assigned to)
    // assignedTo field contains the PRIMARY/MAIN assignee name
    String assigneeName;
    int totalAssignees = 1; // Default to 1

    // Check if this is a group task with multiple assignees
    final participantNames = extraFields['participantNames'] is List
        ? List<String>.from(extraFields['participantNames'] as List)
        : <String>[if (rawAssignedTo.isNotEmpty) rawAssignedTo];
    final isGroupTask = task.isGroupTask && participantNames.length > 1;

    // Index-aligned assignee identity lists for name→UID/phone resolution
    final assigneeNamesList = extraFields['assigneeNames'] is List
        ? (extraFields['assigneeNames'] as List)
              .map((e) => e?.toString().trim() ?? '')
              .toList()
        : <String>[];
    final assigneeUidsList = extraFields['assigneeUids'] is List
        ? (extraFields['assigneeUids'] as List)
              .map((e) => e?.toString().trim() ?? '')
              .toList()
        : <String>[];
    final assigneePhonesList = extraFields['assigneePhones'] is List
        ? (extraFields['assigneePhones'] as List)
              .map((e) => e?.toString().trim() ?? '')
              .toList()
        : <String>[];

    // Legacy tasks stored UID/phone lists compressed (only resolved entries
    // appended), so index matching is only safe when the list length matches
    // assigneeNames — otherwise entries pair with the wrong name.
    final uidsAligned = assigneeUidsList.length == assigneeNamesList.length;
    final phonesAligned = assigneePhonesList.length == assigneeNamesList.length;

    // True only when the named assignee is the current user (UID or phone
    // aligned by index, or direct name/UID string match). A non-empty aligned
    // identity at the name's slot is definitive — legacy corruption can leave
    // another assignee's UID/phone in the primary fields.
    bool isPersonMe(String name) {
      if (name.isEmpty) return false;
      if (name == currentUid || name == currentName) return true;
      final idx = assigneeNamesList.indexOf(name);
      if (idx >= 0) {
        final alignedUid = uidsAligned ? assigneeUidsList[idx] : '';
        if (alignedUid.isNotEmpty &&
            currentUid != null &&
            currentUid.isNotEmpty) {
          return alignedUid == currentUid;
        }
        final alignedPhone = phonesAligned ? assigneePhonesList[idx] : '';
        if (alignedPhone.isNotEmpty && normalizedCurrentPhone.isNotEmpty) {
          return alignedPhone == normalizedCurrentPhone;
        }
      }
      return false;
    }

    if (isGroupTask) {
      totalAssignees = participantNames.length;
      final mainAssignee = participantNames.first.trim();
      if (isPersonMe(mainAssignee)) {
        assigneeName = 'Me';
      } else if (mainAssignee.isNotEmpty &&
          mainAssignee.toLowerCase() != 'user') {
        assigneeName = mainAssignee;
      } else if (rawAssignedTo.isNotEmpty &&
          rawAssignedTo.toLowerCase() != 'user') {
        assigneeName = isAssignedToMe ? 'Me' : rawAssignedTo;
      } else {
        assigneeName = isAssignedToMe ? 'Me' : 'Someone';
      }
    } else {
      // For single-assignee tasks, show normally
      if (isAssignedToMe) {
        assigneeName = 'Me';
      } else if (rawAssignedTo.isNotEmpty &&
          rawAssignedTo != 'Someone' &&
          rawAssignedTo.toLowerCase() != 'user') {
        assigneeName = rawAssignedTo;
      } else {
        assigneeName = 'Someone';
      }
    }

    // Get assigner name (person who created the task)
    String assignerName;
    if (isCreatedByMe) {
      assignerName = 'Me';
    } else if (task.createdByName?.trim().isNotEmpty == true &&
        task.createdByName!.trim().toLowerCase() != 'user') {
      assignerName = task.createdByName!.trim();
    } else if (!_looksLikeUid(rawCreatedBy) && rawCreatedBy.isNotEmpty) {
      assignerName = rawCreatedBy;
    } else {
      assignerName = 'Someone';
    }

    // Show main assignee name with count badge if multiple assignees
    // For To Me tab (showAssigneeName=false), show assigner name instead
    final nameToShow = showAssigneeName ? assigneeName : assignerName;

    // Premium/Basic differentiation: crown when the shown person is premium
    // (lookup refreshed on every contact sync)
    final shownPersonPremium = showAssigneeName
        ? PremiumStatusService().isPremium(
            uid: task.assignedToUid,
            phone: task.assignedToPhone,
          )
        : PremiumStatusService().isPremium(
            uid: task.createdBy,
            phone: task.createdByPhone,
          );

    final displayName = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            nameToShow,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 12,
              color: AppTheme.primaryTextOn(context),
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (shownPersonPremium) const PremiumBadge(),
        // Show count badge with person icon if multiple assignees (only when showing assignee)
        if (showAssigneeName && totalAssignees > 1) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.primaryGreen.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person, size: 9, color: AppTheme.primaryGreen),
                const SizedBox(width: 2),
                Text(
                  '$totalAssignees',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 9,
                    color: AppTheme.primaryGreen,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );

    final displayInitials = Helpers.getInitials(nameToShow);

    // The card always represents the LEADER (first/main) assignee, so the
    // avatar must resolve THAT person. Collect every identity we know for the
    // leader and take the first the avatar cache recognises:
    //   1. the primary assignedToUid/Phone (set to the leader on save),
    //   2. the index-aligned leader slot in assigneeUids/assigneePhones
    //      (guards against legacy corruption where the primary holds another
    //      assignee's identity — the leader is assigneeNames index 0).
    // urlFor(name:) also consults a phonebook-nickname index built off the UI
    // path, so a legacy group task stored under a local nickname like "Sonu"
    // still finds the profile photo without scanning contacts during build.
    String? shownAvatarUrl;
    if (nameToShow == 'Me') {
      _avatarIdentity = (
        uid: currentUid,
        phone: currentPhone,
        name: currentName,
      );
      shownAvatarUrl = AvatarCacheService().urlFor(
        uid: currentUid,
        phone: currentPhone,
        name: currentName,
      );
    } else if (showAssigneeName) {
      _avatarIdentity = (
        uid: task.assignedToUid,
        phone: task.assignedToPhone,
        name: nameToShow,
      );
      final leaderIdx = assigneeNamesList.indexOf(nameToShow);
      final slot = leaderIdx >= 0 ? leaderIdx : 0;
      String? uidAt(int i) =>
          uidsAligned && i < assigneeUidsList.length && assigneeUidsList[i].isNotEmpty
          ? assigneeUidsList[i]
          : null;
      String? phoneAt(int i) =>
          phonesAligned &&
              i < assigneePhonesList.length &&
              assigneePhonesList[i].isNotEmpty
          ? assigneePhonesList[i]
          : null;
      final identities = <({String? uid, String? phone})>[
        (uid: task.assignedToUid, phone: task.assignedToPhone),
        (uid: uidAt(slot), phone: phoneAt(slot)),
      ];
      for (final id in identities) {
        shownAvatarUrl = AvatarCacheService().urlFor(
          uid: id.uid,
          phone: id.phone,
          name: nameToShow,
        );
        if (shownAvatarUrl != null) break;
      }
    } else {
      _avatarIdentity = (
        uid: task.createdBy,
        phone: task.createdByPhone,
        name: nameToShow,
      );
      shownAvatarUrl = AvatarCacheService().urlFor(
        uid: task.createdBy,
        phone: task.createdByPhone,
        name: nameToShow,
      );
    }

    // Remember what this card rendered so the listener above can decide
    // whether a later cache change actually alters this card (see initState).
    _lastAvatarUrl = shownAvatarUrl;

    // Determine arrow direction based on task flow
    // Outward arrow (call_made) = I created this task and assigned it to someone
    // Inward arrow (call_received) = Someone created and assigned this task to me
    // Inward arrow also when I created task AND assigned it to myself
    final directionIcon = (isCreatedByMe && !isAssignedToMe)
        ? Icons
              .call_made // Outward: I created, assigned to others only
        : Icons
              .call_received; // Inward: Assigned to me (regardless of who created)

    // Arrow circle color based on task status
    final directionColor = _getStatusColor(task);

    // Milestone counts — default templates applied at creation become
    // visible on the card (same chip style as Sales cards), but only while
    // milestones are enabled in Tools → Milestone Settings.
    final completedMilestones = task.completedMilestoneCount;
    final totalMilestones = task.milestones.length;
    final showMilestoneChip =
        totalMilestones > 0 &&
        MilestoneSettingsService.isEnabledSync('task');

    // Line-2 state tiles, hoisted so line 1 can reserve a strip at least as
    // wide as the one they render (user rule: the tile strip must never
    // outdent the line-1 chip on the left).
    final urgencyState = CardFlagTile.stateFor(
      isUrgent: task.isUrgent,
      isBlocked: task.extraFields?['isBlocked'] == true,
      urgencyState: task.extraFields?['urgencyState'] as String?,
    );
    final hasLinks = ItemLinksService().linksOf(extraFields).isNotEmpty;
    final tilesStrip = CardStateTiles.stripWidth(
      urgency: urgencyState != 'none',
      links: hasLinks,
      milestone: showMilestoneChip,
    );

    final isDeletedTask = task.isDeleted;

    return RepaintBoundary(
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onLongPress,
            child: InkWell(
              onTap: onTap,
              child: Opacity(
                opacity: isDeletedTask ? 0.5 : 1.0,
                child: Container(
                  height: _expanded ? null : 96,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: isDeletedTask
                        ? Theme.of(context).dividerColor
                        : isSelected
                        ? AppTheme.accent.withOpacity(0.10)
                        : Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 0,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 96,
                    child: Row(
                      children: [
                        // Avatar (WhatsApp style) with direction badge — shared
                        CardAvatarBadge(
                          initials: displayInitials,
                          avatarColor: AppTheme.primaryGreen,
                          badgeColor: directionColor,
                          badgeIcon: directionIcon,
                          avatarUrl: shownAvatarUrl,
                        ),
                        const SizedBox(width: 12),

                        // Content - Clean layout
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Line 1: Main assignee name + draft badge
                              Row(
                                children: [
                                  Expanded(child: displayName),
                                  // Draft badge
                                  if (extraFields['isDraft'] == true) ...[
                                    const SizedBox(width: 4),
                                    const DraftChip(),
                                  ],
                                  const SizedBox(width: 6),
                                  CardChipsRow(
                                    chips: _buildActionIcon(
                                      context,
                                      task.id,
                                      task.lastMessageText,
                                    ),
                                    // The pill fills a strip at least as wide
                                    // as the line-2 tile group below, so that
                                    // group can never outdent it on the left
                                    // (user rule); 68 fits the longest dated
                                    // label ("Deliv on 28").
                                    width: tilesStrip > 68 ? tilesStrip : 68,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),

                              // Line 2: title, with the right-
                              // aligned state tiles (milestone / urgency flag /
                              // links) moved up from line 3 so the last-message
                              // line owns the full width. No #number here —
                              // user rule: the task card doesn't show it.
                              Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            _buildSubtitle(),
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
                                  if (isDeletedTask) ...[
                                    Icon(
                                      Icons.delete_outline,
                                      size: 10,
                                      color: Colors.grey,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        task.deletedAt != null
                                            ? 'Deleted ${Helpers.getRelativeTime(task.deletedAt!)}'
                                            : 'Deleted',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.lightText,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Restore button for deleted tasks
                                    GestureDetector(
                                      onTap: () {
                                        final taskProvider = context
                                            .read<TaskProvider>();
                                        taskProvider.restoreTask(task.id);
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Task restored'),
                                            backgroundColor:
                                                AppTheme.primaryGreen,
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primaryGreen
                                              .withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.restore,
                                              size: 10,
                                              color: AppTheme.primaryGreen,
                                            ),
                                            SizedBox(width: 2),
                                            Text(
                                              'Restore',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: AppTheme.primaryGreen,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ] else ...[
                                    // Last message preview · relative time
                                    // (replaces the old timestamp + display-
                                    // number meta line — the ID moved up to
                                    // the title row). The preview leads with
                                    // the action name then its details
                                    // ("<Action>: <details>", consistent across
                                    // actions via Helpers.cardPreviewText) and
                                    // the text is EXPANDED so the time
                                    // pins to the far right of the line no
                                    // matter the message length. The unread
                                    // pill stays flush right beside it.
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              Helpers.cardPreviewText(
                                                task.lastMessageText,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 12,
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
                                                horizontal: 6,
                                              ),
                                              child: Text(
                                                '·',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: AppTheme.secondaryText,
                                                ),
                                              ),
                                            ),
                                          Text(
                                            Helpers.getRelativeTime(
                                              task.lastMessageTime ??
                                                  task.updatedAt,
                                            ),
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.secondaryText,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // Pending-read count in the Task module
                                    // green, flush right
                                    CardUnreadPill(
                                      count: _getUnreadCount(),
                                      color: AppTheme.primaryGreen,
                                    ),
                                  ],
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

                        // Vertical progress bar (right side) - dashed, right-aligned,
                        // hidden for deleted tasks. The unread pill rides the
                        // timestamp line, so the bar is never covered and the
                        // action icons keep their flush-right slot
                        if (!isDeletedTask) ...[
                          CardProgressStack(
                            progress: task.progress,
                            isClosed: task.isClosed || task.isCancelled,
                            createdAt: task.createdAt,
                            deadline: task.deadline,
                          ),
                        ],
                      ],
                    ),
                        ),
                        if (_expanded && hasCustomer)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 10),
                            child: _buildCustomerSection(task),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildSubtitle() {
    if (widget.task.description.isNotEmpty) {
      final desc = widget.task.description.length > 50
          ? '${widget.task.description.substring(0, 50)}...'
          : widget.task.description;
      return '${widget.task.title} - $desc';
    }
    return widget.task.title;
  }

  /// Get unread message count for current user from task's unreadCounts map.
  int _getUnreadCount() {
    if (widget.currentUid == null || widget.currentUid!.isEmpty) return 0;
    return widget.task.unreadCounts[widget.currentUid!] ?? 0;
  }

  /// Returns true if [s] looks like a Firebase UID (20+ chars, no spaces, alphanumeric)
  bool _looksLikeUid(String s) => Helpers.looksLikeUid(s);

  /// Get color based on task status (shared — cardStatusColor)
  Color _getStatusColor(TaskModel task) => cardStatusColor(
    isCancelled: task.isCancelled,
    isClosed: task.isClosed,
    extraFields: task.extraFields,
  );

  /// Build action icons widget for Line 3 — acronym chips for the last
  /// actions, or pending-only chips in attention mode.
  /// Full pipeline lives in CardActionIcons.taskChips (shared with the
  /// home-screen assignee card).
  List<Widget> _buildActionIcon(
    BuildContext context,
    String taskId,
    String? messageText,
  ) => CardActionIcons.taskChips(
    context,
    taskId,
    messageText,
    baseColor: AppTheme.primaryGreen,
    pendingOnly: widget.pendingActions,
    // Fill the reserved strip: the pill's left edge then IS the strip's left
    // edge, and the line-2 tiles below can never outdent it.
    fill: true,
  );

  /// Expanded customer/contact panel — read-only details plus Call / WhatsApp /
  /// Copy / Save actions wired through [CustomerCommsService]. Recording flows
  /// through [TaskProvider.sendMessage] so the timeline, card chips and the
  /// Actions log all update exactly as they do from the detail screen.
  Widget _buildCustomerSection(TaskModel task) {
    final info = task.customerInfo;
    final provider = context.read<TaskProvider>();
    final byName = widget.currentName?.trim().isNotEmpty == true
        ? widget.currentName!.trim()
        : 'User';
    Future<void> record(String text) => provider.sendMessage(
      task.id,
      MessageModel(
        id: Helpers.generateId(),
        taskId: task.id,
        senderId: widget.currentUid ?? '',
        text: text,
        type: MessageType.system,
        createdAt: DateTime.now(),
        deliveryMethod: 'in-app',
      ),
    );
    return CustomerCardSection(
      info: info,
      expanded: true,
      onToggleExpand: () => setState(() => _expanded = false),
      onCall: () => CustomerCommsService.instance.call(
        context,
        info,
        record: record,
        byName: byName,
      ),
      onWhatsApp: () => CustomerCommsService.instance.whatsapp(
        context,
        info,
        record: record,
        byName: byName,
      ),
      onCopy: () => CustomerCommsService.instance.copyNumber(context, info),
      onSave: () => CustomerCommsService.instance.saveToContacts(context, info),
    );
  }
}
