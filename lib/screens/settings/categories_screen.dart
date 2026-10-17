import 'package:flutter/material.dart';
import '../../services/local_database_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';

/// Screen to manage user-defined categories for Task and Sales modules.
class CategoriesScreen extends StatefulWidget {
  /// Optional: pre-select module filter when opened from a specific module menu.
  final String? initialModule;

  const CategoriesScreen({super.key, this.initialModule});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _db = LocalDatabaseService();
  final _nameController = TextEditingController();
  late String _selectedModule;
  List<Map<String, dynamic>> _categories = [];
  bool _isLoading = true;

  /// True when opened from a module menu — categories stay scoped to it.
  bool get _lockedToModule => widget.initialModule != null;

  @override
  void initState() {
    super.initState();
    _selectedModule = widget.initialModule ?? 'all';
    _loadCategories();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final db = await _db.database;
    // When opened from a module menu, only that module's categories are
    // shown/created; the global Settings entry manages all modules.
    final rows = _lockedToModule
        ? await db.query(
            'categories',
            where: 'module = ?',
            whereArgs: [_selectedModule],
            orderBy: 'name ASC',
          )
        : await db.query('categories', orderBy: 'name ASC');
    setState(() {
      _categories = rows;
      _isLoading = false;
    });
  }

  Future<void> _addCategory() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    // Check for duplicates
    final exists = _categories.any(
      (c) => (c['name'] as String).toLowerCase() == name.toLowerCase(),
    );
    if (exists) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Category already exists')));
      return;
    }

    final id = Helpers.generateId();
    await _db.insertCategory(id, name, _selectedModule);
    _nameController.clear();
    await _loadCategories();
  }

  Future<void> _deleteCategory(String id) async {
    await _db.deleteCategory(id);
    await _loadCategories();
  }

  Future<void> _editCategory(Map<String, dynamic> category) async {
    final controller = TextEditingController(text: category['name'] as String);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: 'Category name',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty && result != category['name']) {
      await _db.updateCategory(category['id'] as String, result);
      await _loadCategories();
    }
  }

  String _moduleLabel(String module) {
    switch (module) {
      case 'task':
        return 'Task';
      case 'sales':
        return 'Sales';
      case 'crm':
        return 'CRM';
      case 'all':
      default:
        return 'Both';
    }
  }

  Color _moduleColor(String module) {
    switch (module) {
      case 'task':
        return AppTheme.primaryGreen;
      case 'sales':
        return const Color(0xFF1971C2);
      case 'crm':
        return const Color(0xFF0C8599);
      case 'all':
      default:
        return AppTheme.secondaryText;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _lockedToModule
              ? '${_moduleLabel(_selectedModule)} Categories'
              : 'Manage Categories',
        ),
        backgroundColor: _lockedToModule
            ? _moduleColor(_selectedModule)
            : AppTheme.headerGreen,
      ),
      body: Column(
        children: [
          // Add category section
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add New Category',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        maxLength: 30,
                        decoration: InputDecoration(
                          hintText: 'Category name',
                          counterText: '',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        onSubmitted: (_) => _addCategory(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _addCategory,
                      icon: const Icon(Icons.add_circle, size: 32),
                      color: AppTheme.primaryGreen,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Module selector chips (hidden when locked to one module)
                if (!_lockedToModule)
                  Row(
                    children: [
                      const Text(
                        'For: ',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(width: 4),
                      _moduleChip('all', 'Both'),
                      const SizedBox(width: 6),
                      _moduleChip('task', 'Task'),
                      const SizedBox(width: 6),
                      _moduleChip('sales', 'Sales'),
                      const SizedBox(width: 6),
                      _moduleChip('crm', 'CRM'),
                    ],
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Categories list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _categories.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.category_outlined,
                          size: 64,
                          color: AppTheme.lightText,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No categories yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Add categories above to organize your tasks & enquiries',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.lightText,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16),
                    itemBuilder: (context, index) {
                      final cat = _categories[index];
                      final module = cat['module'] as String;
                      return ListTile(
                        leading: Icon(
                          Icons.label_outline,
                          color: _moduleColor(module),
                        ),
                        title: Text(
                          cat['name'] as String,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          _moduleLabel(module),
                          style: TextStyle(
                            fontSize: 11,
                            color: _moduleColor(module),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _editCategory(cat),
                              color: AppTheme.secondaryText,
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () =>
                                  _deleteCategory(cat['id'] as String),
                              color: Colors.red,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _moduleChip(String value, String label) {
    final isSelected = _selectedModule == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedModule = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? _moduleColor(value).withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _moduleColor(value) : AppTheme.dividerColor,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected ? _moduleColor(value) : AppTheme.secondaryText,
          ),
        ),
      ),
    );
  }
}
