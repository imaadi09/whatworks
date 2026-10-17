import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../models/task.dart';
import '../providers/auth_provider.dart';
import '../providers/task_provider.dart';
import '../modules/sales/models/enquiry.dart';
import '../modules/sales/providers/sales_provider.dart';
import '../modules/crm/providers/crm_provider.dart';
import '../modules/shared/base_module_provider.dart';
import '../modules/shared/module_config.dart';
import '../utils/helpers.dart';
import 'local_database_service.dart';

/// One side of a link: everything needed to write a mirror entry into the
/// other item's extraFields and to render its chip later.
class LinkRef {
  /// 'task' | 'sales' | 'crm'
  final String module;
  final String id;
  final String title;
  final int? displayId;

  const LinkRef({
    required this.module,
    required this.id,
    required this.title,
    this.displayId,
  });

  /// Human label used in chips and system messages: `#12 "Title"`.
  String get label =>
      '${displayId != null ? '#$displayId ' : ''}"${title.isNotEmpty ? title : 'Untitled'}"';

  /// Module word shown in system messages ("Linked to Task #12 …").
  String get moduleLabel => switch (module) {
    'sales' => ModuleConfig.sales.displayName,
    'crm' => ModuleConfig.crm.displayName,
    _ => 'Task',
  };

  Map<String, dynamic> toEntry(String linkedBy) => {
    'module': module,
    'id': id,
    'displayId': displayId,
    'title': title,
    'linkedAt': DateTime.now().toIso8601String(),
    'linkedBy': linkedBy,
  };
}

/// Cross-module item linking (Task ↔ Task / Sales / CRM).
///
/// Links live in `extraFields['linkedItems']` of both items — a list of
/// snapshot maps ({module, id, displayId, title, linkedAt, linkedBy}).
/// Storing them in extraFields means the existing SQLite/Firestore sync
/// pipelines persist them with no model or schema changes. Every link is
/// bidirectional: a mirror entry is written on the target item, and both
/// chats get a 🔗 system message.
class ItemLinksService {
  ItemLinksService._();
  static final ItemLinksService instance = ItemLinksService._();
  factory ItemLinksService() => instance;

  static const String _fieldKey = 'linkedItems';

