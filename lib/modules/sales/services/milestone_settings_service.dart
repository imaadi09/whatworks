import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../models/milestone.dart';

/// A milestone template with title, optional default deadline offset (days from
/// enquiry creation) and an optional 'payment'/'delivery' kind tag — tagged
/// steps feed the Payments/Delivery filters on the list screens.
class MilestoneTemplate {
  final String title;
  final int? deadlineOffsetDays; // null = no default deadline
  final String? kind; // 'payment' | 'delivery' | null

  MilestoneTemplate({required this.title, this.deadlineOffsetDays, this.kind});

  Map<String, dynamic> toJson() => {
    'title': title,
    'deadlineOffsetDays': deadlineOffsetDays,
    if (kind != null) 'kind': kind,
  };

  factory MilestoneTemplate.fromJson(Map<String, dynamic> json) =>
      MilestoneTemplate(
        title: json['title'] as String,
        deadlineOffsetDays: json['deadlineOffsetDays'] as int?,
        kind: json['kind'] as String?,
      );
}

/// Service to manage module milestone templates stored in SharedPreferences.
/// Templates are scoped per module: sales keeps its legacy key for backward
/// compatibility; CRM and Tasks each use their own key so modules never
/// share templates.
class MilestoneSettingsService {
  /// 'sales', 'crm' or 'task' — templates are stored per module.
  final String module;

  MilestoneSettingsService({this.module = 'sales'});

  String get _key => switch (module) {
    'crm' => 'crm_milestone_templates',
    'task' => 'task_milestone_templates',
    _ => 'sales_milestone_templates',
  };

  String get _enabledKey => '${module}_milestones_enabled';

  /// Milestones are opt-in for tasks (off until the user checks the enable
  /// box); sales/CRM pipelines keep their historical always-on behavior.
  bool get _defaultEnabled => module != 'task';

  /// In-memory cache so synchronous card rendering can read the flag without
  /// awaiting SharedPreferences. Populated by [isEnabled], [setEnabled] and
  /// [warmCache].
  static final Map<String, bool> _enabledCache = {};

  /// Synchronous read used by list cards (M0/M1 chip). Falls back to the
  /// per-module default until the cache is populated at startup.
  static bool isEnabledSync(String module) =>
      _enabledCache[module] ?? (module != 'task');

  /// Pre-populate the sync cache (called once at app startup).
  Future<void> warmCache() async {
    _enabledCache[module] = await isEnabled();
  }

  /// Whether milestones are enabled for this module. When disabled, new
  /// items are created without milestone templates.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_enabledKey) ?? _defaultEnabled;
    _enabledCache[module] = value;
    return value;
  }

  /// Persist the milestone enable flag for this module.
  Future<void> setEnabled(bool enabled) async {
    _enabledCache[module] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  /// Phase-2E: drop this module's saved templates and enable flag so
  /// [getEffectiveTemplates] / [isEnabled] fall back to the built-in defaults.
  /// Used when the app-wide business type is reset to "General". Affects only
  /// NEW items — existing cards keep whatever milestones they were created with.
  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_enabledKey);
    _enabledCache[module] = _defaultEnabled;
  }

  /// Load saved milestone templates. Returns null if none saved (use defaults).
  Future<List<MilestoneTemplate>?> loadTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null) return null;
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => MilestoneTemplate.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Save milestone templates to SharedPreferences.
  Future<void> saveTemplates(List<MilestoneTemplate> templates) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(templates.map((t) => t.toJson()).toList());
    await prefs.setString(_key, jsonStr);
  }

  /// Get effective templates (saved or module defaults).
  Future<List<MilestoneTemplate>> getEffectiveTemplates() async {
    final saved = await loadTemplates();
    if (saved != null && saved.isNotEmpty) return saved;
    // Return defaults for this module
    return switch (module) {
      'crm' => defaultCrmMilestoneTemplates,
      'task' => defaultTaskMilestoneTemplates,
      _ => defaultMilestoneTemplates,
    };
  }
}

/// Default Sales milestone templates (matches the existing defaultSalesMilestoneTitles).
final List<MilestoneTemplate> defaultMilestoneTemplates = [
  MilestoneTemplate(title: 'Initial Contact', deadlineOffsetDays: 0),
  MilestoneTemplate(title: 'Needs Assessment', deadlineOffsetDays: 3),
  MilestoneTemplate(title: 'Follow-up Sent', deadlineOffsetDays: 5),
  MilestoneTemplate(title: 'Demo/Presentation', deadlineOffsetDays: 7),
  MilestoneTemplate(title: 'Proposal Sent', deadlineOffsetDays: 10),
  MilestoneTemplate(title: 'Negotiation', deadlineOffsetDays: 14),
  MilestoneTemplate(title: 'Closing', deadlineOffsetDays: 21),
  // Post-agreement follow-through: the deal isn't done until cash is in and
  // the product/service is handed over. These close the money/delivery loop
  // and pair with the Cash / Payment chat actions. Tagged as payment/delivery
  // kinds so the list filters can answer "paid yet?" / "delivered yet?".
  MilestoneTemplate(
    title: 'Payment Received',
    deadlineOffsetDays: 25,
    kind: MilestoneModel.kindPayment,
  ),
  MilestoneTemplate(
    title: 'Delivered / Handed Over',
    deadlineOffsetDays: 30,
    kind: MilestoneModel.kindDelivery,
  ),
];

/// Default CRM milestone templates (matches ModuleConfig.crm.defaultMilestones).
final List<MilestoneTemplate> defaultCrmMilestoneTemplates = [
  MilestoneTemplate(title: 'Ticket', deadlineOffsetDays: 0),
  MilestoneTemplate(title: 'Visited', deadlineOffsetDays: 2),
  MilestoneTemplate(title: 'Estimate', deadlineOffsetDays: 4),
  MilestoneTemplate(title: 'Repaired', deadlineOffsetDays: 7),
  MilestoneTemplate(title: 'Closed', deadlineOffsetDays: 10),
];

/// Default Task milestone templates applied to newly created tasks.
final List<MilestoneTemplate> defaultTaskMilestoneTemplates = [
  MilestoneTemplate(title: 'Planning', deadlineOffsetDays: 0),
  MilestoneTemplate(title: 'Work In Progress', deadlineOffsetDays: 2),
  MilestoneTemplate(title: 'Review', deadlineOffsetDays: 5),
  MilestoneTemplate(title: 'Completed', deadlineOffsetDays: 7),
];
