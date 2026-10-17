import 'package:flutter/material.dart';

import '../../services/business_vocabulary.dart';

/// Module types supported by the app.
enum ModuleType { sales, crm, task }

/// A chat action type available in a module (Reminder, Follow Up, etc.).
class ModuleAction {
  final String key; // stored in SQLite actions table (actionType)
  final String label; // display label
  final String emoji; // message prefix emoji
  final IconData icon;
  final Color color;
  final bool hasDatePicker; // dialog offers optional date selection

  const ModuleAction({
    required this.key,
    required this.label,
    required this.emoji,
    required this.icon,
    required this.color,
    this.hasDatePicker = false,
  });
}

/// Shared action catalog entries reused across modules.
/// ⚠️ Action catalog — keys here MUST match the string keys returned by
/// Helpers.detectActionType, or the action can't be re-detected from its
/// message text (won't be indexed in actions tables or shown on cards).
/// Adding a new action here also requires updating detectActionType /
/// detectLastAction and the ACTION-TYPE CHECKLIST in task_detail_screen.dart.
class ModuleActions {
  static const ModuleAction reminder = ModuleAction(
    key: 'reminder',
    label: 'Reminder',
    emoji: '🔔',
    icon: Icons.notifications_outlined,
    color: Color(0xFFF59F00),
  );
  static const ModuleAction followUp = ModuleAction(
    key: 'followup',
    label: 'Follow Up',
    emoji: '📋',
    icon: Icons.event_note,
    color: Color(0xFF1971C2),
    // Follow-up always carries a date (pre-filled today) so the schedule is
    // never lost from the card/activity log — mirrors the Task module, whose
    // follow-up is always dated.
    hasDatePicker: true,
  );
  static const ModuleAction query = ModuleAction(
    key: 'query',
    label: 'Query',
    emoji: '❓',
    icon: Icons.help_outline,
    color: Color(0xFFE8590C),
  );
  // Escalation keeps the legacy 'warning' key for data compatibility.
  static const ModuleAction escalation = ModuleAction(
    key: 'warning',
    label: 'Escalation',
    emoji: '🚨',
    icon: Icons.report_gmailerrorred,
    color: Color(0xFFE03131),
  );
  // Request approval — same flow as the Task module's "Request" action.
  static const ModuleAction approval = ModuleAction(
    key: 'approval',
    label: 'Request',
    emoji: '✅',
    icon: Icons.fact_check,
    color: Color(0xFF0B7285),
  );
  static const ModuleAction quotation = ModuleAction(
    key: 'quotation',
    label: 'Quotation',
    emoji: '💰',
    icon: Icons.request_quote,
    color: Color(0xFF2F9E44),
  );
  static const ModuleAction meeting = ModuleAction(
    key: 'meeting',
    label: 'Meeting',
    emoji: '🤝',
    icon: Icons.groups,
    color: Color(0xFF3B5BDB),
    hasDatePicker: true,
  );
  // Field-service visit (Service Teams + the Sales Visit/Demo chooser):
  // scheduling/completing an on-location visit — distinct from a Meeting.
  // Renamed from "Site Visit" to "Visit" across every module (the stored key
  // and 🛠️ emoji stay for data-compat; detection leads on the emoji).
  static const ModuleAction siteVisit = ModuleAction(
    key: 'sitevisit',
    label: 'Visit',
    emoji: '🛠️',
    icon: Icons.handyman,
    color: Color(0xFF1098AD),
    hasDatePicker: true,
  );
  static const ModuleAction call = ModuleAction(
    key: 'call',
    label: 'Schedule Call',
    emoji: '📞',
    icon: Icons.call,
    color: Color(0xFF0C8599),
  );
  // WhatsApp — auto-recorded customer communication (logged by
  // CustomerCommsService when the user taps WhatsApp on a customer card /
  // detail screen). Informational like call/progress, so it is NOT a closure
  // type and is deliberately EXCLUDED from the Message Actions picker tiles in
  // both task_detail_screen and sales_detail_screen (it is never manually
  // composed). It lives in the catalog + each module's actionTypes so
  // actionFor('whatsapp') resolves its label/icon/color for Sales & CRM action
  // logs, card strips, reopen handling and reports.
  static const ModuleAction whatsapp = ModuleAction(
    key: 'whatsapp',
    label: 'WhatsApp',
    emoji: '💬',
    icon: Icons.chat,
    color: Color(0xFF25D366),
  );
  static const ModuleAction payment = ModuleAction(
    key: 'payment',
    label: 'Payment',
    emoji: '💳',
    icon: Icons.payments,
    color: Color(0xFF7048E8),
    hasDatePicker: true,
  );
  static const ModuleAction sample = ModuleAction(
    key: 'sample',
    label: 'Visit/Demo',
    emoji: '📦',
    icon: Icons.inventory_2_outlined,
    color: Color(0xFFAE3EC9),
    // Sales scheduling: like the other dated actions, always carry a visible
    // date (pre-filled today) so the visit/demo plan is never lost.
    hasDatePicker: true,
  );
  static const ModuleAction negotiation = ModuleAction(
    key: 'negotiation',
    label: 'Negotiation',
    emoji: '🏷️',
    icon: Icons.local_offer_outlined,
    color: Color(0xFFF08C00),
  );
  // Won/Lost/Dropped share a single "Outcome" menu tile; stored keys are
  // 'won'/'lost'/'dropped' (see sales_detail_screen _sendWonLostAction).
  static const ModuleAction won = ModuleAction(
    key: 'won',
    label: 'Won',
    emoji: '🏆',
    icon: Icons.emoji_events,
    color: Color(0xFF2F9E44),
  );
  static const ModuleAction lost = ModuleAction(
    key: 'lost',
    label: 'Lost',
    emoji: '❌',
    icon: Icons.cancel,
    color: Color(0xFFE03131),
  );
  // Dropped: lead went cold / disqualified — the third deal-outcome state,
  // reachable from the same Outcome tile and auto-setting status 'dropped'.
  static const ModuleAction dropped = ModuleAction(
    key: 'dropped',
    label: 'Dropped',
    emoji: '📉',
    icon: Icons.remove_circle_outline,
    color: Color(0xFF868E96),
  );
  // Cash management: Add Cash / Expense / Refund / Settled with running
  // balance. Labelled "Cash/Payment" across all modules (the standalone
  // 'payment' action is clubbed into this billing entry on the Service grid).
  static const ModuleAction cash = ModuleAction(
    key: 'cash',
    label: 'Cash/Payment',
    emoji: '💵',
    icon: Icons.account_balance_wallet,
    color: Color(0xFF099268),
  );
  // Field-service lifecycle (Service Teams only). Repaired = the fix is
  // completed on-site; Verified = a second person signs off the repair. Both
  // await a closure from someone else, so they are closure types (see
  // Helpers.actionClosureTypes).
  static const ModuleAction repaired = ModuleAction(
    key: 'repaired',
    label: 'Repaired',
    emoji: '🔧',
    icon: Icons.build,
    color: Color(0xFF1971C2),
  );
  static const ModuleAction verified = ModuleAction(
    key: 'verified',
    label: 'Verified',
    emoji: '✔️',
    icon: Icons.verified,
    color: Color(0xFF2F9E44),
  );
  // Delivery — goods/parts handed over to the customer. Dated (a scheduled
  // delivery day) and open until marked delivered (a closure type), so it
  // surfaces as a real due on the Actions tab. Key 'delivery' MUST match
  // Helpers.detectActionType / detectLastAction.
  static const ModuleAction delivery = ModuleAction(
    key: 'delivery',
    label: 'Delivery',
    emoji: '🚚',
    icon: Icons.local_shipping,
    color: Color(0xFFF76707),
    hasDatePicker: true,
  );
  // Collection — the technician picks the device/item up (Service field flow).
  // Dated + open until marked collected (a closure type), and it gates
  // delivery: a ticket can only be delivered once it has been collected. In
  // CRM this is raised from the Visit card (not a top-level grid tile). Key
  // 'collect' MUST match Helpers.detectActionType / detectLastAction.
  static const ModuleAction collect = ModuleAction(
    key: 'collect',
    label: 'Collected',
    emoji: '📥',
    icon: Icons.call_received,
    color: Color(0xFF0C8599),
    hasDatePicker: true,
  );
}

