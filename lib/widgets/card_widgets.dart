import 'package:flutter/material.dart';
import '../utils/constants.dart';
import 'app_avatar.dart';
import 'dashed_progress_bar.dart';

/// Shared leaf widgets for the list cards (TaskCard, SalesCard and the
/// home-screen assignee card). Task module is the base: fragments here are
/// extracted verbatim from TaskCard so visuals stay identical everywhere.

/// Status color used for the avatar direction badge — cancelled red,
/// closed blue, scheduled orange, draft gray, active green.
Color cardStatusColor({
  required bool isCancelled,
  required bool isClosed,
  Map<String, dynamic>? extraFields,
}) {
  if (isCancelled) {
    return const Color(0xFFE03131); // Red
  }
  if (isClosed) {
    return const Color(0xFF1976D2); // Blue
  }
  if (extraFields != null && extraFields['isBlocked'] == true) {
    return const Color(0xFF862E9C); // Purple — blocked, distinct from cancel red
  }
  if (extraFields != null && extraFields['isDraft'] == true) {
    if (extraFields['scheduledDate'] != null) {
      return const Color(0xFFF59F00); // Orange for Scheduled
    }
    return const Color(0xFF868E96); // Gray for Draft
  }
  return const Color(0xFF2F9E44); // Green for Active
}

/// Small amber crown shown inline next to a person's name when they are on
/// a premium plan (Premium/Basic differentiation). Kept tiny so it fits in
/// the 12px name rows of TaskCard/SalesCard and the picker tiles.
class PremiumBadge extends StatelessWidget {
  final double size;

  const PremiumBadge({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 3),
      child: Icon(
        Icons.workspace_premium,
        size: size,
        color: Colors.amber[700],
      ),
    );
  }
}

/// Avatar (WhatsApp style) with the status-colored direction badge.
/// Shows the person's photo or preset avatar when [avatarUrl] is provided
/// (resolved synchronously via AvatarCacheService at call sites);
/// falls back to tinted initials.
class CardAvatarBadge extends StatelessWidget {
  final String initials;
  final Color avatarColor; // circle background (15%) + initials tint
  final Color badgeColor; // status color of the 20x20 badge circle
  final IconData badgeIcon;
  final String? avatarUrl; // photo URL or `avatar:<id>` preset

