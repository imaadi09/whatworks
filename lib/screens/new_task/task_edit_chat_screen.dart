import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/task.dart';
import '../../models/task_draft.dart';
import '../../models/message.dart';
import '../../models/milestone.dart';
import '../../providers/task_provider.dart';
import '../../services/contact_picker_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';

class TaskEditChatScreen extends StatefulWidget {
  final TaskModel task;

  const TaskEditChatScreen({super.key, required this.task});

  @override
  State<TaskEditChatScreen> createState() => _TaskEditChatScreenState();
}

class _TaskEditChatScreenState extends State<TaskEditChatScreen> {
  final List<ConversationMessage> _messages = [];
  late TaskDraft _draft;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showChips = false;
  List<Widget>? _chips;
  bool _isSaving = false;
  bool _hasChanges = false;

  // Track which fields have been edited
  final Map<TaskDraftStep, bool> _editedFields = {};

  // Milestones
  late List<MilestoneModel> _milestones;

  @override
  void initState() {
    super.initState();
    // Initialize milestones from task
    _milestones = List.from(widget.task.milestones);
    
    // Initialize draft with existing task values
    _draft = TaskDraft(
      assignedTo: widget.task.assignedTo,
      assigneeUid: widget.task.assignedToUid,
      assigneePhone: widget.task.extraFields?['assigneePhone'],
      assigneeIsOnApp: widget.task.extraFields?['assigneeIsOnApp'] ?? true,
      title: widget.task.title,
      description: widget.task.description,
      deadline: widget.task.deadline,
      priority: widget.task.priority,
      isUrgent: widget.task.isUrgent,
      progress: widget.task.progress.toInt(),
      currentStep: TaskDraftStep.enteringTitle,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startEditFlow();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _startEditFlow() {
    _messages.add(
      ConversationMessage(
        isSystem: true,
        text: '✏️ Editing Task',
        step: TaskDraftStep.assigneeSelected,
        canEdit: true,
      ),
    );
    _messages.add(
      ConversationMessage(
        isSystem: true,
        text:
            '👤 Assigned to: ${widget.task.assignedTo}\nSelect new assignee from contacts:',
        canEdit: true,
      ),
    );
    _scrollToBottom();

    // Automatically open contact picker for assignee selection
    _draft.currentStep = TaskDraftStep.assigneeSelected;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _openContactPickerForAssignee();
      }
    });
  }

  void _openContactPickerForAssignee() async {
    final contactPicker = ContactPickerService();
    final contact = await contactPicker.showContactPicker(context);

    if (contact != null && mounted) {
      // Check if the selected contact is the same as current assignee
      if (contact.name == widget.task.assignedTo) {
        setState(() {
          _messages.add(
            ConversationMessage(
              isSystem: true,
              text:
                  'Same assignee selected. Keeping ${widget.task.assignedTo}.',
              step: TaskDraftStep.assigneeSelected,
              canEdit: true,
            ),
          );
        });
        _scrollToBottom();
      } else {
        setState(() {
          _draft.assignedTo = contact.name;
          _draft.assigneeUid = contact.uid;
          _draft.assigneePhone = contact.phone;
          _draft.assigneeIsOnApp = contact.isOnApp;
          _editedFields[TaskDraftStep.assigneeSelected] = true;
          _hasChanges = true;
        });

        _messages.add(
          ConversationMessage(
            isSystem: false,
            text: contact.name,
            step: TaskDraftStep.assigneeSelected,
          ),
        );
        _scrollToBottom();

        _messages.add(
          ConversationMessage(
            isSystem: true,
            text:
                '✅ Assignee changed: "${widget.task.assignedTo}" → "${contact.name}"',
            step: TaskDraftStep.assigneeSelected,
          ),
        );
        _scrollToBottom();
      }

      // Continue to title editing
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _messages.add(
            ConversationMessage(
              isSystem: false,
              text: widget.task.title,
              step: TaskDraftStep.enteringTitle,
            ),
          );
          _scrollToBottom();
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) _promptTitle();
          });
        }
      });
    } else {
      // User cancelled contact picker - keep current assignee and continue
      if (mounted) {
        _messages.add(
          ConversationMessage(
            isSystem: true,
            text: 'Keeping current assignee: ${widget.task.assignedTo}',
            step: TaskDraftStep.assigneeSelected,
            canEdit: true,
          ),
        );
        _scrollToBottom();

        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _messages.add(
              ConversationMessage(
                isSystem: false,
                text: widget.task.title,
                step: TaskDraftStep.enteringTitle,
              ),
            );
            _scrollToBottom();
            Future.delayed(const Duration(milliseconds: 200), () {
              if (mounted) _promptTitle();
            });
          }
        });
      }
    }
  }

  void _promptTitle() {
    _draft.currentStep = TaskDraftStep.enteringTitle;
    final currentValue = _draft.title;
    _prompt(
      TaskDraftStep.enteringTitle,
      'Title: "$currentValue"\nType new title or "keep":',
    );
  }

  void _promptDescription() {
    _draft.currentStep = TaskDraftStep.enteringDescription;
    final currentValue = _draft.description.isEmpty
        ? '(none)'
        : _draft.description;
    _prompt(
      TaskDraftStep.enteringDescription,
      'Description: "$currentValue"\nType new description or "keep"/"skip":',
    );
  }

  void _promptDeadline() {
    _draft.currentStep = TaskDraftStep.enteringDeadline;
    final currentValue = _draft.deadline != null
        ? Helpers.formatDeadlineBadge(_draft.deadline)
        : '(not set)';
    _prompt(
      TaskDraftStep.enteringDeadline,
      'Deadline: $currentValue\nChoose new deadline:',
    );
    _showDeadlineChips();
  }

  void _promptPriority() {
    _draft.currentStep = TaskDraftStep.enteringPriority;
    String currentValue;
    switch (_draft.priority) {
      case 1:
        currentValue = 'L - Low';
        break;
      case 2:
        currentValue = 'M - Mid';
        break;
      case 3:
        currentValue = widget.task.priority == 3 ? 'High' : 'Normal';
        break;
      default:
        currentValue = 'M - Mid';
    }
    _prompt(
      TaskDraftStep.enteringPriority,
      'Priority: $currentValue\nChoose new priority:',
    );
    _showPriorityChips();
  }

  void _promptUrgency() {
    _draft.currentStep = TaskDraftStep.enteringUrgency;
    final currentValue = _draft.isUrgent ? 'Yes 🔥' : 'No';
    _prompt(
      TaskDraftStep.enteringUrgency,
      'Urgent: $currentValue\nMark as urgent?',
    );
    _showUrgencyChips();
  }

  void _promptProgress() {
    _draft.currentStep = TaskDraftStep.enteringProgress;
    final currentValue = _draft.progress;
    _prompt(
      TaskDraftStep.enteringProgress,
      'Progress: $currentValue%\nSelect new progress or "Keep":',
    );
    // Show progress chips
    _showProgressChips();
  }

  void _showProgressChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('0%', () => _setProgress(0)),
        _chip('25%', () => _setProgress(25)),
        _chip('50%', () => _setProgress(50)),
        _chip('75%', () => _setProgress(75)),
        _chip('100% ✓', () => _setProgress(100)),
        _chip('📋 Milestones', () {
          _chipResponse('Using Milestones');
          _showMilestonesUI();
        }),
        _chip('Keep', () {
          _chipResponse('Keep ($currentProgress%)');
          _promptConfirm();
        }),
      ];
    });
  }

  int get currentProgress => _draft.progress;

  void _setProgress(int value) {
    _draft.progress = value;
    _chipResponse('$value%');
    _editedFields[TaskDraftStep.enteringProgress] = true;
    _hasChanges = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptConfirm();
    });
  }

  // Show milestones with checkboxes
  void _showMilestonesUI() {
    final completedCount = _milestones.where((m) => m.isCompleted).length;
    final totalCount = _milestones.length;

    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: true,
          text: '📋 Milestones ($completedCount/$totalCount completed)\nTap ✓ to mark complete, + to add (max 5):',
          canEdit: true,
        ),
      );
      _showChips = true;
      _chips = _buildMilestoneChips();
    });
    _scrollToBottom();
  }

  List<Widget> _buildMilestoneChips() {
    final chips = <Widget>[];

    // Add existing milestones
    for (int i = 0; i < _milestones.length; i++) {
      final milestone = _milestones[i];
      chips.add(
        _chip(
          '${milestone.isCompleted ? '✅' : '⬜'} ${milestone.title}',
          () => _toggleMilestone(i),
        ),
      );
    }

    // Add button if less than 5
    if (_milestones.length < 5) {
      chips.add(
        _chip(
          '+ Add Milestone',
          _addMilestone,
        ),
      );
    }

    // Delete button if milestones exist
    if (_milestones.isNotEmpty) {
      chips.add(
        _chip(
          '🗑 Delete Last',
          _deleteLastMilestone,
        ),
      );
    }

    // Done button
    chips.add(
      _chip(
        'Done ✓',
        () {
          // Update progress based on milestones
          final completedCount = _milestones.where((m) => m.isCompleted).length;
          final totalCount = _milestones.length;
          if (totalCount > 0) {
            _draft.progress = (completedCount / totalCount * 100).round();
            _editedFields[TaskDraftStep.enteringProgress] = true;
            _hasChanges = true;
          }
          _chipResponse('Milestones saved');
          Future.delayed(const Duration(milliseconds: 200), () {
            _promptConfirm();
          });
        },
      ),
    );

    return chips;
  }

  void _toggleMilestone(int index) {
    setState(() {
      _milestones[index] = _milestones[index].copyWith(
        isCompleted: !_milestones[index].isCompleted,
        completedAt: !_milestones[index].isCompleted ? DateTime.now() : null,
      );
      _hasChanges = true;
    });

    // Refresh UI
    _showMilestonesUI();
  }

  void _addMilestone() {
    _showChips = false;
    
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Milestone'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Milestone Title',
            hintText: 'e.g., Design Complete',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final title = controller.text.trim();
              if (title.isNotEmpty) {
                _addMilestoneWithName(title);
              }
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _deleteLastMilestone() {
    if (_milestones.isEmpty) return;

    setState(() {
      _milestones.removeLast();
      _hasChanges = true;
    });

    _showMilestonesUI();
  }

  void _addMilestoneWithName(String name) {
    if (_milestones.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 5 milestones allowed')),
      );
      return;
    }

    setState(() {
      _milestones.add(
        MilestoneModel(
          id: Helpers.generateId(),
          title: name,
          createdAt: DateTime.now(),
        ),
      );
      _hasChanges = true;
    });

    _showMilestonesUI();
  }

  void _promptConfirm() {
    _draft.currentStep = TaskDraftStep.complete;
    final cancelNote = _isCurrentUserAssigner
        ? '\n(You can cancel this task as the assigner)'
        : '\n(Only the assigner can cancel this task)';
    _prompt(
      TaskDraftStep.complete,
      _hasChanges ? 'Save changes? $cancelNote' : 'No changes made.$cancelNote',
    );
    if (_hasChanges) {
      _showConfirmChips();
    } else {
      _showCancelTaskChip();
    }
  }

  void _prompt(TaskDraftStep step, String text) {
    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: true,
          text: text,
          step: step,
          canEdit: true,
        ),
      );
      _showChips = false;
      _chips = null;
    });
    _scrollToBottom();
  }

  void _userResponse(String text) {
    if (text.trim().isEmpty) return;

    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: false,
          text: text.trim(),
          step: _draft.currentStep,
        ),
      );
      _inputController.clear();
      _showChips = false;
      _chips = null;
    });
    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 200), () {
      _advanceStep(text.trim());
    });
  }

  void _chipResponse(String text) {
    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: false,
          text: text,
          step: _draft.currentStep,
        ),
      );
      _showChips = false;
      _chips = null;
    });
    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 200), () {
      _advanceStep(text);
    });
  }

  void _advanceStep(String input) {
    final step = _draft.currentStep;

    switch (step) {
      case TaskDraftStep.assigneeSelected:
        // Contact picker was auto-opened in _startEditFlow
        // If user types anything, just continue to title
        _messages.add(
          ConversationMessage(
            isSystem: true,
            text: 'Keeping current assignee: ${widget.task.assignedTo}',
            step: TaskDraftStep.assigneeSelected,
          ),
        );
        _scrollToBottom();
        Future.delayed(const Duration(milliseconds: 300), () {
          _messages.add(
            ConversationMessage(
              isSystem: false,
              text: widget.task.title,
              step: TaskDraftStep.enteringTitle,
            ),
          );
          _scrollToBottom();
          Future.delayed(const Duration(milliseconds: 200), () {
            _promptTitle();
          });
        });
        break;

      case TaskDraftStep.enteringTitle:
        if (input.toLowerCase() != 'keep') {
          if (input.trim().isNotEmpty) {
            _draft.title = input.trim();
            _editedFields[TaskDraftStep.enteringTitle] = true;
            _hasChanges = true;
          }
        }
        if (widget.task.description.isNotEmpty ||
            _draft.description.isNotEmpty) {
          _promptDescription();
        } else {
          _promptDeadline();
        }
        break;

      case TaskDraftStep.enteringDescription:
        if (input.toLowerCase() != 'keep' && input.toLowerCase() != 'skip') {
          _draft.description = input.trim();
          _editedFields[TaskDraftStep.enteringDescription] = true;
          _hasChanges = true;
        }
        _promptDeadline();
        break;

      case TaskDraftStep.enteringDeadline:
      case TaskDraftStep.enteringPriority:
      case TaskDraftStep.enteringUrgency:
        // Handled by chips
        break;

      case TaskDraftStep.enteringProgress:
        if (input.toLowerCase() != 'keep') {
          final progressValue = int.tryParse(input.trim());
          if (progressValue != null &&
              progressValue >= 0 &&
              progressValue <= 100) {
            _draft.progress = progressValue;
            _editedFields[TaskDraftStep.enteringProgress] = true;
            _hasChanges = true;
          } else {
            _prompt(
              TaskDraftStep.enteringProgress,
              'Please enter a number between 0-100 or "keep":',
            );
            return;
          }
        }
        _promptConfirm();
        break;

      default:
        break;
    }
  }

  void _setDeadline(int days) {
    // Calculate deadline from task START DATE (not current deadline)
    final startDate = _draft.startDate ?? widget.task.startDate ?? DateTime.now();
    final baseDate = startDate;
    
    // Set deadline to the end of the day (11:59 PM) - consistent with task creation
    _draft.deadline = DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day + days,
      23, // 11:59 PM (end of day)
      59,
    );
    
    // Validate: deadline must be after start date
    if (_draft.deadline!.isBefore(startDate)) {
      _draft.deadline = DateTime(
        startDate.year,
        startDate.month,
        startDate.day + days,
        23,
        59,
      );
    }
    
    _chipResponse(
      '${days == 1 ? '1 Day' : '$days Days'} from ${DateFormat('MMM dd').format(startDate)} (${Helpers.formatDeadline(_draft.deadline!)})',
    );
    _editedFields[TaskDraftStep.enteringDeadline] = true;
    _hasChanges = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptPriority();
    });
  }

  void _keepDeadline() {
    _chipResponse(
      'Keep current (${_draft.deadline != null ? Helpers.formatDeadlineBadge(_draft.deadline) : 'not set'})',
    );
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptPriority();
    });
  }

  // Compact date-time picker without full calendar
  Future<DateTime?> _showCompactDateTimePicker({
    required DateTime initialDate,
    String title = 'Select Date & Time',
    bool allowDateOnly = true,  // New parameter to allow date-only selection
  }) async {
    int selectedDay = initialDate.day;
    int selectedMonth = initialDate.month;
    int selectedYear = initialDate.year;
    int selectedHour = 9;
    int selectedMinute = 0;
    bool addTime = false;  // Default to date-only

    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return showDialog<DateTime>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Date selection row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildNumberPicker('Day', selectedDay, 1, 31, (val) {
                        setDialogState(() => selectedDay = val);
                      }),
                      _buildNumberPicker(
                        'Month',
                        selectedMonth,
                        1,
                        12,
                        (val) {
                          setDialogState(() => selectedMonth = val);
                        },
                        displayFormatter: (val) => months[val - 1],
                      ),
                      _buildNumberPicker(
                        'Year',
                        selectedYear,
                        DateTime.now().year,
                        DateTime.now().year + 1,
                        (val) {
                          setDialogState(() => selectedYear = val);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  
                  // Date Only / Add Time toggle
                  if (allowDateOnly)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: addTime ? AppTheme.primaryGreen.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: addTime,
                            onChanged: (val) {
                              setDialogState(() => addTime = val ?? false);
                            },
                            activeColor: AppTheme.primaryGreen,
                          ),
                          Expanded(
                            child: Text(
                              addTime ? 'Add specific time' : 'Date only (end of day)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: addTime ? AppTheme.primaryGreen : AppTheme.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  
                  // Time selection row (only shown if addTime is true)
                  if (addTime) ...[
                    const SizedBox(height: 8),
                    const Divider(),
                    const SizedBox(height: 8),
                    // Time selection row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNumberPicker('Hour', selectedHour, 1, 12, (val) {
                          setDialogState(() => selectedHour = val);
                        }),
                        _buildNumberPicker('Min', selectedMinute, 0, 59, (val) {
                          setDialogState(() => selectedMinute = val);
                        }, step: 5),
                        _buildAmPmPicker(selectedHour >= 12, (isPM) {
                          setDialogState(() {
                            if (isPM && selectedHour < 12) selectedHour += 12;
                            if (!isPM && selectedHour >= 12) selectedHour -= 12;
                          });
                        }),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  DateTime result;
                  if (addTime) {
                    // User selected specific time
                    result = DateTime(
                      selectedYear,
                      selectedMonth,
                      selectedDay,
                      selectedHour,
                      selectedMinute,
                    );
                  } else {
                    // Date only - set to end of day (11:59 PM)
                    result = DateTime(
                      selectedYear,
                      selectedMonth,
                      selectedDay,
                      23,
                      59,
                    );
                  }
                  Navigator.pop(ctx, result);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Select'),
              ),
            ],
          );
        },
      ),
    );
  }

  // Build compact number picker
  Widget _buildNumberPicker(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    int step = 1,
    String Function(int)? displayFormatter,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.secondaryText),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 20),
              onPressed: value > min
                  ? () => onChanged(value - step < min ? min : value - step)
                  : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            SizedBox(
              width: 50,
              child: Text(
                displayFormatter?.call(value) ??
                    value.toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              onPressed: value < max
                  ? () => onChanged(value + step > max ? max : value + step)
                  : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ],
    );
  }

  // Build AM/PM picker
  Widget _buildAmPmPicker(bool isPM, ValueChanged<bool> onChanged) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Period',
          style: TextStyle(fontSize: 11, color: AppTheme.secondaryText),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChoiceChip(
              label: const Text('AM', style: TextStyle(fontSize: 12)),
              selected: !isPM,
              onSelected: (_) => onChanged(false),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            ),
            const SizedBox(width: 4),
            ChoiceChip(
              label: const Text('PM', style: TextStyle(fontSize: 12)),
              selected: isPM,
              onSelected: (_) => onChanged(true),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            ),
          ],
        ),
      ],
    );
  }

  void _setCustomDeadline() async {
    final picked = await _showCompactDateTimePicker(
      initialDate:
          _draft.deadline ?? DateTime.now().add(const Duration(days: 7)),
      title: 'Set Deadline',
    );
    if (picked != null) {
      _draft.deadline = picked;
      _chipResponse(Helpers.formatDeadline(picked));
      _editedFields[TaskDraftStep.enteringDeadline] = true;
      _hasChanges = true;
      Future.delayed(const Duration(milliseconds: 200), () {
        _promptPriority();
      });
    }
  }

  void _setPriority(int priority) {
    _draft.priority = priority;
    String priorityLabel;
    switch (priority) {
      case 1:
        priorityLabel = 'L - Low';
        break;
      case 2:
        priorityLabel = 'M - Mid';
        break;
      case 3:
        priorityLabel = 'H - High';
        break;
      default:
        priorityLabel = 'M - Mid';
    }
    _chipResponse(priorityLabel);
    _editedFields[TaskDraftStep.enteringPriority] = true;
    _hasChanges = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptUrgency();
    });
  }

  void _setUrgency(bool urgent) {
    _draft.isUrgent = urgent;
    _chipResponse(urgent ? 'Yes 🔥' : 'No');
    _editedFields[TaskDraftStep.enteringUrgency] = true;
    _hasChanges = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptProgress();
    });
  }

  void _saveChanges() {
    setState(() {
      _isSaving = true;
    });

    // Create updated task
    final updatedTask = widget.task.copyWith(
      assignedTo: _draft.assignedTo,
      assignedToUid: _draft.assigneeUid,
      assignedToPhone: Helpers.normalizePhone(_draft.assigneePhone),
      title: _draft.title,
      description: _draft.description,
      deadline: _draft.deadline,
      priority: _draft.priority,
      isUrgent: _draft.isUrgent,
      progress: _draft.progress.toDouble(),
      milestones: _milestones,
      updatedAt: DateTime.now(),
      extraFields: {
        ...?widget.task.extraFields,
        if (_draft.assigneePhone != null)
          'assigneePhone': Helpers.normalizePhone(_draft.assigneePhone) ?? _draft.assigneePhone,
        'assigneeIsOnApp': _draft.assigneeIsOnApp,
      },
    );

    // Build change summary
    final changes = <String>[];
    if (_editedFields[TaskDraftStep.assigneeSelected] == true) {
      changes.add(
        '👤 Assignee: "${widget.task.assignedTo}" → "${_draft.assignedTo}"',
      );
    }
    if (_editedFields[TaskDraftStep.enteringTitle] == true) {
      changes.add('Title: "${widget.task.title}" → "${_draft.title}"');
    }
    if (_editedFields[TaskDraftStep.enteringDescription] == true) {
      changes.add('Description updated');
    }
    if (_editedFields[TaskDraftStep.enteringDeadline] == true) {
      final oldDeadline = widget.task.deadline != null
          ? Helpers.formatDeadlineBadge(widget.task.deadline)
          : 'not set';
      final newDeadline = _draft.deadline != null
          ? Helpers.formatDeadlineBadge(_draft.deadline)
          : 'not set';
      changes.add('Deadline: $oldDeadline → $newDeadline');
    }
    if (_editedFields[TaskDraftStep.enteringPriority] == true) {
      final oldPriority = widget.task.priority == 2 ? 'Mid' : 'High';
      final newPriority = _draft.priority == 2 ? 'Mid' : 'High';
      changes.add('Priority: $oldPriority → $newPriority');
    }
    if (_editedFields[TaskDraftStep.enteringUrgency] == true) {
      changes.add(
        'Urgent: ${widget.task.isUrgent ? 'Yes' : 'No'} → ${_draft.isUrgent ? 'Yes' : 'No'}',
      );
    }
    if (_editedFields[TaskDraftStep.enteringProgress] == true) {
      changes.add(
        'Progress: ${widget.task.progress.toInt()}% → ${_draft.progress}%',
      );
    }
    if (_milestones.length != widget.task.milestones.length ||
        _milestones.where((m) => m.isCompleted).length != 
        widget.task.milestones.where((m) => m.isCompleted).length) {
      final completedCount = _milestones.where((m) => m.isCompleted).length;
      changes.add(
        'Milestones: $completedCount/${_milestones.length} completed',
      );
    }

    final changeSummary = changes.join('\n');

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _messages.add(
            ConversationMessage(
              isSystem: true,
              text:
                  '✅ Task updated successfully!\n\nChanges made:\n$changeSummary',
              step: TaskDraftStep.complete,
            ),
          );
        });
        _scrollToBottom();

        // Pop back to task detail with updated task
        Future.delayed(const Duration(milliseconds: 2000), () {
          if (mounted) {
            Navigator.pop(context, updatedTask);
          }
        });
      }
    });
  }

  void _cancelEdit() {
    Navigator.pop(context);
  }

  void _editField(TaskDraftStep step) {
    _draft.currentStep = step;

    // Remove messages from this step onwards
    int removeIndex = -1;
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].step == step && _messages[i].isSystem) {
        removeIndex = i;
        break;
      }
    }

    if (removeIndex >= 0) {
      setState(() {
        _messages.removeRange(removeIndex, _messages.length);
      });
    }

    _prompt(step, _getEditPromptText(step));

    // Reset field to allow re-entry
    switch (step) {
      case TaskDraftStep.enteringTitle:
        _draft.title = '';
        break;
      case TaskDraftStep.enteringDescription:
        _draft.description = '';
        break;
      case TaskDraftStep.enteringDeadline:
        _draft.deadline = null;
        Future.delayed(const Duration(milliseconds: 300), () {
          _showDeadlineChips();
        });
        break;
      case TaskDraftStep.enteringPriority:
        Future.delayed(const Duration(milliseconds: 300), () {
          _showPriorityChips();
        });
        break;
      case TaskDraftStep.enteringUrgency:
        Future.delayed(const Duration(milliseconds: 300), () {
          _showUrgencyChips();
        });
        break;
      case TaskDraftStep.enteringProgress:
        Future.delayed(const Duration(milliseconds: 300), () {
          _showProgressChips();
        });
        break;
      default:
        break;
    }
  }

  String _getEditPromptText(TaskDraftStep step) {
    switch (step) {
      case TaskDraftStep.enteringTitle:
        return '✏️ Editing Title. Type new value:';
      case TaskDraftStep.enteringDescription:
        return '✏️ Editing Description. Type new value:';
      case TaskDraftStep.enteringDeadline:
        return '✏️ Editing Deadline. Choose new deadline:';
      case TaskDraftStep.enteringPriority:
        return '✏️ Editing Priority. Choose new priority:';
      case TaskDraftStep.enteringUrgency:
        return '✏️ Editing Urgency. Mark as urgent?';
      case TaskDraftStep.enteringProgress:
        return '✏️ Editing Progress (${_draft.progress}%). Select new progress:';
      default:
        return '✏️ Editing ${_draft.getStepName(step)}. Type new value:';
    }
  }

  void _showDeadlineChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('1 Day', () => _setDeadline(1)),
        _chip('3 Days', () => _setDeadline(3)),
        _chip('1 Week', () => _setDeadline(7)),
        _chip('15 Days', () => _setDeadline(15)),
        _chip('Custom', _setCustomDeadline),
        _chip('Keep', _keepDeadline),
      ];
    });
  }

  void _showPriorityChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('L - Low', () => _setPriority(1)),
        _chip('M - Mid', () => _setPriority(2)),
        _chip('H - High', () => _setPriority(3)),
      ];
    });
  }

  void _showUrgencyChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('Yes 🔥', () => _setUrgency(true)),
        _chip('No', () => _setUrgency(false)),
      ];
    });
  }

  /// Check if current user is the task assigner (creator)
  bool get _isCurrentUserAssigner {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return widget.task.createdBy == uid;
  }

  void _showConfirmChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('Save ✓', _saveChanges),
        // Only assigner can cancel task
        if (_isCurrentUserAssigner) _chip('Cancel Task ❌', _cancelTask),
        _chip('Discard Edit', _cancelEdit),
      ];
    });
  }

  void _showCancelTaskChip() {
    setState(() {
      _showChips = true;
      _chips = [
        // Only assigner can cancel task
        if (_isCurrentUserAssigner) _chip('Cancel Task ❌', _cancelTask),
        _chip('Close', _cancelEdit),
      ];
    });
  }

  void _cancelTask() async {
    setState(() {
      _isSaving = true;
    });

    // Mark task as closed/canceled
    final updatedTask = widget.task.copyWith(
      isClosed: true,
      updatedAt: DateTime.now(),
    );

    try {
      final taskProvider = context.read<TaskProvider>();
      await taskProvider.updateTask(widget.task.id, updatedTask);

      // Add system message
      final systemMsg = MessageModel(
        id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
        taskId: widget.task.id,
        senderId: 'system',
        text:
            '❌ Task canceled by ${FirebaseAuth.instance.currentUser?.displayName ?? 'user'}',
        type: MessageType.system,
        createdAt: DateTime.now(),
      );
      await taskProvider.sendMessage(widget.task.id, systemMsg);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Task canceled successfully'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate task was closed
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error canceling task: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Widget _chip(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreen.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.3)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.headerGreen,
            ),
          ),
        ),
      ),
    );
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSubmitted(String text) {
    _userResponse(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.chatCanvas(context),
      appBar: AppBar(
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (!_hasChanges) {
              Navigator.pop(context);
            } else {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  title: const Text('Discard Changes?'),
                  content: const Text(
                    'Are you sure you want to discard your changes?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Discard'),
                    ),
                  ],
                ),
              );
            }
          },
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white.withOpacity(0.2),
              child: const Icon(Icons.edit, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Edit Task',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    widget.task.assignedTo,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Chat messages area
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message, index);
              },
            ),
          ),

          // Chips area (when applicable)
          if (_showChips && _chips != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                color: AppTheme.lightGrey,
                child: SingleChildScrollView(
                  child: Wrap(spacing: 0, runSpacing: 0, children: _chips!),
                ),
              ),
            ),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ConversationMessage message, int index) {
    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: InkWell(
            onTap: message.canEdit && message.step != null
                ? () => _editField(message.step!)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.systemMessageBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message.text,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.secondaryText,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (message.canEdit && message.step != null) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.edit,
                      size: 12,
                      color: AppTheme.headerGreen.withOpacity(0.6),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    // User message (pre-filled or new value)
    final isEdited = _editedFields[message.step] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isEdited
                  ? Colors.orange.withOpacity(0.2)
                  : AppTheme.chatBubbleGreen,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEdited)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'EDITED',
                          style: TextStyle(
                            fontSize: 8,
                            color: Colors.orange,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        message.text,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('HH:mm').format(message.createdAt),
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.lightText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final showInput =
        !_showChips && _draft.currentStep != TaskDraftStep.complete;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: AppTheme.lightGrey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showInput) ...[
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _inputController,
                  decoration: InputDecoration(
                    hintText: _getInputHint(),
                    hintStyle: const TextStyle(
                      color: AppTheme.secondaryText,
                      fontSize: 15,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _handleSubmitted,
                ),
              ),
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              radius: 24,
              backgroundColor: _inputController.text.trim().isEmpty
                  ? AppTheme.secondaryText.withOpacity(0.3)
                  : AppTheme.primaryGreen,
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: _inputController.text.trim().isEmpty
                    ? null
                    : () => _handleSubmitted(_inputController.text),
              ),
            ),
          ] else if (_draft.currentStep == TaskDraftStep.complete &&
              !_hasChanges)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: const Text(
                  'No changes made. Tap back to exit.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.secondaryText,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }

  String _getInputHint() {
    switch (_draft.currentStep) {
      case TaskDraftStep.enteringTitle:
        return 'Enter new title or "keep"...';
      case TaskDraftStep.enteringDescription:
        return 'Enter new description or "keep"/"skip"...';
      default:
        return 'Type a message...';
    }
  }
}