/// Centralized configuration for each module.
/// Screens, providers, and services read from this config to avoid hard-coded values.
class ModuleConfig {
  final ModuleType type;
  // Sector-independent fallback names. The user-visible [displayName] /
  // [itemName] getters below may override these with the active business-type
  // vocabulary; these hold the built-in defaults when no sector is chosen.
  final String
  defaultDisplayName; // "WorkTracker", "Sales Teams", "Service Teams"
  final String defaultItemName; // "Task", "Enquiry", "Ticket"
  final Color themeColor;
  final List<String> statusNames; // enum names: ["active", "success", ...]
  final List<String> statusLabels; // display: ["Active", "Success", ...]
  final List<Color> statusColors;
  final List<String> defaultMilestones;
  final String firestoreCollection; // "sales_enquiries" or "crm_records"
  final String teamsCollection; // "sales_teams" or "crm_teams"
  final String sequentialIdKey; // "sales" or "crm"
  final String teamPrefKey; // SharedPreferences key for selected team
  final String actionsTableName; // "sales_actions" or "crm_actions"
  final String enquiriesTableName; // "enquiries" or "crm_enquiries"
  final String teamsTableName; // "sales_teams" or "crm_teams"
  final String defaultStatusName; // "active" or "open"
  /// Statuses that count as "open" (still moving through the pipeline) for
  /// deadline accrual and active/overdue/needs-attention counts. A per-module
  /// whitelist so newly added mid-pipeline sales stages (quotation/demo/
  /// negotiation) stay "open", and CRM's working states (In Progress,
  /// Escalated) keep accruing deadlines instead of looking "done".
  final List<String> openStatusNames;
  final List<ModuleAction> actionTypes; // chat actions available in this module

