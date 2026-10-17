import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/message.dart';
import '../models/enquiry.dart';
import '../providers/sales_provider.dart';
import '../../../services/avatar_cache_service.dart';
import '../../../services/customer_comms_service.dart';
import '../../../services/item_links_service.dart';
import '../../../services/premium_status_service.dart';
import '../../../utils/constants.dart';
import '../../../utils/helpers.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../services/milestone_settings_service.dart';
import '../../crm/providers/crm_provider.dart';
import '../../../widgets/card_action_icons.dart';
import '../../../widgets/card_widgets.dart';
import '../../../widgets/shared_detail_widgets.dart';

/// Card widget for a sales enquiry — styled exactly like TaskCard.
class SalesCard extends StatefulWidget {
  final EnquiryModel enquiry;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showAssigner; // true = show createdBy, false = show assignedTo
  final bool
  showAssigneeName; // true to show assignee, false to show assigner (for To Me tab)
  final String? currentUid;
  final String? currentName;
  final String? currentPhone; // Normalized phone for UID-less identity matching
  final bool isSelected; // WhatsApp-style selection mode
  final ModuleConfig? moduleConfig;
  // Attention mode: chips show only pending (undone/unreplied) actions.
  final bool pendingActions;

  const SalesCard({
    super.key,
    required this.enquiry,
    this.onTap,
    this.onLongPress,
    this.showAssigner = false,
    this.showAssigneeName = true,
    this.currentUid,
    this.currentName,
    this.currentPhone,
    this.isSelected = false,
    this.moduleConfig,
    this.pendingActions = false,
  });

  @override
  State<SalesCard> createState() => _SalesCardState();
}

class _SalesCardState extends State<SalesCard> {
  /// Whether the customer/contact section is expanded. Cards stay compact
  /// (96px) until the person affordance is tapped; only enquiries that carry
  /// customer info can expand, so every other card stays pixel-identical.
  bool _expanded = false;

  // The identity used to resolve this card's avatar and the URL it last
  // rendered. The AvatarCacheService listener re-resolves [_avatarIdentity]
  // and only rebuilds when the URL actually changes, so a contact sync does
  // not repaint the whole visible list (initials→photo fill is the only
  // change worth a frame). Sales + CRM share this card, so both are covered.
  ({String? uid, String? phone, String? name})? _avatarIdentity;
  String? _lastAvatarUrl;

