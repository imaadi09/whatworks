import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../../widgets/recurrence_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/task.dart';
import '../../models/message.dart';
import '../../models/milestone.dart';
import '../../modules/shared/module_config.dart';
import '../../services/contact_picker_service.dart';
import '../../services/avatar_cache_service.dart';
import '../../widgets/app_avatar.dart';
import '../../services/external_notification_service.dart';
import '../../services/message_visibility_service.dart';
import '../../services/storage_service.dart';
import '../../services/firebase_service.dart';
import '../../services/sequential_id_service.dart';
import '../../services/local_database_service.dart';
import '../../services/item_links_service.dart';
import '../../services/outside_share_service.dart';
import '../../models/system_log.dart';
import '../../utils/constants.dart';
import '../../widgets/card_widgets.dart';
import '../forward/forward_target_screen.dart';
import '../../modules/sales/providers/sales_provider.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';
import '../../providers/task_provider.dart';
import '../../providers/auth_provider.dart';
import '../new_task/task_creation_chat_screen.dart';
import '../ratings/rating_dialog.dart';
import '../ratings/ratings_detail_screen.dart';
import '../home/home_screen.dart';

import '../../widgets/shared_detail_widgets.dart';
import '../../services/customer_comms_service.dart';
import '../../modules/shared/customer_info.dart';
import '../../widgets/media_gallery_sheet.dart';
import '../../widgets/card_action_icons.dart';
import '../../widgets/swipe_to_reply.dart';
import '../../widgets/cash_action_dialog.dart';
import '../../widgets/cash_statement_sheet.dart';
import '../../widgets/schedule_call_dialog.dart';
import '../../services/notification_service.dart';
import '../../widgets/detail_chat/detail_chat_bubbles.dart';
import '../../widgets/detail_chat/detail_chat_menu.dart';
import '../../widgets/detail_chat/detail_chat_attachments.dart';
import '../../widgets/detail_chat/detail_chat_emoji.dart';
import '../../widgets/detail_chat/detail_chat_mention.dart';
import '../../widgets/detail_chat/detail_chat_plumbing.dart';
import '../../widgets/linked_items_chips.dart';
import '../../widgets/link_picker_sheet.dart';
import '../../widgets/outside_share_sheet.dart';

// Helper class for Slack-style action parsing
class _ActionDetails {
  final String actor;
  final String title;
  final String? before;
  final String? after;
  final String? message;

  _ActionDetails({
    required this.actor,
    required this.title,
    this.before,
    this.after,
    this.message,
  });
}

class TaskDetailScreen extends StatefulWidget {
  final TaskModel task;
  final String? scrollToMessageId;
  final AssignableContact? creationAssignee; // Triggers creation mode

  const TaskDetailScreen({
    super.key,
    required this.task,
    this.scrollToMessageId,
    this.creationAssignee,
  });

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen>
    with
        DetailChatBubblesMixin,
        DetailChatAttachmentsMixin,
        DetailChatPlumbingMixin,
        DetailChatMenuMixin {
  // Search state, screenshot key and export live in DetailChatMenuMixin now.
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode(); // Draft: keyboard ready
  bool _draftDialogDismissed =
      false; // If true, skip activation dialog on subsequent sends
  bool _showMilestonesInline = false; // Milestones section expand state
  bool _taskCardSheetOpen = false; // Swipe-reveal task card sheet guard
  // Version counter so the open task-card sheet rebuilds when screen state
  // changes (a modal sheet's builder otherwise runs only once).
  final ValueNotifier<int> _cardSheetVersion = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _cardSheetVersion.value++;
  }

  // Get current task status
  String _getTaskStatus() {
    if (_currentTask.isCancelled) return 'Cancelled';
    if (_currentTask.isClosed) return 'Completed';
    final extraFields = _currentTask.extraFields;
    if (extraFields != null && extraFields['isBlocked'] == true) {
      return 'Blocked';
    }
    if (extraFields != null && extraFields['isDraft'] == true) {
      if (extraFields['scheduledDate'] != null) return 'Scheduled';
      return 'Draft';
    }
    return 'Active';
  }

  // Check if task is draft or scheduled
  bool _isDraftOrScheduled() {
    final status = _getTaskStatus();
    return status == 'Draft' || status == 'Scheduled';
  }

  // Get status color
  Color _getStatusColor() {
    switch (_getTaskStatus()) {
      case 'Active':
        return const Color(0xFF2F9E44); // Green
      case 'Completed':
        return const Color(0xFF1976D2); // Blue
      case 'Cancelled':
        return const Color(0xFFE03131); // Red
      case 'Blocked':
        return const Color(0xFF862E9C); // Purple — distinct from cancel red
      case 'Scheduled':
        return const Color(0xFFF59F00); // Orange
      case 'Draft':
      default:
        return const Color(0xFF868E96); // Gray
    }
  }

  // Get status icon
  IconData _getStatusIcon() {
    switch (_getTaskStatus()) {
      case 'Active':
        return Icons.play_circle;
      case 'Completed':
        return Icons.check_circle;
      case 'Cancelled':
        return Icons.cancel;
      case 'Blocked':
        return Icons.block;
      case 'Scheduled':
        return Icons.schedule;
      case 'Draft':
      default:
        return Icons.drafts;
    }
  }

  // Edit task status
  Future<void> _editTaskStatus() async {
    final currentStatus = _getTaskStatus();

    // Only the creator can change status between Active / Completed / Cancelled
    final canChangeStatus = _isTaskCreator();

    if (!canChangeStatus) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the task creator can change status'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (currentStatus == 'Active') {
      // Show options: Complete or Cancel
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text('Update Task Status'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.check_circle,
                  color: Color(0xFF1976D2),
                ),
                title: const Text('Mark as Complete'),
                onTap: () {
                  Navigator.pop(ctx);
                  _updateTaskStatus(isClosed: true, isCancelled: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Color(0xFFE03131)),
                title: const Text('Cancel Task'),
                onTap: () {
                  Navigator.pop(ctx);
                  _updateTaskStatus(isClosed: false, isCancelled: true);
                },
              ),
            ],
          ),
        ),
      );
    } else if (_isDraftOrScheduled()) {
      // Show options: Activate Now, Schedule, or Cancel
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text('Task Status'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow, color: Color(0xFF2F9E44)),
                title: const Text('Activate Now'),
                subtitle: const Text('Make task active immediately'),
                onTap: () {
                  Navigator.pop(ctx);
                  _activateTask();
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule, color: Color(0xFFF59F00)),
                title: const Text('Set Schedule'),
                subtitle: const Text('Activate at a future date'),
                onTap: () {
                  Navigator.pop(ctx);
                  _scheduleTaskActivation();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Color(0xFFE03131)),
                title: const Text('Cancel Task'),
                onTap: () {
                  Navigator.pop(ctx);
                  _updateTaskStatus(isClosed: false, isCancelled: true);
                },
              ),
            ],
          ),
        ),
      );
    } else if (currentStatus == 'Completed' || currentStatus == 'Cancelled') {
      // Allow reactivation of completed/cancelled tasks
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text('Reactivate Task'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This task is ${currentStatus.toLowerCase()}. Make it active again?',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _updateTaskStatus(isClosed: false, isCancelled: false);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Reactivate'),
            ),
          ],
        ),
      );
    }
  }

  // Update task status
  Future<void> _updateTaskStatus({
    required bool isClosed,
    required bool isCancelled,
  }) async {
    // Capture old status BEFORE updating
    final oldStatus = _getTaskStatus();

    // Null (not remove) so FirebaseService.updateTask translates them into
    // FieldValue.delete() — removing the key would let the server merge
    // keep the old isDraft:true value.
    final updatedExtraFields = isCancelled || isClosed
        ? (Map<String, dynamic>.from(_currentTask.extraFields ?? {})
            ..['isDraft'] = null
            ..['scheduledDate'] = null)
        : (_currentTask.extraFields != null
              ? Map<String, dynamic>.from(_currentTask.extraFields!)
              : null);

    final updatedTask = _currentTask.copyWith(
      isClosed: isClosed,
      isCancelled: isCancelled,
      progress: isClosed
          ? 1.0
          : _currentTask.progress, // Set progress to 100% when completed
      extraFields: updatedExtraFields,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _currentTask = updatedTask;
    });

    await _updateTaskInFirebase(updatedTask);

    // Post system message with old status, new status, user, and timestamp
    String statusMessage;
    final timestamp = Helpers.formatDateTime(DateTime.now());
    String newStatus;

    if (isCancelled) {
      newStatus = 'Cancelled';
    } else if (isClosed) {
      newStatus = 'Completed';
    } else {
      // Transitioning from Draft/Scheduled to Active
      newStatus = 'Active';
    }

    statusMessage =
        '📊 Status changed: $oldStatus → $newStatus by $_currentUserName at $timestamp';

    await _sendSystemMessage(statusMessage);

    // Recurrence is now TIME-DRIVEN (Phase-2B): the shared materializer creates
    // each occurrence as its OWN row when its date arrives, so completing a task
    // no longer rolls the SAME row forward. Closing an occurrence (or the
    // anchor) simply marks it done; the series continues from the anchor's
    // nextDue regardless of completion. The old completion-driven roll-forward
    // (extraFields['recurrence']) is retired.

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isCancelled ? 'Task cancelled' : 'Task status updated'),
          duration: const Duration(seconds: 2),
          backgroundColor: isCancelled
              ? const Color(0xFFE03131)
              : AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Activate draft/scheduled task
  Future<void> _activateTask() async {
    try {
      // Capture old status BEFORE updating _currentTask
      final oldStatus = _getTaskStatus();

      final updatedExtraFields = Map<String, dynamic>.from(
        _currentTask.extraFields ?? {},
      );
      // Explicitly set to null to override Firestore's merged value
      updatedExtraFields['isDraft'] = null;
      updatedExtraFields['scheduledDate'] = null;

      final updatedTask = await _withResolvedAssignee(
        _currentTask.copyWith(
          isClosed: false,
          isCancelled: false,
          extraFields: updatedExtraFields,
          updatedAt: DateTime.now(),
        ),
      );

      if (!mounted) return;
      setState(() {
        _currentTask = updatedTask;
      });

      await _updateTaskInFirebase(updatedTask);
      final timestamp = Helpers.formatDateTime(DateTime.now());
      await _sendSystemMessage(
        '📊 Status changed: $oldStatus → Active by $_currentUserName at $timestamp',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Task activated'),
            duration: Duration(seconds: 2),
            backgroundColor: AppTheme.primaryGreen,
          ),
        );
      }
    } catch (e) {
      print('Error activating task: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not activate task: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Schedule task activation
  Future<void> _scheduleTaskActivation() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );

    if (!mounted) return;

    final scheduledDateTime = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? 9,
      pickedTime?.minute ?? 0,
    );

    final updatedExtraFields = Map<String, dynamic>.from(
      _currentTask.extraFields ?? {},
    );
    updatedExtraFields['isDraft'] = true;
    updatedExtraFields['scheduledDate'] = scheduledDateTime.toIso8601String();

    final updatedTask = _currentTask.copyWith(
      isClosed: false,
      isCancelled: false,
      extraFields: updatedExtraFields,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _currentTask = updatedTask;
    });

    await _updateTaskInFirebase(updatedTask);
    final timestamp = Helpers.formatDateTime(scheduledDateTime);
    final oldStatus = _getTaskStatus();
    await _sendSystemMessage(
      '📊 Status changed: $oldStatus → Scheduled by $_currentUserName at $timestamp',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Task scheduled for ${Helpers.formatDateTime(scheduledDateTime)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Get current user's UID from Firebase auth
  String get _currentUserId {
    try {
      return context.read<AuthProvider>().userModel?.uid ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Get current user's display name from Firebase auth
  String get _currentUserName {
    try {
      final name = context.read<AuthProvider>().userModel?.name.trim() ?? '';
      if (name.isEmpty ||
          name.toLowerCase() == 'user' ||
          name.toLowerCase() == 'unknown') {
        return 'Me';
      }
      return name;
    } catch (_) {
      return 'Me';
    }
  }

  /// Get current user's normalized phone from Firebase auth
  String get _currentUserPhone {
    try {
      return context.read<AuthProvider>().userModel?.phone.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// True only when the named assignee is the current user.
  /// Matches by name/UID string, or by UID/phone aligned to the same index
  /// in assigneeNames — handles assignees stored under a contact-book name
  /// that differs from the user's profile name.
  bool _isAssigneeMe(String assignee) {
    final name = assignee.trim();
    if (name.isEmpty) return false;
    if (name == _currentUserId ||
        name == _currentUserName ||
        name.toLowerCase() == 'me') {
      return true;
    }
    final phone = _currentUserPhone;
    final extra = _currentTask.extraFields ?? const <String, dynamic>{};
    final names = extra['assigneeNames'];
    final uids = extra['assigneeUids'];
    final phones = extra['assigneePhones'];
    if (names is List) {
      // Legacy tasks stored UID/phone lists compressed (only resolved entries),
      // so index matching is only safe when lengths match assigneeNames.
      final uidsAligned = uids is List && uids.length == names.length;
      final phonesAligned = phones is List && phones.length == names.length;
      for (int i = 0; i < names.length; i++) {
        if (names[i]?.toString().trim() != name) continue;
        // A non-empty aligned identity at this slot is DEFINITIVE — never
        // fall through to the primary-field fallback, because legacy
        // corruption can leave another assignee's phone in assignedToPhone.
        final alignedUid = uidsAligned ? (uids[i]?.toString() ?? '') : '';
        if (alignedUid.isNotEmpty && _currentUserId.isNotEmpty) {
          return alignedUid == _currentUserId;
        }
        final alignedPhone = phonesAligned
            ? (phones[i]?.toString().trim() ?? '')
            : '';
        if (alignedPhone.isNotEmpty && phone.isNotEmpty) {
          return alignedPhone == phone;
        }
      }
    }
    // Primary assignee fallback (single-assignee tasks)
    if (name == _currentTask.assignedTo.trim()) {
      if (_currentUserId.isNotEmpty &&
          _currentTask.assignedToUid == _currentUserId) {
        return true;
      }
      if (phone.isNotEmpty && _currentTask.assignedToPhone?.trim() == phone) {
        return true;
      }
    }
    return false;
  }

  /// Check if current user is the task creator
  bool _isTaskCreator() {
    final user = context.read<AuthProvider>().userModel;
    final currentIds =
        <String>{
              _currentUserId,
              _currentUserName,
              user?.uid ?? '',
              user?.name ?? '',
              user?.phone ?? '',
              user?.mobileNumber ?? '',
            }
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty && value != 'me')
            .toSet();

    final extraFields = _currentTask.extraFields ?? const <String, dynamic>{};
    final creatorValues =
        <String>{
              _currentTask.createdBy,
              _currentTask.createdByName ?? '',
              extraFields['createdBy']?.toString() ?? '',
              extraFields['createdByName']?.toString() ?? '',
              extraFields['createdByUid']?.toString() ?? '',
              extraFields['creatorUid']?.toString() ?? '',
              extraFields['creatorName']?.toString() ?? '',
              extraFields['createdByPhone']?.toString() ?? '',
              extraFields['creatorPhone']?.toString() ?? '',
            }
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty && value != 'unknown')
            .toSet();

    if (creatorValues.any(currentIds.contains)) return true;

    final assigneeValues =
        <String>{
              _currentTask.assignedTo,
              _currentTask.assignedToUid ?? '',
              _currentTask.assignedToPhone ?? '',
              ..._currentTask.participants,
              ...(extraFields['participantUids'] is List
                  ? List<String>.from(extraFields['participantUids'] as List)
                  : const <String>[]),
            }
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toSet();

    final hasCreatorInfo = creatorValues.isNotEmpty;
    final isAssignedToMe = assigneeValues.any(currentIds.contains);

    // Legacy self-created tasks may have blank/unknown creator fields but still point to me as assignee.
    return !hasCreatorInfo && isAssignedToMe;
  }

  // Check and auto-activate scheduled tasks
  Future<void> _checkAndAutoActivate() async {
    final status = _getTaskStatus();
    if (status != 'Scheduled') return;

    final extraFields = _currentTask.extraFields;
    if (extraFields == null || extraFields['scheduledDate'] == null) return;

    try {
      final scheduledDate = DateTime.parse(
        extraFields['scheduledDate'] as String,
      );
      final now = DateTime.now();

      if (now.isAfter(scheduledDate) || now.isAtSameMomentAs(scheduledDate)) {
        print(
          '[TaskDetail] Auto-activating task: scheduled date $scheduledDate has passed',
        );
        await _activateTask();
      }
    } catch (e) {
      print('[TaskDetail] Error checking auto-activation: $e');
    }
  }

  List<MessageModel> _messages =
      []; // Initialize empty - stream will populate (chronological: oldest first)
  List<MessageModel> _displayMessages =
      []; // Reversed view (newest first) for reverse ListView
  List<MessageModel> _allMessages =
      []; // All messages from stream (for pagination)

  void _rebuildDisplayMessages() {
    // Always sort by createdAt ascending, then reverse for display
    // (reverse ListView: index 0 = latest message at bottom of screen)
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _displayMessages = _messages.reversed.toList();
  }

  bool _isLoadingMore = false;
  bool _isScrollingToMessage =
      false; // Guard flag: prevents stream from resetting _messages during scroll
  // Range of _displayMessages indices the lazy ListView has actually built
  // into the viewport/cache since the last scroll-to-message was armed. Used
  // by _scrollToMessageById to know which DIRECTION to step when the target
  // widget is not built yet (a far-off-screen card in a reverse:true list).
  int _builtMinDisplayIndex = 0;
  int _builtMaxDisplayIndex = 0;
  // One coarse-height leap is allowed on the first hop of a scroll-to-message
  // climb (accelerant); later hops use exact built-index steps. Reset on arm.
  bool _coarseLeapDone = false;
  // Transient highlight band on the card a notification tap jumps to, so the
  // referenced action is easy to spot once the scroll lands. Auto-clears.
  String? _highlightedMessageId;
  Timer? _highlightClearTimer;
  bool _justSentMessage =
      false; // True after optimistic send; prevents stream re-scroll
  bool _initialScrollDone =
      false; // True after first scroll on load; prevents double scroll
  bool _isUserScrolling =
      false; // True while user is actively scrolling (defers stream setState)
  bool _pendingStreamRefresh =
      false; // True when stream fired during user scroll (deferred)

  // Safety net for the deferred stream refresh: if a ScrollEnd never arrives
  // (interrupted animation, rebuild mid-scroll) the pending refresh still
  // lands instead of leaving the chat frozen until the screen is reopened.
  Timer? _pendingRefreshTimer;
  int _messagePageSize = 50; // Load 50 messages at a time
  int _reminderCount = 0;
  int _warningCount = 0;
  int _statusRequestCount = 0;
  final Map<String, double> _uploadProgress = {}; // messageId → 0.0..1.0
  DateTime? _selectedReminderDate; // For inline reminder
  StreamSubscription? _messagesSubscription; // SQLite messages stream
  StreamSubscription<TaskModel?>? _taskSubscription; // SQLite task stream
  Timer? _autoActivateTimer; // Timer for auto-activation check
  final ValueNotifier<bool> _showScrollToBottom = ValueNotifier<bool>(
    false,
  ); // Show scroll to bottom button
  final ValueNotifier<bool> _showScrollToTop = ValueNotifier<bool>(
    false,
  ); // Show scroll to top button
  final ValueNotifier<int> _newMessageCount = ValueNotifier<int>(
    0,
  ); // Unread new messages count (WhatsApp-style)

  // Rating state
  List<Map<String, dynamic>> _taskRatings = [];
  Map<String, List<int>> _taskCriteriaRatings = {};
  late TaskModel _currentTask;
  String? _resolvedCreatorName;
  String? _creatorNameLookupUid;
  // UID → resolved display name cache for chat/activity attribution
  // (multi-assignee co-participants aren't covered by creator/assignee fields)
  final Map<String, String> _resolvedSenderNames = {};
  final Set<String> _senderNameLookupsInFlight = {};

  // Creation mode state
  bool _isCreationMode = false;
  AssignableContact? _creationAssignee;

  // Chat message keys (search/screenshot state now lives in DetailChatMenuMixin)
  final Map<String, GlobalKey> _messageKeys = {};

  // Multi-select mode (WhatsApp-style)
  bool _isSelecting = false;
  final Set<String> _selectedMessageIds = {};

  // Track whether text field has content (for mic/send toggle)
  final ValueNotifier<bool> _hasText = ValueNotifier(false);

  // ── Send Later (in-app only) ──────────────────────────────────────
  // Scheduled chat messages are held in a local SharedPreferences outbox (no
  // background / push delivery). While this task's chat is open a periodic
  // timer flushes ones that come due; on re-open they flush on load — the
  // message finally goes out through the normal send path at/after its time.
  static const String _scheduledOutboxKey = 'scheduled_messages_outbox';
  final List<MessageModel> _scheduledMessages = [];
  Timer? _scheduledFlushTimer;

  // WhatsApp-style @mention picker for the chat composer (many-assignee chats).
  late final ChatMentionController _mention = ChatMentionController(
    candidatesProvider: _mentionCandidates,
  );

  /// Display names eligible for @mention — everyone on this task (assignees,
  /// co-participants and the creator), de-duplicated and sorted.
  List<String> _mentionCandidates() {
    final names = <String>{};
    void addAll(Object? raw) {
      if (raw is List) {
        for (final n in raw) {
          final s = '$n'.trim();
          if (s.isNotEmpty) names.add(s);
        }
      }
    }

    final extra = _currentTask.extraFields;
    addAll(extra?['participantNames']);
    addAll(extra?['assigneeNames']);
    final assigned = _currentTask.assignedTo.trim();
    if (assigned.isNotEmpty) names.add(assigned);
    final creator = (_currentTask.createdByName ?? '').trim();
    if (creator.isNotEmpty) names.add(creator);
    for (final n in _resolvedSenderNames.values) {
      final s = n.trim();
      if (s.isNotEmpty) names.add(s);
    }
    final list = names.toList()..sort();
    return list;
  }

  // WhatsApp-style reply state
  MessageModel? _replyingToMessage;

  @override
  void initState() {
    super.initState();
    _currentTask = widget.task;
    _loadCustomFieldLabels();

    // Detect creation mode
    if (widget.creationAssignee != null) {
      _isCreationMode = true;
      _creationAssignee = widget.creationAssignee;
      return; // Skip normal initialization — creation widget handles everything
    }

    _resolveCreatorNameIfNeeded();

    print('[TaskDetail] Task description: "${_currentTask.description}"');
    print(
      '[TaskDetail] Task description is empty: ${_currentTask.description.isEmpty}',
    );

    // Add scroll listener for pagination
    _scrollController.addListener(_onScroll);

    // Background server cleanup (receipts backfill + minimal-server deletes)
    scheduleChatCleanupSweep(context.read<AuthProvider>().effectivePlanType);

    // Listen to text input to toggle mic/send button
    _messageController.addListener(() {
      final hasText = _messageController.text.trim().isNotEmpty;
      if (hasText != _hasText.value) {
        _hasText.value = hasText;
      }
      // Keep the @mention dropdown in sync with the caret / typed text.
      _mention.updateFrom(_messageController.value);
    });

    // Auto-activate if scheduled time has arrived
    _checkAndAutoActivate();

    // Initialize counts from task
    _reminderCount = widget.task.reminderCount;
    _warningCount = widget.task.warningCount;
    _statusRequestCount = widget.task.statusRequestCount;

    // Load messages from Firebase stream
    _loadMessagesFromFirebase();

    // Load + start flushing this task's scheduled ("Send Later") messages.
    _initScheduledMessages();

    // Listen to task updates from Firebase
    _loadTaskFromFirebase();

    // Initialize empty ratings (real ratings come from Firestore)
    _taskRatings = [];

    // Check every minute for auto-activation of scheduled tasks
    _autoActivateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkAndAutoActivate();
    });

    // Check connectivity immediately and then every 15 seconds
    startConnectivityMonitor();

    // Draft stage: keyboard + cursor ready on the message box
    _focusMessageInputIfDraft();
  }

  /// Called by the embedded TaskCreationChatScreen when the task is created.
  /// Transitions from creation mode to normal task detail mode.
  void _onTaskCreated(TaskModel createdTask) {
    setState(() {
      _isCreationMode = false;
      _currentTask = createdTask;
      _creationAssignee = null;
    });

    // Now initialize all the normal task detail state
    _resolveCreatorNameIfNeeded();
    _scrollController.addListener(_onScroll);
    _checkAndAutoActivate();
    _reminderCount = createdTask.reminderCount;
    _warningCount = createdTask.warningCount;
    _statusRequestCount = createdTask.statusRequestCount;
    _loadMessagesFromFirebase();
    _loadTaskFromFirebase();
    _taskRatings = [];
    // Cancel the timer created in initState before reassigning, otherwise the
    // original 60s periodic timer is orphaned (its only reference is dropped)
    // and keeps firing _checkAndAutoActivate() forever after each task creation.
    _autoActivateTimer?.cancel();
    _autoActivateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkAndAutoActivate();
    });

    // Draft stage: keyboard + cursor ready on the message box
    _focusMessageInputIfDraft();
  }

  // Handle scroll for pagination (load more messages when scrolling to top)
  void _onScroll() {
    // NOTE: _isUserScrolling is set from ScrollStartNotification (drag only)
    // in the chat NotificationListener — flagging here would also mark
    // programmatic scrolls (scroll-to-bottom, activity jumps) as user
    // scrolls and could defer stream updates forever.

    // With reverse:true, maxScrollExtent = TOP (oldest messages), 0 = BOTTOM (newest)
    // If user scrolls near maxScrollExtent (top = oldest), load more messages
    if (_scrollController.position.pixels >
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        _messages.length < _allMessages.length) {
      _loadMoreMessages();
    }

    // Show/hide scroll to bottom button (uses ValueNotifier to avoid rebuilding ListView)
    // "At bottom" = near scroll position 0 (newest messages visible)
    final isAtBottom = _scrollController.position.pixels <= 100;
    if (_showScrollToBottom.value == isAtBottom) {
      _showScrollToBottom.value = !isAtBottom;
    }

    // Show/hide scroll to top button
    // "At top" = near maxScrollExtent (oldest messages/enquiry card visible)
    final isAtTop =
        _scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 100;
    if (_showScrollToTop.value == isAtTop) {
      _showScrollToTop.value = !isAtTop;
    }
  }

  // (No end-of-history hint: the app cannot truly detect an offline gap, so a
  //  'older messages purged' pill was not credible and has been removed.)

  // Load more older messages
  void _loadMoreMessages() {
    if (_isLoadingMore || _messages.length >= _allMessages.length) return;

    setState(() {
      _isLoadingMore = true;
    });

    // Calculate how many more to load
    final newPageSize =
        (_messagePageSize * 2); // Load double the previous amount

    // Apply visibility filtering to all messages
    final visibleMessages = MessageVisibilityService.getVisibleMessages(
      allMessages: _allMessages,
      participantHistory: widget.task.participantHistory,
      viewerId: _currentUserId,
      currentParticipants: _currentTask.participants,
    );

    // Get more messages from the beginning
    final newDisplayCount = _messages.length + newPageSize;
    final finalStartIndex = visibleMessages.length - newDisplayCount;
    final actualStartIndex2 = finalStartIndex < 0 ? 0 : finalStartIndex;

    setState(() {
      _messages = visibleMessages.sublist(actualStartIndex2);
      _rebuildDisplayMessages();
      _isLoadingMore = false;
    });

    print(
      '[TaskDetail] Loaded more messages: now showing ${_messages.length} of ${_allMessages.length}',
    );
  }

  // Re-query SQLite after deferred stream update (called when user stops scrolling)
  void _refreshFromStream() async {
    final messages = await LocalDatabaseService().getMessages(_currentTask.id);
    if (!mounted || messages.isEmpty) return;
    final filteredForUser = messages.where((m) {
      if (m.deletedFor.contains(_currentUserId)) return false;
      return true;
    }).toList();
    final visibleMessages = MessageVisibilityService.getVisibleMessages(
      allMessages: filteredForUser,
      participantHistory: widget.task.participantHistory,
      viewerId: _currentUserId,
      currentParticipants: _currentTask.participants,
    );
    final displayCount = visibleMessages.length > _messagePageSize
        ? _messagePageSize
        : visibleMessages.length;
    final startIndex = visibleMessages.length - displayCount;
    final paginatedMessages = visibleMessages.sublist(
      startIndex < 0 ? 0 : startIndex,
    );
    if (mounted) {
      setState(() {
        _allMessages = messages;
        // Set-based id lookup instead of nested .any() scans — the O(n²)
        // version caused visible scroll jank on long chats.
        final paginatedIds = paginatedMessages.map((p) => p.id).toSet();
        final pendingMessages = _messages
            .where((m) => !paginatedIds.contains(m.id))
            .toList();
        _messages = List<MessageModel>.from(paginatedMessages)
          ..addAll(pendingMessages);
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _rebuildDisplayMessages();
      });
    }
  }

  // Load messages from SQLite stream (background sync writes to SQLite)
  void _loadMessagesFromFirebase() {
    final taskProvider = context.read<TaskProvider>();

    // Start background syncs (Firestore -> SQLite)
    FirebaseService().startMessageSync(_currentTask.id);
    FirebaseService().startTaskDetailSync(_currentTask.id);
    FirebaseService().startMilestoneSync(_currentTask.id);
    FirebaseService().startSystemLogSync(_currentTask.id);

    // Durable action log: watch the SQLite copy of system_logs so recovered
    // entries (chat swept / device restored) appear in the Activity section.
    _systemLogSub?.cancel();
    _systemLogSub = LocalDatabaseService()
        .watchSystemLogs(_currentTask.id)
        .listen((logs) {
          if (!mounted) return;
          setState(() => _recoveredLogs = logs);
          _backfillSystemLogs();
        });

    // Subscribe to SQLite-backed stream
    _messagesSubscription = LocalDatabaseService()
        .watchMessages(_currentTask.id)
        .listen(
          (messages) {
            if (mounted) {
              print(
                '[TaskDetail] Stream: ${messages.length} messages for task ${_currentTask.id}',
              );

              // Store ALL messages
              _allMessages = messages;

              // Filter out messages deleted for this user
              final filteredForUser = messages.where((m) {
                if (m.deletedFor.contains(_currentUserId)) return false;
                return true;
              }).toList();

              // Apply visibility filtering
              final visibleMessages =
                  MessageVisibilityService.getVisibleMessages(
                    allMessages: filteredForUser,
                    participantHistory: widget.task.participantHistory,
                    viewerId: _currentUserId,
                    currentParticipants: _currentTask.participants,
                  );

              // Show latest messages by default
              final targetMessageId = widget.scrollToMessageId;
              final targetIndex = targetMessageId == null
                  ? -1
                  : visibleMessages.indexWhere((m) => m.id == targetMessageId);
              final displayCount = visibleMessages.length > _messagePageSize
                  ? _messagePageSize
                  : visibleMessages.length;

              var startIndex = visibleMessages.length - displayCount;
              if (targetIndex >= 0 && targetIndex < startIndex) {
                startIndex = targetIndex;
              }
              final paginatedMessages = visibleMessages.sublist(startIndex);

              // Set-based id lookups — the old nested .any() scans were
              // O(n²) on every stream emission and froze scrolling on
              // long chats.
              final existingIds = _messages.map((old) => old.id).toSet();

              // Check if there are new messages (for scroll logic only)
              final hasNewMessages =
                  paginatedMessages.length != _messages.length ||
                  paginatedMessages.any((m) => !existingIds.contains(m.id));

              // Count truly new messages from OTHERS. System cards are
              // included on purpose: action posts (query / follow-up /
              // meeting / visit / approval …) ride as system messages, and
              // the user asked that a new action raise the WhatsApp-style
              // down-arrow instead of the view shifting under them. Own
              // sends stay excluded (the sender is already at the message).
              final newMessagesFromOthers = paginatedMessages
                  .where(
                    (m) =>
                        !existingIds.contains(m.id) &&
                        m.senderId != _currentUserId,
                  )
                  .length;

              // Check if user was EXACTLY at the bottom before the update
              // With reverse:true, bottom = scroll position 0
              final isAtVeryBottom =
                  !_scrollController.hasClients ||
                  _scrollController.position.pixels <= 10;
              final isFirstLoad = _messages.isEmpty;

              // Always sync state with SQLite stream (ensures optimistic messages
              // are replaced with authoritative DB data and nothing gets lost)
              if (!_isScrollingToMessage) {
                if (_isUserScrolling) {
                  // User is actively scrolling — defer update to avoid jank
                  _pendingStreamRefresh = true;
                  // Arm the fallback once — if ScrollEnd never fires the
                  // deferred refresh still lands a couple of seconds later.
                  _pendingRefreshTimer ??= Timer(
                    const Duration(seconds: 2),
                    () {
                      _pendingRefreshTimer = null;
                      if (_pendingStreamRefresh) {
                        _pendingStreamRefresh = false;
                        _isUserScrolling = false;
                        _refreshFromStream();
                      }
                    },
                  );
                } else {
                  setState(() {
                    // Use SQLite as source of truth, but preserve any optimistic
                    // messages not yet persisted (race condition guard)
                    final paginatedIds = paginatedMessages
                        .map((p) => p.id)
                        .toSet();
                    final pendingMessages = _messages
                        .where((m) => !paginatedIds.contains(m.id))
                        .toList();
                    _messages = List<MessageModel>.from(paginatedMessages)
                      ..addAll(pendingMessages);
                    _messages.sort(
                      (a, b) => a.createdAt.compareTo(b.createdAt),
                    );
                    _rebuildDisplayMessages();
                  });
                }
              }

              // Mark all messages as read when chat is opened
              markChatMessagesAsRead(messages);

              // Cache ALL messages (unfiltered) in provider for the Actions tab
              taskProvider.cacheMessages(_currentTask.id, messages);

              // Handle scroll position
              if (hasNewMessages || isFirstLoad) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  // Don't return early if !hasClients — _scrollToLatestMessage
                  // and _scrollToMessageById both have frame-retry built in.

                  if (!_initialScrollDone) {
                    // First scroll ever — scroll to bottom (or target message)
                    _initialScrollDone = true;
                    if (widget.scrollToMessageId != null) {
                      _scrollToMessageById(widget.scrollToMessageId!);
                    } else {
                      _scrollToLatestMessage();
                    }
                    _newMessageCount.value = 0;
                  } else if (widget.scrollToMessageId != null &&
                      !_isScrollingToMessage) {
                    _scrollToMessageById(widget.scrollToMessageId!);
                  } else if (_justSentMessage) {
                    _justSentMessage = false;
                    _newMessageCount.value = 0;
                  } else if (isAtVeryBottom && !_isScrollingToMessage) {
                    // Never yank to the bottom while a scroll-to-message is
                    // settling — the jump starts at pixels≈0, so
                    // isAtVeryBottom still reads true mid-animation (Sales
                    // mirror carries the same guard).
                    _scrollToLatestMessage();
                    _newMessageCount.value = 0;
                  } else {
                    // User is NOT at bottom — preserve scroll, increment unread count
                    if (newMessagesFromOthers > 0) {
                      _newMessageCount.value += newMessagesFromOthers;
                    }
                  }
                });
              }
            }
          },
          onError: (error, stackTrace) {
            print('[TaskDetail] ERROR in message stream: $error');
            print('[TaskDetail] Stack trace: $stackTrace');
            // Don't clear messages on stream error — preserves optimistic UI
            // and previously loaded messages. Stream will resume on next change.
          },
        );
  }

  // Listen to task updates from SQLite to keep _currentTask fresh
  void _loadTaskFromFirebase() {
    try {
      final taskProvider = context.read<TaskProvider>();
      _taskSubscription = taskProvider
          .taskStream(_currentTask.id)
          .listen(
            (task) {
              if (task != null && mounted) {
                // Repaint the card only on a real CONTENT change. A
                // message send bumps updatedAt (and the reminder/warning/
                // status counters) without touching any card field, so
                // comparing a card signature — not the whole model — keeps
                // the chat from rebuilding (and the scroll from shifting)
                // on every send, while still catching urgency / deadline /
                // priority / status / assignee / participant edits made on
                // the other side.
                if (_taskCardSignature(_currentTask) !=
                    _taskCardSignature(task)) {
                  setState(() {
                    _currentTask = task;
                  });
                }
                _resolveCreatorNameIfNeeded();
              }
            },
            onError: (error) {
              print('[TaskDetail] Error loading task: $error');
            },
          );
    } catch (e) {
      print('[TaskDetail] Error setting up task stream: $e');
    }
  }

  // Signature of the fields rendered on the task detail card / header. Used
  // by the taskStream listener to tell a genuine edit apart from a
  // message-send timestamp bump. Deliberately EXCLUDES updatedAt,
  // lastMessage*, and the reminder / warning / status / unread counters —
  // those move on every send and must not rebuild the chat.
  String _taskCardSignature(TaskModel t) {
    final participants = (t.participants.toSet().toList()..sort()).join(',');
    // Assignee name/phone lists: removing a NON-primary assignee, or an
    // external contact who has no UID, leaves assignedTo / assignedToUid /
    // participants unchanged — so without folding these in the signature is
    // identical and the card never repaints (the removed person keeps showing).
    final assigneeNames = (t.extraFields?['assigneeNames'] is List)
        ? (t.extraFields!['assigneeNames'] as List).join('\u0002')
        : '';
    final participantNames = (t.extraFields?['participantNames'] is List)
        ? (t.extraFields!['participantNames'] as List).join('\u0002')
        : '';
    final assigneePhones = (t.extraFields?['assigneePhones'] is List)
        ? (t.extraFields!['assigneePhones'] as List).join('\u0002')
        : '';
    final parts = <String>[
      t.id,
      t.title,
      t.description,
      '${t.priority}',
      '${t.isUrgent}',
      '${t.deadline?.millisecondsSinceEpoch ?? 0}',
      '${t.startDate?.millisecondsSinceEpoch ?? 0}',
      '${t.progress}',
      t.category ?? '',
      '${t.isClosed}',
      '${t.isCancelled}',
      '${t.rating ?? -1}',
      t.assignedTo,
      t.assignedToUid ?? '',
      participants,
      assigneeNames,
      participantNames,
      assigneePhones,
      '${t.extraFields?['urgencyState'] ?? ''}',
      '${t.extraFields?['isBlocked'] ?? false}',
    ];
    return parts.join('\u0001');
  }

  @override
  void dispose() {
    _highlightClearTimer?.cancel();
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    _mention.dispose();
    _messagesSubscription?.cancel();
    _taskSubscription?.cancel();
    // Stop background syncs
    FirebaseService().stopMessageSync(_currentTask.id);
    FirebaseService().stopTaskDetailSync(_currentTask.id);
    FirebaseService().stopMilestoneSync(_currentTask.id);
    FirebaseService().stopSystemLogSync(_currentTask.id);
    _systemLogSub?.cancel();
    _autoActivateTimer?.cancel();
    _pendingRefreshTimer?.cancel();
    _scheduledFlushTimer?.cancel();
    disposeDetailChatBubbles();
    disposeDetailChatAttachments();
    disposeDetailChatPlumbing();
    disposeDetailChatMenu();
    _showScrollToBottom.dispose();
    _showScrollToTop.dispose();
    _newMessageCount.dispose();
    _hasText.dispose();
    super.dispose();
  }

  // Search, share & export capabilities now live in DetailChatMenuMixin.

  // Parse natural language date/time from message text
  DateTime? _parseDateTimeFromText(String text) {
    final now = DateTime.now();
    final lowerText = text.toLowerCase().trim();

    // Helper: extract time from phrases like "at 9pm", "at 14:30", "9:30 am"
    int _extractHour(String s, int defaultHour) {
      final t = RegExp(
        r'(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)',
        caseSensitive: false,
      ).firstMatch(s);
      if (t != null) {
        int h = int.parse(t.group(1)!);
        final p = t.group(3)!.toLowerCase();
        if (p == 'pm' && h < 12) h += 12;
        if (p == 'am' && h == 12) h = 0;
        return h;
      }
      // 24h format: "at 14:00" or "14:30"
      final t24 = RegExp(r'(?:at\s*)?(\d{1,2}):(\d{2})').firstMatch(s);
      if (t24 != null) return int.parse(t24.group(1)!);
      return defaultHour;
    }

    int _extractMinute(String s) {
      final t = RegExp(r'(?:at\s*)?\d{1,2}:(\d{2})').firstMatch(s);
      return t != null ? int.parse(t.group(1)!) : 0;
    }

    // Pattern 1: "today" or "tomorrow" (optionally with time)
    if (lowerText == 'today' || lowerText.startsWith('today')) {
      final h = _extractHour(lowerText, 9);
      final m = _extractMinute(lowerText);
      return DateTime(now.year, now.month, now.day, h, m);
    }
    if (lowerText == 'tomorrow' || lowerText.startsWith('tomorrow')) {
      final h = _extractHour(lowerText, 9);
      final m = _extractMinute(lowerText);
      return DateTime(now.year, now.month, now.day + 1, h, m);
    }

    // Pattern 2: Day names (monday, tuesday, etc.) optionally with time
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
        final h = _extractHour(lowerText, 9);
        final m = _extractMinute(lowerText);
        return DateTime(now.year, now.month, now.day + daysUntil, h, m);
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

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty && _selectedReminderDate == null) return;

    // If task is still a draft, show message first, then prompt to activate
    final isDraft = _currentTask.extraFields?['isDraft'] == true;
    if (isDraft && !_draftDialogDismissed) {
      // Create and show message in chat immediately
      final draftMessage = MessageModel(
        id: Helpers.generateId(),
        taskId: _currentTask.id,
        senderId: _currentUserId,
        text: text,
        type: MessageType.text,
        createdAt: DateTime.now(),
        deliveryMethod: 'in-app',
      );
      setState(() {
        _messages.add(draftMessage);
        _rebuildDisplayMessages();
        _messageController.clear();
      });
      _scrollToBottom();

      // Brief pause for message to render before showing dialog
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      final result = await _showDraftActivationDialog(suggestedTitle: text);
      // Keep the keyboard/cursor on the message box through the draft stage
      if (mounted) _messageFocusNode.requestFocus();
      if (result == null) {
        // User cancelled — allow further messages without re-showing dialog
        setState(() {
          _draftDialogDismissed = true;
        });
        // Save the message to Firebase
        _saveMessageToFirebase(draftMessage);
        return;
      } else {
        // Title is applied TOGETHER with the activation below — a separate
        // title-only write still carried isDraft:true and could land last
        // (locally or on the server), snapping the task back to draft.
        final rawTitle = (result['title'] as String?)?.trim() ?? '';
        // The dialog validates non-empty, but fall back to the message
        // text rather than a placeholder string if it ever comes back blank.
        final newTitle = rawTitle.isNotEmpty ? rawTitle : text;

        if (result['action'] == 'schedule') {
          // Show date picker after dialog closes
          if (!mounted) return;
          final pickedDate = await showDatePicker(
            context: context,
            initialDate: DateTime.now().add(const Duration(days: 1)),
            firstDate: DateTime.now(),
            lastDate: DateTime(2030),
          );
          if (pickedDate == null) {
            // User cancelled date picker — save message anyway
            _saveMessageToFirebase(draftMessage);
            return;
          }
          await _activateDraftTask(startDate: pickedDate, title: newTitle);
        } else {
          await _activateDraftTask(title: newTitle);
        }
        // Save the message to Firebase after activation
        // Update taskId in case the task was promoted from onboarding draft
        final messageToSave = draftMessage.taskId != _currentTask.id
            ? draftMessage.copyWith(taskId: _currentTask.id)
            : draftMessage;
        _saveMessageToFirebase(messageToSave);
        return;
      }
    }

    final externalService = ExternalNotificationService();
    // B6: resolve the assignee from the task's own persisted fields. The
    // previous getAssigneeUser([], ...) was handed an EMPTY team list, so its
    // firstWhere always threw and the catch returned null — the guard below
    // could never be true and this whole off-app branch was dead code.
    final recipient = _externalRecipient();

    // If assignee is not on the app, offer to send via WhatsApp/SMS
    if (recipient != null && recipient.needsExternalNudge) {
      final message = externalService.formatTextMessageForTitle(
        _currentTask.title,
        _currentUserName,
        text,
      );

      _showExternalDeliveryDialog(
        title: 'Send Message',
        message: message,
        onSent: (deliveryMethod) async {
          final newMessage = MessageModel(
            id: Helpers.generateId(),
            taskId: _currentTask.id,
            senderId: _currentUserId,
            text: text,
            type: MessageType.text,
            createdAt: DateTime.now(),
            deliveryMethod: deliveryMethod,
          );

          // Check if message contains a date/time - auto-create reminder
          DateTime? parsedDate = _selectedReminderDate;
          String? reminderText;

          if (parsedDate == null) {
            parsedDate = _parseDateTimeFromText(text);
            if (parsedDate != null) {
              reminderText = text;
            }
          }

          // Optimistically add to local list FIRST
          setState(() {
            _messages.add(newMessage);
            _rebuildDisplayMessages();
            _messageController.clear();
          });

          // Save to Firebase
          try {
            _saveMessageToFirebase(newMessage);
            print('[TaskDetail] External message saved successfully');
          } catch (e) {
            print('[TaskDetail] Error saving external message: $e');
          }

          // Add reminder if date is set (stream will update UI)
          if (parsedDate != null && _selectedReminderDate == null) {
            final reminderMsg = MessageModel(
              id: Helpers.generateId(),
              taskId: _currentTask.id,
              senderId: _currentUserId,
              text: reminderText != null
                  ? 'Reminder "$reminderText"'
                  : 'Reminder',
              type: MessageType.system,
              createdAt: DateTime.now(),
            );

            try {
              _saveMessageToFirebase(reminderMsg);
            } catch (e) {
              print('[TaskDetail] Error saving reminder: $e');
            }
          }

          // Add delivery confirmation
          if (deliveryMethod != 'in-app') {
            final deliveryMsg = MessageModel(
              id: Helpers.generateId(),
              taskId: _currentTask.id,
              senderId: _currentUserId,
              text:
                  '💬 Message sent to ${widget.task.assignedTo} via ${deliveryMethod == 'whatsapp'
                      ? 'WhatsApp'
                      : deliveryMethod == 'sms'
                      ? 'SMS'
                      : 'unknown'}',
              type: MessageType.system,
              createdAt: DateTime.now(),
              deliveryMethod: deliveryMethod,
            );

            try {
              _saveMessageToFirebase(deliveryMsg);
            } catch (e) {
              print('[TaskDetail] Error saving delivery confirmation: $e');
            }
          }

          _scrollToBottom();
        },
      );
    } else {
      // Normal in-app message
      final newMessage = MessageModel(
        id: Helpers.generateId(),
        taskId: _currentTask.id,
        senderId: _currentUserId,
        text: text,
        type: MessageType.text,
        createdAt: DateTime.now(),
        deliveryMethod: 'in-app',
        replyToMessageId: _replyingToMessage?.id,
        replyToMessageText: _replyingToMessage?.text,
        replyToMessageSender: _replyingToMessage != null
            ? _getSenderName(_replyingToMessage!.senderId)
            : null,
      );

      // Check if message contains a date/time - auto-create reminder
      DateTime? parsedDate = _selectedReminderDate;
      String? reminderText;

      // Try to parse date from message text if no reminder date is set
      if (parsedDate == null) {
        parsedDate = _parseDateTimeFromText(text);
        if (parsedDate != null) {
          reminderText = text;
        }
      }

      // Optimistically add to local list FIRST for immediate display
      setState(() {
        _messages.add(newMessage);
        _rebuildDisplayMessages();
        _messageController.clear();
        _replyingToMessage = null;
      });

      // Save to Firebase
      try {
        _saveMessageToFirebase(newMessage);
        print('[TaskDetail] In-app message saved successfully');
      } catch (e) {
        print('[TaskDetail] Error saving in-app message: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Message not saved: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
              action: SnackBarAction(
                label: 'Retry',
                textColor: Colors.white,
                onPressed: () => _saveMessageToFirebase(newMessage),
              ),
            ),
          );
        }
      }

      // Add reminder if date is set (stream will update UI)
      if (parsedDate != null && _selectedReminderDate == null) {
        final reminderMsg = MessageModel(
          id: Helpers.generateId(),
          taskId: _currentTask.id,
          senderId: _currentUserId,
          text: reminderText != null ? 'Reminder "$reminderText"' : 'Reminder',
          type: MessageType.system,
          createdAt: DateTime.now(),
        );

        _saveMessageToFirebase(reminderMsg);
        print('[TaskDetail] Reminder saved successfully');
      }

      // Scroll to bottom
      _scrollToBottom();
    }
  }

  /// Show activation dialog for draft tasks.
  /// Returns 'activate', 'schedule', or null (dismissed).
  /// Show the draft activation dialog with title edit, date picker, and action buttons.
  /// Returns a map with 'action' ('activate'|'schedule'|null), 'title' (String), 'date' (DateTime?).
  Future<Map<String, dynamic>?> _showDraftActivationDialog({
    String? suggestedTitle,
  }) async {
    // Pre-fill title: use existing title if set, otherwise use suggested title from message
    final currentTitle = _currentTask.title.isNotEmpty
        ? _currentTask.title
        : (suggestedTitle ?? '');
    final titleController = TextEditingController(text: currentTitle);
    String? titleError; // Shown in the header when title is submitted empty

    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          child: StatefulBuilder(
            builder: (context, setDialogState) => Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header (small, grey — turns into the error prompt when
                      // the title is submitted empty)
                      Text(
                        titleError ?? 'Activate Task',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: titleError != null
                              ? const Color(0xFFE03131)
                              : AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Task title text field
                      TextField(
                        controller: titleController,
                        autofocus: _currentTask.title.isEmpty,
                        maxLength: 100,
                        decoration: InputDecoration(
                          labelText: 'Task Title',
                          hintText: 'Enter task title...',
                          counterText: '',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 15),
                      ),
                      const SizedBox(height: 16),

                      // Action buttons (Schedule + Activate only, X handles cancel)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                final t = titleController.text.trim();
                                if (t.isEmpty) {
                                  setDialogState(
                                    () => titleError = 'Enter Task title',
                                  );
                                  return;
                                }
                                Navigator.pop(context, {
                                  'action': 'schedule',
                                  'title': t,
                                });
                              },
                              icon: const Icon(Icons.event_note, size: 16),
                              label: const Text('Schedule'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.primaryGreen,
                                side: const BorderSide(
                                  color: AppTheme.primaryGreen,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                final t = titleController.text.trim();
                                if (t.isEmpty) {
                                  setDialogState(
                                    () => titleError = 'Enter Task title',
                                  );
                                  return;
                                }
                                Navigator.pop(context, {
                                  'action': 'activate',
                                  'title': t,
                                });
                              },
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('Activate'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // X close button (top-right)
                Positioned(
                  right: -8,
                  top: -8,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.pop(context, null),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        child: const Icon(
                          Icons.close,
                          size: 20,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Activate a draft task — removes isDraft flag and optionally sets
  /// startDate and/or title. Title + activation go out as ONE write.
  Future<void> _activateDraftTask({DateTime? startDate, String? title}) async {
    try {
      // Capture old status BEFORE updating for the transition message
      final oldStatus = _getTaskStatus();

      final updatedExtraFields = <String, dynamic>{
        ...?_currentTask.extraFields,
      };
      // Explicitly set to null — FirebaseService.updateTask translates null
      // entries into FieldValue.delete() (Firestore rejects nulls inside
      // nested maps, and omitting the key would let the merge keep it).
      updatedExtraFields['isDraft'] = null;
      updatedExtraFields['scheduledDate'] = null;

      // Drafts skip ID generation on create — assign the sequential
      // displayId now so the activated task carries its #N like any other.
      int? displayId = _currentTask.displayId;
      if (displayId == null) {
        try {
          displayId = await SequentialIdService().getNextId('task');
        } catch (e) {
          print('[TaskDetail] displayId generation failed: $e');
        }
      }

      final updatedTask = await _withResolvedAssignee(
        _currentTask.copyWith(
          title: title ?? _currentTask.title,
          extraFields: updatedExtraFields,
          displayId: displayId,
          startDate: startDate ?? _currentTask.startDate,
          updatedAt: DateTime.now(),
        ),
      );
      setState(() {
        _currentTask = updatedTask;
      });
      // Update via provider (SQLite-first, Firestore fire-and-forget)
      await context.read<TaskProvider>().updateTask(
        _currentTask.id,
        updatedTask,
      );
      // Belt-and-braces server write: pin the flag to false on the doc so a
      // concurrent full-map merge can never resurrect isDraft:true.
      FirebaseService().markTaskActive(_currentTask.id).catchError((e) {
        print('[TaskDetail] isDraft pin write failed: $e');
      });
      print('[TaskDetail] Draft task activated');

      final timestamp = Helpers.formatDateTime(DateTime.now());
      await _sendSystemMessage(
        '📊 Status changed: $oldStatus → Active by $_currentUserName at $timestamp',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Task activated'),
            duration: Duration(seconds: 2),
            backgroundColor: AppTheme.primaryGreen,
          ),
        );
      }
    } catch (e) {
      print('[TaskDetail] Error activating draft task: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to activate task: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Tasks created through name-only flows can lack the assignee's UID/phone
  /// (participants then holds just the creator, so the assignee device never
  /// receives the task). Resolve the assignee against the in-app directory and
  /// patch the identity fields before the update is pushed to Firestore.
  Future<TaskModel> _withResolvedAssignee(TaskModel task) async {
    if ((task.assignedToUid ?? '').isNotEmpty) return task;
    final name = task.assignedTo.trim();
    if (name.isEmpty) return task;
    try {
      final members = await ContactPickerService().getTeamMembers();
      final lower = name.toLowerCase();
      String? matchUid;
      String? matchPhone;
      for (final m in members) {
        if ((m.uid ?? '').isEmpty) continue;
        if (m.name.trim().toLowerCase() != lower) continue;
        matchUid = m.uid;
        matchPhone = m.phone;
        break;
      }
      if (matchUid == null) return task;
      return task.copyWith(
        assignedToUid: matchUid,
        assignedToPhone:
            Helpers.normalizePhone(matchPhone) ?? task.assignedToPhone,
        participants: {...task.participants, matchUid}.toList(),
      );
    } catch (e) {
      print('[TaskDetail] Assignee identity resolution failed: $e');
      return task;
    }
  }

  // Helper method to save message to Firebase — fire-and-forget.
  // NOTE: Caller already adds message to _messages and clears input.
  void _saveMessageToFirebase(MessageModel message, {bool scroll = true}) {
    // 1. Scroll to bottom (position 0 with reverse:true). Skipped for card
    //    edit/action system messages so the view stays where the user is
    //    (they can tap the down arrow to see the new entry).
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          if (scroll) _scrollController.jumpTo(0);
          _justSentMessage = true;
        }
      });
    }

    // 2. Fire-and-forget: SQLite write + Firestore delivery (don't block UI)
    try {
      final taskProvider = context.read<TaskProvider>();
      taskProvider.sendMessage(_currentTask.id, message).catchError((e) {
        print('[TaskDetail] Error saving message: $e');
        // Show error SnackBar for failed message sends
        if (mounted) {
          _showMessageSendErrorSnackBar(message, e);
        }
      });
      // The recipient's unread badge is bumped inside TaskProvider.sendMessage
      // as part of the same atomic Firestore update that touches the task's
      // updatedAt, so every send path raises it — not just the typed messages
      // sent from here. A separate updatedAt-silent write could lose the
      // increment against a device that delta-synced on the clock bump.
      // Durable action log: mirror system action messages into the task's
      // system_logs subcollection (doc id = message id) so the log survives
      // chat retention and can be recovered on any device.
      if (message.type == MessageType.system && _isActionLogMessage(message)) {
        FirebaseService().writeSystemLog(
          taskId: _currentTask.id,
          messageId: message.id,
          action: _parseActionDetails(message).title,
          performedBy: message.senderId,
          details: message.text,
          createdAt: message.createdAt,
        );
      }
    } catch (e) {
      print('[TaskDetail] Error saving message: $e');
    }
  }

  /// Show error SnackBar with retry for failed text/system messages.
  void _showMessageSendErrorSnackBar(MessageModel message, dynamic error) {
    final isSystem = message.type == MessageType.system;
    final label = isSystem ? 'Status update failed' : 'Message failed to send';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label: $error'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: () => _saveMessageToFirebase(message),
        ),
      ),
    );
  }

  // Helper method to update task in Firebase without blocking local UI
  Future<void> _updateTaskInFirebase(
    TaskModel task, {
    bool clearAssignee = false,
  }) async {
    try {
      final taskProvider = context.read<TaskProvider>();
      taskProvider
          .updateTask(_currentTask.id, task, clearAssignee: clearAssignee)
          .catchError((e) {
            print('Error updating task in Firebase: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Could not sync update: $e'),
                  backgroundColor: Colors.red,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          });
    } catch (e) {
      print('Error starting task update: $e');
    }
  }

  /// Reset current user's unread count to 0 when opening the task.
  void _resetMyUnreadCount() {
    context.read<TaskProvider>().resetMyUnreadCount(
      _currentTask.id,
      _currentUserId,
    );
  }

  /// Build the creation mode UI — embeds TaskCreationChatScreen
  Widget _buildCreationMode() {
    final assignee = _creationAssignee!;
    return Scaffold(
      backgroundColor: AppTheme.headerGreen,
      appBar: AppBar(
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          // Use maybePop to trigger WillPopScope (saves draft on back press)
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: assignee.isOnApp
                  ? Colors.white.withOpacity(0.2)
                  : Colors.grey.withOpacity(0.2),
              child: Text(
                assignee.name.isNotEmpty ? assignee.name[0].toUpperCase() : '?',
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
                    assignee.name,
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
      ),
      body: TaskCreationChatScreen(
        key: ValueKey('creation_${assignee.uid ?? assignee.phone}'),
        assignee: assignee,
        onTaskCreated: _onTaskCreated,
        onDraftSaved: () {
          // Refresh home task list after draft is saved on back press
          if (mounted) {
            context.read<TaskProvider>().loadTasks(
              context.read<AuthProvider>().userModel!.uid,
              userPhone: context.read<AuthProvider>().userModel?.phone ?? '',
            );
          }
        },
        initialText: null,
        showDraftHint: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Creation mode: embed the task creation chat widget
    if (_isCreationMode && _creationAssignee != null) {
      return _buildCreationMode();
    }

    return PopScope(
      // If this screen ever becomes the root route (restored/replaced stack),
      // the phone back button must land on Home instead of exiting the app.
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      },
      child: Scaffold(
        backgroundColor: Colors.white, // Slack-style white background
        resizeToAvoidBottomInset: true, // Ensure input stays above keyboard
        appBar: _isSelecting
            ? AppBar(
                backgroundColor: AppTheme.headerGreen,
                foregroundColor: Colors.white,
                elevation: 1,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _isSelecting = false;
                      _selectedMessageIds.clear();
                    });
                  },
                ),
                title: Text(
                  '${_selectedMessageIds.length} selected',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                actions: [
                  // Forward selected
                  IconButton(
                    icon: const Icon(Icons.forward),
                    onPressed: _selectedMessageIds.isEmpty
                        ? null
                        : () => _bulkForwardMessages(),
                    tooltip: 'Forward',
                  ),
                  // Delete for me
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _selectedMessageIds.isEmpty
                        ? null
                        : () => _bulkDeleteMessages(forEveryone: false),
                    tooltip: 'Delete for Me',
                  ),
                  // Delete for everyone (only if all selected are own messages)
                  if (_selectedMessagesAllOwn())
                    IconButton(
                      icon: const Icon(Icons.delete_forever),
                      onPressed: _selectedMessageIds.isEmpty
                          ? null
                          : () => _bulkDeleteMessages(forEveryone: true),
                      tooltip: 'Delete for Everyone',
                    ),
                ],
              )
            : AppBar(
                backgroundColor: AppTheme.headerGreen,
                foregroundColor: Colors.white,
                elevation: 1,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.pop<String>(context, _currentTask.id);
                    } else {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const HomeScreen()),
                      );
                    }
                  },
                ),
                titleSpacing: 0,
                title: _currentTask.extraFields?['isDraft'] == true
                    ? _buildDraftAssigneeAppBarTitle()
                    // Always the full-name stacked view — the initials
                    // variant and its tap-to-expand toggle were dropped.
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentTask.title.isNotEmpty
                                ? _currentTask.title
                                : 'Enter task title',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _currentTask.title.isNotEmpty
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.6),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                // Stacked: each full name gets the whole
                                // subtitle width instead of sharing one
                                // cramped row.
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // By — the creator is always an app user,
                                    // so a filled dot; skipped on the "Me" line.
                                    Builder(
                                      builder: (_) {
                                        final byIsMe =
                                            _currentTask.createdBy ==
                                            _currentUserId;
                                        return Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                _participantLine(
                                                  'By',
                                                  _getUserNameById(
                                                    _currentTask.createdBy,
                                                  ),
                                                ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white.withOpacity(
                                                    0.8,
                                                  ),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            // On-app badge trails the name (not
                                            // before it). Creator is always an
                                            // app user → filled dot; skipped on
                                            // the "Me" line.
                                            if (!byIsMe &&
                                                _currentTask.createdBy
                                                    .trim()
                                                    .isNotEmpty) ...[
                                              const SizedBox(width: 4),
                                              const OnAppDot(onApp: true),
                                            ],
                                          ],
                                        );
                                      },
                                    ),
                                    // To — filled dot once the assignee has an
                                    // app UID; hollow ring while they're a
                                    // phone-only invitee. Skipped on "Me"/blank.
                                    Builder(
                                      builder: (_) {
                                        final toIsMe = _isAssigneeMe(
                                          _currentTask.assignedTo,
                                        );
                                        final toKnown =
                                            _currentTask.assignedTo
                                                .trim()
                                                .isNotEmpty;
                                        final toOnApp =
                                            (_currentTask.assignedToUid ?? '')
                                                .trim()
                                                .isNotEmpty;
                                        return Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                _participantLine(
                                                  'To',
                                                  _currentTask.assignedTo,
                                                  forceMe: toIsMe,
                                                ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white.withOpacity(
                                                    0.8,
                                                  ),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            // On-app badge trails the name: filled
                                            // once the assignee has an app UID,
                                            // hollow ring while phone-only invitee.
                                            // Skipped on "Me"/blank.
                                            if (!toIsMe && toKnown) ...[
                                              const SizedBox(width: 4),
                                              OnAppDot(onApp: toOnApp),
                                            ],
                                          ],
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                actions: [
                  // Task details card — quick open; closes on back / tap outside
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => _openTaskCardSheet(),
                    tooltip: 'Task Details',
                  ),
                  // Call participants in this task (name + number, copy or dial)
                  IconButton(
                    icon: const Icon(Icons.call),
                    onPressed: () => _showTaskCallSheet(),
                    tooltip: 'Call',
                  ),
                  // More Options (3-dot menu)
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showMoreOptions(context),
                  ),
                ],
              ),
        body: RepaintBoundary(
          key: chatScreenshotKey,
          child: Column(
            children: [
              // Search bar (when active)
              if (isChatSearching) buildChatSearchBar(),

              // Offline banner
              if (isOffline)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: Colors.orange.shade700,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.wifi_off, size: 16, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'No internet — messages saved locally',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

              // Chat messages area with scroll-to-bottom button
              Expanded(
                child: Stack(
                  children: [
                    // WhatsApp-style tinted canvas so white other-side
                    // bubbles read clearly against the background.
                    Positioned.fill(child: ColoredBox(color: chatCanvasColor)),
                    NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification &&
                            notification.dragDetails != null) {
                          // Only real finger drags defer stream updates —
                          // programmatic scrolls (scroll-to-bottom, activity
                          // jumps) must not set the flag or updates could be
                          // swallowed forever.
                          _isUserScrolling = true;
                        }
                        if (notification is ScrollUpdateNotification) {
                          final controller = notification.metrics.pixels;
                          final isNearBottom = controller < 300;

                          if (_showScrollToBottom.value == isNearBottom) {
                            _showScrollToBottom.value = !isNearBottom;
                          }
                          // Reset unread count when user scrolls to bottom
                          if (isNearBottom && _newMessageCount.value > 0) {
                            _newMessageCount.value = 0;
                          }
                        }
                        if (notification is ScrollEndNotification) {
                          // User stopped scrolling — allow stream updates again
                          _pendingRefreshTimer?.cancel();
                          _pendingRefreshTimer = null;
                          if (_isUserScrolling) {
                            _isUserScrolling = false;
                            // If there's pending data from stream, refresh now
                            if (_pendingStreamRefresh) {
                              _pendingStreamRefresh = false;
                              _refreshFromStream();
                            }
                          }
                        }
                        return true;
                      },
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse:
                            true, // WhatsApp-style: scroll anchor at bottom
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: _displayMessages.length + 1, // + card
                        itemBuilder: (context, index) {
                          // Task details card at the END (appears at TOP visually with reverse:true)
                          if (index == _displayMessages.length) {
                            final card = _buildTaskDetailsCard();
                            // Unfilled draft card stays blurred until the
                            // first message is sent.
                            final blurCard =
                                _currentTask.extraFields?['isDraft'] == true &&
                                _displayMessages.isEmpty;
                            if (!blurCard) return card;
                            return IgnorePointer(
                              child: ImageFiltered(
                                imageFilter: ui.ImageFilter.blur(
                                  sigmaX: 5,
                                  sigmaY: 5,
                                ),
                                child: card,
                              ),
                            );
                          }

                          // Map ListView index to _displayMessages index
                          // With reverse:true, index 0 = BOTTOM (newest), so direct mapping works
                          final messageIndex = index;
                          final message = _displayMessages[messageIndex];

                          // Store key for scroll-to using MESSAGE ID (not index) to avoid key reuse issues
                          _messageKeys[message.id] ??= GlobalKey();

                          // Track the built display-index window so a pending
                          // scroll-to-message knows how far the lazy list has
                          // rendered (and which way to step for an off-screen
                          // target).
                          if (messageIndex >= 0) {
                            if (messageIndex > _builtMaxDisplayIndex) {
                              _builtMaxDisplayIndex = messageIndex;
                            }
                            if (messageIndex < _builtMinDisplayIndex) {
                              _builtMinDisplayIndex = messageIndex;
                            }
                          }

                          // Date separator: show when visually-ABOVE message is on a different day
                          // Visually above = _displayMessages[messageIndex + 1] (chrono-previous)
                          Widget? dateSeparator;
                          if (messageIndex >= _displayMessages.length - 1 ||
                              !_isSameDay(
                                message.createdAt,
                                _displayMessages[messageIndex + 1].createdAt,
                              )) {
                            dateSeparator = DateSeparator(
                              date: message.createdAt,
                            );
                          }

                          // Club consecutive response notices: the run's
                          // OLDEST notice (visually topmost with reverse:true)
                          // renders the whole quiet block and newer members
                          // collapse into it — a burst of "Marked as done /
                          // Replied" pills reads as one trail, not a stack.
                          if (message.type == MessageType.system &&
                              _responseNoticeKind(message.text) != null) {
                            bool isNoticeAt(int i) =>
                                i >= 0 &&
                                i < _displayMessages.length &&
                                _displayMessages[i].type ==
                                    MessageType.system &&
                                _responseNoticeKind(_displayMessages[i].text) !=
                                    null;
                            if (isNoticeAt(messageIndex + 1)) {
                              // Absorbed into the block drawn above; keep any
                              // date separator that belongs at this boundary.
                              return dateSeparator ?? const SizedBox.shrink();
                            }
                            final run = <MessageModel>[message];
                            for (var q = messageIndex - 1; isNoticeAt(q); q--) {
                              run.add(_displayMessages[q]);
                            }
                            return _buildNoticeClub(
                              run,
                              separator: dateSeparator,
                            );
                          }

                          final isMe = message.senderId == _currentUserId;

                          // Check if visually-ABOVE message is from same sender (hide avatar)
                          final isSameSenderAsPrevious =
                              messageIndex < _displayMessages.length - 1 &&
                              _displayMessages[messageIndex + 1].senderId ==
                                  message.senderId &&
                              _displayMessages[messageIndex + 1].type !=
                                  MessageType.system &&
                              _isSameDay(
                                message.createdAt,
                                _displayMessages[messageIndex + 1].createdAt,
                              );

                          // Hide sender name if only 2 participants (obvious who's talking).
                          // Union of all sources — participants alone can miss co-assignees.
                          final bool isTwoPersonChat =
                              _getAllParticipantUids().length <= 2;

                          final isSearchMatch = chatIsSearchMatch(message.id);

                          // Swipe-right-to-reply (WhatsApp-style): typed
                          // bubbles and action cards answer with a quote;
                          // tombstones and plain system trails don't. Held
                          // off while multi-selecting so drags never fight
                          // the selection UX.
                          final canSwipeReply =
                              !_isSelecting &&
                              !message.deleted &&
                              (message.type != MessageType.system ||
                                  Helpers.detectActionType(message.text) !=
                                      null);

                          return Column(
                            key: _messageKeys[message.id],
                            children: [
                              if (messageIndex < _displayMessages.length - 1)
                                const SizedBox(height: 2),
                              if (dateSeparator != null) dateSeparator,
                              GestureDetector(
                                onLongPress: () {
                                  if (message.type == MessageType.system)
                                    return;
                                  // Action messages: show single-message options (not multi-select)
                                  if (Helpers.detectActionType(message.text) !=
                                      null) {
                                    _showMessageOptions(
                                      message,
                                      isMe,
                                      messageIndex,
                                    );
                                    return;
                                  }
                                  if (!_isSelecting) {
                                    setState(() {
                                      _isSelecting = true;
                                      _selectedMessageIds.add(message.id);
                                    });
                                  }
                                },
                                onTap: _isSelecting
                                    ? () {
                                        // Don't allow selecting action messages in multi-select
                                        if (Helpers.detectActionType(
                                              message.text,
                                            ) !=
                                            null)
                                          return;
                                        setState(() {
                                          if (_selectedMessageIds.contains(
                                            message.id,
                                          )) {
                                            _selectedMessageIds.remove(
                                              message.id,
                                            );
                                            if (_selectedMessageIds.isEmpty) {
                                              _isSelecting = false;
                                            }
                                          } else {
                                            _selectedMessageIds.add(message.id);
                                          }
                                        });
                                      }
                                    : null,
                                child: SwipeToReply(
                                  enabled: canSwipeReply,
                                  onReply: () {
                                    setState(
                                      () => _replyingToMessage = message,
                                    );
                                    // WhatsApp flashes the quoted message on
                                    // swipe-reply: same short green band the
                                    // notification jump uses, no scroll (the
                                    // row is on screen — it was just swiped).
                                    _highlightMessageCard(message.id);
                                  },
                                  child: buildMessageBubble(
                                    message,
                                    isMe,
                                    showSenderName:
                                        !isSameSenderAsPrevious &&
                                        !isTwoPersonChat,
                                    showTimestamp: true,
                                    isSearchMatch: isSearchMatch,
                                    isSelected:
                                        _isSelecting &&
                                        _selectedMessageIds.contains(
                                          message.id,
                                        ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    // WhatsApp-style scroll to bottom button with unread count badge
                    ValueListenableBuilder<bool>(
                      valueListenable: _showScrollToBottom,
                      builder: (context, showButton, _) {
                        if (!showButton) return const SizedBox.shrink();
                        return Positioned(
                          right: 16,
                          bottom: 16,
                          child: ValueListenableBuilder<int>(
                            valueListenable: _newMessageCount,
                            builder: (context, count, _) {
                              return GestureDetector(
                                onTap: () {
                                  _newMessageCount.value = 0;
                                  _scrollController.animateTo(
                                    0, // Bottom of reverse:true ListView
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  );
                                },
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.15),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Center(
                                        child: Icon(
                                          Icons.keyboard_arrow_down,
                                          color: AppTheme.primaryGreen,
                                          size: 24,
                                        ),
                                      ),
                                      if (count > 0)
                                        Positioned(
                                          top: -4,
                                          right: -4,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.red,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 18,
                                              minHeight: 18,
                                            ),
                                            child: Center(
                                              child: Text(
                                                count > 99 ? '99+' : '$count',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                    // Scroll to top button (enquiry card / oldest messages)
                    ValueListenableBuilder<bool>(
                      valueListenable: _showScrollToTop,
                      builder: (context, showButton, _) {
                        if (!showButton) return const SizedBox.shrink();
                        return Positioned(
                          right: 16,
                          top: 16,
                          child: GestureDetector(
                            onTap: () {
                              _scrollController.animateTo(
                                _scrollController.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            },
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.15),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.keyboard_arrow_up,
                                  color: AppTheme.primaryGreen,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              // Draft info banner (only once a message exists in the draft)
              if (_currentTask.extraFields?['isDraft'] == true &&
                  _displayMessages.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59F00).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 14,
                        color: Color(0xFFF59F00),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Messages are not delivered in Draft Mode',
                          style: TextStyle(
                            fontSize: 11,
                            color: const Color(0xFFF59F00).withOpacity(0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Assignee stage for unfilled drafts — tap to pick/change
              if (_currentTask.extraFields?['isDraft'] == true)
                _buildDraftAssigneeStrip(),

              // Bottom input bar (WhatsApp style)
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// Draft stage: put the keyboard/cursor on the message box so the first
  /// message can be typed straight away.
  void _focusMessageInputIfDraft() {
    if (_currentTask.extraFields?['isDraft'] != true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _messageFocusNode.requestFocus();
    });
  }

  /// Draft-stage AppBar title: assignee avatar + name. Tapping opens the
  /// contact picker so the assignee can be picked/changed before the first
  /// message is sent.
  Widget _buildDraftAssigneeAppBarTitle() {
    final name = _currentTask.assignedTo.isEmpty
        ? 'Select assignee'
        : (_isAssigneeMe(_currentTask.assignedTo)
              ? 'Me'
              : _currentTask.assignedTo);
    final initial = _currentTask.assignedTo.isNotEmpty
        ? _currentTask.assignedTo[0].toUpperCase()
        : '?';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _changeDraftAssignee(),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white.withOpacity(0.2),
            child: Text(
              initial,
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
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Icon(
                      Icons.swap_horiz,
                      size: 12,
                      color: Colors.white.withOpacity(0.85),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Tap to change assignee',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withOpacity(0.85),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compact assignee stage shown above the input bar while the task is an
  /// unfilled draft — tap to pick/change the assignee from contacts.
  Widget _buildDraftAssigneeStrip() {
    final name = _currentTask.assignedTo.isEmpty
        ? 'Select assignee'
        : (_isAssigneeMe(_currentTask.assignedTo)
              ? 'Me'
              : _currentTask.assignedTo);
    final initial = _currentTask.assignedTo.isNotEmpty
        ? _currentTask.assignedTo[0].toUpperCase()
        : '?';
    return Material(
      color: AppTheme.primaryGreen.withOpacity(0.08),
      child: InkWell(
        onTap: () => _changeDraftAssignee(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppTheme.primaryGreen.withOpacity(0.15),
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreen,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Assignee: $name',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.contact_page_outlined,
                size: 16,
                color: AppTheme.secondaryText.withOpacity(0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Contact-picker stage for drafts: pick/change the assignee before the
  /// first message is sent.
  Future<void> _changeDraftAssignee() async {
    final contact = await ContactPickerService().showContactPicker(context);
    if (contact == null || !mounted) return;
    final updated = await _withResolvedAssignee(
      _currentTask.copyWith(
        assignedTo: contact.name,
        assignedToUid: contact.uid,
        assignedToPhone: Helpers.normalizePhone(contact.phone),
        participants: {
          ..._currentTask.participants,
          if (contact.uid != null && contact.uid!.isNotEmpty) contact.uid!,
        }.toList(),
        updatedAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _currentTask = updated;
    });
    _updateTaskInFirebase(updated);
  }

  // ---- DetailChatBubblesMixin hooks ----
  @override
  String get chatCurrentUserId => _currentUserId;

  @override
  String get chatMessagesCollection => 'tasks';

  @override
  Set<String> get chatTickParticipants => {
    ...widget.task.participants,
    if (widget.task.assignedToUid != null &&
        widget.task.assignedToUid!.isNotEmpty)
      widget.task.assignedToUid!,
    if (widget.task.createdBy.isNotEmpty) widget.task.createdBy,
  };

  @override
  Set<String> get chatAllParticipants => _getAllParticipantUids();

  @override
  String chatSenderName(String senderId) => _getSenderName(senderId);

  @override
  String chatUserNameById(String uid) => _getUserNameById(uid);

  @override
  Map<String, double> get chatUploadProgress => _uploadProgress;

  @override
  void chatOpenImageViewer(String url) => _openImageViewer(url);

  @override
  Future<void> chatOpenDocument(MessageModel message) async =>
      _openDocumentViewer(message);

  @override
  Future<void> chatOpenPendingFile(
    MessageModel message,
    String localPath,
  ) async {
    // Open the locally saved file with the system viewer
    final result = await OpenFilex.open(localPath);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File saved locally: ${message.fileName}'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget chatBuildSystemMessage(MessageModel message) =>
      _buildSystemMessage(message);

  @override
  Color get chatAccentColor => AppTheme.accent;

  @override
  Color get chatTextBubbleMineBg => const Color(0xFFD7EAE2);

  @override
  Color get chatMediaBubbleMineBg => AppTheme.chatBubbleGreen;

  @override
  Color get chatSenderNameColor => AppTheme.accent;

  @override
  Color get chatVoiceMineColor => AppTheme.accent;

  @override
  Color get chatVoiceOtherColor => AppTheme.accent;

  @override
  Color get chatUrgentColor => AppTheme.urgent;

  @override
  bool get chatShowInlineTicks => true;

  @override
  bool get chatShowDeliverySummary => true;

  // ---- DetailChatMenuMixin hooks ----
  @override
  List<MessageModel> get chatSearchMessages => _messages;

  @override
  List<MessageModel> get chatExportMessages =>
      _allMessages.isNotEmpty ? _allMessages : _messages;

  @override
  void chatScrollToMessageById(String messageId) =>
      _scrollToMessageById(messageId);

  @override
  String chatSenderNameFor(String senderId) => _getSenderName(senderId);

  @override
  String get chatExportTitle => _currentTask.title;

  @override
  String get chatShareSubjectLabel => 'Task';

  @override
  String get chatScreenshotFilePrefix => 'task_screenshot';

  // ---- DetailChatAttachmentsMixin hooks ----
  @override
  String get chatEntityId => _currentTask.id;

  @override
  List<MessageModel> get chatMessages => _messages;

  @override
  void chatRefreshMessages() => _rebuildDisplayMessages();

  @override
  void chatScrollToBottom() => _scrollToBottom();

  @override
  Future<void> chatSyncMessage(MessageModel message) =>
      context.read<TaskProvider>().sendMessage(_currentTask.id, message);

  @override
  String get chatStorageFolder => 'tasks';

  @override
  String? get chatSqliteParentType => null;

  // ---- DetailChatPlumbingMixin hooks ----
  @override
  void chatMarkMessageRead(String messageId) => FirebaseService()
      .markMessageRead(_currentTask.id, messageId, _currentUserId);

  @override
  void chatMarkMessagesDelivered(List<String> messageIds) => FirebaseService()
      .markMessagesDelivered(_currentTask.id, messageIds, _currentUserId);

  @override
  void chatResetMyUnreadCount() => _resetMyUnreadCount();

  // Build full participant set from all available sources
  // (uses _currentTask so newly added assignees are reflected immediately)
  Set<String> _getAllParticipantUids() {
    final participants = <String>{
      ..._currentTask.participants,
      if (_currentTask.assignedToUid != null &&
          _currentTask.assignedToUid!.isNotEmpty)
        _currentTask.assignedToUid!,
      if (_currentTask.createdBy.isNotEmpty) _currentTask.createdBy,
    };
    // Also include assigneeUids from extraFields
    final extra = _currentTask.extraFields;
    if (extra != null && extra['assigneeUids'] is List) {
      for (final uid in extra['assigneeUids'] as List) {
        final u = uid?.toString() ?? '';
        if (u.isNotEmpty) participants.add(u);
      }
    }
    return participants;
  }

  // ⚠️ Chat action card — label chain AND the body-extraction block below
  // both parse message text. A type missing from body extraction renders a
  // label-only 200px card with its data silently discarded (this was the
  // cash amount/balance bug). See checklist at _getActionMessages.
  /// Display label for the action card a response notification (Done /
  /// Reply / Resolve) references via replyToMessageId: the referenced card's
  /// own base label plus its send-time sequence number ("Query 1",
  /// "Follow-up 3"). Returns null when the reference is unknown or points at
  /// something that isn't a recognized action — the notification then keeps
  /// its generic "Action" label instead of guessing.
  String? _responseRefLabel(MessageModel message) {
    final refId = message.replyToMessageId;
    if (refId == null || refId.isEmpty) return null;
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    MessageModel? ref;
    for (final m in source) {
      if (m.id == refId) {
        ref = m;
        break;
      }
    }
    if (ref == null) return null;
    final typeKey = Helpers.detectActionType(ref.text);
    if (typeKey == null) return null;
    final base = CardActionIcons.actionBaseLabel(
      typeName: typeKey,
      message: ref.text,
    );
    // The base label's catch-all is 'Reminder' — only trust it when the
    // referenced card really is a reminder, so an unclassified card doesn't
    // get mislabeled.
    if (base == 'Reminder' && typeKey != 'reminder') return null;
    final seq = ref.sequenceNumber;
    return seq != null ? '$base $seq' : base;
  }

  /// Classifies a response-notification message ("↩️ Replied by …",
  /// "✅ Marked as done by …", "🔓 Blocker resolved by …") into its emoji +
  /// verb, or null when the text is not a response notification. Single
  /// source of truth shared with _isResponseNotificationText (log gate).
  (String, String)? _responseNoticeKind(String text) {
    final lower = text.toLowerCase();
    // Verbs stay short because the referenced card's own label leads the
    // line ("Request 1 · Done · Me · 5:56 PM") — "Marked as done" would
    // repeat what the label + verb pair already says.
    if (lower.contains('replied by ')) return ('↩️', 'Replied');
    if (lower.contains('marked as done by ')) return ('✅', 'Done');
    if (lower.contains('blocker resolved by ')) return ('🔓', 'Resolved');
    return null;
  }

  /// Send-time display label of the ACTION CARD a response notice points at
  /// ("Follow up 1", "Query 2"). Same chain as [_responseRefLabel] but applied
  /// to the referenced message directly — the notice text is composed while
  /// that card's message is in hand, so no replyToMessageId lookup.
  String? _noticeActionLabel(MessageModel ref) {
    final typeKey = Helpers.detectActionType(ref.text);
    if (typeKey == null) return null;
    final base = CardActionIcons.actionBaseLabel(
      typeName: typeKey,
      message: ref.text,
    );
    // The base label's catch-all is 'Reminder' — only trust it when the
    // card really is a reminder, so an unclassified card doesn't mislabel.
    if (base == 'Reminder' && typeKey != 'reminder') return null;
    final seq = ref.sequenceNumber;
    return seq != null ? '$base $seq' : base;
  }

  /// Compose a response-notice system line, formatted as
  /// ``<lead> by <actor> (<action label>) at <time>``. The parenthesized
  /// label is what lets the LIST CARD preview name the action it answered
  /// ("✓ Follow up 1 by Aditya" — see Helpers._noticeCardForm); the chat
  /// notice renders its own label from the reference, and the " by …"
  /// signature keeps detectActionType's response-notice guard matching, so
  /// the notice never indexes as an action.
  String _noticeText(String lead, MessageModel ref) {
    final label = _noticeActionLabel(ref);
    return '$lead by $_currentUserName'
        '${label != null ? ' ($label)' : ''}'
        ' at ${Helpers.formatDateTime(DateTime.now())}';
  }

  /// A subtle, centered system line for a reply/done/resolve event. Rendered
  /// WITHOUT the action-card chrome (no border, tint or width family) so it
  /// stays quiet and visually distinct from real actions. The referenced
  /// card's label leads, then the short verb, actor and time —
  /// "Query 1 · ↩️ Replied · Me · 5:56 PM". Tapping jumps to the referenced
  /// action card. Kept out of the Activity log / system_logs (see
  /// _isActionLogMessage) so it only appears as this quiet chat note.
  /// One compact trail line inside a notice club (see [_buildNoticeClub]).
  Widget _noticeLine(MessageModel message) {
    final kind = _responseNoticeKind(message.text)!;
    final refLabel = _responseRefLabel(message);
    final actor = message.senderId == 'system'
        ? null
        : _getSenderName(message.senderId);
    final time = DateFormat('h:mm a').format(message.createdAt);
    // Sequence: WHAT got answered → HOW → WHO → WHEN (was verb-first, which
    // buried the card name behind "Marked as done"). WHO is dropped in
    // two-person chats — the pill's side already shows it (bubble rule).
    final parts = <String>[
      if (refLabel != null) refLabel,
      '${kind.$1} ${kind.$2}',
      if (actor != null && _getAllParticipantUids().length > 2) actor,
      time,
    ];
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final ref = message.replyToMessageId;
        _scrollToMessageById(
          (ref != null && ref.isNotEmpty) ? ref : message.id,
        );
      },
      child: Text(
        parts.join(' · '),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onSurface.withOpacity(0.5),
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Consecutive response notices ("Done · …", "Replied · …") club into one
  /// quiet block instead of a loud stack of grey pills — a burst of them
  /// used to dominate the feed. [run] is oldest-first (visual top→down).
  /// The block is rendered at the oldest notice's slot; newer runs collapse
  /// into it. Each line keeps its own key so scroll-to-message still works.
  /// The block hugs its actor's side (mine right, theirs left, legacy
  /// 'system' centered); a mixed-sender run splits into one pill per side.
  Alignment _noticeAlignFor(String senderId) {
    if (senderId == _currentUserId) return Alignment.centerRight;
    if (senderId == 'system') return Alignment.center;
    return Alignment.centerLeft;
  }

  Widget _buildNoticeClub(List<MessageModel> run, {Widget? separator}) {
    final theme = Theme.of(context);
    // One pill per same-actor stretch — notices from both sides can't share
    // a single block and still sit on their creator's side of the feed.
    final segments = <List<MessageModel>>[];
    for (final m in run) {
      if (segments.isNotEmpty &&
          _noticeAlignFor(segments.last.last.senderId) ==
              _noticeAlignFor(m.senderId)) {
        segments.last.add(m);
      } else {
        segments.add([m]);
      }
    }
    return Column(
      children: [
        if (separator != null) separator,
        if (run.length > 1 && separator == null) const SizedBox(height: 2),
        for (final seg in segments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
            child: Align(
              alignment: _noticeAlignFor(seg.first.senderId),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 240),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final m in seg)
                      Padding(
                        key: _messageKeys[m.id],
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: _noticeLine(m),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResponseNoticeLine(MessageModel message) =>
      _buildNoticeClub([message]);

  /// Card body spans: a dd/MM/yyyy HH:mm date-time segment renders in the
  /// card's semantic color at NORMAL weight (user rule — the bold read as the
  /// whole line being shouted; only the colour now sets it apart) so notes and
  /// scheduled times stay distinct without the heavy weight.
  List<InlineSpan> _bodySpans(String text, Color accent) {
    final re = RegExp(r'\d{2}/\d{2}/\d{4}(?: \d{2}:\d{2})?');
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(fontWeight: FontWeight.normal, color: accent),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  Widget _buildSystemMessage(MessageModel message) {
    // Parse message type from text
    final messageText = message.text;
    // Response notifications (Reply / Done / Resolve) render as a subtle,
    // centered system line — deliberately different from an action card so
    // they read as a quiet status note, not a new action.
    if (_responseNoticeKind(messageText) != null) {
      return _buildResponseNoticeLine(message);
    }
    IconData? icon;
    String actionType;
    // Sequential occurrence number baked at send time (space form, no '#')
    // — same convention as the Sales cards' "Quotation 2" labels.
    final int? seqNo = message.sequenceNumber;
    String numbered(String base) => seqNo != null ? '$base $seqNo' : base;

    // Detect message type and assign icon + label
    if (messageText.contains('📞') ||
        messageText.toLowerCase().startsWith('call made')) {
      icon = Icons.call;
      // A scheduled call stays "Call Scheduled" until the scheduler marks
      // it done; legacy "call made" entries keep the plain label. Numbered
      // per occurrence ("Call Scheduled 2") like Meeting.
      actionType = messageText.toLowerCase().contains('call scheduled')
          ? (message.isFollowUpDone
                ? '${numbered('Call')} - Done'
                : numbered('Call Scheduled'))
          : numbered('Call');
    } else if (messageText.contains('🤝') ||
        messageText.toLowerCase().startsWith('meeting')) {
      // Numbered per occurrence ("Meeting 2") like the Sales card; scheduled
      // meetings keep the plain "Meeting" label; done meetings get a ✓ icon.
      icon = message.isFollowUpDone ? Icons.check_circle : Icons.groups;
      actionType = message.isFollowUpDone
          ? '${numbered('Meeting')} - Done'
          : numbered('Meeting');
    } else if (messageText.contains('🛠️') ||
        messageText.toLowerCase().startsWith('site visit') ||
        messageText.toLowerCase().startsWith('visit')) {
      // 🛠️ Visit — dated on-location commitment (Sales sitevisit parity):
      // open until the owner marks it done. Numbered per occurrence; the
      // heading carries the state word so the body text no longer repeats
      // "Visit scheduled" (user rule).
      icon = message.isFollowUpDone ? Icons.check_circle : Icons.handyman;
      actionType = message.isFollowUpDone
          ? '${numbered('Visit')} - Done'
          : '${numbered('Visit')} - Scheduled';
    } else if (messageText.contains('💬') ||
        messageText.toLowerCase().contains('whatsapp message')) {
      icon = Icons.chat;
      actionType = 'WhatsApp';
    } else if (messageText.toLowerCase().contains('assignee added')) {
      icon = Icons.person_add_alt;
      actionType = 'Assignee Added';
    } else if (messageText.toLowerCase().contains('assignee removed')) {
      icon = Icons.person_remove_alt_1;
      actionType = 'Assignee Removed';
    } else if (messageText.toLowerCase().contains('assignee updated')) {
      icon = Icons.group;
      actionType = 'Assignee Updated';
    } else if (messageText.contains('Status changed')) {
      icon = Icons.flag;
      actionType = 'Status Changed';
    } else if (messageText.contains('Progress updated')) {
      icon = Icons.trending_up;
      actionType = 'Progress Updated';
    } else if (messageText.contains('💵') ||
        messageText.toLowerCase().startsWith('cash')) {
      icon = Icons.account_balance_wallet;
      // Numbered per occurrence like Sales ("Cash Added 2") — the number
      // lives in sequenceNumber, never in the parsed text.
      if (messageText.contains('Cash Added')) {
        actionType = numbered('Cash Added');
      } else if (messageText.contains('Cash Expense')) {
        actionType = numbered('Cash Expense');
      } else if (messageText.contains('Cash Refund')) {
        actionType = numbered('Cash Refund');
      } else if (messageText.contains('Cash Settled')) {
        actionType = numbered('Cash Settled');
      } else {
        actionType = numbered('Cash');
      }
    } else if (messageText.contains('💳') ||
        messageText.toLowerCase().startsWith('payment')) {
      icon = Icons.payments;
      // Sales parity: receivable entries keep their own verb on the card
      // header ("💳 Due: …" / "💳 Collected: …"); legacy payment notes
      // fall back to the plain 'Payment' label. Numbered per occurrence.
      final payFirstLine = messageText.split('\n').first;
      actionType = payFirstLine.contains('Due')
          ? numbered('Payment - Due')
          : payFirstLine.contains('Collected')
          ? numbered('Payment - Collected')
          : numbered('Payment');
    } else if (messageText.contains('🚧') ||
        messageText.toLowerCase().contains('blocker raised')) {
      icon = Icons.block;
      // Numbered per occurrence ("Blocker 2") like Query/Request — raisings
      // are sequential even though only one stays open at a time; the
      // sequence number baked at send time also feeds the card chip.
      actionType = message.isFollowUpDone
          ? '${numbered('Blocker')} - Resolved'
          : numbered('Blocker');
    } else if (messageText.toLowerCase().contains('approval requested')) {
      icon = Icons.fact_check;
      // Numbered per occurrence ("Request 2") like Query/Call — the status
      // suffix stays after the number.
      // Request status word in the header (user rule: show PENDING until the
      // other side replies, then REPLIED) so the card reads as an open item
      // that needs an answer, not a bare label.
      actionType = message.isFollowUpDone || message.isReplied
          ? '${numbered('Request')} - Replied'
          : '${numbered('Request')} - Pending';
    } else if (messageText.contains('⏳') ||
        messageText.toLowerCase().contains('extension requested')) {
      icon = Icons.more_time;
      actionType = message.isReplied
          ? 'Extension - Actioned'
          : 'Extension Requested';
    } else if (messageText.contains('📈') ||
        messageText.toLowerCase().contains('progress report')) {
      icon = Icons.trending_up;
      actionType = 'Progress Report';
    } else if (messageText.toLowerCase().contains('follow-up') ||
        messageText.toLowerCase().contains('followup')) {
      icon = Icons.calendar_today;
      actionType = message.isFollowUpDone
          ? '${numbered('Follow-up')} - Done'
          : numbered('Follow-up');
    } else if (messageText.toLowerCase().contains('status report') ||
        messageText.toLowerCase().contains('status request') ||
        messageText.toLowerCase().contains('asked for an update') ||
        messageText.toLowerCase().startsWith('query')) {
      icon = Icons.summarize;
      if (message.systemType == SystemMessageType.query &&
          message.sequenceNumber != null) {
        actionType = message.isReplied
            ? 'Query ${message.sequenceNumber} - Replied'
            : 'Query ${message.sequenceNumber} - Pending';
      } else {
        actionType = message.isReplied
            ? 'Query - Replied'
            : 'Query - Pending';
      }
    } else if (messageText.toLowerCase().contains('title updated') ||
        (messageText.toLowerCase().contains('title:') &&
            messageText.contains('→'))) {
      icon = Icons.edit;
      actionType = 'Title Updated';
    } else if (messageText.toLowerCase().contains('description updated') ||
        (messageText.toLowerCase().contains('description:') &&
            messageText.contains('→'))) {
      icon = Icons.description;
      actionType = 'Description Updated';
    } else if (messageText.toLowerCase().contains('deadline updated')) {
      icon = null;
      actionType = 'Deadline Updated';
    } else if (messageText.toLowerCase().contains('priority changed')) {
      icon = Icons.flag;
      actionType = 'Priority Changed';
    } else if (messageText.toLowerCase().contains('urgency changed')) {
      icon = Icons.local_fire_department;
      actionType = 'Urgency Changed';
    } else if (messageText.toLowerCase().contains('category changed')) {
      icon = Icons.label;
      actionType = 'Category Updated';
    } else if (messageText.toLowerCase().contains('start date updated')) {
      icon = Icons.event_note;
      actionType = 'Start Date Updated';
    } else if (messageText.toLowerCase().contains('title updated')) {
      icon = Icons.edit;
      actionType = 'Title Updated';
    } else if (messageText.toLowerCase().contains('description updated')) {
      icon = Icons.description;
      actionType = 'Description Updated';
    } else if (RegExp(
          r'milestone \d+ added',
        ).hasMatch(messageText.toLowerCase()) ||
        messageText.toLowerCase().contains('milestone added')) {
      icon = Icons.flag;
      actionType = 'Milestone Added';
    } else if (RegExp(
          r'milestone \d+ removed',
        ).hasMatch(messageText.toLowerCase()) ||
        messageText.toLowerCase().contains('milestone removed')) {
      icon = Icons.flag_outlined;
      actionType = 'Milestone Removed';
    } else if (messageText.toLowerCase().contains('milestone completed')) {
      icon = Icons.flag;
      actionType = 'Milestone Completed';
    } else if (messageText.toLowerCase().contains('milestone reopened')) {
      icon = Icons.flag_outlined;
      actionType = 'Milestone Reopened';
    } else if (messageText.contains('📅 Reminder') ||
        messageText.toLowerCase().startsWith('reminder') ||
        messageText.contains('Reminder scheduled') ||
        messageText.contains('sent a reminder')) {
      icon = Icons.notifications_active;
      int? reminderNum = message.sequenceNumber;
      if (reminderNum == null) {
        final numMatch = RegExp(
          r'Reminder\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) reminderNum = int.tryParse(numMatch.group(1)!);
      }
      actionType = reminderNum != null ? 'Reminder $reminderNum' : 'Reminder';
    } else if (messageText.contains('⚠️ WARNING') ||
        messageText.toLowerCase().startsWith('warning')) {
      icon = Icons.warning_amber_rounded;
      int? warningNum = message.sequenceNumber;
      if (warningNum == null) {
        final numMatch = RegExp(
          r'Warning\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) warningNum = int.tryParse(numMatch.group(1)!);
      }
      actionType = warningNum != null ? 'Warning $warningNum' : 'Warning';
    } else if (messageText.contains('asked for an update') ||
        messageText.contains('Status') ||
        messageText.toLowerCase().startsWith('query')) {
      icon = Icons.summarize;
      int? queryNum = message.sequenceNumber;
      if (queryNum == null) {
        final numMatch = RegExp(
          r'Query\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) queryNum = int.tryParse(numMatch.group(1)!);
      }
      if (queryNum != null) {
        actionType = message.isReplied
            ? 'Query $queryNum - Replied'
            : 'Query $queryNum - Pending';
      } else {
        actionType = message.isReplied
            ? 'Query - Replied'
            : 'Query - Pending';
      }
    } else if (messageText.contains('Follow-up') ||
        messageText.contains('follow-up')) {
      icon = Icons.calendar_today;
      actionType = message.isFollowUpDone ? 'Follow-up - Done' : 'Follow-up';
    } else if (messageText.contains('changed title') ||
        messageText.contains('changed description') ||
        messageText.contains('changed customer name')) {
      // Sales-style inline edits: "X changed description from "old" to "new""
      icon = Icons.edit;
      if (messageText.contains('changed customer name')) {
        actionType = 'Customer Name Edited';
      } else if (messageText.contains('changed description')) {
        actionType = 'Description Edited';
      } else {
        actionType = 'Title Edited';
      }
    } else {
      icon = Icons.info_outline;
      actionType = message.senderId == 'system' ? 'System' : 'Action';
    }

    // Semantic colors: blue = action, green = done/success, grey = metadata edit
    final bool isDone = message.isFollowUpDone || message.isReplied;
    final bool isCashAction =
        messageText.contains('💵') ||
        messageText.toLowerCase().startsWith('cash');
    final bool isMetadataEdit =
        !isCashAction &&
        (actionType.contains('Updated') ||
            actionType.contains('Added') ||
            actionType.contains('Removed') ||
            actionType.endsWith('Edited') ||
            actionType == 'System' ||
            actionType == 'Action');
    final Color color = isCashAction
        ? AppTheme.accent
        : isDone
        ? AppTheme.success
        : isMetadataEdit
        ? AppTheme.tertiaryLabel
        : AppTheme.info;

    // Compact action message: icon + label + timestamp on one line
    // Message body (before→after) on next line if present
    final displayTime = DateFormat('h:mm a').format(message.createdAt);

    // Actor attribution — every action card says who did it. senderId is the
    // real actor UID; legacy 'system' senders can't be attributed reliably.
    final String? actorLabel = message.senderId == 'system'
        ? null
        : _getSenderName(message.senderId);

    // Alignment follows the actor, just like text messages: my actions on the
    // right, other people's on the left; unattributed legacy cards stay center.
    final AlignmentGeometry cardAlignment = message.senderId == _currentUserId
        ? Alignment.centerRight
        : (message.senderId == 'system'
              ? Alignment.center
              : Alignment.centerLeft);

    // Extract before/after values from message text
    String? beforeValue;
    String? afterValue;
    String? displayText;
    final recvDelta = Helpers.extractReceivableDelta(messageText);
    final bool isReceivable = recvDelta.$1 > 0 || recvDelta.$2 > 0;
    if (isCashAction) {
      // "💵 Cash Added: ₹500 — note\nBalance: ₹800" →
      // line 1: amount (+note), line 2: "(Bal) ₹800"
      final lines = messageText.split('\n');
      final amountLine = lines.first
          .replaceFirst(RegExp(r'^💵\s*Cash\s*\w*\s*[:—–-]?\s*'), '')
          .trim();
      String? balanceLine;
      for (final line in lines.skip(1)) {
        final balMatch = RegExp(
          r'Balance:\s*(.+)',
          caseSensitive: false,
        ).firstMatch(line);
        if (balMatch != null) {
          balanceLine = '(Bal) ${balMatch.group(1)!.trim()}';
        }
      }
      displayText = [
        if (amountLine.isNotEmpty) amountLine,
        if (balanceLine != null) balanceLine,
      ].join('\n');
      if (displayText.isEmpty) displayText = null;
    } else if (isReceivable) {
      // "💳 Due: ₹5,000 — note\nDue ₹5,000 · Collected ₹0 · Outstanding ₹5,000"
      // → line 1: the entry (Due/Collected + note), line 2: the running totals.
      final lines = messageText.split('\n');
      final amountLine = lines.first.replaceFirst(RegExp(r'^💳\s*'), '').trim();
      final totalLine = lines.length > 1 ? lines[1].trim() : '';
      displayText = [
        if (amountLine.isNotEmpty) amountLine,
        if (totalLine.isNotEmpty) totalLine,
      ].join('\n');
      if (displayText.isEmpty) displayText = null;
    } else {
      final byAtMatch = RegExp(
        r'^(.+?)\s+by\s+(.+?)\s+at\s+(.+)$',
      ).firstMatch(messageText);
      if (byAtMatch != null) {
        final action = byAtMatch.group(1)!;
        displayText = action;
        // Scheduled / blocker cards already show their type in the header
        // icon + label, so drop the "X scheduled:" / "Blocker raised:"
        // lead-in (and a bare leading "for") from the body — keep only the
        // typed note and the scheduled date/time.
        final capKey = Helpers.detectActionType(action);
        if (capKey == 'followup' ||
            capKey == 'meeting' ||
            capKey == 'call' ||
            capKey == 'blocker') {
          displayText = action
              .replaceFirst(RegExp(r'^[^:]*:\s*'), '')
              .replaceFirst(RegExp(r'^for\s+', caseSensitive: false), '')
              // "Hh" for 02/10/2026 10:00 → the bare connector adds noise
              // before a date; the styled date segment carries it instead.
              .replaceAll(RegExp(r'\s+for\s+(?=\d)', caseSensitive: false), ' ')
              .trim();
        }
        if (capKey == 'approval') {
          // The header already reads "Request N" — the "Approval requested:"
          // lead-in in the body just repeated it. Keep only the typed note.
          final note = action
              .replaceFirst(
                RegExp(r'^Approval requested\s*:?\s*', caseSensitive: false),
                '',
              )
              .trim();
          displayText = note.isEmpty ? null : note;
        }
        final fromToMatch = RegExp(
          r':\s*"?([^"\n]+?)"?\s+→\s*"?(.+?)"?$',
          caseSensitive: false,
        ).firstMatch(action);
        if (fromToMatch != null) {
          beforeValue = fromToMatch.group(1);
          afterValue = fromToMatch.group(2);
        } else {
          final toMatch = RegExp(
            r':\s*"?([^"\n,]+?)"?(?:, Assignee = |\s+by\s)',
            caseSensitive: false,
          ).firstMatch(action);
          if (toMatch != null) afterValue = toMatch.group(1);
        }
      } else {
        // Inline edits: "X changed description from "old" to "new"" — show
        // WHAT changed as an old → new pair instead of discarding it.
        final changedFromTo = RegExp(
          r'changed\s+(.+?)\s+from\s+"(.*)"\s+to\s+"(.*)"$',
          caseSensitive: false,
        ).firstMatch(messageText);
        final quoteMatch = RegExp(r'"([^"]+)"').firstMatch(messageText);
        if (changedFromTo != null) {
          beforeValue = changedFromTo.group(2);
          afterValue = changedFromTo.group(3);
        } else if (quoteMatch != null) {
          displayText = quoteMatch.group(1);
        } else {
          // Dialog actions carry their note after the label colon
          // ("📋 Follow Up: <note> on dd/MM/yyyy") with no by/at suffix —
          // show that detail instead of a label-only card.
          final colon = messageText.indexOf(':');
          if (colon > 0 && colon < messageText.length - 1) {
            displayText = messageText.substring(colon + 1).trim();
          } else if (Helpers.detectActionType(messageText) == 'sitevisit') {
            // Visit cards lead with a bare 🛠️ emoji and no colon/quotes/by-at
            // anchor (Sales caption "🛠️ <note> on dd/MM… at hh:mm") — strip the
            // emoji (the "icon" the user wants gone from the caption) and show
            // the rest, so the typed note + date aren't lost to a label-only
            // card. Mirrors sales_detail_screen.dart _buildSystemMessage.
            final stripped = messageText
                .replaceFirst(RegExp(r'^🛠️\s*'), '')
                .trim();
            displayText = stripped.isEmpty ? null : stripped;
          }
        }
      }
    }

    // Determine card width: two size families. Real actions (call, query,
    // One uniform width family for every card - actions, edits and activity
    // alike: body-text cards 240, label-only 168. The old split gave real
    // actions a roomier 280/200 bubble than the 240/168 metadata cards, which
    // read as inconsistent widths down the feed.
    final bool hasBodyText =
        (beforeValue != null && afterValue != null) ||
        (afterValue != null && beforeValue == null) ||
        (beforeValue == null &&
            afterValue == null &&
            displayText != null &&
            displayText.isNotEmpty);
    final double cardWidth = hasBodyText ? 240.0 : 168.0;

    // Tapping an action card reopens the matching Message Action dialog so
    // the next one can be issued right away (e.g. tap any Call card to type
    // a note and schedule the next call). Non-action cards keep the old
    // scroll-to-message behavior.
    VoidCallback? reopenAction;
    // Reopen parity with the Message Actions grid: tapping any action card
    // reopens the same dialog its tile would open, dispatched through
    // _runTaskAction. This now includes Request ('approval') — previously
    // excluded over duplicate-send fears, but tapping the card only reopens
    // the compose dialog (guarded by _requestApprovalInFlight), exactly like
    // tapping its tile. Keys with no Task handler (auto-recorded WhatsApp,
    // extension, progress) keep the old scroll-to-message behavior.
    final actionKey = Helpers.detectActionType(messageText);
    if (actionKey != null && _runnableTaskActionKeys.contains(actionKey)) {
      reopenAction = () => _runTaskAction(actionKey);
    } else if (messageText.toLowerCase().contains('urgency changed')) {
      // Metadata-edit cards reopen their editor too (parity with action
      // cards): an "Urgency changed" card reopens the priority/urgency sheet.
      reopenAction = _showPriorityUrgencyMenu;
    } else if (messageText.toLowerCase().contains('status changed')) {
      reopenAction = () => _editTaskStatus();
    }

    // Action cards ride the chat's side colors (explicit user rule): a card
    // I raised sits on the same 'mine' green tint as my bubbles, a card from
    // the other side is a white bubble with the bubbles' hairline edge —
    // mirroring buildTextMessage's isMe/other/dark inversion exactly. Only
    // legacy unattributed senderId='system' cards (centered, no side) keep
    // the quiet grey panel.
    final scheme = Theme.of(context).colorScheme;
    final bool cardIsDark = Theme.of(context).brightness == Brightness.dark;
    final bool mineCard = message.senderId == _currentUserId;
    final bool otherCard = !mineCard && message.senderId != 'system';
    final Color bubbleBg = mineCard
        ? (cardIsDark ? chatAccentColor : chatTextBubbleMineBg)
        : otherCard
        ? (cardIsDark ? Theme.of(context).cardColor : Colors.white)
        : scheme.surfaceContainerHighest;
    final Border? bubbleBorder = mineCard
        ? null
        : otherCard
        ? (cardIsDark
              ? null
              : Border.all(color: AppTheme.separator.withOpacity(0.9)))
        : Border.all(color: scheme.outlineVariant, width: 1);

    return GestureDetector(
      // Card-body tap jumps back to the referenced action (response notices
      // carry replyToMessageId) or to the card itself. The reopen-the-action
      // popup is bound to the card HEADING only now (user rule) — an
      // accidental tap on the body text must never open a new-activity dialog.
      onTap: () => _scrollToMessageById(
        (message.replyToMessageId != null &&
                message.replyToMessageId!.isNotEmpty)
            ? message.replyToMessageId!
            : message.id,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        // Horizontal highlight band: while a jump flags this card, a soft
        // green strip spans the row so the referenced action is easy to spot.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          color: _highlightedMessageId == message.id
              ? AppTheme.success.withOpacity(0.14)
              : Colors.transparent,
          child: Align(
            alignment: cardAlignment,
            child: Container(
              width: cardWidth,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: bubbleBg,
                borderRadius: BorderRadius.circular(12),
                border: bubbleBorder,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Line 1: Icon + action label (left) · time + actor (flush
                  // right). The meta group used to sit directly after the
                  // title, which read as part of the message text; pushing it
                  // to the trailing edge keeps the label the headline.
                  // Tapping the HEADING reopens the action dialog (create
                  // next activity); taps anywhere else in the card only
                  // scroll (user rule). Opaque behavior so the thin gaps
                  // around the label row still receive the tap.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: reopenAction,
                    child: Row(
                    children: [
                      if (icon != null) ...[
                        // Done actions keep their own icon + tiny ✓ badge
                        CardActionIcons.withDoneBadge(
                          Icon(icon, size: 13, color: color),
                          done: isDone,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          actionType,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        displayTime,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.lightText.withOpacity(0.6),
                        ),
                      ),
                      // Two-person chats skip the name — the card's side
                      // (and the AppBar By/To row) already say who (parity
                      // with the bubble sender-name rule).
                      if (actorLabel != null &&
                          _getAllParticipantUids().length > 2) ...[
                        const SizedBox(width: 4),
                        // Constrained so a long name ellipsizes instead of
                        // pushing the time out of the card.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 72),
                          child: Text(
                            'by $actorLabel',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  ),
                  // Line 2: Before → After values or message text (if present)
                  if (beforeValue != null && afterValue != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 4),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              beforeValue,
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.lightText.withOpacity(0.7),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward, size: 11, color: color),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              afterValue,
                              style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (afterValue != null && beforeValue == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 4),
                      child: Text(
                        afterValue,
                        style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (beforeValue == null &&
                      afterValue == null &&
                      displayText != null &&
                      displayText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 4),
                      child: Text.rich(
                        TextSpan(children: _bodySpans(displayText, color)),
                        style: const TextStyle(
                          // Typed note renders at the chat-message body size
                          // (user rule: "same font size in typed text as in
                          // message") — the card's quiet 11pt made long notes
                          // hard to read next to real bubbles.
                          fontSize: 16,
                          color: AppTheme.secondaryText,
                          height: 1.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                        // A receivable footer ("Due · Collected · Outstanding")
                        // wraps to a 3rd visual line in the 240pt card; a 2-line
                        // cap clipped the Outstanding amount.
                        maxLines: 3,
                      ),
                    ),
                  // Attachment riding inside the action card (Sales parity,
                  // one-message edit): a small "Attached document" line under
                  // the body. Its own tap opens the file — the inner
                  // GestureDetector wins over the card's reopen-the-action tap.
                  if (message.fileUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, left: 4),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap:
                            message.fileUrl == 'pending' ||
                                message.isUploadFailed
                            ? null
                            : () => chatOpenDocument(message),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              message.isUploadFailed
                                  ? Icons.error_outline
                                  : Icons.attach_file,
                              size: 11,
                              color: message.isUploadFailed
                                  ? Colors.red
                                  : AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                message.fileUrl == 'pending'
                                    ? 'Uploading attachment…'
                                    : message.isUploadFailed
                                    ? 'Attachment failed'
                                    : 'Attached document',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: message.isUploadFailed
                                      ? Colors.red
                                      : AppTheme.secondaryText,
                                  decoration:
                                      message.isUploadFailed ||
                                          message.fileUrl == 'pending'
                                      ? null
                                      : TextDecoration.underline,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Reply text — ONE block for every action type, placed
                  // under the initial text/attachment and ABOVE the action
                  // buttons. Gated only on the replied flag, so a reply
                  // survives Done/Close: closing a card only flips its header
                  // status, the answer text stays on the card (Sales parity).
                  if (message.isReplied && message.queryReply != null)
                    _inlineDoneRow(
                      'Reply: ${message.queryReply}',
                      // Same person replied → stay under the typed text on
                      // its left edge; the other person → opposite (right)
                      // edge (user rule).
                      left: message.repliedBy == message.senderId,
                    ),
                  // Follow-up mark done button
                  if (message.systemType == SystemMessageType.followUp &&
                      !message.isFollowUpDone &&
                      message.senderId == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () => _markFollowUpDone(message),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1976D2).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(
                                  0xFF1976D2,
                                ).withOpacity(0.25),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.check_circle_outline,
                                  size: 11,
                                  color: const Color(0xFF1976D2),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  'Mark Done',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF1976D2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Follow-up: Reply belongs to the OTHER side only (user
                  // rule — same-side Reply removed). A reply answers the
                  // follow-up but is NOT a mark-done; only the scheduler's
                  // Mark Done closes it (replyCloses excludes followUp in
                  // _showQueryReplyDialog).
                  if (message.systemType == SystemMessageType.followUp &&
                      message.senderId != _currentUserId &&
                      !message.isFollowUpDone &&
                      !message.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _inlineActionChip(
                          'Reply',
                          Icons.reply,
                          () => _showQueryReplyDialog(
                            message,
                            dialogTitle: 'Reply to Follow Up',
                          ),
                        ),
                      ),
                    ),
                  // Follow-up done status (who/when rides the notice line)
                  if (message.systemType == SystemMessageType.followUp &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Done', headerLabel: actionType),
                  // Blocker: creator can mark resolved
                  if (message.systemType == SystemMessageType.blocker &&
                      !message.isFollowUpDone &&
                      _currentTask.createdBy == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _inlineActionChip(
                          'Mark Resolved',
                          Icons.check_circle_outline,
                          () => _resolveBlocker(message),
                        ),
                      ),
                    ),
                  // Blocker resolved status
                  if (message.systemType == SystemMessageType.blocker &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Resolved', headerLabel: actionType),
                  // Approval/Request: only the OTHER side gets Reply — and a
                  // reply from them CLOSES the card (user rule: "take reply
                  // as closed", the Close button is gone). The raiser sees no
                  // chips on their own request.
                  if (message.systemType == SystemMessageType.approval &&
                      !message.isFollowUpDone &&
                      message.senderId != _currentUserId &&
                      !message.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Reply',
                            Icons.reply,
                            () => _showQueryReplyDialog(
                              message,
                              dialogTitle: 'Reply to Request',
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Request closed status (set by the other side's reply)
                  if (message.systemType == SystemMessageType.approval &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Closed', headerLabel: actionType),
                  // Query: only the OTHER side replies, and their reply closes
                  // the card (user rule — the raiser's Close button is gone;
                  // the reply IS the answer the query asked for).
                  if (message.systemType == SystemMessageType.query &&
                      !message.isFollowUpDone &&
                      message.senderId != _currentUserId &&
                      !message.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Reply',
                            Icons.reply,
                            () => _showQueryReplyDialog(
                              message,
                              dialogTitle: 'Reply to Query',
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Query closed status
                  if (message.systemType == SystemMessageType.query &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Closed', headerLabel: actionType),
                  // Scheduled call: the scheduler marks the call done
                  if (message.systemType == SystemMessageType.call &&
                      !message.isFollowUpDone &&
                      message.senderId == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _inlineActionChip(
                          'Mark Done',
                          Icons.check_circle_outline,
                          () => _markCallDone(message),
                        ),
                      ),
                    ),
                  // Scheduled call done status
                  if (message.systemType == SystemMessageType.call &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Done', headerLabel: actionType),
                  // Scheduled meeting: Mark Done belongs to the scheduler (the
                  // card's sender) only; Reply belongs to the OTHER side only
                  // (user rule — removed from the same side). Done closes; a
                  // reply never does, and once closed the Reply option is
                  // gone (reply TEXT stays in the consolidated block).
                  if (Helpers.detectActionType(messageText) == 'meeting' &&
                      !message.isFollowUpDone &&
                      (message.senderId == _currentUserId ||
                          !message.isReplied))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (message.senderId == _currentUserId)
                            _inlineActionChip(
                              'Mark Done',
                              Icons.check_circle_outline,
                              () => _markMeetingDone(message),
                            ),
                          if (message.senderId != _currentUserId &&
                              !message.isReplied)
                            _inlineActionChip(
                              'Reply',
                              Icons.reply,
                              () => _showQueryReplyDialog(
                                message,
                                dialogTitle: 'Reply to Meeting',
                              ),
                            ),
                        ],
                      ),
                    ),
                  // Meeting reply note lives in the single consolidated Reply
                  // block above (survives Done). Meeting done status:
                  if (Helpers.detectActionType(messageText) == 'meeting' &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Done', headerLabel: actionType),
                  // Scheduled visit (🛠️ key, rides as a regular system message —
                  // same as meeting): Mark Done shows on BOTH sides (user
                  // rule — either party can confirm the visit happened), so
                  // R2's initiator-only gate does NOT apply to Visit. Reply
                  // stays while the card is open; a reply never closes; once
                  // Done lands the Reply option is gone (reply TEXT stays in
                  // the consolidated block above).
                  if (Helpers.detectActionType(messageText) == 'sitevisit' &&
                      !message.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Mark Done',
                            Icons.check_circle_outline,
                            () => _markVisitDone(message),
                          ),
                          // Reply belongs to the OTHER side only (user rule)
                          // — the scheduler acts via Mark Done, not reply.
                          if (!message.isReplied &&
                              message.senderId != _currentUserId) ...[
                            const SizedBox(width: 6),
                            _inlineActionChip(
                              'Reply',
                              Icons.reply,
                              () => _showQueryReplyDialog(
                                message,
                                dialogTitle: 'Reply to Visit',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  // Visit reply note lives in the single consolidated Reply
                  // block above (survives Done). Visit done status:
                  if (Helpers.detectActionType(messageText) == 'sitevisit' &&
                      message.isFollowUpDone)
                    _inlineDoneRow('Done', headerLabel: actionType),
                  // Extension: creator can grant or deny
                  if (message.systemType == SystemMessageType.extension &&
                      !message.isReplied &&
                      _currentTask.createdBy == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Grant',
                            Icons.event_available,
                            () => _resolveExtension(message, true),
                          ),
                          const SizedBox(width: 6),
                          _inlineActionChip(
                            'Deny',
                            Icons.event_busy,
                            () => _resolveExtension(message, false),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Send Later (in-app only) ──────────────────────────────────────

  String get _outboxModuleTag => 'task';

  /// Read every scheduled row across all modules/tasks from the local
  /// SharedPreferences outbox (a JSON list). Malformed data degrades to empty.
  Future<List<Map<String, dynamic>>> _readScheduledOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scheduledOutboxKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeScheduledOutbox(List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scheduledOutboxKey, jsonEncode(rows));
  }

  /// Add [m] to the outbox, or drop it when [remove] is true. Rows are keyed by
  /// message id so a flush + cancel can't race into duplicates.
  Future<void> _persistScheduled(MessageModel m, {bool remove = false}) async {
    final rows = await _readScheduledOutbox();
    rows.removeWhere((r) => r['id'] == m.id);
    if (!remove) {
      rows.add({
        'id': m.id,
        'taskId': m.taskId,
        'module': _outboxModuleTag,
        'senderId': m.senderId,
        'text': m.text,
        'scheduledAt': m.scheduledAt!.toIso8601String(),
      });
    }
    await _writeScheduledOutbox(rows);
  }

  /// Load this task's held messages into memory, flush any already due, and
  /// start the periodic timer that fires ones coming due while the chat is open.
  Future<void> _initScheduledMessages() async {
    await _loadScheduledFromOutbox();
    await _flushDueScheduled();
    _scheduledFlushTimer?.cancel();
    _scheduledFlushTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _flushDueScheduled();
    });
  }

  Future<void> _loadScheduledFromOutbox() async {
    final rows = await _readScheduledOutbox();
    final loaded = <MessageModel>[];
    for (final r in rows) {
      if (r['taskId'] != _currentTask.id) continue;
      final at = DateTime.tryParse('${r['scheduledAt']}');
      if (at == null) continue;
      loaded.add(
        MessageModel(
          id: '${r['id']}',
          taskId: '${r['taskId']}',
          senderId: '${r['senderId']}',
          text: '${r['text']}',
          type: MessageType.text,
          createdAt: at,
          scheduledAt: at,
        ),
      );
    }
    loaded.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
    if (!mounted) return;
    setState(() {
      _scheduledMessages
        ..clear()
        ..addAll(loaded);
    });
  }

  /// Send every held message whose time has passed through the normal send path
  /// (so it persists + renders like a live message), then drop it from outbox.
  Future<void> _flushDueScheduled() async {
    if (_scheduledMessages.isEmpty) return;
    final now = DateTime.now();
    final due = _scheduledMessages
        .where((m) => !m.scheduledAt!.isAfter(now))
        .toList();
    for (final m in due) {
      await _persistScheduled(m, remove: true);
      final msg = MessageModel(
        id: m.id,
        taskId: _currentTask.id,
        senderId: m.senderId,
        text: m.text,
        type: MessageType.text,
        createdAt: DateTime.now(),
        deliveryMethod: 'in-app',
      );
      if (!mounted) return;
      setState(() {
        _messages.add(msg);
        _rebuildDisplayMessages();
        _scheduledMessages.removeWhere((x) => x.id == m.id);
      });
      _saveMessageToFirebase(msg);
    }
  }

  /// Composer action: pick a future date + time, then hold the draft text as a
  /// scheduled message (in-app only — no push at send time).
  Future<void> _scheduleCurrentMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a message to schedule first')),
      );
      return;
    }
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(minutes: 5)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
    );
    if (time == null || !mounted) return;
    final when = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!when.isAfter(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a time in the future')),
      );
      return;
    }
    final msg = MessageModel(
      id: Helpers.generateId(),
      taskId: _currentTask.id,
      senderId: _currentUserId,
      text: text,
      type: MessageType.text,
      createdAt: when,
      scheduledAt: when,
    );
    await _persistScheduled(msg);
    if (!mounted) return;
    _messageController.clear();
    setState(() {
      _scheduledMessages
        ..add(msg)
        ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Scheduled for ${DateFormat('d MMM, h:mm a').format(when)}',
        ),
      ),
    );
  }

  Future<void> _cancelScheduled(MessageModel m) async {
    await _persistScheduled(m, remove: true);
    if (!mounted) return;
    setState(() => _scheduledMessages.removeWhere((x) => x.id == m.id));
  }

  /// Send a held scheduled message immediately (before its time) through the
  /// normal send path, then drop it from the outbox.
  Future<void> _sendScheduledNow(MessageModel m) async {
    await _persistScheduled(m, remove: true);
    final msg = MessageModel(
      id: m.id,
      taskId: _currentTask.id,
      senderId: m.senderId,
      text: m.text,
      type: MessageType.text,
      createdAt: DateTime.now(),
      deliveryMethod: 'in-app',
    );
    if (!mounted) return;
    setState(() {
      _messages.add(msg);
      _rebuildDisplayMessages();
      _scheduledMessages.removeWhere((x) => x.id == m.id);
    });
    _scrollToBottom();
    _saveMessageToFirebase(msg);
  }

  /// Pending-scheduled strip shown above the composer. Collapsed to a single
  /// tappable heading — "Scheduled (N)" — so a queue of "Send Later" items
  /// never crowds the input bar. Tapping opens [_showScheduledSheet] where the
  /// user can send an item now, review it, or cancel before it fires.
  Widget _buildScheduledStrip() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: _showScheduledSheet,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              const Icon(
                Icons.schedule,
                size: 13,
                color: AppTheme.secondaryText,
              ),
              const SizedBox(width: 4),
              Text(
                'Scheduled (${_scheduledMessages.length})',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.secondaryText,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.expand_more,
                size: 16,
                color: AppTheme.secondaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom sheet listing every pending "Send Later" message with its time and
  /// text, each with a send-now and a delete action so the user can fire it
  /// early or cancel it before it goes out. Keeps its own local view via
  /// [StatefulBuilder] so an action refreshes the list live, and dismisses once
  /// the last item is removed.
  void _showScheduledSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final items = List<MessageModel>.from(_scheduledMessages);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.schedule,
                          size: 16,
                          color: AppTheme.secondaryText,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Scheduled (${items.length})',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No scheduled messages',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (final m in items)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.grey[300]!,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${DateFormat('d MMM, h:mm a').format(m.scheduledAt!)}\n${m.text}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.primaryText,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // Send now — fire it immediately.
                                      InkWell(
                                        onTap: () async {
                                          await _sendScheduledNow(m);
                                          if (_scheduledMessages.isEmpty) {
                                            if (sheetContext.mounted) {
                                              Navigator.pop(sheetContext);
                                            }
                                          } else {
                                            setSheetState(() {});
                                          }
                                        },
                                        child: const Padding(
                                          padding: EdgeInsets.all(2),
                                          child: Icon(
                                            Icons.send,
                                            size: 20,
                                            color: AppTheme.primaryGreen,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // Cancel — drop it without sending.
                                      InkWell(
                                        onTap: () async {
                                          await _cancelScheduled(m);
                                          if (_scheduledMessages.isEmpty) {
                                            if (sheetContext.mounted) {
                                              Navigator.pop(sheetContext);
                                            }
                                          } else {
                                            setSheetState(() {});
                                          }
                                        },
                                        child: const Padding(
                                          padding: EdgeInsets.all(2),
                                          child: Icon(
                                            Icons.delete_outline,
                                            size: 20,
                                            color: AppTheme.secondaryText,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInputBar() {
    // Removed assignee: the card stays visible but is frozen and read-only.
    // The Firestore rules already deny this user sending (they are no longer a
    // participant), so rather than let them type into a composer whose sends
    // would silently fail, replace the whole input bar with a plain hint.
    if (_currentTask.extraFields?['accessRevoked'] == true) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          color: AppTheme.lightGrey,
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: AppTheme.secondaryText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "You're no longer assigned to this task — chats and updates "
                  'are paused.',
                  style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(color: AppTheme.lightGrey),
      // Ensure input bar stays above bottom sheet and keyboard
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pending "Send Later" items held for this task (tap to review,
            // send now or cancel).
            if (_scheduledMessages.isNotEmpty) _buildScheduledStrip(),
            // Show selected follow-up date indicator
            if (_selectedReminderDate != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.primaryGreen.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.event_note,
                      size: 16,
                      color: AppTheme.primaryGreen,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Follow-up: ${DateFormat('MMM dd, yyyy hh:mm a').format(_selectedReminderDate!)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryGreen,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedReminderDate = null;
                        });
                      },
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: AppTheme.primaryGreen,
                      ),
                    ),
                  ],
                ),
              ),
            // Voice recording overlay
            if (isRecording) buildRecordingOverlay(),
            // Voice preview (after recording stopped)
            if (voicePreviewVisible && !isRecording) buildVoicePreview(),
            // Reply preview (WhatsApp-style)
            if (_replyingToMessage != null) _buildReplyPreview(),
            // @mention suggestions dropdown (shown while typing "@name")
            MentionSuggestions(
              mention: _mention,
              messageController: _messageController,
            ),
            // Input row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Expanded text input area (Slack-style: square corners)
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.grey[300]!, width: 1),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Emoji button (left)
                        IconButton(
                          icon: const Icon(
                            Icons.emoji_emotions_outlined,
                            color: AppTheme.secondaryText,
                            size: 22,
                          ),
                          onPressed: () {
                            ChatEmojiPicker.show(context, _messageController);
                          },
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                        // Text field
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            focusNode: _messageFocusNode,
                            maxLines: 1,
                            maxLength: 2000,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                            decoration: InputDecoration(
                              hintText:
                                  _currentTask.extraFields?['isDraft'] == true
                                  ? 'Type your task here...'
                                  : 'Type a message...',
                              counterText: '',
                              isCollapsed: true,
                              hintStyle: TextStyle(
                                color: AppTheme.lightText,
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 14,
                              ),
                            ),
                            style: const TextStyle(
                              fontSize: 16,
                              color: AppTheme.primaryText,
                            ),
                          ),
                        ),
                        // Attachment button
                        IconButton(
                          icon: const Icon(
                            Icons.attach_file,
                            color: AppTheme.secondaryText,
                            size: 22,
                          ),
                          onPressed: () => _showAttachmentSheet(context),
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // More actions button (Slack-style: square corners)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[300]!, width: 1),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _showMessageActions(context),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        child: const Icon(
                          Icons.add_circle_outline,
                          color: AppTheme.primaryGreen,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Send Later (schedule) button — only while there is draft text.
                ValueListenableBuilder<bool>(
                  valueListenable: _hasText,
                  builder: (context, hasText, _) => hasText
                      ? Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.grey[300]!,
                                width: 1,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _scheduleCurrentMessage,
                                borderRadius: BorderRadius.circular(8),
                                child: const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: Icon(
                                    Icons.schedule,
                                    color: AppTheme.secondaryText,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                // Conditional Send / Mic button (Slack-style: square corners, flat design)
                if (voicePreviewVisible)
                  // Voice preview mode: show send voice button
                  Container(
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: sendVoiceMessage,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          child: const Icon(
                            Icons.send,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  ValueListenableBuilder<bool>(
                    valueListenable: _hasText,
                    builder: (context, hasText, _) {
                      if (hasText)
                        // Text mode: show send button
                        return Container(
                          decoration: BoxDecoration(
                            color: AppTheme.primaryGreen,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _sendMessage,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                child: const Icon(
                                  Icons.send,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        );
                      else
                        // Empty text: show mic button for voice recording
                        return Container(
                          decoration: BoxDecoration(
                            color: isRecording
                                ? Colors.red
                                : AppTheme.primaryGreen,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: isRecording
                                  ? stopRecording
                                  : startRecording,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                child: Icon(
                                  isRecording ? Icons.stop : Icons.mic,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        );
                    },
                  ),
              ],
            ),
          ],
        ), // SafeArea
      ),
    );
  }

  // WhatsApp-style reply preview bar above text input.
  // Rendered by DetailChatPlumbingMixin so Sales/CRM quote identically.
  Widget _buildReplyPreview() => buildChatReplyPreview(
    _replyingToMessage!,
    senderName: _getSenderName(_replyingToMessage!.senderId),
    accent: AppTheme.primaryGreen,
    onCancel: () => setState(() => _replyingToMessage = null),
  );

  void _showMessageActions(BuildContext context) {
    // Flat 4-column action grid — same format as the Sales module sheet.
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.only(
          top: 20,
          bottom: 20 + MediaQuery.of(ctx).padding.bottom,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.lightText.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Message Actions',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryGreen,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  runSpacing: 16,
                  children: [
                    for (final a in ModuleConfig.task.actionTypes)
                      // Sales parity: 'call' has no standalone tile — it is
                      // folded into the 'meeting' chooser ("Meeting/Call").
                      // WhatsApp is auto-recorded (no manual tile / handler).
                      ...a.key == 'meeting'
                          ? [
                              _messageActionTile(
                                ctx,
                                a.icon,
                                'Meeting/Call',
                                a.color,
                                () {
                                  Navigator.pop(ctx);
                                  _chooseMeetingOrCall();
                                },
                              ),
                            ]
                          : (a.key == 'whatsapp' || a.key == 'call')
                          ? const <Widget>[]
                          : [
                              _messageActionTile(
                                ctx,
                                a.icon,
                                a.label,
                                a.color,
                                () {
                                  Navigator.pop(ctx);
                                  _runTaskAction(a.key);
                                },
                              ),
                            ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// One tile of the Message Actions grid (Sales-module sheet format).
  SizedBox _messageActionTile(
    BuildContext ctx,
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return SizedBox(
      width: (MediaQuery.of(ctx).size.width - 16) / 4,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 28, color: color),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dispatch a Message Actions tile tap by its configured action key. The
  /// tile list is data-driven from [ModuleConfig.task].actionTypes; this maps
  /// each key back to the same bespoke Task handler the hardcoded sheet used,
  /// so tapping a tile behaves exactly as before.
  /// Action keys that have a bespoke Task dialog, i.e. everything
  /// _runTaskAction can dispatch. The action-card reopen path checks this set
  /// so a card only reopens a dialog its tile would also offer — non-listed
  /// classify keys (auto-recorded WhatsApp, extension, progress) fall through
  /// to scroll-to-message. Must stay in sync with _runTaskAction's cases.
  static const Set<String> _runnableTaskActionKeys = {
    'reminder',
    'approval',
    'query',
    'followup',
    'call',
    // 🤝 Meeting cards reopen the paired Meeting/Call chooser (Sales parity).
    'meeting',
    'cash',
    // 💳 receivable cards reopen the same Cash/Payment dialog (Sales parity).
    'payment',
    'blocker',
    // 🛠️ Visit cards reopen the schedule-visit dialog (dated commitment).
    'sitevisit',
  };

  void _runTaskAction(String key) {
    switch (key) {
      case 'reminder':
        _issueReminder();
        break;
      case 'approval':
        _requestApproval();
        break;
      case 'query':
        _askStatusReport();
        break;
      case 'followup':
        _showFollowUpWithMessageDialog();
        break;
      case 'call':
        _showScheduleCallDialog();
        break;
      case 'meeting':
        _showScheduleMeetingDialog();
        break;
      case 'cash':
      case 'payment':
        _recordCashAction();
        break;
      case 'blocker':
        _raiseBlocker();
        break;
      case 'sitevisit':
        _scheduleVisit();
        break;
    }
  }

  /// Next occurrence number for [actionKey] — same rule as the Sales cards'
  /// _nextActionNumber: count prior chat messages of the same detected type
  /// (full stream list when available) and add 1. Called before the new card
  /// is appended, so the returned number is the card's own.
  int _nextActionNumber(String actionKey) {
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    var n = 0;
    for (final m in source) {
      if (Helpers.detectActionType(m.text) == actionKey) n++;
    }
    return n + 1;
  }

  // Cash management: add / expense / refund / settled with running balance,
  // plus the Sales-parity Payment side (due / collected with the
  // Due · Collected · Outstanding receivables footer).
  Future<void> _recordCashAction() async {
    // Balance from every cash message seen so far (full stream list when
    // available — _messages may be a paginated subset)
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    final texts = source.map((m) => m.text);
    final balance = Helpers.computeCashBalance(texts);
    final (due, collected, _) = Helpers.computeReceivables(texts);
    final result = await showCashActionDialog(
      context,
      currentBalance: balance,
      currentDue: due,
      currentCollected: collected,
      includeReceivables: true,
    );
    if (result == null || !mounted) return;
    // Number the card per occurrence ('Cash Added 2', 'Payment - Due 1')
    // — 💵 entries share the 'cash' counter, 💳 entries the 'payment' one.
    final entryKey = Helpers.detectActionType(result.text);
    await _sendSystemMessage(
      result.text,
      sequenceNumber: entryKey == null ? null : _nextActionNumber(entryKey),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cash entry recorded'),
          backgroundColor: Color(0xFF099268),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Assignee: raise a blocker (resolved by creator via follow-up done mechanics)
  // Switch the task between Blocked and Active. Blocked is stored in
  // extraFields (null clears it — FirebaseService translates the null
  // into FieldValue.delete).
  Future<void> _applyBlockedStatus({required bool blocked}) async {
    final extra = _currentTask.extraFields;
    final currentlyBlocked = extra != null && extra['isBlocked'] == true;
    if (blocked == currentlyBlocked) return;

    final oldStatus = _getTaskStatus();
    final updatedExtraFields = Map<String, dynamic>.from(extra ?? {});
    updatedExtraFields['isBlocked'] = blocked ? true : null;

    final updatedTask = _currentTask.copyWith(
      extraFields: updatedExtraFields,
      updatedAt: DateTime.now(),
    );
    setState(() {
      _currentTask = updatedTask;
    });
    await _updateTaskInFirebase(updatedTask);

    final newStatus = blocked ? 'Blocked' : 'Active';
    final timestamp = Helpers.formatDateTime(DateTime.now());
    await _sendSystemMessage(
      '📊 Status changed: $oldStatus → $newStatus by $_currentUserName at $timestamp',
    );
  }

  Future<void> _raiseBlocker() async {
    // Only one open blocker at a time: refuse a second until the current one
    // is resolved (mirrors Sales).
    if (_messages.any(
      (m) => m.systemType == SystemMessageType.blocker && !m.isFollowUpDone,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Resolve the current blocker before raising a new one'),
          backgroundColor: Color(0xFFC92A2A),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final controller = TextEditingController();
    String reason = '';
    // Sales parity: every action composer offers the optional attachment
    // that rides inside the posted action card.
    PickedChatAttachment? pickedAttachment;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Row(
            children: [
              Icon(Icons.block, color: Color(0xFFC92A2A)),
              SizedBox(width: 8),
              Text('Raise Blocker'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'What is blocking you?',
                  counterText: '',
                  hintStyle: const TextStyle(fontSize: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (value) => reason = value,
              ),
              buildChatAttachmentRow(
                picked: pickedAttachment,
                onChanged: (a) => setDialogState(() => pickedAttachment = a),
                accentColor: const Color(0xFFC92A2A),
              ),
              // "Previous Blocker: 2" — only one stays open at a time, so this
              // shows how many were already raised and resolved on this task.
              PreviousActionHint(
                label: 'Blocker',
                count: _nextActionNumber('blocker') - 1,
                color: const Color(0xFFC92A2A),
                emoji: '🚧',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (reason.trim().isEmpty) return;
                Navigator.pop(ctx, reason.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC92A2A),
                foregroundColor: Colors.white,
              ),
              child: const Text('Raise'),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;
    // Task becomes Blocked while a blocker is open
    await _applyBlockedStatus(blocked: true);
    if (!mounted) return;
    await _sendSystemMessage(
      '🚧 Blocker raised: "$result" by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      systemType: SystemMessageType.blocker,
      attachment: pickedAttachment,
      // Number the card per occurrence ("Blocker 2") — same rule as
      // Request/Call; the chip reads it off the actions row's seqNo.
      sequenceNumber: _nextActionNumber('blocker'),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Blocker raised'),
          backgroundColor: Color(0xFFC92A2A),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Guards against a second Request dialog opening while one is already
  // up or being sent (was causing duplicate 'Approval requested' posts).
  bool _requestApprovalInFlight = false;

  // Assignee: request approval from the creator
  Future<void> _requestApproval() async {
    if (_requestApprovalInFlight) return;
    _requestApprovalInFlight = true;
    final controller = TextEditingController();
    String note = '';
    // Sales parity: optional attachment rides inside the Request card.
    PickedChatAttachment? pickedAttachment;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Row(
            children: [
              Icon(Icons.fact_check, color: Color(0xFF0B7285)),
              SizedBox(width: 8),
              Text('Request'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Note',
                  counterText: '',
                  hintStyle: const TextStyle(fontSize: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (value) => note = value,
              ),
              buildChatAttachmentRow(
                picked: pickedAttachment,
                onChanged: (a) => setDialogState(() => pickedAttachment = a),
                accentColor: const Color(0xFF0B7285),
              ),
              // "Previous Request: 2" — this card will be numbered N+1.
              PreviousActionHint(
                label: 'Request',
                count: _nextActionNumber('approval') - 1,
                color: const Color(0xFF0B7285),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (note.trim().isEmpty) return;
                Navigator.pop(ctx, note.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0B7285),
                foregroundColor: Colors.white,
              ),
              child: const Text('Request'),
            ),
          ],
        ),
      ),
    );
    _requestApprovalInFlight = false;

    if (result == null || !mounted) return;
    final noteText = result.isEmpty ? '' : ': "$result"';
    await _sendSystemMessage(
      'Approval requested$noteText by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      systemType: SystemMessageType.approval,
      attachment: pickedAttachment,
      // Number the card per occurrence ("Request 2") — same rule as
      // Call/Meeting/Follow-up; computed before the card is appended.
      sequenceNumber: _nextActionNumber('approval'),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request sent'),
          backgroundColor: Color(0xFF0B7285),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Schedule Follow Up: ONE popup (date + time + note) exactly like Schedule
  // Visit — replaced the old two-step flow (a compact day/month/year/hour
  // roller, then a separate message box). Posts a single blue follow-up card.
  Future<void> _showFollowUpWithMessageDialog() async {
    final result = await showScheduleCallDialog(
      context,
      accentColor: AppTheme.primaryGreen,
      title: 'Follow Up',
      icon: Icons.event_note,
      previousLabel: 'Follow Up',
      previousCount: _nextActionNumber('followup') - 1,
      previousEmoji: '📅',
    );
    if (result == null || !mounted) return;
    await _sendMessageWithReminder(
      result.note.trim(),
      result.reminderAt,
      hasTime: result.hasTime,
    );
  }

  // Schedule Call: ONE popup with date/time rollers + note box, then one blue
  // call action message. Available to BOTH sides; tapping any Call card in
  // chat reopens this so the next call can be scheduled right away. At the
  // scheduled time this device fires a local notification and the other side
  // gets a server push (remindScheduledCalls sweep).
  Future<void> _showScheduleCallDialog() async {
    final result = await showScheduleCallDialog(
      context,
      previousLabel: 'Call',
      previousCount: _nextActionNumber('call') - 1,
      previousEmoji: '📞',
    );
    if (result == null || !mounted) return;

    // Picker rule: a day-only schedule (no time chosen) sends just the date to
    // the chat; the stored/reminder moment falls back to 09:00 via reminderAt.
    final selectedDate = result.reminderAt;
    final bool hasTime = result.hasTime;
    final note = result.note;
    final timestamp = Helpers.formatDateTime(DateTime.now());
    final whenStr = hasTime
        ? Helpers.formatDateTime(selectedDate)
        : Helpers.formatDate(selectedDate);
    final callText = note.isNotEmpty
        ? '📞 Call scheduled: "$note" for $whenStr by $_currentUserName at $timestamp'
        : '📞 Call scheduled: for $whenStr by $_currentUserName at $timestamp';
    await _sendSystemMessage(
      callText,
      systemType: SystemMessageType.call,
      scheduledAt: selectedDate,
      // Number the card per occurrence ("Call Scheduled 2") — same rule as
      // Meeting/Reminder; computed before the card is appended.
      sequenceNumber: _nextActionNumber('call'),
    );
    _scheduleCallReminder(selectedDate, note);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '📞 Call scheduled for ${DateFormat(hasTime ? 'MMM dd, yyyy hh:mm a' : 'MMM dd, yyyy').format(selectedDate)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFF0C8599),
        ),
      );
    }
  }

  // Local reminder on this device for whoever scheduled the call; the other
  // side gets the server-side push at the same moment.
  void _scheduleCallReminder(DateTime when, String note) {
    final title = _currentTask.title.isNotEmpty ? _currentTask.title : 'Task';
    NotificationService().scheduleDeadlineReminder(
      id:
          '${_currentTask.id}-call-${when.millisecondsSinceEpoch}'.hashCode &
          0x7fffffff,
      title: '📞 Scheduled call',
      body: note.isNotEmpty ? '"$title" — $note' : 'Call for "$title"',
      scheduledDate: when,
    );
  }

  /// Combined "Meeting/Call" chooser for the Task Message Actions sheet —
  /// Sales parity: one tile offers Meeting or Call, each opening its own
  /// appointment dialog (the same schedule-call popup, retitled for meetings).
  Future<void> _chooseMeetingOrCall() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                'Meeting or Call',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryText,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.groups, color: Color(0xFF3B5BDB)),
              title: const Text(
                'Meeting',
                style: TextStyle(fontSize: 15, color: AppTheme.primaryText),
              ),
              onTap: () => Navigator.pop(ctx, 'meeting'),
            ),
            ListTile(
              leading: const Icon(Icons.call, color: Color(0xFF0C8599)),
              title: const Text(
                'Call',
                style: TextStyle(fontSize: 15, color: AppTheme.primaryText),
              ),
              onTap: () => Navigator.pop(ctx, 'call'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (picked == 'meeting') {
      await _showScheduleMeetingDialog();
    } else if (picked == 'call') {
      await _showScheduleCallDialog();
    }
  }

  // Schedule Meeting: same date/time + note popup as Schedule Call, but posts
  // a 🤝 Meeting card (Sales parity). Numbered per occurrence ("Meeting 2");
  // informational like the Sales meeting card (no done checkbox).
  Future<void> _showScheduleMeetingDialog() async {
    final result = await showScheduleCallDialog(
      context,
      accentColor: const Color(0xFF3B5BDB),
      title: 'Schedule Meeting',
      icon: Icons.groups,
      previousLabel: 'Meeting',
      previousCount: _nextActionNumber('meeting') - 1,
      previousEmoji: '🤝',
    );
    if (result == null || !mounted) return;

    // Picker rule: day-only → date-only caption, reminder/stored at 09:00.
    final selectedDate = result.reminderAt;
    final bool hasTime = result.hasTime;
    final note = result.note;
    final timestamp = Helpers.formatDateTime(DateTime.now());
    final whenStr = hasTime
        ? Helpers.formatDateTime(selectedDate)
        : Helpers.formatDate(selectedDate);
    final meetingText = note.isNotEmpty
        ? '🤝 Meeting scheduled: "$note" for $whenStr by $_currentUserName at $timestamp'
        : '🤝 Meeting scheduled: for $whenStr by $_currentUserName at $timestamp';
    await _sendSystemMessage(
      meetingText,
      systemType: SystemMessageType.regular,
      scheduledAt: selectedDate,
      sequenceNumber: _nextActionNumber('meeting'),
    );
    _scheduleMeetingReminder(selectedDate, note);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '🤝 Meeting scheduled for ${DateFormat(hasTime ? 'MMM dd, yyyy hh:mm a' : 'MMM dd, yyyy').format(selectedDate)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFF3B5BDB),
        ),
      );
    }
  }

  void _scheduleMeetingReminder(DateTime when, String note) {
    final title = _currentTask.title.isNotEmpty ? _currentTask.title : 'Task';
    NotificationService().scheduleDeadlineReminder(
      id:
          '${_currentTask.id}-meeting-${when.millisecondsSinceEpoch}'.hashCode &
          0x7fffffff,
      title: '🤝 Scheduled meeting',
      body: note.isNotEmpty ? '"$title" — $note' : 'Meeting for "$title"',
      scheduledDate: when,
    );
  }

  // Schedule Visit: same date/time + note popup as Meeting/Call, but posts a
  // 🛠️ Visit card (Sales sitevisit parity). A dated commitment — the owner
  // marks it done via the card's Mark-Done chip; numbered per occurrence.
  Future<void> _scheduleVisit() async {
    final result = await showScheduleCallDialog(
      context,
      accentColor: const Color(0xFF1098AD),
      title: 'Schedule Visit',
      icon: Icons.handyman,
      previousLabel: 'Visit',
      previousCount: _nextActionNumber('sitevisit') - 1,
      previousEmoji: '🛠️',
    );
    if (result == null || !mounted) return;

    // Picker rule: a day-only visit sends just "on dd/MM/yyyy" — no fabricated
    // "at hh:mm" — while the stored/reminder moment defaults to 09:00.
    final selectedDate = result.reminderAt;
    final bool hasTime = result.hasTime;
    final note = result.note;
    // Match the Sales visit caption exactly (user rule): "🛠️ <note> on
    // dd/MM/yyyy at hh:mm a" — no quotes, "on" (not "for"), and no trailing
    // "by <name> at <ts>" (the card header already shows the actor). The 🛠️
    // emoji stays as the lead token for Helpers.detectActionType; the card
    // body strips it on display (sitevisit extraction fallback below).
    final d = selectedDate;
    final dateStr =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final whenPart = hasTime
        ? '$dateStr at ${DateFormat('hh:mm a').format(d)}'
        : dateStr;
    final visitText = note.isNotEmpty
        ? '🛠️ $note on $whenPart'
        : '🛠️ $whenPart';
    await _sendSystemMessage(
      visitText,
      systemType: SystemMessageType.regular,
      scheduledAt: selectedDate,
      sequenceNumber: _nextActionNumber('sitevisit'),
    );
    _scheduleVisitReminder(selectedDate, note);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '🛠️ Visit scheduled for ${DateFormat(hasTime ? 'MMM dd, yyyy hh:mm a' : 'MMM dd, yyyy').format(selectedDate)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFF1098AD),
        ),
      );
    }
  }

  void _scheduleVisitReminder(DateTime when, String note) {
    final title = _currentTask.title.isNotEmpty ? _currentTask.title : 'Task';
    NotificationService().scheduleDeadlineReminder(
      id:
          '${_currentTask.id}-visit-${when.millisecondsSinceEpoch}'.hashCode &
          0x7fffffff,
      title: '🛠️ Scheduled visit',
      body: note.isNotEmpty ? '"$title" — $note' : 'Visit for "$title"',
      scheduledDate: when,
    );
  }

  // Helper to create one blue follow-up action message only.
  Future<void> _sendMessageWithReminder(
    String text,
    DateTime scheduledDate, {
    PickedChatAttachment? attachment,
    // Picker rule: day-only follow-ups (no time chosen) send just the date.
    bool hasTime = true,
  }) async {
    final timestamp = Helpers.formatDateTime(DateTime.now());
    final whenStr = hasTime
        ? Helpers.formatDateTime(scheduledDate)
        : Helpers.formatDate(scheduledDate);
    final followupText = text.isNotEmpty
        ? '📅 Follow-up scheduled: "$text" for $whenStr by $_currentUserName at $timestamp'
        : '📅 Follow-up scheduled: $whenStr by $_currentUserName at $timestamp';

    _sendSystemMessage(
      followupText,
      systemType: SystemMessageType.followUp,
      attachment: attachment,
      // Number the card per occurrence ("Follow-up 2") — same rule as
      // Reminder/Query; computed before the card is appended.
      sequenceNumber: _nextActionNumber('followup'),
    );
    _selectedReminderDate = null;
    // Don't auto-scroll on follow-up scheduling - user can tap the down arrow

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '📅 Follow-up scheduled for ${DateFormat(hasTime ? 'MMM dd, yyyy hh:mm a' : 'MMM dd, yyyy').format(scheduledDate)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Show menu to edit Priority and Urgency
  void _showPriorityUrgencyMenu() {
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
                // Priority section removed — only Urgency is user-settable.
                // Urgency section
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Urgency',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryText,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Column(
                        children: [
                          _urgencyOption('none'),
                          _urgencyOption('attention'),
                          _urgencyOption('urgent'),
                          _urgencyOption('blocked'),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Category Picker ──────────────────────────────────────────────────────
  void _showCategoryPicker() async {
    final db = LocalDatabaseService();
    // getCategories('task') already includes module='all' rows (SQL ORs
    // module='all'), so a single fetch is enough. Dedupe by name to guard
    // against any legacy duplicate rows.
    final categories = await db.getCategories('task');
    final seen = <String>{};
    final combined = categories
        .where((cat) => seen.add((cat['name'] as String).toLowerCase()))
        .toList();

    if (!mounted) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Text(
                      'Select Category',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (_currentTask.category != null &&
                        _currentTask.category!.isNotEmpty)
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, '__clear__'),
                        child: const Text(
                          'Clear',
                          style: TextStyle(color: Colors.red, fontSize: 13),
                        ),
                      ),
                  ],
                ),
              ),
              if (combined.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No categories defined yet.\nGo to Settings → Categories to add.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppTheme.lightText),
                  ),
                )
              else
                ...combined.map((cat) {
                  final name = cat['name'] as String;
                  final isSelected = name == _currentTask.category;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isSelected ? Icons.label : Icons.label_outline,
                      color: isSelected
                          ? AppTheme.primaryGreen
                          : AppTheme.secondaryText,
                      size: 20,
                    ),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: isSelected
                            ? AppTheme.primaryGreen
                            : AppTheme.primaryText,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(
                            Icons.check,
                            color: AppTheme.primaryGreen,
                            size: 18,
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, name),
                  );
                }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (selected == null || !mounted) return;

    final newCategory = selected == '__clear__' ? null : selected;
    final oldCategory = _currentTask.category;
    if (newCategory == oldCategory) return;

    final updatedTask = _currentTask.copyWith(
      category: newCategory ?? '',
      updatedAt: DateTime.now(),
    );
    setState(() => _currentTask = updatedTask);
    await _updateTaskInFirebase(updatedTask);

    final timestamp = Helpers.formatDateTime(DateTime.now());
    final msg =
        '📂 Category changed: ${oldCategory ?? "None"} → ${newCategory ?? "None"} by $_currentUserName at $timestamp';
    await _sendSystemMessage(msg);
  }

  // ── Closure Rating ──────────────────────────────────────────────────────
  void _setRating(int rating) async {
    final oldRating = _currentTask.rating ?? 0;
    if (rating == oldRating) return;

    final updatedTask = _currentTask.copyWith(
      rating: rating,
      updatedAt: DateTime.now(),
    );
    setState(() => _currentTask = updatedTask);
    await _updateTaskInFirebase(updatedTask);

    final timestamp = Helpers.formatDateTime(DateTime.now());
    final msg =
        '⭐ Rating changed: $oldRating → $rating by $_currentUserName at $timestamp';
    await _sendSystemMessage(msg);
  }

  // Manage assignees inline
  void _manageAssignees() {
    print('[TaskDetail] _manageAssignees called');

    // Get max assignee limit based on user's plan type
    final planType = context.read<AuthProvider>().effectivePlanType;
    final maxAssigneeLimit = PaywallLimits.maxAssignees(planType);

    // Track both names and UIDs for proper Firestore queries
    List<String> currentAssigneeNames = [_currentTask.assignedTo];
    List<String> currentAssigneeUids = [];
    // Track phones for dual-lookup queries (UID + phone)
    List<String> currentAssigneePhones = [];

    // Initialize UIDs from extraFields if available
    if (_currentTask.extraFields != null &&
        _currentTask.extraFields!['assigneeUids'] != null) {
      currentAssigneeUids = List<String>.from(
        _currentTask.extraFields!['assigneeUids'] as List,
      );
    } else if (_currentTask.assignedToUid != null) {
      currentAssigneeUids = [_currentTask.assignedToUid!];
    }

    // Initialize phones from extraFields or top-level assignedToPhone
    if (_currentTask.extraFields != null &&
        _currentTask.extraFields!['assigneePhones'] != null) {
      currentAssigneePhones = List<String>.from(
        _currentTask.extraFields!['assigneePhones'] as List,
      );
    } else if (_currentTask.assignedToPhone != null &&
        _currentTask.assignedToPhone!.isNotEmpty) {
      currentAssigneePhones = [_currentTask.assignedToPhone!];
    }

    // If group task, use participants list
    if (_currentTask.isGroupTask) {
      final participantNames = _currentTask.extraFields?['participantNames'];
      if (participantNames is List && participantNames.isNotEmpty) {
        currentAssigneeNames = List<String>.from(participantNames);
      }
      // NOTE: participantUids/participants include the CREATOR's UID, so they
      // must never seed assignee UIDs — doing so corrupted assignedToUid on
      // save (creator UID stored as primary assignee). assigneeUids from
      // extraFields (handled above) is the only safe source.
    }

    // Pad UID/phone lists with '' so indexes stay aligned with names
    while (currentAssigneeUids.length < currentAssigneeNames.length) {
      currentAssigneeUids.add('');
    }
    while (currentAssigneePhones.length < currentAssigneeNames.length) {
      currentAssigneePhones.add('');
    }

    // Collapse rows that point to the SAME person under different names (the
    // contact-book name vs their app profile name — e.g. "Sonu" and
    // "Sudarshna Bhatnagar" sharing one phone number). Identity is matched on
    // normalized phone, then UID, then name; the first row wins and the
    // duplicate's missing UID/phone are merged into it. Runs on seed and after
    // every add so the list can never double-list one human.
    void dedupAssignees() {
      final keptNames = <String>[];
      final keptUids = <String>[];
      final keptPhones = <String>[];
      final phoneSlot = <String, int>{};
      final uidSlot = <String, int>{};
      final nameSlot = <String, int>{};
      for (int i = 0; i < currentAssigneeNames.length; i++) {
        final name = currentAssigneeNames[i];
        final nameLower = name.trim().toLowerCase();
        final rawPhone = i < currentAssigneePhones.length
            ? currentAssigneePhones[i]
            : '';
        final phone = Helpers.normalizePhone(rawPhone) ?? '';
        final uid = i < currentAssigneeUids.length
            ? currentAssigneeUids[i]
            : '';
        int? slot;
        if (phone.isNotEmpty) slot = phoneSlot[phone];
        if (slot == null && uid.isNotEmpty) slot = uidSlot[uid];
        if (slot == null) slot = nameSlot[nameLower];
        if (slot != null) {
          if (keptUids[slot].isEmpty && uid.isNotEmpty) keptUids[slot] = uid;
          if ((Helpers.normalizePhone(keptPhones[slot]) ?? '').isEmpty &&
              phone.isNotEmpty) {
            keptPhones[slot] = rawPhone;
          }
        } else {
          slot = keptNames.length;
          keptNames.add(name);
          keptUids.add(uid);
          keptPhones.add(rawPhone);
          if (phone.isNotEmpty) phoneSlot[phone] = slot;
          if (uid.isNotEmpty) uidSlot[uid] = slot;
          nameSlot[nameLower] = slot;
        }
      }
      currentAssigneeNames
        ..clear()
        ..addAll(keptNames);
      currentAssigneeUids
        ..clear()
        ..addAll(keptUids);
      currentAssigneePhones
        ..clear()
        ..addAll(keptPhones);
    }

    dedupAssignees();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Manage Assignees'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Current Assignees:',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  // Assignee count indicator
                  Text(
                    '${currentAssigneeNames.length}/$maxAssigneeLimit assignees',
                    style: TextStyle(
                      fontSize: 12,
                      color: currentAssigneeNames.length >= maxAssigneeLimit
                          ? Colors.orange
                          : AppTheme.secondaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Current assignees list
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: currentAssigneeNames.length,
                      itemBuilder: (context, index) {
                        final assignee = currentAssigneeNames[index];
                        final avatarUrl = AvatarCacheService().urlFor(
                          uid: index < currentAssigneeUids.length
                              ? currentAssigneeUids[index]
                              : null,
                          phone: index < currentAssigneePhones.length
                              ? currentAssigneePhones[index]
                              : null,
                          name: assignee,
                        );
                        return ListTile(
                          leading: AppAvatar(
                            avatarUrl: avatarUrl,
                            initials: Helpers.getInitials(assignee),
                            radius: 16,
                            color: AppTheme.primaryGreen,
                            fontSize: 12,
                          ),
                          title: Text(assignee),
                          // Creator-only removal: an assignee (including the
                          // current user) must not be able to drop anyone from
                          // the task — only the creator manages the assignee
                          // list. Non-creators see a plain, action-less row.
                          trailing: _isTaskCreator()
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.remove_circle,
                                    color: Colors.red,
                                  ),
                                  onPressed: () {
                                    setDialogState(() {
                                      currentAssigneeNames.removeAt(index);
                                      // Also remove corresponding UID
                                      if (index < currentAssigneeUids.length) {
                                        currentAssigneeUids.removeAt(index);
                                      }
                                      // Also remove corresponding phone
                                      if (index <
                                          currentAssigneePhones.length) {
                                        currentAssigneePhones.removeAt(index);
                                      }
                                    });
                                  },
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  // Add assignee button — creator only, matching the Remove
                  // gating above: assignee management is the creator's prerogative.
                  if (_isTaskCreator())
                    InkWell(
                      onTap: () async {
                        if (currentAssigneeNames.length >= maxAssigneeLimit) {
                          // Show paywall dialog
                          final higherCap = PaywallLimits.maxAssignees(
                            'business',
                          );
                          showPaywallDialog(
                            context,
                            feature:
                                'Maximum $maxAssigneeLimit assignees allowed on ${PaywallLimits.planLabel(planType)} plan.',
                            detail: higherCap > maxAssigneeLimit
                                ? 'Upgrade your plan to add up to $higherCap assignees per task.'
                                : 'This is the maximum number of assignees per task on all plans.',
                          );
                          return;
                        }
                        // Show contact picker with both team members and phone contacts
                        final picker = ContactPickerService();
                        final contact = await picker.showContactPicker(context);

                        if (contact != null && mounted) {
                          setDialogState(() {
                            // Add unconditionally, then collapse by identity so a
                            // person already listed under a different name (same
                            // phone/UID) is never double-listed.
                            currentAssigneeNames.add(contact.name);
                            // Keep UID/phone lists index-aligned with names
                            // ('' placeholder when unavailable)
                            currentAssigneeUids.add(contact.uid ?? '');
                            currentAssigneePhones.add(contact.phone ?? '');
                            dedupAssignees();
                          });
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: currentAssigneeNames.length >= maxAssigneeLimit
                              ? Colors.amber.withOpacity(0.1)
                              : AppTheme.primaryGreen.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color:
                                currentAssigneeNames.length >= maxAssigneeLimit
                                ? Colors.amber.withOpacity(0.3)
                                : AppTheme.primaryGreen.withOpacity(0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add, color: AppTheme.primaryGreen),
                            SizedBox(width: 8),
                            Text(
                              'Add Assignee',
                              style: TextStyle(
                                color: AppTheme.primaryGreen,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                onPressed: () async {
                  if (currentAssigneeNames.isNotEmpty) {
                    final previousAssigneeNames =
                        _currentTask.extraFields?['participantNames'] is List
                        ? List<String>.from(
                            _currentTask.extraFields!['participantNames']
                                as List,
                          )
                        : [_currentTask.assignedTo];
                    final oldAssignees = _currentTask.isGroupTask
                        ? previousAssigneeNames
                        : [_currentTask.assignedTo];

                    // Determine who was added and removed
                    final addedAssignees = currentAssigneeNames
                        .where(
                          (a) => !oldAssignees.any(
                            (oa) => oa.toLowerCase() == a.toLowerCase(),
                          ),
                        )
                        .toList();
                    final removedAssignees = oldAssignees
                        .where(
                          (oa) => !currentAssigneeNames.any(
                            (a) => oa.toLowerCase() == a.toLowerCase(),
                          ),
                        )
                        .toList();

                    // Normalize phones for consistent Firestore dual-lookup queries
                    final normalizedPhones = currentAssigneePhones
                        .map((p) => Helpers.normalizePhone(p) ?? p)
                        .toList();

                    // Resolve missing UIDs from LOCAL sources only on the UI path:
                    // the in-memory team cache (same source the picker used), then
                    // the SQLite phone→UID cache. No blocking Firestore read here —
                    // see the loop body. Anything still unresolved is healed in the
                    // background by scheduleIdentityRepair() after the save below.
                    final db = LocalDatabaseService();
                    final cachedTeam = ContactPickerService()
                        .getCachedTeamMembers();
                    for (int i = 0; i < currentAssigneeNames.length; i++) {
                      if (i >= currentAssigneeUids.length ||
                          currentAssigneeUids[i].isEmpty) {
                        // UID is missing for this assignee, try to resolve by phone
                        if (i < normalizedPhones.length &&
                            normalizedPhones[i].isNotEmpty) {
                          final phone = normalizedPhones[i];
                          try {
                            String? resolvedUid;
                            // Cached team members first (same source the
                            // picker used — avoids phone-format mismatches)
                            if (cachedTeam != null) {
                              for (final u in cachedTeam) {
                                if (Helpers.normalizePhone(u.phone) == phone &&
                                    u.uid.isNotEmpty) {
                                  resolvedUid = u.uid;
                                  break;
                                }
                              }
                            }
                            // Check SQLite cache next
                            resolvedUid ??= await db.getCachedUid(phone);
                            if (resolvedUid != null) {
                              print(
                                '[TaskDetail] Cache hit for phone $phone: $resolvedUid',
                              );
                            }
                            // A cache miss is intentionally NOT chased with a live
                            // Firestore .get() here: that read ran serially per
                            // assignee and, for a contact who is not on the app, was
                            // re-issued on EVERY save (a miss never caches) — holding
                            // the dialog open for seconds on network latency (the
                            // "hang" on change assignee). Leave the slot blank; the
                            // post-save scheduleIdentityRepair() resolves it off the
                            // UI thread and unions the UID into participants.
                            if (resolvedUid != null) {
                              // Ensure the UIDs list is long enough
                              while (currentAssigneeUids.length <= i) {
                                currentAssigneeUids.add('');
                              }
                              currentAssigneeUids[i] = resolvedUid;
                            }
                          } catch (e) {
                            print(
                              '[TaskDetail] Error resolving UID for phone $phone: $e',
                            );
                          }
                        }
                      }
                    }

                    // Keep '' placeholders in assigneeUids so indexes stay
                    // aligned with assigneeNames/assigneePhones. Only strip
                    // empties when building the participants set below.

                    // Include creator in participants so they're always findable
                    final allParticipantUids = <String>{
                      _currentTask.createdBy, // Always include creator
                      ...currentAssigneeUids.where((uid) => uid.isNotEmpty),
                    };

                    print(
                      '[TaskDetail] Updating participants: ${allParticipantUids.toList()}',
                    );
                    print(
                      '[TaskDetail] currentAssigneeUids: $currentAssigneeUids',
                    );
                    print(
                      '[TaskDetail] currentAssigneeNames: $currentAssigneeNames',
                    );

                    final updatedTask = _currentTask.copyWith(
                      assignedTo: currentAssigneeNames.first,
                      assignedToUid: currentAssigneeUids.isNotEmpty
                          ? currentAssigneeUids.first
                          : '',
                      assignedToPhone:
                          normalizedPhones.isNotEmpty &&
                              normalizedPhones.first.isNotEmpty
                          ? normalizedPhones.first
                          : null,
                      participants: allParticipantUids.toList(),
                      isGroupTask: currentAssigneeNames.length > 1,
                      extraFields: {
                        ...?_currentTask.extraFields,
                        'assigneeUids': List<String>.from(currentAssigneeUids),
                        'participantUids': allParticipantUids.toList(),
                        'assigneeNames': List<String>.from(
                          currentAssigneeNames,
                        ),
                        'participantNames': List<String>.from(
                          currentAssigneeNames,
                        ),
                        'assigneePhones': List<String>.from(normalizedPhones),
                        if (normalizedPhones.isNotEmpty &&
                            normalizedPhones.first.isNotEmpty)
                          'assigneePhone': normalizedPhones.first,
                      },
                      updatedAt: DateTime.now(),
                    );

                    setState(() {
                      _currentTask = updatedTask;
                    });
                    Navigator.pop(ctx);

                    // Save to Firebase
                    await _updateTaskInFirebase(updatedTask);

                    // Any assignee still without a UID can't be delivered via
                    // participants — re-arm the creator-side identity repair
                    // to retry resolution from the contact book shortly.
                    if (currentAssigneeUids.any((u) => u.isEmpty)) {
                      context.read<TaskProvider>().scheduleIdentityRepair();
                    }

                    // Send system messages for assignee changes
                    final timestamp = Helpers.formatDateTime(DateTime.now());

                    // Build assignee change summary
                    final assigneeChanges = <String>[];

                    // Track removed assignees
                    for (final removedAssignee in removedAssignees) {
                      assigneeChanges.add(removedAssignee);
                    }

                    // Track added assignees
                    for (final addedAssignee in addedAssignees) {
                      assigneeChanges.add(addedAssignee);
                    }

                    // Send single consolidated message
                    if (assigneeChanges.isNotEmpty) {
                      final totalAssignees = currentAssigneeNames.length;
                      final assigneeCountText = totalAssignees == 1
                          ? '1 assignee'
                          : '$totalAssignees assignees';

                      String changeMsg;
                      if (removedAssignees.isNotEmpty &&
                          addedAssignees.isNotEmpty) {
                        // Both removed and added
                        changeMsg =
                            '👤 Assignee Updated: Removed ${removedAssignees.join(', ')}; Added ${addedAssignees.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                      } else if (removedAssignees.isNotEmpty) {
                        // Only removed
                        changeMsg =
                            '👤 Assignee Removed: ${removedAssignees.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                      } else {
                        // Only added
                        changeMsg =
                            '👤 Assignee Added: ${addedAssignees.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                      }

                      await _sendSystemMessage(changeMsg);
                    }

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            currentAssigneeNames.length > 1
                                ? '${currentAssigneeNames.length} assignees updated'
                                : 'Assignee: ${currentAssigneeNames.first}',
                          ),
                          duration: const Duration(seconds: 2),
                          backgroundColor: AppTheme.primaryGreen,
                        ),
                      );
                    }
                  } else {
                    // The assignee list is now empty — the last/only assignee
                    // was removed. Previously the whole Save path was gated on
                    // a non-empty list, so unassigning everyone was a silent
                    // no-op. Flip the card to a genuine "Unassigned" state for
                    // the creator: blank the assignee (name/uid/phone), keep
                    // only the creator in participants, clear the assignee
                    // identity fields and post a system message. `clearAssignee`
                    // tells the Firestore write path to let the emptied fields
                    // through instead of reverting them to the stored assignee.
                    final previousNames = _currentTask.isGroupTask
                        ? (_currentTask.extraFields?['assigneeNames'] is List
                              ? List<String>.from(
                                  _currentTask.extraFields!['assigneeNames']
                                      as List,
                                )
                              : <String>[_currentTask.assignedTo])
                        : <String>[_currentTask.assignedTo];
                    final removedText = previousNames
                        .where((n) => n.trim().isNotEmpty)
                        .join(', ');

                    final updatedTask = _currentTask.copyWith(
                      assignedTo: '',
                      assignedToUid: '',
                      clearAssigneePhone: true,
                      participants: [_currentTask.createdBy],
                      isGroupTask: false,
                      extraFields: {
                        ...?_currentTask.extraFields,
                        'assigneeUids': <String>[],
                        'participantUids': [_currentTask.createdBy],
                        'assigneeNames': <String>[],
                        'participantNames': <String>[],
                        'assigneePhones': <String>[],
                        'assigneePhone': '',
                      },
                      updatedAt: DateTime.now(),
                    );

                    setState(() {
                      _currentTask = updatedTask;
                    });
                    Navigator.pop(ctx);

                    await _updateTaskInFirebase(
                      updatedTask,
                      clearAssignee: true,
                    );

                    final timestamp = Helpers.formatDateTime(DateTime.now());
                    final changeMsg =
                        '👤 Assignee Removed: ${removedText.isEmpty ? 'all assignees' : removedText}, Assignee = Unassigned by $_currentUserName at $timestamp';
                    await _sendSystemMessage(changeMsg);

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Task is now Unassigned'),
                          duration: Duration(seconds: 2),
                          backgroundColor: AppTheme.primaryGreen,
                        ),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Inline milestone checklist (expanded under the Milestones row) ──

  /// Checklist shown when the Milestones row is expanded. Tap a row to
  /// complete/reopen it immediately (progress recalculates automatically).
  Widget _buildMilestoneChecklistInline() {
    final milestones = _currentTask.milestones;
    if (milestones.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: GestureDetector(
          onTap: () => _showMilestonesDialog(),
          child: Text(
            'No milestones — tap the pencil to add',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: AppTheme.lightText.withOpacity(0.8),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: milestones.map((m) => _buildMilestoneTileInline(m)).toList(),
      ),
    );
  }

  Widget _buildMilestoneTileInline(MilestoneModel milestone) {
    return InkWell(
      onTap: () => _toggleMilestoneInline(milestone),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            Icon(
              milestone.isCompleted
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: milestone.isCompleted
                  ? const Color(0xFF2F9E44)
                  : AppTheme.lightText,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                milestone.title,
                style: TextStyle(
                  fontSize: 13,
                  decoration: milestone.isCompleted
                      ? TextDecoration.lineThrough
                      : null,
                  color: milestone.isCompleted
                      ? AppTheme.lightText
                      : AppTheme.primaryText,
                ),
              ),
            ),
            if (milestone.completedAt != null)
              Text(
                DateFormat('MMM d, HH:mm').format(milestone.completedAt!),
                style: const TextStyle(fontSize: 10, color: AppTheme.lightText),
              ),
          ],
        ),
      ),
    );
  }

  /// Toggle a milestone complete/reopen from the inline checklist — saves
  /// immediately, recalculates progress and logs a system message.
  Future<void> _toggleMilestoneInline(MilestoneModel milestone) async {
    final nowCompleted = !milestone.isCompleted;
    final milestones = _currentTask.milestones
        .map(
          (m) => m.id == milestone.id
              ? MilestoneModel(
                  id: m.id,
                  title: m.title,
                  order: m.order,
                  isCompleted: nowCompleted,
                  completedAt: nowCompleted ? DateTime.now() : null,
                  createdAt: m.createdAt,
                  deadline: m.deadline,
                )
              : m,
        )
        .toList();
    final completedCount = milestones.where((m) => m.isCompleted).length;
    final totalCount = milestones.length;
    final newProgress = totalCount > 0
        ? completedCount / totalCount
        : _currentTask.progress;

    final updatedTask = _currentTask.copyWith(
      milestones: milestones,
      progress: newProgress,
      updatedAt: DateTime.now(),
    );
    setState(() {
      _currentTask = updatedTask;
    });
    _updateTaskInFirebase(updatedTask);

    final timestamp = Helpers.formatDateTime(DateTime.now());
    await _sendSystemMessage(
      '🏁 Milestone ${nowCompleted ? 'completed' : 'reopened'}: "${milestone.title}" by $_currentUserName at $timestamp',
    );
  }

  // Show milestones dialog
  Future<void> _showMilestonesDialog() async {
    final milestones = List<MilestoneModel>.from(_currentTask.milestones);

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final completedCount = milestones.where((m) => m.isCompleted).length;
          final totalCount = milestones.length;

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.flag, color: Color(0xFF9C27B0)),
                SizedBox(width: 8),
                Text('Milestones'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$completedCount/$totalCount completed',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Tap a milestone to mark it complete — task progress updates automatically. Tap again to reopen.',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: AppTheme.lightText.withOpacity(0.9),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (milestones.isNotEmpty)
                    ...milestones.asMap().entries.map((entry) {
                      final index = entry.key;
                      final milestone = entry.value;
                      return InkWell(
                        onTap: () {
                          setDialogState(() {
                            milestones[index] = milestone.copyWith(
                              isCompleted: !milestone.isCompleted,
                              completedAt: !milestone.isCompleted
                                  ? DateTime.now()
                                  : null,
                            );
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                milestone.isCompleted
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: milestone.isCompleted
                                    ? const Color(0xFF2F9E44)
                                    : AppTheme.lightText,
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  milestone.title,
                                  style: TextStyle(
                                    fontSize: 14,
                                    decoration: milestone.isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: milestone.isCompleted
                                        ? AppTheme.lightText
                                        : AppTheme.primaryText,
                                  ),
                                ),
                              ),
                              if (milestone.completedAt != null)
                                Text(
                                  DateFormat(
                                    'MMM d, HH:mm',
                                  ).format(milestone.completedAt!),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.lightText,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  const SizedBox(height: 12),
                  if (milestones.length < 5)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final controller = TextEditingController();
                          showDialog(
                            context: ctx,
                            builder: (ctx2) => AlertDialog(
                              title: const Text('Add Milestone'),
                              content: TextField(
                                controller: controller,
                                maxLength: 100,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                  labelText: 'Milestone Title',
                                  hintText: 'e.g., Design Complete',
                                  counterText: '',
                                ),
                                autofocus: true,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx2),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    final title = controller.text.trim();
                                    if (title.isNotEmpty) {
                                      setDialogState(() {
                                        milestones.add(
                                          MilestoneModel(
                                            id: DateTime.now()
                                                .millisecondsSinceEpoch
                                                .toString(),
                                            title: title,
                                            createdAt: DateTime.now(),
                                          ),
                                        );
                                      });
                                    }
                                    Navigator.pop(ctx2);
                                  },
                                  child: const Text('Add'),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add Milestone'),
                      ),
                    ),
                  if (milestones.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setDialogState(() {
                              milestones.removeLast();
                            });
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Delete Last Milestone'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  // Capture old milestones before updating so chat/log entries can show details.
                  final oldMilestones = List<MilestoneModel>.from(
                    _currentTask.milestones,
                  );
                  final oldCompletedCount = oldMilestones
                      .where((m) => m.isCompleted)
                      .length;
                  final oldTotalCount = oldMilestones.length;
                  final oldProgressValue = _currentTask.progress;

                  Navigator.pop(ctx);

                  final completedCount = milestones
                      .where((m) => m.isCompleted)
                      .length;
                  final totalCount = milestones.length;
                  double newProgress = _currentTask.progress;
                  if (totalCount > 0) {
                    newProgress = (completedCount / totalCount);
                  }

                  final updatedTask = _currentTask.copyWith(
                    milestones: milestones,
                    progress: newProgress,
                    updatedAt: DateTime.now(),
                  );

                  setState(() {
                    _currentTask = updatedTask;
                  });

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Milestones saved: $completedCount/$totalCount completed',
                        ),
                        duration: const Duration(seconds: 2),
                        backgroundColor: const Color(0xFF9C27B0),
                      ),
                    );
                  }

                  _updateTaskInFirebase(updatedTask);

                  final timestamp = Helpers.formatDateTime(DateTime.now());
                  final addedMilestones = milestones
                      .where(
                        (milestone) => !oldMilestones.any(
                          (oldMilestone) => oldMilestone.id == milestone.id,
                        ),
                      )
                      .toList();
                  final removedMilestones = oldMilestones
                      .where(
                        (oldMilestone) => !milestones.any(
                          (milestone) => milestone.id == oldMilestone.id,
                        ),
                      )
                      .toList();
                  final statusChangedMilestones = milestones.where((milestone) {
                    final oldMatches = oldMilestones.where(
                      (oldMilestone) => oldMilestone.id == milestone.id,
                    );
                    if (oldMatches.isEmpty) return false;
                    return oldMatches.first.isCompleted !=
                        milestone.isCompleted;
                  }).toList();

                  for (final entry in addedMilestones.asMap().entries) {
                    await _sendSystemMessage(
                      '🏁 Milestone ${entry.key + 1} added: "${entry.value.title}" by $_currentUserName at $timestamp',
                    );
                  }

                  for (final entry in removedMilestones.asMap().entries) {
                    await _sendSystemMessage(
                      '🏁 Milestone ${entry.key + 1} removed: "${entry.value.title}" by $_currentUserName at $timestamp',
                    );
                  }

                  for (final milestone in statusChangedMilestones) {
                    await _sendSystemMessage(
                      '🏁 Milestone ${milestone.isCompleted ? 'completed' : 'reopened'}: "${milestone.title}" by $_currentUserName at $timestamp',
                    );
                  }

                  if (milestones.length != oldTotalCount ||
                      completedCount != oldCompletedCount) {
                    // Calculate old and new progress percentages
                    final oldProgressPercent = oldTotalCount > 0
                        ? ((oldCompletedCount / oldTotalCount) * 100).round()
                        : (oldProgressValue * 100).round();
                    final newProgressPercent = (newProgress * 100).round();

                    // Send progress change message if progress actually changed
                    if (oldProgressPercent != newProgressPercent) {
                      await _sendSystemMessage(
                        '📊 Progress updated: $oldProgressPercent% → $newProgressPercent% by $_currentUserName at $timestamp',
                      );
                    }
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9C27B0),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _buildMilestoneSummary() {
    final milestones = _currentTask.milestones;
    if (milestones.isEmpty) {
      return 'No milestones set';
    }
    final completedCount = milestones.where((m) => m.isCompleted).length;
    final totalCount = milestones.length;
    return '$completedCount/$totalCount completed';
  }

  // Inline edit title
  void _editTitleInline() {
    print('[TaskDetail] _editTitleInline called');
    final oldTitle = _currentTask.title; // Capture old title
    final controller = TextEditingController(text: oldTitle);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Title'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Enter task title...',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newTitle = controller.text.trim();
              Navigator.pop(ctx);
              if (newTitle.isNotEmpty && newTitle != oldTitle) {
                // Use copyWith to preserve ALL fields
                final updatedTask = _currentTask.copyWith(
                  title: newTitle,
                  updatedAt: DateTime.now(),
                );

                setState(() {
                  _currentTask = updatedTask;
                });

                // Update Firebase after closing the dialog
                await _updateTaskInFirebase(updatedTask);

                // Send system message with old and new title
                final timestamp = Helpers.formatDateTime(DateTime.now());
                await _sendSystemMessage(
                  '✏️ Title updated: "$oldTitle" → "$newTitle" by $_currentUserName at $timestamp',
                );

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Title updated'),
                      duration: Duration(seconds: 2),
                      backgroundColor: AppTheme.primaryGreen,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // Inline edit description
  void _editDescriptionInline() {
    print('[TaskDetail] _editDescriptionInline called');
    final oldDescription = _currentTask.description; // Capture old description
    final controller = TextEditingController(text: oldDescription);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Description'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 1000,
          textCapitalization: TextCapitalization.sentences,
          maxLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Enter task description...',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newDescription = controller.text.trim();
              Navigator.pop(ctx);
              if (newDescription != oldDescription) {
                // Use copyWith to preserve ALL fields
                final updatedTask = _currentTask.copyWith(
                  description: newDescription,
                  updatedAt: DateTime.now(),
                );

                setState(() {
                  _currentTask = updatedTask;
                });

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Description updated'),
                    duration: Duration(seconds: 2),
                    backgroundColor: AppTheme.primaryGreen,
                  ),
                );

                _updateTaskInFirebase(updatedTask);

                // Send system message with old and new values
                final oldDesc = oldDescription.isNotEmpty
                    ? oldDescription
                    : '(empty)';
                final newDesc = newDescription.isNotEmpty
                    ? newDescription
                    : '(empty)';
                final timestamp = Helpers.formatDateTime(DateTime.now());
                _sendSystemMessage(
                  '✏️ Description updated: "$oldDesc" → "$newDesc" by $_currentUserName at $timestamp',
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // Edit start date (only for draft/scheduled tasks)
  Future<void> _editStartDate() async {
    final status = _getTaskStatus();
    if (status != 'Draft' && status != 'Scheduled') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Start date can only be changed before task is activated',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _currentTask.startDate ?? _currentTask.createdAt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _currentTask.startDate ?? _currentTask.createdAt,
      ),
    );

    if (!mounted) return;

    final newStartDate = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? 9,
      pickedTime?.minute ?? 0,
    );

    final oldStartDate = _currentTask.startDate ?? _currentTask.createdAt;
    final updatedTask = _currentTask.copyWith(
      startDate: newStartDate,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _currentTask = updatedTask;
    });

    _updateTaskInFirebase(updatedTask);

    // Send system message with old and new start date values
    _sendSystemMessage(
      '📆 Start date updated: ${Helpers.formatDateTime(oldStartDate)} → ${Helpers.formatDateTime(newStartDate)} by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Start date updated: ${Helpers.formatDateTime(newStartDate)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Inline edit deadline
  Future<void> _editDeadlineInline() async {
    print('[TaskDetail] _editDeadlineInline called');
    // Only the task creator can change the deadline — assignees get a hint.
    if (!_isTaskCreator()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the task creator can change the deadline'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    // One dialog for date + repeat (see showDeadlinePicker): the repeat rule is
    // a dropdown defaulting to "Does not repeat", so editing a deadline no
    // longer pops a second dialog. Cancelling keeps the existing values.
    final picked = await showDeadlinePicker(
      context,
      initialDate:
          _currentTask.deadline ?? DateTime.now().add(const Duration(days: 7)),
      initialRule: _currentTask.recurrenceRule,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked == null || !mounted) return;

    // Date-only: set to end-of-day (23:59) for proper day calculation
    final finalDateTime = DateTime(
      picked.date.year,
      picked.date.month,
      picked.date.day,
      23,
      59,
    );

    final oldDeadline = _currentTask.deadline != null
        ? Helpers.formatDate(_currentTask.deadline!) // Date-only format
        : 'No deadline';

    // Recurrence BEFORE the edit — captured now because _currentTask is
    // reassigned to the updated task (and setState'd) further down. Comparing
    // it with the picked rule lets the system message state the repeat change
    // explicitly instead of only "Deadline updated: X → X".
    final oldRule = _currentTask.recurrenceRule;

    // The legacy extraFields['recurrence'] key is always dropped on edit — the
    // dedicated column is now the single source of truth.
    final updatedExtra = Map<String, dynamic>.from(
      _currentTask.extraFields ?? {},
    )..remove('recurrence');

    // Time-driven recurrence (Phase-2B): a chosen rule re-anchors the series at
    // the new deadline. A task with no series yet becomes the ANCHOR (seriesId =
    // its own id, nextDue = first occurrence after the deadline); an existing
    // series keeps its id. "Does not repeat" (rule == null) clears the trio and
    // ends the series. The shared materializer generates occurrences from here.
    final rule = picked.rule;
    final TaskModel updatedTask;
    if (rule == null) {
      updatedTask = _currentTask.copyWith(
        deadline: finalDateTime,
        extraFields: updatedExtra,
        updatedAt: DateTime.now(),
        clearRecurrence: true,
      );
    } else {
      updatedTask = _currentTask.copyWith(
        deadline: finalDateTime,
        extraFields: updatedExtra,
        recurrence: rule.toJson(),
        seriesId: _currentTask.seriesId ?? _currentTask.id,
        nextDue: rule.nextOccurrenceAfter(finalDateTime),
        updatedAt: DateTime.now(),
      );
    }

    setState(() {
      _currentTask = updatedTask;
    });

    _updateTaskInFirebase(updatedTask);

    // Send system message reflecting BOTH the date move and the repeat
    // change, so switching a recurring task to one-time (or vice-versa) reads
    // clearly instead of a bare "Deadline updated: X → X".
    final newDeadline = Helpers.formatDate(finalDateTime); // Date-only format
    final dateChanged = oldDeadline != newDeadline;
    String recNote;
    if (rule != null && oldRule == null) {
      recNote = 'Repeat added · ${rule.label}';
    } else if (rule != null && oldRule != null && rule.label != oldRule.label) {
      recNote = 'Repeat changed · ${oldRule.label} to ${rule.label}';
    } else if (rule != null) {
      // Rule kept, only the date moved — just name the cadence.
      recNote = rule.label;
    } else if (oldRule != null) {
      recNote = 'Repeat removed · Now one-time';
    } else {
      recNote = '';
    }

    if (dateChanged || recNote.isNotEmpty) {
      final core = dateChanged
          ? 'Deadline updated: $oldDeadline → $newDeadline'
          : 'Deadline updated: $newDeadline';
      final tail = recNote.isNotEmpty ? ' · $recNote' : '';
      _sendSystemMessage(
        '📅 $core$tail by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deadline updated: ${Helpers.formatDate(finalDateTime)}',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  // Send system message optimistically, then sync to Firebase.
  // [attachment] follows the Sales action-card flow: the card posts as ONE
  // message with fileUrl='pending', then the local-first upload pipeline
  // patches the real URL back onto the same message id.
  Future<void> _sendSystemMessage(
    String text, {
    SystemMessageType systemType = SystemMessageType.regular,
    DateTime? scheduledAt,
    PickedChatAttachment? attachment,
    int? sequenceNumber,
    String? referenceMessageId,
  }) async {
    final systemMsg = MessageModel(
      id: Helpers.generateId(),
      taskId: _currentTask.id,
      senderId: _currentUserId, // Use actual user ID instead of 'system'
      text: text,
      type: MessageType.system,
      systemType: systemType,
      sequenceNumber: sequenceNumber,
      scheduledAt: scheduledAt,
      createdAt: DateTime.now(),
      deliveryMethod: 'in-app',
      fileUrl: attachment != null ? 'pending' : null,
      fileName: attachment?.name,
      // Response-action notifications (Done / Reply / Resolve) carry a pointer
      // to the action card they refer to so tapping the notification jumps back
      // to it. Reusing replyToMessageId (already persisted in Firestore + SQLite
      // and never set on system cards otherwise) avoids a schema change.
      replyToMessageId: referenceMessageId,
    );

    if (mounted) {
      setState(() {
        _messages.add(systemMsg);
        _allMessages.add(systemMsg);
        _rebuildDisplayMessages();
      });
      // Don't auto-scroll on edit/action messages - user can tap the down arrow to see them
    }

    _saveMessageToFirebase(systemMsg, scroll: false);
    if (attachment != null) {
      chatAttachToExistingMessage(systemMsg, attachment);
    }
    print('[TaskDetail] System message saved: $text');
  }

  // Edit progress inline
  Future<void> _editProgressInline() async {
    final currentProgress = (_currentTask.progress * 100).toInt();
    double sliderValue = currentProgress.toDouble();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Row(
            children: [
              Icon(Icons.trending_up, color: AppTheme.primaryGreen),
              SizedBox(width: 8),
              Text('Update Progress'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${sliderValue.toInt()}%',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryGreen,
                ),
              ),
              const SizedBox(height: 16),
              Slider(
                value: sliderValue,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${sliderValue.toInt()}%',
                activeColor: AppTheme.primaryGreen,
                onChanged: (value) {
                  setDialogState(() {
                    sliderValue = value;
                  });
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        sliderValue = 0;
                      });
                    },
                    child: const Text('0%'),
                  ),
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        sliderValue = 25;
                      });
                    },
                    child: const Text('25%'),
                  ),
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        sliderValue = 50;
                      });
                    },
                    child: const Text('50%'),
                  ),
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        sliderValue = 75;
                      });
                    },
                    child: const Text('75%'),
                  ),
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        sliderValue = 100;
                      });
                    },
                    child: const Text('100%'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newProgress = (sliderValue / 100).toDouble();
                Navigator.pop(ctx);

                final updatedTask = _currentTask.copyWith(
                  progress: newProgress,
                  updatedAt: DateTime.now(),
                );

                setState(() {
                  _currentTask = updatedTask;
                });

                // Persist to Firebase
                await _updateTaskInFirebase(updatedTask);

                // Send system message for progress change — only when it
                // actually moved (no 0% → 0% / same-value noise in the chat).
                final timestamp = Helpers.formatDateTime(DateTime.now());
                final oldProgress = (currentProgress.toInt());
                final newProgressPercent = (newProgress * 100).toInt();
                if (oldProgress != newProgressPercent) {
                  await _sendSystemMessage(
                    'Progress updated: ${oldProgress}% → ${newProgressPercent}% by $_currentUserName at $timestamp',
                  );
                }

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Progress updated to $newProgressPercent%'),
                      duration: const Duration(seconds: 2),
                      backgroundColor: AppTheme.primaryGreen,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    );
  }

  // Build urgency chip
  /// Current urgency state: Blocked (isBlocked) wins, else
  /// extraFields['urgencyState'], else legacy isUrgent → 'urgent'/'none'.
  String _urgencyStateOf(TaskModel t) {
    if (t.extraFields?['isBlocked'] == true) return 'blocked';
    final s = t.extraFields?['urgencyState'];
    if (s == 'attention' || s == 'urgent' || s == 'none') return s as String;
    return t.isUrgent ? 'urgent' : 'none';
  }

  String _urgencyLabel(String s) {
    if (s == 'attention') return 'Needs Attention';
    if (s == 'urgent') return 'Urgent';
    if (s == 'blocked') return 'Blocked';
    return 'None';
  }

  IconData _urgencyIcon(String s) {
    if (s == 'attention') return Icons.error_outline;
    if (s == 'urgent') return Icons.local_fire_department;
    if (s == 'blocked') return Icons.block;
    return Icons.circle_outlined;
  }

  Color _urgencyColor(String s) {
    if (s == 'attention') return AppTheme.warning;
    if (s == 'urgent') return AppTheme.destructive;
    if (s == 'blocked') return AppTheme.blocked;
    return AppTheme.tertiaryLabel;
  }

  /// Persist a new urgency state. Blocked unifies with extraFields['isBlocked']
  /// (the formal blocker flag); 'urgent' keeps isUrgent in sync for legacy
  /// filters/badges; any other state clears both.
  /// Names of the user-defined header fields (Settings → Custom fields);
  /// blank name = that field is hidden everywhere.
  List<String> _customFieldLabels = const ['', '', ''];

  Future<void> _applyUrgencyState(String state) async {
    final oldState = _urgencyStateOf(_currentTask);
    Navigator.pop(context);
    if (oldState == state) return;
    final extra = Map<String, dynamic>.from(_currentTask.extraFields ?? {});
    extra['urgencyState'] = state;
    if (state == 'blocked') {
      extra['isBlocked'] = true;
    } else {
      extra.remove('isBlocked');
    }
    final updatedTask = _currentTask.copyWith(
      isUrgent: state == 'urgent',
      extraFields: extra,
      updatedAt: DateTime.now(),
    );
    setState(() {
      _currentTask = updatedTask;
    });
    await _updateTaskInFirebase(updatedTask);
    await _sendSystemMessage(
      '🔥 Urgency changed: ${_urgencyLabel(oldState)} → ${_urgencyLabel(state)} by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Urgency: ${_urgencyLabel(state)}'),
          duration: const Duration(seconds: 2),
          backgroundColor: _urgencyColor(state),
        ),
      );
    }
  }

  /// Load the two user-defined field names (Settings → Custom fields).
  Future<void> _loadCustomFieldLabels() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _customFieldLabels = [
        prefs.getString('customFieldLabel1') ?? '',
        prefs.getString('customFieldLabel2') ?? '',
        prefs.getString('customFieldLabel3') ?? '',
      ];
    });
  }

  /// One By/To line for the AppBar subtitle: plain 'Me' for the current
  /// user (never the cryptic "M (Me)"), always the full name — the
  /// initials variant was dropped.
  String _participantLine(String role, String name, {bool forceMe = false}) {
    if (forceMe || name.trim().toLowerCase() == 'me') return '$role Me';
    if (name.trim().isEmpty) return '$role Unknown';
    return '$role $name';
  }

  /// The two user-named extra fields as tappable chips (empty value shows
  /// a "+ Name" placeholder; unnamed fields are hidden entirely).
  List<Widget> _buildCustomFieldChips() {
    final chips = <Widget>[];
    for (int slot = 1; slot <= 3; slot++) {
      final label = _customFieldLabels[slot - 1].trim();
      if (label.isEmpty) continue;
      final value =
          (_currentTask.extraFields?['customField$slot'] as String? ?? '')
              .trim();
      chips.add(const SizedBox(height: 6));
      chips.add(
        GestureDetector(
          onTap: () => _editCustomField(slot),
          child: value.isEmpty
              ? Text(
                  '+ $label',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                )
              // Capped width so a long value wraps inside the chip (up to
              // 4 lines) instead of stretching or overflowing the header.
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.lightText.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$label: ${value.replaceAll('\n', ' ')}',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                  ),
                ),
        ),
      );
    }
    return chips;
  }

  /// Tap-to-edit one custom field value; stored in extraFields so both
  /// sides of the task see it after sync.
  Future<void> _editCustomField(int slot) async {
    final label = _customFieldLabels[slot - 1].trim();
    if (label.isEmpty) return;
    final current =
        (_currentTask.extraFields?['customField$slot'] as String? ?? '');
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          // Multi-line entry: long text wraps onto the next line instead of
          // scrolling on a single line.
          minLines: 1,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onEditingComplete: () => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final extra = Map<String, dynamic>.from(_currentTask.extraFields ?? {});
    if (result.trim().isEmpty) {
      extra.remove('customField$slot');
    } else {
      extra['customField$slot'] = result.trim();
    }
    final updatedTask = _currentTask.copyWith(
      extraFields: extra,
      updatedAt: DateTime.now(),
    );
    setState(() {
      _currentTask = updatedTask;
    });
    await _updateTaskInFirebase(updatedTask);
  }

  /// Urgency badge with the two user-named custom fields stacked under it
  /// (names from Settings; values live in extraFields per task).
  Widget _buildUrgencyAndCustomFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _showPriorityUrgencyMenu(),
          child: Builder(
            builder: (context) {
              final uState = _urgencyStateOf(_currentTask);
              final uColor = _urgencyColor(uState);
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: uState == 'none'
                      ? AppTheme.separator.withOpacity(0.6)
                      : uColor.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_urgencyIcon(uState), size: 14, color: uColor),
                    const SizedBox(width: 4),
                    Text(
                      uState == 'none' ? 'Urgency' : _urgencyLabel(uState),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: uColor,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        ..._buildCustomFieldChips(),
      ],
    );
  }

  /// One tappable urgency option inside the chooser sheet.
  Widget _urgencyOption(String state) {
    final isSelected = _urgencyStateOf(_currentTask) == state;
    final color = _urgencyColor(state);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _applyUrgencyState(state),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(isSelected ? 0.18 : 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? color : color.withOpacity(0.25),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(_urgencyIcon(state), size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _urgencyLabel(state),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (isSelected) Icon(Icons.check, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }

  // ── Cross-module linking (Task ↔ Task/Sales/CRM) ──────────────────

  /// This task as one side of a link.
  LinkRef get _selfLinkRef => LinkRef(
    module: 'task',
    id: _currentTask.id,
    title: _currentTask.title,
    displayId: _currentTask.displayId,
  );

  /// Re-read this task from the provider cache / SQLite after a link
  /// mutation so the chips (and the open details sheet) refresh.
  Future<void> _refreshCurrentTask() async {
    TaskModel? fresh;
    try {
      fresh = context
          .read<TaskProvider>()
          .allTasks
          .where((t) => t.id == _currentTask.id)
          .firstOrNull;
    } catch (_) {}
    fresh ??= await LocalDatabaseService().getTaskById(_currentTask.id);
    if (fresh != null && mounted) {
      setState(() => _currentTask = fresh!);
      _cardSheetVersion.value++;
    }
  }

  Future<void> _openLinkPicker() async {
    final links = ItemLinksService().linksOf(_currentTask.extraFields);
    final created = await showLinkPickerSheet(
      context,
      source: _selfLinkRef,
      sourceLinks: links,
    );
    if (created) await _refreshCurrentTask();
  }

  Future<void> _confirmRemoveLink(Map<String, dynamic> link) async {
    final target = LinkRef(
      module: link['module'] as String? ?? 'task',
      id: link['id'] as String? ?? '',
      title: link['title'] as String? ?? '',
      displayId: link['displayId'] as int?,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove link?'),
        content: Text(
          'Unlink ${target.moduleLabel} ${target.label} from this task on both sides.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ItemLinksService().unlink(
      context,
      source: _selfLinkRef,
      target: target,
    );
    await _refreshCurrentTask();
  }

  /// Compact inline "Customer Name" row inside the details card (Sales-module
  /// parity): person icon + name (or italic placeholder) + edit/add affordance;
  /// tapping opens the shared 5-field editor. Replaces the old collapsible
  /// CustomerCardSection — Call / WhatsApp / Copy / Save still live on the list
  /// card, so the detail card stays a single clean line like Sales.
  Widget _buildCustomerSection() {
    final info = _currentTask.customerInfo;
    final hasName = info.hasName;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _editCustomerInline,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.person_outline,
              size: 14,
              color: AppTheme.headerGreen.withOpacity(0.7),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                hasName ? info.name : 'Customer Name',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: hasName ? FontWeight.w500 : FontWeight.normal,
                  color: hasName
                      ? AppTheme.primaryText
                      : AppTheme.lightText.withOpacity(0.6),
                  fontStyle: hasName ? FontStyle.normal : FontStyle.italic,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              hasName ? Icons.edit : Icons.add,
              size: 12,
              color: AppTheme.lightText,
            ),
          ],
        ),
      ),
    );
  }

  /// Open the shared 5-field [CustomerEditDialog], persist through the same
  /// SQLite-first path as every other inline edit (`_updateTaskInFirebase` →
  /// `TaskProvider.updateTask`), and log a plain (non-action) "Customer …
  /// updated" system message. Mirrors the sales/CRM customer editor.
  /// Distinct customers already used across this user's tasks (name non-empty,
  /// de-duplicated by name, sorted) — feeds the edit dialog's "reuse a saved
  /// customer" picker (per-module parity with Sales).
  List<CustomerInfo> _savedTaskCustomers() {
    final byName = <String, CustomerInfo>{};
    for (final t in context.read<TaskProvider>().allTasks) {
      final info = t.customerInfo;
      if (!info.hasName) continue;
      byName.putIfAbsent(info.name.trim().toLowerCase(), () => info);
    }
    final list = byName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  void _editCustomerInline() async {
    final old = _currentTask.customerInfo;
    final next = await CustomerEditDialog.show(
      context,
      initial: old,
      accentColor: AppTheme.headerGreen,
      existingCustomers: _savedTaskCustomers(),
    );
    if (next == null || next == old || !mounted) return;

    final updatedTask = _currentTask
        .withCustomerInfo(next)
        .copyWith(updatedAt: DateTime.now());
    setState(() => _currentTask = updatedTask);
    await _updateTaskInFirebase(updatedTask);

    final changed = <String>[
      if (old.name != next.name) 'name',
      if (old.phone != next.phone) 'phone',
      if (old.email != next.email) 'email',
      if (old.company != next.company) 'company',
      if (old.address != next.address) 'address',
    ];
    final fields = changed.isEmpty ? 'details' : changed.join(', ');
    final timestamp = Helpers.formatDateTime(DateTime.now());
    await _sendSystemMessage(
      '👤 Customer $fields updated by $_currentUserName at $timestamp',
    );
  }

  // Swipe-reveal: show the task details card as a bottom sheet so the user
  // doesn't have to scroll up through the chat to see it.
  Future<void> _openTaskCardSheet() async {
    if (_taskCardSheetOpen) return;
    _taskCardSheetOpen = true;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.75,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppTheme.lightText.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Flexible(
              child: ValueListenableBuilder<int>(
                valueListenable: _cardSheetVersion,
                builder: (context, _, _) =>
                    SingleChildScrollView(child: _buildTaskDetailsCard()),
              ),
            ),
          ],
        ),
      ),
    );
    _taskCardSheetOpen = false;
  }

  // Build task details card shown at top of chat
  Widget _buildTaskDetailsCard() {
    final Widget card = Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primaryGreen.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Draft hint caption
            if (_currentTask.extraFields?['isDraft'] == true) ...[
              Row(
                children: [
                  Icon(
                    Icons.keyboard_alt,
                    size: 12,
                    color: AppTheme.headerGreen,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Type your task in the message box below',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.headerGreen,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],

            // Display ID (small grey text)
            if (_currentTask.displayId != null) ...[
              Text(
                '#${_currentTask.displayId}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.lightText.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
            ],

            // Header: Task title + Description + Urgency badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title - CLICKABLE TO EDIT
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _editTitleInline(),
                              child: Text(
                                _currentTask.title.isEmpty
                                    ? 'Enter Task Title'
                                    : _currentTask.title,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _currentTask.title.isEmpty
                                      ? AppTheme.lightText.withOpacity(0.6)
                                      : AppTheme.primaryText,
                                  fontStyle: _currentTask.title.isEmpty
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                  height: 1.3,
                                  decoration: TextDecoration.underline,
                                  decorationColor: AppTheme.primaryGreen
                                      .withOpacity(0.3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Description - CLICKABLE TO EDIT
                      if (_currentTask.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _editDescriptionInline(),
                                child: Text(
                                  _currentTask.description,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.secondaryText,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _editDescriptionInline(),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Description',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.secondaryText.withOpacity(
                                      0.5,
                                    ),
                                    fontStyle: FontStyle.italic,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.add,
                                size: 14,
                                color: AppTheme.secondaryText,
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Status chip - clickable (creator only for status changes)
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () => _editTaskStatus(),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _getStatusColor().withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _getStatusColor().withOpacity(0.3),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _getStatusIcon(),
                                size: 14,
                                color: _getStatusColor(),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _getTaskStatus(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _getStatusColor(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Category chip
                      if (_currentTask.category != null &&
                          _currentTask.category!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () => _showCategoryPicker(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryGreen.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppTheme.primaryGreen.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.label_outline,
                                  size: 12,
                                  color: AppTheme.primaryGreen,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _currentTask.category!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.primaryGreen,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () => _showCategoryPicker(),
                          child: Text(
                            '+ Category',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.lightText,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Urgency badge + the two user-named custom fields below.
                _buildUrgencyAndCustomFields(),
              ],
            ),

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // People: Creator (show actual name) + Assignee (clickable)
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showContactInfo(
                      name: _getUserNameById(_currentTask.createdBy),
                      phone: _currentTask.createdByPhone,
                      label: 'Created By',
                    ),
                    child: PersonCard(
                      icon: Icons.person_outline,
                      label: 'Created By',
                      name: _getUserNameById(_currentTask.createdBy),
                      color: AppTheme.headerGreen,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => _manageAssignees(),
                    onLongPress: () => _showContactInfo(
                      name: _currentTask.assignedTo,
                      phone: _currentTask.assignedToPhone,
                      label: 'Assignee',
                    ),
                    child: _buildAssigneeCard(
                      'Assignee',
                      AppTheme.primaryGreen,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Customer: shared read-only section + Call/WhatsApp/Copy/Save
            // actions; the edit icon (or "Add customer") opens the 5-field
            // editor. Renders byte-identical to before when no customer is set.
            _buildCustomerSection(),

            const SizedBox(height: 12),

            // Dates: Start Date + Deadline with days info
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _editStartDate(),
                    child: DateCard(
                      icon: Icons.event,
                      label: 'Start Date',
                      date: Helpers.formatDate(
                        _currentTask.startDate ?? _currentTask.createdAt,
                      ),
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _editDeadlineInline(),
                    child: Builder(
                      builder: (context) {
                        if (_currentTask.deadline == null) {
                          return DateCard(
                            label: 'Deadline',
                            date: 'ΓÇö',
                            color: AppTheme.secondaryText,
                          );
                        }
                        // Shared 3-color timing (card_widgets).
                        final deadlineColor = deadlineColorFor(
                          _currentTask.createdAt,
                          _currentTask.deadline,
                          isClosed: _currentTask.isClosed ||
                              _currentTask.isCancelled,
                        );
                        final recShort =
                            _currentTask.recurrenceRule?.shortLabel ?? '';
                        return DateCard(
                          label: recShort.isNotEmpty
                              ? 'Deadline 🔁 $recShort'
                              : 'Deadline',
                          date: Helpers.formatDate(_currentTask.deadline!),
                          color: deadlineColor,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),
            // Linked items — cross-module links (Task/Sales/CRM) stored in
            // extraFields['linkedItems']; tap opens, long-press removes.
            Row(
              children: [
                const Icon(Icons.link, size: 14, color: AppTheme.secondaryText),
                const SizedBox(width: 6),
                const Text(
                  'Linked',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LinkedItemsChips(
                    links: ItemLinksService().linksOf(_currentTask.extraFields),
                    onAdd: _openLinkPicker,
                    onRemove: _confirmRemoveLink,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),
            // Edit hint caption
            Row(
              children: [
                Icon(
                  Icons.edit_outlined,
                  size: 11,
                  color: AppTheme.lightText.withOpacity(0.6),
                ),
                const SizedBox(width: 4),
                Text(
                  'Tap title, deadline, or assignee to edit',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.lightText.withOpacity(0.6),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),

            // Closure Rating (shown when task is closed)
            if (_currentTask.isClosed || _currentTask.isCancelled) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text(
                    'Rating: ',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                  ...List.generate(5, (i) {
                    final filled = (_currentTask.rating ?? 0) > i;
                    return GestureDetector(
                      onTap: () => _setRating(i + 1),
                      child: Icon(
                        filled ? Icons.star : Icons.star_border,
                        size: 22,
                        color: filled ? Colors.amber : AppTheme.lightText,
                      ),
                    );
                  }),
                ],
              ),
            ],

            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // Progress bar with duration and expected progress - CLICKABLE TO EDIT
            InkWell(
              onTap: () => _editProgressInline(),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.trending_up,
                          size: 16,
                          color: AppTheme.secondaryText,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Progress:',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                        const Spacer(),
                        // Duration info
                        if (widget.task.deadline != null)
                          Text(
                            '${Helpers.getTaskDurationDays(widget.task.createdAt, widget.task.deadline)} days',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _currentTask.progress,
                              // Timing colours only while under way — a
                              // finished or cancelled task reads calm green.
                              backgroundColor: AppTheme.primaryGreen
                                  .withOpacity(0.1),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _currentTask.progress >= 1.0 ||
                                        _currentTask.isClosed ||
                                        _currentTask.isCancelled
                                    ? AppTheme.onTime
                                    : deadlineColorFor(
                                        _currentTask.createdAt,
                                        _currentTask.deadline,
                                      ),
                              ),
                              minHeight: 10,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(_currentTask.progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Expected vs Actual progress (hidden once task is
                    // completed/cancelled ΓÇö no point warning 'Behind by')
                    if (_currentTask.deadline != null &&
                        !_currentTask.isClosed &&
                        !_currentTask.isCancelled) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Expected: ${(Helpers.getExpectedProgress(_currentTask.createdAt, _currentTask.deadline) * 100).toInt()}%',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          Builder(
                            builder: (context) {
                              final expected = Helpers.getExpectedProgress(
                                _currentTask.createdAt,
                                _currentTask.deadline,
                              );
                              final actual = _currentTask.progress;
                              final diff = ((actual - expected) * 100).toInt();

                              if (diff >= 0) {
                                return Text(
                                  'Ahead by +$diff%',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF0D47A1), // Dark blue
                                  ),
                                );
                              } else {
                                return Text(
                                  'Behind by $diff%',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    // Same timing rule as the bar above.
                                    color: deadlineColorFor(
                                      _currentTask.createdAt,
                                      _currentTask.deadline,
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Milestones ΓÇö subtle expandable row (mirrors Sales Pipeline).
            // Header toggles the inline checklist; pencil opens the full
            // add/remove dialog.
            InkWell(
              onTap: () => setState(
                () => _showMilestonesInline = !_showMilestonesInline,
              ),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.flag_outlined,
                      size: 16,
                      color: AppTheme.secondaryText,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Milestones',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _buildMilestoneSummary(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _showMilestonesDialog(),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: AppTheme.secondaryText.withOpacity(0.7),
                        ),
                      ),
                    ),
                    Icon(
                      _showMilestonesInline
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: AppTheme.secondaryText,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
            if (_showMilestonesInline) _buildMilestoneChecklistInline(),
            // Money summary: Cash ledger and Payments (Sales/CRM parity).
            _buildMoneySummary(),
            const SizedBox(height: 8),

            // Actions Taken section ΓÇö tappable list with date/time, scrolls to message
            _buildActionsTakenSection(),
          ],
        ),
      ),
    );

    // Card taps are always live ΓÇö title/deadline/assignee stay editable even
    // for a fresh draft (the old "type in the message box first" lock was
    // removed per user request).
    return card;
  }

  /// Money summary for the task card. Two independent ledgers, never summed:
  /// • Cash — net in-hand from 💵 Added/Expense/Refund (cost categories are a
  ///   CRM-only concept, so Tasks show just the Net).
  /// • Payments — 💳 receivables (Due · Collected · Outstanding); a payment is
  ///   money promised/collected against a due and never touches cash.
  /// Hidden entirely when the task carries neither kind of entry. Mirrors the
  /// Sales/CRM detail card so money reads the same across modules.
  Widget _buildMoneySummary() {
    final cashMsgs = _messages
        .where((m) => Helpers.extractCashDelta(m.text) != null)
        .toList();
    final (due, collected, outstanding) = Helpers.computeReceivables(
      _messages.map((m) => m.text),
    );
    final hasCash = cashMsgs.isNotEmpty;
    final hasPayments = due != 0 || collected != 0 || outstanding != 0;
    if (!hasCash && !hasPayments) return const SizedBox.shrink();

    final balance = Helpers.computeCashBalance(_messages.map((m) => m.text));

    // Per-category cash buckets — only populated on CRM/Service tickets.
    final cats = Map<String, dynamic>.from(
      _currentTask.extraFields?['cashCats'] ?? const {},
    );
    final totals = <String, double>{};
    for (final m in cashMsgs) {
      final label = (cats[m.id] as String?) ?? 'Uncategorized';
      totals[label] =
          (totals[label] ?? 0) + (Helpers.extractCashDelta(m.text) ?? 0);
    }
    // Show category chips only when at least one real category exists.
    final hasCategories = totals.keys.any((k) => k != 'Uncategorized');
    final entries =
        (hasCategories
                ? totals.entries.where((e) => e.value != 0)
                : const <MapEntry<String, double>>[])
            .toList()
          ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 10),
          // Cash ledger — tap opens the full 💵 ledger date-wise.
          if (hasCash)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openCashStatement,
              child: Row(
                children: [
                  const Icon(
                    Icons.account_balance_wallet,
                    size: 16,
                    color: Color(0xFF099268),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Cash',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Net: ${Helpers.formatCashAmount(balance)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF099268),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: AppTheme.secondaryText,
                  ),
                ],
              ),
            ),
          if (hasCash && hasCategories) ...[
            const SizedBox(height: 6),
            if (entries.isEmpty)
              const Text(
                'Entries offset to zero',
                style: TextStyle(fontSize: 11, color: AppTheme.secondaryText),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: entries
                    .map(
                      (e) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryGreen.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppTheme.primaryGreen.withOpacity(0.15),
                          ),
                        ),
                        child: Text(
                          '${e.key}: ${Helpers.formatCashAmount(e.value)}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.primaryText,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
          // Payments ledger — separate from cash by design; tap opens the
          // full 💳 receivables statement date-wise.
          if (hasPayments) ...[
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPaymentsStatement,
              child: Row(
                children: [
                  const Icon(
                    Icons.payments,
                    size: 16,
                    color: Color(0xFF099268),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Payments',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Outstanding: ${Helpers.formatCashAmount(outstanding)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF099268),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: AppTheme.secondaryText,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Due ${Helpers.formatCashAmount(due)} · '
              'Collected ${Helpers.formatCashAmount(collected)}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppTheme.secondaryText,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Tap handler for the Cash summary row: date-wise 💵 statement popup.
  /// Uses the full message list when available (`_messages` may be a
  /// paginated subset — the statement should not miss older entries).
  void _openCashStatement() {
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    showCashStatementSheet(
      context,
      title: 'Cash Transactions',
      entries: buildCashStatement(
        source,
        ledger: 'cash',
        includeSettledMarker: true,
        senderNameOf: _getSenderName,
      ),
      footerLabel: 'Net Cash Balance',
      footerValue: Helpers.formatCashAmount(
        Helpers.computeCashBalance(source.map((m) => m.text)),
      ),
      onJumpToMessage: _scrollToMessageById,
    );
  }

  /// Tap handler for the Payments summary row: date-wise 💳 receivables
  /// statement popup (Due · Collected rows, running Outstanding).
  void _openPaymentsStatement() {
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    final outstanding = Helpers.computeReceivables(
      source.map((m) => m.text),
    ).$3;
    showCashStatementSheet(
      context,
      title: 'Payment Transactions',
      entries: buildCashStatement(
        source,
        ledger: 'payments',
        senderNameOf: _getSenderName,
      ),
      footerLabel: 'Outstanding',
      footerValue: Helpers.formatCashAmount(outstanding),
      onJumpToMessage: _scrollToMessageById,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIONS TAKEN — tappable list, scroll to message
  // ─────────────────────────────────────────────────────────────────────────

  // ⚠️ ACTION-TYPE CHECKLIST — actions are read by TEXT PARSING in several
  // independent places. When adding a new action type (like 'cash' was),
  // update ALL of these or the action silently disappears somewhere:
  //   1. _getActionMessages (below)      — log gate; not matched = no log row
  //   2. _actionMeta                     — log row icon/color (else: bell)
  //   3. _buildActionsTakenSection       — filter chips row + filter switch
  //   4. _parseActionDetails             — log row title/detail text
  //   5. _buildSystemMessage             — chat card label, color, BODY text
  //   6. assignee_tasks_screen.dart _buildCompactActionRow — row icon chain
  //   7. task_actions_screen.dart (byMe/toMe) row builder  — row icon chain
  //   8. card_action_icons.dart / helpers.dart detectActionType — card strips
  //   9. local_database_service.dart write-through/backfill — index via (8);
  //      a type missing in detectActionType is never written to actions tables
  // Message text FORMATS are defined in the action dialogs (e.g.
  // cash_action_dialog.dart _submit) — changing a format breaks all parsers.
  // Sales twins: sales_detail_screen.dart _buildSystemMessage,
  // _getActivityActionInfo, _buildActivityLog filter switch + chips.
  /// Stable id of the synthesized "Task created" log entry (never a chat
  /// message, so it gets a fixed id and is skipped for tap-to-scroll).
  static const String _createdEntryId = '__task_created__';

  List<(int, MessageModel)> _getActionMessages() {
    final results = <(int, MessageModel)>[];
    for (int i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      if (_isActionLogMessage(msg)) results.add((i, msg));
    }

    // Merge recovered entries from the durable system_logs subcollection —
    // covers chats swept by retention or devices that lost local data.
    final knownIds = <String>{for (final m in _messages) m.id};
    for (final log in _recoveredLogs) {
      if (knownIds.contains(log.id)) continue;
      if (log.details.trim().isEmpty) continue;
      // Skip legacy response-notification rows mirrored before the gate
      // excluded them — the outcome lives on the original card now.
      if (_isResponseNotificationText(log.details)) continue;
      results.add((
        -1,
        MessageModel(
          id: log.id,
          taskId: log.taskId,
          senderId: log.performedBy,
          text: log.details,
          type: MessageType.system,
          createdAt: log.createdAt,
        ),
      ));
    }

    // Synthesize the "Task created" entry from the task itself — creation
    // never produced a chat message, so it is reconstructed on every render
    // (nothing to persist or recover). Skipped when a creation entry already
    // exists so older tasks keep their original one.
    final hasCreation = results.any(
      (r) => r.$2.text.toLowerCase().contains('task created'),
    );
    if (!hasCreation) {
      results.add((
        -1,
        MessageModel(
          id: _createdEntryId,
          taskId: _currentTask.id,
          senderId: _currentTask.createdBy,
          text: 'Task created',
          type: MessageType.system,
          createdAt: _currentTask.createdAt,
        ),
      ));
    }

    // Creation is the earliest entry — sort unconditionally so it lands first.
    results.sort((a, b) => a.$2.createdAt.compareTo(b.$2.createdAt));
    return results;
  }

  /// Response notifications (Reply/Done/Resolve) — they update the original
  /// action card in place (chip flips to Actioned/Closed on the referenced
  /// bubble), so they must never appear as separate rows in the Actions log
  /// nor be mirrored into the durable system_logs. Delegates to
  /// _responseNoticeKind so the chat-line and log-gate signatures never drift.
  bool _isResponseNotificationText(String text) =>
      _responseNoticeKind(text) != null;

  /// Gate for the durable action log: which system messages count as actions.
  bool _isActionLogMessage(MessageModel msg) {
    final text = msg.text;
    final lower = text.toLowerCase();
    // Response notifications are NOT log entries — the original action card
    // already carries the outcome in place ("Query 1 - Actioned/Closed").
    if (_isResponseNotificationText(text)) return false;
    return msg.type == MessageType.system &&
        (lower.startsWith('reminder') ||
            lower.startsWith('warning') ||
            lower.startsWith('query') ||
            lower.contains('task created') ||
            lower.startsWith('status report') ||
            lower.startsWith('followup') ||
            text.contains('💵') ||
            lower.startsWith('cash') ||
            text.contains('💳') ||
            lower.startsWith('payment') ||
            lower.contains('follow-up') ||
            lower.contains('warning') || // Catch "Warning" anywhere
            lower.contains('assignee changed') ||
            lower.contains('assignee added') ||
            lower.contains('assignee removed') ||
            lower.contains('assignee updated') ||
            lower.contains('deadline updated') ||
            lower.contains('status changed') ||
            lower.contains('progress updated') ||
            lower.contains('priority changed') ||
            lower.contains('urgency changed') ||
            lower.contains('milestone added') ||
            RegExp(r'milestone \d+ added').hasMatch(lower) ||
            lower.contains('milestone removed') ||
            RegExp(r'milestone \d+ removed').hasMatch(lower) ||
            lower.contains('milestone completed') ||
            lower.contains('milestone reopened') ||
            lower.contains('milestones updated') ||
            text.contains('Action scheduled') ||
            text.contains('Reminder scheduled') ||
            text.contains('Follow-up scheduled') ||
            text.contains('sent a reminder') ||
            text.contains('requested a status report') ||
            text.contains('Status request sent') ||
            text.contains('🚧') ||
            lower.contains('blocker raised') ||
            lower.contains('approval requested') ||
            text.contains('⏳') ||
            lower.contains('extension requested') ||
            text.contains('📈') ||
            lower.contains('progress report') ||
            text.contains('📞') ||
            lower.contains('call made') ||
            text.contains('💬') ||
            lower.contains('whatsapp message') ||
            text.contains('⚠️') ||
            text.contains('Status') ||
            lower.contains('status') ||
            text.contains('asked for an update') ||
            // Response notifications (Reply/Done/Resolve) are excluded up-front
            // by _isResponseNotificationText — the original card carries the
            // outcome in place, so they are not separate log actions.
            text.contains('Task cancelled') ||
            text.contains('Task marked as complete') ||
            text.contains('Task activated') ||
            text.contains('Task scheduled') ||
            lower.contains('priority changed') ||
            lower.contains('urgency changed') ||
            lower.contains('category changed') ||
            lower.contains('deadline updated') ||
            lower.contains('start date updated') ||
            lower.contains('title updated') ||
            (lower.contains('title:') && text.contains('→')) ||
            lower.contains('description updated') ||
            (lower.contains('description:') && text.contains('→')) ||
            lower.contains('milestone added') ||
            RegExp(r'milestone \d+ added').hasMatch(lower) ||
            lower.contains('milestone removed') ||
            RegExp(r'milestone \d+ removed').hasMatch(lower) ||
            lower.contains('milestone completed') ||
            lower.contains('milestone reopened') ||
            lower.contains('milestones updated'));
  }

  /// One-time backfill: mirror pre-existing action messages into system_logs
  /// so old tasks get a durable log too (doc id = message id → idempotent).
  void _backfillSystemLogs() {
    if (_systemLogBackfillDone || _messages.isEmpty) return;
    _systemLogBackfillDone = true;
    final known = <String>{for (final l in _recoveredLogs) l.id};
    var written = 0;
    for (final m in _messages) {
      if (written >= 200) break;
      if (known.contains(m.id)) continue;
      if (!_isActionLogMessage(m)) continue;
      written++;
      FirebaseService().writeSystemLog(
        taskId: _currentTask.id,
        messageId: m.id,
        action: _parseActionDetails(m).title,
        performedBy: m.senderId,
        details: m.text,
        createdAt: m.createdAt,
      );
    }
  }

  // ⚠️ Keyword chain — unmatched action types fall to the default bell.
  // New action types MUST get a case here (see checklist at _getActionMessages).
  (IconData?, Color) _actionMeta(MessageModel msg) {
    final lower = msg.text.toLowerCase();
    if (lower.contains('task created')) {
      return (Icons.add_task, const Color(0xFF2F9E44));
    }
    if (msg.text.contains('⚠️') || lower.startsWith('warning')) {
      return (Icons.warning_amber_rounded, AppTheme.urgent);
    }
    if (msg.text.contains('💵') || lower.startsWith('cash')) {
      return (Icons.account_balance_wallet, const Color(0xFF099268));
    }
    if (msg.text.contains('💳') || lower.startsWith('payment')) {
      return (Icons.payments, const Color(0xFF7048E8));
    }
    if (lower.contains('assignee added') ||
        lower.contains('assignee removed') ||
        lower.contains('assignee updated') ||
        lower.contains('assignee changed')) {
      return (Icons.person_add_alt, const Color(0xFFF59F00));
    }
    if (lower.contains('deadline updated')) {
      return (null, const Color(0xFF1976D2)); // No icon for deadline changes
    }
    if (lower.contains('title updated') ||
        (lower.contains('title:') && msg.text.contains('→'))) {
      return (Icons.edit, const Color(0xFFF59F00));
    }
    if (lower.contains('description updated') ||
        (lower.contains('description:') && msg.text.contains('→'))) {
      return (Icons.description, const Color(0xFFF59F00));
    }
    if (lower.contains('status changed')) {
      return (Icons.flag, const Color(0xFF2F9E44));
    }
    if (lower.contains('progress updated')) {
      return (Icons.trending_up, const Color(0xFF1976D2));
    }
    if (lower.contains('priority changed')) {
      return (Icons.flag, const Color(0xFFE03131));
    }
    if (lower.contains('urgency changed')) {
      return (Icons.local_fire_department, const Color(0xFFFF6B00));
    }
    if (lower.contains('category changed')) {
      return (Icons.label, const Color(0xFFF59F00));
    }
    if (lower.contains('milestone added') ||
        RegExp(r'milestone \d+ added').hasMatch(lower) ||
        lower.contains('milestone removed') ||
        RegExp(r'milestone \d+ removed').hasMatch(lower) ||
        lower.contains('milestone completed') ||
        lower.contains('milestone reopened') ||
        lower.contains('milestones updated')) {
      return (Icons.flag, const Color(0xFF9C27B0));
    }
    // Assignee-side actions (check before follow-up — extension messages
    // contain a date but must not classify as follow-up)
    if (msg.text.contains('📞') || lower.contains('call made')) {
      return (Icons.call, const Color(0xFF0C8599));
    }
    if (msg.text.contains('💬') || lower.contains('whatsapp message')) {
      return (Icons.chat, const Color(0xFF25D366));
    }
    if (msg.text.contains('🚧') || lower.contains('blocker raised')) {
      return (Icons.block, const Color(0xFFC92A2A));
    }
    if (lower.contains('approval requested')) {
      return (Icons.fact_check, const Color(0xFF0B7285));
    }
    if (msg.text.contains('⏳') || lower.contains('extension requested')) {
      return (Icons.more_time, const Color(0xFF3B5BDB));
    }
    if (msg.text.contains('📈') || lower.contains('progress report')) {
      return (Icons.trending_up, const Color(0xFF7048E8));
    }
    if (lower.contains('follow-up') || lower.contains('followup')) {
      return (Icons.event_repeat, const Color(0xFF1976D2));
    }
    if (lower.contains('asked for an update') ||
        lower.contains('status request') ||
        (lower.contains('status') && lower.contains('query')) ||
        lower.startsWith('query')) {
      // Blue while pending — green is reserved for done/replied states
      return (Icons.summarize, const Color(0xFF1976D2));
    }
    if (lower.startsWith('status report') ||
        lower.contains('status report') ||
        lower.contains('status request') ||
        lower.contains('asked for an update') ||
        lower.contains('requested a status report') ||
        lower.contains('status')) {
      return (Icons.summarize, AppTheme.headerGreen);
    }
    return (Icons.notifications_active, AppTheme.deadlineNearing);
  }

  /// Scheduled/target date carried INSIDE the message text (reminder or
  /// follow-up), falling back to when the message was sent.
  /// ⚠️ Do NOT group the log by this — see [_scheduledDate].
  DateTime _actionDate(MessageModel msg) {
    final text = msg.text;
    // Parse "Followup dd/MM/yyyy HH:mm"
    final followupMatch = RegExp(
      r'Followup\s+(\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2})',
    ).firstMatch(text);
    if (followupMatch != null) {
      try {
        final parts = followupMatch.group(1)!.split(' ');
        final d = parts[0].split('/');
        final t = parts[1].split(':');
        return DateTime(
          int.parse(d[2]),
          int.parse(d[1]),
          int.parse(d[0]),
          int.parse(t[0]),
          int.parse(t[1]),
        );
      } catch (_) {}
    }
    final forMatch = RegExp(
      r'For:\s*(\d{2}/\d{2}/\d{4} \d{2}:\d{2})',
    ).firstMatch(text);
    if (forMatch != null) {
      try {
        final parts = forMatch.group(1)!.split(' ');
        final d = parts[0].split('/');
        final t = parts[1].split(':');
        return DateTime(
          int.parse(d[2]),
          int.parse(d[1]),
          int.parse(d[0]),
          int.parse(t[0]),
          int.parse(t[1]),
        );
      } catch (_) {}
    }
    final remMatch = RegExp(
      r'scheduled for (\d{2}/\d{2}/\d{4} \d{2}:\d{2})',
    ).firstMatch(text);
    if (remMatch != null) {
      try {
        final parts = remMatch.group(1)!.split(' ');
        final d = parts[0].split('/');
        final t = parts[1].split(':');
        return DateTime(
          int.parse(d[2]),
          int.parse(d[1]),
          int.parse(d[0]),
          int.parse(t[0]),
          int.parse(t[1]),
        );
      } catch (_) {}
    }
    return msg.createdAt;
  }

  /// The scheduled date parsed out of the message text, or null when the
  /// action carries none. The log groups by `createdAt` — when the action
  /// actually happened — and shows this as a trailing "→ 19 Jul" instead.
  /// Grouping by it filed a reminder set for next week under a future date
  /// header that sorted ABOVE "This Week", so the log read time-travelled.
  DateTime? _scheduledDate(MessageModel msg) {
    final parsed = _actionDate(msg);
    return parsed == msg.createdAt ? null : parsed;
  }

  /// One-line value summary for a log row — before/after pair, else the single
  /// new value, else the quoted message. _parseActionDetails already computes
  /// these; the log used to discard them, forcing a trip into chat to learn
  /// WHAT changed. Trimmed so a row stays one or two lines.
  String? _actionValueLabel(_ActionDetails d) {
    var value = (d.before != null && d.after != null)
        ? '${d.before} → ${d.after}'
        : (d.after ?? d.message);
    if (value == null) return null;
    value = value.replaceAll('\n', ' · ').trim();
    if (value.isEmpty) return null;
    // Acronyms for compact one-line display
    value = value.replaceAll('Balance:', 'Bal:');
    return value.length > 40 ? '${value.substring(0, 39)}…' : value;
  }

  /// Single source of truth for the filter chips AND the filtered list, so a
  /// chip can never drift out of sync with its predicate.
  bool _actionMatchesFilter(MessageModel msg, String? filter) {
    if (filter == null) return true;
    final lower = msg.text.toLowerCase();
    switch (filter) {
      case 'status':
        return lower.contains('status changed') ||
            lower.contains('status report');
      case 'progress':
        return lower.contains('progress updated');
      case 'edit':
        return lower.contains('title updated') ||
            lower.contains('description') ||
            lower.contains('assignee added') ||
            lower.contains('assignee removed') ||
            lower.contains('assignee updated') ||
            lower.contains('assignee changed') ||
            lower.contains('priority changed') ||
            lower.contains('urgency changed') ||
            lower.contains('category changed') ||
            lower.contains('deadline updated');
      case 'reminder':
        return lower.contains('reminder') || lower.contains('followup');
      case 'warning':
        return lower.contains('warning');
      case 'cash':
        return msg.text.contains('💵') ||
            msg.text.contains('💳') ||
            lower.startsWith('cash') ||
            lower.startsWith('payment');
      case 'request':
        return lower.contains('approval requested');
      default:
        return true;
    }
  }

  // Durable action log recovered from the system_logs subcollection —
  // survives chat retention sweeps and lost local data; merged into the
  // Activity section below.
  List<SystemLogModel> _recoveredLogs = [];
  StreamSubscription<List<SystemLogModel>>? _systemLogSub;
  bool _systemLogBackfillDone = false;
  // Activity log starts collapsed — fully expanded it fills the screen and
  // pushes the chat out of view; tap the header row to open it
  bool _activityExpanded = false;
  String?
  _selectedActionFilter; // For Slack-style filtering: 'status', 'progress', 'edit', 'reminder', 'warning'

  Widget _buildActionsTakenSection() {
    final allActions = _getActionMessages();
    if (allActions.isEmpty) return const SizedBox.shrink();

    // Chronological per-type numbering so every log row shows "#N"
    // (computed over ALL actions so numbers survive filtering)
    final actionNumbers = <String, int>{};
    final typeCounts = <String, int>{};
    for (final record in allActions) {
      final msg = record.$2;
      // Creation entry carries no #N — it is unique by definition.
      if (msg.id == _createdEntryId) continue;
      final key = _actionTypeKey(_parseActionDetails(msg).title);
      typeCounts[key] = (typeCounts[key] ?? 0) + 1;
      actionNumbers[msg.id] = typeCounts[key]!;
    }

    // Filter actions with the shared predicate so chips and rows agree
    var filteredActions = allActions;
    if (_selectedActionFilter != null) {
      filteredActions = allActions
          .where(
            (record) => _actionMatchesFilter(record.$2, _selectedActionFilter),
          )
          .toList();
    }

    // Counts over ALL actions. A chip with 0 hits is hidden, so tapping any
    // visible chip always yields rows instead of "No <type> actions".
    final chipDefs = <({String label, IconData icon, String key})>[
      (label: 'Status', icon: Icons.flag, key: 'status'),
      (label: 'Progress', icon: Icons.trending_up, key: 'progress'),
      (label: 'Edits', icon: Icons.edit, key: 'edit'),
      (label: 'Reminders', icon: Icons.notifications, key: 'reminder'),
      (label: 'Warnings', icon: Icons.warning, key: 'warning'),
      (label: 'Cash', icon: Icons.account_balance_wallet, key: 'cash'),
      (label: 'Request', icon: Icons.fact_check, key: 'request'),
    ];
    final chipCounts = <String, int>{
      for (final c in chipDefs)
        c.key: allActions
            .where((record) => _actionMatchesFilter(record.$2, c.key))
            .length,
    };

    // Collapsed header stays informative: newest entry + when it landed
    final latestMsg = allActions.last.$2;
    final latestLabel =
        '${_numberedTitle(_parseActionDetails(latestMsg).title, actionNumbers[latestMsg.id])}'
        ' · ${DateFormat('d MMM, h:mm a').format(latestMsg.createdAt)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        const Divider(height: 1),
        const SizedBox(height: 6),
        // Header — tap the row to expand/collapse the log
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _activityExpanded = !_activityExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                const Icon(
                  Icons.history,
                  size: 14,
                  color: AppTheme.secondaryText,
                ),
                const SizedBox(width: 4),
                Text(
                  'Activity (${allActions.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(width: 8),
                // Collapsed: newest entry. Expanded: every row is listed —
                // the old 10-row cap + "Show All" toggle made the header
                // count disagree with the visible rows (user report).
                if (!_activityExpanded)
                  Expanded(
                    child: Text(
                      latestLabel,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.lightText,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 4),
                Icon(
                  _activityExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: AppTheme.secondaryText,
                ),
              ],
            ),
          ),
        ),
        if (_activityExpanded) ...[
          const SizedBox(height: 4),
          // Rows are tappable (jump to the message in chat) — say so
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Tap an entry to jump to it in chat',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: AppTheme.lightText,
              ),
            ),
          ),
          // Filter chips (compact) — only types this task actually has
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                children: [
                  _buildActionFilterChip(
                    'All',
                    Icons.filter_list,
                    null,
                    allActions.length,
                  ),
                  for (final c in chipDefs)
                    if ((chipCounts[c.key] ?? 0) > 0)
                      _buildActionFilterChip(
                        c.label,
                        c.icon,
                        c.key,
                        chipCounts[c.key],
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Grouped actions by date (condensed)
          ..._buildGroupedActions(filteredActions, actionNumbers),
        ],
      ],
    );
  }

  Widget _buildActionFilterChip(
    String label,
    IconData icon,
    String? filter, [
    int? count,
  ]) {
    final isSelected = _selectedActionFilter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? Colors.white : AppTheme.secondaryText,
            ),
            const SizedBox(width: 4),
            Text(count == null ? label : '$label $count'),
          ],
        ),
        selected: isSelected,
        onSelected: (_) {
          setState(() {
            _selectedActionFilter = isSelected ? null : filter;
          });
        },
        selectedColor: AppTheme.primaryGreen,
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: isSelected ? Colors.white : AppTheme.primaryText,
        ),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isSelected ? AppTheme.primaryGreen : Colors.grey[300]!,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedActions(
    List<(int, MessageModel)> actions,
    Map<String, int> actionNumbers,
  ) {
    // All entries are listed — the old "last 10" cap + Show All toggle was
    // removed so the header count always matches the visible rows.
    final visible = actions;

    if (visible.isEmpty) {
      return [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'No ${_selectedActionFilter} actions',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.lightText,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ];
    }

    // Group by date
    final groups = <String, List<(int, MessageModel)>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (final record in visible) {
      final msg = record.$2;
      // Group by when the action HAPPENED. Grouping by a date parsed out of
      // the text put reminders scheduled for next week under a future header
      // that sorted above "This Week" — the scheduled date rides the row.
      final date = msg.createdAt;
      final dateOnly = DateTime(date.year, date.month, date.day);
      final diff = dateOnly.difference(today).inDays;

      String groupLabel;
      if (diff == 0) {
        groupLabel = 'Today';
      } else if (diff == -1) {
        groupLabel = 'Yesterday';
      } else if (diff < -1 && diff >= -7) {
        groupLabel = 'This Week';
      } else {
        groupLabel = DateFormat('MMMM d, yyyy').format(dateOnly);
      }

      if (!groups.containsKey(groupLabel)) {
        groups[groupLabel] = [];
      }
      groups[groupLabel]!.add(record);
    }

    // Build widgets
    final widgets = <Widget>[];
    groups.forEach((label, groupActions) {
      // The header already names the day for Today/Yesterday/single-date
      // groups, so rows there show the TIME; only the multi-day 'This Week'
      // group needs a per-row date to stay readable.
      final rowMode = label == 'This Week' ? 'date' : 'time';
      // Date header
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.secondaryText,
            ),
          ),
        ),
      );

      // Actions in this group
      for (int i = 0; i < groupActions.length; i++) {
        widgets.add(
          _buildSlackStyleActionItem(
            groupActions[i],
            actionNumbers[groupActions[i].$2.id],
            rowMode,
          ),
        );
        if (i < groupActions.length - 1) {
          widgets.add(const SizedBox(height: 2));
        }
      }

      // Divider after group
      widgets.add(const Divider(height: 12));
    });

    return widgets;
  }

  Widget _buildSlackStyleActionItem(
    (int, MessageModel) record, [
    int? number,
    String rowMode = 'time',
  ]) {
    final msg = record.$2;
    final meta = _actionMeta(msg);
    final icon = meta.$1;
    final color = meta.$2;

    final actionDetails = _parseActionDetails(msg);
    // Time for single-day groups (header carries the date), date only for
    // the multi-day 'This Week' group.
    final slotLabel = rowMode == 'date'
        ? DateFormat('d MMM').format(msg.createdAt)
        : DateFormat('h:mm a').format(msg.createdAt);
    final valueLabel = _actionValueLabel(actionDetails);
    final scheduled = _scheduledDate(msg);

    // A row earns its trailing icon only while the action is still waiting on
    // someone (query reply, follow-up/approval/extension/blocker/call closure).
    // Informational entries and already-closed ones show no tile — the log used
    // to end every row with an icon + ✓ badge, which read as noise.
    final closed = msg.isReplied || msg.isFollowUpDone;
    final actionType = Helpers.detectActionType(msg.text);
    final needsClosure =
        !closed &&
        actionType != null &&
        CardActionIcons.closureTypes.contains(actionType);

    // Build a single-line summary: "· Actor · Title · value → date"
    final parts = <String>[
      '· ${actionDetails.actor}',
      '· ${_numberedTitle(actionDetails.title, number)}',
    ];
    if (valueLabel != null) parts.add('· $valueLabel');
    if (scheduled != null)
      parts.add('→ ${DateFormat('d MMM').format(scheduled)}');
    final summary = parts.join(' ');

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      // The synthesized creation entry has no chat message to jump to.
      onTap: msg.id == _createdEntryId
          ? null
          : () {
              // Entry tapped inside the details sheet: close the sheet so
              // the target chat message is visible, then scroll to it.
              if (_taskCardSheetOpen) Navigator.of(context).pop();
              _scrollToMessageById(msg.id);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Time/date in a fixed-width slot so content aligns vertically
            SizedBox(
              width: 50,
              child: Text(
                slotLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.lightText.withValues(alpha: 0.7),
                ),
              ),
            ),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.secondaryText,
                  height: 1.2,
                ),
              ),
            ),
            // Trailing tile: only for actions that still need closure. The
            // fixed-size empty slot keeps the summary column aligned on rows
            // without a marker.
            const SizedBox(width: 6),
            if (needsClosure && icon != null)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(icon, size: 12, color: color),
              )
            else
              const SizedBox(width: 24, height: 24),
          ],
        ),
      ),
    );
  }

  /// Base type key for per-type numbering — strips "#N" and status suffixes
  /// (e.g. "Query #2 - Replied" → "Query").
  String _actionTypeKey(String title) {
    var t = title;
    final dash = t.indexOf(' - ');
    if (dash >= 0) t = t.substring(0, dash);
    t = t.replaceAll(RegExp(r'\s*#\d+'), '').trim();
    // Cash sub-types (Added/Expense/Refund/Settled) share ONE counter, so
    // log rows agree with the chat cards' family numbering ("Cash Added 2"
    // counts every 💵 entry, not just the Added ones). "Payment - Due"
    // already coalesces to "Payment" via the dash split above.
    if (t.startsWith('Cash')) t = 'Cash';
    return t;
  }

  /// Inserts "#N" into a title that doesn't already carry a number,
  /// keeping suffixes like " - Replied" after the number.
  String _numberedTitle(String title, int? number) {
    if (number == null || title.contains('#')) return title;
    final dash = title.indexOf(' - ');
    if (dash >= 0) {
      return '${title.substring(0, dash)} #$number${title.substring(dash)}';
    }
    return '$title #$number';
  }

  // ⚠️ Per-type title/detail parser for log rows. A type missing here shows
  // the generic 'Action' title (see checklist at _getActionMessages).
  _ActionDetails _parseActionDetails(MessageModel msg) {
    final lower = msg.text.toLowerCase();
    // Use senderId to get actual user name, shown as initials in the log
    String actor = Helpers.nameInitials(_getSenderName(msg.senderId));
    String title = 'Action';
    String? before;
    String? after;
    String? message;

    // Parse different action types - concise titles (no past tense)
    if (lower.contains('task created')) {
      title = 'Task created'; // Synthesized entry — actor rides senderId
    } else if (lower.contains('status changed')) {
      title = 'Status'; // Not "Status changed"
      // Current format: "Status changed: Old → New by X at Y"; old messages
      // used "from Old to New", kept as fallback.
      final arrowMatch = RegExp(
        r'Status changed:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      } else {
        final fromMatch = RegExp(r'from (.+?) to').firstMatch(msg.text);
        final toMatch = RegExp(r'to (.+?) by').firstMatch(msg.text);
        if (fromMatch != null) before = fromMatch.group(1);
        if (toMatch != null) after = toMatch.group(1);
      }
    } else if (lower.contains('progress updated')) {
      title = 'Progress'; // Not "Progress updated"
      // Current format: "Progress updated: X% → Y% by ..."
      final arrowMatch = RegExp(
        r'Progress updated:\s*(\d+)\s*%\s*→\s*(\d+)\s*%',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = '${arrowMatch.group(1)}%';
        after = '${arrowMatch.group(2)}%';
      } else {
        final fromMatch = RegExp(r'from (\d+)%').firstMatch(msg.text);
        final toMatch = RegExp(r'to (\d+)%').firstMatch(msg.text);
        if (fromMatch != null) before = '${fromMatch.group(1)}%';
        if (toMatch != null) after = '${toMatch.group(1)}%';
      }
    } else if (lower.contains('priority changed')) {
      title = 'Priority'; // Not "Priority changed"
      final arrowMatch = RegExp(
        r'Priority changed:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      } else {
        final fromMatch = RegExp(r'from (.+?) to').firstMatch(msg.text);
        final toMatch = RegExp(r'to (.+?) by').firstMatch(msg.text);
        if (fromMatch != null) before = fromMatch.group(1);
        if (toMatch != null) after = toMatch.group(1);
      }
    } else if (lower.contains('urgency changed')) {
      title = 'Urgency'; // Not "Urgency changed"
      final arrowMatch = RegExp(
        r'Urgency changed:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      } else {
        final fromMatch = RegExp(r'from (.+?) to').firstMatch(msg.text);
        final toMatch = RegExp(r'to (.+?) by').firstMatch(msg.text);
        if (fromMatch != null) before = fromMatch.group(1);
        if (toMatch != null) after = toMatch.group(1);
      }
    } else if (lower.contains('category changed')) {
      title = 'Category'; // Not "Category changed"
      // Format: "📂 Category changed: Old → New by X at Y" (unquoted values)
      final arrowMatch = RegExp(
        r'Category changed:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      }
    } else if (lower.contains('title updated') ||
        (lower.contains('title:') && lower.contains('→'))) {
      title = 'Title'; // Not "Title updated"
      // Try arrow format first: "Title updated: "old" → "new"" or "Title: "old" → "new""
      final arrowMatch =
          RegExp(
            r'Title updated:\s*"([^"]+)"\s*→\s*"([^"]+)"',
          ).firstMatch(msg.text) ??
          RegExp(r'Title:\s*"([^"]+)"\s*→\s*"([^"]+)"').firstMatch(msg.text);
      if (arrowMatch != null) {
        before = '"${arrowMatch.group(1)}"';
        after = '"${arrowMatch.group(2)}"';
      } else {
        // Fallback to old format: "from X to Y"
        final fromMatch = RegExp(r'from "([^"]+)"').firstMatch(msg.text);
        final toMatch = RegExp(r'to "([^"]+)"').firstMatch(msg.text);
        if (fromMatch != null) before = '"${fromMatch.group(1)}"';
        if (toMatch != null) after = '"${toMatch.group(1)}"';
      }
    } else if (lower.contains('description updated') ||
        (lower.contains('description:') && lower.contains('→'))) {
      title = 'Description'; // Not "Description updated"
      // Try arrow format: "Description updated: "old" → "new"" or "Description: "old" → "new""
      final arrowMatch =
          RegExp(
            r'Description updated:\s*"([^"]+)"\s*→\s*"([^"]+)"',
          ).firstMatch(msg.text) ??
          RegExp(
            r'Description:\s*"([^"]+)"\s*→\s*"([^"]+)"',
          ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = '"${arrowMatch.group(1)}"';
        after = '"${arrowMatch.group(2)}"';
      }
    } else if (lower.contains('deadline updated')) {
      title = 'Deadline'; // Not "Deadline updated"
      final arrowMatch = RegExp(
        r'Deadline updated:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      } else {
        final fromMatch = RegExp(r'from (.+?) to').firstMatch(msg.text);
        final toMatch = RegExp(r'to (.+?) by').firstMatch(msg.text);
        if (fromMatch != null) before = fromMatch.group(1);
        if (toMatch != null) after = toMatch.group(1);
      }
    } else if (lower.contains('start date updated')) {
      title = 'Start date'; // Not "Start date updated"
      final arrowMatch = RegExp(
        r'Start date updated:\s*(.+?)\s*→\s*(.+?)\s+by\s',
        caseSensitive: false,
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = arrowMatch.group(1);
        after = arrowMatch.group(2);
      } else {
        final fromMatch = RegExp(r'from (.+?) to').firstMatch(msg.text);
        final toMatch = RegExp(r'to (.+?) by').firstMatch(msg.text);
        if (fromMatch != null) before = fromMatch.group(1);
        if (toMatch != null) after = toMatch.group(1);
      }
    } else if (lower.contains('assignee added') ||
        lower.contains('assignee removed') ||
        lower.contains('assignee updated')) {
      final isAdded = lower.contains('assignee added');
      final isRemoved = lower.contains('assignee removed');
      final isUpdated = lower.contains('assignee updated');
      title = isAdded
          ? 'Assignee Added'
          : isRemoved
          ? 'Assignee Removed'
          : 'Assignee Updated';

      final countMatch = RegExp(
        r'Assignee = ([^\s]+\s+assignees?)',
        caseSensitive: false,
      ).firstMatch(msg.text);
      final countText = countMatch?.group(1);

      if (isAdded || isRemoved) {
        final namesMatch = RegExp(
          r'Assignee (?:Added|Removed):\s*(.+?),\s*Assignee =',
          caseSensitive: false,
        ).firstMatch(msg.text);
        final names = namesMatch?.group(1)?.trim();
        if (names != null && names.isNotEmpty) {
          after = countText == null ? names : '$names · $countText';
        }
      } else if (isUpdated) {
        final updatedMatch = RegExp(
          r'Assignee Updated:\s*Removed\s*(.+?)\s*(?:;|→)\s*Added\s*(.+?),\s*Assignee =',
          caseSensitive: false,
        ).firstMatch(msg.text);
        if (updatedMatch != null) {
          before = 'Removed ${updatedMatch.group(1)?.trim() ?? ''}';
          final addedNames = updatedMatch.group(2)?.trim() ?? '';
          after = countText == null
              ? 'Added $addedNames'
              : 'Added $addedNames · $countText';
        }
      }
    } else if (lower.contains('assignee changed')) {
      title = 'Assignee'; // Not "Assignee changed"
      final fromMatch = RegExp(r'from "([^"]+)"').firstMatch(msg.text);
      final toMatch = RegExp(r'to "([^"]+)"').firstMatch(msg.text);
      if (fromMatch != null) before = fromMatch.group(1);
      if (toMatch != null) after = toMatch.group(1);
    } else if (lower.contains('milestone added') ||
        RegExp(r'milestone \d+ added').hasMatch(lower) ||
        lower.contains('milestone removed') ||
        RegExp(r'milestone \d+ removed').hasMatch(lower) ||
        lower.contains('milestone completed') ||
        lower.contains('milestone reopened')) {
      if (lower.contains('milestone added') ||
          RegExp(r'milestone \d+ added').hasMatch(lower)) {
        title = 'Milestone Added';
      } else if (lower.contains('milestone removed') ||
          RegExp(r'milestone \d+ removed').hasMatch(lower)) {
        title = 'Milestone Removed';
      } else if (lower.contains('milestone completed')) {
        title = 'Milestone Completed';
      } else {
        title = 'Milestone Reopened';
      }
      final detailMatch = RegExp(r':\s*"([^"]+)"').firstMatch(msg.text);
      if (detailMatch != null) {
        message = detailMatch.group(1);
      }
    } else if (lower.contains('milestones updated')) {
      title = 'Milestones'; // Backward-compatible old messages
      final arrowMatch = RegExp(
        r'(\d+)/(\d+)\s*→\s*(\d+)/(\d+)',
      ).firstMatch(msg.text);
      if (arrowMatch != null) {
        before = '${arrowMatch.group(1)}/${arrowMatch.group(2)}';
        after = '${arrowMatch.group(3)}/${arrowMatch.group(4)}';
      }
    } else if (msg.text.contains('💵') || lower.startsWith('cash')) {
      if (msg.text.contains('Cash Added')) {
        title = 'Cash Added';
      } else if (msg.text.contains('Cash Expense')) {
        title = 'Cash Expense';
      } else if (msg.text.contains('Cash Refund')) {
        title = 'Cash Refund';
      } else if (msg.text.contains('Cash Settled')) {
        title = 'Cash Settled';
      } else {
        title = 'Cash';
      }
      // Detail: amount/note plus running balance on one line
      final detail = msg.text
          .replaceFirst(RegExp(r'^💵\s*Cash\s*\w*\s*:?\s*'), '')
          .replaceAll('\n', ' · ')
          .trim();
      if (detail.isNotEmpty) message = detail;
    } else if (msg.text.contains('💳') || lower.startsWith('payment')) {
      final payFirstLine = msg.text.split('\n').first;
      title = payFirstLine.contains('Due')
          ? 'Payment - Due'
          : payFirstLine.contains('Collected')
          ? 'Payment - Collected'
          : 'Payment';
      // Detail: entry (Due/Collected + note) plus running totals on one line
      final detail = msg.text
          .replaceFirst(RegExp(r'^💳\s*'), '')
          .replaceAll('\n', ' · ')
          .trim();
      if (detail.isNotEmpty) message = detail;
    } else if (msg.text.contains('🚧') || lower.contains('blocker raised')) {
      title = msg.isFollowUpDone ? 'Blocker - Resolved' : 'Blocker';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (lower.contains('approval requested')) {
      title = msg.isFollowUpDone
          ? 'Request - Closed'
          : msg.isReplied
          ? 'Request - Actioned'
          : 'Request';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (msg.text.contains('⏳') ||
        lower.contains('extension requested')) {
      title = msg.isReplied ? 'Extension - Actioned' : 'Extension Requested';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (msg.text.contains('📈') || lower.contains('progress report')) {
      title = 'Progress Report';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (msg.text.contains('📞') || lower.contains('call made')) {
      if (lower.contains('call scheduled')) {
        title = msg.isFollowUpDone ? 'Call - Done' : 'Call Scheduled';
        final noteMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
        if (noteMatch != null) message = noteMatch.group(1);
      } else {
        title = 'Call';
        final nameMatch = RegExp(r'to (.+?) \(').firstMatch(msg.text);
        if (nameMatch != null) message = nameMatch.group(1);
      }
    } else if (msg.text.contains('💬') || lower.contains('whatsapp message')) {
      title = 'WhatsApp';
      final nameMatch = RegExp(r'to (.+?) \(').firstMatch(msg.text);
      if (nameMatch != null) message = nameMatch.group(1);
    } else if (lower.contains('follow-up') || lower.contains('followup')) {
      title = msg.isFollowUpDone ? 'Follow-up - Done' : 'Follow-up';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (lower.startsWith('query') ||
        lower.contains('asked for an update') ||
        lower.contains('status request') ||
        (lower.contains('status') && lower.contains('query'))) {
      // Query message
      int? queryNum = msg.sequenceNumber;
      if (queryNum == null) {
        final numMatch = RegExp(
          r'Query\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(msg.text);
        if (numMatch != null) queryNum = int.tryParse(numMatch.group(1)!);
      }
      if (queryNum != null) {
        title = msg.isReplied ? 'Query $queryNum - Replied' : 'Query $queryNum';
      } else {
        title = msg.isReplied ? 'Query - Replied' : 'Query';
      }
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (lower.contains('reminder')) {
      // Parse sequence number from model or text
      int? reminderNum = msg.sequenceNumber;
      if (reminderNum == null) {
        final numMatch = RegExp(
          r'Reminder\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(msg.text);
        if (numMatch != null) reminderNum = int.tryParse(numMatch.group(1)!);
      }
      title = reminderNum != null ? 'Reminder $reminderNum' : 'Reminder';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (lower.contains('warning')) {
      // Parse sequence number from model or text
      int? warningNum = msg.sequenceNumber;
      if (warningNum == null) {
        final numMatch = RegExp(
          r'Warning\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(msg.text);
        if (numMatch != null) warningNum = int.tryParse(numMatch.group(1)!);
      }
      title = warningNum != null ? 'Warning $warningNum' : 'Warning';
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    } else if (lower.contains('status report')) {
      title = 'Status Report'; // Not "Status Report requested"
      final msgMatch = RegExp(r'"([^"]+)"').firstMatch(msg.text);
      if (msgMatch != null) message = msgMatch.group(1);
    }

    return _ActionDetails(
      actor: actor,
      title: title,
      before: before,
      after: after,
      message: message,
    );
  }

  // ---- Call sheet: users in the task with numbers (copy / dial) ----

  /// Collect all task participants that have a phone number.
  List<({String label, String name, String phone})> _getCallableParticipants() {
    final entries = <({String label, String name, String phone})>[];
    final seenPhones = <String>{};

    void add(String label, String name, String? phone, {String? uid}) {
      // Phone is often missing on in-app users (referenced by UID only) —
      // fall back to cached team members so the sheet still lists a
      // callable / WhatsApp-able number instead of "no numbers available".
      var p = (phone ?? '').trim();
      if (p.isEmpty) p = _lookupPhoneFor(uid: uid, name: name) ?? '';
      if (p.isEmpty) return;
      final normalized = Helpers.normalizePhone(p) ?? p;
      if (!seenPhones.add(normalized)) return;
      entries.add((label: label, name: name.isNotEmpty ? name : p, phone: p));
    }

    // Creator
    add(
      'Created By',
      _getUserNameById(_currentTask.createdBy),
      _currentTask.createdByPhone,
      uid: _currentTask.createdBy,
    );

    // Assignees (multi-assignee lists first, else single assignee)
    final extra = _currentTask.extraFields;
    final names = extra?['assigneeNames'];
    final phones = extra?['assigneePhones'];
    final uids = extra?['assigneeUids'];
    if (names is List && names.isNotEmpty) {
      final phonesAligned = phones is List && phones.length == names.length;
      final uidsAligned = uids is List && uids.length == names.length;
      for (int i = 0; i < names.length; i++) {
        add(
          'Assignee',
          names[i]?.toString() ?? '',
          phonesAligned ? phones[i]?.toString() : null,
          uid: uidsAligned ? uids[i]?.toString() : null,
        );
      }
    } else {
      add(
        'Assignee',
        _currentTask.assignedTo,
        _currentTask.assignedToPhone,
        uid: _currentTask.assignedToUid,
      );
    }

    return entries;
  }

  /// Resolve a phone number for a participant from cached team members when
  /// the task itself didn't store one. Matches by UID first, then by
  /// (case-insensitive) name.
  String? _lookupPhoneFor({String? uid, String? name}) {
    final members = ContactPickerService().getCachedTeamMembers();
    if (members == null) return null;
    final u = (uid ?? '').trim();
    final n = (name ?? '').trim().toLowerCase();
    if (u.isNotEmpty) {
      for (final m in members) {
        if (m.uid == u && m.phone.trim().isNotEmpty) return m.phone.trim();
      }
    }
    if (n.isNotEmpty) {
      for (final m in members) {
        if (m.name.trim().toLowerCase() == n && m.phone.trim().isNotEmpty) {
          return m.phone.trim();
        }
      }
    }
    return null;
  }

  void _copyPhoneNumber(String phone) {
    Clipboard.setData(ClipboardData(text: phone));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Number copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// AppBar call icon: list users in the task with numbers (copy or call).
  void _showTaskCallSheet() {
    final participants = _getCallableParticipants();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Call',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Call, WhatsApp, or copy the number',
                style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
              ),
              const SizedBox(height: 12),
              if (participants.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'No phone numbers available for this task.',
                    style: TextStyle(fontSize: 13, color: AppTheme.lightText),
                  ),
                )
              else
                ...participants.map(
                  (p) => _buildCallRow(ctx, p.label, p.name, p.phone),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCallRow(
    BuildContext sheetCtx,
    String label,
    String name,
    String phone,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.headerGreen.withValues(alpha: 0.15),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: AppTheme.headerGreen,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$phone · $label',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            color: AppTheme.secondaryText,
            tooltip: 'Copy number',
            onPressed: () => _copyPhoneNumber(phone),
          ),
          IconButton(
            icon: const Icon(Icons.chat, size: 22),
            color: AppTheme.primaryGreen,
            tooltip: 'WhatsApp',
            onPressed: () {
              Navigator.pop(sheetCtx);
              _openWhatsApp(name, phone);
            },
          ),
          IconButton(
            icon: const Icon(Icons.call, size: 22),
            color: AppTheme.headerGreen,
            tooltip: 'Call',
            onPressed: () {
              Navigator.pop(sheetCtx);
              _placeCall(name, phone);
            },
          ),
        ],
      ),
    );
  }

  /// Launch the dialer (user picks their calling app) and record the call
  /// in the chat with date, time and the user who made it.
  Future<void> _placeCall(String name, String phone) async {
    final uri = Uri.parse('tel:$phone');
    bool launched = false;
    try {
      launched = await launchUrl(uri);
    } catch (e) {
      print('[TaskDetail] Failed to launch dialer: $e');
    }
    if (launched) {
      await _sendSystemMessage(
        '📞 Call made to $name ($phone) by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the dialer'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Open WhatsApp chat for the number and log it in the chat with date,
  /// time and the user who sent it.
  Future<void> _openWhatsApp(String name, String phone) async {
    final normalized = Helpers.normalizePhone(phone) ?? phone;
    final uri = Uri.parse('https://wa.me/$normalized');
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      print('[TaskDetail] Failed to launch WhatsApp: $e');
    }
    if (launched) {
      await _sendSystemMessage(
        '💬 WhatsApp message sent to $name ($phone) by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open WhatsApp'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper method to build person card
  /// Show a bottom sheet with contact info (phone number) and call option
  void _showContactInfo({
    required String name,
    required String? phone,
    required String label,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            CircleAvatar(
              radius: 28,
              backgroundColor: AppTheme.headerGreen.withValues(alpha: 0.15),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: AppTheme.headerGreen,
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.secondaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            if (phone != null && phone.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.phone,
                    size: 16,
                    color: AppTheme.secondaryText,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    phone,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.primaryText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Call button
                  ElevatedButton.icon(
                    onPressed: () {
                      CustomerCommsService.instance.call(
                        context,
                        CustomerInfo(name: name, phone: phone),
                        record: (text) => _sendSystemMessage(text),
                        byName: _currentUserName,
                      );
                    },
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Call'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.headerGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // WhatsApp button
                  ElevatedButton.icon(
                    onPressed: () {
                      CustomerCommsService.instance.whatsapp(
                        context,
                        CustomerInfo(name: name, phone: phone),
                        record: (text) => _sendSystemMessage(text),
                        byName: _currentUserName,
                      );
                    },
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'Phone number not available',
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.secondaryText,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // Helper method to build assignee card with all assignees
  Widget _buildAssigneeCard(String label, Color color) {
    // Get all assignees
    final participantNames = _currentTask.extraFields?['participantNames'];
    final allAssignees =
        _currentTask.isGroupTask &&
            participantNames is List &&
            participantNames.isNotEmpty
        ? List<String>.from(participantNames)
        : [_currentTask.assignedTo];

    // Filter out empty/null assignees
    final validAssignees = allAssignees.where((a) => a.isNotEmpty).toList();

    if (validAssignees.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.15)),
        ),
        child: Row(
          children: [
            Icon(Icons.person_outline, size: 18, color: color.withOpacity(0.5)),
            const SizedBox(width: 8),
            Text(
              'Unassigned',
              style: TextStyle(
                fontSize: 12,
                color: color.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: color.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (validAssignees.length > 1) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${validAssignees.length}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Show assignee names with better formatting
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: validAssignees.map((assignee) {
              final isMe = _isAssigneeMe(assignee);
              final displayName = isMe ? 'Me' : assignee;
              final initial = displayName.isNotEmpty
                  ? displayName[0].toUpperCase()
                  : '?';

              return Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.4,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isMe
                      ? color.withOpacity(0.15)
                      : color.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isMe
                        ? color.withOpacity(0.3)
                        : color.withOpacity(0.15),
                    width: isMe ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Avatar circle with initial
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: isMe ? color : color.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          initial,
                          style: TextStyle(
                            fontSize: 9,
                            color: isMe ? Colors.white : color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    // Name
                    Flexible(
                      child: Text(
                        displayName,
                        style: TextStyle(
                          fontSize: 11,
                          color: isMe ? color : AppTheme.primaryText,
                          fontWeight: isMe ? FontWeight.w700 : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  bool _isUsableDisplayName(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty &&
        normalized != 'user' &&
        normalized != 'unknown' &&
        normalized != 'unknown creator';
  }

  void _resolveCreatorNameIfNeeded() async {
    if (_isTaskCreator()) {
      print('[TaskDetail] Skipping creator name resolution - user is creator');
      return;
    }

    // Check if we already have a resolved name
    if (_resolvedCreatorName != null &&
        _isUsableDisplayName(_resolvedCreatorName!)) {
      print(
        '[TaskDetail] Creator name already resolved: $_resolvedCreatorName',
      );
      return;
    }

    final creatorPhone = _currentTask.createdByPhone ?? '';
    final creatorUid = _currentTask.createdBy.trim();

    // PHONEBOOK-FIRST: Look up creator's phone in local contacts
    if (creatorPhone.isNotEmpty && _creatorNameLookupUid != creatorUid) {
      print(
        '[TaskDetail] Looking up creator phone in phonebook: $creatorPhone',
      );
      final phonebookName = await ContactPickerService().getPhonebookName(
        creatorPhone,
      );
      if (phonebookName != null && _isUsableDisplayName(phonebookName)) {
        if (mounted && _currentTask.createdBy.trim() == creatorUid) {
          print('[TaskDetail] Found in phonebook: "$phonebookName"');
          _creatorNameLookupUid = creatorUid;
          setState(() {
            _resolvedCreatorName = phonebookName;
          });
          return;
        }
      }
      print(
        '[TaskDetail] Creator phone not found in phonebook, falling back to Firestore',
      );
    }

    // FALLBACK: Use Firestore user lookup
    final lowerCreatorUid = creatorUid.toLowerCase();
    if (creatorUid.isEmpty ||
        creatorUid.length < 5 ||
        lowerCreatorUid == 'user' ||
        lowerCreatorUid == 'unknown' ||
        _creatorNameLookupUid == creatorUid) {
      print(
        '[TaskDetail] Skipping Firestore lookup - invalid or already looked up',
      );
      // Try using createdByName as final fallback
      final fallbackName = _currentTask.createdByName ?? '';
      // Guard with mounted: this branch runs after an await, so the widget
      // can be unmounted by the time we get here — an unguarded setState
      // then hits `_element!` on null and crashes the isolate.
      if (mounted &&
          _isUsableDisplayName(fallbackName) &&
          _resolvedCreatorName == null) {
        setState(() {
          _resolvedCreatorName = fallbackName;
        });
      }
      return;
    }

    print('[TaskDetail] Firestore lookup for UID: $creatorUid');
    _creatorNameLookupUid = creatorUid;
    FirebaseService()
        .getUser(creatorUid)
        .then((user) {
          if (!mounted || _currentTask.createdBy.trim() != creatorUid) return;
          final resolvedName = user?.name.trim() ?? '';
          print(
            '[TaskDetail] Firestore resolved: "$resolvedName" (user: ${user?.name})',
          );
          if (_isUsableDisplayName(resolvedName)) {
            setState(() {
              _resolvedCreatorName = resolvedName;
            });
            return;
          }
          // Fallback to phone number
          final phone = user?.phone ?? creatorPhone;
          if (phone.isNotEmpty) {
            setState(() {
              _resolvedCreatorName = phone;
            });
          }
        })
        .catchError((error) {
          print('[TaskDetail] Creator name lookup failed: $error');
          // Final fallback to createdByName or phone
          final fallbackName = _currentTask.createdByName ?? creatorPhone;
          if (fallbackName.isNotEmpty && mounted) {
            setState(() {
              _resolvedCreatorName = fallbackName;
            });
          }
        });
  }

  // Helper method to get creator display name.
  String _getUserNameById(String uid) {
    final normalizedUid = uid.trim();
    final extraFields = _currentTask.extraFields ?? const <String, dynamic>{};
    // Prioritize _resolvedCreatorName (phonebook-first resolution)
    final creatorNameCandidates = <String>[
      _resolvedCreatorName ?? '',
      _currentTask.createdByName ?? '',
      extraFields['createdByName']?.toString() ?? '',
      extraFields['creatorName']?.toString() ?? '',
    ];

    // Check if the uid parameter matches the CURRENT user (show "Me" for self)
    if (normalizedUid == _currentUserId) {
      return 'Me';
    }

    for (final candidate in creatorNameCandidates) {
      final name = candidate.trim();
      if (_isUsableDisplayName(name)) {
        return name;
      }
    }

    final lowerUid = normalizedUid.toLowerCase();
    // Don't return raw Firebase UID - check if it looks like a UID (28 chars alphanumeric)
    final looksLikeFirebaseUid =
        normalizedUid.length >= 20 &&
        RegExp(r'^[a-zA-Z0-9]+$').hasMatch(normalizedUid);

    if (!looksLikeFirebaseUid &&
        normalizedUid.isNotEmpty &&
        normalizedUid.length >= 5 &&
        lowerUid != 'user' &&
        lowerUid != 'unknown') {
      return normalizedUid;
    }

    // Final fallback: try to use phone number
    final creatorPhone = _currentTask.createdByPhone ?? '';
    if (creatorPhone.isNotEmpty) {
      return creatorPhone;
    }

    return 'Unknown';
  }

  String _getSenderName(String senderId) {
    // NEVER return "System" - always return actual user name or "Me"
    if (senderId == 'system') {
      return _currentUserName.isNotEmpty ? _currentUserName : 'Unknown';
    }
    if (senderId == _currentUserId) return 'Me'; // Show "Me" for current user

    // Check if sender is the task creator
    if (senderId == _currentTask.createdBy) {
      return _getUserNameById(senderId);
    }

    // Check if sender is the assignee
    if (senderId == _currentTask.assignedToUid &&
        _currentTask.assignedTo.isNotEmpty) {
      final name = _currentTask.assignedTo.trim();
      if (name.toLowerCase() != 'user' && name.toLowerCase() != 'unknown') {
        return name;
      }
    }

    // Don't return raw Firebase UID
    final looksLikeFirebaseUid =
        senderId.length >= 20 && RegExp(r'^[a-zA-Z0-9]+$').hasMatch(senderId);
    if (looksLikeFirebaseUid) {
      // Multi-assignee co-participants: index-aligned extraFields lookup
      final extraName = _senderNameFromExtraFields(senderId);
      if (extraName != null) return extraName;

      // Previously resolved via Firestore users lookup
      final resolved = _resolvedSenderNames[senderId];
      if (resolved != null) return resolved;

      // Kick off async resolution; rebuild fills the name in when it lands
      _resolveSenderName(senderId);
      return 'Unknown';
    }

    return senderId.isNotEmpty ? senderId : 'Unknown';
  }

  /// Index-aligned UID→name lookup from task extraFields
  /// (assigneeUids↔assigneeNames, participantUids↔participantNames).
  String? _senderNameFromExtraFields(String senderId) {
    final extra = _currentTask.extraFields;
    if (extra == null) return null;
    String? lookup(String uidsKey, String namesKey) {
      final uids = extra[uidsKey];
      final names = extra[namesKey];
      if (uids is List && names is List && uids.length == names.length) {
        for (int i = 0; i < uids.length; i++) {
          if (uids[i]?.toString() == senderId) {
            final name = names[i]?.toString().trim() ?? '';
            if (_isUsableDisplayName(name)) return name;
          }
        }
      }
      return null;
    }

    return lookup('assigneeUids', 'assigneeNames') ??
        lookup('participantUids', 'participantNames');
  }

  /// Resolve an unknown sender UID via the Firestore users collection
  /// (memoized; mirrors the creator-name resolution pattern).
  void _resolveSenderName(String senderId) {
    if (_resolvedSenderNames.containsKey(senderId) ||
        _senderNameLookupsInFlight.contains(senderId)) {
      return;
    }
    _senderNameLookupsInFlight.add(senderId);
    FirebaseService()
        .getUser(senderId)
        .then((user) {
          if (!mounted) return;
          final name = user?.name.trim() ?? '';
          final phone = user?.phone.trim() ?? '';
          final display = _isUsableDisplayName(name) ? name : phone;
          if (display.isNotEmpty) {
            setState(() => _resolvedSenderNames[senderId] = display);
          }
        })
        .catchError((_) {})
        .whenComplete(() {
          _senderNameLookupsInFlight.remove(senderId);
        });
  }

  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  void _scrollToLatestMessage() {
    if (_messages.isEmpty) return;
    if (!mounted) return;
    if (!_scrollController.hasClients) {
      // ListView hasn't built yet — retry on next frame
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToLatestMessage(),
      );
      return;
    }
    // With reverse:true ListView, newest message is at scroll position 0
    _scrollController.jumpTo(0);
  }

  void _scrollToBottom() {
    _scrollToLatestMessage();
  }

  /// Paint a short-lived horizontal band behind the card being jumped to
  /// (notification tap → referenced action). Clears after ~2.5s so the feed
  /// returns to its normal look without another tap.
  void _highlightMessageCard(String messageId) {
    _highlightClearTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightClearTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  void _scrollToMessageById(String messageId, {int retryCount = 0}) {
    // Set guard flag on first call to prevent stream from resetting _messages
    if (retryCount == 0) {
      _isScrollingToMessage = true;
      // Reset the built-window probe so direction is measured fresh for this
      // jump (itemBuilder re-populates it as the lazy list renders).
      _builtMinDisplayIndex = 0;
      _builtMaxDisplayIndex = 0;
      _coarseLeapDone = false;
      _highlightMessageCard(messageId);
    }

    var index = _messages.indexWhere((m) => m.id == messageId);

    if (index < 0) {
      // Target message not currently rendered – expand _messages to include it
      final visibleMessages = MessageVisibilityService.getVisibleMessages(
        allMessages: _allMessages,
        participantHistory: widget.task.participantHistory,
        viewerId: _currentUserId,
        currentParticipants: _currentTask.participants,
      );
      final targetIndex = visibleMessages.indexWhere((m) => m.id == messageId);
      if (targetIndex < 0) {
        _isScrollingToMessage = false;
        return;
      }

      setState(() {
        // Include all messages from the target onwards so the widget will exist
        _messages = visibleMessages.sublist(targetIndex);
        _rebuildDisplayMessages();
      });

      // Wait one frame for build, then scroll
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted)
          _scrollToMessageById(messageId, retryCount: retryCount + 1);
      });
      return;
    }

    // Fast path: the target widget is laid out — lock onto it precisely.
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
      // Release guard flag after scroll animation completes
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _isScrollingToMessage = false;
      });
      return;
    }

    // The target is in the list but its widget is NOT built yet — a far
    // off-screen card in a lazy reverse:true ListView. The old approach made
    // one coarse fixed-height guess and a single correction, so it routinely
    // stopped SHORT of the target and only finished once a manual scroll
    // forced the list to render more. Instead, step the viewport toward the
    // real built-index window: each frame we jump closer (a coarse leap
    // first), the builder renders the newly exposed range, and once the
    // target gets a context the fast path above locks on. Bounded so it can
    // never spin.
    if (!_scrollController.hasClients) {
      if (retryCount < 10) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToMessageById(messageId, retryCount: retryCount + 1);
          }
        });
      } else {
        _isScrollingToMessage = false;
      }
      return;
    }

    final displayIndex = _displayMessages.indexWhere((m) => m.id == messageId);
    if (displayIndex < 0) {
      _isScrollingToMessage = false;
      return;
    }

    if (retryCount >= 60) {
      // Safety cap on the climb — release rather than loop forever.
      _isScrollingToMessage = false;
      return;
    }

    final position = _scrollController.position;
    final viewport = position.viewportDimension;

    // reverse:true puts the newest item (display index 0) at offset 0 (bottom
    // of the screen); older items sit at HIGHER offsets. Compare the target's
    // display index against the window the builder rendered LAST frame: if
    // it's beyond the top of that window we step up (toward older); if below,
    // step back down. Built-index feedback — not a fixed-height guess — is
    // what makes this land exactly, and it self-corrects an overshoot.
    double next = position.pixels;
    if (displayIndex > _builtMaxDisplayIndex) {
      next = position.pixels + viewport * 0.9;
      // First hop may leap straight to a coarse estimate to skip frames.
      if (!_coarseLeapDone) {
        final coarse = _coarseOffsetFor(displayIndex);
        if (coarse > next) next = coarse;
      }
    } else if (displayIndex < _builtMinDisplayIndex) {
      next = position.pixels - viewport * 0.9;
    }

    final maxExtent = position.maxScrollExtent;
    final clamped = next < 0 ? 0.0 : (next > maxExtent ? maxExtent : next);
    _scrollController.jumpTo(clamped);
    _coarseLeapDone = true;
    // Force the builder to re-report the rendered window next frame so the
    // following step reads the CURRENT range, not the whole-session max.
    _builtMinDisplayIndex = 1 << 30;
    _builtMaxDisplayIndex = -1;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToMessageById(messageId, retryCount: retryCount + 1);
    });
  }

  /// Coarse scroll-offset guess for a display index in the reverse:true list:
  /// sum of the (approximate) heights of every item newer than it. Only used
  /// as a first-hop accelerant — the built-index walk corrects any error.
  double _coarseOffsetFor(int displayIndex) {
    double est = 0;
    for (int i = displayIndex - 1; i >= 0; i--) {
      final msg = _displayMessages[i];
      if (msg.type == MessageType.system) {
        est += 50;
      } else if (msg.type == MessageType.image) {
        est += 200;
      } else {
        // Action cards (body + attachment + chips) run much taller than a
        // plain text bubble, so weight them higher to avoid undershoot.
        est += msg.isReplied || msg.type != MessageType.text ? 120 : 70;
      }
      if (i > 0 &&
          !_isSameDay(msg.createdAt, _displayMessages[i - 1].createdAt)) {
        est += 35; // Date separator
      }
    }
    return est;
  }

  // Show the delivery choice dialog before sending externally.
  // The dialog itself lives in DetailChatPlumbingMixin.chatDeliverToRecipient
  // so Sales/CRM offer the identical WhatsApp/SMS choice.
  void _showExternalDeliveryDialog({
    required String title,
    required String message,
    required ValueChanged<String> onSent,
  }) async {
    final recipient = _externalRecipient();
    if (recipient == null) {
      // No assignee on the card: nothing to nudge, but the message still has
      // to be saved.
      onSent('in-app');
      return;
    }
    await chatDeliverToRecipient(
      recipient: recipient,
      title: title,
      message: message,
      onSent: onSent,
      accent: AppTheme.headerGreen,
    );
  }

  /// The assignee this task's out-of-app nudges should be routed through,
  /// resolved from fields the task itself persists.
  ///
  /// B6: this used to call getAssigneeUser with an EMPTY team list, so its
  /// firstWhere always threw, the catch returned null, and every caller took
  /// the `assignee == null -> in-app` branch. The WhatsApp/SMS chooser was
  /// unreachable dead UI regardless of what the assignee actually had
  /// installed, and an off-app assignee silently received nothing.
  ExternalRecipient? _externalRecipient() {
    final rawIsOnApp = _currentTask.extraFields?['assigneeIsOnApp'];
    return ExternalNotificationService().resolveRecipient(
      assignedToName: _currentTask.assignedTo,
      assignedToUid: _currentTask.assignedToUid,
      // TaskModel.assignedToPhone already falls back to
      // extraFields['assigneePhone'].
      assignedToPhone: _currentTask.assignedToPhone,
      // Only trust the flag when it really is a bool — tasks created before it
      // existed fall back to "a resolved UID means they're on the app".
      isOnAppFlag: rawIsOnApp is bool ? rawIsOnApp : null,
    );
  }

  void _issueReminder() {
    final messageController = TextEditingController();
    String reminderMessage = '';
    // Sales parity: optional attachment rides inside the reminder card.
    PickedChatAttachment? pickedAttachment;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(
                Icons.notifications_active,
                color: AppTheme.deadlineNearing,
                size: 24,
              ),
              const SizedBox(width: 8),
              const Text(
                'Send Reminder',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Send reminder to ${widget.task.assignedTo}?',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                // Custom message
                const Text(
                  'Message (optional):',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: messageController,
                  maxLines: 3,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Add a custom message to the reminder...',
                    counterText: '',
                    hintStyle: const TextStyle(fontSize: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.dividerColor,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.deadlineNearing,
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(12),
                  ),
                  onChanged: (value) {
                    reminderMessage = value;
                  },
                ),
                buildChatAttachmentRow(
                  picked: pickedAttachment,
                  onChanged: (a) => setDialogState(() => pickedAttachment = a),
                  accentColor: AppTheme.deadlineNearing,
                ),
                const SizedBox(height: 8),
                if (_reminderCount > 0)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.deadlineNearing.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '⏰ Previous reminders sent: $_reminderCount',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.deadlineNearing,
                      ),
                    ),
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
                Navigator.pop(ctx);
                _sendReminderWithDetails(
                  null,
                  reminderMessage,
                  attachment: pickedAttachment,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.deadlineNearing,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Send Reminder'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendReminderWithDetails(
    DateTime? reminderDate,
    String customMessage, {
    PickedChatAttachment? attachment,
  }) async {
    final externalService = ExternalNotificationService();

    final externalMessage = externalService.formatReminderMessage(
      widget.task,
      _currentUserName,
      _reminderCount + 1,
    );

    _showExternalDeliveryDialog(
      title: 'Send Reminder',
      message: externalMessage,
      onSent: (deliveryMethod) async {
        final reminderNumber = _reminderCount + 1;
        final reminderMsg = MessageModel(
          id: Helpers.generateId(),
          taskId: _currentTask.id,
          senderId: _currentUserId,
          text:
              'Reminder $reminderNumber${customMessage.isNotEmpty ? ' "$customMessage"' : ''}',
          type: MessageType.system,
          systemType: SystemMessageType.reminder,
          sequenceNumber: reminderNumber,
          createdAt: DateTime.now(),
          deliveryMethod: deliveryMethod,
          fileUrl: attachment != null ? 'pending' : null,
          fileName: attachment?.name,
        );

        // Save message to Firebase
        _saveMessageToFirebase(reminderMsg);
        if (attachment != null) {
          chatAttachToExistingMessage(reminderMsg, attachment);
        }

        // Update task reminder count
        final updatedTask = _currentTask.copyWith(
          reminderCount: _reminderCount + 1,
          updatedAt: DateTime.now(),
        );
        await _updateTaskInFirebase(updatedTask);

        setState(() {
          _reminderCount++;
          _currentTask = updatedTask;
        });

        // If reminder date is set, add a scheduled reminder message
        if (reminderDate != null) {
          final scheduledMsg = MessageModel(
            id: Helpers.generateId(),
            taskId: _currentTask.id,
            senderId: _currentUserId,
            text: 'Followup ${Helpers.formatDateTime(reminderDate)}',
            type: MessageType.system,
            createdAt: DateTime.now(),
          );
          _saveMessageToFirebase(scheduledMsg);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deliveryMethod == 'in-app'
                  ? 'Reminder sent to ${widget.task.assignedTo}'
                  : deliveryMethod == 'failed'
                  ? 'Failed to send reminder'
                  : 'Reminder sent via ${deliveryMethod == 'whatsapp' ? 'WhatsApp' : 'SMS'} to ${widget.task.assignedTo}',
            ),
            backgroundColor: deliveryMethod == 'failed'
                ? Colors.red
                : AppTheme.deadlineNearing,
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }

  Future<void> _issueWarning() async {
    final messageController = TextEditingController();
    String warningMessage = '';
    // Sales parity: optional attachment rides inside the warning card.
    PickedChatAttachment? pickedAttachment;
    final externalService = ExternalNotificationService();
    final message = externalService.formatWarningMessage(
      widget.task,
      _currentUserName,
      _warningCount + 1,
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: AppTheme.urgent,
                size: 24,
              ),
              const SizedBox(width: 8),
              const Text(
                'Warning',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send a formal warning to ${widget.task.assignedTo}?'),
                const SizedBox(height: 16),
                // Custom message
                const Text(
                  'Message (optional):',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: messageController,
                  maxLines: 3,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Add a custom message to the warning...',
                    counterText: '',
                    hintStyle: const TextStyle(fontSize: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.dividerColor,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.urgent,
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(12),
                  ),
                  onChanged: (value) {
                    warningMessage = value;
                  },
                ),
                buildChatAttachmentRow(
                  picked: pickedAttachment,
                  onChanged: (a) => setDialogState(() => pickedAttachment = a),
                  accentColor: AppTheme.urgent,
                ),
                const SizedBox(height: 8),
                if (_warningCount > 0)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.urgent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Previous warnings issued: $_warningCount',
                      style: TextStyle(fontSize: 12, color: AppTheme.urgent),
                    ),
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
              onPressed: () async {
                Navigator.pop(ctx);
                // Now route through external delivery dialog if needed
                _showExternalDeliveryDialog(
                  title: 'Warning',
                  message: message,
                  onSent: (deliveryMethod) async {
                    final warningNumber = _warningCount + 1;
                    final warningMsg = MessageModel(
                      id: Helpers.generateId(),
                      taskId: _currentTask.id,
                      senderId: _currentUserId,
                      text:
                          'Warning $warningNumber${warningMessage.isNotEmpty ? ' "$warningMessage"' : ''}',
                      type: MessageType.system,
                      systemType: SystemMessageType.warning,
                      sequenceNumber: warningNumber,
                      createdAt: DateTime.now(),
                      deliveryMethod: deliveryMethod,
                      fileUrl: pickedAttachment != null ? 'pending' : null,
                      fileName: pickedAttachment?.name,
                    );

                    // Save message to Firebase
                    _saveMessageToFirebase(warningMsg);
                    final attach = pickedAttachment;
                    if (attach != null) {
                      chatAttachToExistingMessage(warningMsg, attach);
                    }

                    // Update task warning count
                    final updatedTask = _currentTask.copyWith(
                      warningCount: _warningCount + 1,
                      updatedAt: DateTime.now(),
                    );
                    await _updateTaskInFirebase(updatedTask);

                    setState(() {
                      _warningCount++;
                      _currentTask = updatedTask;
                    });
                  },
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.urgent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Send Warning'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _askStatusReport() async {
    final messageController = TextEditingController();
    String statusMessage = '';
    // Sales parity: optional attachment rides inside the query card.
    PickedChatAttachment? pickedAttachment;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: [
              Icon(Icons.summarize, color: AppTheme.headerGreen, size: 24),
              const SizedBox(width: 8),
              const Text(
                'Query',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send a query to ${widget.task.assignedTo}?'),
                const SizedBox(height: 16),
                // Custom message
                const Text(
                  'Message (required):',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: messageController,
                  maxLines: 3,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Add a custom message to the query...',
                    counterText: '',
                    hintStyle: const TextStyle(fontSize: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.dividerColor,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppTheme.headerGreen,
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(12),
                  ),
                  onChanged: (value) {
                    statusMessage = value;
                  },
                ),
                buildChatAttachmentRow(
                  picked: pickedAttachment,
                  onChanged: (a) => setDialogState(() => pickedAttachment = a),
                  accentColor: AppTheme.headerGreen,
                ),
                const SizedBox(height: 8),
                if (_statusRequestCount > 0)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.headerGreen.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Previous queries: $_statusRequestCount',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.headerGreen,
                      ),
                    ),
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
                if (statusMessage.trim().isEmpty) return;
                Navigator.pop(ctx);
                _sendStatusRequestWithMessage(
                  statusMessage.trim(),
                  attachment: pickedAttachment,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.headerGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Send Query'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendStatusRequestWithMessage(
    String customMessage, {
    PickedChatAttachment? attachment,
  }) async {
    final externalService = ExternalNotificationService();
    final message = externalService.formatStatusRequestMessage(
      widget.task,
      _currentUserName,
      _statusRequestCount + 1,
    );

    _showExternalDeliveryDialog(
      title: 'Send Query',
      message: message,
      onSent: (deliveryMethod) async {
        final queryNumber = _statusRequestCount + 1;
        // Create query message with sequence number
        final statusMsg = MessageModel(
          id: Helpers.generateId(),
          taskId: _currentTask.id,
          senderId: _currentUserId,
          text: customMessage.isNotEmpty
              ? 'Query $queryNumber "$customMessage"'
              : 'Query $queryNumber requested',
          type: MessageType.system,
          systemType: SystemMessageType.query,
          sequenceNumber: queryNumber,
          isReplied: false,
          createdAt: DateTime.now(),
          deliveryMethod: deliveryMethod,
          fileUrl: attachment != null ? 'pending' : null,
          fileName: attachment?.name,
        );

        // Save message to Firebase
        _saveMessageToFirebase(statusMsg);
        if (attachment != null) {
          chatAttachToExistingMessage(statusMsg, attachment);
        }

        // Update task status request count
        final updatedTask = _currentTask.copyWith(
          statusRequestCount: _statusRequestCount + 1,
          updatedAt: DateTime.now(),
        );
        await _updateTaskInFirebase(updatedTask);

        setState(() {
          _statusRequestCount++;
          _currentTask = updatedTask;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deliveryMethod == 'in-app'
                  ? 'Query sent to ${widget.task.assignedTo}'
                  : deliveryMethod == 'failed'
                  ? 'Failed to send query'
                  : 'Query sent via ${deliveryMethod == 'whatsapp' ? 'WhatsApp' : 'SMS'} to ${widget.task.assignedTo}',
            ),
            backgroundColor: deliveryMethod == 'failed'
                ? Colors.red
                : AppTheme.headerGreen,
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }

  // Show dialog to reply to a query
  Future<void> _showQueryReplyDialog(
    MessageModel message, {
    String dialogTitle = 'Reply to Query',
  }) async {
    final replyController = TextEditingController();
    String replyText = '';

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.reply, color: AppTheme.headerGreen, size: 24),
            const SizedBox(width: 8),
            Text(
              dialogTitle,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show original query
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.headerGreen.withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                message.text,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.primaryText,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: replyController,
              maxLines: 3,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Type your reply...',
                counterText: '',
                hintStyle: const TextStyle(fontSize: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.dividerColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: AppTheme.headerGreen,
                    width: 2,
                  ),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (value) {
                replyText = value;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (replyText.trim().isEmpty) return;
              Navigator.pop(ctx, replyText.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.headerGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Send Reply'),
          ),
        ],
      ),
    );

    if (result != null && mounted) {
      // Update the message with the reply
      try {
        final taskProvider = context.read<TaskProvider>();
        // Reply = closed (user rule): for Request and Query cards the OTHER
        // side's reply closes the card — the done flag rides the same update,
        // silently (the "↩️ Replied" notice below is the closure record; no
        // extra Done notice line). Follow-up/Meeting/Visit replies never close.
        final bool replyCloses =
            (message.systemType == SystemMessageType.approval ||
                message.systemType == SystemMessageType.query) &&
            message.senderId != _currentUserId;
        await taskProvider.updateMessage(_currentTask.id, message.id, {
          'queryReply': result,
          'repliedBy': _currentUserId,
          'repliedAt': Timestamp.now(),
          'isReplied': true,
          if (replyCloses) 'isFollowUpDone': true,
          if (replyCloses) 'followUpDoneBy': _currentUserId,
          if (replyCloses) 'followUpDoneAt': Timestamp.now(),
        });
        if (replyCloses && mounted) {
          setState(() {
            final index = _messages.indexWhere((m) => m.id == message.id);
            if (index != -1) {
              _messages[index] = _messages[index].copyWith(
                isReplied: true,
                queryReply: result,
                isFollowUpDone: true,
                followUpDoneBy: _currentUserId,
                followUpDoneAt: DateTime.now(),
              );
            }
          });
        }

        // Record the reply as a subtle system line (rendered by
        // _buildResponseNoticeLine, NOT as an action card). The query card
        // also flips to "Actioned" in place. Tapping jumps back to it.
        await _sendSystemMessage(
          _noticeText('↩️ Replied', message),
          referenceMessageId: message.id,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reply sent'),
            backgroundColor: AppTheme.headerGreen,
            duration: Duration(seconds: 2),
          ),
        );
      } catch (e) {
        print('[TaskDetail] Error sending query reply: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send reply'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // Mark a follow-up as done
  Future<void> _markFollowUpDone(MessageModel message) async {
    // Optimistic update: update local state immediately for instant UI feedback
    if (mounted) {
      setState(() {
        // Update the message in the local list
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = message.copyWith(
            isFollowUpDone: true,
            followUpDoneBy: _currentUserId,
            followUpDoneAt: DateTime.now(),
          );
        }
      });
    }

    try {
      final taskProvider = context.read<TaskProvider>();
      await taskProvider.updateMessage(_currentTask.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });

      // Record the completion as a subtle system line (not an action card).
      await _sendSystemMessage(
        _noticeText('✅ Marked as done', message),
        referenceMessageId: message.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Follow-up marked as done'),
            backgroundColor: AppTheme.primaryGreen,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[TaskDetail] Error marking follow-up as done: $e');
      // Revert optimistic update on failure
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message; // Revert to original
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to mark as done'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // Creator: mark a blocker as resolved (reuses follow-up done mechanics)
  Future<void> _resolveBlocker(MessageModel message) async {
    // Optimistic update for instant UI feedback
    if (mounted) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = message.copyWith(
            isFollowUpDone: true,
            followUpDoneBy: _currentUserId,
            followUpDoneAt: DateTime.now(),
          );
        }
      });
    }

    try {
      final taskProvider = context.read<TaskProvider>();
      await taskProvider.updateMessage(_currentTask.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });

      // Record the resolution as a subtle system line (not an action card).
      await _sendSystemMessage(
        _noticeText('🔓 Blocker resolved', message),
        referenceMessageId: message.id,
      );

      // Once the last open blocker is resolved, the task goes back to Active
      if (mounted) {
        final source = _allMessages.isNotEmpty ? _allMessages : _messages;
        final openBlockers = source
            .where(
              (m) =>
                  m.systemType == SystemMessageType.blocker &&
                  !m.isFollowUpDone &&
                  m.id != message.id,
            )
            .length;
        if (openBlockers == 0) {
          await _applyBlockedStatus(blocked: false);
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Blocker marked as resolved'),
            backgroundColor: AppTheme.primaryGreen,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[TaskDetail] Error resolving blocker: $e');
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message; // Revert to original
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to resolve blocker'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // Scheduler: mark a scheduled call as done once the call happened.
  Future<void> _markCallDone(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Call marked as done');
  }

  // Scheduler: mark a scheduled meeting as done once it happened (reuses the
  // generic isFollowUpDone flag — meetings carry no dedicated systemType).
  Future<void> _markMeetingDone(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Meeting marked as done');
  }

  Future<void> _markVisitDone(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Visit marked as done');
  }

  // Shared optimistic isFollowUpDone update backing the Close / Mark Done
  // chips (same fields _resolveBlocker/_markFollowUpDone write).
  Future<void> _setMessageDoneFlag(
    MessageModel message,
    String snackText,
  ) async {
    if (mounted) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = message.copyWith(
            isFollowUpDone: true,
            followUpDoneBy: _currentUserId,
            followUpDoneAt: DateTime.now(),
          );
        }
      });
    }
    try {
      final taskProvider = context.read<TaskProvider>();
      await taskProvider.updateMessage(_currentTask.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });
      // Record the completion as a subtle system line (not an action card).
      await _sendSystemMessage(
        _noticeText('✅ Marked as done', message),
        referenceMessageId: message.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(snackText),
            backgroundColor: AppTheme.primaryGreen,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[TaskDetail] Error updating done flag: $e');
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message; // Revert to original
          }
        });
      }
    }
  }

  // Creator: grant or deny a deadline extension request
  Future<void> _resolveExtension(MessageModel message, bool grant) async {
    String reply;
    if (grant) {
      // First date in the message text is the requested "until" date
      final dates = Helpers.parseAllActionDates(message.text);
      if (dates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not read the requested date'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      final requested = dates.first;
      // Date-only: set to end-of-day (23:59) for proper day calculation
      final newDeadline = DateTime(
        requested.year,
        requested.month,
        requested.day,
        23,
        59,
      );
      final oldDeadline = _currentTask.deadline != null
          ? Helpers.formatDate(_currentTask.deadline!)
          : 'No deadline';
      final updatedTask = _currentTask.copyWith(
        deadline: newDeadline,
        updatedAt: DateTime.now(),
      );
      setState(() {
        _currentTask = updatedTask;
      });
      await _updateTaskInFirebase(updatedTask);
      _sendSystemMessage(
        '📅 Deadline updated: $oldDeadline → ${Helpers.formatDate(newDeadline)} by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      );
      reply = 'Granted — new deadline ${Helpers.formatDate(newDeadline)}';
    } else {
      final reason = await _promptActionReason(
        title: 'Deny Extension',
        hint: 'Reason (optional)',
      );
      if (reason == null) return; // cancelled
      reply = reason.isEmpty ? 'Denied' : 'Denied: $reason';
    }
    await _replyToActionRequest(
      message,
      reply,
      grant ? 'Extension granted' : 'Extension denied',
    );
  }

  // Shared: store a creator reply on an approval/extension request message
  Future<void> _replyToActionRequest(
    MessageModel message,
    String reply,
    String snackText,
  ) async {
    try {
      final taskProvider = context.read<TaskProvider>();
      await taskProvider.updateMessage(_currentTask.id, message.id, {
        'queryReply': reply,
        'repliedBy': _currentUserId,
        'repliedAt': Timestamp.now(),
        'isReplied': true,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(snackText),
            backgroundColor: AppTheme.primaryGreen,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[TaskDetail] Error replying to action request: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to update request'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // Optional-reason prompt shared by resolve flows. Returns null on cancel.
  Future<String?> _promptActionReason({
    required String title,
    required String hint,
  }) async {
    final controller = TextEditingController();
    String text = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 500,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: hint,
            counterText: '',
            hintStyle: const TextStyle(fontSize: 13),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (value) => text = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  // Small blue inline chip used by blocker/approval/extension resolve actions
  Widget _inlineActionChip(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF1976D2).withOpacity(0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF1976D2).withOpacity(0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: const Color(0xFF1976D2)),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1976D2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Green trail shown once a request/call is closed, done or replied.
  // No who/when stamp here: every response also posts a quiet notice line
  // ("Request 7 · Replied · Me · 8:35 PM") at its chronological spot, and
  // repeating actor + time on the card made a triple (header meta, trail,
  // notice). Done-status trails duplicate the header's status word and the
  // notice entirely, so they vanish; reply trails keep just the replied
  // text and the ✓ (mirrored in sales_detail_screen.dart _inlineDoneLabel).
  Widget _inlineDoneRow(String label, {String? headerLabel, bool left = false}) {
    final dup =
        label.isNotEmpty && headerLabel != null && headerLabel.contains(label);
    if (dup) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        // Reply trails sit under the typed text on the REPLIER's edge: left
        // when the card's own sender wrote the reply, right when the other
        // person did (user rule). Status trails stay flush-right.
        mainAxisAlignment: left ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              label,
              textAlign: left ? TextAlign.start : TextAlign.end,
              // Normal weight, matching the header meta stamps — the ✓
              // carries the "done" signal, not bold text.
              style: const TextStyle(fontSize: 10, color: Color(0xFF2F9E44)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 3),
          const Icon(Icons.check_circle, size: 11, color: Color(0xFF2F9E44)),
        ],
      ),
    );
  }

  // Media helpers
  List<MessageModel> get _mediaMessages => _messages
      .where(
        (m) =>
            m.type == MessageType.image ||
            m.type == MessageType.file ||
            m.type == MessageType.voice,
      )
      .toList();

  // WhatsApp-style full media gallery screen (shared widget with
  // search, filters, sizes, page counts, select/forward/share/delete).
  void _showMediaGallery(BuildContext context) {
    showChatMediaGallery(
      context,
      MediaGalleryConfig(
        messages: () => _mediaMessages,
        themeColor: AppTheme.primaryGreen,
        currentUserId: _currentUserId,
        senderName: _getSenderName,
        localPathFor: chatLocalPathFor,
        openImage: (m) => _openImageViewer(m.fileUrl ?? ''),
        openDocument: _openDocumentViewer,
        openInChat: (m) => _scrollToMessageById(m.id),
        forward: _forwardMessage,
        deleteForMe: _galleryDeleteForMe,
        deleteForEveryone: _galleryDeleteForEveryone,
        // Same centralized gate as the long-press menu — an attached media
        // that reads as an audit entry is only deletable inside the tight
        // action-card undo window, never on the plain 60-minute rule.
        canDeleteForEveryone: _canDeleteForEveryoneGate,
      ),
    );
  }

  void _galleryDeleteForMe(MessageModel m) {
    final index = _messages.indexWhere((x) => x.id == m.id);
    if (index != -1) _deleteMessageForMe(m, index);
  }

  void _galleryDeleteForEveryone(MessageModel m) {
    final index = _messages.indexWhere((x) => x.id == m.id);
    if (index != -1) _deleteMessageForEveryone(m, index);
  }

  void _showAttachmentSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.lightText.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Attachments',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.headerGreen,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Media attachments row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(
                    Icons.document_scanner,
                    'Document',
                    Colors.blue,
                    () {
                      Navigator.pop(ctx);
                      attachFile();
                    },
                  ),
                  _attachOption(Icons.photo, 'Photo', Colors.purple, () {
                    Navigator.pop(ctx);
                    attachImage();
                  }),
                  _attachOption(Icons.camera_alt, 'Camera', Colors.pink, () {
                    Navigator.pop(ctx);
                    attachCamera();
                  }),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(Icons.headset_mic, 'Audio', Colors.orange, () {
                    Navigator.pop(ctx);
                    startRecording();
                  }),
                  _attachOption(
                    Icons.location_on,
                    'Location',
                    Colors.green,
                    () {
                      Navigator.pop(ctx);
                      _shareLocation();
                    },
                  ),
                  _attachOption(
                    Icons.contact_phone,
                    'Contact',
                    Colors.teal,
                    () {
                      Navigator.pop(ctx);
                      _shareContact();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Task Actions section
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Task Actions',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.headerGreen,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Action buttons row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _actionOption(
                    Icons.notifications_active,
                    'Reminder',
                    AppTheme.deadlineNearing,
                    '$_reminderCount sent',
                    () {
                      Navigator.pop(ctx);
                      _issueReminder();
                    },
                  ),
                  _actionOption(
                    Icons.warning_amber_rounded,
                    'Warning',
                    AppTheme.urgent,
                    '$_warningCount sent',
                    () {
                      Navigator.pop(ctx);
                      _issueWarning();
                    },
                  ),
                  _actionOption(
                    Icons.summarize,
                    'Status Update',
                    AppTheme.headerGreen,
                    '$_statusRequestCount sent',
                    () {
                      Navigator.pop(ctx);
                      _askStatusReport();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Removed Edit Task option - use AppBar edit icon instead
                  _actionOption(
                    Icons.check_circle_outline,
                    'Complete',
                    Colors.green,
                    'Mark done',
                    () {
                      Navigator.pop(ctx);
                      _markTaskComplete();
                    },
                  ),
                  _actionOption(
                    Icons.close,
                    'Close Task',
                    AppTheme.secondaryText,
                    'Archive task',
                    () {
                      Navigator.pop(ctx);
                      _closeTask();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: color.withOpacity(0.15),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Action option widget (for task actions)
  Widget _actionOption(
    IconData icon,
    String label,
    Color color,
    String subtitle,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: color.withOpacity(0.15),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryText,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Mark task complete
  void _markTaskComplete() {
    setState(() {
      _currentTask = _currentTask.copyWith(
        progress: 1.0,
        isClosed: true,
        updatedAt: DateTime.now(),
      );
    });

    // Add system message
    _messages.add(
      MessageModel(
        id: Helpers.generateId(),
        taskId: _currentTask.id,
        senderId: _currentUserId,
        text: 'Task marked as complete by ${_currentUserName}',
        type: MessageType.system,
        createdAt: DateTime.now(),
      ),
    );
    _rebuildDisplayMessages();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Task completed! 🎉'),
        duration: Duration(seconds: 2),
        backgroundColor: AppTheme.primaryGreen,
      ),
    );
    _scrollToBottom();
  }

  // Close task
  void _closeTask() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Close Task'),
        content: const Text(
          'Are you sure you want to close this task? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _currentTask = _currentTask.copyWith(
                  tags: [..._currentTask.tags, 'Closed'],
                  isClosed: true,
                  updatedAt: DateTime.now(),
                );
              });

              _messages.add(
                MessageModel(
                  id: Helpers.generateId(),
                  taskId: _currentTask.id,
                  senderId: _currentUserId,
                  text: 'Task closed by ${_currentUserName}',
                  type: MessageType.system,
                  createdAt: DateTime.now(),
                ),
              );
              _rebuildDisplayMessages();

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Task closed'),
                  duration: Duration(seconds: 2),
                  backgroundColor: AppTheme.secondaryText,
                ),
              );
              _scrollToBottom();
            },
            child: const Text(
              'Close',
              style: TextStyle(color: AppTheme.urgent),
            ),
          ),
        ],
      ),
    );
  }

  // Share location as a Google Maps link.
  // Implementation lives in DetailChatAttachmentsMixin.chatShareLocation so
  // Sales/CRM share this exact dialog instead of the dead tile they had.
  Future<void> _shareLocation() => chatShareLocation();

  // Share contact from device contacts.
  // Implementation lives in DetailChatAttachmentsMixin.chatShareContact.
  Future<void> _shareContact() => chatShareContact();

  // Full-screen image viewer (WhatsApp style)
  // Accepts either a local file path or a network URL.
  void _openImageViewer(String imageUrl) {
    final isLocal = !imageUrl.startsWith('http');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.share), onPressed: () {}),
              IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: isLocal
                  ? Image.file(
                      File(imageUrl),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const Icon(
                        Icons.broken_image,
                        size: 64,
                        color: Colors.white54,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.contain,
                      placeholder: (context, url) => const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.broken_image,
                        size: 64,
                        color: Colors.white54,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // Show message options on long-press (WhatsApp-style)
  void _showMessageOptions(MessageModel message, bool isMe, int index) {
    // WhatsApp-style time limits
    final messageAge = DateTime.now().difference(message.createdAt);
    final canEdit =
        isMe &&
        message.type == MessageType.text &&
        message.senderId != 'system' && // Cannot edit system messages
        !message.isEdited && // Cannot re-edit edited messages
        messageAge.inMinutes < 15; // 15-minute edit limit (WhatsApp standard)

    // Forward + BOTH Delete options are reserved for typed messages and
    // attachments — action cards (Reminder/Query/Cash/…), system edits and
    // status changes never offer them, in either direction or age window.
    // The text-keyword check only applies to plain TEXT (legacy action cards
    // stored as text) — a real attachment stays deletable even if its file
    // name starts with a keyword like "payment_receipt.pdf".
    final isActionOrEdit =
        message.type == MessageType.system ||
        (message.type == MessageType.text &&
            Helpers.detectActionType(message.text) != null);

    // Forward: only for text/media messages, not system actions or edits
    final canForward = !isActionOrEdit && !message.isEdited;

    // Share outside WhatWorks: same rule as Forward/Delete — typed messages
    // and attachments only. Action cards, status changes and edits are not
    // shareable off-app and are also excluded from the last-5 trail (both
    // go through _isShareableMessage).
    final canShareOutside = _isShareableMessage(message);

    // Undo a just-sent ACTION CARD: within a tight 60-second window, only by
    // its sender, and only while the card is still pristine — nobody has
    // replied, marked it done, and no response-notice points at it yet. A
    // Blocker is excluded (it's resolved, not deleted), and plain status / edit
    // / assignment system lines never classify as an action so they stay a
    // frozen audit trail. Everything else (query / follow-up / call / meeting /
    // visit / reminder / cash / …) becomes undoable like an accidental message.
    final canDeleteForEveryone = _canDeleteForEveryoneGate(message);

    // Delete for me: same typed/attachment-only gate
    final canDeleteForMe = !isActionOrEdit && !message.isEdited;

    // Reply: available for all non-system messages
    final canReply = message.type != MessageType.system;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Message preview
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.lightGrey,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      message.text.length > 100
                          ? '${message.text.substring(0, 100)}...'
                          : message.text,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.secondaryText,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Reply option (WhatsApp-style)
            if (canReply)
              ListTile(
                leading: const Icon(Icons.reply, color: AppTheme.headerGreen),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _replyingToMessage = message;
                  });
                },
              ),

            // Seen by option (only for own non-system messages)
            if (isMe && message.senderId != 'system')
              ListTile(
                leading: const Icon(
                  Icons.visibility,
                  color: AppTheme.headerGreen,
                ),
                title: const Text('Seen by'),
                onTap: () {
                  Navigator.pop(context);
                  showSeenByDialog(message);
                },
              ),

            // Forward option (only for text/media, not system actions or edits)
            if (canForward)
              ListTile(
                leading: const Icon(Icons.forward, color: AppTheme.headerGreen),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(context);
                  _forwardMessage(message);
                },
              ),

            // Share outside WhatWorks (WhatsApp / SMS to people without the app)
            if (canShareOutside)
              ListTile(
                leading: const Icon(
                  Icons.ios_share,
                  color: AppTheme.headerGreen,
                ),
                title: const Text('Share This Post'),
                subtitle: const Text(
                  'With item details · WhatsApp / SMS',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _shareOutside(tapped: message);
                },
              ),
            if (canShareOutside)
              ListTile(
                leading: const Icon(
                  Icons.dynamic_feed,
                  color: AppTheme.headerGreen,
                ),
                title: const Text('Share Last 5 Posts'),
                subtitle: const Text(
                  'Recent updates with item details',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _shareOutside();
                },
              ),

            // Edit message (only for own text messages)
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit, color: AppTheme.headerGreen),
                title: const Text('Edit Message'),
                onTap: () {
                  Navigator.pop(context);
                  _editMessage(message, index);
                },
              ),

            const Divider(height: 1),

            // Delete for me (not for system messages or edits)
            if (canDeleteForMe)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete for Me'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessageForMe(message, index);
                },
              ),

            // Delete for everyone — typed/attachment within 1 hour; an action
            // card within a tight 60-second undo window (isUndoableCard).
            if (canDeleteForEveryone)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for Everyone'),
                subtitle: Text(
                  isActionOrEdit
                      ? 'Available for ${60 - DateTime.now().difference(message.createdAt).inSeconds} more seconds'
                      : 'Available for ${60 - DateTime.now().difference(message.createdAt).inMinutes} more minutes',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.lightText,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessageForEveryone(message, index);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _forwardMessage(MessageModel message) async {
    // Navigate to shared forward target screen
    final targets = await Navigator.push<List<ForwardTarget>>(
      context,
      MaterialPageRoute(
        builder: (_) => ForwardTargetScreen(sourceParentId: _currentTask.id),
      ),
    );

    if (targets == null || targets.isEmpty) return;

    int successCount = 0;
    int failCount = 0;

    for (final target in targets) {
      try {
        final forwardedMessage = MessageModel(
          id: Helpers.generateId(),
          taskId: target.id,
          senderId: _currentUserId,
          text: message.type == MessageType.text
              ? message.text
              : '📎 ${message.fileName ?? 'File'}',
          type: message.type,
          fileUrl: message.fileUrl,
          fileName: message.fileName,
          createdAt: DateTime.now(),
          deliveryMethod: 'in-app',
        );

        if (target.type == 'task') {
          await context.read<TaskProvider>().sendMessage(
            target.id,
            forwardedMessage,
          );
        } else {
          await context.read<SalesProvider>().sendMessage(
            target.id,
            forwardedMessage,
          );
        }
        successCount++;
      } catch (e) {
        print(
          '[TaskDetail] Error forwarding to ${target.type} ${target.id}: $e',
        );
        failCount++;
      }
    }

    if (!mounted) return;

    if (successCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Forwarded to $successCount conversation${successCount > 1 ? 's' : ''}'
            '${failCount > 0 ? ', $failCount failed' : ''}',
          ),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to forward message'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _editMessage(MessageModel message, int index) {
    final controller = TextEditingController(text: message.text);
    final timeRemaining =
        15 - DateTime.now().difference(message.createdAt).inMinutes;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Edit Message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Edit your message...',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              maxLines: 4,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text(
              'You can edit for $timeRemaining more minutes',
              style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newText = controller.text.trim();
              if (newText.isNotEmpty && newText != message.text) {
                // Update local state
                setState(() {
                  _messages[index] = MessageModel(
                    id: message.id,
                    taskId: message.taskId,
                    senderId: message.senderId,
                    text: newText,
                    type: message.type,
                    fileUrl: message.fileUrl,
                    fileName: message.fileName,
                    duration: message.duration,
                    createdAt: message.createdAt,
                    searchableContent: message.searchableContent,
                    deliveryMethod: message.deliveryMethod,
                    isEdited: true,
                  );
                });

                // Sync to Firebase
                try {
                  await context
                      .read<TaskProvider>()
                      .updateMessage(_currentTask.id, message.id, {
                        'text': newText,
                        'isEdited': true,
                        'editedAt': DateTime.now().toIso8601String(),
                      });

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Message edited successfully'),
                      backgroundColor: AppTheme.primaryGreen,
                    ),
                  );
                } catch (e) {
                  print('[TaskDetail] Error saving edited message: $e');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to edit message: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.headerGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _deleteMessageForMe(MessageModel message, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete Message'),
        content: const Text('Delete this message for you?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);

              // Remove from local state
              setState(() {
                _messages.removeAt(index);
                _rebuildDisplayMessages();
              });

              // Persist: add current user to deletedFor array
              try {
                await context.read<TaskProvider>().updateMessage(
                  _currentTask.id,
                  message.id,
                  {
                    'deletedFor': FieldValue.arrayUnion([_currentUserId]),
                    'deletedForUid': _currentUserId, // For local SQLite update
                  },
                );
              } catch (e) {
                print('[TaskDetail] Error persisting delete-for-me: $e');
              }

              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Message deleted'),
                  backgroundColor: Colors.red,
                ),
              );
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

  /// Single source of truth for "this action card may be undone for everyone":
  /// the sender's own, still-pristine action card within a tight 60-second
  /// window. Mirrored in the long-press menu gate, the delete guard below and
  /// the gallery delete closure so the affordance and the action never disagree.
  bool _canUndoActionCard(MessageModel m) {
    if (m.senderId != _currentUserId) return false;
    if (!Helpers.isUndoableAction(m.text)) return false;
    if (DateTime.now().difference(m.createdAt).inSeconds >= 60) return false;
    if (m.isReplied || m.isFollowUpDone) return false;
    // A response-notice (or a chat reply) already pointing at the card means
    // someone has engaged with it — no longer pristine, so not undoable. Scan
    // the full store (same source _responseRefLabel trusts), not just the
    // display list, so a child that isn't rendered can't slip through.
    final source = _allMessages.isNotEmpty ? _allMessages : _messages;
    return !source.any((x) => x.replyToMessageId == m.id);
  }

  /// Single gate for the "Delete for Everyone" AFFORDANCE at every entry point
  /// (long-press menu, media gallery). Mirrors the defense-in-depth guard in
  /// [_deleteMessageForEveryone] so the option is never shown for a message the
  /// delete would silently reject: the sender's own plain message/media inside
  /// the 60-minute window, or — for anything that reads as an audit entry
  /// (system card, action-keyword text, replied/done card) — only while it is a
  /// pristine just-sent action card inside the tight 60-second undo window.
  /// Blockers and plain status/edit/assignment lines never pass either gate.
  bool _canDeleteForEveryoneGate(MessageModel m) {
    if (m.senderId != _currentUserId) return false;
    final isAuditEntry =
        m.type == MessageType.system ||
        (m.type == MessageType.text &&
            Helpers.detectActionType(m.text) != null);
    if (isAuditEntry || m.isReplied || m.isFollowUpDone) {
      return _canUndoActionCard(m);
    }
    return DateTime.now().difference(m.createdAt).inMinutes < 60;
  }

  void _deleteMessageForEveryone(MessageModel message, int index) {
    // A pristine, just-sent action card (query / follow-up / call / meeting /
    // visit / reminder / cash / …) is undoable for everyone within a tight 60s
    // window — recomputed here as defense in depth against any caller that
    // bypassed the menu gate. Everything this screen treats as an audit entry
    // stays permanently frozen: plain status / edit / assignment system lines,
    // Blockers (resolved, not deleted), and any action card whose reply / done
    // / response-notice has already landed.
    final isUndoableCard = _canUndoActionCard(message);
    if (!isUndoableCard &&
        (message.type == MessageType.system ||
            (message.type == MessageType.text &&
                Helpers.detectActionType(message.text) != null) ||
            message.isReplied ||
            message.isFollowUpDone)) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete for Everyone'),
        content: const Text(
          'This will delete the message for everyone in this task.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);

              try {
                // Soft-delete: mark as deleted instead of hard delete
                final taskProvider = context.read<TaskProvider>();
                await taskProvider.updateMessage(_currentTask.id, message.id, {
                  'text': '🗑️ This message was deleted',
                  'deleted': true,
                });

                // Also remove from actions table if it was an action
                await LocalDatabaseService().deleteAction(message.id);

                // Full clean undo for an action card: drop its durable
                // system-log mirror and reverse the unread badge the card
                // raised on the recipients, so the Activity log, pending
                // counts and every other device agree the action never
                // happened. SQLite-first inside the provider with the
                // Firestore transports fired after — the UI waits on local
                // writes only, never on the network.
                if (isUndoableCard) {
                  final recipients = <String>{
                    _currentTask.createdBy,
                    if ((_currentTask.assignedToUid ?? '').isNotEmpty)
                      _currentTask.assignedToUid!,
                    ..._currentTask.participants,
                  }.where((u) => u.isNotEmpty && u != _currentUserId).toList();
                  await taskProvider.undoActionCard(
                    _currentTask.id,
                    message,
                    recipientUids: recipients,
                  );
                }

                // Update local state - replace with deleted message placeholder
                setState(() {
                  final deletedIndex = _messages.indexWhere(
                    (m) => m.id == message.id,
                  );
                  if (deletedIndex != -1) {
                    _messages[deletedIndex] = MessageModel(
                      id: message.id,
                      taskId: _currentTask.id,
                      senderId: message.senderId,
                      text: '🗑️ This message was deleted',
                      type: MessageType.system,
                      createdAt: message.createdAt,
                    );
                    _rebuildDisplayMessages();
                  }
                });

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Message deleted for everyone'),
                    backgroundColor: Colors.red,
                  ),
                );
              } catch (e) {
                print('[TaskDetail] Error deleting message: $e');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to delete message: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete for Everyone'),
          ),
        ],
      ),
    );
  }

  // ── Multi-select bulk actions ──────────────────────────────────────────

  /// Check if all selected messages are owned by the current user
  bool _selectedMessagesAllOwn() {
    return _selectedMessageIds.every((id) {
      final msg = _messages.firstWhere(
        (m) => m.id == id,
        orElse: () => _emptyMessage,
      );
      return msg.senderId == _currentUserId && msg.type != MessageType.system;
    });
  }

  /// Bulk forward selected messages
  void _bulkForwardMessages() async {
    final selectedMessages = _messages
        .where((m) => _selectedMessageIds.contains(m.id))
        .where((m) => m.type != MessageType.system && !m.isEdited)
        .toList();
    if (selectedMessages.isEmpty) return;

    final targets = await Navigator.push<List<ForwardTarget>>(
      context,
      MaterialPageRoute(
        builder: (_) => ForwardTargetScreen(sourceParentId: _currentTask.id),
      ),
    );
    if (targets == null || targets.isEmpty) return;

    int successCount = 0;
    int failCount = 0;

    for (final target in targets) {
      for (final message in selectedMessages) {
        try {
          final forwardedMessage = MessageModel(
            id: Helpers.generateId(),
            taskId: target.id,
            senderId: _currentUserId,
            text: message.type == MessageType.text
                ? message.text
                : '📎 ${message.fileName ?? 'File'}',
            type: message.type,
            fileUrl: message.fileUrl,
            fileName: message.fileName,
            createdAt: DateTime.now(),
            deliveryMethod: 'in-app',
          );

          if (target.type == 'task') {
            await context.read<TaskProvider>().sendMessage(
              target.id,
              forwardedMessage,
            );
          } else {
            await context.read<SalesProvider>().sendMessage(
              target.id,
              forwardedMessage,
            );
          }
          successCount++;
        } catch (e) {
          failCount++;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _isSelecting = false;
      _selectedMessageIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failCount == 0
              ? 'Forwarded $successCount message${successCount > 1 ? 's' : ''}'
              : 'Forwarded $successCount, failed $failCount',
        ),
        backgroundColor: failCount == 0 ? AppTheme.primaryGreen : Colors.orange,
      ),
    );
  }

  /// Bulk delete selected messages (for me or for everyone)
  void _bulkDeleteMessages({required bool forEveryone}) {
    final count = _selectedMessageIds.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(forEveryone ? 'Delete for Everyone' : 'Delete for Me'),
        content: Text(
          'Delete $count message${count > 1 ? 's' : ''}${forEveryone ? ' for everyone?' : ' for you?'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ids = List<String>.from(_selectedMessageIds);
              int successCount = 0;

              for (final id in ids) {
                final msgIndex = _messages.indexWhere((m) => m.id == id);
                if (msgIndex == -1) continue;
                final message = _messages[msgIndex];

                // Same typed/attachment-only rule as the menus: action,
                // status and edit cards are never bulk-deletable — for me
                // or for everyone.
                if (message.type == MessageType.system ||
                    (message.type == MessageType.text &&
                        Helpers.detectActionType(message.text) != null) ||
                    message.isReplied ||
                    message.isFollowUpDone) {
                  continue;
                }

                try {
                  if (forEveryone) {
                    await context
                        .read<TaskProvider>()
                        .updateMessage(_currentTask.id, id, {
                          'text': '\u{1F5D1}\uFE0F This message was deleted',
                          'deleted': true,
                        });
                    await LocalDatabaseService().deleteAction(id);
                    setState(() {
                      _messages[msgIndex] = MessageModel(
                        id: id,
                        taskId: _currentTask.id,
                        senderId: message.senderId,
                        text: '\u{1F5D1}\uFE0F This message was deleted',
                        type: MessageType.system,
                        createdAt: message.createdAt,
                      );
                    });
                  } else {
                    await context.read<TaskProvider>().updateMessage(
                      _currentTask.id,
                      id,
                      {
                        'deletedFor': FieldValue.arrayUnion([_currentUserId]),
                        'deletedForUid': _currentUserId,
                      },
                    );
                    setState(() {
                      _messages.removeAt(msgIndex);
                    });
                  }
                  successCount++;
                } catch (e) {
                  print('[TaskDetail] Bulk delete error: $e');
                }
              }

              setState(() {
                _rebuildDisplayMessages();
                _isSelecting = false;
                _selectedMessageIds.clear();
              });

              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Deleted $successCount message${successCount > 1 ? 's' : ''}',
                  ),
                  backgroundColor: Colors.red,
                ),
              );
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

  // Placeholder message for orElse
  static final MessageModel _emptyMessage = MessageModel(
    id: '',
    taskId: '',
    senderId: '',
    text: '',
    type: MessageType.system,
    createdAt: DateTime.now(),
  );

  // Show rate task dialog
  void _showRateTaskDialog() {
    showDialog(
      context: context,
      builder: (ctx) => RatingDialog(
        title: 'Rate Task: ${widget.task.title}',
        onRatingSubmitted: (rating) {
          Navigator.pop(ctx);

          // Add the rating
          setState(() {
            _taskRatings.add({
              'rating': rating,
              'comment': null,
              'ratedBy': _currentUserId,
              'ratedAt': DateTime.now(),
              'criteriaRatings': <String, int>{},
            });
          });

          // Add system message to chat
          _messages.add(
            MessageModel(
              id: Helpers.generateId(),
              taskId: _currentTask.id,
              senderId: _currentUserId,
              text: '⭐ ${_currentUserName} rated this task $rating/5 stars',
              type: MessageType.system,
              createdAt: DateTime.now(),
            ),
          );
          _rebuildDisplayMessages();
          _scrollToBottom();

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Task rated $rating/5 stars!'),
              backgroundColor: AppTheme.primaryGreen,
            ),
          );
        },
      ),
    );
  }

  // Show ratings detail screen
  void _showRatingsDetail() {
    final ratings = _taskRatings.map((r) => r['rating'] as int).toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RatingsDetailScreen(
          title: 'Ratings: ${widget.task.title}',
          ratings: ratings,
          ratingDetails: _taskRatings,
          criteriaRatings: _taskCriteriaRatings,
          onAddRating: _showRateTaskDialog,
        ),
      ),
    );
  }

  void _showMoreOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search option
              ListTile(
                leading: const Icon(Icons.search, color: AppTheme.headerGreen),
                title: const Text('Search Messages'),
                onTap: () {
                  Navigator.pop(context);
                  toggleChatSearch();
                },
              ),
              const Divider(height: 1),
              // Share option (chat screenshot)
              ListTile(
                leading: const Icon(Icons.share, color: AppTheme.headerGreen),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(context);
                  shareChatScreenshot();
                },
              ),
              const Divider(height: 1),
              // Export Chat option (full transcript: messages, actions, edits)
              ListTile(
                leading: const Icon(
                  Icons.download_outlined,
                  color: AppTheme.headerGreen,
                ),
                title: const Text('Export Chat'),
                subtitle: const Text(
                  'All messages, actions & edits • CSV / Excel / PDF',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                ),
                onTap: () {
                  Navigator.pop(context);
                  exportChat();
                },
              ),
              const Divider(height: 1),
              // Media & attachments gallery (view + search)
              ListTile(
                leading: const Icon(
                  Icons.perm_media,
                  color: AppTheme.headerGreen,
                ),
                title: const Text('Media & Attachments'),
                subtitle: const Text(
                  'View & search photos, files and voice notes',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showMediaGallery(context);
                },
              ),
              const Divider(height: 1),
              // Ratings (view history + add a rating) — combined
              ListTile(
                leading: const Icon(Icons.star, color: Colors.amber),
                title: const Text('Ratings'),
                subtitle: const Text(
                  'View history & add a rating',
                  style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                ),
                trailing: _taskRatings.isNotEmpty
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.headerGreen,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_taskRatings.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _showRatingsDetail();
                },
              ),
              // Delete Task option (only for creator)
              if (_isTaskCreator()) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text(
                    'Delete Task',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _showDeleteTaskWarning();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Export chat & screenshot share now live in DetailChatMenuMixin.

  // ── Outside share (WhatsApp / SMS for people without the app) ──────────

  /// A delete placeholder carries nothing worth sending, and action/status/
  /// edit cards are NOT shareable off-app either — same isActionOrEdit rule
  /// as Forward/Delete, so only typed messages and attachments can leave
  /// WhatWorks. The keyword check applies to MessageType.text only, so a
  /// file named e.g. payment_receipt.pdf stays shareable.
  bool _isShareableMessage(MessageModel m) =>
      !m.deleted &&
      m.text.trim().isNotEmpty &&
      !m.text.contains('This message was deleted') &&
      m.type != MessageType.system &&
      !(m.type == MessageType.text && Helpers.detectActionType(m.text) != null);

  /// Flatten one chat message for the share body: media travels as its 📎 label
  /// (the binary itself is shared from the Media gallery), a reply keeps a short
  /// quote, an edit keeps its suffix.
  ShareEntry _shareEntryOf(MessageModel m) {
    var text = m.text.trim();
    if ((m.type == MessageType.image || m.type == MessageType.file) &&
        (m.fileName?.isNotEmpty ?? false)) {
      final label = '📎 ${m.fileName}';
      text = text.isEmpty ? label : '$label — $text';
    } else if (m.type == MessageType.voice) {
      final dur = m.duration != null ? ' ${m.duration}s' : '';
      text = text.isEmpty ? '🎤 Voice note$dur' : text;
    }
    final quoted = m.replyToMessageText?.trim() ?? '';
    if (quoted.isNotEmpty) {
      final snippet = quoted.length > 40
          ? '${quoted.substring(0, 40)}…'
          : quoted;
      final who = m.replyToMessageSender?.trim() ?? '';
      text = '↩︎ ${who.isEmpty ? '' : '$who: '}$snippet\n$text';
    }
    if (m.isEdited) text = '$text (edited)';
    return ShareEntry.of(
      senderName: _getSenderName(m.senderId),
      timeLabel: DateFormat('dd/MM hh:mm a').format(m.createdAt),
      text: text,
    );
  }

  /// The 5 most recent visible posts, oldest → newest. `_displayMessages` is the
  /// reversed (newest-first) view the ListView uses, so take from the front and
  /// flip back — no extra query needed.
  List<MessageModel> _lastFiveShareMessages() => _displayMessages
      .where(_isShareableMessage)
      .take(5)
      .toList()
      .reversed
      .toList();

  /// Item header + entries, handed to the shared service so Task, Sales and CRM
  /// compose identical output.
  OutsideSharePayload _buildSharePayload(List<MessageModel> messages) {
    return OutsideSharePayload(
      itemLabel: 'Task',
      title: _currentTask.title,
      displayId: _currentTask.displayId,
      byName: _getUserNameById(_currentTask.createdBy),
      toName: _currentTask.assignedTo,
      deadlineLabel: _currentTask.deadline == null
          ? null
          : Helpers.formatDeadlineBadge(_currentTask.deadline),
      statusLine:
          '${_getTaskStatus()} · Progress ${(_currentTask.progress * 100).toInt()}%',
      entries: messages.map(_shareEntryOf).toList(),
      recipientName: _currentTask.assignedTo,
      recipientPhone: _currentTask.assignedToPhone,
      replyPhone: _currentUserPhone,
      themeColor: AppTheme.primaryGreen,
    );
  }

  /// Shares one post ([tapped]) or the last five, then logs it in the chat so
  /// both sides can see it went out. senderId is the current user, so the card
  /// renders right-aligned like every other action by me.
  Future<void> _shareOutside({MessageModel? tapped}) async {
    // Action/status/edit cards never leave the app — same rule as
    // Forward/Delete. The menu gate hides the tiles, this guard makes the
    // rule unbypassable (the last-5 trail is already filtered through
    // _isShareableMessage).
    if (tapped != null && !_isShareableMessage(tapped)) return;
    final messages = tapped != null
        ? <MessageModel>[tapped]
        : _lastFiveShareMessages();
    if (messages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nothing to share yet')));
      return;
    }
    final result = await showOutsideShareSheet(
      context,
      payload: _buildSharePayload(messages),
    );
    if (result == null || !mounted) return; // user backed out
    if (!result.success) return; // the sheet already reported why
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Shared via ${result.channelLabel} with ${result.recipientName}',
        ),
      ),
    );
    await _sendSystemMessage(
      OutsideShareService().systemMessageFor(
        result: result,
        byName: _currentUserName,
        atLabel: Helpers.formatDateTime(DateTime.now()),
      ),
    );
  }

  // Show delete task warning dialog
  void _showDeleteTaskWarning() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.red, size: 28),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Delete Task Permanently?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This action cannot be undone. Are you sure you want to delete:',
              style: TextStyle(fontSize: 14, color: AppTheme.secondaryText),
            ),
            const SizedBox(height: 12),
            // Task info card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentTask.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Created: ${Helpers.formatDate(_currentTask.createdAt)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.lightText,
                    ),
                  ),
                  if (_currentTask.deadline != null)
                    Text(
                      'Deadline: ${Helpers.formatDate(_currentTask.deadline!)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.lightText,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Warning points
            const Text(
              'This task will be deleted and hidden from all participants:',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 8),
            _buildWarningPoint('Task will be hidden from normal views'),
            _buildWarningPoint(
              'Can be restored within 30 days from Deleted filter',
            ),
            _buildWarningPoint('Auto-purged after 30 days'),
          ],
        ),
        actions: [
          // Cancel button
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(fontSize: 14, color: AppTheme.secondaryText),
            ),
          ),
          // Delete button
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteTask();
            },
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('Delete Task'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }

  // Build warning point item
  Widget _buildWarningPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: TextStyle(color: Colors.red.withOpacity(0.7), fontSize: 13),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Delete task from Firebase
  Future<void> _deleteTask() async {
    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Deleting task...'),
                ],
              ),
            ),
          ),
        ),
      );

      // Delete task via provider (SQLite-first, Firestore fire-and-forget)
      await context.read<TaskProvider>().deleteTask(_currentTask.id);

      // Close loading dialog
      if (mounted) {
        Navigator.pop(context);

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Task deleted successfully'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );

        // Navigate back to home screen
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) {
        Navigator.pop(context);

        // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete task: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // In-document deep search now lives in DetailChatMenuMixin.

  // Open document viewer (full content view)
  void _openDocumentViewer(MessageModel message) async {
    if (message.searchableContent != null) {
      searchInsideDocument(message);
      return;
    }
    // Check if file is still uploading
    if (message.fileUrl == 'pending') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is still uploading, please wait...'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    if (message.fileUrl == null || message.fileUrl!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File URL not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    try {
      // Check local cache first
      String? localPath;
      if (message.fileName != null) {
        localPath = await chatLocalPathFor(message);
      }

      if (localPath != null && await File(localPath).exists()) {
        // Open from local cache via content:// URI (file:// URIs throw
        // FileUriExposedException on Android 7+)
        final result = await OpenFilex.open(localPath);
        if (result.type != ResultType.done) {
          _showCannotOpenSnackBar(message);
        }
      } else {
        // Download to local cache first, then open
        if (message.fileName != null) {
          final storageService = StorageService();
          final downloaded = await storageService.downloadAndCacheAttachment(
            _currentTask.id,
            message.id,
            message.fileName!,
            message.fileUrl!,
            _currentUserId,
            collection: 'tasks',
            senderId: message.senderId,
            participants: chatAllParticipants,
          );
          if (downloaded != null && await File(downloaded).exists()) {
            final result = await OpenFilex.open(downloaded);
            if (result.type != ResultType.done) {
              _showCannotOpenSnackBar(message);
            }
            return;
          }
        }
        // No local copy and download failed — never fall back to opening
        // the raw Firebase URL in a browser.
        _showCannotOpenSnackBar(message);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showCannotOpenSnackBar(MessageModel message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Cannot open ${message.fileName ?? 'file'} — download failed, please try again',
        ),
        backgroundColor: Colors.red,
      ),
    );
  }
}
