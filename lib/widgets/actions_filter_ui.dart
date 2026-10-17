import 'package:flutter/material.dart';
import '../modules/shared/module_config.dart';
import '../utils/constants.dart';

/// One selectable filter entry (time axis or action type). Kept minimal on
/// purpose: value + label + icon + tint, no counts (counts would force a
/// full re-scan of the action list on every rebuild).
class ActionFilterOption {
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  const ActionFilterOption(this.value, this.label, this.icon, this.color);
}

/// Build the Actions-tab Type dropdown from a module's OWN action catalog
/// (`ModuleConfig.actionTypes`) so every module surfaces exactly the actions it
/// offers, with the canonical catalog label / icon / colour. Previously each
/// screen hardcoded its own list: Sales and CRM shared a single superset (so
/// CRM leaked Won/Lost/Meeting and Sales leaked Repaired/Verified/Collected and
/// mislabeled CRM's 'Estimate' as 'Quotation'), and Task carried Warning /
/// Extension / Progress it no longer offers. Deriving from the catalog removes
/// all of that drift — the catalog is the single source of truth.
///
/// WhatsApp is auto-recorded (never a composed Message Actions tile), so it is
/// excluded here just like the Message Actions sheet already excludes it.
///
/// [valueFor] maps a catalog key to the option's stored value. The Sales/CRM
/// Actions rows expose `followup` under its display form `followUp`
/// (`_actionsFromRows`), so those surfaces pass a mapper that matches it; Task
/// keys map straight through (its filter converts the value back to the enum).
List<ActionFilterOption> actionTypeFilterOptions(
  List<ModuleAction> catalog, {
  String Function(String key)? valueFor,
}) {
  return <ActionFilterOption>[
    for (final a in catalog)
      if (a.key != 'whatsapp')
        ActionFilterOption(
          valueFor == null ? a.key : valueFor(a.key),
          a.label,
          a.icon,
          a.color,
        ),
  ];
}

/// Time-axis value meaning "no time filter at all".
const String kActionTimeAll = 'All';

/// Time-axis default: the Actions tabs open on TODAY's dated actions so the
/// user lands on what is due now (matches the icon-select's red "Today" tint).
const String kActionTimeToday = 'Today';

/// Sentinel value used by the Type dropdown for "no type filter". It is never
/// an action key/label, so it cannot collide with a real option value.
const String kActionTypeAll = '';

/// The single time-axis option list shared by every Actions surface (main
/// Task, main Sales/CRM and both assignee tabs). Each screen used to declare
/// its own copy, which is how 'All' went missing from all four at once: the
/// tab could only ever show a filtered subset. Keep it here so the dropdown
/// and the `switch (_timeFilter)` bodies cannot drift again.
const List<ActionFilterOption> kActionTimeOptions = [
  ActionFilterOption(kActionTimeAll, 'All', Icons.filter_alt_off_outlined, AppTheme.secondaryText),
  ActionFilterOption('Needs Attention', 'Needs Attention', Icons.hourglass_bottom, Color(0xFFF59F00)),
  ActionFilterOption('Overdue', 'Overdue', Icons.error_outline, AppTheme.mutedRed),
  ActionFilterOption(kActionTimeToday, 'Today', Icons.event, AppTheme.mutedRed),
  ActionFilterOption('Upcoming', 'Upcoming', Icons.event_available, AppTheme.secondaryText),
];

