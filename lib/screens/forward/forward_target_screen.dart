import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/task.dart';
import '../../providers/task_provider.dart';
import '../../providers/auth_provider.dart';
import '../../modules/sales/models/enquiry.dart';
import '../../modules/sales/providers/sales_provider.dart';
import '../../utils/constants.dart';

/// Represents a target conversation for forwarding a message.
class ForwardTarget {
  final String id;
  final String type; // 'task' or 'enquiry'
  final String title;
  final String subtitle;

  const ForwardTarget({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle = '',
  });
}

/// WhatsApp-style forward target selection screen.
/// Shows both tasks and sales enquiries with search and multi-select.
/// Returns List<ForwardTarget> when user confirms.
class ForwardTargetScreen extends StatefulWidget {
  final String sourceParentId; // Exclude current conversation

  const ForwardTargetScreen({super.key, required this.sourceParentId});

  @override
  State<ForwardTargetScreen> createState() => _ForwardTargetScreenState();
}

class _ForwardTargetScreenState extends State<ForwardTargetScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _selectedIds = {}; // key: "task:{id}" or "enquiry:{id}"

  late TabController _tabController;
  int _currentTabIndex = 0; // 0 = By Me, 1 = To Me

  List<TaskModel> _byMeTasks = [];
  List<TaskModel> _toMeTasks = [];
  List<EnquiryModel> _allEnquiries = [];
  String _currentUserId = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() => _currentTabIndex = _tabController.index);
    });
    _loadData();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _loadData() {
    final taskProvider = context.read<TaskProvider>();
    final salesProvider = context.read<SalesProvider>();
    final authProvider = context.read<AuthProvider>();
    _currentUserId = authProvider.userModel?.uid ?? '';

    final byMe = <TaskModel>[];
    final toMe = <TaskModel>{};

    // Categorize tasks
    for (final t in taskProvider.byMeTasks) {
      if (t.id == widget.sourceParentId) continue;
      byMe.add(t);
    }
    for (final t in taskProvider.toMeTasks) {
      if (t.id == widget.sourceParentId) continue;
      if (!byMe.any((bt) => bt.id == t.id)) {
        toMe.add(t);
      }
    }
    // Also check participant tasks
    for (final t in taskProvider.participantTasks) {
      if (t.id == widget.sourceParentId) continue;
      if (t.createdBy == _currentUserId) {
        if (!byMe.any((bt) => bt.id == t.id)) byMe.add(t);
      } else {
        if (!toMe.any((tt) => tt.id == t.id) &&
            !byMe.any((bt) => bt.id == t.id)) {
          toMe.add(t);
        }
      }
    }

    // Filter enquiries — exclude current conversation
    final enquiries = salesProvider.enquiries
        .where((e) => e.id != widget.sourceParentId)
        .toList();

    setState(() {
      // Order pickers by last activity (same key the cards display)
      _byMeTasks = byMe
        ..sort(
          (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
            a.lastMessageTime ?? a.updatedAt,
          ),
        );
      _toMeTasks = toMe.toList()
        ..sort(
          (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
            a.lastMessageTime ?? a.updatedAt,
          ),
        );
      _allEnquiries = enquiries
        ..sort(
          (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
            a.lastMessageTime ?? a.updatedAt,
          ),
        );
    });
  }

  List<TaskModel> get _currentTabTasks {
    final tasks = _currentTabIndex == 0 ? _byMeTasks : _toMeTasks;
    if (_searchQuery.isEmpty) return tasks;
    return tasks.where((t) {
      final title = t.title.toLowerCase();
      final desc = t.description.toLowerCase();
      final name = (t.createdByName ?? '').toLowerCase();
      final assignee = t.assignedTo.toLowerCase();
      return title.contains(_searchQuery) ||
          desc.contains(_searchQuery) ||
          name.contains(_searchQuery) ||
          assignee.contains(_searchQuery);
    }).toList();
  }

  List<EnquiryModel> get _filteredEnquiries {
    if (_searchQuery.isEmpty) return _allEnquiries;
    return _allEnquiries.where((e) {
      final client = e.clientName.toLowerCase();
      final title = e.title.toLowerCase();
      return client.contains(_searchQuery) || title.contains(_searchQuery);
    }).toList();
  }

  String _taskKey(String id) => 'task:$id';
  String _enquiryKey(String id) => 'enquiry:$id';

  bool _isSelected(String key) => _selectedIds.contains(key);

  void _toggle(String key) {
    setState(() {
      if (_selectedIds.contains(key)) {
        _selectedIds.remove(key);
      } else {
        _selectedIds.add(key);
      }
    });
  }

  List<ForwardTarget> _buildResult() {
    final allTasks = [..._byMeTasks, ..._toMeTasks];
    final targets = <ForwardTarget>[];
    for (final key in _selectedIds) {
      final parts = key.split(':');
      final type = parts[0];
      final id = parts.sublist(1).join(':'); // handle ids with colons
      if (type == 'task') {
        final task = allTasks.firstWhere((t) => t.id == id);
        targets.add(
          ForwardTarget(
            id: id,
            type: 'task',
            title: task.title,
            subtitle: task.createdByName ?? '',
          ),
        );
      } else {
        final enquiry = _allEnquiries.firstWhere((e) => e.id == id);
        targets.add(
          ForwardTarget(
            id: id,
            type: 'enquiry',
            title: enquiry.clientName,
            subtitle: enquiry.title,
          ),
        );
      }
    }
    return targets;
  }

  @override
  Widget build(BuildContext context) {
    final filteredTasks = _currentTabTasks;
    final filteredEnquiries = _filteredEnquiries;
    final totalResults = filteredTasks.length + filteredEnquiries.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Forward to...'),
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: AppTheme.primaryText,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.headerGreen,
          indicatorWeight: 3,
          labelColor: AppTheme.headerGreen,
          unselectedLabelColor: AppTheme.secondaryText,
          labelStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          tabs: [
            Tab(text: 'BY ME (${_byMeTasks.length})'),
            Tab(text: 'TO ME (${_toMeTasks.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.white,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search tasks or enquiries...',
                prefixIcon: const Icon(Icons.search, color: AppTheme.lightText),
                filled: true,
                fillColor: AppTheme.lightGrey,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ),

          // Results count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '$totalResults conversation${totalResults == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.lightText,
                  ),
                ),
                if (_selectedIds.isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    '${_selectedIds.length} selected',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.headerGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),

          const Divider(height: 1),

          // List
          Expanded(
            child: totalResults == 0
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 48,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _searchQuery.isEmpty
                              ? 'No conversations available'
                              : 'No results found',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    children: [
                      // Tasks section
                      if (filteredTasks.isNotEmpty) ...[
                        _buildSectionHeader('Tasks', filteredTasks.length),
                        ...filteredTasks.map((task) => _buildTaskTile(task)),
                      ],
                      // Enquiries section
                      if (filteredEnquiries.isNotEmpty) ...[
                        _buildSectionHeader(
                          'Sales Enquiries',
                          filteredEnquiries.length,
                        ),
                        ...filteredEnquiries.map((e) => _buildEnquiryTile(e)),
                      ],
                    ],
                  ),
          ),

          // Bottom action bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => Navigator.pop(context, _buildResult()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.headerGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    _selectedIds.isEmpty
                        ? 'Select conversations'
                        : 'Forward (${_selectedIds.length})',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppTheme.lightGrey.withOpacity(0.5),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTheme.lightText,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(TaskModel task) {
    final key = _taskKey(task.id);
    final selected = _isSelected(key);
    final displayName = task.createdByName ?? task.assignedTo;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => _toggle(key),
      title: Text(
        task.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        displayName,
        style: const TextStyle(fontSize: 12, color: AppTheme.lightText),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      secondary: CircleAvatar(
        radius: 18,
        backgroundColor: AppTheme.headerGreen.withOpacity(0.1),
        child: const Icon(
          Icons.chat_bubble_outline,
          size: 18,
          color: AppTheme.headerGreen,
        ),
      ),
      dense: true,
      controlAffinity: ListTileControlAffinity.trailing,
      activeColor: AppTheme.headerGreen,
    );
  }

  Widget _buildEnquiryTile(EnquiryModel enquiry) {
    final key = _enquiryKey(enquiry.id);
    final selected = _isSelected(key);

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => _toggle(key),
      title: Text(
        enquiry.clientName,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        enquiry.title.isNotEmpty ? enquiry.title : 'Sales Enquiry',
        style: const TextStyle(fontSize: 12, color: AppTheme.lightText),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      secondary: CircleAvatar(
        radius: 18,
        backgroundColor: const Color(0xFF6C5CE7).withOpacity(0.1),
        child: const Icon(
          Icons.shopping_bag_outlined,
          size: 18,
          color: Color(0xFF6C5CE7),
        ),
      ),
      dense: true,
      controlAffinity: ListTileControlAffinity.trailing,
      activeColor: AppTheme.headerGreen,
    );
  }
}