  /// Null-safe parse of an item's link list.
  List<Map<String, dynamic>> linksOf(Map<String, dynamic>? extraFields) {
    final raw = extraFields?[_fieldKey];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => (m['id'] as String?)?.isNotEmpty ?? false)
        .toList();
  }

  /// Write a bidirectional link between [source] and [target].
  /// Returns false when the link was rejected (self-link or duplicate).
  Future<bool> link(
    BuildContext context, {
    required LinkRef source,
    required LinkRef target,
  }) async {
    if (source.module == target.module && source.id == target.id) {
      return false;
    }
    final userName = _currentUserName(context);
    final sourceEntry = target.toEntry(userName);
    final targetEntry = source.toEntry(userName);

    final okSource = await _appendLink(context, source, sourceEntry);
    if (!okSource) return false;
    await _appendLink(context, target, targetEntry);

    await _sendLinkMessage(
      context,
      side: source,
      text:
          '🔗 Linked to ${target.moduleLabel} ${target.label} by $userName at '
          '${Helpers.formatDateTime(DateTime.now())}',
    );
    await _sendLinkMessage(
      context,
      side: target,
      text:
          '🔗 Linked to ${source.moduleLabel} ${source.label} by $userName at '
          '${Helpers.formatDateTime(DateTime.now())}',
    );
    return true;
  }

  /// Remove the bidirectional link between [source] and [target] and post
  /// the removal system message on both sides.
  Future<void> unlink(
    BuildContext context, {
    required LinkRef source,
    required LinkRef target,
  }) async {
    final userName = _currentUserName(context);
    await _removeLink(context, source, target);
    await _removeLink(context, target, source);

    await _sendLinkMessage(
      context,
      side: source,
      text:
          '🔗 Link removed: ${target.moduleLabel} ${target.label} by $userName at '
          '${Helpers.formatDateTime(DateTime.now())}',
    );
    await _sendLinkMessage(
      context,
      side: target,
      text:
          '🔗 Link removed: ${source.moduleLabel} ${source.label} by $userName at '
          '${Helpers.formatDateTime(DateTime.now())}',
    );
  }

  // ── Internals ────────────────────────────────────────────────────────

  String _currentUserName(BuildContext context) {
    try {
      final name = context.read<AuthProvider>().userModel?.name.trim() ?? '';
      return name.isEmpty ? 'Unknown' : name;
    } catch (_) {
      return 'Unknown';
    }
  }

  /// Append [entry] to [side]'s linkedItems unless a link to the same
  /// module+id already exists. False = the item could not be resolved.
  Future<bool> _appendLink(
    BuildContext context,
    LinkRef side,
    Map<String, dynamic> entry,
  ) async {
    return _mutateLinks(context, side, (links) {
      final duplicate = links.any(
        (l) => l['module'] == entry['module'] && l['id'] == entry['id'],
      );
      if (duplicate) return null; // no-op, but still "success"
      return [...links, entry];
    });
  }

  Future<bool> _removeLink(
    BuildContext context,
    LinkRef side,
    LinkRef other,
  ) async {
    return _mutateLinks(context, side, (links) {
      return links
          .where(
            (l) => !(l['module'] == other.module && l['id'] == other.id),
          )
          .toList();
    });
  }

  /// Load the item's current links, run [mutate] and persist the result
  /// through the module's existing update path. A null mutate result means
  /// "nothing to write" (duplicate link) — treated as success.
  Future<bool> _mutateLinks(
    BuildContext context,
    LinkRef side,
    List<Map<String, dynamic>>? Function(List<Map<String, dynamic>> links)
    mutate,
  ) async {
    if (side.module == 'task') {
      final task = await _resolveTask(context, side.id);
      if (task == null) return false;
      final updated = mutate(linksOf(task.extraFields));
      if (updated == null) return true;
      final newTask = task.copyWith(
        extraFields: {...?task.extraFields, _fieldKey: updated},
        updatedAt: DateTime.now(),
      );
      await context.read<TaskProvider>().updateTask(task.id, newTask);
      return true;
    }
    final config = side.module == 'crm' ? ModuleConfig.crm : ModuleConfig.sales;
    final provider = _enquiryProvider(context, config);
    final enquiry = await _resolveEnquiry(context, config, side.id);
    if (enquiry == null) return false;
    final updated = mutate(linksOf(enquiry.extraFields));
    if (updated == null) return true;
    await provider.updateEnquiry(enquiry.id, {'extraFields.$_fieldKey': updated});
    return true;
  }

  BaseModuleProvider _enquiryProvider(BuildContext context, ModuleConfig config) {
    return config.type == ModuleType.crm
        ? context.read<CrmProvider>()
        : context.read<SalesProvider>();
  }

  /// Fresh task copy — provider cache first (in-memory, already synced),
  /// SQLite fallback for items outside the cached lists.
  Future<TaskModel?> _resolveTask(BuildContext context, String id) async {
    try {
      final cached = context.read<TaskProvider>().allTasks
          .where((t) => t.id == id)
          .firstOrNull;
      if (cached != null) return cached;
    } catch (_) {}
    return LocalDatabaseService().getTaskById(id);
  }

  Future<EnquiryModel?> _resolveEnquiry(
    BuildContext context,
    ModuleConfig config,
    String id,
  ) async {
    final cached = _enquiryProvider(context, config).enquiries
        .where((e) => e.id == id)
        .firstOrNull;
    if (cached != null) return cached;
    return LocalDatabaseService().getModuleEnquiryById(
      id,
      tableName: config.enquiriesTableName,
    );
  }

  /// System message on one side of the link. senderId is the acting user so
  /// the card renders right-aligned in the actor's chat (parity with the
  /// urgency/deadline system messages).
  Future<void> _sendLinkMessage(
    BuildContext context, {
    required LinkRef side,
    required String text,
  }) async {
    String userId = '';
    try {
      userId = context.read<AuthProvider>().userModel?.uid ?? '';
    } catch (_) {}
    final msg = MessageModel(
      id: Helpers.generateId(),
      taskId: side.id,
      senderId: userId,
      text: text,
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    if (side.module == 'task') {
      await context.read<TaskProvider>().sendMessage(side.id, msg);
    } else {
      final config = side.module == 'crm'
          ? ModuleConfig.crm
          : ModuleConfig.sales;
      await _enquiryProvider(context, config).sendMessage(side.id, msg);
    }
  }
}