  const ModuleConfig({
    required this.type,
    required this.defaultDisplayName,
    required this.defaultItemName,
    required this.themeColor,
    required this.statusNames,
    required this.statusLabels,
    required this.statusColors,
    required this.defaultMilestones,
    required this.firestoreCollection,
    required this.teamsCollection,
    required this.sequentialIdKey,
    required this.teamPrefKey,
    required this.actionsTableName,
    required this.enquiriesTableName,
    required this.teamsTableName,
    required this.defaultStatusName,
    required this.openStatusNames,
    required this.actionTypes,
  });

  /// Module label surfaced in AppBars / drawers. Resolves to the active
  /// business-type vocabulary when it defines an override for this module,
  /// otherwise the built-in [defaultDisplayName]. Read-only view so every
  /// existing `config.displayName` call site relabels for free.
  String get displayName =>
      BusinessVocabulary.displayNameFor(type) ?? defaultDisplayName;

  /// Item noun ("Task" / "Enquiry" / "Ticket") used across cards, dialogs and
  /// pluralizers. Sector-aware like [displayName].
  String get itemName =>
      BusinessVocabulary.itemNameFor(type) ?? defaultItemName;

  /// Sales module configuration.
  static const ModuleConfig sales = ModuleConfig(
    type: ModuleType.sales,
    defaultDisplayName: 'Sales Teams',
    defaultItemName: 'Enquiry',
    themeColor: Color(0xFF1971C2),
    // Pipeline order: the mid-funnel stages (Quotation/Demo/Negotiation) sit
    // between Active and the decided outcomes so the Status Change menu reads
    // as a natural sales funnel.
    statusNames: [
      'active',
      'quotation',
      'demo',
      'negotiation',
      'success',
      'lost',
      'dropped',
      'cancel',
    ],
    statusLabels: [
      'Active',
      'Quotation',
      'Demo',
      'Negotiation',
      'Success',
      'Lost',
      'Dropped',
      'Closed',
    ],
    statusColors: [
      Color(0xFF1971C2), // Active - Blue
      Color(0xFF0C8599), // Quotation - Teal
      Color(0xFFAE3EC9), // Demo - Grape
      Color(0xFFF08C00), // Negotiation - Amber
      Color(0xFF2F9E44), // Success - Green
      Color(0xFFE03131), // Lost - Red
      Color(0xFF868E96), // Dropped - Grey
      Color(0xFF495057), // Closed - Dark grey
    ],
    defaultMilestones: [
      'Initial Contact',
      'Needs Assessment',
      'Follow-up Sent',
      'Demo/Presentation',
      'Proposal Sent',
      'Negotiation',
      'Closing',
      'Payment Received',
      'Delivered / Handed Over',
    ],
    firestoreCollection: 'sales_enquiries',
    teamsCollection: 'sales_teams',
    sequentialIdKey: 'sales',
    teamPrefKey: 'current_sales_team_id',
    actionsTableName: 'sales_actions',
    enquiriesTableName: 'enquiries',
    teamsTableName: 'sales_teams',
    defaultStatusName: 'active',
    openStatusNames: ['active', 'quotation', 'demo', 'negotiation'],
    actionTypes: [
      ModuleActions.reminder,
      ModuleActions.followUp,
      ModuleActions.query,
      ModuleActions.escalation,
      ModuleActions.cash,
      ModuleActions.quotation,
      ModuleActions.meeting,
      ModuleActions.call,
      ModuleActions.whatsapp,
      ModuleActions.payment,
      ModuleActions.sample,
      // Site Visit is folded into the "Visit/Demo" tile (the chooser composes
      // it), so it is kept OUT of the Sales grid order but IN actionTypes so
      // actionFor('sitevisit') resolves for composing + card rendering.
      ModuleActions.siteVisit,
      ModuleActions.delivery,
      ModuleActions.approval,
      ModuleActions.negotiation,
      ModuleActions.won,
      ModuleActions.lost,
      ModuleActions.dropped,
    ],
  );