  @override
  void initState() {
    super.initState();
    // Repaint the moment the avatar index resolves a person this card was
    // showing as initials (cold-start load / contact sync / nickname rebuild)
    // instead of waiting for the next scroll-driven rebuild. Sales + CRM share
    // this card, so both get the instant fill.
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

  ModuleConfig get _config => widget.moduleConfig ?? ModuleConfig.sales;
  Color get _themeColor => _config.themeColor;

  @override
  Widget build(BuildContext context) {
    // Local aliases so the (large) build body keeps referring to the widget
    // fields verbatim after the StatelessWidget → StatefulWidget conversion.
    final enquiry = widget.enquiry;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final currentUid = widget.currentUid;
    final currentName = widget.currentName;
    final currentPhone = widget.currentPhone;
    final isSelected = widget.isSelected;
    final showAssigneeName = widget.showAssigneeName;
    final hasCustomer = enquiry.customerInfo.hasAny;
    final extraFields = enquiry.extraFields ?? const <String, dynamic>{};
    // Blocked overrides the pipeline status color while a blocker is open.
    final statusColor = extraFields['isBlocked'] == true
        ? const Color(0xFF862E9C)
        : _config.statusColorFor(enquiry.status);

    // Resolve display name (same logic as TaskCard)
    final isCreatedByMe =
        enquiry.createdBy == currentUid ||
        (enquiry.createdByName?.trim() == currentName);
    final isAssignedToMe =
        enquiry.assignedToUid == currentUid ||
        enquiry.assignedTo == currentName ||
        enquiry.assignedTo.toLowerCase() == 'me' ||
        enquiry.assigneeUids.contains(currentUid);

    // Index-aligned assignee identity lists (RAW, not the empties-filtered
    // EnquiryModel getters) so the LEADER's avatar/name can be resolved by
    // name→slot even when a legacy group compressed its UID/phone lists.
    // Mirrors TaskCard.
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
    final uidsAligned = assigneeUidsList.length == assigneeNamesList.length;
    final phonesAligned =
        assigneePhonesList.length == assigneeNamesList.length;
    // Real (non-blank) names drive the leader + count badge.
    final resolvedAssigneeNames = assigneeNamesList
        .where((n) => n.isNotEmpty)
        .toList();
    // Leader = first real assignee name, falling back to the stored primary.
    final leaderName = resolvedAssigneeNames.isNotEmpty
        ? resolvedAssigneeNames.first
        : enquiry.assignedTo;
    final totalAssignees = resolvedAssigneeNames.isNotEmpty
        ? resolvedAssigneeNames.length
        : enquiry.assigneeUids.length;
    final isGroup = totalAssignees > 1;

    // True when the named person is the current user, trusting the index-
    // aligned identity at their slot first (legacy corruption can leave
    // another assignee's UID/phone in the primary fields).
    bool isPersonMe(String name) {
      if (name.isEmpty) return false;
      if (name == currentUid || name == currentName) return true;
      if (name.toLowerCase() == 'me') return true;
      final idx = assigneeNamesList.indexOf(name);
      if (idx >= 0) {
        final alignedUid =
            uidsAligned && idx < assigneeUidsList.length
                ? assigneeUidsList[idx]
                : '';
        if (alignedUid.isNotEmpty &&
            currentUid != null &&
            alignedUid == currentUid) {
          return true;
        }
        final alignedPhone =
            phonesAligned && idx < assigneePhonesList.length
                ? assigneePhonesList[idx]
                : '';
        if (alignedPhone.isNotEmpty &&
            currentPhone != null &&
            alignedPhone == currentPhone) {
          return true;
        }
      }
      return false;
    }

    String assigneeName;
    if (isGroup) {
      // Multi-assignee: show ONLY the LEADER's name (Task parity) — the total
      // rides in a count badge beside it, not the old "First +N others" label.
      if (isPersonMe(leaderName)) {
        assigneeName = 'Me';
      } else if (leaderName.isNotEmpty && leaderName.toLowerCase() != 'user') {
        assigneeName = leaderName;
      } else if (isAssignedToMe) {
        assigneeName = 'Me';
      } else {
        assigneeName = 'Someone';
      }
    } else if (isAssignedToMe) {
      assigneeName = 'Me';
    } else if (enquiry.assignedTo.isNotEmpty &&
        enquiry.assignedTo != 'Someone' &&
        enquiry.assignedTo.toLowerCase() != 'user') {
      assigneeName = enquiry.assignedTo;
    } else {
      // Unassigned shows "Unassigned", NOT the customer name — the customer
      // already reads on line 2, so the assignee slot must say the deal has no
      // owner yet (parity with the Task card / AppBar assignee fallback).
      assigneeName = 'Unassigned';
    }

    String assignerName;
    if (isCreatedByMe) {
      assignerName = 'Me';
    } else if (enquiry.createdByName?.trim().isNotEmpty == true &&
        enquiry.createdByName!.trim().toLowerCase() != 'user') {
      assignerName = enquiry.createdByName!.trim();
    } else {
      assignerName = 'Someone';
    }

    // Show main assignee name (for To Me tab, show assigner name instead)
    final nameToShow = showAssigneeName ? assigneeName : assignerName;

    // Premium/Basic differentiation: crown when the shown person is premium
    // (lookup refreshed on every contact sync)
    final shownPersonPremium = showAssigneeName
        ? PremiumStatusService().isPremium(
            uid: enquiry.assignedToUid,
            phone: enquiry.assignedToPhone,
          )
        : PremiumStatusService().isPremium(
            uid: enquiry.createdBy,
            phone: enquiry.createdByPhone,
          );

    final displayInitials = Helpers.getInitials(nameToShow);

    // Avatar of the shown person (photo or preset) — synchronous lookup
    // from the same identity the premium crown uses; own avatar for 'Me'.
    // Phone is part of the 'Me' chain (TaskCard parity): the cache can key
    // the own user by phone when the UID misses, and name alone is not
    // enough — without it the Me card fell back to initials in sales/CRM.
    // The card always represents the LEADER assignee, so the avatar must
    // resolve THAT person — never a later assignee. Try every identity we
    // know for the leader and take the first the avatar cache recognises:
    //   1. the primary assignedToUid/Phone (set to the leader on save),
    //   2. the index-aligned leader slot in assigneeUids/assigneePhones,
    //   3. a contact-book lookup (nickname → phone/UID) for legacy groups
    //      whose stored lists are blank or compressed.
    // Mirrors TaskCard; fixes the multi-assignee card showing initials or the
    // wrong person's photo instead of the leader's.
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
      final resolveName = isGroup ? leaderName : nameToShow;
      _avatarIdentity = (
        uid: enquiry.assignedToUid,
        phone: enquiry.assignedToPhone,
        name: resolveName,
      );
      final leaderIdx = assigneeNamesList.indexOf(resolveName);
      final slot = leaderIdx >= 0 ? leaderIdx : 0;
      String? uidAt(int i) =>
          uidsAligned &&
                  i < assigneeUidsList.length &&
                  assigneeUidsList[i].isNotEmpty
          ? assigneeUidsList[i]
          : null;
      String? phoneAt(int i) =>
          phonesAligned &&
                  i < assigneePhonesList.length &&
                  assigneePhonesList[i].isNotEmpty
          ? assigneePhonesList[i]
          : null;
      final identities = <({String? uid, String? phone})>[
        (uid: enquiry.assignedToUid, phone: enquiry.assignedToPhone),
        (uid: uidAt(slot), phone: phoneAt(slot)),
      ];
      for (final id in identities) {
        shownAvatarUrl = AvatarCacheService().urlFor(
          uid: id.uid,
          phone: id.phone,
          name: resolveName,
        );
        if (shownAvatarUrl != null) break;
      }
    } else {
      _avatarIdentity = (
        uid: enquiry.createdBy,
        phone: enquiry.createdByPhone,
        name: nameToShow,
      );
      shownAvatarUrl = AvatarCacheService().urlFor(
        uid: enquiry.createdBy,
        phone: enquiry.createdByPhone,
        name: nameToShow,
      );
    }

    // Remember what this card rendered so the listener above can decide
    // whether a later cache change actually alters this card (see initState).
    _lastAvatarUrl = shownAvatarUrl;

    // Direction icon: outward if I created & assigned to others
    final directionIcon = (isCreatedByMe && !isAssignedToMe)
        ? Icons.call_made
        : Icons.call_received;

    // (Deadline chip removed from the card — timing shows on the progress bar.)

    // Milestone count — chip renders only while milestones are enabled for
    // this module in Tools → Milestone Settings.
    final completedMilestones = enquiry.completedMilestoneCount;
    final totalMilestones = enquiry.milestones.length;
    final showMilestoneChip =
        totalMilestones > 0 &&
        MilestoneSettingsService.isEnabledSync(_config.sequentialIdKey);

    // Line-2 state tiles, hoisted so line 1 can reserve a strip at least as
    // wide as the one they render (user rule: the tile strip must never
    // outdent the line-1 chip on the left).
    final urgencyState = CardFlagTile.stateFor(
      isUrgent: enquiry.isUrgent,
      isBlocked: extraFields['isBlocked'] == true,
      urgencyState: extraFields['urgencyState'] as String?,
    );
    final hasLinks = ItemLinksService().linksOf(extraFields).isNotEmpty;
    final tilesStrip = CardStateTiles.stripWidth(
      urgency: urgencyState != 'none',
      links: hasLinks,
      milestone: showMilestoneChip,
    );

    final bool isDraft =
        extraFields['isDraft'] == true && enquiry.title.isEmpty;

    return RepaintBoundary(
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onLongPress,
            child: InkWell(
              onTap: onTap,
              child: Container(
                // Collapsed height — 4-line layout (one line taller than
                // TaskCard): customer name gets its own line 3, #id + time
                // move to line 4. Expands (height: null) to reveal the
                // customer section; only enquiries with customer info can.
                height: _expanded ? null : 96,
                margin: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: isSelected
                      ? _themeColor.withOpacity(0.10)
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
                      // Avatar with direction badge — shared (status color
                      // tints both the circle and the badge in sales)
                      CardAvatarBadge(
                        initials: displayInitials,
                        avatarColor: statusColor,
                        badgeColor: statusColor,
                        // Group is conveyed by the line-1 count badge (Task
                        // parity); the avatar badge stays the direction arrow.
                        badgeIcon: directionIcon,
                        avatarUrl: shownAvatarUrl,
                      ),
                      const SizedBox(width: 12),

                      // Content — 3 lines (same structure as TaskCard)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Line 1: Name + Draft badge + deadline days
                            Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          nameToShow,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w500,
                                            fontSize: 12,
                                            color: AppTheme.primaryTextOn(
                                              context,
                                            ),
                                            height: 1.2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      // Multi-assignee count badge (Task
                                      // parity): leader name + total people.
                                      if (showAssigneeName &&
                                          totalAssignees > 1) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 4,
                                                vertical: 2,
                                              ),
                                          decoration: BoxDecoration(
                                            color: _themeColor.withOpacity(
                                              0.15,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: _themeColor.withOpacity(
                                                0.3,
                                              ),
                                              width: 1,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.person,
                                                size: 9,
                                                color: _themeColor,
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                '$totalAssignees',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 9,
                                                  color: _themeColor,
                                                  height: 1.0,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                // Premium crown in a reserved slot so the
                                // line-1 chips keep the same x-position on
                                // every card.
                                SizedBox(
                                  width: 18,
                                  child: shownPersonPremium
                                      ? const PremiumBadge()
                                      : null,
                                ),
                                // Draft badge
                                if (isDraft) ...[
                                  const SizedBox(width: 4),
                                  const DraftChip(),
                                ],
                                const SizedBox(width: 6),
                                CardChipsRow(
                                  chips: _buildActionIcon(
                                    context,
                                    enquiry.id,
                                    enquiry.lastMessageText,
                                  ),
                                  // The pill fills a strip at least as wide as
                                  // the line-2 tile group below, so that group
                                  // can never outdent it on the left (user
                                  // rule); 68 fits the longest dated label
                                  // ("Deliv on 28").
                                  width: tilesStrip > 68 ? tilesStrip : 68,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),

                            // Line 2: title | state tiles (Task-card parity).
                            // The ticket #id left this line — it now rides
                            // line 3's right end (user rule: fixed under the
                            // chips, matching the tiles' flush-right edge), so
                            // the title owns the full remaining width here.
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _buildSubtitle(),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.primaryTextOn(context),
                                      height: 1.2,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                // State tiles (M# / urgency flag / link) moved up
                                // to line 2 (Task / home-card parity) so the
                                // customer line reads full width.
                                CardStateTiles(
                                  urgencyState: urgencyState,
                                  hasLinks: hasLinks,
                                  accentColor: _themeColor,
                                  milestoneLabel: showMilestoneChip
                                      // Completed count only ("M0", "M5") —
                                      // Task-card parity; the total is noise on
                                      // a list card.
                                      ? 'M$completedMilestones'
                                      : null,
                                  // Fixed-width flush-right slot: the line-3 #id
                                  // chip shares this exact box, so the two stack
                                  // on identical edges.
                                  trailingSlotWidth: cardTrailingSlotWidth,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),

                            // Line 3: customer name + rating take the flexible
                            // part; the ticket #id rides a FIXED trailing slot
                            // (see below) so it holds the same x on every card
                            // whatever the customer name length.
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 16,
                                    child: Row(
                                children: [
                                  if (enquiry.clientName.isNotEmpty) ...[
                                    Icon(
                                      Icons.person_outline,
                                      size: 12,
                                      color: _themeColor.withOpacity(0.7),
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        enquiry.clientName,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: _themeColor.withOpacity(0.8),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                  if (enquiry.rating != null &&
                                      enquiry.rating! > 0) ...[
                                    if (enquiry.clientName.isNotEmpty)
                                      const SizedBox(width: 6),
                                    ...List.generate(
                                      enquiry.rating!,
                                      (i) => Icon(
                                        Icons.star,
                                        size: 10,
                                        color: const Color(0xFFF59F00),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                                ),
                                // Ticket number in the shared fixed-width
                                // trailing slot (same box as the line-2
                                // milestone chip), as a DIRECT trailing child of
                                // this bounded Row so its LEFT edge — not just
                                // its right one — is identical on every card
                                // whatever the customer name, rating or tile
                                // count. It must not sit behind a Spacer inside
                                // the name row: the name is Flexible (flex 1) and
                                // a Spacer is flex 1 too, so the free space
                                // splits 50/50 and the unused half lands AFTER
                                // the chip — that drifted #id left on every card
                                // whose name was shorter than half the row.
                                if (enquiry.displayId != null)
                                  SizedBox(
                                    width: cardTrailingSlotWidth,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: CardMetaChip(
                                        label: '#${enquiry.displayId}',
                                        color: AppTheme.secondaryText,
                                        textColor: AppTheme.secondaryText,
                                        // Equal-width digits so #1017 and #1000
                                        // draw to the same width inside the
                                        // slot.
                                        tabularFigures: true,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),

                            // Line 4: last message preview · relative time, with
                            // the unread bubble flush right (Task-card parity).
                            // The preview leads with "<Action>: <details>"
                            // via the shared Helpers.cardPreviewText (identical
                            // rule across modules) and the text is EXPANDED so
                            // the time pins to the far right of the line.
                            Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          Helpers.cardPreviewText(
                                            enquiry.lastMessageText,
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
                                        enquiry.lastMessageText,
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
                                          enquiry.lastMessageTime ??
                                              enquiry.updatedAt,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.secondaryText,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(width: 6),
                                      // Pending-read count bubble, flush right,
                                      // in the module color (Sales blue /
                                      // CRM mint)
                                      CardUnreadPill(
                                        count: _unreadCount,
                                        color: _themeColor,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),

                      // Vertical progress bar — dashed, right-aligned, same as
                      // TaskCard. The unread pill rides the timestamp line, so
                      // the bar is never covered and the action icons keep
                      // their flush-right slot. Fill color is the shared
                      // deadline timing rule (card_widgets deadlineColorFor).
                      CardProgressStack(
                        progress: enquiry.progress.clamp(0.0, 1.0),
                        isClosed:
                            enquiry.isClosed ||
                            !_config.isOpenStatus(enquiry.status),
                        createdAt: enquiry.createdAt,
                        deadline: enquiry.deadline,
                        height: 76,
                        // Each module paints its own brand color: Sales blue
                        // (#1971C2), CRM mint/teal (#0C8599). Only the calm
                        // on-track green is overridden — amber/red lateness and
                        // the closed-green stay intact (see CardProgressStack).
                        progressColor: _themeColor,
                      ),
                    ],
                  ),
                      ),
                      if (_expanded && hasCustomer)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, bottom: 10),
                          child: _buildCustomerSection(enquiry),
                        ),
                    ],
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
    final enquiry = widget.enquiry;
    if (enquiry.description.isNotEmpty) {
      final desc = enquiry.description.length > 50
          ? '${enquiry.description.substring(0, 50)}...'
          : enquiry.description;
      return '${enquiry.title} - $desc';
    }
    return enquiry.title.isNotEmpty ? enquiry.title : 'New Enquiry';
  }

  int get _unreadCount {
    final currentUid = widget.currentUid;
    if (currentUid == null || currentUid.isEmpty) return 0;
    return widget.enquiry.unreadCounts[currentUid] ?? 0;
  }

  /// Build action icons widget for Line 3 — shows last 3 action icons.
  /// Mapping/fallback/chip rendering live in CardActionIcons (shared with
  /// TaskCard); module-specific types resolve through ModuleConfig.
  List<Widget> _buildActionIcon(
    BuildContext context,
    String enquiryId,
    String? messageText,
  ) {
    // Try action icons cache first (from actions table — O(3) query)
    List<Map<String, dynamic>> actions = [];
    try {
      final salesProvider = _config.type == ModuleType.crm
          ? Provider.of<CrmProvider>(context, listen: false)
          : Provider.of<SalesProvider>(context, listen: false)
                as BaseModuleProvider;
      final cachedIcons = salesProvider.getActionIcons(enquiryId);
      if (cachedIcons != null && cachedIcons.isNotEmpty) {
        actions = CardActionIcons.fromCachedIcons(
          cachedIcons,
          resolve: (actionType, isReplied, isDone) {
            // Replied queries render as done; card uses the alarm glyph
            // for reminders (denser than bell) — both come from the shared
            // core mapping. Blocker is raised via the separate Raise Blocker
            // tile and is NOT a module config action, so it (and any other
            // type absent from the config: extension, progress) must also
            // resolve through core or its chip is silently skipped.
            if (actionType == 'query' ||
                actionType == 'reminder' ||
                actionType == 'blocker') {
              return CardActionIcons.visualFor(
                actionType,
                isReplied: isReplied,
                isDone: isDone,
              );
            }
            final def = _config.actionFor(actionType);
            if (def == null) {
              return CardActionIcons.visualFor(
                actionType,
                isReplied: isReplied,
                isDone: isDone,
              );
            }
            return {'icon': def.icon, 'color': def.color};
          },
          // Date-carrying actions show the day number below the icon
          hasDay: (actionType) =>
              actionType == 'followup' ||
              (_config.actionFor(actionType)?.hasDatePicker ?? false),
        );
      }
    } catch (_) {}

    // Fallback: scan cached messages if no action icons in cache
    if (actions.isEmpty) {
      try {
        final salesProvider = _config.type == ModuleType.crm
            ? Provider.of<CrmProvider>(context, listen: false)
            : Provider.of<SalesProvider>(context, listen: false)
                  as BaseModuleProvider;
        final messages = salesProvider.getCachedMessages(enquiryId);
        if (messages != null && messages.isNotEmpty) {
          actions = CardActionIcons.fromCachedMessages(messages);
        }
      } catch (_) {
        final action = Helpers.detectLastAction(messageText);
        if (action != null) actions.add(action);
      }
    }

    // Attention mode: keep only actions that still need a response or
    // closure — informational actions are hidden (Task-module parity).
    if (widget.pendingActions) {
      actions.removeWhere((a) {
        final type = a['type'] as String?;
        if (type == null || !CardActionIcons.closureTypes.contains(type)) {
          return true;
        }
        if (a['done'] == true || a['isDone'] == true) return true;
        // A reply closes queries/requests/extensions; follow-ups, blockers
        // and calls stay open until marked done — same rule the pending
        // counts use, so chips and numbers can never disagree.
        if (type == 'followup' || type == 'blocker' || type == 'call') {
          return false;
        }
        return a['isReplied'] == true;
      });
    }

    return CardActionIcons.renderChips(
      actions,
      baseColor: _themeColor,
      pendingMode: widget.pendingActions,
      // Fill the reserved strip: the pill's left edge then IS the strip's
      // left edge, and the line-2 tiles below can never outdent it.
      fill: true,
      // Show only the most recent action as a single numbered pill
      // ("Qry 1") — matches the redesigned TaskCard line 1.
      maxChips: 1,
    );
  }

  /// Expanded customer/contact panel — read-only details plus Call / WhatsApp /
  /// Copy / Save actions wired through [CustomerCommsService]. Recording flows
  /// through the module provider's sendMessage so the timeline, card chips and
  /// the Actions log all update exactly as they do from the detail screen.
  Widget _buildCustomerSection(EnquiryModel enquiry) {
    final info = enquiry.customerInfo;
    final provider = _config.type == ModuleType.crm
        ? Provider.of<CrmProvider>(context, listen: false)
        : Provider.of<SalesProvider>(context, listen: false)
              as BaseModuleProvider;
    final byName = widget.currentName?.trim().isNotEmpty == true
        ? widget.currentName!.trim()
        : 'User';
    Future<void> record(String text) => provider.sendMessage(
      enquiry.id,
      MessageModel(
        id: Helpers.generateId(),
        taskId: enquiry.id,
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
      accentColor: _themeColor,
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
