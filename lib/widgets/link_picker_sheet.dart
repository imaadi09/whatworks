import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../modules/sales/providers/sales_provider.dart';
import '../modules/crm/providers/crm_provider.dart';
import '../services/item_links_service.dart';
import '../utils/constants.dart';
import 'linked_items_chips.dart';

/// Open the cross-module link picker: choose a Task, Sales enquiry or CRM
/// ticket to link to the source item. [sourceLinks] = the source's current
/// link entries (already-linked targets are excluded from the list).
/// Returns true when a link was created (the host screen can then refresh
/// its item copy).
Future<bool> showLinkPickerSheet(
  BuildContext context, {
  required LinkRef source,
  List<Map<String, dynamic>> sourceLinks = const [],
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _LinkPickerSheet(source: source, sourceLinks: sourceLinks),
  );
  return result ?? false;
}

class _LinkPickerSheet extends StatefulWidget {
  final LinkRef source;
  final List<Map<String, dynamic>> sourceLinks;

  const _LinkPickerSheet({required this.source, required this.sourceLinks});

  @override
  State<_LinkPickerSheet> createState() => _LinkPickerSheetState();
}

class _LinkPickerSheetState extends State<_LinkPickerSheet> {
  /// 'task' | 'sales' | 'crm' — the source's own module is preselected.
  late String _module = widget.source.module;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _linking = false;

  static const List<(String, String)> _modules = [
    ('task', 'Tasks'),
    ('sales', 'Sales'),
    ('crm', 'CRM'),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Candidate rows for the selected module — provider caches (listened, so
  /// the sheet stays fresh), minus deleted items, the source itself and
  /// items already linked from the source.
  List<(String, int?, String, String)> _candidates(BuildContext context) {
    // (id, displayId, title, subtitle)
    final rows = switch (_module) {
      'task' => context
          .watch<TaskProvider>()
          .allTasks
          .where((t) => !t.isDeleted)
          .map(
            (t) => (
              t.id,
              t.displayId,
              t.title.isNotEmpty ? t.title : 'Untitled task',
              t.assignedTo,
            ),
          )
          .toList(),
      'sales' => context
          .watch<SalesProvider>()
          .enquiries
          .where((e) => !e.isDeleted)
          .map(
            (e) => (
              e.id,
              e.displayId,
              e.title.isNotEmpty ? e.title : e.clientName,
              e.assignedTo,
            ),
          )
          .toList(),
      _ => context
          .watch<CrmProvider>()
          .enquiries
          .where((e) => !e.isDeleted)
          .map(
            (e) => (
              e.id,
              e.displayId,
              e.title.isNotEmpty ? e.title : e.clientName,
              e.assignedTo,
            ),
          )
          .toList(),
    };

    // Exclude the source item and anything already linked from it.
    final linkedIds = widget.sourceLinks
        .where((l) => l['module'] == _module)
        .map((l) => l['id'] as String)
        .toSet();
    final filtered = rows
        .where((r) => r.$1 != widget.source.id && !linkedIds.contains(r.$1))
        .toList();

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return filtered;
    return filtered
        .where(
          (r) =>
              r.$3.toLowerCase().contains(q) ||
              r.$4.toLowerCase().contains(q) ||
              (r.$2 != null && '#${r.$2}'.contains(q)) ||
              (r.$2 != null && '${r.$2}'.contains(q)),
        )
        .toList();
  }

  Future<void> _pick((String, int?, String, String) row) async {
    if (_linking) return;
    setState(() => _linking = true);
    final target = LinkRef(
      module: _module,
      id: row.$1,
      title: row.$3,
      displayId: row.$2,
    );
    final ok = await ItemLinksService().link(
      context,
      source: widget.source,
      target: target,
    );
    if (!mounted) return;
    Navigator.pop(context, ok);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates(context);
    return Padding(
      // Keep the search field above the keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.add_link, size: 18, color: AppTheme.accent),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Link to…',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryText,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: AppTheme.lightText,
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ],
              ),
            ),
            // Module selector — all three modules always available.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final (key, label) in _modules) ...[
                    ChoiceChip(
                      label: Text(label),
                      selected: _module == key,
                      onSelected: (_) => setState(() => _module = key),
                      selectedColor: LinkedItemsChips.colorFor(
                        key,
                      ).withOpacity(0.18),
                      labelStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _module == key
                            ? LinkedItemsChips.colorFor(key)
                            : AppTheme.secondaryText,
                      ),
                      backgroundColor: Colors.white,
                      side: BorderSide(
                        color: _module == key
                            ? LinkedItemsChips.colorFor(key)
                            : AppTheme.separator,
                      ),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search by title, name or #id',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.lightText,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: AppTheme.lightText,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF5F6F7),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: AppTheme.separator),
            // Results
            Expanded(
              child: _linking
                  ? const Center(child: CircularProgressIndicator())
                  : candidates.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Nothing available to link'
                            : 'No matches',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.lightText,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppTheme.separator),
                      itemBuilder: (context, index) {
                        final row = candidates[index];
                        final color = LinkedItemsChips.colorFor(_module);
                        return ListTile(
                          dense: true,
                          onTap: () => _pick(row),
                          leading: CircleAvatar(
                            radius: 15,
                            backgroundColor: color.withOpacity(0.15),
                            child: Icon(
                              LinkedItemsChips.iconFor(_module),
                              size: 15,
                              color: color,
                            ),
                          ),
                          title: Text(
                            row.$2 != null ? '#${row.$2} · ${row.$3}' : row.$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryText,
                            ),
                          ),
                          subtitle: row.$4.isEmpty
                              ? null
                              : Text(
                                  row.$4,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.secondaryText,
                                  ),
                                ),
                          trailing: const Icon(
                            Icons.link,
                            size: 16,
                            color: AppTheme.lightText,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