  /// CRM module configuration.
  static const ModuleConfig crm = ModuleConfig(
    type: ModuleType.crm,
    defaultDisplayName: 'Service Teams',
    defaultItemName: 'Ticket',
    themeColor: Color(0xFF0C8599),
    statusNames: ['open', 'inProgress', 'resolved', 'closed', 'escalated'],
    statusLabels: ['Open', 'Estimate', 'Repaired', 'Closed', 'Escalated'],
    statusColors: [
      Color(0xFF1971C2), // Open - Blue
      Color(0xFFF59F00), // Estimate - Amber
      Color(0xFF2F9E44), // Repaired - Green
      Color(0xFF495057), // Closed - Dark grey
      Color(0xFFE03131), // Escalated - Red
    ],
    defaultMilestones: [
      'Ticket',
      'Visited',
      'Estimate',
      'Repaired',
      'Closed',
    ],
    firestoreCollection: 'crm_records',
    teamsCollection: 'crm_teams',
    sequentialIdKey: 'crm',
    teamPrefKey: 'current_crm_team_id',
    actionsTableName: 'crm_actions',
    enquiriesTableName: 'crm_enquiries',
    teamsTableName: 'crm_teams',
    defaultStatusName: 'open',
    // A ticket is still being worked until it is Repaired/Closed: Estimate
    // (inProgress) and Escalated must keep counting as open (deadlines,
    // overdue counts, reports, open/done splits).
    openStatusNames: ['open', 'inProgress', 'escalated'],
    actionTypes: [
      ModuleActions.reminder,
      ModuleActions.escalation,
      // Query is offered as a top-level tile in Service too (same as Sales) —
      // the customer/technician asks a question the other side must answer.
      ModuleActions.query,
      // Field-service complaint lifecycle, in flow order:
      //   schedule a visit → estimate the repair → repair done → verify → collect.
      // Site Visit / Quotation keys are kept (data-compat with existing
      // tickets) but relabeled for Service Teams via CRM-local catalog entries;
      // detection leads on the emoji so the label change is transparent.
      ModuleAction(
        key: 'sitevisit',
        label: 'Visit',
        emoji: '🛠️',
        icon: Icons.handyman,
        color: Color(0xFF1098AD),
        hasDatePicker: true,
      ),
      ModuleAction(
        key: 'quotation',
        label: 'Estimate',
        emoji: '💰',
        icon: Icons.request_quote,
        color: Color(0xFF2F9E44),
      ),
      ModuleActions.repaired,
      ModuleActions.verified,
      // Collect + Delivery are SEPARATE top-level tiles in the CRM Message
      // Actions grid (like Sales Delivery). They stay in the catalog so
      // actionFor() resolves their label/icon for chat cards, activity log and
      // the Actions-tab dues, and so the compose path works when launched.
      ModuleActions.collect,
      ModuleActions.delivery,
      ModuleActions.cash,
      ModuleActions.payment,
      ModuleActions.whatsapp,
    ],
  );