  const CardAvatarBadge({
    super.key,
    required this.initials,
    required this.avatarColor,
    required this.badgeColor,
    required this.badgeIcon,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAvatar(
            avatarUrl: avatarUrl,
            initials: initials,
            radius: 24.5,
            color: avatarColor,
            fontSize: 17,
          ),
          // Direction badge (send/receive) — compact circle per user request
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Icon(badgeIcon, size: 12, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// One visual family for every small card pill — draft, milestone, deadline
/// and the bottom-row action chips. Soft tinted background with a colored
/// label by default; [solid] paints a filled accent (reserved for attention
/// items like blockers) so they still pop. Uniform radius / padding / height
/// keeps each card's right-hand clusters aligned and calm.
class CardMetaChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool solid;
  final double fontSize;
  final FontWeight fontWeight;
  final IconData? icon; // optional leading icon (urgency chip)
  final bool fill; // stretch to the parent slot width (side column rows)
  final Color? textColor; // label/icon colour override; bg keeps [color] tint
  // Force equal-width (tabular) digits so a numeric label of a given length
  // always renders at the same pixel width. Without it a device fallback font
  // can draw '0' wider than '1', so two right-aligned ticket chips (#1017 vs
  // #1000) hug to different widths and read as sitting at different positions.
  final bool tabularFigures;

  const CardMetaChip({
    super.key,
    required this.label,
    required this.color,
    this.solid = false,
    this.fontSize = 10,
    this.fontWeight = FontWeight.w600,
    this.icon,
    this.fill = false,
    this.textColor,
    this.tabularFigures = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = solid ? Colors.white : (textColor ?? color);
    return Container(
      width: fill ? double.infinity : null,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: solid ? color : color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: fontWeight,
              color: fg,
              height: 1.2,
              // Slightly condensed so short-form chips stay compact.
              letterSpacing: -0.2,
              fontFeatures: tabularFigures
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Gray "Draft" chip shown on line 1 for draft tasks/enquiries.
class DraftChip extends StatelessWidget {
  const DraftChip({super.key});

  @override
  Widget build(BuildContext context) {
    return const CardMetaChip(
      label: 'Draft',
      color: Color(0xFF868E96),
    );
  }
}

/// Urgency flag tile for the card side column (Row 3): a grey tinted tile
/// with a red flag glyph for any urgency state. Rendered only when the
/// item actually carries the state; display-only (the detail screen owns
/// the urgency chooser).
class CardFlagTile extends StatelessWidget {
  final String state; // 'urgent' | 'attention' | 'blocked'
  const CardFlagTile({super.key, required this.state});

  /// Resolves the 4-state urgency from raw card fields: [urgencyState] is
  /// the extraFields value stored by the detail chooser, isBlocked wins
  /// over it, and the legacy isUrgent bool is the fallback.
  static String stateFor({
    required bool isUrgent,
    bool isBlocked = false,
    String? urgencyState,
  }) {
    if (isBlocked || urgencyState == 'blocked') return 'blocked';
    if (urgencyState == 'attention') return 'attention';
    if (urgencyState == 'urgent') return 'urgent';
    return isUrgent ? 'urgent' : 'none';
  }

  /// Needs Attention -> orange (AppTheme.warning), Urgent -> red, Blocked ->
  /// the blocked colour. Matches the detail urgency chooser's own colours so
  /// the card flag and the detail chip agree.
  static Color colorFor(String state) {
    switch (state) {
      case 'attention':
        return AppTheme.warning;
      case 'urgent':
        return AppTheme.mutedRed;
      case 'blocked':
        return AppTheme.blocked;
      default:
        return AppTheme.mutedRed;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Colour the flag glyph by urgency state so a card visibly reflects the
  // detail chooser: Needs Attention is orange, Urgent stays red, Blocked uses
  // the blocked token. The tile background stays a calm grey tint so the card
  // palette is unchanged (red/orange live only on the glyph).
  return Container(
    width: double.infinity,
    height: 20,
    decoration: BoxDecoration(
      color: AppTheme.lightText.withOpacity(0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Center(
      child: Icon(Icons.flag_rounded, size: 12, color: colorFor(state)),
    ),
  );
  }
}

/// Linked-items tile for the card side column (Row 3): same geometry as
/// CardFlagTile in the module accent tint with a chain icon. Rendered
/// only when the item has linked items; display-only.
class CardLinkTile extends StatelessWidget {
  final Color color;
  const CardLinkTile({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 20,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Icon(Icons.link, size: 12, color: color),
      ),
    );
  }
}

/// Small on-app presence tick placed after a chat participant's name in the
/// detail AppBar. Solid white = the person is a registered app user (they
/// have an app UID); faded white = invited by phone and not on the app yet.
/// White reads on every coloured header (Task green, Sales blue, CRM teal).
class OnAppDot extends StatelessWidget {
  final bool onApp;
  final double size;
  const OnAppDot({super.key, required this.onApp, this.size = 8});

  @override
  Widget build(BuildContext context) {
    // A white tick trails the participant's name in the chat AppBar: solid for
    // a registered app user, faded for a phone-invited contact not on the app.
    return Icon(
      Icons.check,
      size: size * 1.7,
      color: onApp ? Colors.white : Colors.white.withOpacity(0.6),
    );
  }
}

/// The single 3-color deadline rule shared by every progress surface:
/// due date passed → [AppTheme.mutedRed], due within 2 days →
/// [AppTheme.deadlineNearing], otherwise → [AppTheme.onTime]. Closed/
/// cancelled items pass [isClosed] and fall back to [AppTheme.secondaryText]
/// so a finished item never glows. An OPEN item with no due date reads
/// [AppTheme.onTime] (green) — a missing deadline means "nothing is late",
/// not "stalled", so the bar stays green rather than grey. [createdAt] may be
/// replaced by a start date; only the day difference against today matters.
Color deadlineColorFor(
  DateTime createdAt,
  DateTime? deadline, {
  bool isClosed = false,
}) {
  // A finished item never glows — keep it the calm grey.
  if (isClosed) return AppTheme.secondaryText;
  // Open with no due date → green (on track), not grey.
  if (deadline == null) return AppTheme.onTime;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final deadlineDate = DateTime(deadline.year, deadline.month, deadline.day);
  final daysLeft = deadlineDate.difference(today).inDays;
  if (daysLeft < 0) return AppTheme.mutedRed;
  if (daysLeft <= 2) return AppTheme.deadlineNearing;
  return AppTheme.onTime;
}

/// True when [deadline]'s calendar day has already passed (ignoring the
/// time-of-day). Used so an open, fully-progressed-but-late item can still
/// read overdue rather than green.
bool isPastDeadline(DateTime? deadline) {
  if (deadline == null) return false;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final deadlineDate = DateTime(deadline.year, deadline.month, deadline.day);
  return deadlineDate.isBefore(today);
}

/// Deadline chip values computed from createdAt/deadline — a single
/// human-readable label plus a timing colour. To keep the card's chip
/// palette calm, the countdown chip colours by DAY MAGNITUDE (beyond 2 days
/// green, within 2 amber) and uses the SAME colour for "Xd over" as the
/// matching "Xd left", so overdue adds no extra colour; the overdue red
/// signal stays on the progress bar / flag via [deadlineColorFor]. Closed
/// items render a quiet graphite "Closed"/"No due" pill and never glow.
class DeadlineChipData {
  final String label;
  final Color color;

  const DeadlineChipData._({required this.label, required this.color});

  /// [isOpen] mirrors the summary strips: closed/cancelled cards stop
  /// accruing "Xd over" days (default true keeps old callers unchanged).
  static DeadlineChipData compute(
    DateTime createdAt,
    DateTime? deadline, {
    bool isOpen = true,
  }) {
    if (deadline == null) {
      return const DeadlineChipData._(
        label: 'No due',
        color: AppTheme.secondaryText,
      );
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final deadlineDate = DateTime(
      deadline.year,
      deadline.month,
      deadline.day,
    );
    final difference = deadlineDate.difference(today).inDays;
    final color = deadlineColorFor(createdAt, deadline, isClosed: !isOpen);

    if (difference < 0) {
      if (!isOpen) {
        return const DeadlineChipData._(
          label: 'Closed',
          color: AppTheme.secondaryText,
        );
      }
      final days = difference.abs();
      // Keep the countdown chip to the SAME timing colour an equal-length
      // "Xd left" chip would use (green beyond 2 days, amber within 2) instead
      // of red, so an overdue card doesn't introduce a fourth chip colour.
      // The overdue signal still lives on the progress bar / flag tile,
      // which keep using deadlineColorFor's mutedRed.
      final overColor = days <= 2
          ? AppTheme.deadlineNearing
          : AppTheme.onTime;
      return DeadlineChipData._(
        label: '${days}d over',
        color: overColor,
      );
    }
    if (difference == 0) {
      // Deadline date is today — show hours when a time component remains.
      final hoursLeft = deadline.difference(now).inHours;
      return DeadlineChipData._(
        label: hoursLeft > 0 && hoursLeft < 24
            ? '${hoursLeft}h left'
            : 'Due today',
        color: color,
      );
    }
    return DeadlineChipData._(
      label: '${difference}d left',
      color: color,
    );
  }
}

/// Days-to-deadline badge with a single human-readable label
/// ("5d left", "2d over", "Due today") instead of the old cryptic
/// "elapsed | total" day pair.
class DeadlineChip extends StatelessWidget {
  final DeadlineChipData data;

  const DeadlineChip({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // No deadline set: leave the slot blank instead of a "No due" pill.
    if (data.label == 'No due') return const SizedBox.shrink();
    return CardMetaChip(label: data.label, color: data.color);
  }
}

/// Full-width deadline pill for the card side column (Row 2). Unlike the
/// inline DeadlineChip it never shrinks: a missing deadline still paints
/// the graphite "No due" pill so the column rows keep their rhythm.
class CardDeadlineBar extends StatelessWidget {
  final DeadlineChipData data;

  /// When set, the pill is forced to this single colour (background + text)
  /// instead of the timing colour carried in [data]. Sales/CRM pass their
  /// module accent so the deadline chip is always blue — the red/amber/green
  /// timing signal stays only on the progress bar, per the chip palette rule.
  final Color? overrideColor;

  const CardDeadlineBar({
    super.key,
    required this.data,
    this.overrideColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: CardMetaChip(
        label: data.label,
        color: overrideColor ?? data.color,
        fill: true,
      ),
    );
  }
}

/// Row 1 of the card side grid: the action chips, each filling an equal
/// slot of the fixed side width. Height is reserved even with no chips
/// so the deadline and tile rows keep the same y on every card. Lives
/// INSIDE the card's line-1 Row so chips align with the name line.
/// The width is a CAP chosen per call site to match how many chips that
/// card shows: a dated chip reads "Fup on 28", so a single-chip slot needs
/// ~68 — the old 60 ellipsized the day, which is the operative detail.
/// Chips hug (fill:false), so a short label never spends the whole cap.
class CardChipsRow extends StatelessWidget {
  final List<Widget> chips;
  final double width;

  const CardChipsRow({super.key, required this.chips, this.width = 100});

  @override
  Widget build(BuildContext context) {
    final shown = chips.length > 3 ? chips.sublist(chips.length - 3) : chips;
    return SizedBox(
      width: width,
      height: 16,
      child: shown.isEmpty
          ? null
          // Right-aligned, hugging the acronym (chips are built with fill:false)
          // so a single short action reads as a compact pill instead of a
          // full-width bar; Flexible keeps an over-long label within the slot.
          : Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final chip in shown) Flexible(child: chip),
              ],
            ),
    );
  }
}

/// Width of the shared trailing slot on a card's right edge: the milestone
/// chip (line 2) and the ticket `#id` chip (line 3) both sit inside a slot of
/// this exact width, flush right, so the `#id` holds an identical x — and the
/// same left edge — whether or not a customer name, rating or flag is present
/// next to it. A hugging chip would drift by its own width instead.
const double cardTrailingSlotWidth = 48;

/// Row 3 of the card side grid: flag & link tiles beside the milestone
/// chip — the flag owns the left slot, the link the right one, so an
/// active tile never drifts when the other is absent. Height is always
/// reserved so the meta line keeps the same y on every card. The strip
/// HUGS its content (no fixed 100px reserve): it lives at the end of the
/// title Row, so a card with a single small tile no longer steals ~70px
/// from the title and truncates it early.
class CardStateTiles extends StatelessWidget {
  final String urgencyState; // 'urgent' | 'attention' | 'blocked' | 'none'
  final bool hasLinks;
  final Color accentColor;
  final String? milestoneLabel; // e.g. 'M2' — sits with flag/link, flush right
  // When set, the milestone chip is wrapped in a fixed-width flush-right slot
  // of this size (see [cardTrailingSlotWidth]) so another line's chip can share
  // the exact same box. Null keeps the hugging width.
  final double? trailingSlotWidth;

  const CardStateTiles({
    super.key,
    required this.urgencyState,
    required this.hasLinks,
    required this.accentColor,
    this.milestoneLabel,
    this.trailingSlotWidth,
  });

  /// Width this tile configuration renders (24 per icon tile, the milestone
  /// in [milestoneSlot], 4px between tiles) so the line ABOVE can reserve the
  /// same box: user rule is that this strip must never outdent the line-1
  /// chip on the left, and line 1 reserves max(68, stripWidth) for it.
  static double stripWidth({
    required bool urgency,
    required bool links,
    required bool milestone,
    double milestoneSlot = cardTrailingSlotWidth,
  }) {
    final widths = <double>[
      if (urgency) 24,
      if (links) 24,
      if (milestone) milestoneSlot,
    ];
    if (widths.isEmpty) return 0;
    return widths.reduce((a, b) => a + b) + 4 * (widths.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    // Right-column icons read neutral grey/black EXCEPT the urgency flag,
    // which keeps its state colour — so colour on the card signals only a
    // genuine problem. Milestone + link therefore use a calm grey, not the
    // module accent (accentColor is kept on the API for callers that still
    // want it but no longer tints these two tiles).
    final neutral = AppTheme.secondaryText;
    // Milestone is the TRAILING (flush-right) tile so it holds an identical x
    // on every card and the sales card's flush-right #id chip (line 3) sits
    // directly under it. Flag/link are to its LEFT — they may appear/disappear
    // without shifting the milestone (and hence the # chip) out of place.
    final children = <Widget>[];
    if (urgencyState != 'none') {
      children.add(
        SizedBox(width: 24, child: CardFlagTile(state: urgencyState)),
      );
    }
    if (hasLinks) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 4));
      children.add(SizedBox(width: 24, child: CardLinkTile(color: neutral)));
    }
    if (milestoneLabel != null) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 4));
      final chip = CardMetaChip(label: milestoneLabel!, color: neutral);
      final slot = trailingSlotWidth;
      children.add(
        slot == null
            ? chip
            : SizedBox(
                width: slot,
                child: Align(alignment: Alignment.centerRight, child: chip),
              ),
      );
    }
    return SizedBox(
      height: 20,
      child: children.isEmpty
          ? const SizedBox.shrink()
          : Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// Vertical progress bar for the card's right edge. The fill color carries
/// the shared [deadlineColorFor] timing (red past-deadline, amber within 2
/// days, green otherwise; quiet gray once closed), so lateness reads at a
/// glance on every card. [progressColor] optionally overrides the calm
/// on-track green with a module brand tint (e.g. Sales blue) — the amber/red
/// lateness signals are never masked. The unread count rides the timestamp
/// line as a quiet grey pill ([CardUnreadPill]) so the bar stays readable and
/// the last action icon keeps its flush-right slot.
class CardProgressStack extends StatelessWidget {
  final double progress;
  final bool isClosed;
  final DateTime createdAt;
  final DateTime? deadline;
  final double height;
  // Module override for the on-track (green) base color only. Null keeps the
  // shared deadline-timing green; Sales passes its blue.
  final Color? progressColor;

  const CardProgressStack({
    super.key,
    required this.progress,
    required this.isClosed,
    required this.createdAt,
    required this.deadline,
    this.height = 60,
    this.progressColor,
  });

  @override
  Widget build(BuildContext context) {
    // Being late outranks being finished-but-open: an OPEN item past its
    // deadline must read red even when every milestone is ticked
    // (progress >= 1.0). Only a closed/cancelled item keeps the calm green.
    final overdue = isPastDeadline(deadline);
    Color base;
    if (isClosed || (progress >= 1.0 && !overdue)) {
      base = AppTheme.onTime;
    } else {
      base = deadlineColorFor(createdAt, deadline, isClosed: isClosed);
    }
    // Swap the calm on-track green for a module brand color (Sales blue), but
    // never mask an amber/red lateness signal.
    final override = progressColor;
    if (override != null && base == AppTheme.onTime) {
      base = override;
    }
    // A zero-progress card shows the very START of the bar (a 1% sliver in the
    // same track) rather than a standalone dot — it reads as "not started yet"
    // while still carrying the on-track / late color.
    return DashedProgressBar(
      progress: progress <= 0 ? 0.01 : progress,
      height: height,
      color: base,
    );
  }
}

/// Quiet grey unread pill placed immediately AFTER the card's relative
/// timestamp. "Pending read" is a hint, not an alarm, so it stays in the
/// grey family (never the old bright green) and never covers the bar.
class CardUnreadPill extends StatelessWidget {
  final int count;

  /// Module brand color: Task green, Sales blue, CRM mint (pass
  /// `ModuleConfig.<module>.themeColor`). The pill is painted in it so each
  /// module's cards keep their own identity.
  final Color color;

  const CardUnreadPill({
    super.key,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Container(
        // Tight padding: the pill must stay inside the 14px meta line so the
        // card height never changes.
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: const TextStyle(
            fontSize: 10,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
