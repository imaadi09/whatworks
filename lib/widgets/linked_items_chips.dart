import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../modules/sales/models/enquiry.dart';
import '../modules/shared/module_config.dart';
import '../modules/sales/providers/sales_provider.dart';
import '../modules/crm/providers/crm_provider.dart';
import '../providers/task_provider.dart';
import '../screens/task_detail/task_detail_screen.dart';
import '../modules/sales/screens/sales_detail_screen.dart';
import '../services/local_database_service.dart';
import '../utils/constants.dart';

/// The "Linked" chips row shown in the Task / Sales / CRM details cards.
///
/// One pill per link (module icon + `#id · title`), a trailing "+ Link"
/// chip that opens the picker sheet, tap to open the target item and
/// long-press to remove (the hosting screen wires [onRemove] to the
/// confirm-dialog + ItemLinksService.unlink flow).
class LinkedItemsChips extends StatelessWidget {
  /// Raw link entries from extraFields (ItemLinksService.linksOf).
  final List<Map<String, dynamic>> links;

  /// Opens the link picker sheet.
  final VoidCallback onAdd;

  /// Called with the tapped link entry — host screen confirms + unlinks.
  final ValueChanged<Map<String, dynamic>> onRemove;

  const LinkedItemsChips({
    super.key,
    required this.links,
    required this.onAdd,
    required this.onRemove,
  });

  /// Module accent for a link entry — Task teal, Sales blue, CRM cyan
  /// (matches each module's theme so chips are instantly attributable).
  static Color colorFor(String module) => switch (module) {
    'sales' => ModuleConfig.sales.themeColor,
    'crm' => ModuleConfig.crm.themeColor,
    _ => AppTheme.accent,
  };

  static IconData iconFor(String module) => switch (module) {
    'sales' => Icons.work_outline,
    'crm' => Icons.storefront_outlined,
    _ => Icons.checklist_rounded,
  };

  /// Display label: `#12 · Title` (id falls back to title-only).
  static String labelFor(Map<String, dynamic> link) {
    final title = (link['title'] as String?)?.trim() ?? '';
    final displayId = link['displayId'];
    final prefix = displayId is int ? '#$displayId' : '';
    if (prefix.isEmpty) return title.isEmpty ? 'Untitled' : title;
    return title.isEmpty ? prefix : '$prefix · $title';
  }

  /// Open a link's target detail screen, resolving a fresh copy from the
  /// provider cache (SQLite fallback). Deleted/missing targets surface a
  /// SnackBar so the user can long-press-unlink the stale chip.
  ///
  /// Uses pushReplacement (not push): this is only ever reached from another
  /// detail screen's Linked row, so replacing the current route keeps the
  /// stack at Home + one detail — following a chain of links and pressing Back
  /// returns to Home instead of retracing every intermediate screen.
  static Future<void> openLink(
    BuildContext context,
    Map<String, dynamic> link,
  ) async {
    final module = link['module'] as String? ?? 'task';
    final id = link['id'] as String? ?? '';
    if (id.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    if (module == 'task') {
      TaskModel? task;
      try {
        task = context.read<TaskProvider>().allTasks
            .where((t) => t.id == id)
            .firstOrNull;
      } catch (_) {}
      task ??= await LocalDatabaseService().getTaskById(id);
      if (task == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('This item was deleted')),
        );
        return;
      }
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task!)),
      );
      return;
    }

    final config = module == 'crm' ? ModuleConfig.crm : ModuleConfig.sales;
    EnquiryModel? enquiry;
    try {
      final provider = config.type == ModuleType.crm
          ? context.read<CrmProvider>()
          : context.read<SalesProvider>();
      enquiry = provider.enquiries.where((e) => e.id == id).firstOrNull;
    } catch (_) {}
    enquiry ??= await LocalDatabaseService().getModuleEnquiryById(
      id,
      tableName: config.enquiriesTableName,
    );
    if (enquiry == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This item was deleted')),
      );
      return;
    }
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            SalesDetailScreen(enquiry: enquiry!, moduleConfig: config),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final link in links)
          _LinkPill(
            link: link,
            onTap: () => openLink(context, link),
            onLongPress: () => onRemove(link),
          ),
        // Trailing "+ Link" chip — always available (empty state included).
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.lightText.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_link, size: 13, color: AppTheme.lightText),
                SizedBox(width: 3),
                Text(
                  'Link',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.lightText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Single link pill: module-coloured tint, icon + label, tap opens the
/// target, long-press removes the link.
class _LinkPill extends StatelessWidget {
  final Map<String, dynamic> link;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _LinkPill({
    required this.link,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final module = link['module'] as String? ?? 'task';
    final color = LinkedItemsChips.colorFor(module);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LinkedItemsChips.iconFor(module), size: 12, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                LinkedItemsChips.labelFor(link),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