  /// Task module configuration.
  ///
  /// Task is the app's reference implementation and predates the config-driven
  /// engine, so it consumes only [actionTypes] today — the Message Actions
  /// sheet in task_detail_screen now builds its tiles from here instead of a
  /// hardcoded list. The remaining fields carry Task's real collection / table
  /// / pref names and lifecycle so Task can migrate onto the shared engine
  /// later without inventing values.
  ///
  /// Task's action tiles intentionally keep their bespoke icons / labels /
  /// colors (they differ from the Sales/CRM catalog — e.g. "Warning" not
  /// "Escalation", a filled bell, the summarize icon for Query). The three
  /// tiles that already match [ModuleActions] are reused; the rest are defined
  /// inline with Task's exact prior values, so the rendered sheet is
  /// byte-identical to the previous hardcoded one.
  static const ModuleConfig task = ModuleConfig(
    type: ModuleType.task,
    defaultDisplayName: 'WorkTracker',
    defaultItemName: 'Task',
    themeColor: Color(0xFF25D366), // AppTheme.primaryGreen
    // Task has no status pipeline (it tracks isClosed / isCancelled / progress);
    // these mirror that lifecycle for forward-compatibility and are inert today.
    statusNames: ['active', 'closed', 'cancelled'],
    statusLabels: ['Active', 'Closed', 'Cancelled'],
    statusColors: [
      Color(0xFF25D366), // Active - Green
      Color(0xFF868E96), // Closed - Grey
      Color(0xFFE03131), // Cancelled - Red
    ],
    defaultMilestones: ['Planning', 'Work In Progress', 'Review', 'Completed'],
    firestoreCollection: 'tasks',
    teamsCollection: 'task_teams',
    sequentialIdKey: 'task',
    teamPrefKey: 'current_task_team_id',
    // Task records actions as chat messages (re-detected via detectActionType),
    // not a dedicated actions table — inert today.
    actionsTableName: 'task_actions',
    enquiriesTableName: 'tasks',
    teamsTableName: 'task_teams',
    defaultStatusName: 'active',
    openStatusNames: ['active'],
    actionTypes: [
      // Reminder — filled bell + amber (catalog uses an outlined bell).
      ModuleAction(
        key: 'reminder',
        label: 'Reminder',
        emoji: '🔔',
        icon: Icons.notifications_active,
        color: Color(0xFFF59F00),
      ),
      ModuleActions.approval, // Request — identical to the catalog entry.
      // Query — summarize icon + header green (catalog uses help_outline).
      ModuleAction(
        key: 'query',
        label: 'Query',
        emoji: '❓',
        icon: Icons.summarize,
        color: Color(0xFF075E54),
      ),
      // Follow Up — primary green (catalog uses blue); always dated.
      ModuleAction(
        key: 'followup',
        label: 'Follow Up',
        emoji: '📋',
        icon: Icons.event_note,
        color: Color(0xFF25D366),
        hasDatePicker: true,
      ),
      ModuleActions.call, // Schedule Call — identical to the catalog entry.
      // Meeting — paired with Call into a single "Meeting/Call" chooser tile
      // in the Task sheet (Sales parity). Kept in the catalog so
      // actionFor('meeting') resolves for card rendering + reopen.
      ModuleActions.meeting,
      // WhatsApp — auto-recorded; excluded from the Task picker (no manual
      // tile), kept here for catalog consistency + actionFor() resolution.
      ModuleActions.whatsapp,
      ModuleActions.cash, // Cash — identical to the catalog entry.
      // Raise Blocker — shared concept, not part of the Sales/CRM catalog list.
      ModuleAction(
        key: 'blocker',
        label: 'Raise Blocker',
        emoji: '🚧',
        icon: Icons.block,
        color: Color(0xFFC92A2A),
      ),
      // Visit — dated on-location commitment (🛠️, shared sitevisit key so
      // Sales/CRM detection + card rendering already resolve it). Replaced the
      // old Warning tile; warning stays in the ActionItem enum + parsers so any
      // pre-existing warning messages still classify.
      ModuleActions.siteVisit,
    ],
  );

  /// Get the color for a given status name.
  Color statusColorFor(String statusName) {
    final index = statusNames.indexOf(statusName);
    if (index >= 0 && index < statusColors.length) {
      return statusColors[index];
    }
    return themeColor;
  }

  /// Get display label for a status name.
  String statusLabelFor(String statusName) {
    final index = statusNames.indexOf(statusName);
    if (index >= 0 && index < statusLabels.length) {
      return statusLabels[index];
    }
    return statusName;
  }

  /// True if [statusName] is an open (in-pipeline) status for this module —
  /// used for deadline accrual and active/overdue/needs-attention counts.
  bool isOpenStatus(String statusName) => openStatusNames.contains(statusName);

  /// Look up an action definition by its stored key (e.g. 'followup').
  ModuleAction? actionFor(String key) {
    for (final a in actionTypes) {
      if (a.key == key) return a;
    }
    return null;
  }
}
