import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/task.dart';
import '../../models/message.dart';
import '../../models/task_draft.dart';
import '../../services/contact_picker_service.dart';
import '../../services/firebase_service.dart';
import '../../services/local_database_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';
import '../../utils/validator.dart';
import '../task_detail/task_detail_screen.dart';

class TaskCreationChatScreen extends StatefulWidget {
  final AssignableContact assignee;

  /// When provided, called instead of navigating away after task creation.
  /// The callback receives the created TaskModel (with real Firestore ID).
  final void Function(TaskModel createdTask)? onTaskCreated;

  /// Called when back is pressed and a draft was saved, so parent can refresh.
  final VoidCallback? onDraftSaved;

  /// Pre-filled text in the input box (e.g. "Hello!" for onboarding drafts).
  final String? initialText;

  /// Show a draft hint caption above the input bar.
  final bool showDraftHint;

  const TaskCreationChatScreen({
    super.key,
    required this.assignee,
    this.onTaskCreated,
    this.onDraftSaved,
    this.initialText,
    this.showDraftHint = false,
  });

  @override
  State<TaskCreationChatScreen> createState() => _TaskCreationChatScreenState();
}

class _TaskCreationChatScreenState extends State<TaskCreationChatScreen> {
  final List<ConversationMessage> _messages = [];
  late TaskDraft _draft;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late FocusNode _inputFocusNode;
  bool _showChips = false;
  List<Widget>? _chips;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode();
    _draft = TaskDraft(
      assignedTo: widget.assignee.name,
      assigneeUid: widget.assignee.uid,
      assigneePhone: widget.assignee.phone,
      assigneeIsOnApp: widget.assignee.isOnApp,
    );
    // Pre-fill input for onboarding drafts
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _inputController.text = widget.initialText!;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputController.text.length),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startConversation();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _startConversation() {
    // Skip the "New Task: [Name]" system message — go straight to title prompt
    _promptTitle();
  }

  void _promptTitle() {
    _draft.currentStep = TaskDraftStep.enteringTitle;
    // Don't show "Task Title:" system bubble — the input hint is enough
    _showChips = false;
    _chips = null;
    _scrollToBottom();

    // Auto-focus the input field
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _inputFocusNode.requestFocus();
      }
    });
  }

  void _promptDeadline() {
    _draft.currentStep = TaskDraftStep.enteringDeadline;
    _prompt(TaskDraftStep.enteringDeadline, 'Deadline (Days/Date):');
    // Show deadline chips above the text box
    Future.delayed(const Duration(milliseconds: 200), () {
      _showDeadlineChips();
    });
  }

  void _promptPriority() {
    // Skip priority - auto-set to Normal (2)
    _draft.priority = 2; // Normal
    _draft.isUrgent = false; // No

    // Don't show urgency message - just move to scheduling
    // Move to scheduling after a delay
    Future.delayed(const Duration(milliseconds: 300), () {
      _promptScheduling();
    });
  }

  void _promptScheduling() {
    _draft.currentStep = TaskDraftStep.scheduling;
    // Don't show system message - just show chips directly
    _showSchedulingChips();
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

    // Auto-focus the input field after a short delay
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _inputFocusNode.requestFocus();
      }
    });
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
      // Refocus input after advancing to next step
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_showChips) {
          _inputFocusNode.requestFocus();
        }
      });
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
      case TaskDraftStep.enteringTitle:
        if (input.isEmpty) {
          _prompt(TaskDraftStep.enteringTitle, 'Task Title:');
          return;
        }

        // Validate and store title
        final titleValidation = AppValidator.validateTitle(input.trim());
        if (!titleValidation.isValid) {
          _prompt(TaskDraftStep.enteringTitle, 'Task Title:');
          return;
        }

        _draft.title = input.trim();

        // Skip description — go directly to deadline
        Future.delayed(const Duration(milliseconds: 200), () {
          _promptDeadline();
        });
        break;

      case TaskDraftStep.enteringDescription:
        // Description step removed — fall through to deadline
        Future.delayed(const Duration(milliseconds: 200), () {
          _promptDeadline();
        });
        break;

      case TaskDraftStep.enteringDeadline:
        // Try to parse date/time from user input
        final parsedDate = _parseDateTimeFromText(input);
        if (parsedDate != null) {
          _draft.deadline = parsedDate;
          // Message already added by _userResponse or _chipResponse
        } else if (input.toLowerCase() == 'skip' ||
            input.toLowerCase() == 'picker') {
          // User wants to use picker or skip
          if (input.toLowerCase() == 'picker') {
            _setCustomDeadline();
            return;
          }
          // Skip - keep null or existing (message already added by _chipResponse)
        } else {
          _prompt(TaskDraftStep.enteringDeadline, 'Deadline (Days/Date):');
          return;
        }
        Future.delayed(const Duration(milliseconds: 200), () {
          _promptPriority();
        });
        break;

      case TaskDraftStep.enteringPriority:
        // Priority is hidden - auto-advance to scheduling
        Future.delayed(const Duration(milliseconds: 100), () {
          _promptScheduling();
        });
        break;

      case TaskDraftStep.enteringUrgency:
        // Handle text input for urgency
        if (input.toLowerCase() == 'skip' || input.toLowerCase() == 'keep') {
          // Keep default
        } else if (input.toLowerCase() == 'yes' || input.toLowerCase() == 'y') {
          _draft.isUrgent = true;
        } else if (input.toLowerCase() == 'no' || input.toLowerCase() == 'n') {
          _draft.isUrgent = false;
        } else {
          _prompt(TaskDraftStep.enteringUrgency, 'Yes or No:');
          return;
        }

        // Don't add duplicate urgency message - it's already shown in _promptPriority

        Future.delayed(const Duration(milliseconds: 200), () {
          _promptScheduling();
        });
        break;

      case TaskDraftStep.scheduling:
        // Handled by chips
        break;

      default:
        break;
    }
  }

  // Parse natural language date/time from user input
  DateTime? _parseDateTimeFromText(String text) {
    final now = DateTime.now();
    final lowerText = text.toLowerCase().trim();

    // Pattern 0: Plain integer — treat as "N days from today"
    final plainDays = int.tryParse(lowerText);
    if (plainDays != null && plainDays > 0) {
      return DateTime(now.year, now.month, now.day + plainDays, 23, 59);
    }

    // Pattern 1: "today" or "tomorrow"
    if (lowerText == 'today' || lowerText.startsWith('today ')) {
      return DateTime(now.year, now.month, now.day, 9, 0);
    }
    if (lowerText == 'tomorrow' || lowerText.startsWith('tomorrow ')) {
      return DateTime(now.year, now.month, now.day + 1, 9, 0);
    }

    // Pattern 2: Day names (monday, tuesday, etc.)
    final daysOfWeek = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    for (int i = 0; i < daysOfWeek.length; i++) {
      if (lowerText.startsWith(daysOfWeek[i]) ||
          lowerText.contains(' ${daysOfWeek[i]}')) {
        final currentDay = now.weekday;
        final targetDay = i + 1; // Monday = 1
        int daysUntil = targetDay - currentDay;
        if (daysUntil <= 0) daysUntil += 7; // Next occurrence
        return DateTime(now.year, now.month, now.day + daysUntil, 9, 0);
      }
    }

    // Pattern 3: "DD/MM" or "MM/DD" (assume current year)
    final dateRegex = RegExp(
      r'^(\d{1,2})[\/\-](\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?\s*(am|pm)?',
      caseSensitive: false,
    );
    final dateMatch = dateRegex.firstMatch(lowerText);
    if (dateMatch != null) {
      int day = int.parse(dateMatch.group(1)!);
      int month = int.parse(dateMatch.group(2)!);
      int hour = 9;
      int minute = 0;

      // Parse time if provided
      if (dateMatch.group(3) != null) {
        hour = int.parse(dateMatch.group(3)!);
        minute = int.parse(dateMatch.group(4) ?? '0');
        final period = dateMatch.group(5)?.toLowerCase();
        if (period == 'pm' && hour < 12) hour += 12;
        if (period == 'am' && hour == 12) hour = 0;
      }

      // Assume current year
      return DateTime(now.year, month, day, hour, minute);
    }

    // Pattern 4: "Jan 15", "January 15", "21st jan", "Jan 21st" (assume current year)
    final months = {
      'jan': 1,
      'january': 1,
      'feb': 2,
      'february': 2,
      'mar': 3,
      'march': 3,
      'apr': 4,
      'april': 4,
      'may': 5,
      'jun': 6,
      'june': 6,
      'jul': 7,
      'july': 7,
      'aug': 8,
      'august': 8,
      'sep': 9,
      'september': 9,
      'oct': 10,
      'october': 10,
      'nov': 11,
      'november': 11,
      'dec': 12,
      'december': 12,
    };

    for (final entry in months.entries) {
      if (lowerText.contains(entry.key)) {
        // Match day with optional ordinal suffix (1st, 2nd, 3rd, 4th, 21st, etc.)
        final dayRegex = RegExp(
          r'(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{1,2}):(\d{2}))?\s*(am|pm)?',
          caseSensitive: false,
        );
        final dayMatch = dayRegex.firstMatch(lowerText);
        if (dayMatch != null) {
          int day = int.parse(dayMatch.group(1)!);
          int hour = 9;
          int minute = 0;

          if (dayMatch.group(2) != null) {
            hour = int.parse(dayMatch.group(2)!);
            minute = int.parse(dayMatch.group(3) ?? '0');
            final period = dayMatch.group(4)?.toLowerCase();
            if (period == 'pm' && hour < 12) hour += 12;
            if (period == 'am' && hour == 12) hour = 0;
          }

          return DateTime(now.year, entry.value, day, hour, minute);
        }
      }
    }

    // Pattern 5: Full date "DD/MM/YYYY" or "YYYY-MM-DD"
    final fullDateRegex = RegExp(
      r'^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})(?:\s+(\d{1,2}):(\d{2}))?\s*(am|pm)?',
      caseSensitive: false,
    );
    final fullDateMatch = fullDateRegex.firstMatch(lowerText);
    if (fullDateMatch != null) {
      int day = int.parse(fullDateMatch.group(1)!);
      int month = int.parse(fullDateMatch.group(2)!);
      int year = int.parse(fullDateMatch.group(3)!);
      int hour = 9;
      int minute = 0;

      if (fullDateMatch.group(4) != null) {
        hour = int.parse(fullDateMatch.group(4)!);
        minute = int.parse(fullDateMatch.group(5) ?? '0');
        final period = fullDateMatch.group(6)?.toLowerCase();
        if (period == 'pm' && hour < 12) hour += 12;
        if (period == 'am' && hour == 12) hour = 0;
      }

      return DateTime(year, month, day, hour, minute);
    }

    return null;
  }

  void _setDeadline(int days) {
    // Calculate deadline from task start date (not current time)
    final baseDate = _draft.startDate ?? DateTime.now();

    // Set deadline to the end of the day (11:59 PM) - time is optional
    _draft.deadline = DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day + days,
      23, // 11:59 PM (end of day)
      59,
    );

    final startDateLabel = _draft.activateNow
        ? 'Today'
        : DateFormat('MMM dd').format(baseDate);

    _chipResponse(
      '${days == 1 ? '1 Day' : '$days Days'} from $startDateLabel (${DateFormat('MMM dd, yyyy').format(_draft.deadline!)})',
    );
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptPriority();
    });
  }

  void _setCustomDeadline() async {
    // Calculate minimum date (task start date)
    final minDate = _draft.startDate ?? DateTime.now();

    // Show compact date-time picker
    final DateTime? picked = await _showCompactDateTimePicker(
      initialDate: minDate.add(const Duration(days: 7)),
      title: 'Select Deadline',
    );

    if (picked != null) {
      // Validate that deadline is not before start date
      final pickedDateOnly = DateTime(picked.year, picked.month, picked.day);
      final minDateOnly = DateTime(minDate.year, minDate.month, minDate.day);

      if (pickedDateOnly.isBefore(minDateOnly)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Deadline cannot be before task start date (${DateFormat('MMM dd, yyyy').format(minDate)})',
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      _draft.deadline = picked;
      final startDateLabel = _draft.activateNow
          ? 'Today'
          : DateFormat('MMM dd').format(minDate);
      _chipResponse(
        'Deadline: ${Helpers.formatDeadline(picked)} (from $startDateLabel)',
      );
      Future.delayed(const Duration(milliseconds: 200), () {
        _promptPriority();
      });
    }
  }

  // Compact date-time picker without full calendar
  Future<DateTime?> _showCompactDateTimePicker({
    required DateTime initialDate,
    String title = 'Select Date & Time',
  }) async {
    int selectedDay = initialDate.day;
    int selectedMonth = initialDate.month;
    int selectedYear = initialDate.year;
    int selectedHour = 9;
    int selectedMinute = 0;

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
                      // Day
                      _buildNumberPicker('Day', selectedDay, 1, 31, (val) {
                        setDialogState(() => selectedDay = val);
                      }),
                      // Month
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
                      // Year
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
                  const Divider(),
                  const SizedBox(height: 8),
                  // Time selection row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Hour
                      _buildNumberPicker('Hour', selectedHour, 1, 12, (val) {
                        setDialogState(() => selectedHour = val);
                      }),
                      // Minute
                      _buildNumberPicker('Min', selectedMinute, 0, 59, (val) {
                        setDialogState(() => selectedMinute = val);
                      }, step: 5),
                      // AM/PM
                      _buildAmPmPicker(selectedHour >= 12, (isPM) {
                        setDialogState(() {
                          if (isPM && selectedHour < 12) selectedHour += 12;
                          if (!isPM && selectedHour >= 12) selectedHour -= 12;
                        });
                      }),
                    ],
                  ),
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
                  final result = DateTime(
                    selectedYear,
                    selectedMonth,
                    selectedDay,
                    selectedHour,
                    selectedMinute,
                  );
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

  void _setPriority(int priority) {
    _draft.priority = priority;
    _draft.isUrgent = false; // Default to No

    // Only show urgency as editable message
    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: false,
          text: 'Urgency: No',
          step: TaskDraftStep.enteringUrgency,
          canEdit: true,
        ),
      );
      _showChips = false;
      _chips = null;
    });
    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 300), () {
      _promptScheduling();
    });
  }

  void _setUrgency(bool urgent) {
    _draft.isUrgent = urgent;
    _chipResponse(urgent ? 'Yes 🔥' : 'No');
    Future.delayed(const Duration(milliseconds: 200), () {
      _promptScheduling();
    });
  }

  void _setActivation(bool activateNow) {
    _draft.activateNow = activateNow;
    _chipResponse(activateNow ? 'Activate Now' : 'Schedule for Later');

    if (activateNow) {
      // Auto-create the task immediately
      Future.delayed(const Duration(milliseconds: 300), () {
        _finalizeTask();
      });
    } else {
      // Scheduled for later - task already saved with start date in _showStartDatePicker
      Future.delayed(const Duration(milliseconds: 300), () {
        _showCompletionMessage(false);
      });
    }
  }

  Future<void> _showStartDatePicker() async {
    // Show compact date-time picker
    final DateTime? pickedDate = await _showCompactDateTimePicker(
      initialDate: DateTime.now().add(const Duration(days: 1)),
      title: 'Select Start Date',
    );

    if (pickedDate != null && mounted) {
      _draft.activateNow = false; // Schedule for later
      _draft.startDate = pickedDate; // Store start date

      final formattedDateTime = DateFormat(
        'MMM dd, yyyy hh:mm a',
      ).format(pickedDate);
      _chipResponse('Task starts: $formattedDateTime');

      Future.delayed(const Duration(milliseconds: 300), () {
        _showCompletionMessage(false);
      });
    }
  }

  void _showCompletionMessage(bool created) {
    String message;
    if (created) {
      message = '✅ Task created!';
    } else {
      // Show start date for scheduled tasks
      if (_draft.startDate != null) {
        message =
            '📅 Task scheduled!\nStarts: ${DateFormat('MMM dd, yyyy hh:mm a').format(_draft.startDate!)}';
      } else {
        message = '📅 Task scheduled!';
      }
    }

    setState(() {
      _messages.add(
        ConversationMessage(
          isSystem: true,
          text: message,
          step: TaskDraftStep.complete,
        ),
      );
      _showChips = false;
      _chips = null;
    });
    _scrollToBottom();

    // For scheduled tasks, show "Take to Chat" option after a delay
    if (!created) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() {
            _showChips = true;
            _chips = [
              _chip('Take to Chat', () => _navigateToScheduledTaskChat()),
            ];
          });
        }
      });
    }
  }

  String _safeDisplayName(String? value, {String fallback = 'Me'}) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty ||
        trimmed.toLowerCase() == 'user' ||
        trimmed.toLowerCase() == 'unknown') {
      return fallback;
    }
    return trimmed;
  }

  String? _resolvedAssigneeUid(AuthProvider authProvider) {
    final explicitUid = _draft.assigneeUid?.trim() ?? '';
    if (explicitUid.isNotEmpty) return explicitUid;

    final user = authProvider.userModel;
    if (user == null) return null;

    final assignee = _draft.assignedTo.trim().toLowerCase();
    final currentUserValues =
        <String>{'me', user.uid, user.name, user.phone, user.mobileNumber ?? ''}
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toSet();

    return currentUserValues.contains(assignee) ? user.uid : null;
  }

  /// Look up a user's UID by their normalized phone number using cached team members.
  /// Returns null if not found in cache.
  String? _lookupUidByPhone(String normalizedPhone) {
    if (normalizedPhone.isEmpty) return null;
    // Use ContactPickerService's cached team members for synchronous lookup
    final picker = ContactPickerService();
    final teamMembers = picker.getCachedTeamMembers();
    if (teamMembers != null) {
      for (final user in teamMembers) {
        final userPhone = Helpers.normalizePhone(user.phone);
        if (userPhone != null && userPhone == normalizedPhone) {
          return user.uid;
        }
      }
    }
    return null;
  }

  String _resolvedAssigneeName(AuthProvider authProvider) {
    final user = authProvider.userModel;
    final assigneeUid = _resolvedAssigneeUid(authProvider);
    if (user != null && assigneeUid == user.uid) {
      return _safeDisplayName(user.name);
    }
    return _safeDisplayName(_draft.assignedTo, fallback: 'Someone');
  }

  Future<TaskModel> _buildTaskFromDraft(
    AuthProvider authProvider, {
    required bool isDraft,
    bool includeScheduledDate = false,
  }) async {
    final user = authProvider.userModel!;
    final creatorName = _safeDisplayName(user.name);
    final assigneeUid = _resolvedAssigneeUid(authProvider);
    final assigneeName = _resolvedAssigneeName(authProvider);
    final normalizedAssigneePhone = Helpers.normalizePhone(
      _draft.assigneePhone,
    );

    // Resolve assignee UID: use explicit UID, or resolve from phone number
    String? resolvedUid = assigneeUid;
    if (resolvedUid == null &&
        normalizedAssigneePhone != null &&
        normalizedAssigneePhone.isNotEmpty) {
      // Try to resolve UID from phone number: cached team members first,
      // then the SQLite users cache, then Firestore (cached for next time).
      resolvedUid = _lookupUidByPhone(normalizedAssigneePhone);
      if (resolvedUid == null) {
        try {
          final db = LocalDatabaseService();
          resolvedUid = await db.getCachedUid(normalizedAssigneePhone);
          if (resolvedUid == null) {
            final usersSnapshot = await FirebaseFirestore.instance
                .collection('users')
                .where('phone', isEqualTo: normalizedAssigneePhone)
                .limit(1)
                .get();
            if (usersSnapshot.docs.isNotEmpty) {
              resolvedUid = usersSnapshot.docs.first.id;
              await db.cacheUser(resolvedUid, normalizedAssigneePhone);
            }
          }
        } catch (e) {
          print(
            '[TaskCreation] Error resolving UID for phone $normalizedAssigneePhone: $e',
          );
        }
      }
    }

    final assigneeUids = resolvedUid == null
        ? <String>[]
        : <String>[resolvedUid];
    // Always include creator in participants so they're findable
    final allParticipantUids = <String>{user.uid, ...assigneeUids};
    final assigneePhones = normalizedAssigneePhone != null
        ? <String>[normalizedAssigneePhone]
        : <String>[];

    return TaskModel(
      id: Helpers.generateId(),
      title: _draft.title,
      description: _draft.description,
      createdBy: user.uid,
      createdByName: creatorName,
      assignedTo: assigneeName,
      assignedToUid: resolvedUid,
      assignedToPhone: Helpers.normalizePhone(_draft.assigneePhone),
      participants: allParticipantUids.toList(),
      isGroupTask: false,
      priority: _draft.priority,
      isUrgent: _draft.isUrgent,
      deadline: _draft.deadline,
      startDate: _draft.startDate,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      extraFields: {
        'createdByUid': user.uid,
        'creatorUid': user.uid,
        'createdByName': creatorName,
        'creatorName': creatorName,
        'creatorPhone': Helpers.normalizePhone(user.phone) ?? user.phone,
        if (normalizedAssigneePhone != null)
          'assigneePhone': normalizedAssigneePhone,
        'assigneeIsOnApp': _draft.assigneeIsOnApp,
        if (resolvedUid != null) 'assigneeUid': resolvedUid,
        'assigneeUids': assigneeUids,
        'participantUids': assigneeUids,
        'assigneeNames': <String>[assigneeName],
        'participantNames': <String>[assigneeName],
        'assigneePhones': assigneePhones,
        'activateNow': _draft.activateNow,
        'isDraft': isDraft,
        if (_draft.startDate != null)
          'startDate': _draft.startDate!.toIso8601String(),
        if (includeScheduledDate && _draft.startDate != null)
          'scheduledDate': _draft.startDate!.toIso8601String(),
      },
    );
  }

  // Navigate to scheduled task chat
  void _navigateToScheduledTaskChat() async {
    // Save the scheduled task first
    setState(() {
      _isCreating = true;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final taskProvider = context.read<TaskProvider>();

      final task = await _buildTaskFromDraft(
        authProvider,
        isDraft: !_draft.activateNow,
        includeScheduledDate: true,
      );

      final taskId = await taskProvider.createTask(
        task,
        planType: authProvider.effectivePlanTypeFor('task'),
      );

      if (taskId != null && mounted) {
        setState(() {
          _isCreating = false;
        });

        // Create task with the real ID from Firebase — reload from SQLite so
        // the detail screen sees applied default milestones / team stamp.
        final createdTask = await taskProvider.persistedTask(task, taskId);

        // Persist creation conversation messages
        await _persistCreationMessages(taskId, authProvider.userModel!.uid);

        if (widget.onTaskCreated != null) {
          // Embedded mode: notify parent
          widget.onTaskCreated!(createdTask);
        } else {
          // Standalone mode: navigate to Task Detail Screen
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => TaskDetailScreen(task: createdTask),
            ),
          );
        }
      }
    } on PlanLimitException catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
        await showPaywallDialog(context, feature: e.feature, detail: e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveAsDraft() async {
    try {
      // If we have a title, create an actual task instead of just a draft
      if (_draft.title.isNotEmpty) {
        final authProvider = context.read<AuthProvider>();
        final taskProvider = context.read<TaskProvider>();

        final task = await _buildTaskFromDraft(
          authProvider,
          isDraft: true,
          includeScheduledDate: true,
        );

        final taskId = await taskProvider.createTask(
          task,
          planType: authProvider.effectivePlanTypeFor('task'),
        );

        if (taskId != null && mounted) {
          setState(() {
            _messages.add(
              ConversationMessage(
                isSystem: true,
                text: 'Task saved as draft',
                step: TaskDraftStep.complete,
              ),
            );
            _showChips = false;
            _chips = null;
          });
          _scrollToBottom();
        }
      } else {
        // No title yet, save as draft in separate collection
        final taskProvider = context.read<TaskProvider>();
        final draftId = await taskProvider.saveTaskDraft(_draft);

        if (draftId != null && mounted) {
          setState(() {
            _messages.add(
              ConversationMessage(
                isSystem: true,
                text: 'Saved as draft',
                step: TaskDraftStep.complete,
              ),
            );
            _showChips = false;
            _chips = null;
          });
          _scrollToBottom();
        }
      }
    } on PlanLimitException catch (e) {
      if (mounted) {
        await showPaywallDialog(context, feature: e.feature, detail: e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(ConversationMessage(isSystem: true, text: 'Error: $e'));
        });
        _scrollToBottom();
      }
    }
  }

  void _showExitConfirmation() {
    // Save if ANY field has data (title, description, or deadline)
    final hasData =
        _draft.title.isNotEmpty ||
        _draft.description.isNotEmpty ||
        _draft.deadline != null ||
        _messages.any((m) => !m.isSystem && m.text.contains('Urgency:'));

    if (!hasData) {
      // Nothing to save, just exit
      Navigator.of(context).pop();
    } else {
      // Auto-save as draft if there's any input
      _saveAsDraft();
      Navigator.of(context).pop();
    }
  }

  // Handle back button press - auto-save draft
  Future<bool> _handleBackPress() async {
    // Also check the input controller for unsaved text
    final hasInput = _inputController.text.trim().isNotEmpty;
    // Save if ANY field has data (title, description, deadline, or input text)
    final hasData =
        _draft.title.isNotEmpty ||
        _draft.description.isNotEmpty ||
        _draft.deadline != null ||
        hasInput ||
        _messages.any((m) => !m.isSystem && m.text.contains('Urgency:'));

    if (!hasData) {
      // Nothing to save, allow back
      return true;
    }

    // If user typed something in input but hasn't submitted yet, capture it
    if (hasInput &&
        _draft.title.isEmpty &&
        _draft.currentStep == TaskDraftStep.enteringTitle) {
      _draft.title = _inputController.text.trim();
    }

    // Auto-save draft silently
    await _saveAsDraft();

    // Notify parent to refresh task list
    if (widget.onDraftSaved != null) {
      widget.onDraftSaved!();
    }

    // Show snackbar notification
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Draft saved'),
          duration: Duration(seconds: 2),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }

    return true; // Allow back navigation
  }

  /// Persist creation conversation messages to Firestore as real MessageModel entries.
  Future<void> _persistCreationMessages(
    String taskId,
    String currentUserId,
  ) async {
    final firebaseService = FirebaseService();
    for (final convMsg in _messages) {
      final messageModel = MessageModel(
        id: Helpers.generateId(),
        taskId: taskId,
        senderId: convMsg.isSystem ? 'system' : currentUserId,
        text: convMsg.text,
        type: convMsg.isSystem ? MessageType.system : MessageType.text,
        createdAt: convMsg.createdAt,
      );
      try {
        await firebaseService.sendMessage(taskId, messageModel);
      } catch (e) {
        print('[TaskCreation] Error persisting creation message: $e');
      }
    }
  }

  Future<void> _finalizeTask() async {
    setState(() {
      _isCreating = true;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final taskProvider = context.read<TaskProvider>();

      final task = await _buildTaskFromDraft(
        authProvider,
        isDraft: !_draft.activateNow,
        includeScheduledDate: true,
      );

      final taskId = await taskProvider.createTask(
        task,
        planType: authProvider.effectivePlanTypeFor('task'),
      );

      if (taskId != null && mounted) {
        setState(() {
          _isCreating = false;
        });

        // Create task with the real ID from Firebase — reload from SQLite so
        // the detail screen sees applied default milestones / team stamp.
        final createdTask = await taskProvider.persistedTask(task, taskId);

        // Persist creation conversation messages as real chat messages
        await _persistCreationMessages(taskId, authProvider.userModel!.uid);

        // Show completion message
        _showCompletionMessage(true);

        // Navigate to Task Detail Screen after a short delay
        await Future.delayed(const Duration(milliseconds: 800));

        if (mounted) {
          if (widget.onTaskCreated != null) {
            // Embedded mode: notify parent instead of navigating
            widget.onTaskCreated!(createdTask);
          } else {
            // Standalone mode: navigate to Task Detail Screen
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => TaskDetailScreen(task: createdTask),
              ),
            );
          }
        }
      }
    } on PlanLimitException catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
        await showPaywallDialog(context, feature: e.feature, detail: e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _messages.add(ConversationMessage(isSystem: true, text: 'Error: $e'));
        });
        _scrollToBottom();
      }
    }
  }

  void _editField(TaskDraftStep step) {
    _draft.currentStep = step;
    final stepName = _draft.getStepName(step);

    // Get existing value for this field
    String existingValue = '';
    switch (step) {
      case TaskDraftStep.enteringTitle:
        existingValue = _draft.title;
        break;
      case TaskDraftStep.enteringDescription:
        existingValue = _draft.description;
        break;
      case TaskDraftStep.enteringDeadline:
        existingValue = _draft.deadline != null
            ? Helpers.formatDate(_draft.deadline!)
            : '';
        break;
      case TaskDraftStep.enteringPriority:
        final labels = {2: 'Normal', 3: 'High'};
        existingValue = labels[_draft.priority] ?? 'M - Mid';
        break;
      case TaskDraftStep.enteringUrgency:
        existingValue = _draft.isUrgent ? 'Yes 🔥' : 'No';
        break;
      case TaskDraftStep.scheduling:
        existingValue = _draft.activateNow ? 'Activate Now' : 'Schedule';
        break;
      default:
        break;
    }

    // Load existing value into input box (WhatsApp-style edit)
    if (existingValue.isNotEmpty) {
      _inputController.text = existingValue;
    }

    _prompt(step, 'Edit $stepName?');

    // Show chips for fields that use them
    switch (step) {
      case TaskDraftStep.enteringDeadline:
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
      case TaskDraftStep.scheduling:
        Future.delayed(const Duration(milliseconds: 300), () {
          _showSchedulingChips();
        });
        break;
      default:
        break;
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
      ];
    });
  }

  void _showPriorityChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('Normal', () => _setPriority(2)),
        _chip('High', () => _setPriority(3)),
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

  void _showSchedulingChips() {
    setState(() {
      _showChips = true;
      _chips = [
        _chip('Activate Now', () => _setActivation(true)),
        _chip('Schedule for Later', () => _showStartDatePicker()),
      ];
    });
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
    return WillPopScope(
      onWillPop: _handleBackPress,
      child: Scaffold(
        backgroundColor: AppTheme.chatCanvas(context),
        appBar: widget.onTaskCreated != null
            ? null // Embedded mode: no AppBar (parent provides it)
            : AppBar(
                backgroundColor: AppTheme.headerGreen,
                foregroundColor: Colors.white,
                elevation: 1,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _showExitConfirmation,
                ),
                titleSpacing: 0,
                title: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: widget.assignee.isOnApp
                          ? Colors.white.withOpacity(0.2)
                          : Colors.grey.withOpacity(0.2),
                      child: Text(
                        widget.assignee.name.isNotEmpty
                            ? widget.assignee.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.assignee.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Create new task',
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
                  if (_isCreating)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return _buildMessageBubble(message, index);
                },
              ),
            ),

            // Draft hint caption for onboarding
            if (widget.showDraftHint)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                color: AppTheme.headerGreen.withOpacity(0.08),
                child: const Text(
                  'Change assignee or task title by tapping on it.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.secondaryText,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),

            // Input bar
            _buildInputBar(),

            // Chips area (below input bar)
            if (_showChips && _chips != null)
              SafeArea(
                top: false,
                child: ConstrainedBox(
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
              ),
          ],
        ),
      ),
    );
  }

  // Show context menu on long press (WhatsApp-style)
  void _showMessageContextMenu(ConversationMessage message, int index) {
    // Only show edit option for user messages with a step
    if (message.isSystem || message.step == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Edit option
                ListTile(
                  leading: const Icon(Icons.edit, color: AppTheme.headerGreen),
                  title: const Text('Edit Message'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _editMessage(message, index);
                  },
                ),
                const Divider(height: 1),
                // Cancel option
                ListTile(
                  leading: const Icon(Icons.close, color: Colors.red),
                  title: const Text('Cancel'),
                  onTap: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Edit a message
  void _editMessage(ConversationMessage message, int index) {
    if (message.step == null) return;

    final controller = TextEditingController(text: message.text);
    final focusNode = FocusNode();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit Message'),
          content: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter new text...',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final newText = controller.text.trim();
                if (newText.isNotEmpty && newText != message.text) {
                  setState(() {
                    // Update the message
                    _messages[index] = ConversationMessage(
                      isSystem: message.isSystem,
                      text: newText,
                      step: message.step,
                      canEdit: message.canEdit,
                      createdAt: message.createdAt,
                    );

                    // Update the draft based on the step
                    if (message.step == TaskDraftStep.enteringTitle) {
                      _draft.title = newText;
                    } else if (message.step ==
                        TaskDraftStep.enteringDescription) {
                      _draft.description = newText;
                    }
                  });
                }
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.headerGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    // Auto-focus after dialog shows
    Future.delayed(const Duration(milliseconds: 100), () {
      focusNode.requestFocus();
    });
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
                border: message.canEdit && message.step != null
                    ? Border.all(
                        color: AppTheme.headerGreen.withOpacity(0.2),
                        width: 1,
                      )
                    : null,
              ),
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
          ),
        ),
      );
    }

    // User message
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onLongPress: () => _showMessageContextMenu(message, index),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.chatBubbleGreen,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    message.text,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.primaryText,
                    ),
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
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final showInput = !_showChips;

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
                  focusNode: _inputFocusNode,
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
                  onEditingComplete: () {},
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
          ] else
            const SizedBox.shrink(),
        ],
      ),
    );
  }

  String _getInputHint() {
    switch (_draft.currentStep) {
      case TaskDraftStep.enteringTitle:
        return 'Enter task title...';
      case TaskDraftStep.enteringDescription:
        return 'Enter description or type "skip"...';
      default:
        return 'Type a message...';
    }
  }
}
