import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/task.dart';
import '../../models/user.dart';
import '../../models/task_participant.dart';
import '../../providers/auth_provider.dart';
import '../../services/contact_picker_service.dart';
import '../../utils/constants.dart';

class TaskParticipantsDialog extends StatefulWidget {
  final TaskModel task;
  final Function(TaskModel) onTaskUpdated;

  const TaskParticipantsDialog({
    super.key,
    required this.task,
    required this.onTaskUpdated,
  });

  @override
  State<TaskParticipantsDialog> createState() => _TaskParticipantsDialogState();
}

class _TaskParticipantsDialogState extends State<TaskParticipantsDialog> {
  late TaskModel _task;
  late List<String> _participants;
  late List<TaskParticipant> _participantHistory;
  late String _mainAssignee;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
    _participants = List.from(_task.participants);
    _participantHistory = List.from(_task.participantHistory);
    _mainAssignee = _task.assignedTo;

    // If participants is empty, initialize with current assignee
    if (_participants.isEmpty) {
      _participants.add(_mainAssignee);
      final currentUser = context.read<AuthProvider>().userModel;
      final creatorName = currentUser?.name ?? _task.createdBy;
      // Add creator to history
      _participantHistory.add(
        TaskParticipant(
          userId: _task.createdBy,
          userName: creatorName,
          joinedAt: _task.createdAt,
          addedBy: 'system',
          isMainAssignee: false,
        ),
      );
      // Add main assignee to history
      _participantHistory.add(
        TaskParticipant(
          userId: _mainAssignee,
          userName: _mainAssignee,
          joinedAt: _task.createdAt,
          addedBy: creatorName,
          isMainAssignee: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.group, size: 24, color: AppTheme.headerGreen),
                const SizedBox(width: 8),
                const Text(
                  'Task Participants',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.headerGreen,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Main Assignee Section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.headerGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.headerGreen.withOpacity(0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '👤 Main Assignee',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.headerGreen,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _mainAssignee,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _changeMainAssignee,
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Participants List
            Row(
              children: [
                const Text(
                  '👥 Participants',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_participants.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Participants list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _participants.length,
                itemBuilder: (context, index) {
                  final participant = _participants[index];
                  final isMainAssignee = participant == _mainAssignee;
                  final isCreator = participant == _task.createdBy;

                  // Find user details
                  final user = _participants.contains(participant)
                      ? UserModel(
                          uid: participant,
                          name: participant,
                          email: '',
                          phone: '',
                          createdAt: DateTime.now(),
                        )
                      : null;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: isMainAssignee
                          ? AppTheme.headerGreen
                          : AppTheme.lightGrey,
                      child: Text(
                        user?.name.substring(0, 1).toUpperCase() ?? '?',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isMainAssignee
                              ? Colors.white
                              : AppTheme.primaryText,
                        ),
                      ),
                    ),
                    title: Text(
                      participant,
                      style: TextStyle(
                        fontWeight: isMainAssignee
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: Row(
                      children: [
                        if (isMainAssignee)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.headerGreen,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'ASSIGNEE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        if (isCreator) ...[
                          if (isMainAssignee) const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryGreen,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'CREATOR',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: !isCreator
                        ? IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _removeParticipant(participant),
                          )
                        : const Icon(
                            Icons.lock,
                            size: 20,
                            color: AppTheme.lightText,
                          ),
                  );
                },
              ),
            ),

            const Divider(height: 24),

            // Add Participant Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _addParticipant,
                icon: const Icon(Icons.person_add),
                label: const Text('Add Participant'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.headerGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Close button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addParticipant() async {
    // Show contact picker (reuse existing)
    final selectedUser = await _showUserPicker();
    if (selectedUser != null) {
      setState(() {
        if (!_participants.contains(selectedUser.name)) {
          _participants.add(selectedUser.name);
          // Track join in history
          _participantHistory.add(
            TaskParticipant(
              userId: selectedUser.uid,
              userName: selectedUser.name,
              joinedAt: DateTime.now(),
              addedBy: context.read<AuthProvider>().userModel?.name ?? 'user',
              isMainAssignee: false,
            ),
          );
        }
      });
      _saveChanges();
    }
  }

  void _removeParticipant(String participant) {
    if (participant == _mainAssignee) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot remove the main assignee. Change assignee first.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove Participant'),
        content: Text('Remove $participant from this task?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _participants.remove(participant);
                // Mark as left in history (don't delete, just set leftAt)
                final index = _participantHistory.indexWhere(
                  (p) => p.userId == participant && p.leftAt == null,
                );
                if (index != -1) {
                  _participantHistory[index] = _participantHistory[index]
                      .copyWith(leftAt: DateTime.now());
                }
              });
              _saveChanges();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _changeMainAssignee() async {
    final selectedUser = await _showUserPicker();
    if (selectedUser != null) {
      setState(() {
        _mainAssignee = selectedUser.name;
        if (!_participants.contains(selectedUser.name)) {
          _participants.add(selectedUser.name);
        }
      });
      _saveChanges();
    }
  }

  Future<UserModel?> _showUserPicker() async {
    // Load users from Firebase via ContactPickerService
    final contactService = ContactPickerService();
    final contacts = await contactService.getTeamMembers();
    final users = contacts
        .where((c) => c.uid != null)
        .map(
          (c) => UserModel(
            uid: c.uid!,
            name: c.name,
            email: c.email ?? '',
            phone: c.phone ?? '',
            createdAt: DateTime.now(),
          ),
        )
        .toList();

    if (!mounted) return null;

    return showModalBottomSheet<UserModel>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: const Text(
                'Select User',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: users.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No users found'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: users.length,
                      itemBuilder: (context, index) {
                        final user = users[index];
                        final alreadyAdded = _participants.contains(user.name);

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: alreadyAdded
                                ? AppTheme.lightGrey
                                : AppTheme.headerGreen.withOpacity(0.2),
                            child: Text(
                              user.name.substring(0, 1).toUpperCase(),
                              style: TextStyle(
                                color: alreadyAdded
                                    ? AppTheme.lightText
                                    : AppTheme.headerGreen,
                              ),
                            ),
                          ),
                          title: Text(user.name),
                          subtitle: Text(user.email),
                          trailing: alreadyAdded
                              ? const Icon(
                                  Icons.check,
                                  color: AppTheme.primaryGreen,
                                )
                              : null,
                          enabled: !alreadyAdded,
                          onTap: () => Navigator.pop(context, user),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _saveChanges() {
    final updatedTask = _task.copyWith(
      assignedTo: _mainAssignee,
      participants: _participants,
      participantHistory: _participantHistory,
      isGroupTask: _participants.length > 1,
      updatedAt: DateTime.now(),
    );

    widget.onTaskUpdated(updatedTask);
  }
}