/// The Actions filter: a small Time icon-select + a full-width Type dropdown.
/// replacing the old 6-pill time row + "Showing:" chip.
///
/// Why this shape: the Type axis carries the long, module-specific action list
/// and needs room to read, so it keeps a labelled dropdown that fills the row.
/// The Time axis is a short, fixed set (All / Needs Attention / Overdue /
/// Today / Upcoming) — giving it equal width wasted space and made the two
/// controls compete. It now collapses to a compact icon button that shows the
/// active time's glyph (defaulting to "All") and opens a small menu. The icon
/// also carries the problem colour (red for Overdue/Today, amber for Needs
/// Attention) so an attention filter is visible at a glance.
///
/// PARITY: identical control across Task/Sales/Service. The ONLY per-module
/// difference is [typeOptions] — Sales/Service pass extra action kinds
/// (quotation, payment, delivery, …) that Task has no equivalent for. The
/// widget itself never branches on module.
///
/// [selectedType] is the current type value (or null for "All types"); the
/// widget renders a leading "All types" entry keyed by [kActionTypeAll].
/// [onTypeChanged] receives null when "All types" is chosen.
Widget buildActionFilterDropdowns({
  required List<ActionFilterOption> timeOptions,
  required String selectedTime,
  required ValueChanged<String> onTimeChanged,
  required List<ActionFilterOption> typeOptions,
  required String? selectedType,
  required ValueChanged<String?> onTypeChanged,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        _filterTimeIconButton(
          options: timeOptions,
          value: selectedTime,
          onChanged: onTimeChanged,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _filterDropdown(
            options: [
              const ActionFilterOption(
                kActionTypeAll,
                'All types',
                Icons.layers_outlined,
                AppTheme.secondaryText,
              ),
              ...typeOptions,
            ],
            value: selectedType ?? kActionTypeAll,
            onChanged: (v) => onTypeChanged(v == kActionTypeAll ? null : v),
          ),
        ),
      ],
    ),
  );
}

/// Compact Time filter: a single bordered icon button that shows the active
/// time option's glyph (tinted with its colour) and opens a small menu to pick
/// another. Replaces the equal-width Time dropdown so the two controls are no
/// longer the same size.
Widget _filterTimeIconButton({
  required List<ActionFilterOption> options,
  required String value,
  required ValueChanged<String> onChanged,
}) {
  // Fall back to the first option ("All") if a stale filter is passed in — the
  // same guard _filterDropdown uses, so the icon is never left unresolved.
  final selected = options.firstWhere(
    (o) => o.value == value,
    orElse: () => options.first,
  );
  return PopupMenuButton<String>(
    color: Colors.white,
    padding: EdgeInsets.zero,
    tooltip: 'Time: ${selected.label}',
    position: PopupMenuPosition.under,
    onSelected: onChanged,
    itemBuilder: (context) => [
      for (final o in options)
        PopupMenuItem<String>(
          value: o.value,
          child: Row(
            children: [
              Icon(o.icon, size: 18, color: o.color),
              const SizedBox(width: 10),
              Text(
                o.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryText,
                ),
              ),
            ],
          ),
        ),
    ],
    child: Container(
      height: 42,
      width: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          // Keep the neutral border, but hint an active non-"All" filter with
          // the option colour so it reads as "a time filter is on".
          color: selected.value == kActionTimeAll
              ? AppTheme.separator
              : selected.color,
        ),
      ),
      child: Icon(selected.icon, size: 20, color: selected.color),
    ),
  );
}

/// One labelled dropdown pill. Rendered as a bordered, white container so it
/// matches the card aesthetic of the rest of the tab.
Widget _filterDropdown({
  required List<ActionFilterOption> options,
  required String value,
  required ValueChanged<String> onChanged,
}) {
  // Guarantee the dropdown value matches exactly one item value; fall back to
  // the first option (an "All"/default entry) if a stale filter is passed in.
  final selectedValue =
      options.any((o) => o.value == value) ? value : options.first.value;

  return Container(
    height: 42,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppTheme.separator),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selectedValue,
        isExpanded: true,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        icon: const Icon(
          Icons.expand_more,
          size: 20,
          color: AppTheme.secondaryText,
        ),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.primaryText,
        ),
        items: [
          for (final o in options)
            DropdownMenuItem<String>(
              value: o.value,
              child: Row(
                children: [
                  Icon(o.icon, size: 16, color: o.color),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      o.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ),
  );
}
