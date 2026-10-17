import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/task_provider.dart';
import '../providers/sales_provider.dart';
import '../../crm/providers/crm_provider.dart';
import '../../../utils/constants.dart';
import '../../../models/milestone.dart';
import '../services/milestone_settings_service.dart';
import '../../shared/module_config.dart';

/// Screen to configure pipeline milestone templates for a module.
/// Accessible from the Sales/CRM/Task 3-dot menus.
class SalesMilestoneSettingsScreen extends StatefulWidget {
  final ModuleConfig? moduleConfig;

  /// When true the screen manages Task module milestone templates
  /// (Task module is not part of the ModuleConfig framework).
  final bool isTaskModule;

  const SalesMilestoneSettingsScreen({
    super.key,
    this.moduleConfig,
    this.isTaskModule = false,
  });

  @override
  State<SalesMilestoneSettingsScreen> createState() =>
      _SalesMilestoneSettingsScreenState();
}

class _SalesMilestoneSettingsScreenState
    extends State<SalesMilestoneSettingsScreen> {
  ModuleConfig get _config => widget.moduleConfig ?? ModuleConfig.sales;
  bool get _isTask => widget.isTaskModule;
  bool get _isCrm => !_isTask && _config.type == ModuleType.crm;
  Color get _themeColor => _isTask ? AppTheme.primaryGreen : _config.themeColor;

  /// Templates are scoped per module (task / sales / crm never share a key).
  MilestoneSettingsService get _service => MilestoneSettingsService(
    module: _isTask ? 'task' : (_isCrm ? 'crm' : 'sales'),
  );
  List<MilestoneTemplate> _templates = [];
  bool _loading = true;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  void _loadTemplates() async {
    final templates = await _service.getEffectiveTemplates();
    final enabled = await _service.isEnabled();
    if (mounted) {
      setState(() {
        _templates = List.from(templates);
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  void _toggleEnabled(bool? value) async {
    final enabled = value ?? false;
    setState(() => _enabled = enabled);
    await _service.setEnabled(enabled);
    // Rebuild list cards so the M chip appears/disappears right away.
    if (mounted) {
      context.read<TaskProvider>().refresh();
      context.read<SalesProvider>().rebuildCards();
      context.read<CrmProvider>().rebuildCards();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? 'Milestones enabled for new ${_itemLabel}s'
                : 'Milestones disabled — new ${_itemLabel}s will have no milestones',
          ),
          backgroundColor: _themeColor,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String get _itemLabel => _isTask ? 'task' : _config.itemName.toLowerCase();

  /// Shared 'Type' chooser for the add/edit dialogs: a milestone can be tagged
  /// as a Payment or Delivery step (or none) so the list screens can filter
  /// "paid yet?" / "delivered yet?" off the user's own manual ticks.
  Widget _buildKindChips(String? kind, ValueChanged<String?> onPick) {
    ChoiceChip chip(String label, IconData icon, String? value) {
      final selected = kind == value;
      return ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? Colors.white : AppTheme.secondaryText,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? Colors.white : AppTheme.secondaryText,
              ),
            ),
          ],
        ),
        selected: selected,
        selectedColor: _themeColor,
        backgroundColor: _themeColor.withOpacity(0.06),
        side: BorderSide(
          color: selected ? _themeColor : _themeColor.withOpacity(0.25),
          width: 1,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        onSelected: (_) => onPick(value),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text(
          'TYPE (for Payments/Delivered filters)',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppTheme.secondaryText,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            chip('None', Icons.remove_circle_outline, null),
            chip(
              'Payment',
              Icons.payments_outlined,
              MilestoneModel.kindPayment,
            ),
            chip(
              'Delivery',
              Icons.local_shipping_outlined,
              MilestoneModel.kindDelivery,
            ),
          ],
        ),
      ],
    );
  }

  /// '💰 Payment' / '📦 Delivery' prefix for the template list subtitle.
  static String? _kindPrefix(MilestoneTemplate t) => switch (t.kind) {
    'payment' => '💰 Payment',
    'delivery' => '📦 Delivery',
    _ => null,
  };

  void _save() async {
    await _service.saveTemplates(_templates);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Milestone templates saved'),
          backgroundColor: _themeColor,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _addMilestone() async {
    final controller = TextEditingController();
    final offsetController = TextEditingController();
    String? kind; // 'payment' | 'delivery' | null
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Add Milestone',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Milestone title',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _themeColor, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: offsetController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Default deadline (days from start, optional)',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _themeColor, width: 2),
                  ),
                ),
              ),
              // Payment/Delivery type chooser — drives the list filters.
              _buildKindChips(kind, (k) => setDialogState(() => kind = k)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final title = controller.text.trim();
                if (title.isEmpty) return;
                final offset = int.tryParse(offsetController.text.trim());
                Navigator.pop(ctx, true);
                setState(() {
                  _templates.add(
                    MilestoneTemplate(
                      title: title,
                      deadlineOffsetDays: offset,
                      kind: kind,
                    ),
                  );
                });
                _save();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _editMilestone(int index) async {
    final template = _templates[index];
    final controller = TextEditingController(text: template.title);
    final offsetController = TextEditingController(
      text: template.deadlineOffsetDays?.toString() ?? '',
    );
    String? kind = template.kind;
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Edit Milestone',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Milestone title',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _themeColor, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: offsetController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Default deadline (days from start, optional)',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _themeColor, width: 2),
                  ),
                ),
              ),
              // Payment/Delivery type chooser — drives the list filters.
              _buildKindChips(kind, (k) => setDialogState(() => kind = k)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final title = controller.text.trim();
                if (title.isEmpty) return;
                final offset = int.tryParse(offsetController.text.trim());
                setState(() {
                  _templates[index] = MilestoneTemplate(
                    title: title,
                    deadlineOffsetDays: offset,
                    kind: kind,
                  );
                });
                Navigator.pop(ctx);
                _save();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteMilestone(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Milestone?'),
        content: Text(
          'Remove "${_templates[index].title}" from milestone templates?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _templates.removeAt(index));
              _save();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _resetToDefaults() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reset to Defaults?'),
        content: const Text(
          'This will replace your custom milestones with the default template.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(
                () => _templates = List.from(
                  _isTask
                      ? defaultTaskMilestoneTemplates
                      : _isCrm
                      ? defaultCrmMilestoneTemplates
                      : defaultMilestoneTemplates,
                ),
              );
              await _service.saveTemplates(_templates);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Reset to default milestones'),
                    backgroundColor: _themeColor,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 1,
        title: const Text(
          'Milestone Settings',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset to defaults',
            onPressed: _resetToDefaults,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: _themeColor))
          : Column(
              children: [
                // Info banner
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _themeColor.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _themeColor.withOpacity(0.15),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 18, color: _themeColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isTask
                              ? 'Configure milestone templates for new tasks. These milestones are added to every newly created task.'
                              : 'Configure milestone templates for new ${_config.displayName.toLowerCase()} ${_config.itemName.toLowerCase()}s. Deadline offset is days from ${_config.itemName.toLowerCase()} creation date.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Enable checkbox — milestones apply to new items only when on
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: CheckboxListTile(
                    value: _enabled,
                    onChanged: _toggleEnabled,
                    activeColor: _themeColor,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: const Text(
                      'Enable milestones',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    subtitle: Text(
                      _enabled
                          ? 'Added to every new $_itemLabel'
                          : 'New ${_itemLabel}s will be created without milestones',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                  ),
                ),
                // Milestone list
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _templates.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = _templates.removeAt(oldIndex);
                        _templates.insert(newIndex, item);
                      });
                      _save();
                    },
                    itemBuilder: (context, index) {
                      final template = _templates[index];
                      // Subtitle: optional 💰/📦 kind tag + the deadline line.
                      final kindP = _kindPrefix(template);
                      final dlText = template.deadlineOffsetDays != null
                          ? 'Deadline: ${template.deadlineOffsetDays} days from start'
                          : 'No deadline';
                      final subtitleText = kindP == null
                          ? dlText
                          : '$kindP · $dlText';
                      return Container(
                        key: ValueKey('${template.title}_$index'),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _themeColor.withOpacity(0.15),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          leading: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: _themeColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: _themeColor,
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            template.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryText,
                            ),
                          ),
                          subtitle: Text(
                            subtitleText,
                            style: TextStyle(
                              fontSize: 11,
                              color:
                                  kindP == null &&
                                      template.deadlineOffsetDays == null
                                  ? AppTheme.lightText
                                  : AppTheme.secondaryText,
                              fontStyle:
                                  kindP == null &&
                                      template.deadlineOffsetDays == null
                                  ? FontStyle.italic
                                  : null,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  Icons.edit_outlined,
                                  size: 20,
                                  color: _themeColor,
                                ),
                                onPressed: () => _editMilestone(index),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                  color: Colors.red,
                                ),
                                onPressed: () => _deleteMilestone(index),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: Icon(
                                  Icons.drag_handle,
                                  color: AppTheme.lightText,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Add button
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  child: ElevatedButton.icon(
                    onPressed: _addMilestone,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Milestone'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _themeColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
