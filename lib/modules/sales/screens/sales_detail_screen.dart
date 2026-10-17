import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/enquiry.dart';
import '../providers/sales_provider.dart';
import 'sales_milestone_settings_screen.dart';
import 'assignee_sales_screen.dart';
import '../../../models/message.dart';
import '../../../models/system_log.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/storage_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/firebase_service.dart';
import '../../../utils/constants.dart';
import '../../../widgets/card_widgets.dart';
import '../../../utils/paywall_constants.dart';
import '../../../utils/helpers.dart';
import '../../../widgets/recurrence_picker.dart';
import '../../../services/sequential_id_service.dart';
import '../../../services/contact_picker_service.dart';
import '../../../services/avatar_cache_service.dart';
import '../../../widgets/app_avatar.dart';
import '../../../widgets/shared_detail_widgets.dart';
import '../../../services/customer_comms_service.dart';
import '../../../services/external_notification_service.dart';
import '../../shared/customer_info.dart';
import '../../../widgets/card_action_icons.dart';
import '../../../widgets/media_gallery_sheet.dart';
import '../../../widgets/swipe_to_reply.dart';
import '../../../widgets/cash_action_dialog.dart';
import '../../../widgets/cash_statement_sheet.dart';
import '../../../widgets/schedule_call_dialog.dart';
import '../../../services/notification_service.dart';
import '../../../widgets/detail_chat/detail_chat_bubbles.dart';
import '../../../widgets/detail_chat/detail_chat_attachments.dart';
import '../../../widgets/detail_chat/detail_chat_menu.dart';
import '../../../widgets/detail_chat/detail_chat_emoji.dart';
import '../../../widgets/detail_chat/detail_chat_mention.dart';
import '../../../widgets/detail_chat/detail_chat_plumbing.dart';
import '../../../services/item_links_service.dart';
import '../../../services/outside_share_service.dart';
import '../../../widgets/linked_items_chips.dart';
import '../../../widgets/link_picker_sheet.dart';
import '../../../widgets/outside_share_sheet.dart';
import '../../../screens/forward/forward_target_screen.dart';
import '../../../providers/task_provider.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/base_module_service.dart';
import '../../shared/module_config.dart';
import '../../crm/providers/crm_provider.dart';

class SalesDetailScreen extends StatefulWidget {
  final EnquiryModel enquiry;

  /// Required — a missing config used to silently default to Sales mode,
  /// which wrote CRM records into Sales storage.
  final ModuleConfig moduleConfig;

  /// When set (e.g. from an Actions tab row), the chat auto-scrolls to this
  /// message on open — parity with TaskDetailScreen.scrollToMessageId.
  final String? scrollToMessageId;

  const SalesDetailScreen({
    super.key,
    required this.enquiry,
    required this.moduleConfig,
    this.scrollToMessageId,
  });

  @override
  State<SalesDetailScreen> createState() => _SalesDetailScreenState();
}

class _SalesDetailScreenState extends State<SalesDetailScreen>
    with
        DetailChatBubblesMixin,
        DetailChatAttachmentsMixin,
        DetailChatPlumbingMixin,
        DetailChatMenuMixin {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode(); // Draft: keyboard ready
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showScrollToBottom = ValueNotifier(false);
  final ValueNotifier<bool> _showScrollToTop = ValueNotifier(false);
  final ValueNotifier<int> _newMessageCount = ValueNotifier(0);
  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, double> _uploadProgress = {};

  /// Module config (resolved from widget param or defaults to sales).
  ModuleConfig get _config => widget.moduleConfig;
  bool get _isCrm => _config.type == ModuleType.crm;

  /// Read the module provider (non-listening).
  BaseModuleProvider _readProvider(BuildContext ctx) =>
      _isCrm ? ctx.read<CrmProvider>() : ctx.read<SalesProvider>();

  /// Watch the module provider (listening for rebuilds).
  BaseModuleProvider _watchProvider(BuildContext ctx) =>
      _isCrm ? ctx.watch<CrmProvider>() : ctx.watch<SalesProvider>();

  /// Theme color for the module.
  Color get _themeColor => _config.themeColor;

  /// Fill for the detail card's Progress bar. Same rule as the card's
  /// [CardProgressStack]: the shared 3-color deadline timing, but the calm
  /// on-track green is swapped for the module brand color (Sales blue /
  /// CRM mint) so the bar matches the AppBar. Amber/red lateness is never
  /// masked.
  Color get _progressBarColor {
    final base =
        _enquiry.progress >= 1.0 ||
            _enquiry.isClosed ||
            !_config.isOpenStatus(_enquiry.status)
        ? AppTheme.onTime
        : deadlineColorFor(_enquiry.createdAt, _enquiry.deadline);
    return base == AppTheme.onTime ? _themeColor : base;
  }

  /// Module service for direct Firestore operations.
  BaseModuleService get _moduleService => _readProvider(context).service;

  late EnquiryModel _enquiry;

  /// Fixed id of the synthesized "Card created" activity entry — never
  /// persisted, never backfilled (parity with the Task module's log).
  static const String _createdEntryId = '__enquiry_created__';
  List<MessageModel> _messages = []; // Chronological (oldest first)
  List<MessageModel> _displayMessages =
      []; // Reversed (newest first) for reverse ListView

  void _rebuildDisplayMessages() {
    // Always sort by createdAt ascending, then reverse for display
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _displayMessages = _messages.reversed.toList();
  }

  StreamSubscription<List<MessageModel>>? _messageSub;
  bool _initialScrollDone = false; // Prevents double scroll on stream emissions
  bool _isScrollingToMessage =
      false; // Guard flag: prevents stream from resetting _messages during scroll-to-target
  // Range of _displayMessages indices the lazy ListView rendered LAST frame.
  // _scrollToMessageById uses it to pick a DIRECTION and step toward a target
  // whose widget is not built yet (a far off-screen card in reverse:true).
  // Parity with task_detail_screen.dart.
  int _builtMinDisplayIndex = 0;
  int _builtMaxDisplayIndex = 0;
  bool _coarseLeapDone = false;
  // Transient highlight band on the card a notification tap jumps to, so the
  // referenced action is easy to spot once the scroll lands. Auto-clears.
  String? _highlightedMessageId;
  Timer? _highlightClearTimer;
  bool _isUserScrolling =
      false; // True while user is actively scrolling (defers stream setState)
  bool _pendingStreamRefresh =
      false; // True when stream fired during user scroll (deferred)
  bool _isSending = false;
  // Milestones (Sales Pipeline) start collapsed — matches Task detail's
  // _showMilestonesInline default so the checklist never crowds the chat on
  // open; the header row (progress + count) always shows, tap to expand.
  bool _showMilestones = false;
  bool _draftDialogDismissed = false;
  // Activity log starts collapsed — fully expanded it fills the screen and
  // pushes the chat out of view; tap the header row to open it
  bool _activityExpanded = false;
  String? _selectedActivityFilter;
  bool _isLoadingOlderMessages = false;

  bool _hasLoadedAllOlderMessages = false;

  // Safety net for the deferred stream refresh: if a ScrollEnd never arrives
  // (interrupted animation, rebuild mid-scroll) the pending refresh still
  // lands instead of leaving the chat frozen until the screen is reopened.
  Timer? _pendingRefreshTimer;

  // Track whether text field has content (for mic/send toggle)
  final ValueNotifier<bool> _hasText = ValueNotifier(false);

  // WhatsApp-style @mention picker for the chat composer (many-assignee chats).
  late final ChatMentionController _mention = ChatMentionController(
    candidatesProvider: _mentionCandidates,
  );

  /// Display names eligible for @mention — everyone on this enquiry/CRM record
  /// (assignees and the creator), de-duplicated and sorted.
  List<String> _mentionCandidates() {
    final names = <String>{};
    for (final n in _enquiry.assigneeNames) {
      final s = n.trim();
      if (s.isNotEmpty) names.add(s);
    }
    final assigned = _enquiry.assignedTo.trim();
    if (assigned.isNotEmpty) names.add(assigned);
    final creator = (_enquiry.createdByName ?? '').trim();
    if (creator.isNotEmpty) names.add(creator);
    final list = names.toList()..sort();
    return list;
  }

  // ── Send Later (in-app only) ──────────────────────────────────────
  // Scheduled chat messages are held in a local SharedPreferences outbox (no
  // background / push delivery). While this enquiry's chat is open a periodic
  // timer flushes ones that come due; on re-open they flush on load — the
  // message finally goes out through the normal send path at/after its time.
  static const String _scheduledOutboxKey = 'scheduled_messages_outbox';
  final List<MessageModel> _scheduledMessages = [];
  Timer? _scheduledFlushTimer;

  // WhatsApp-style reply state. The shared bubble renderer already draws
  // quoted replies; Sales simply had no way to create one.
  MessageModel? _replyingToMessage;

  // Durable action log (B4, parity with Task): rows recovered from the
  // enquiry's system_logs subcollection via SQLite, merged into the Activity
  // section so the history survives chat retention and a fresh install.
  List<SystemLogModel> _recoveredLogs = [];
  StreamSubscription<List<SystemLogModel>>? _systemLogSub;
  bool _systemLogBackfillDone = false;

  String get _currentUserId =>
      context.read<AuthProvider>().userModel?.uid ?? '';
  String get _currentUserName =>
      context.read<AuthProvider>().userModel?.name ?? 'User';

  @override
  void initState() {
    super.initState();
    _enquiry = widget.enquiry;
    _loadCustomFieldLabels();
    // Opening a chat counts as navigating away from the list — drop any
    // leftover 3-dot menu filter so going back shows the unfiltered view.
    _readProvider(context).setStatusFilter('All');
    _readProvider(context).setSortBy('Last Action');
    // Instant-open parity with the Task module: paint any already-cached
    // messages on the FIRST frame before the async SQLite stream resolves.
    _seedMessagesFromCache();
    _subscribeToMessages();
    _scrollController.addListener(_onScroll);
    // Listen to text input to toggle the mic/send button. A controller
    // listener (not TextField.onChanged) so programmatic insertions -- e.g.
    // the emoji picker -- flip the button too.
    _messageController.addListener(() {
      final hasText = _messageController.text.trim().isNotEmpty;
      if (hasText != _hasText.value) {
        _hasText.value = hasText;
      }
      // Keep the @mention dropdown in sync with the caret / typed text.
      _mention.updateFrom(_messageController.value);
    });
    // Background server cleanup (receipts backfill + minimal-server deletes)
    scheduleChatCleanupSweep(context.read<AuthProvider>().effectivePlanType);
    // Reset unread count when opening the chat
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetMyUnreadCount();
    });
    // Check connectivity
    startConnectivityMonitor();
    // Load + start flushing this enquiry's scheduled ("Send Later") messages.
    _initScheduledMessages();

    // Draft stage: keyboard + cursor ready on the message box
    _focusMessageInputIfDraft();
  }

  /// New enquiry (draft): put the keyboard/cursor on the message box so the
  /// first message can be typed straight away. Mirrors the Task module's
  /// draft behaviour so a freshly created card is ready for input.
  void _focusMessageInputIfDraft() {
    if (!_isDraftEnquiry) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _messageFocusNode.requestFocus();
    });
  }

  void _onScroll() {
    // NOTE: _isUserScrolling is set from ScrollStartNotification (drag only)
    // in _buildChatArea — flagging here would also mark programmatic scrolls
    // (scroll-to-bottom, activity jumps) as user scrolls and defer updates.
    if (_scrollController.hasClients) {
      // With reverse:true, maxScrollExtent = TOP (oldest), 0 = BOTTOM (newest)
      final maxScrollExtent = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      final isNearBottom =
          currentScroll < 300; // Near position 0 = newest messages
      _showScrollToBottom.value = !isNearBottom;
      // Reset unread count when user scrolls to bottom
      if (isNearBottom && _newMessageCount.value > 0) {
        _newMessageCount.value = 0;
      }
      // Show/hide scroll to top button
      final isNearTop = currentScroll > maxScrollExtent - 200;
      _showScrollToTop.value = !isNearTop;
      // Load older messages when scrolled near top (maxScrollExtent)
      if (isNearTop &&
          !_isLoadingOlderMessages &&
          !_hasLoadedAllOlderMessages) {
        _loadOlderMessages();
      }
    }
  }

  // (No end-of-history hint: the app cannot truly detect an offline gap, so a
  //  'older messages purged' pill was not credible and has been removed.)

  void _loadOlderMessages() async {
    if (_isLoadingOlderMessages || _hasLoadedAllOlderMessages) return;
    if (_messages.isEmpty) {
      _hasLoadedAllOlderMessages = true;
      return;
    }
    _isLoadingOlderMessages = true;
    final beforeCount = _messages.length;
    // Oldest message currently loaded (list is kept sorted ascending).
    final oldest = _messages
        .map((m) => m.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    try {
      // Additive pagination (parity with the Task module): older messages are
      // MERGED into the existing list. Replacing the list with the provider's
      // smaller cache shrank it mid-scroll and stranded the chat at the top.
      var older = await LocalDatabaseService().getMessagesBefore(
        _enquiry.id,
        oldest,
        limit: 30,
      );
      if (older.isEmpty) {
        final fromServer = await _moduleService.getOlderMessages(
          _enquiry.id,
          oldest,
        );
        if (fromServer.isNotEmpty) {
          await LocalDatabaseService().saveMessages(
            fromServer,
            parentType: 'enquiry',
          );
          older = fromServer;
        }
      }
      if (mounted) {
        setState(() {
          final existingIds = _messages.map((m) => m.id).toSet();
          final fresh = older
              .where((m) => !existingIds.contains(m.id))
              .toList();
          if (fresh.isNotEmpty) {
            _messages = [...fresh, ..._messages]
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _rebuildDisplayMessages();
          }
        });
        // If no new messages were loaded, we've reached the end
        if (_messages.length <= beforeCount) {
          _hasLoadedAllOlderMessages = true;
        }
      }
    } catch (_) {
      // Non-fatal: allow retry on the next scroll to the top.
    } finally {
      _isLoadingOlderMessages = false;
    }
  }

  // Re-query SQLite after deferred stream update (called when user stops scrolling)
  void _refreshFromStream() async {
    final allMsgs = await LocalDatabaseService().getMessages(_enquiry.id);
    if (!mounted || allMsgs.isEmpty) return;
    // Parity with the Task module: hide messages I deleted for myself.
    final msgs = allMsgs
        .where((m) => !m.deletedFor.contains(_currentUserId))
        .toList();
    setState(() {
      // Set-based id lookup instead of nested .any() scans — the O(n²)
      // version caused visible scroll jank on long chats (parity with task).
      final dbIds = msgs.map((p) => p.id).toSet();
      final pendingMessages = _messages
          .where((m) => !dbIds.contains(m.id))
          .toList();
      _messages = List<MessageModel>.from(msgs)..addAll(pendingMessages);
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _rebuildDisplayMessages();
    });
  }

  /// Instant-open parity with the Task module. The UI reads from SQLite via the
  /// async [LocalDatabaseService.watchMessages] stream, whose FIRST emission is
  /// an `await getMessages(...)` — so without a seed the very first frame builds
  /// with an empty `_messages` list, the enquiry details card fills the viewport,
  /// and the chat visibly jumps in when the query resolves. When the provider
  /// already holds this enquiry's messages in memory (the Sales/CRM list cached
  /// them for the card action-icon strips, or the chat was opened before) paint
  /// them synchronously here so the first frame shows the chat at the bottom.
  /// The stream then refines against authoritative SQLite data as usual.
  void _seedMessagesFromCache() {
    // A targeted notification/Actions jump manages its own scroll target.
    if (widget.scrollToMessageId != null) return;
    final cached = _readProvider(context).getCachedMessages(_enquiry.id);
    if (cached == null || cached.isEmpty) return;
    final visible = cached
        .where((m) => !m.deletedFor.contains(_currentUserId))
        .toList();
    if (visible.isEmpty) return;
    _messages = visible;
    _rebuildDisplayMessages();
    // Treat the seed as the initial scroll so the first stream emission that
    // matches it is recognised as already-displayed (isSameData) instead of
    // re-triggering the empty→loaded transition.
    _initialScrollDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom(immediate: true);
    });
  }

  void _subscribeToMessages() {
    // Start background syncs (Firestore -> SQLite).
    //
    // Module-aware on purpose. startEnquiryMessageSync hardcodes the
    // sales_enquiries collection, so a CRM record listened to a document that
    // never existed and its chat only updated because the list screen's
    // prefetch had already attached the correct listener.
    FirebaseService().startModuleMessageSync(
      _enquiry.id,
      _config.firestoreCollection,
    );
    // B9: keep this card's own document live. Without it a chat opened from a
    // deep link (notification tap, forward target, linked item) renders the
    // header from whatever stale SQLite row it was navigated in with.
    FirebaseService().startModuleDetailSync(
      _enquiry.id,
      _config.firestoreCollection,
      tableName: _config.enquiriesTableName,
    );
    // B4: durable action log feeding the Activity section below.
    FirebaseService().startModuleSystemLogSync(
      _enquiry.id,
      _config.firestoreCollection,
    );
    _systemLogSub?.cancel();
    _systemLogSub = LocalDatabaseService().watchSystemLogs(_enquiry.id).listen((
      logs,
    ) {
      if (!mounted) return;
      setState(() => _recoveredLogs = logs);
      _backfillSystemLogs();
    });

    // Subscribe to SQLite-backed stream
    _messageSub = LocalDatabaseService().watchMessages(_enquiry.id).listen((
      msgs,
    ) {
      if (mounted) {
        // Set-based id lookups — the old nested .any() scans were O(n²) on
        // every stream emission and froze scrolling on long chats.
        // Parity with the Task module: hide messages I deleted for myself.
        msgs = msgs
            .where((m) => !m.deletedFor.contains(_currentUserId))
            .toList();
        final existingIds = _messages.map((old) => old.id).toSet();

        // Content-aware signature — the ids+length dedup below treated an
        // in-place update as "same data" and returned early, so an Approve /
        // Reply / Mark Done / Delivered tap (and a remote completion) never
        // refreshed the card. Folding the flags that drive the action chips
        // (done / replied) into the comparison keeps it O(n) with no per-tap
        // full rebuild while letting real state changes through.
        final signature = {
          for (final m in msgs)
            '${m.id}:${m.isFollowUpDone ? 1 : 0}${m.isReplied ? 1 : 0}',
        };
        final currentSignature = {
          for (final m in _messages)
            '${m.id}:${m.isFollowUpDone ? 1 : 0}${m.isReplied ? 1 : 0}',
        };

        // Skip if data is identical to what's already displayed (prevents double-scroll)
        final isSameData =
            msgs.length == _messages.length &&
            msgs.every((m) => existingIds.contains(m.id)) &&
            signature.length == currentSignature.length &&
            signature.containsAll(currentSignature);
        if (isSameData && _initialScrollDone) return;

        // Count new messages from others before updating. System cards are
        // included so an incoming action (query / follow-up / meeting /
        // visit …) raises the WhatsApp-style down-arrow instead of the view
        // shifting under a scrolled-up reader (Task module parity). Own
        // sends stay excluded.
        final newFromOthers = msgs
            .where(
              (m) =>
                  !existingIds.contains(m.id) && m.senderId != _currentUserId,
            )
            .length;

        // Check if user is at bottom before updating (reverse:true: bottom = position 0)
        final isAtBottom =
            !_scrollController.hasClients ||
            _scrollController.position.pixels <= 10;

        // A stream event must NOT rebuild the list or re-run the scroll
        // branches while a scroll-to-message is settling: the jump starts at
        // pixels≈0 so isAtBottom reads TRUE mid-animation, and the old
        // unguarded _scrollToBottom() yanked the view back to the latest
        // message (notification tap "did nothing" until a manual scroll
        // moved pixels off 0). Same guard structure as Task's stream handler.
        if (!_isScrollingToMessage) {
          if (_isUserScrolling) {
            _pendingStreamRefresh = true;
            // Arm the fallback once — if ScrollEnd never fires the deferred
            // refresh still lands a couple of seconds later.
            _pendingRefreshTimer ??= Timer(const Duration(seconds: 2), () {
              _pendingRefreshTimer = null;
              if (_pendingStreamRefresh) {
                _pendingStreamRefresh = false;
                _isUserScrolling = false;
                _refreshFromStream();
              }
            });
          } else {
            setState(() {
              // Preserve any optimistic messages not yet in SQLite
              final dbIds = msgs.map((p) => p.id).toSet();
              final pendingMessages = _messages
                  .where((m) => !dbIds.contains(m.id))
                  .toList();
              _messages = List<MessageModel>.from(msgs)
                ..addAll(pendingMessages);
              _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
              _rebuildDisplayMessages();
            });
          }
        }

        // Mark messages as read when chat is open
        markChatMessagesAsRead(msgs);

        if (!_initialScrollDone) {
          // First scroll ever — scroll to bottom (or target message when
          // navigated here from an Actions row — Task module parity)
          _initialScrollDone = true;
          if (widget.scrollToMessageId != null) {
            _scrollToMessageById(widget.scrollToMessageId!);
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollToBottom(immediate: true);
            });
          }
          _newMessageCount.value = 0;
        } else if (widget.scrollToMessageId != null && !_isScrollingToMessage) {
          // Stream re-emitted while still settling on the target message
          _scrollToMessageById(widget.scrollToMessageId!);
        } else if (isAtBottom && !_isScrollingToMessage) {
          _scrollToBottom();
          _newMessageCount.value = 0;
        } else if (newFromOthers > 0) {
          // User is NOT at bottom — preserve scroll, increment unread count
          _newMessageCount.value += newFromOthers;
        }
      }
    });
  }

  void _scrollToBottom({bool immediate = false}) {
    void _doScroll() {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        // ListView hasn't built yet — retry on next frame
        WidgetsBinding.instance.addPostFrameCallback((_) => _doScroll());
        return;
      }
      // With reverse:true ListView, bottom = scroll position 0
      _scrollController.jumpTo(0);
    }

    if (immediate) {
      _doScroll();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _doScroll());
    }
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
    // (parity with TaskDetailScreen's scroll-to-message strategy)
    if (retryCount == 0) {
      _isScrollingToMessage = true;
      _builtMinDisplayIndex = 0;
      _builtMaxDisplayIndex = 0;
      _coarseLeapDone = false;
      _highlightMessageCard(messageId);
    }

    // Find the message index in the list
    final messageIndex = _messages.indexWhere((m) => m.id == messageId);
    if (messageIndex == -1) {
      _isScrollingToMessage = false;
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
    // forced the list to render more. Instead, wait for layout then step the
    // viewport toward the real built-index window until the target gets a
    // context (the fast path above then locks on). Bounded so it can't spin.
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
    if (displayIndex == -1) {
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
    // display index against the window the builder rendered LAST frame: step
    // up if it's beyond the top, back down if below. Built-index feedback —
    // not a fixed-height guess — is what makes this land exactly.
    double next = position.pixels;
    if (displayIndex > _builtMaxDisplayIndex) {
      next = position.pixels + viewport * 0.9;
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
  /// sum of the (approximate) heights of every item newer than it, plus the
  /// enquiry details card that sits above everything. Only a first-hop
  /// accelerant — the built-index walk corrects any error.
  double _coarseOffsetFor(int displayIndex) {
    double est = 0;
    for (int i = displayIndex - 1; i >= 0; i--) {
      final msg = _displayMessages[i];
      if (msg.type == MessageType.system) {
        est += 50;
      } else if (msg.type == MessageType.image) {
        est += 200;
      } else {
        est += msg.isReplied || msg.type != MessageType.text ? 120 : 70;
      }
      if (i > 0 &&
          !_isSameDay(msg.createdAt, _displayMessages[i - 1].createdAt)) {
        est += 35; // Date separator
      }
    }
    est += 200; // Enquiry details card at the very top of the scroll range
    return est;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _getSenderName(String senderId) {
    if (senderId == _currentUserId) {
      return context.read<AuthProvider>().userModel?.name ?? 'Me';
    }
    if (senderId == _enquiry.assignedToUid) return _enquiry.assignedTo;
    if (senderId == _enquiry.createdBy)
      return _enquiry.createdByName ?? 'Unknown';
    // Multi-assignee co-participants: index-aligned UID→name lookup
    final uids = _enquiry.assigneeUids;
    final names = _enquiry.assigneeNames;
    if (uids.length == names.length) {
      for (int i = 0; i < uids.length; i++) {
        if (uids[i] == senderId && names[i].trim().isNotEmpty) {
          return names[i].trim();
        }
      }
    }
    return 'Unknown';
  }

  /// Display label for a chat actor: your own bubbles/cards read "Me"
  /// (Task-module parity), everyone else keeps their resolved name. Only for
  /// on-screen chat attribution - the outside-share header and seen-by row
  /// still use the real name via _getSenderName.
  String _chatActorName(String senderId) =>
      senderId == _currentUserId ? 'Me' : _getSenderName(senderId);

  /// Returns true if chat has only 2 participants (creator + assignee).
  bool _isTwoParticipantChat() {
    final creatorUid = _enquiry.createdBy;
    final assigneeUid = _enquiry.assignedToUid ?? '';
    if (assigneeUid.isEmpty || assigneeUid == creatorUid) return true;
    // Check multi-assignee: if there are extra assignees beyond the first
    final extraAssigneeUids = _enquiry.assigneeUids
        .where(
          (uid) => uid.isNotEmpty && uid != assigneeUid && uid != creatorUid,
        )
        .toList();
    return extraAssigneeUids.isEmpty;
  }

  /// Mark messages as read and delivered when chat is opened / new messages arrive.
  /// (Shared logic lives in DetailChatPlumbingMixin.)

  /// Reset current user's unread count to 0 when opening the chat.
  void _resetMyUnreadCount() {
    _readProvider(context).resetMyUnreadCount(_enquiry.id, _currentUserId);
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
          onPressed: () {
            _readProvider(context).sendMessage(_enquiry.id, message);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _highlightClearTimer?.cancel();
    _messageSub?.cancel();
    _systemLogSub?.cancel();
    _pendingRefreshTimer?.cancel();
    _scheduledFlushTimer?.cancel();
    _cardSheetVersion.dispose();
    // Stop background sync
    FirebaseService().stopModuleMessageSync(
      _enquiry.id,
      _config.firestoreCollection,
    );
    FirebaseService().stopModuleDetailSync(
      _enquiry.id,
      _config.firestoreCollection,
    );
    FirebaseService().stopModuleSystemLogSync(
      _enquiry.id,
      _config.firestoreCollection,
    );
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    _showScrollToBottom.dispose();
    _showScrollToTop.dispose();
    _newMessageCount.dispose();
    disposeDetailChatBubbles();
    disposeDetailChatAttachments();
    // Stop the 15s connectivity monitor started in initState. Without this the
    // periodic Timer (and its leaked State) outlives the screen — one leaked
    // timer per Sales/CRM chat opened, which accumulates and saturates the main
    // isolate over a session. Task detail already tears this down; this restores
    // parity.
    disposeDetailChatPlumbing();
    disposeDetailChatMenu();
    _hasText.dispose();
    _mention.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final salesProvider = _watchProvider(context);
    final updated = salesProvider.enquiries
        .where((e) => e.id == _enquiry.id)
        .firstOrNull;
    if (updated != null) _enquiry = updated;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        // Always the full-name stacked view — the initials variant and its
        // tap-to-expand toggle were dropped (Task-module parity).
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _enquiry.title.isNotEmpty
                  ? _enquiry.title
                  : (_enquiry.clientName.isNotEmpty
                        ? _enquiry.clientName
                        : 'New Enquiry'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // Stacked: each full name gets the whole subtitle width
            // instead of sharing one cramped row.
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // By — creator is always an app user (filled dot); skipped on
                // the "Me" line.
                Builder(
                  builder: (_) {
                    final byIsMe = _enquiry.createdBy == _currentUserId;
                    return Row(
                      children: [
                        Flexible(
                          child: Text(
                            _participantLine(
                              'By',
                              _enquiry.createdByName ?? '',
                            ),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // On-app badge trails the name (creator always on →
                        // filled dot); skipped on the "Me" line.
                        if (!byIsMe &&
                            _enquiry.createdBy.trim().isNotEmpty) ...[
                          const SizedBox(width: 4),
                          const OnAppDot(onApp: true),
                        ],
                      ],
                    );
                  },
                ),
                // To — filled dot once the assignee has an app UID; hollow
                // ring while phone-only. Skipped on "Me"/blank.
                Builder(
                  builder: (_) {
                    final toUid = (_enquiry.assignedToUid ?? '').trim();
                    final toIsMe =
                        toUid == _currentUserId ||
                        _enquiry.assignedTo.trim().toLowerCase() == 'me';
                    final toKnown = _enquiry.assignedTo.trim().isNotEmpty;
                    final toOnApp = toUid.isNotEmpty;
                    return Row(
                      children: [
                        Flexible(
                          child: Text(
                            _participantLine(
                              'To',
                              _enquiry.assignedTo,
                              forceMe: toIsMe,
                            ),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // On-app badge trails the name: filled once the assignee
                        // has an app UID, hollow ring while phone-only. Skipped
                        // on "Me"/blank.
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
          ],
        ),
        actions: [
          // Details card — read-only summary (Task-module parity)
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _openEnquiryCardSheet(),
            tooltip: '${_config.itemName} Details',
          ),
          // Call icon: list users in the enquiry with numbers (copy or dial)
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () => _showEnquiryCallSheet(),
            tooltip: 'Call',
          ),
          // More Options (3-dot menu)
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showEnquiryMenu(context),
          ),
        ],
      ),
      // Screenshot boundary for the Share (chat screenshot) menu action —
      // parity with Task Detail's RepaintBoundary-wrapped chat body.
      body: RepaintBoundary(
        key: chatScreenshotKey,
        child: Column(
          children: [
            // Search bar (when active) — DetailChatMenuMixin
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
            Expanded(child: _buildChatArea(salesProvider)),
            _buildMessageInput(salesProvider),
          ],
        ),
      ),
    );
  }

  // ── Enquiry Details Card ─────────────────────────────────────────────

  Widget _buildEnquiryDetailsCard(BaseModuleProvider provider) {
    // Blocked overrides the pipeline status while a blocker is open.
    final bool isBlocked = _enquiry.extraFields?['isBlocked'] == true;
    // A draft has not entered the funnel yet, but EnquiryModel defaults
    // `status` to 'active' — so an un-activated card would otherwise paint an
    // "Active" pill (the reported "skip activation still shows as active").
    // Override with the neutral Draft state (same grey as the card DraftChip),
    // mirroring the Task module's _getTaskStatus() draft branch.
    final bool isDraftCard = _isDraftEnquiry;
    final statusColor = isDraftCard
        ? const Color(0xFF868E96)
        : isBlocked
        ? const Color(0xFF862E9C)
        : _config.statusColorFor(_enquiry.status);
    final completed = _enquiry.completedMilestoneCount;
    final total = _enquiry.milestones.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _themeColor.withOpacity(0.2), width: 1),
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
            if (_isDraftEnquiry) ...[
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
                      'Type your enquiry in the message box below',
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
            if (_enquiry.displayId != null) ...[
              Text(
                '#${_enquiry.displayId}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.lightText.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
            ],
            // Header: Title + Status chip + Priority badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _editTitleInline(provider),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _enquiry.title.isNotEmpty
                                    ? _enquiry.title
                                    : _titleHint,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _enquiry.title.isNotEmpty
                                      ? AppTheme.primaryText
                                      : AppTheme.lightText.withOpacity(0.6),
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_enquiry.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _editDescriptionInline(provider),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _enquiry.description,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.secondaryText,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _editDescriptionInline(provider),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _descLabel,
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
                      // Customer Name (inline editable)
                      const SizedBox(height: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _editClientNameInline(provider),
                        child: Row(
                          children: [
                            Icon(
                              Icons.person_outline,
                              size: 14,
                              color: _themeColor.withOpacity(0.7),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _enquiry.clientName.isNotEmpty
                                    ? _enquiry.clientName
                                    : 'Customer Name',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: _enquiry.clientName.isNotEmpty
                                      ? FontWeight.w500
                                      : FontWeight.normal,
                                  color: _enquiry.clientName.isNotEmpty
                                      ? AppTheme.primaryText
                                      : AppTheme.lightText.withOpacity(0.6),
                                  fontStyle: _enquiry.clientName.isNotEmpty
                                      ? FontStyle.normal
                                      : FontStyle.italic,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            // Declutter (user request): no pencil once a name is
                            // set — the row is still tap-to-edit. The "+" stays
                            // only for an empty customer so adding is obvious.
                            if (_enquiry.clientName.isEmpty) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.add,
                                size: 12,
                                color: AppTheme.lightText,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        // Tapping the status pill NEVER unblocks: a Blocked
                        // enquiry returns to active only when its blocker is
                        // resolved via the "Mark Resolved" chip on the blocker
                        // card. The pill still opens the status menu so the
                        // underlying pipeline status can be changed.
                        onTap: () => _showStatusMenu(provider),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: statusColor.withOpacity(0.3),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _getStatusIcon(),
                                size: 14,
                                color: statusColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isDraftCard
                                    ? 'Draft'
                                    : isBlocked
                                    ? 'Blocked'
                                    : _statusLabel(_enquiry.status),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: statusColor,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 14,
                                color: statusColor,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Urgency chip + the two user-named custom fields below.
                _buildUrgencyAndCustomFields(provider),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // People: Creator + Assignee (tappable for contact info / edit)
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showContactInfo(
                      _enquiry.createdByName ?? 'Unknown',
                      _enquiry.createdBy,
                    ),
                    child: PersonCard(
                      icon: Icons.person_outline,
                      label: 'Created By',
                      name: _enquiry.createdByName ?? 'Unknown',
                      color: _themeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => _manageAssignee(provider),
                    onLongPress: () => _showContactInfo(
                      _enquiry.assignedTo,
                      _enquiry.assignedToUid,
                    ),
                    child: PersonCard(
                      icon: Icons.person_outline,
                      label: 'Assigned To',
                      name: _enquiry.assignedTo.isNotEmpty
                          ? _enquiry.assignedTo
                          : 'Unassigned',
                      color: _themeColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Dates: Created + Deadline (deadline is tappable to edit)
            Row(
              children: [
                Expanded(
                  child: DateCard(
                    icon: Icons.event,
                    label: 'Created',
                    date: Helpers.formatDate(_enquiry.createdAt),
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _editDeadlineInline(provider),
                    child: Builder(
                      builder: (context) {
                        if (_enquiry.deadline == null) {
                          return DateCard(
                            icon: Icons.flag_outlined,
                            label: 'Deadline',
                            date: '—',
                            color: AppTheme.secondaryText,
                          );
                        }
                        // Shared 3-color timing (card_widgets) — same rule
                        // as the card's deadline pill and bar.
                        final deadlineColor = deadlineColorFor(
                          _enquiry.createdAt,
                          _enquiry.deadline,
                          isClosed:
                              _enquiry.isClosed ||
                              !_config.isOpenStatus(_enquiry.status),
                        );
                        final recShort =
                            _enquiry.recurrenceRule?.shortLabel ?? '';
                        return DateCard(
                          icon: Icons.flag_outlined,
                          label: recShort.isNotEmpty
                              ? 'Deadline 🔁 $recShort'
                              : 'Deadline',
                          date: Helpers.formatDate(_enquiry.deadline!),
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
                    links: ItemLinksService().linksOf(_enquiry.extraFields),
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
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Sales Pipeline (collapsible)
            if (_enquiry.milestones.isNotEmpty) ...[
              InkWell(
                onTap: () => setState(() => _showMilestones = !_showMilestones),
                child: Row(
                  children: [
                    Icon(Icons.flag_outlined, size: 16, color: _themeColor),
                    const SizedBox(width: 8),
                    const Text(
                      'Sales Pipeline',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$completed/$total',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: _enquiry.milestoneProgress,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation(_themeColor),
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _showMilestones
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: AppTheme.secondaryText,
                      size: 18,
                    ),
                  ],
                ),
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildMilestoneChecklist(provider),
                crossFadeState: _showMilestones
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Progress bar - clickable to edit
            InkWell(
              onTap: () => _editProgressInline(provider),
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
                        if (_enquiry.deadline != null)
                          Text(
                            '${_getEnquiryDurationDays()} days',
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
                              value: _enquiry.progress,
                              // Timing colours only while under way — a
                              // finished enquiry reads the module color.
                              backgroundColor: _themeColor.withOpacity(0.1),
                              valueColor: AlwaysStoppedAnimation(
                                _progressBarColor,
                              ),
                              minHeight: 10,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(_enquiry.progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryText,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Money summary: Cash ledger (+ CRM categories) and Payments.
            _buildMoneySummary(),
            // Satisfaction capture — Service Teams tickets are resolved per
            // customer visit, so the closure section mirrors the Task module's
            // inline star row (rating is shown on the card strip once set).
            _buildSatisfactionSection(provider),
            // Activity Summary Log
            _buildActivityLog(),
          ],
        ),
      ),
    );
  }

  // ── Cross-module linking (Task ↔ Task/Sales/CRM) ──────────────────

  /// This enquiry's module key: 'sales' or 'crm' (from the config, never
  /// hardcoded).
  String get _selfModule => _config.type == ModuleType.crm ? 'crm' : 'sales';

  /// This enquiry as one side of a link.
  LinkRef get _selfLinkRef => LinkRef(
    module: _selfModule,
    id: _enquiry.id,
    title: _enquiry.title.isNotEmpty ? _enquiry.title : _enquiry.clientName,
    displayId: _enquiry.displayId,
  );

  /// Re-read this enquiry from the provider cache / SQLite after a link
  /// mutation so the chips refresh (the chat picks up the 🔗 system
  /// message through its own stream).
  Future<void> _refreshCurrentEnquiry() async {
    EnquiryModel? fresh;
    try {
      fresh = _readProvider(
        context,
      ).enquiries.where((e) => e.id == _enquiry.id).firstOrNull;
    } catch (_) {}
    fresh ??= await LocalDatabaseService().getModuleEnquiryById(
      _enquiry.id,
      tableName: _config.enquiriesTableName,
    );
    if (fresh != null && mounted) {
      setState(() => _enquiry = fresh!);
    }
  }

  Future<void> _openLinkPicker() async {
    final links = ItemLinksService().linksOf(_enquiry.extraFields);
    final created = await showLinkPickerSheet(
      context,
      source: _selfLinkRef,
      sourceLinks: links,
    );
    if (created) await _refreshCurrentEnquiry();
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
          'Unlink ${target.moduleLabel} ${target.label} from this ${_config.itemName.toLowerCase()} on both sides.',
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
    await _refreshCurrentEnquiry();
  }

  IconData _getStatusIcon() {
    if (_isDraftEnquiry) return Icons.edit_note;
    if (_enquiry.extraFields?['isBlocked'] == true) return Icons.block;
    return _iconForStatus(_enquiry.status);
  }

  /// Canonical icon for any pipeline status key — shared by the header chip and
  /// the Change Status popup so each option carries the same glyph users see on
  /// cards. Mirrors the tracker's status rows (leading icon + label).
  IconData _iconForStatus(String status) {
    switch (status) {
      case 'active':
      case 'open':
        return Icons.play_circle_outline;
      case 'quotation':
        return Icons.request_quote;
      case 'demo':
        return Icons.inventory_2_outlined;
      case 'negotiation':
        return Icons.local_offer_outlined;
      case 'success':
      case 'resolved':
        return Icons.check_circle_outline;
      case 'lost':
      case 'escalated':
        return Icons.cancel_outlined;
      case 'dropped':
      case 'closed':
        return Icons.remove_circle_outline;
      case 'cancel':
        return Icons.block;
      case 'inProgress':
        return Icons.hourglass_top;
      default:
        return Icons.circle_outlined;
    }
  }

  // ── Milestone Checklist ──────────────────────────────────────────────

  Widget _buildMilestoneChecklist(BaseModuleProvider provider) {
    final sorted = List<MilestoneModel>.from(_enquiry.milestones)
      ..sort((a, b) => a.order.compareTo(b.order));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: sorted.map((m) => _buildMilestoneTile(provider, m)).toList(),
      ),
    );
  }

  Widget _buildMilestoneTile(
    BaseModuleProvider provider,
    MilestoneModel milestone,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Container(
        decoration: BoxDecoration(
          color: milestone.isCompleted
              ? _themeColor.withOpacity(0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              // Tap circle to toggle completion
              GestureDetector(
                onTap: () => _toggleMilestone(provider, milestone),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: milestone.isCompleted
                        ? _themeColor
                        : Colors.grey.shade200,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: milestone.isCompleted
                        ? const Icon(Icons.check, size: 14, color: Colors.white)
                        : Text(
                            '${milestone.order + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title + tiny payment/delivery kind tag (💰/📦). The kind
                    // comes from the milestone template (or the title itself for
                    // older cards) and gates the Payments/Delivered filters —
                    // completion is still ticked manually by the user.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            milestone.title,
                            style: TextStyle(
                              fontSize: 13,
                              color: milestone.isCompleted
                                  ? AppTheme.secondaryText
                                  : AppTheme.primaryText,
                              decoration: milestone.isCompleted
                                  ? TextDecoration.lineThrough
                                  : null,
                              fontWeight: milestone.isCompleted
                                  ? FontWeight.w400
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (milestone.effectiveKind != null) ...[
                          const SizedBox(width: 5),
                          Text(
                            milestone.effectiveKind ==
                                    MilestoneModel.kindPayment
                                ? (milestone.isCompleted
                                      ? '💰 Paid'
                                      : '💰 Paid?')
                                : (milestone.isCompleted
                                      ? '📦 Delivered'
                                      : '📦 Delivered?'),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: milestone.isCompleted
                                  ? AppTheme.lightText
                                  : milestone.effectiveKind ==
                                        MilestoneModel.kindPayment
                                  ? const Color(0xFF2F9E44)
                                  : const Color(0xFFAE3EC9),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Builder(
                      builder: (context) {
                        if (milestone.deadline == null) {
                          return GestureDetector(
                            onTap: () =>
                                _editMilestoneDeadline(provider, milestone),
                            child: Text(
                              'Set deadline',
                              style: TextStyle(
                                fontSize: 10,
                                color: _themeColor.withOpacity(0.7),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          );
                        }
                        final now = DateTime.now();
                        final today = DateTime(now.year, now.month, now.day);
                        final dlDate = DateTime(
                          milestone.deadline!.year,
                          milestone.deadline!.month,
                          milestone.deadline!.day,
                        );
                        final daysLeft = dlDate.difference(today).inDays;
                        Color dlColor;
                        String dlText;
                        if (milestone.isCompleted) {
                          dlColor = AppTheme.lightText;
                          dlText =
                              'Due: ${DateFormat('MMM d').format(milestone.deadline!)}';
                        } else if (daysLeft < 0) {
                          dlColor = Colors.red;
                          dlText = Helpers.overdueLabel(daysLeft.abs());
                        } else if (daysLeft == 0) {
                          dlColor = Colors.orange;
                          dlText = 'Due today';
                        } else if (daysLeft <= 3) {
                          dlColor = Colors.orange;
                          dlText =
                              'Due in ${Helpers.dayCountLabel(daysLeft)} (${DateFormat('MMM d').format(milestone.deadline!)})';
                        } else {
                          dlColor = AppTheme.secondaryText;
                          dlText =
                              'Due: ${DateFormat('MMM d, yyyy').format(milestone.deadline!)}';
                        }
                        return Text(
                          dlText,
                          style: TextStyle(fontSize: 10, color: dlColor),
                        );
                      },
                    ),
                  ],
                ),
              ),
              // Edit deadline button (visible)
              GestureDetector(
                onTap: () => _editMilestoneDeadline(provider, milestone),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.edit_calendar,
                    size: 16,
                    color: AppTheme.lightText.withOpacity(0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _editMilestoneDeadline(
    BaseModuleProvider provider,
    MilestoneModel milestone,
  ) async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate:
          milestone.deadline ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (pickedDate == null || !mounted) return;
    final finalDateTime = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      23,
      59,
    );
    final updated = milestone.copyWith(deadline: finalDateTime);
    final allMilestones = _enquiry.milestones
        .map((m) => m.id == milestone.id ? updated : m)
        .toList();
    await provider.updateEnquiry(_enquiry.id, {
      'milestones': allMilestones
          .map(
            (m) => {
              'id': m.id,
              'title': m.title,
              'order': m.order,
              'isCompleted': m.isCompleted,
              'completedAt': m.completedAt != null
                  ? Timestamp.fromDate(m.completedAt!)
                  : null,
              'deadline': m.deadline != null
                  ? Timestamp.fromDate(m.deadline!)
                  : null,
            },
          )
          .toList(),
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deadline set for "${milestone.title}": ${DateFormat('MMM d, yyyy').format(finalDateTime)}',
          ),
          backgroundColor: _themeColor,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleMilestone(BaseModuleProvider provider, MilestoneModel milestone) {
    // Debug: log milestone IDs to help diagnose the bug
    print(
      '[SalesDetail] Toggling milestone: id=${milestone.id}, title=${milestone.title}, order=${milestone.order}',
    );
    print(
      '[SalesDetail] Current milestones: ${_enquiry.milestones.map((m) => '${m.id}:${m.title}').toList()}',
    );

    // Ensure milestone has a valid ID
    if (milestone.id.isEmpty) {
      print('[SalesDetail] ERROR: Milestone has empty ID, cannot toggle');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot update milestone: invalid ID')),
      );
      return;
    }

    final updated = milestone.copyWith(
      isCompleted: !milestone.isCompleted,
      completedAt: !milestone.isCompleted ? DateTime.now() : null,
    );
    final allMilestones = _enquiry.milestones
        .map((m) => m.id == milestone.id ? updated : m)
        .toList();

    print(
      '[SalesDetail] Updated milestones: ${allMilestones.map((m) => '${m.id}:${m.isCompleted}').toList()}',
    );

    final completedCount = allMilestones.where((m) => m.isCompleted).length;
    final progress = allMilestones.isEmpty
        ? 0.0
        : completedCount / allMilestones.length;
    final oldTitle = milestone.title;
    final action = milestone.isCompleted ? 'uncompleted' : 'completed';

    provider.updateEnquiry(_enquiry.id, {
      'milestones': allMilestones
          .map(
            (m) => {
              'id': m.id,
              'title': m.title,
              'order': m.order,
              'isCompleted': m.isCompleted,
              'completedAt': m.completedAt != null
                  ? Timestamp.fromDate(m.completedAt!)
                  : null,
              'deadline': m.deadline != null
                  ? Timestamp.fromDate(m.deadline!)
                  : null,
            },
          )
          .toList(),
      'progress': progress,
    });

    final userName = context.read<AuthProvider>().userModel?.name ?? 'User';
    final msg = MessageModel(
      id: '',
      taskId: _enquiry.id,
      senderId: _currentUserId,
      text: '$userName $action "$oldTitle"',
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    provider.sendMessage(_enquiry.id, msg);
  }

  // ── Chat Area ─────────────────────────────────────────────────────────

  Widget _buildChatArea(BaseModuleProvider provider) {
    return Stack(
      children: [
        // WhatsApp-style tinted canvas so white other-side bubbles read
        // clearly against the background (Task-module parity).
        Positioned.fill(child: ColoredBox(color: chatCanvasColor)),
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Only finger-driven scrolls defer stream updates; programmatic
            // animateTo/jumpTo must never set the flag (it used to stick and
            // swallow updates until the screen was reopened).
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _isUserScrolling = true;
            }
            if (notification is ScrollUpdateNotification) {
              final controller = notification.metrics.pixels;
              final isNearBottom = controller < 300;
              _showScrollToBottom.value = !isNearBottom;
              if (isNearBottom && _newMessageCount.value > 0) {
                _newMessageCount.value = 0;
              }
            }
            if (notification is ScrollEndNotification) {
              if (_isUserScrolling) {
                _isUserScrolling = false;
                _pendingRefreshTimer?.cancel();
                _pendingRefreshTimer = null;
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
            reverse: true, // WhatsApp-style: scroll anchor at bottom
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: _displayMessages.length + 1, // + enquiry card
            itemBuilder: (context, index) {
              // Enquiry card at the END (appears at TOP visually with reverse:true)
              if (index == _displayMessages.length) {
                final card = _buildEnquiryDetailsCard(provider);
                // Unfilled draft card stays blurred until the
                // first message is sent.
                final blurCard =
                    _enquiry.extraFields?['isDraft'] == true &&
                    _displayMessages.isEmpty;
                if (!blurCard) return card;
                return IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: card,
                  ),
                );
              }
              // Map ListView index to _displayMessages index
              // With reverse:true, index 0 = BOTTOM (newest), so direct mapping works
              final messageIndex = index;
              final msg = _displayMessages[messageIndex];
              _messageKeys[msg.id] ??= GlobalKey();

              // Track the built display-index window for scroll-to-message
              // direction (parity with task_detail_screen.dart).
              if (messageIndex >= 0) {
                if (messageIndex > _builtMaxDisplayIndex) {
                  _builtMaxDisplayIndex = messageIndex;
                }
                if (messageIndex < _builtMinDisplayIndex) {
                  _builtMinDisplayIndex = messageIndex;
                }
              }

              // Date separator: show when visually-ABOVE message is on a different day
              Widget? dateSeparator;
              if (messageIndex >= _displayMessages.length - 1 ||
                  !_isSameDay(
                    msg.createdAt,
                    _displayMessages[messageIndex + 1].createdAt,
                  )) {
                dateSeparator = DateSeparator(date: msg.createdAt);
              }

              // Club consecutive response notices: the run's OLDEST notice
              // (visually topmost with reverse:true) renders the whole quiet
              // block and newer members collapse into it — a burst of "Marked
              // as done / Replied" pills reads as one trail, not a stack
              // (Task-module parity).
              if (msg.type == MessageType.system &&
                  _responseNoticeKind(msg.text) != null) {
                bool isNoticeAt(int i) =>
                    i >= 0 &&
                    i < _displayMessages.length &&
                    _displayMessages[i].type == MessageType.system &&
                    _responseNoticeKind(_displayMessages[i].text) != null;
                if (isNoticeAt(messageIndex + 1)) {
                  // Absorbed into the block drawn above; keep any date
                  // separator that belongs at this boundary.
                  return dateSeparator ?? const SizedBox.shrink();
                }
                final run = <MessageModel>[msg];
                for (var q = messageIndex - 1; isNoticeAt(q); q--) {
                  run.add(_displayMessages[q]);
                }
                return _buildNoticeClub(run, separator: dateSeparator);
              }

              final isMe = msg.senderId == _currentUserId;

              // Message grouping: check visually-ABOVE message
              final isSameSenderAsPrevious =
                  messageIndex < _displayMessages.length - 1 &&
                  _displayMessages[messageIndex + 1].senderId == msg.senderId &&
                  _displayMessages[messageIndex + 1].type !=
                      MessageType.system &&
                  _isSameDay(
                    msg.createdAt,
                    _displayMessages[messageIndex + 1].createdAt,
                  );

              return Column(
                key: _messageKeys[msg.id],
                children: [
                  if (messageIndex < _displayMessages.length - 1)
                    const SizedBox(height: 2),
                  if (dateSeparator != null) dateSeparator,
                  GestureDetector(
                    onLongPress: () =>
                        _showMessageOptions(msg, isMe, messageIndex),
                    child: SwipeToReply(
                      // WhatsApp-style swipe-right-to-reply: typed bubbles
                      // and action cards answer with a quote; tombstones and
                      // plain system trails decline (Task parity).
                      enabled:
                          !msg.deleted &&
                          (msg.type != MessageType.system ||
                              Helpers.detectActionType(msg.text) != null),
                      onReply: () {
                        setState(() => _replyingToMessage = msg);
                        // WhatsApp flashes the quoted message on swipe-reply:
                        // same short highlight band the notification jump
                        // uses, no scroll (the row is already on screen).
                        _highlightMessageCard(msg.id);
                      },
                      child: buildMessageBubble(
                        msg,
                        isMe,
                        showSenderName:
                            !isSameSenderAsPrevious && !_isTwoParticipantChat(),
                        showTimestamp: true,
                        isSearchMatch: chatIsSearchMatch(msg.id),
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
                        0, // reverse:true: bottom = position 0
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
                              color: _themeColor,
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
                                  borderRadius: BorderRadius.circular(10),
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
                      color: _themeColor,
                      size: 24,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ---- DetailChatBubblesMixin hooks ----

  @override
  String get chatCurrentUserId => _currentUserId;

  @override
  String get chatMessagesCollection => _moduleService.collectionName;

  @override
  Set<String> get chatTickParticipants => {
    if (_enquiry.createdBy.isNotEmpty) _enquiry.createdBy,
    if (_enquiry.assignedToUid != null && _enquiry.assignedToUid!.isNotEmpty)
      _enquiry.assignedToUid!,
    ..._enquiry.assigneeUids.where((uid) => uid.isNotEmpty),
  };

  @override
  Set<String> get chatAllParticipants => chatTickParticipants;

  @override
  String chatSenderName(String senderId) => _chatActorName(senderId);

  @override
  String chatUserNameById(String uid) => _getSenderName(uid);

  @override
  Map<String, double> get chatUploadProgress => _uploadProgress;

  @override
  void chatOpenImageViewer(String url) => _openImageViewer(url);

  @override
  Future<void> chatOpenDocument(MessageModel message) async {
    if (message.fileUrl == null) return;
    String? localPath;
    if (message.fileName != null) {
      localPath = await chatLocalPathFor(message);
    }
    if (localPath != null && await File(localPath).exists()) {
      // content:// open — file:// URIs throw FileUriExposedException
      OpenFilex.open(localPath);
    } else if (message.fileName != null) {
      final downloaded = await StorageService().downloadAndCacheAttachment(
        _enquiry.id,
        message.id,
        message.fileName!,
        message.fileUrl!,
        _currentUserId,
        collection: chatMessagesCollection,
        senderId: message.senderId,
        participants: chatAllParticipants,
      );
      if (downloaded != null && await File(downloaded).exists()) {
        OpenFilex.open(downloaded);
      } else {
        // Never fall back to opening the raw Firebase URL in a browser.
        if (mounted) {
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
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot open ${message.fileName ?? 'file'}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Future<void> chatOpenPendingFile(
    MessageModel message,
    String localPath,
  ) async {
    OpenFilex.open(localPath);
  }

  @override
  Widget chatBuildSystemMessage(MessageModel message) =>
      _buildSystemMessage(message);

  @override
  Color get chatAccentColor => _themeColor;

  @override
  Color get chatTextBubbleMineBg => const Color(0xFFD8E9FA);

  @override
  Color get chatMediaBubbleMineBg => const Color(0xFFD8E9FA);

  @override
  Color get chatSenderNameColor => _themeColor;

  @override
  Color get chatVoiceMineColor => const Color(0xFF1971C2);

  @override
  Color get chatVoiceOtherColor => _themeColor;

  @override
  Color get chatUrgentColor => Colors.red;

  @override
  bool get chatShowInlineTicks => false;

  @override
  bool get chatShowDeliverySummary => false;

  // ---- DetailChatAttachmentsMixin hooks ----
  @override
  String get chatEntityId => _enquiry.id;

  @override
  List<MessageModel> get chatMessages => _messages;

  @override
  void chatRefreshMessages() => _rebuildDisplayMessages();

  @override
  void chatScrollToBottom() => _scrollToBottom();

  @override
  Future<void> chatSyncMessage(MessageModel message) async {
    await _readProvider(context).sendMessage(_enquiry.id, message);
  }

  @override
  String get chatStorageFolder => 'sales';

  @override
  String? get chatSqliteParentType => 'enquiry';

  // ---- DetailChatPlumbingMixin hooks ----
  @override
  void chatMarkMessageRead(String messageId) =>
      _moduleService.markMessageRead(_enquiry.id, messageId, _currentUserId);

  @override
  void chatMarkMessagesDelivered(List<String> messageIds) => _moduleService
      .markMessagesDelivered(_enquiry.id, messageIds, _currentUserId);

  @override
  void chatResetMyUnreadCount() => _resetMyUnreadCount();

  // ---- DetailChatMenuMixin hooks ----
  @override
  List<MessageModel> get chatSearchMessages => _messages;

  @override
  void chatScrollToMessageById(String messageId) =>
      _scrollToMessageById(messageId);

  @override
  String chatSenderNameFor(String senderId) => _getSenderName(senderId);

  @override
  String get chatExportTitle => _enquiry.title;

  @override
  String get chatShareSubjectLabel => _config.itemName;

  @override
  String get chatScreenshotFilePrefix => 'sales_screenshot';

  // ── System Message ────────────────────────────────────────────────────

  /// Display label for the action card a response notification (Done /
  /// Reply / Resolve) references via replyToMessageId: the referenced card's
  /// own base label plus its send-time sequence number ("Query 1",
  /// "Follow-up 3"). Returns null when the reference is unknown or points at
  /// something that isn't a recognized action — the notification then keeps
  /// its generic "Action" label instead of guessing. Mirrors
  /// task_detail_screen.dart _responseRefLabel (Sales + CRM share this file).
  String? _responseRefLabel(MessageModel msg) {
    final refId = msg.replyToMessageId;
    if (refId == null || refId.isEmpty) return null;
    MessageModel? ref;
    for (final m in _messages) {
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
  /// Mirrors task_detail_screen.dart _responseNoticeKind.
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
  /// Mirrors task_detail_screen.dart _noticeActionLabel.
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
  /// action card. Kept out of the Activity log / system_logs so it only
  /// appears as this quiet chat note.
  /// One compact trail line inside a notice club (see [_buildNoticeClub]).
  Widget _noticeLine(MessageModel msg) {
    final kind = _responseNoticeKind(msg.text)!;
    final refLabel = _responseRefLabel(msg);
    final actor = msg.senderId == 'system'
        ? null
        : _getSenderName(msg.senderId);
    final time = DateFormat('h:mm a').format(msg.createdAt);
    // Sequence: WHAT got answered → HOW → WHO → WHEN (was verb-first, which
    // buried the card name behind "Marked as done"). WHO is dropped in
    // two-person chats — the pill's side already shows it (bubble rule).
    final parts = <String>[
      if (refLabel != null) refLabel,
      '${kind.$1} ${kind.$2}',
      if (actor != null && !_isTwoParticipantChat()) actor,
      time,
    ];
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final ref = msg.replyToMessageId;
        _scrollToMessageById((ref != null && ref.isNotEmpty) ? ref : msg.id);
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
  /// used to dominate the feed (Task-module parity). [run] is oldest-first;
  /// the block renders at the oldest notice's slot and each line keeps its
  /// own key so scroll-to-message still works. The block hugs its actor's
  /// side (mine right, theirs left, legacy 'system' centered); a mixed-
  /// sender run splits into one pill per side.
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

  Widget _buildResponseNoticeLine(MessageModel msg) => _buildNoticeClub([msg]);

  // Card body spans: a dd/MM/yyyy HH:mm date-time segment renders in the
  // card's semantic color at NORMAL weight (user rule — the bold read as the
  // whole line being shouted; only the colour now sets it apart) so notes and
  // scheduled times stay distinct without the heavy weight.
  // Mirrors task_detail_screen.dart _bodySpans.
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

  // ⚠️ Chat action card — label chain AND the body-extraction block below
  // both parse message text; a type missing from body extraction renders a
  // label-only card with its data discarded (this was the cash bug). Twin of
  // task_detail_screen.dart _buildSystemMessage — see the ACTION-TYPE
  // CHECKLIST at its _getActionMessages.
  Widget _buildSystemMessage(MessageModel msg) {
    final messageText = msg.text;
    // Response notifications (Reply / Done / Resolve) render as a subtle,
    // centered system line — deliberately different from an action card so
    // they read as a quiet status note, not a new action.
    if (_responseNoticeKind(messageText) != null) {
      return _buildResponseNoticeLine(msg);
    }
    IconData? icon;
    String actionType;
    // Sequential occurrence number baked at send time (space form, no '#').
    final int? seqNo = msg.sequenceNumber;
    String numbered(String base) => seqNo != null ? '$base $seqNo' : base;

    if (messageText.contains('changed status to') ||
        messageText.contains('📊 Status changed')) {
      icon = Icons.flag;
      actionType = 'Status Changed';
    } else if (messageText.contains('completed') ||
        messageText.contains('uncompleted')) {
      icon = Icons.flag;
      actionType = 'Milestone Update';
    } else if (messageText.contains('💵') || messageText.contains('Cash')) {
      icon = Icons.account_balance_wallet;
      // Numbered per occurrence like the other repeatable actions
      // ("Cash Added 2") — sequence baked at send time.
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
    } else if (messageText.contains('💰') ||
        messageText.contains('Quotation') ||
        messageText.contains('Estimate')) {
      icon = Icons.request_quote;
      actionType = numbered(
        _config.type == ModuleType.crm ? 'Estimate' : 'Quotation',
      );
    } else if (messageText.contains('🛠️') ||
        messageText.contains('Site Visit') ||
        messageText.contains('Visit Schedule')) {
      // Heading carries the state word (Task parity): open visits read
      // "Visit N - Scheduled", done ones keep the occurrence number too.
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.handyman;
      actionType = msg.isFollowUpDone
          ? '${numbered('Visit')} - Done'
          : '${numbered('Visit')} - Scheduled';
    } else if (messageText.contains('🔧') || messageText.contains('Repaired')) {
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.build;
      actionType = msg.isFollowUpDone ? 'Repaired - Verified' : 'Repaired';
    } else if (messageText.contains('✔️') || messageText.contains('Verified')) {
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.verified;
      actionType = msg.isFollowUpDone ? 'Verified - Closed' : 'Verified';
    } else if (messageText.contains('🚚') || messageText.contains('Delivery')) {
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.local_shipping;
      actionType = msg.isFollowUpDone
          ? 'Delivery - Done'
          : numbered('Delivery');
    } else if (messageText.contains('📥')) {
      // Collection (Service field flow). Matched on the 📥 emoji only — a bare
      // 'Collected' word also appears in 💳 payment cards, which are handled by
      // their own branch, so keying on the emoji avoids the collision.
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.call_received;
      actionType = msg.isFollowUpDone
          ? 'Collected - Done'
          : numbered('Collected');
    } else if (messageText.contains('🤝') || messageText.contains('Meeting')) {
      icon = Icons.groups;
      actionType = numbered('Meeting');
    } else if (messageText.contains('📞') || messageText.contains('Call Log')) {
      icon = Icons.call;
      actionType = messageText.contains('Call scheduled')
          ? 'Call Scheduled'
          : 'Call Log';
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
    } else if (messageText.contains('💳') || messageText.contains('Payment')) {
      icon = Icons.payments;
      // Receivable entries keep their own verb on the card header
      // ("💳 Due: …" / "💳 Collected: …"); legacy payment notes fall back
      // to the plain 'Payment' label. Numbered per occurrence ("Payment -
      // Due 2") from the sequence baked at send time.
      final payFirstLine = messageText.split('\n').first;
      actionType = payFirstLine.contains('Due')
          ? numbered('Payment - Due')
          : payFirstLine.contains('Collected')
          ? numbered('Payment - Collected')
          : numbered('Payment');
    } else if (messageText.contains('📦') ||
        messageText.contains('Sample/Demo')) {
      icon = Icons.inventory_2_outlined;
      actionType = numbered('Sample/Demo');
    } else if (messageText.contains('🏷️') ||
        messageText.contains('Negotiation')) {
      icon = Icons.local_offer_outlined;
      actionType = numbered('Negotiation');
    } else if (messageText.contains('🏆')) {
      icon = Icons.emoji_events;
      // Numbered per outcome family ("Won 2") from the sequence baked at send
      // time — re-marking a deal posts a superseding, individually traceable
      // card instead of being blocked.
      actionType = numbered('Won');
    } else if (messageText.contains('❌')) {
      icon = Icons.cancel;
      actionType = numbered('Lost');
    } else if (messageText.contains('📉') || messageText.contains('Dropped')) {
      icon = Icons.trending_down;
      actionType = numbered('Dropped');
    } else if (messageText.contains('Reminder')) {
      icon = Icons.notifications_active;
      int? reminderNum = msg.sequenceNumber;
      if (reminderNum == null) {
        final numMatch = RegExp(
          r'Reminder\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) reminderNum = int.tryParse(numMatch.group(1)!);
      }
      actionType = reminderNum != null ? 'Reminder $reminderNum' : 'Reminder';
    } else if (messageText.contains('Follow Up') ||
        messageText.contains('Follow-up')) {
      icon = msg.isFollowUpDone ? Icons.check_circle : Icons.calendar_today;
      actionType = msg.isFollowUpDone
          ? '${numbered('Follow Up')} - Done'
          : numbered('Follow Up');
    } else if (messageText.contains('Query')) {
      icon = msg.isReplied ? Icons.check_circle : Icons.summarize;
      int? queryNum = msg.sequenceNumber;
      if (queryNum == null) {
        final numMatch = RegExp(
          r'Query\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) queryNum = int.tryParse(numMatch.group(1)!);
      }
      actionType = queryNum != null
          ? (msg.isReplied
                ? 'Query $queryNum - Replied'
                : 'Query $queryNum - Pending')
          : (msg.isReplied ? 'Query - Replied' : 'Query - Pending');
    } else if (messageText.contains('Warning') ||
        messageText.contains('Escalation')) {
      icon = Icons.report_gmailerrorred;
      int? warningNum = msg.sequenceNumber;
      if (warningNum == null) {
        final numMatch = RegExp(
          r'(?:Warning|Escalation)\s*#?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(messageText);
        if (numMatch != null) warningNum = int.tryParse(numMatch.group(1)!);
      }
      actionType = warningNum != null ? 'Escalation $warningNum' : 'Escalation';
    } else if (messageText.contains('changed title') ||
        messageText.contains('changed description') ||
        messageText.contains('changed customer name')) {
      icon = Icons.edit;
      if (messageText.contains('changed customer name')) {
        actionType = 'Customer Name Edited';
      } else if (messageText.contains('changed description')) {
        actionType = 'Description Edited';
      } else {
        actionType = 'Title Edited';
      }
    } else if (messageText.contains('changed deadline') ||
        messageText.contains('deadline')) {
      icon = null;
      actionType = 'Deadline';
    } else if (messageText.contains('changed priority')) {
      icon = Icons.flag;
      actionType = 'Priority';
    } else if (messageText.contains('🚧') ||
        messageText.toLowerCase().contains('blocker raised')) {
      icon = Icons.block;
      // Numbered per occurrence ("Blocker 2") like Request (Task parity);
      // the send-time sequence number also feeds the card chip.
      actionType = msg.isFollowUpDone
          ? '${numbered('Blocker')} - Resolved'
          : numbered('Blocker');
    } else if (messageText.toLowerCase().contains('approval requested')) {
      icon = Icons.fact_check;
      // Numbered per occurrence ("Request 2") like Query/Call (Task parity).
      // Header carries the PENDING/REPLIED status word (user rule).
      actionType = msg.isReplied || msg.isFollowUpDone
          ? '${numbered('Request')} - Replied'
          : '${numbered('Request')} - Pending';
    } else if (messageText.toLowerCase().contains('urgency changed') ||
        messageText.contains('\u{1F525}')) {
      // "🔥 Urgency changed: X → Y by ..." — used to fall through to the
      // generic 'Action' card; give it its own label + flame glyph.
      icon = Icons.local_fire_department;
      actionType = 'Urgency';
    } else if (messageText.toLowerCase().contains('added customer') ||
        messageText.toLowerCase().contains('updated customer')) {
      // Recording a customer (first-time "added" vs later "updated") must show
      // the real action, not a generic 'Action' tile.
      icon = Icons.badge_outlined;
      actionType = messageText.toLowerCase().contains('added customer')
          ? 'Customer Added'
          : 'Customer Updated';
    } else {
      icon = Icons.info_outline;
      actionType = 'Action';
    }

    // Semantic colors: blue = action, green = done/success, grey = metadata edit
    final bool isDone = msg.isFollowUpDone || msg.isReplied;
    final bool isCashAction =
        messageText.contains('💵') || actionType.startsWith('Cash');
    final bool isMetadataEdit =
        actionType.endsWith('Edited') ||
        actionType == 'Deadline' ||
        actionType == 'Milestone Update' ||
        actionType == 'Action';
    final Color color = isCashAction
        ? AppTheme.accent
        : isDone
        ? AppTheme.success
        : isMetadataEdit
        ? AppTheme.tertiaryLabel
        : AppTheme.info;

    final displayTime = DateFormat('h:mm a').format(msg.createdAt);

    // Actor attribution — every action card says who did it. senderId is the
    // real actor UID; legacy 'system' senders can't be attributed reliably.
    final String? actorLabel = msg.senderId == 'system'
        ? null
        : _chatActorName(msg.senderId);

    // Alignment follows the actor, just like text messages: my actions on the
    // right, other people's on the left; unattributed legacy cards stay center.
    final AlignmentGeometry cardAlignment = msg.senderId == _currentUserId
        ? Alignment.centerRight
        : (msg.senderId == 'system' ? Alignment.center : Alignment.centerLeft);

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
        // Task-module parity: strip the label lead-ins the card header
        // already shows, so the body reads as the note only.
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
            // Visit cards dropped the "Visit" label echo (heading carries the
            // state now), leaving "🛠️ <note> on dd/MM…" with no quote/colon/
            // by-at anchor for the extractors above — the typed note silently
            // vanished. Strip the emoji and show the rest (Task parity, and
            // it heals visit cards posted earlier).
            final stripped = messageText
                .replaceFirst(RegExp(r'^🛠️\s*'), '')
                .trim();
            displayText = stripped.isEmpty ? null : stripped;
          }
        }
      }
    }

    // Determine card width: wider for cards with body text, narrower for label-only
    final bool hasBodyText =
        (beforeValue != null && afterValue != null) ||
        (afterValue != null && beforeValue == null) ||
        (beforeValue == null &&
            afterValue == null &&
            displayText != null &&
            displayText.isNotEmpty);
    // One uniform width family for every card - actions, edits and activity
    // alike: body-text cards 240, label-only 168 (Task-module parity). The old
    // split gave real actions a roomier 280/200 bubble than the 240/168
    // metadata cards, which read as inconsistent widths down the feed. A
    // card carrying an attachment joins the 240 family (the "Attached
    // document" line is body content).
    final double cardWidth = hasBodyText || msg.fileUrl != null ? 240.0 : 168.0;

    // Tapping an action card reopens the matching action dialog so the next
    // one can be issued right away (e.g. tap any call card to type a note
    // and schedule the next call — both sides). Non-action cards keep the
    // old scroll-to-message behavior (parity with task detail).
    final reopenKey = Helpers.detectActionType(messageText);
    final reopenDef = reopenKey == null ? null : _config.actionFor(reopenKey);
    // Grouped action-card families driving the shared Reply / Done / Approve
    // chips below (module-uniform across Sales + CRM).
    final bool isVisitAction =
        reopenKey == 'sitevisit' || reopenKey == 'sample';
    final bool isQuoteAction =
        reopenKey == 'quotation' || reopenKey == 'negotiation';

    // Action cards ride the chat's side colors (Task-module parity, explicit
    // user rule): a card I raised sits on the same 'mine' tint as my bubbles,
    // a card from the other side is a white bubble with the hairline edge.
    // Only legacy unattributed senderId='system' cards (centered, no side)
    // keep the quiet grey panel.
    final scheme = Theme.of(context).colorScheme;
    final bool cardIsDark = Theme.of(context).brightness == Brightness.dark;
    final bool mineCard = msg.senderId == _currentUserId;
    final bool otherCard = !mineCard && msg.senderId != 'system';
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

    // Reopen-the-action bindings now live on the card HEADING only (user
    // rule: the create-new-activity popup must not fire from a body tap).
    // A null headingTap lets the tap fall through to the outer scroll.
    VoidCallback? headingTap;
    if (reopenKey == 'won' || reopenKey == 'lost' || reopenKey == 'dropped') {
      headingTap = () => _sendWonLostAction(_readProvider(context));
    } else if (reopenKey == 'blocker') {
      // Raise Blocker is a manual tile but NOT in [ModuleConfig.actionTypes],
      // so actionFor('blocker') is null — its card used to fall through to
      // scroll-to-message instead of reopening. Match every other action.
      headingTap = () => _raiseBlocker(_readProvider(context));
    } else if (reopenDef != null) {
      headingTap = () => _sendActionMessage(_readProvider(context), reopenKey!);
    } else if (messageText.toLowerCase().contains('urgency changed')) {
      // Metadata-edit cards reopen their editor too (parity with action
      // cards): an "Urgency changed" card reopens the urgency chooser.
      headingTap = () => _showUrgencyMenu(_readProvider(context));
    } else if (messageText.toLowerCase().contains('status changed')) {
      headingTap = () => _showStatusMenu(_readProvider(context));
    } else if (messageText.toLowerCase().contains('customer')) {
      // Customer edit cards reopen the customer editor (name/phone/email/
      // company/address) so the record can be corrected in place.
      headingTap = () => _editClientNameInline(_readProvider(context));
    }

    return GestureDetector(
      // Card-body tap only scrolls: response notifications (Done / Reply /
      // Resolve) carry a replyToMessageId pointing at the action card they
      // refer to — jumping back works from anywhere on the card.
      onTap: () {
        final ref = msg.replyToMessageId;
        _scrollToMessageById(ref != null && ref.isNotEmpty ? ref : msg.id);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        // Horizontal highlight band: while a jump flags this card, a soft
        // green strip spans the row so the referenced action is easy to spot.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          color: _highlightedMessageId == msg.id
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
                  // scroll (user rule, Task parity). Opaque behavior so the
                  // thin gaps around the label row still receive the tap.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: headingTap,
                    child: Row(
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 13, color: color),
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
                        if (actorLabel != null && !_isTwoParticipantChat()) ...[
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
                          // (user rule, Task parity) — 11pt made long notes
                          // hard to read next to real bubbles.
                          fontSize: 16,
                          color: AppTheme.secondaryText,
                          height: 1.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                        // Receivable footers wrap to a 3rd line in the 240pt
                        // card; a 2-line cap clipped the Outstanding amount.
                        maxLines: 3,
                      ),
                    ),
                  // Attachment riding inside the action card (one-message edit):
                  // a small "Attached document" line under the body. Its own
                  // tap opens the file — the inner GestureDetector wins over
                  // the card's reopen-the-action tap.
                  if (msg.fileUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, left: 4),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: msg.fileUrl == 'pending' || msg.isUploadFailed
                            ? null
                            : () => chatOpenDocument(msg),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              msg.isUploadFailed
                                  ? Icons.error_outline
                                  : Icons.attach_file,
                              size: 11,
                              color: msg.isUploadFailed
                                  ? Colors.red
                                  : AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                msg.fileUrl == 'pending'
                                    ? 'Uploading attachment…'
                                    : msg.isUploadFailed
                                    ? 'Attachment failed'
                                    : 'Attached document',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: msg.isUploadFailed
                                      ? Colors.red
                                      : AppTheme.secondaryText,
                                  decoration:
                                      msg.isUploadFailed ||
                                          msg.fileUrl == 'pending'
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
                  // status, the answer text stays on the card.
                  if (msg.isReplied && msg.queryReply != null)
                    _inlineDoneLabel(
                      'Reply: ${msg.queryReply}',
                      // Same person replied → under the typed text, left
                      // edge; other person → opposite (right) edge.
                      left: msg.repliedBy == msg.senderId,
                    ),
                  // Follow-up: Mark Done belongs to the card's initiator only
                  // (user rule, Task parity); the other side answers with the
                  // Reply option while the card is open. A reply never closes
                  // and once Done lands the Reply option is gone (reply TEXT
                  // stays in the consolidated block above).
                  if ((messageText.contains('Follow Up') ||
                          messageText.contains('Follow-up')) &&
                      !msg.isFollowUpDone &&
                      msg.senderId == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () => _markFollowUpDone(msg),
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
                  // rule — same-side Reply removed, Task parity). A reply
                  // answers the follow-up but never closes it.
                  if ((messageText.contains('Follow Up') ||
                          messageText.contains('Follow-up')) &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied &&
                      !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(msg, 'Reply to Follow Up'),
                      ),
                    ),
                  // Follow-up done status — routed through the shared trail
                  // helper so the word "Done" hides when the header already
                  // says "Follow Up - Done" (and the systemType-gated trail
                  // below used to render this a second time).
                  if ((messageText.contains('Follow Up') ||
                          messageText.contains('Follow-up')) &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Done', headerLabel: actionType),
                  // Blocker: the creator resolves it (Task-module parity).
                  // Gate on the enquiry creator, NOT "anyone but the sender" —
                  // the old senderId check hid Resolve from the creator whenever
                  // they raised it themselves (and in single-account testing),
                  // so it appeared on neither side.
                  if (msg.systemType == SystemMessageType.blocker &&
                      !msg.isFollowUpDone &&
                      _enquiry.createdBy == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Mark Resolved',
                        Icons.check_circle_outline,
                        const Color(0xFF2F9E44),
                        () => _resolveBlocker(_readProvider(context), msg),
                      ),
                    ),
                  // Blocker resolved status
                  if (msg.systemType == SystemMessageType.blocker &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Resolved', headerLabel: actionType),
                  // Approval/Request: only the OTHER side gets Reply — and a
                  // reply from them CLOSES the card (user rule: "take reply
                  // as closed"; the Close button is gone). The raiser sees no
                  // chips on their own request (Task parity).
                  if (msg.systemType == SystemMessageType.approval &&
                      !msg.isFollowUpDone &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Reply',
                            Icons.reply,
                            const Color(0xFF1976D2),
                            () => _showReplyDialog(msg, 'Reply to Request'),
                          ),
                        ],
                      ),
                    ),
                  // (systemType-gated follow-up trail removed: the text-gated
                  // trail above already renders it — having both drew "Done"
                  // twice on every follow-up card.)
                  // Scheduled call: the scheduler marks the call done
                  if (msg.systemType == SystemMessageType.call &&
                      !msg.isFollowUpDone &&
                      msg.senderId == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Mark Done',
                        Icons.check_circle_outline,
                        const Color(0xFF1976D2),
                        () => _markCallDone(msg),
                      ),
                    ),
                  // Scheduled call done status
                  if (msg.systemType == SystemMessageType.call &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Done', headerLabel: actionType),
                  // Request closed status
                  if (msg.systemType == SystemMessageType.approval &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Closed', headerLabel: actionType),
                  // Query / Escalation: only the OTHER side replies, and their
                  // reply CLOSES the card (user rule — the raiser's Close
                  // button is gone; the reply is the answer the query asked
                  // for). Reply-only until replied; then the card shows the
                  // closed trail (Task parity).
                  if ((reopenKey == 'query' || reopenKey == 'warning') &&
                      !msg.isFollowUpDone &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inlineActionChip(
                            'Reply',
                            Icons.reply,
                            const Color(0xFF1976D2),
                            () => _showReplyDialog(
                              msg,
                              reopenKey == 'query'
                                  ? 'Reply to Query'
                                  : 'Reply to Escalation',
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Query / Escalation closed status
                  if ((reopenKey == 'query' || reopenKey == 'warning') &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Closed', headerLabel: actionType),
                  // ── Visit / Demo action chips ──
                  // Done (close the visit) shows on BOTH sides (user rule —
                  // either party can confirm the visit happened; R2's
                  // initiator-only gate does not apply to Visit/Demo). The
                  // other side also keeps a Reply note while the card is
                  // open (the raiser's same-side Reply is removed — user
                  // rule). A reply never closes, and once Done lands the
                  // Reply option is gone (reply TEXT stays above).
                  if (isVisitAction && !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Done',
                        Icons.check_circle_outline,
                        const Color(0xFF1098AD),
                        () => _markVisitDone(msg),
                      ),
                    ),
                  if (isVisitAction &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied &&
                      !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(
                          msg,
                          reopenKey == 'sample'
                              ? 'Reply to Demo'
                              : 'Reply to Visit',
                        ),
                      ),
                    ),
                  if (isVisitAction && msg.isFollowUpDone)
                    _inlineDoneLabel(
                      // 'Done' matches the "Visit - Done" header so the
                      // trail vanishes (was 'Visited', which read as a
                      // duplicate status).
                      'Done',
                      headerLabel: actionType,
                    ),
                  // ── Meeting action chips ──
                  // Mark Done belongs to the card's initiator only (user
                  // rule); only the OTHER side answers with Reply (same-side
                  // Reply removed — user rule), and Reply hides once the card
                  // is closed.
                  if (reopenKey == 'meeting' &&
                      !msg.isFollowUpDone &&
                      msg.senderId == _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Mark Done',
                        Icons.check_circle_outline,
                        const Color(0xFF1098AD),
                        () => _markVisitDone(msg),
                      ),
                    ),
                  if (reopenKey == 'meeting' &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied &&
                      !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(msg, 'Reply to Meeting'),
                      ),
                    ),
                  if (reopenKey == 'meeting' && msg.isFollowUpDone)
                    _inlineDoneLabel('Done', headerLabel: actionType),
                  // ── CRM field-service ──
                  // Collect (📥 pickup) and Repair (🔧) are now SEPARATE
                  // top-level Message Actions tiles (like Sales Delivery), no
                  // longer raised as chips nested on the Visit card. The Visit
                  // card itself carries no CRM-specific chips.
                  // Quotation / Estimate / Negotiation: Approve and Reply are
                  // independent chips but belong to the OTHER side only (user
                  // rule) — the raiser tracks their own quote via the card,
                  // the recipient answers with Approve or Reply. A reply
                  // never closes; Approve does.
                  if (isQuoteAction &&
                      msg.senderId != _currentUserId &&
                      !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Approve',
                        Icons.check_circle_outline,
                        const Color(0xFF2F9E44),
                        () => _approveEstimate(msg),
                      ),
                    ),
                  if (isQuoteAction &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied &&
                      !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(
                          msg,
                          reopenKey == 'negotiation'
                              ? 'Reply to Negotiation'
                              : (_config.type == ModuleType.crm
                                    ? 'Reply to Estimate'
                                    : 'Reply to Quotation'),
                        ),
                      ),
                    ),
                  if (isQuoteAction && msg.isFollowUpDone)
                    _inlineDoneLabel('Approved', headerLabel: actionType),
                  // Delivery: confirm goods/parts handed over. Actionable in
                  // both Sales and CRM, so either side may mark it delivered
                  // (the deliverer logs it, or the recipient acknowledges).
                  if (reopenKey == 'delivery' && !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Delivered',
                        Icons.local_shipping,
                        const Color(0xFFF76707),
                        () => _markDelivered(msg),
                      ),
                    ),
                  if (reopenKey == 'delivery' && msg.isFollowUpDone)
                    _inlineDoneLabel(
                      // 'Done' matches the "Delivery - Done" header so the
                      // word hides (was 'Delivered' — a duplicate status).
                      'Done',
                      headerLabel: actionType,
                    ),
                  // Collection: technician confirms the pick-up. Marking it done
                  // is what unlocks Deliver on the parent Visit card (only a
                  // collected ticket can be delivered).
                  if (reopenKey == 'collect' && !msg.isFollowUpDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Collected',
                        Icons.call_received,
                        const Color(0xFF0C8599),
                        () => _markCollected(msg),
                      ),
                    ),
                  if (reopenKey == 'collect' && msg.isFollowUpDone)
                    _inlineDoneLabel('Collected', headerLabel: actionType),
                  // Repaired: Done confirms the fix on-site → ticket status
                  // Repaired. Both Done and Reply belong to the OTHER side only
                  // (user rule) — the technician who logged the repair does not
                  // act on their own card.
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'repaired' &&
                      !msg.isFollowUpDone &&
                      msg.senderId != _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Done',
                        Icons.check_circle_outline,
                        const Color(0xFF1971C2),
                        () => _verifyRepaired(msg),
                      ),
                    ),
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'repaired' &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(msg, 'Reply to Repair'),
                      ),
                    ),
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'repaired' &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Repaired', headerLabel: actionType),
                  // Verified: Close finishes the ticket → status Closed. Close
                  // and Reply belong to the OTHER side only (user rule) — the
                  // verifier does not act on their own card.
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'verified' &&
                      !msg.isFollowUpDone &&
                      msg.senderId != _currentUserId)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Close',
                        Icons.lock_outline,
                        const Color(0xFF495057),
                        () => _closeVerifiedTicket(msg),
                      ),
                    ),
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'verified' &&
                      msg.senderId != _currentUserId &&
                      !msg.isReplied)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _inlineActionChipR(
                        'Reply',
                        Icons.reply,
                        const Color(0xFF1976D2),
                        () => _showReplyDialog(msg, 'Reply to Verify'),
                      ),
                    ),
                  if (_config.type == ModuleType.crm &&
                      reopenKey == 'verified' &&
                      msg.isFollowUpDone)
                    _inlineDoneLabel('Closed', headerLabel: actionType),
                ],
              ),
            ),
          ),
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
  // text and the ✓ (Task-module parity).
  Widget _inlineDoneLabel(
    String label, {
    String? headerLabel,
    bool left = false,
  }) {
    final dup =
        label.isNotEmpty && headerLabel != null && headerLabel.contains(label);
    if (dup) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        // Reply trails sit under the typed text on the REPLIER's edge: left
        // when the card's own sender wrote the reply, right when the other
        // person did (user rule, Task parity). Status trails stay flush-right.
        mainAxisAlignment: left
            ? MainAxisAlignment.start
            : MainAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              label,
              textAlign: left ? TextAlign.start : TextAlign.end,
              // Normal weight, matching the header meta stamps — the ✓
              // carries the "done" signal, not bold text (Task parity).
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

  // Reply dialog for request cards (Task-module parity).
  Future<void> _showReplyDialog(MessageModel message, String title) async {
    final replyController = TextEditingController();
    String replyText = '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.reply, color: _themeColor, size: 24),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: TextField(
          controller: replyController,
          maxLines: 3,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Type your reply...',
            counterText: '',
            hintStyle: const TextStyle(fontSize: 13),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (value) => replyText = value,
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
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Send Reply'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    // Request/Query/Escalation: the OTHER side's reply IS the closure (user
    // rule) — done fields ride the same update so one write passes rules and
    // the '↩️ Replied' notice stands as the closing record (no extra ✅ line).
    final replyAct = Helpers.detectActionType(message.text);
    final bool replyCloses =
        (message.systemType == SystemMessageType.approval ||
            replyAct == 'query' ||
            replyAct == 'warning') &&
        message.senderId != _currentUserId;
    try {
      await _readProvider(context).updateMessage(_enquiry.id, message.id, {
        'queryReply': result,
        'repliedBy': _currentUserId,
        'repliedAt': Timestamp.now(),
        'isReplied': true,
        if (replyCloses) 'isFollowUpDone': true,
        if (replyCloses) 'followUpDoneBy': _currentUserId,
        if (replyCloses) 'followUpDoneAt': Timestamp.now(),
      });
      // Record the reply as a subtle system line (rendered by
      // _buildResponseNoticeLine, NOT as an action card). The query card also
      // flips to "Actioned" in place. Tapping jumps back to it.
      _dispatchActionMessage(
        _readProvider(context),
        _noticeText('↩️ Replied', message),
        _currentUserId,
        referenceMessageId: message.id,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Reply sent'),
          backgroundColor: _themeColor,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      print('[SalesDetail] Error sending reply: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to send reply'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Scheduler: mark a scheduled call as done once the call happened.
  Future<void> _markCallDone(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Call marked as done');
  }

  // ── Field-service complaint flow handlers (Service Teams) ──────────
  // Visit completed — closes the Visit Schedule card.
  Future<void> _markVisitDone(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Visit marked done');
  }

  // Estimate approved — closes the Estimate card and moves an Open ticket to
  // In Progress (work sanctioned). Never regresses an already-decided ticket.
  Future<void> _approveEstimate(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Estimate approved');
    if (!mounted) return;
    final provider = _readProvider(context);
    if (_enquiry.status == 'open') _changeStatus(provider, 'inProgress');
  }

  // Repair verified by a second person — closes the Repaired card and resolves
  // the ticket (the checkpoint the whole complaint flow builds to).
  Future<void> _verifyRepaired(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Repair verified');
    if (!mounted) return;
    final provider = _readProvider(context);
    if (_config.isOpenStatus(_enquiry.status)) {
      _changeStatus(provider, 'resolved');
    }
  }

  // Verified ticket closed — closes the Verified card and closes the ticket.
  Future<void> _closeVerifiedTicket(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Ticket closed');
    if (!mounted) return;
    final provider = _readProvider(context);
    if (_enquiry.status != 'closed') _changeStatus(provider, 'closed');
  }

  // Delivery completed — closes the 🚚 Delivery card (goods/parts handed over).
  // Does not change enquiry status; a delivery is a checkpoint, not an outcome.
  Future<void> _markDelivered(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Marked delivered');
  }

  // Collection completed — closes the 📥 Collected card (device/item picked up).
  Future<void> _markCollected(MessageModel message) async {
    await _setMessageDoneFlag(message, 'Marked collected');
  }

  // Shared optimistic isFollowUpDone update backing the Close / Mark Done
  // chips (same fields _markFollowUpDone writes).
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
        // The message card list renders _displayMessages (a reversed copy), so
        // mutating _messages alone leaves the chip showing its pre-tap state —
        // and the SQLite stream dedup skips content-only re-emissions. Rebuild
        // here so Approve / Reply / Close / Mark Done / Delivered land at once.
        _rebuildDisplayMessages();
      });
    }
    try {
      await _readProvider(context).updateMessage(_enquiry.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });
      // Record the completion as a subtle system line (not an action card).
      _dispatchActionMessage(
        _readProvider(context),
        _noticeText('✅ Marked as done', message),
        _currentUserId,
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
      print('[SalesDetail] Error updating done flag: $e');
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message;
          }
          _rebuildDisplayMessages();
        });
      }
    }
  }

  Future<void> _markFollowUpDone(MessageModel message) async {
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
        _rebuildDisplayMessages();
      });
    }

    try {
      await _readProvider(context).updateMessage(_enquiry.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });

      // Record the completion as a subtle system line (not an action card).
      _dispatchActionMessage(
        _readProvider(context),
        _noticeText('✅ Marked as done', message),
        _currentUserId,
        referenceMessageId: message.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Follow-up marked as done'),
            backgroundColor: AppTheme.primaryGreen,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[SalesDetail] Error marking follow-up as done: $e');
      // Revert optimistic update on failure
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark as done'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // ── Schedule Call (Task-module parity) ────────────────────────────────

  /// Schedule Call: ONE popup with date/time rollers + note box, then post a
  /// "📞 Call scheduled" card. Tapping any call card reopens this flow so
  /// the next call can be scheduled right away — usable by both sides. At
  /// the scheduled time this device fires a local notification and the other
  /// side gets a server push (remindScheduledCalls sweep).
  Future<void> _showScheduleCallDialog(BaseModuleProvider provider) async {
    final userId = _currentUserId;
    if (userId.isEmpty) return;

    final result = await showScheduleCallDialog(
      context,
      previousLabel: 'Call',
      previousCount: _nextActionNumber('call') - 1,
      previousEmoji: '📞',
    );
    if (result == null || !mounted) return;
    // Picker rule: day-only (no time chosen) sends just the date; the stored /
    // reminder moment falls back to 09:00 via reminderAt.
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
    _dispatchActionMessage(
      provider,
      callText,
      userId,
      systemType: SystemMessageType.call,
      scheduledAt: selectedDate,
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
    final title = _enquiry.title.isNotEmpty ? _enquiry.title : 'Enquiry';
    NotificationService().scheduleDeadlineReminder(
      id:
          '${_enquiry.id}-call-${when.millisecondsSinceEpoch}'.hashCode &
          0x7fffffff,
      title: '📞 Scheduled call',
      body: note.isNotEmpty ? '"$title" — $note' : 'Call for "$title"',
      scheduledDate: when,
    );
  }

  // ── Request approval (Task-module parity) ─────────────────────────────

  /// Request: note box -> "Approval requested" card. The other side (not the
  /// requester) gets Approve / Send Back buttons on the card.
  Future<void> _requestApprovalAction(BaseModuleProvider provider) async {
    final userId = _currentUserId;
    if (userId.isEmpty) return;
    final controller = TextEditingController();
    String note = '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            // "Previous Request: 2" — the card this posts is numbered N+1
            // (Task-module parity).
            PreviousActionHint(
              label: 'Request',
              count: _nextActionNumber('approval') - 1,
              color: const Color(0xFF0B7285),
            ),
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // Note is mandatory so a Request always carries context
              // (Task-module parity).
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
    );
    if (result == null || !mounted) return;
    final noteText = result.trim().isEmpty ? '' : ': "${result.trim()}"';
    final timestamp = Helpers.formatDateTime(DateTime.now());
    _dispatchActionMessage(
      provider,
      'Approval requested$noteText by $_currentUserName at $timestamp',
      userId,
      systemType: SystemMessageType.approval,
      // Number the card per occurrence ("Request 2") — this dialog bypasses
      // the generic _numberedActions composer, so bake it explicitly.
      sequenceNumber: _nextActionNumber('approval'),
    );
  }

  // ── Blocker (Task-module parity) ─────────────────────────────────────

  /// Toggle the enquiry between Blocked and its base status. Blocked lives
  /// in extraFields so the pipeline status itself is untouched.
  Future<void> _applyBlockedStatus(
    BaseModuleProvider provider, {
    required bool blocked,
  }) async {
    final extra = _enquiry.extraFields;
    final currentlyBlocked = extra != null && extra['isBlocked'] == true;
    if (blocked == currentlyBlocked) return;

    final oldStatus = currentlyBlocked
        ? 'Blocked'
        : _statusLabel(_enquiry.status);
    final updatedExtra = Map<String, dynamic>.from(extra ?? {});
    updatedExtra['isBlocked'] = blocked;
    setState(() {
      _enquiry = _enquiry.copyWith(
        extraFields: updatedExtra,
        updatedAt: DateTime.now(),
      );
    });
    await provider.updateEnquiry(_enquiry.id, {
      'extraFields.isBlocked': blocked,
      'updatedAt': Timestamp.now(),
    });

    final newStatus = blocked ? 'Blocked' : _statusLabel(_enquiry.status);
    if (mounted) {
      _dispatchActionMessage(
        provider,
        '📊 Status changed: $oldStatus → $newStatus by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
        _currentUserId,
      );
    }
  }

  /// Raise a blocker: reason dialog, enquiry goes Blocked, card is posted
  /// for the creator to resolve (Task-module parity).
  Future<void> _raiseBlocker(BaseModuleProvider provider) async {
    final userId = _currentUserId;
    if (userId.isEmpty) return;
    // Only one open blocker at a time: refuse a second until the current one
    // is resolved (Task-module parity).
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
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            // "Previous Blocker: 2" — only one stays open at a time, so this
            // counts the blockers already raised and resolved on this card.
            PreviousActionHint(
              label: 'Blocker',
              count: _nextActionNumber('blocker') - 1,
              color: const Color(0xFFC92A2A),
              emoji: '🚧',
            ),
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
    );
    if (result == null || !mounted) return;
    // Enquiry becomes Blocked while a blocker is open
    await _applyBlockedStatus(provider, blocked: true);
    if (!mounted) return;
    _dispatchActionMessage(
      provider,
      '🚧 Blocker raised: "$result" by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      userId,
      systemType: SystemMessageType.blocker,
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

  /// Creator: mark a blocker as resolved (reuses follow-up done mechanics).
  /// Once the last open blocker is resolved the enquiry goes back to its
  /// base status.
  Future<void> _resolveBlocker(
    BaseModuleProvider provider,
    MessageModel message,
  ) async {
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
          _rebuildDisplayMessages();
        }
      });
    }

    try {
      await provider.updateMessage(_enquiry.id, message.id, {
        'isFollowUpDone': true,
        'followUpDoneBy': _currentUserId,
        'followUpDoneAt': Timestamp.now(),
      });

      // Record the resolution as a subtle system line (not an action card).
      _dispatchActionMessage(
        provider,
        _noticeText('🔓 Blocker resolved', message),
        _currentUserId,
        referenceMessageId: message.id,
      );

      if (mounted) {
        final openBlockers = _messages
            .where(
              (m) =>
                  m.systemType == SystemMessageType.blocker &&
                  !m.isFollowUpDone &&
                  m.id != message.id,
            )
            .length;
        if (openBlockers == 0) {
          await _applyBlockedStatus(provider, blocked: false);
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
      print('[SalesDetail] Error resolving blocker: $e');
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = message; // Revert optimistic update
          }
          _rebuildDisplayMessages();
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

  // Small inline action chip used on approval cards (Approve / Send Back).
  Widget _inlineActionChip(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Same chip, hugged to the card's right edge — action buttons sit in the
  // bottom-right corner (Task-module parity), never centered.
  Widget _inlineActionChipR(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) => Align(
    alignment: Alignment.centerRight,
    child: _inlineActionChip(label, icon, color, onTap),
  );

  // ── Message Input ─────────────────────────────────────────────────────

  /// True only while the enquiry is a real draft: flagged AND still untitled.
  /// An enquiry that received a title (via activation or any edit) is active,
  /// even if a stale isDraft flag was left behind.
  bool get _isDraftEnquiry =>
      _enquiry.extraFields?['isDraft'] == true && _enquiry.title.trim().isEmpty;

  Widget _buildMessageInput(BaseModuleProvider provider) {
    // Removed assignee: the card stays visible but frozen and read-only. The
    // Firestore rules already deny this user sending (no longer a participant),
    // so swap the whole composer for a plain hint instead of letting them type
    // into a box whose sends would silently fail. Mirrors Task Detail.
    if (_enquiry.extraFields?['accessRevoked'] == true) {
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
                  "You're no longer assigned to this ticket — chats and "
                  'updates are paused.',
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
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pending "Send Later" items held for this enquiry (with cancel).
            if (_scheduledMessages.isNotEmpty) _buildScheduledStrip(),
            // Draft info banner (shown above input bar when enquiry is draft)
            if (_isDraftEnquiry)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
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
            // Voice recording overlay
            if (isRecording) buildRecordingOverlay(),
            // Voice preview (after recording stopped)
            if (voicePreviewVisible && !isRecording) buildVoicePreview(),
            // Reply preview (WhatsApp-style quoted reply)
            if (_replyingToMessage != null) _buildReplyPreview(),
            // @mention suggestions dropdown (shown while typing "@name")
            MentionSuggestions(
              mention: _mention,
              messageController: _messageController,
              accentColor: _themeColor,
            ),
            // Input row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Text input area (Slack-style: square corners)
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
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
                            textCapitalization: TextCapitalization.sentences,
                            maxLines: 1,
                            maxLength: 2000,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(provider),
                            onChanged: (v) {
                              final hasText = v.trim().isNotEmpty;
                              if (hasText != _hasText.value) {
                                _hasText.value = hasText;
                              }
                            },
                            decoration: InputDecoration(
                              hintText: _isDraftEnquiry
                                  ? 'Type your enquiry here...'
                                  : 'Type a message...',
                              counterText: '',
                              isCollapsed: true,
                              hintStyle: TextStyle(
                                fontSize: 15,
                                color: AppTheme.lightText,
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
                          onPressed: () => _showAttachmentSheet(),
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
                // More actions button (Slack-style)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[300]!, width: 1),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _showMessageActions(provider),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_circle_outline,
                          color: _themeColor,
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
                                onTap: () => _scheduleCurrentMessage(provider),
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
                // Conditional Send / Mic button
                if (voicePreviewVisible)
                  // Voice preview mode: show send voice button
                  Container(
                    decoration: BoxDecoration(
                      color: _themeColor,
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
                            color: _themeColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _isSending
                                  ? null
                                  : () => _sendMessage(provider),
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
                            color: isRecording ? Colors.red : _themeColor,
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
        ),
      ),
    );
  }

  /// Tile order for the Message Actions sheet (4 per row). Keys the module
  /// catalog does not define are skipped, so each module renders its own
  /// subset. The order is module-specific via [_actionSheetOrder] below.
  ///
  /// Sales (3 rows of 4, user layout rule):
  ///   Row 1 — the pipeline: Visit/Demo, Quotation, Negotiation, Outcome.
  ///   Row 2 — the close: Delivery, Payment, Meeting/Call, Raise Blocker.
  ///   Row 3 — the nudges: Reminder, Request, Query, Follow Up.
  /// Two tiles are combined choosers that pop a "which one?" sheet before
  /// composing: Visit/Demo (→ Site Visit or Demo) and Meeting/Call (→ Meeting
  /// or Call). The 'sitevisit' and 'call' keys are therefore kept in the Sales
  /// catalog (so they compose + render) but not listed as their own tiles.
  static const List<String> _salesActionSheetOrder = [
    'sample',
    'quotation',
    'negotiation',
    'won',
    'delivery',
    'cash',
    'meeting',
    'blocker',
    'reminder',
    'approval',
    'query',
    'followup',
  ];

  /// Service (CRM): field-service order. Row 1 is the repair lifecycle
  /// (Visit → Estimate → Repaired → Verified); Row 2 the logistics + attention
  /// dues (Collect/Pickup · Delivery · Query · Blocker); Row 3 Cash + Escalation.
  /// Collect and Delivery are SEPARATE top-level tiles (like Sales), no longer
  /// nested on the Visit card. The old Reminder tile is replaced by Query
  /// (user rule: same as Sales). 'payment' is clubbed into the 'cash' tile.
  static const List<String> _crmActionSheetOrder = [
    'sitevisit',
    'quotation',
    'repaired',
    'verified',
    'collect',
    'delivery',
    'query',
    'blocker',
    'cash',
    'warning',
  ];

  /// The action-sheet order for the current module.
  List<String> get _actionSheetOrder => _config.type == ModuleType.crm
      ? _crmActionSheetOrder
      : _salesActionSheetOrder;

  List<Widget> _actionSheetTiles(
    BuildContext ctx,
    BaseModuleProvider provider,
  ) {
    final tileWidth = (MediaQuery.of(ctx).size.width - 16) / 4;
    final tiles = <Widget>[];
    for (final key in _actionSheetOrder) {
      final def = _config.actionFor(key);
      // 'blocker' is a manual tile (not in actionTypes); everything else must
      // exist in the module catalog or it is skipped for this module.
      if (def == null && key != 'blocker') continue;
      // Delivery is a post-sale step in SALES: the 🚚 tile only appears once the
      // enquiry is WON (Success stage) — nothing to ship before the deal
      // closes (user rule). In CRM a delivery is a field-service step, so the
      // tile is always offered there (CRM never reaches 'success').
      if (key == 'delivery' &&
          !_isCrm &&
          _enquiry.status != SalesStatus.success) {
        continue;
      }
      Widget option;
      if (key == 'won') {
        option = _attachOption(
          Icons.emoji_events,
          'Outcome',
          const Color(0xFF2F9E44),
          () {
            Navigator.pop(ctx);
            _sendWonLostAction(provider);
          },
        );
      } else if (key == 'blocker') {
        option = _attachOption(
          Icons.block,
          'Raise Blocker',
          const Color(0xFFC92A2A),
          () {
            Navigator.pop(ctx);
            _raiseBlocker(provider);
          },
        );
      } else if (key == 'sample') {
        // Combined Visit/Demo tile — pop a chooser, then compose the pick.
        option = _attachOption(def!.icon, 'Visit/Demo', def.color, () {
          Navigator.pop(ctx);
          _chooseAndSendAction(
            provider,
            title: 'Visit or Demo',
            choices: [
              (
                label: 'Visit',
                icon: Icons.handyman,
                color: const Color(0xFF1098AD),
                key: 'sitevisit',
              ),
              (
                label: 'Demo',
                icon: Icons.inventory_2_outlined,
                color: const Color(0xFFAE3EC9),
                key: 'sample',
              ),
            ],
          );
        });
      } else if (key == 'meeting') {
        // Combined Meeting/Call tile — the Call pick routes to the schedule
        // -call dialog via the normal 'call' dispatch below.
        option = _attachOption(def!.icon, 'Meeting/Call', def.color, () {
          Navigator.pop(ctx);
          _chooseAndSendAction(
            provider,
            title: 'Meeting or Call',
            choices: [
              (
                label: 'Meeting',
                icon: Icons.groups,
                color: const Color(0xFF3B5BDB),
                key: 'meeting',
              ),
              (
                label: 'Call',
                icon: Icons.call,
                color: const Color(0xFF0C8599),
                key: 'call',
              ),
            ],
          );
        });
      } else {
        option = _attachOption(def!.icon, def.label, def.color, () {
          Navigator.pop(ctx);
          _sendActionMessage(provider, key);
        });
      }
      tiles.add(SizedBox(width: tileWidth, child: option));
    }
    return tiles;
  }

  /// Shared two-choice sheet for the combined Sales tiles (Visit/Demo,
  /// Meeting/Call). Presents labelled options and forwards the picked key to the
  /// normal [_sendActionMessage] dispatch, so a Call pick still opens the
  /// schedule-call dialog and a dated pick (Site Visit / Meeting / Demo) still
  /// gets its date picker.
  Future<void> _chooseAndSendAction(
    BaseModuleProvider provider, {
    required String title,
    required List<({String label, IconData icon, Color color, String key})>
    choices,
  }) async {
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryText,
                ),
              ),
            ),
            for (final c in choices)
              ListTile(
                leading: Icon(c.icon, color: c.color),
                title: Text(
                  c.label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.primaryText,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, c.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) _sendActionMessage(provider, picked);
  }

  void _showMessageActions(BaseModuleProvider provider) {
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Message Actions',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _themeColor,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  runSpacing: 16,
                  children: _actionSheetTiles(ctx, provider),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // ── Send Later (in-app only) ──────────────────────────────────────

  String get _outboxModuleTag =>
      _config.type == ModuleType.crm ? 'crm' : 'sales';

  /// Read every scheduled row across all modules/enquiries from the local
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

  /// Load this enquiry's held messages into memory, flush any already due, and
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
      if (r['taskId'] != _enquiry.id) continue;
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

  /// Send every held message whose time has passed through the normal provider
  /// path (so it persists + notifies like a live message), then drop it.
  Future<void> _flushDueScheduled() async {
    if (_scheduledMessages.isEmpty) return;
    final now = DateTime.now();
    final due = _scheduledMessages
        .where((m) => !m.scheduledAt!.isAfter(now))
        .toList();
    if (due.isEmpty) return;
    final provider = _readProvider(context);
    for (final m in due) {
      await provider.sendMessage(
        _enquiry.id,
        MessageModel(
          id: m.id,
          taskId: _enquiry.id,
          senderId: m.senderId,
          text: m.text,
          type: MessageType.text,
          createdAt: DateTime.now(),
        ),
      );
      await _persistScheduled(m, remove: true);
    }
    if (!mounted) return;
    setState(
      () => _scheduledMessages.removeWhere((m) => due.any((d) => d.id == m.id)),
    );
  }

  /// Composer action: pick a future date + time, then hold the draft text as a
  /// scheduled message (in-app only — no push at send time).
  Future<void> _scheduleCurrentMessage(BaseModuleProvider provider) async {
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
      taskId: _enquiry.id,
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
    if (!mounted) return;
    final provider = _readProvider(context);
    await provider.sendMessage(
      _enquiry.id,
      MessageModel(
        id: m.id,
        taskId: _enquiry.id,
        senderId: m.senderId,
        text: m.text,
        type: MessageType.text,
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() => _scheduledMessages.removeWhere((x) => x.id == m.id));
  }

  /// Pending-scheduled strip shown above the composer. Collapsed to a single
  /// tappable heading — "Scheduled (N)" — so a queue of "Send Later" items
  /// never crowds the input bar. Tapping opens [_showScheduledSheet] where the
  /// user can review each held message or cancel it before it fires.
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
  /// text, each with a delete action so the user can cancel it before it fires.
  /// Keeps its own local view via [StatefulBuilder] so a cancel refreshes the
  /// list live, and dismisses once the last item is removed.
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

  void _sendMessage(BaseModuleProvider provider) async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final userId = _currentUserId;
    if (userId.isEmpty) return;

    // If enquiry is still a draft, show message first, then prompt to activate
    final isDraft = _isDraftEnquiry;
    if (isDraft && !_draftDialogDismissed) {
      final draftMessage = MessageModel(
        id: Helpers.generateId(),
        taskId: _enquiry.id,
        senderId: userId,
        text: text,
        type: MessageType.text,
        createdAt: DateTime.now(),
      );
      setState(() {
        _messages.add(draftMessage);
        _rebuildDisplayMessages();
        _messageController.clear();
      });
      _scrollToBottom();

      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      final result = await _showDraftActivationDialog(suggestedTitle: text);
      if (result == null) {
        setState(() {
          _draftDialogDismissed = true;
        });
        provider.sendMessage(_enquiry.id, draftMessage);
        return;
      } else {
        final newTitle = (result['title']?.trim().isNotEmpty ?? false)
            ? result['title']!.trim()
            : 'Enter Enquiry title';
        // Generate displayId on activation (drafts skip ID generation)
        int? displayId = _enquiry.displayId;
        if (displayId == null) {
          displayId = await SequentialIdService().getNextId('sales');
        }
        // Activate: update title, remove isDraft flag, set displayId
        final updates = <String, dynamic>{
          'title': newTitle,
          'extraFields.isDraft': false,
          'displayId': displayId,
        };
        await provider.updateEnquiry(_enquiry.id, updates);
        final updatedExtra = Map<String, dynamic>.from(
          _enquiry.extraFields ?? {},
        );
        updatedExtra['isDraft'] = false;
        setState(() {
          _enquiry = _enquiry.copyWith(
            title: newTitle,
            displayId: displayId,
            extraFields: updatedExtra,
          );
        });
        provider.sendMessage(_enquiry.id, draftMessage);
        return;
      }
    }

    // Normal in-app message — optimistic UI
    // B6 (Task parity): an assignee who is not on the WhatWorks app cannot
    // receive this in-app, so offer the WhatsApp/SMS nudge first. The message
    // is persisted either way — only `deliveryMethod` differs, and cancelling
    // leaves the text in the composer instead of dropping it.
    final recipient = _externalRecipient();

    void persistAndSend(String deliveryMethod) {
      if (!mounted) return;
      _messageController.clear();
      final message = MessageModel(
        id: Helpers.generateId(),
        taskId: _enquiry.id,
        senderId: userId,
        text: text,
        type: MessageType.text,
        createdAt: DateTime.now(),
        deliveryMethod: deliveryMethod,
        replyToMessageId: _replyingToMessage?.id,
        replyToMessageText: _replyingToMessage?.text,
        replyToMessageSender: _replyingToMessage != null
            ? _getSenderName(_replyingToMessage!.senderId)
            : null,
      );

      // Optimistically add to local list for immediate display
      setState(() {
        _messages.add(message);
        _rebuildDisplayMessages();
        _replyingToMessage = null;
      });
      _scrollToBottom();

      // Fire-and-forget to provider (SQLite + Firestore)
      provider.sendMessage(_enquiry.id, message).then((_) {}).catchError((e) {
        print('[SalesDetail] Error sending message: $e');
        if (mounted) {
          _showMessageSendErrorSnackBar(message, e);
        }
      });
      // Unread badge is bumped inside BaseModuleProvider.sendMessage, merged
      // into the same atomic Firestore update that moves the enquiry's
      // updatedAt — so it fires on every send path (forwards, action messages,
      // status updates, retries) and can never be lost against a device that
      // delta-synced on the clock bump.
    }

    if (recipient != null && recipient.needsExternalNudge) {
      await chatDeliverToRecipient(
        recipient: recipient,
        title: 'Send Message',
        message: ExternalNotificationService().formatTextMessageForTitle(
          _enquiry.title.isNotEmpty ? _enquiry.title : _enquiry.clientName,
          _currentUserName,
          text,
        ),
        onSent: persistAndSend,
        accent: _themeColor,
      );
      return;
    }

    persistAndSend('in-app');
  }

  /// The assignee this card's out-of-app nudges should be routed through.
  ///
  /// EnquiryModel stores all three fields first-class, so — unlike TaskModel —
  /// there is no `extraFields` fallback to reach for and no persisted
  /// `assigneeIsOnApp` flag. resolveRecipient applies the app-wide convention
  /// instead: a resolved `assignedToUid` means the person is on the app.
  ExternalRecipient? _externalRecipient() =>
      ExternalNotificationService().resolveRecipient(
        assignedToName: _enquiry.assignedTo,
        assignedToUid: _enquiry.assignedToUid,
        assignedToPhone: _enquiry.assignedToPhone,
      );

  /// Maps a sales-cycle chat action to the pipeline stage it auto-advances the
  /// enquiry to (mirrors Won/Lost → Success/Lost). Returns null for actions
  /// that don't move the stage (reminder, follow-up, query, call, cash, etc.).
  String? _stageStatusForAction(String actionKey) {
    switch (actionKey) {
      case 'quotation':
        return 'quotation';
      case 'sample':
        return 'demo';
      case 'negotiation':
        return 'negotiation';
      default:
        return null;
    }
  }

  /// Pipeline stage an action key IMPLIES for the enquiry status — the open
  /// funnel stages plus the terminal outcomes. Delete-for-all uses this to
  /// reverse a deleted card's status side-effect (auto-advance above only
  /// needs the open stages, hence the narrower [_stageStatusForAction]).
  String? _pipelineStageForActionKey(String? actionKey) {
    switch (actionKey) {
      case 'quotation':
        return 'quotation';
      case 'sample':
        return 'demo';
      case 'negotiation':
        return 'negotiation';
      case 'won':
        return 'success';
      case 'lost':
        return 'lost';
      case 'dropped':
        return 'dropped';
      default:
        return null;
    }
  }

  /// Actions whose repeated occurrences are numbered in their chat + activity
  /// log labels ("Quotation 2", "Visit 1", "Reminder 3") — space form, no '#'.
  static const Set<String> _numberedActions = {
    'quotation',
    'sample',
    'delivery',
    'collect',
    'negotiation',
    'meeting',
    'sitevisit',
    'reminder',
    'followup',
    'query',
    'warning',
    // Outcomes number per family too (Won 1, Won 2 …) — re-marking a deal is
    // allowed and each superseding card is individually traceable.
    'won',
    'lost',
    'dropped',
    // Cash/Payment number per occurrence too ("Cash Added 2",
    // "Payment - Due 1") — they bypass the generic composer, so their
    // sequence is baked explicitly in _sendActionMessage.
    'cash',
    'payment',
  };

  /// Next occurrence number for [actionKey] = count of prior chat messages of
  /// the same detected type + 1. Called before the new card is appended.
  int _nextActionNumber(String actionKey) {
    var n = 0;
    for (final m in _messages) {
      if (Helpers.detectActionType(m.text) == actionKey) n++;
    }
    return n + 1;
  }

  void _sendActionMessage(
    BaseModuleProvider provider,
    String actionType,
  ) async {
    final userId = _currentUserId;
    if (userId.isEmpty) return;
    final action = _config.actionFor(actionType);
    if (action == null) return;
    // Cash AND Payment share the Cash/Payment dialog (sub-type + amount +
    // running balance / receivables). A payment entry must carry the
    // Due · Collected · Outstanding footer so the bubble shows the
    // outstanding — and tapping a 💳 card reopens the very dialog it was
    // created from (it used to fall to the generic note+date composer,
    // which is why the payment card appeared to open a different screen).
    if (actionType == 'cash' || actionType == 'payment') {
      final balance = Helpers.computeCashBalance(_messages.map((m) => m.text));
      // Receivables running totals (Due / Collected) — Payment is tracked here,
      // NOT folded into the cash balance.
      final (due, collected, _) = Helpers.computeReceivables(
        _messages.map((m) => m.text),
      );
      // Service Teams billing: offer cost-type chips on the entry.
      final result = await showCashActionDialog(
        context,
        currentBalance: balance,
        currentDue: due,
        currentCollected: collected,
        // One sheet, two sections: Sales + CRM get the Receivables (Due /
        // Collected) section; Task is unaffected (passes includeReceivables).
        includeReceivables: true,
        costCategories: _config.type == ModuleType.crm
            ? _costCategories
            : const [],
      );
      if (result == null || result.text.isEmpty || !mounted) return;
      // Bake the occurrence number ('Cash Added 2') into the card — the
      // dialog entry is a 💵 'cash' or 💳 'payment' action like any other.
      final entryKey = Helpers.detectActionType(result.text) ?? 'cash';
      final messageId = _dispatchActionMessage(
        provider,
        result.text,
        userId,
        sequenceNumber: _nextActionNumber(entryKey),
      );
      // Store id→category so the ticket shows a categorized totals row;
      // lives in extraFields (syncs with the card, no schema change).
      if (result.category != null && messageId != null) {
        final cats = Map<String, dynamic>.from(
          _enquiry.extraFields?['cashCats'] ?? const {},
        )..[messageId] = result.category!;
        provider.updateEnquiry(_enquiry.id, {'extraFields.cashCats': cats});
      }
      return;
    }
    // Schedule Call follows the Task module flow: date + time first, then a
    // note box, posted as a "📞 Call scheduled" card (both sides).
    if (actionType == 'call') {
      await _showScheduleCallDialog(provider);
      return;
    }
    // Request follows the Task module flow: note box -> "Approval requested"
    // card the other side can Approve / Send Back.
    if (actionType == 'approval') {
      await _requestApprovalAction(provider);
      return;
    }
    // Visit: the card heading already reads "Visit N - Scheduled", so the
    // body keeps just the emoji + note + date — the "Visit" label echo is
    // dropped (user rule, Task parity). 🛠️ stays as the detection token
    // (Helpers.detectActionType and the card header lead on the emoji).
    final bool isVisitCard = actionType == 'sitevisit';
    final prefix = isVisitCard
        ? action.emoji
        : '${action.emoji} ${action.label}';
    final icon = action.icon;
    final actionController = TextEditingController();
    // Date-picker actions always carry a visible date so the schedule is never
    // lost from the card/activity log. Picker rule (user): default to TOMORROW,
    // day-only — the appointment time stays null until the user taps the clock,
    // so an untouched schedule sends just the date to the chat.
    final pickNow = DateTime.now();
    DateTime? selectedDate = action.hasDatePicker
        ? DateTime(pickNow.year, pickNow.month, pickNow.day + 1)
        : null;
    // Optional appointment time alongside the date (Visit/Demo, Meeting, etc.).
    TimeOfDay? selectedTime;
    // Optional attachment picked in-dialog; uploaded right after the action card.
    PickedChatAttachment? pickedAttachment;
    final result = await showDialog<_ActionComposeResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(icon, color: _themeColor, size: 22),
              const SizedBox(width: 8),
              Text(action.label, style: const TextStyle(fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // "Previous Follow Up: 3" — how many cards of this action type
              // are already on record; the one being composed is numbered N+1.
              // Silent on the first occurrence (Task-module parity).
              PreviousActionHint(
                label: action.label,
                count: _nextActionNumber(actionType) - 1,
                color: _themeColor,
                emoji: action.emoji,
              ),
              TextField(
                controller: actionController,
                autofocus: true,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  hintText: 'Add details...',
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
              if (action.hasDatePicker) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: selectedDate ?? DateTime.now(),
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 365),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedDate = picked);
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: 18,
                          color: _themeColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          selectedDate == null
                              ? 'Add date'
                              : '${selectedDate!.day.toString().padLeft(2, '0')}/${selectedDate!.month.toString().padLeft(2, '0')}/${selectedDate!.year} (tap to change)',
                          style: TextStyle(
                            fontSize: 14,
                            color: selectedDate == null
                                ? AppTheme.lightText
                                : AppTheme.primaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Optional time alongside the date — Visit/Demo and other
                // scheduled actions can pin an appointment hour (no time keeps
                // the day-only format used before).
                InkWell(
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime:
                          selectedTime ?? const TimeOfDay(hour: 10, minute: 0),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedTime = picked);
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 18,
                          color: selectedTime == null
                              ? AppTheme.lightText
                              : _themeColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          selectedTime == null
                              ? 'Add time (optional)'
                              : '${selectedTime!.format(ctx)} (tap to change)',
                          style: TextStyle(
                            fontSize: 14,
                            color: selectedTime == null
                                ? AppTheme.lightText
                                : AppTheme.primaryText,
                          ),
                        ),
                        if (selectedTime != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: GestureDetector(
                              onTap: () =>
                                  setDialogState(() => selectedTime = null),
                              child: const Icon(
                                Icons.close,
                                size: 16,
                                color: AppTheme.lightText,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              // Attachment (optional) — posted right after the action card so
              // a photo/document rides with the Quotation/Visit/Demo record.
              const SizedBox(height: 8),
              buildChatAttachmentRow(
                picked: pickedAttachment,
                onChanged: (a) => setDialogState(() => pickedAttachment = a),
                accentColor: _themeColor,
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
                // Query notes are mandatory so a raised query always carries
                // context (Request/Query parity across modules).
                if (actionType == 'query' &&
                    actionController.text.trim().isEmpty) {
                  return;
                }
                Navigator.pop(
                  ctx,
                  _ActionComposeResult(
                    actionController.text.trim(),
                    attachment: pickedAttachment,
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final note = result.text;
    // Visit cards have a bare-emoji prefix — join with a space, no colon.
    String text = note.isNotEmpty
        ? (isVisitCard ? '$prefix $note' : '$prefix: $note')
        : prefix;
    if (selectedDate != null) {
      final d = selectedDate!;
      final dateStr =
          '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
      if (selectedTime != null) {
        final at = DateTime(
          d.year,
          d.month,
          d.day,
          selectedTime!.hour,
          selectedTime!.minute,
        );
        text = '$text on $dateStr at ${DateFormat('hh:mm a').format(at)}';
      } else {
        text = '$text on $dateStr';
      }
    }
    final int? seqForCard = _numberedActions.contains(actionType)
        ? _nextActionNumber(actionType)
        : null;
    // The composer attachment (if any) rides INSIDE the action card — one
    // message carrying both, not a separate attachment bubble below it.
    _dispatchActionMessage(
      provider,
      text,
      userId,
      sequenceNumber: seqForCard,
      attachment: result.attachment,
    );
    // Auto-advance the pipeline stage when a stage-mapped sales action is
    // posted — exactly like Won/Lost auto-set Success/Lost. Never regresses a
    // closed or already-decided (success/lost/dropped/cancel) enquiry, and
    // only fires for statuses this module actually defines.
    final stage = _stageStatusForAction(actionType);
    if (stage != null &&
        _enquiry.status != stage &&
        !_enquiry.isClosed &&
        _config.statusNames.contains(stage) &&
        _config.isOpenStatus(_enquiry.status)) {
      final curIdx = _config.statusNames.indexOf(_enquiry.status);
      final stageIdx = _config.statusNames.indexOf(stage);
      // Funnel guard: a stage action never drags the pipeline backwards.
      // Visit/Demo is stricter — it only claims a stage while the deal is
      // still Active; once a Quotation / Negotiation / Outcome is on record
      // a visit must leave the status alone.
      final bool allowAdvance = actionType == 'sample'
          ? curIdx <= 0
          : stageIdx >= curIdx;
      if (allowAdvance) {
        // Advance the pipeline silently — the action card above is the record.
        _changeStatus(provider, stage, emitMessage: false);
      }
    }
  }

  /// Deal Outcome dialog: outcome toggle + reason chips + optional notes
  /// + optional enquiry status update. Re-marking is allowed — each Send posts
  /// a new numbered outcome card (Won 2 supersedes Won 1) and re-advances the
  /// enquiry status, so a corrected decision replaces the old one in the log.
  void _sendWonLostAction(BaseModuleProvider provider) async {
    final userId = _currentUserId;
    if (userId.isEmpty) return;
    int outcome = 0; // 0=won, 1=lost, 2=dropped
    String reason = 'Price';
    bool updateStatus = true;
    final notesController = TextEditingController();
    const reasons = [
      'Price',
      'Competitor',
      'No Response',
      'Requirement Changed',
      'Other',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.emoji_events, color: _themeColor, size: 22),
              const SizedBox(width: 8),
              const Text('Deal Outcome', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('\ud83c\udfc6 Won')),
                        selected: outcome == 0,
                        selectedColor: const Color(0xFF2F9E44),
                        backgroundColor: Colors.white,
                        showCheckmark: false,
                        elevation: 0,
                        labelStyle: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: outcome == 0
                              ? Colors.white
                              : const Color(0xFF2F9E44),
                        ),
                        side: const BorderSide(
                          color: Color(0xFF2F9E44),
                          width: 1,
                        ),
                        onSelected: (_) => setDialogState(() => outcome = 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('\u274c Lost')),
                        selected: outcome == 1,
                        selectedColor: const Color(0xFFE03131),
                        backgroundColor: Colors.white,
                        showCheckmark: false,
                        elevation: 0,
                        labelStyle: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: outcome == 1
                              ? Colors.white
                              : const Color(0xFFE03131),
                        ),
                        side: const BorderSide(
                          color: Color(0xFFE03131),
                          width: 1,
                        ),
                        onSelected: (_) => setDialogState(() => outcome = 1),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('📉 Drop')),
                        selected: outcome == 2,
                        selectedColor: const Color(0xFF868E96),
                        backgroundColor: Colors.white,
                        showCheckmark: false,
                        elevation: 0,
                        labelStyle: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: outcome == 2
                              ? Colors.white
                              : const Color(0xFF868E96),
                        ),
                        side: const BorderSide(
                          color: Color(0xFF868E96),
                          width: 1,
                        ),
                        onSelected: (_) => setDialogState(() => outcome = 2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Reason',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in reasons)
                      ChoiceChip(
                        label: Text(r, style: const TextStyle(fontSize: 12)),
                        selected: reason == r,
                        selectedColor: _themeColor.withOpacity(0.15),
                        onSelected: (_) => setDialogState(() => reason = r),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  maxLength: 300,
                  decoration: InputDecoration(
                    hintText: 'Notes (optional)...',
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
                CheckboxListTile(
                  value: updateStatus,
                  onChanged: (v) =>
                      setDialogState(() => updateStatus = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _themeColor,
                  title: const Text(
                    'Also update enquiry status',
                    style: TextStyle(fontSize: 13),
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
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final action = switch (outcome) {
      1 => ModuleActions.lost,
      2 => ModuleActions.dropped,
      _ => ModuleActions.won,
    };
    final notes = notesController.text.trim();
    final text = notes.isNotEmpty
        ? '${action.emoji} ${action.label} \u2014 $reason: $notes'
        : '${action.emoji} ${action.label} \u2014 $reason';
    // Number the card per outcome family (Won 1, Won 2, Lost 1 …) so a
    // corrected decision is a fresh, individually traceable record.
    _dispatchActionMessage(
      provider,
      text,
      userId,
      sequenceNumber: _nextActionNumber(action.key),
    );
    if (updateStatus) {
      final targetStatus = switch (outcome) {
        1 => 'lost',
        2 => 'dropped',
        _ => 'success',
      };
      if (_config.statusNames.contains(targetStatus)) {
        // The outcome card is the record — no separate status-change card.
        _changeStatus(provider, targetStatus, emitMessage: false);
      }
    }
  }

  // ---- Call sheet: users in the enquiry with numbers (copy / dial) ----

  /// Collect all enquiry participants that have a phone number.
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
      _enquiry.createdByName ?? 'Unknown',
      _enquiry.createdByPhone,
      uid: _enquiry.createdBy,
    );

    // Assignees (model getters fall back to the single assignee)
    final names = _enquiry.assigneeNames;
    final phones = _enquiry.assigneePhones;
    final uids = _enquiry.assigneeUids;
    for (int i = 0; i < names.length; i++) {
      add(
        'Assignee',
        names[i],
        i < phones.length ? phones[i] : null,
        uid: i < uids.length ? uids[i] : null,
      );
    }

    // Customer
    add('Customer', _enquiry.clientName, _enquiry.clientPhone);

    return entries;
  }

  /// Resolve a phone number for a participant from cached team members when
  /// the enquiry didn't store one. Matches by UID first, then by
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

  /// AppBar call icon: list users in the enquiry with numbers (copy or call).
  void _showEnquiryCallSheet() {
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
                    'No phone numbers available for this enquiry.',
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
            backgroundColor: _themeColor.withValues(alpha: 0.15),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: _themeColor,
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
            icon: const Icon(Icons.call, size: 22),
            color: _themeColor,
            tooltip: 'Call',
            onPressed: () {
              Navigator.pop(sheetCtx);
              _placeCall(name, phone);
            },
          ),
          IconButton(
            icon: const Icon(Icons.chat, size: 22),
            color: const Color(0xFF25D366),
            tooltip: 'WhatsApp',
            onPressed: () {
              Navigator.pop(sheetCtx);
              CustomerCommsService.instance.whatsapp(
                context,
                CustomerInfo(name: name, phone: phone),
                record: (text) async {
                  _dispatchActionMessage(
                    _readProvider(context),
                    text,
                    _currentUserId,
                  );
                },
                byName: _currentUserName,
              );
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
      print('[SalesDetail] Failed to launch dialer: $e');
    }
    if (launched) {
      _dispatchActionMessage(
        _readProvider(context),
        '📞 Call made to $name ($phone) by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
        _currentUserId,
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

  /// Shared tail for action messages: optimistic append + send.
  /// Returns the local message id (the key [cashCats] entries are stored
  /// under — both the picker and the totals row read the same _messages).
  String? _dispatchActionMessage(
    BaseModuleProvider provider,
    String text,
    String userId, {
    SystemMessageType? systemType,
    DateTime? scheduledAt,
    int? sequenceNumber,
    PickedChatAttachment? attachment,
    String? referenceMessageId,
  }) {
    final message = MessageModel(
      id: Helpers.generateId(),
      taskId: _enquiry.id,
      senderId: userId,
      text: text,
      type: MessageType.system,
      systemType: systemType ?? SystemMessageType.regular,
      sequenceNumber: sequenceNumber,
      scheduledAt: scheduledAt,
      // An action composer attachment rides INSIDE the card (one message):
      // the file lands on the same message id once uploaded.
      fileUrl: attachment != null ? 'pending' : null,
      fileName: attachment?.name,
      createdAt: DateTime.now(),
      deliveryMethod: 'in-app',
      // Response notifications (Done / Reply / Resolve) carry a pointer to the
      // action card they refer to so tapping jumps back to it (Task parity).
      // replyToMessageId is already persisted and never otherwise set on a
      // system card, so this needs no schema change.
      replyToMessageId: referenceMessageId,
    );
    // Postings always land the user on the newest card — actions, status
    // edits and posts jump the chat back to the live end of the thread.
    setState(() {
      _messages.add(message);
      _rebuildDisplayMessages();
    });
    _scrollToBottom();
    provider.sendMessage(_enquiry.id, message).then((_) {}).catchError((e) {
      print('[SalesDetail] Error sending action message: $e');
    });
    if (attachment != null) {
      chatAttachToExistingMessage(message, attachment);
    }
    return message.id;
  }

  // ── Message Options (Long Press) ──────────────────────────────────────

  // WhatsApp-style reply preview bar above the text input.
  // Rendered by DetailChatPlumbingMixin — the same widget Task Detail uses.
  Widget _buildReplyPreview() => buildChatReplyPreview(
    _replyingToMessage!,
    senderName: _getSenderName(_replyingToMessage!.senderId),
    accent: _themeColor,
    onCancel: () => setState(() => _replyingToMessage = null),
  );

  void _showMessageOptions(MessageModel message, bool isMe, int index) {
    final messageAge = DateTime.now().difference(message.createdAt);
    final canEdit =
        isMe &&
        message.type == MessageType.text &&
        message.senderId != 'system' &&
        !message.isEdited && // Task parity: no re-editing an edited message
        messageAge.inMinutes < 15;
    // Forward + BOTH Delete options are reserved for typed messages and
    // attachments — action cards (Quotation/Visit/Payment/…), system edits
    // and status changes never offer them (Task-module parity). The
    // text-keyword check only applies to plain TEXT so an attachment named
    // e.g. "payment_receipt.pdf" stays deletable.
    final isActionOrEdit =
        message.type == MessageType.system ||
        (message.type == MessageType.text &&
            Helpers.detectActionType(message.text) != null);
    final canForward = !isActionOrEdit && !message.isEdited;
    final canDeleteForMe = !isActionOrEdit && !message.isEdited;
    final canDeleteForEveryone =
        isMe && !isActionOrEdit && messageAge.inMinutes < 60;
    // Reply: every non-system message can be quoted (Task parity).
    final canReply = message.type != MessageType.system;

    // Share outside WhatWorks: same rule as Forward/Delete — typed messages
    // and attachments only. Action cards, status changes and edits are not
    // shareable off-app and are also excluded from the last-5 trail (both
    // go through _isShareableMessage).
    final canShareOutside = _isShareableMessage(message);

    showModalBottomSheet(
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
              decoration: BoxDecoration(
                color: AppTheme.lightGrey,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
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
            const Divider(height: 1),
            // Reply option (WhatsApp-style quoted reply)
            if (canReply)
              ListTile(
                leading: Icon(Icons.reply, color: _themeColor),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _replyingToMessage = message;
                  });
                },
              ),
            // Forward option (typed messages + attachments only)
            if (canForward)
              ListTile(
                leading: Icon(Icons.forward, color: _themeColor),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(context);
                  _forwardMessage(message);
                },
              ),
            // Share outside WhatWorks (WhatsApp / SMS to people without the app)
            if (canShareOutside)
              ListTile(
                leading: Icon(Icons.ios_share, color: _themeColor),
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
                leading: Icon(Icons.dynamic_feed, color: _themeColor),
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
            // Seen by option (only for own non-system messages)
            if (isMe && message.senderId != 'system')
              ListTile(
                leading: Icon(Icons.visibility, color: _themeColor),
                title: const Text('Seen by'),
                onTap: () {
                  Navigator.pop(context);
                  showSeenByDialog(message);
                },
              ),
            if (canEdit)
              ListTile(
                leading: Icon(Icons.edit, color: _themeColor),
                title: const Text('Edit Message'),
                onTap: () {
                  Navigator.pop(context);
                  _editMessage(message, index);
                },
              ),
            // Delete for me (typed messages + attachments only)
            if (canDeleteForMe)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete for Me'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessageForMe(message, index);
                },
              ),
            if (canDeleteForEveryone)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for Everyone'),
                subtitle: Text(
                  'Available for ${60 - messageAge.inMinutes} more minutes',
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

  // ── Outside share (WhatsApp / SMS for people without the app) ──────────
  // Mirrors Task Detail exactly; CRM inherits it through `_config`.

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

  /// Flatten one chat message for the share body: media travels as its 📎 label,
  /// a reply keeps a short quote, an edit keeps its suffix.
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

  /// Item header + entries. `_config` supplies the item name and theme colour,
  /// so Sales says "Enquiry" and CRM says "Ticket" with no extra branching.
  OutsideSharePayload _buildSharePayload(List<MessageModel> messages) {
    final total = _enquiry.milestones.length;
    final done = _enquiry.milestones.where((m) => m.isCompleted).length;
    final status = total > 0
        ? '${_statusLabel(_enquiry.status)} · Milestones $done/$total'
        : _statusLabel(_enquiry.status);
    final title = _enquiry.title.trim().isNotEmpty
        ? _enquiry.title.trim()
        : _enquiry.clientName;
    return OutsideSharePayload(
      itemLabel: _config.itemName,
      title: title,
      displayId: _enquiry.displayId,
      byName: _getSenderName(_enquiry.createdBy),
      toName: _enquiry.assignedTo,
      deadlineLabel: _enquiry.deadline == null
          ? null
          : Helpers.formatDeadlineBadge(_enquiry.deadline),
      statusLine: status,
      entries: messages.map(_shareEntryOf).toList(),
      recipientName: _enquiry.assignedTo,
      recipientPhone: _enquiry.assignedToPhone,
      replyPhone: context.read<AuthProvider>().userModel?.phone ?? '',
      themeColor: _themeColor,
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
    _dispatchActionMessage(
      _readProvider(context),
      OutsideShareService().systemMessageFor(
        result: result,
        byName: _currentUserName,
        atLabel: Helpers.formatDateTime(DateTime.now()),
      ),
      _currentUserId,
    );
  }

  void _forwardMessage(MessageModel message) async {
    // Navigate to shared forward target screen
    final targets = await Navigator.push<List<ForwardTarget>>(
      context,
      MaterialPageRoute(
        builder: (_) => ForwardTargetScreen(sourceParentId: _enquiry.id),
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
          await _readProvider(context).sendMessage(target.id, forwardedMessage);
        }
        successCount++;
      } catch (e) {
        print(
          '[SalesDetail] Error forwarding to ${target.type} ${target.id}: $e',
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
          backgroundColor: _themeColor,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
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
                setState(() {
                  _messages[index] = message.copyWith(
                    text: newText,
                    isEdited: true,
                  );
                });
                try {
                  await _readProvider(
                    context,
                  ).updateMessage(_enquiry.id, message.id, {
                    'text': newText,
                    'isEdited': true,
                    'editedAt': DateTime.now().toIso8601String(),
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Message edited successfully'),
                      backgroundColor: _themeColor,
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to edit: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
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
              setState(() {
                _messages.removeAt(index);
                _rebuildDisplayMessages();
              });
              try {
                await _readProvider(context).updateMessage(
                  _enquiry.id,
                  message.id,
                  {
                    'deletedFor': FieldValue.arrayUnion([_currentUserId]),
                    'deletedForUid': _currentUserId, // For local SQLite update
                  },
                );
              } catch (_) {}
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
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

  void _deleteMessageForEveryone(MessageModel message, int index) {
    // Audit-trail guard (menu-gating parity): action/status/edit cards — and
    // any action card whose child action (reply / done / approve) has already
    // landed — are NEVER delete-for-everyone, regardless of age or caller
    // (Task module parity).
    if (message.type == MessageType.system ||
        (message.type == MessageType.text &&
            Helpers.detectActionType(message.text) != null) ||
        message.isReplied ||
        message.isFollowUpDone) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete for Everyone'),
        content: const Text('This will delete the message for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final salesProvider = _readProvider(context);
                await salesProvider.updateMessage(_enquiry.id, message.id, {
                  'text': '🗑️ This message was deleted',
                  'deleted': true,
                });

                // Also remove from the shared actions table if this message was
                // an action (parity with TaskDetail's delete-for-everyone).
                await LocalDatabaseService().deleteAction(message.id);

                setState(() {
                  final i = _messages.indexWhere((m) => m.id == message.id);
                  if (i != -1) {
                    _messages[i] = MessageModel(
                      id: message.id,
                      taskId: _enquiry.id,
                      senderId: message.senderId,
                      text: '🗑️ This message was deleted',
                      type: MessageType.system,
                      createdAt: message.createdAt,
                    );
                    _rebuildDisplayMessages();
                  }
                });

                // Deleting an action card also reverses its status
                // side-effect: when the enquiry still sits on the stage this
                // card set, walk the surviving action history and restore the
                // stage implied by the last remaining stage/outcome card (or
                // the module's default stage). Silent change — the tombstone
                // card is the record of the reversal.
                final removedStage = _pipelineStageForActionKey(
                  Helpers.detectActionType(message.text),
                );
                if (removedStage != null &&
                    _enquiry.status == removedStage &&
                    _config.statusNames.contains(removedStage)) {
                  var target = _config.defaultStatusName;
                  for (final m in _messages) {
                    final s = _pipelineStageForActionKey(
                      Helpers.detectActionType(m.text),
                    );
                    if (s != null && _config.statusNames.contains(s)) {
                      target = s;
                    }
                  }
                  if (target != _enquiry.status) {
                    _changeStatus(salesProvider, target, emitMessage: false);
                  }
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Message deleted for everyone'),
                    backgroundColor: Colors.red,
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed: $e'),
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

  // ── Image Viewer ──────────────────────────────────────────────────────

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

  // ── Attachment Sheet ──────────────────────────────────────────────────

  void _showAttachmentSheet() {
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Attachments',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _themeColor,
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
                      // Was a dead tile: the sheet closed and nothing happened.
                      // Now shares the shared-mixin implementation Task uses.
                      chatShareLocation();
                    },
                  ),
                  _attachOption(
                    Icons.contact_phone,
                    'Contact',
                    Colors.teal,
                    () {
                      Navigator.pop(ctx);
                      chatShareContact();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
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
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── Manage Assignee ───────────────────────────────────────────────────

  void _manageAssignee(BaseModuleProvider provider) async {
    final planType =
        context.read<AuthProvider>().userModel?.planType ?? 'basic';
    final maxAssigneeLimit = PaywallLimits.maxSalesAssignees(planType);

    // Build current assignee lists from enquiry
    List<String> currentAssigneeNames = List<String>.from(
      _enquiry.assigneeNames,
    );
    List<String> currentAssigneeUids = List<String>.from(_enquiry.assigneeUids);
    List<String> currentAssigneePhones = List<String>.from(
      _enquiry.assigneePhones,
    );

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
                  // Current assignees count
                  Text(
                    '${currentAssigneeNames.length}/$maxAssigneeLimit assignees',
                    style: TextStyle(
                      fontSize: 12,
                      color: currentAssigneeNames.length >= maxAssigneeLimit
                          ? Colors.red
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Current assignee list
                  ...List.generate(currentAssigneeNames.length, (index) {
                    final name = currentAssigneeNames[index];
                    final avatarUrl = AvatarCacheService().urlFor(
                      uid: index < currentAssigneeUids.length
                          ? currentAssigneeUids[index]
                          : null,
                      phone: index < currentAssigneePhones.length
                          ? currentAssigneePhones[index]
                          : null,
                      name: name,
                    );
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          AppAvatar(
                            avatarUrl: avatarUrl,
                            initials: Helpers.getInitials(name),
                            radius: 14,
                            color: _themeColor,
                            fontSize: 11,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          // Creator-only removal: an assignee (including the
                          // current user) must not be able to drop anyone from
                          // the enquiry — only the creator manages the
                          // assignee list. Non-creators see no Remove action.
                          if (_enquiry.createdBy == _currentUserId)
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                color: Colors.red,
                                size: 20,
                              ),
                              onPressed: () {
                                setDialogState(() {
                                  currentAssigneeNames.removeAt(index);
                                  if (index < currentAssigneeUids.length) {
                                    currentAssigneeUids.removeAt(index);
                                  }
                                  if (index < currentAssigneePhones.length) {
                                    currentAssigneePhones.removeAt(index);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                    );
                  }),
                  const Divider(),
                  // Add assignee button — creator only, matching the Remove
                  // gating above: assignee management is the creator's prerogative.
                  if (_enquiry.createdBy == _currentUserId)
                    InkWell(
                      onTap: () async {
                        if (currentAssigneeNames.length >= maxAssigneeLimit) {
                          final higherCap = PaywallLimits.maxAssignees(
                            'business',
                          );
                          showPaywallDialog(
                            context,
                            feature:
                                'Maximum $maxAssigneeLimit assignee${maxAssigneeLimit > 1 ? 's' : ''} allowed on ${PaywallLimits.planLabel(planType)} plan.',
                            detail: higherCap > maxAssigneeLimit
                                ? 'Upgrade your plan to add up to $higherCap assignees per enquiry.'
                                : 'This is the maximum number of assignees per enquiry on all plans.',
                          );
                          return;
                        }
                        final picker = ContactPickerService();
                        final contact = await picker.showContactPicker(context);
                        if (contact == null || !mounted) return;
                        setDialogState(() {
                          // Add unconditionally, then collapse by identity so a
                          // person already listed under a different name (same
                          // phone/UID) is never double-listed.
                          currentAssigneeNames.add(contact.name);
                          currentAssigneeUids.add(contact.uid ?? '');
                          currentAssigneePhones.add(
                            Helpers.normalizePhone(contact.phone ?? '') ??
                                contact.phone ??
                                '',
                          );
                          dedupAssignees();
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.add_circle_outline,
                              color: _themeColor,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Add Assignee',
                              style: TextStyle(
                                color: _themeColor,
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
                  if (currentAssigneeNames.isEmpty) {
                    // Unassigning the last/only assignee — previously a silent
                    // no-op (just popped the sheet). Flip the card to a genuine
                    // "Unassigned" state: blank the assignee fields, keep only
                    // the creator in participants, clear the assignee identity
                    // lists and post a system message. CRM inherits this shared
                    // Sales screen, so the same edit covers both modules.
                    final removedNames = _enquiry.assigneeNames;
                    final removedText = removedNames
                        .where((n) => n.trim().isNotEmpty)
                        .join(', ');
                    final creatorUid = _enquiry.createdBy;
                    final unassignUpdates = <String, dynamic>{
                      'assignedTo': '',
                      'assignedToUid': '',
                      'assignedToPhone': '',
                      'participants': [creatorUid],
                      'extraFields.assigneeNames': <String>[],
                      'extraFields.assigneeUids': <String>[],
                      'extraFields.assigneePhones': <String>[],
                    };
                    await provider.updateEnquiry(_enquiry.id, unassignUpdates);
                    Navigator.pop(ctx);

                    final unTs = Helpers.formatDateTime(DateTime.now());
                    final unMsg = MessageModel(
                      id: '',
                      taskId: _enquiry.id,
                      senderId: _currentUserId,
                      text:
                          '👤 Assignee Removed: ${removedText.isEmpty ? 'all assignees' : removedText}, Assignee = Unassigned by $_currentUserName at $unTs',
                      type: MessageType.system,
                      createdAt: DateTime.now(),
                    );
                    provider.sendMessage(_enquiry.id, unMsg);
                    return;
                  }
                  final previousAssigneeNames = _enquiry.assigneeNames;

                  // Resolve missing UIDs by looking up users by phone number
                  // Check SQLite cache first, then Firestore if not found
                  final normalizedPhones = currentAssigneePhones
                      .map((p) => Helpers.normalizePhone(p) ?? p)
                      .toList();
                  final db = LocalDatabaseService();
                  // Resolve missing UIDs in parallel
                  final resolveFutures = <Future<void>>[];
                  for (int i = 0; i < currentAssigneeNames.length; i++) {
                    if (i >= currentAssigneeUids.length ||
                        currentAssigneeUids[i].isEmpty) {
                      if (i < normalizedPhones.length) {
                        final phone = normalizedPhones[i];
                        final index = i;
                        resolveFutures.add(
                          (() async {
                            try {
                              // Check SQLite cache first
                              String? resolvedUid = await db.getCachedUid(
                                phone,
                              );
                              if (resolvedUid != null) {
                                print(
                                  '[SalesDetail] Cache hit for phone $phone: $resolvedUid',
                                );
                              } else {
                                // Cache miss — query Firestore
                                final snapshot = await FirebaseFirestore
                                    .instance
                                    .collection('users')
                                    .where('phone', isEqualTo: phone)
                                    .limit(1)
                                    .get();
                                if (snapshot.docs.isNotEmpty) {
                                  resolvedUid = snapshot.docs.first.id;
                                  // Cache the result for future lookups
                                  await db.cacheUser(resolvedUid, phone);
                                  print(
                                    '[SalesDetail] Resolved and cached UID for phone $phone: $resolvedUid',
                                  );
                                }
                              }
                              if (resolvedUid != null) {
                                while (currentAssigneeUids.length <= index) {
                                  currentAssigneeUids.add('');
                                }
                                currentAssigneeUids[index] = resolvedUid;
                              }
                            } catch (e) {
                              print(
                                '[SalesDetail] Error resolving UID for phone $phone: $e',
                              );
                            }
                          })(),
                        );
                      }
                    }
                  }
                  await Future.wait(resolveFutures);
                  // Keep the identity lists index-aligned with names (Task
                  // parity). Previously unresolved UIDs were stripped here,
                  // compressing assigneeUids so a name no longer matched its
                  // UID/phone slot — the root cause of a group card resolving
                  // the wrong person's (or no) avatar. Pad with '' placeholders
                  // instead; the EnquiryModel getters filter empties, so group
                  // detection and the count badge are unaffected, and the card
                  // resolves the leader by slot then falls back to the contact
                  // book for any still-blank placeholder.
                  while (currentAssigneeUids.length <
                      currentAssigneeNames.length) {
                    currentAssigneeUids.add('');
                  }
                  while (currentAssigneePhones.length <
                      currentAssigneeNames.length) {
                    currentAssigneePhones.add('');
                  }

                  final primaryName = currentAssigneeNames.first;
                  // Primary identity = the LEADER's slot (index 0), which may
                  // still be a blank placeholder when unresolved — that is fine
                  // and matches Task; the card resolves the leader independently.
                  final primaryUid = currentAssigneeUids.isNotEmpty
                      ? currentAssigneeUids.first
                      : '';
                  final primaryPhone = currentAssigneePhones.isNotEmpty
                      ? currentAssigneePhones.first
                      : '';

                  // Build participants array (creator + all assignees)
                  final creatorUid = _enquiry.createdBy;
                  final allParticipantUids = <String>{
                    creatorUid,
                    ...currentAssigneeUids.where((uid) => uid.isNotEmpty),
                  };

                  final updates = <String, dynamic>{
                    'assignedTo': primaryName,
                    'assignedToUid': primaryUid,
                    'assignedToPhone': primaryPhone,
                    'extraFields.assigneeNames': currentAssigneeNames,
                    'extraFields.assigneeUids': currentAssigneeUids,
                    'extraFields.assigneePhones': currentAssigneePhones,
                    'participants': allParticipantUids.toList(),
                  };

                  await provider.updateEnquiry(_enquiry.id, updates);
                  Navigator.pop(ctx);

                  // Send system message for assignee change.
                  //
                  // B5: Task's canonical format — emoji, Removed-before-Added
                  // order, assignee count, actor and timestamp — so the shared
                  // system-message card, the Activity log classifier and the
                  // durable system_logs row all recognise it. The previous
                  // "Added: X by Y" shape matched no parser at all: it rendered
                  // as a generic "Action" card, fell outside every filter chip
                  // and carried no record of when it happened.
                  final addedNames = currentAssigneeNames
                      .where((n) => !previousAssigneeNames.contains(n))
                      .toList();
                  final removedNames = previousAssigneeNames
                      .where((n) => !currentAssigneeNames.contains(n))
                      .toList();

                  final totalAssignees = currentAssigneeNames.length;
                  final assigneeCountText = totalAssignees == 1
                      ? '1 assignee'
                      : '$totalAssignees assignees';
                  final timestamp = Helpers.formatDateTime(DateTime.now());

                  String changeText = '';
                  if (removedNames.isNotEmpty && addedNames.isNotEmpty) {
                    changeText =
                        '👤 Assignee Updated: Removed ${removedNames.join(', ')}; Added ${addedNames.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                  } else if (removedNames.isNotEmpty) {
                    changeText =
                        '👤 Assignee Removed: ${removedNames.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                  } else if (addedNames.isNotEmpty) {
                    changeText =
                        '👤 Assignee Added: ${addedNames.join(', ')}, Assignee = $assigneeCountText by $_currentUserName at $timestamp';
                  }

                  if (changeText.isNotEmpty) {
                    final msg = MessageModel(
                      id: '',
                      taskId: _enquiry.id,
                      senderId: _currentUserId,
                      text: changeText,
                      type: MessageType.system,
                      createdAt: DateTime.now(),
                    );
                    provider.sendMessage(_enquiry.id, msg);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: _themeColor),
                child: const Text(
                  'Save',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Edit Deadline Inline ──────────────────────────────────────────────

  void _editDeadlineInline(BaseModuleProvider provider) async {
    // Only the card creator can change the deadline — assignees get a hint
    // (parity with the task module's _editDeadlineInline).
    if (_enquiry.createdBy != _currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the card creator can change the deadline'),
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
          _enquiry.deadline ?? DateTime.now().add(const Duration(days: 7)),
      initialRule: _enquiry.recurrenceRule,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    final finalDateTime = DateTime(
      picked.date.year,
      picked.date.month,
      picked.date.day,
      23,
      59,
    );
    final oldDeadline = _enquiry.deadline != null
        ? Helpers.formatDate(_enquiry.deadline!)
        : 'No deadline';

    // Recurrence BEFORE the edit — compare with the picked rule so the system
    // message states the repeat change explicitly instead of only
    // "Deadline updated: X → X". Read before updateEnquiry mutates the card.
    final oldRule = _enquiry.recurrenceRule;

    // Time-driven recurrence (Phase-2B): a chosen rule re-anchors the series at
    // the new deadline. A card with no series yet becomes the ANCHOR (seriesId =
    // its own id, nextDue = first occurrence after the deadline); an existing
    // series keeps its id. "Does not repeat" (rule == null) clears the trio and
    // ends the series. The shared materializer generates occurrences from here.
    final rule = picked.rule;
    final Map<String, dynamic> update = {'deadline': finalDateTime};
    if (rule == null) {
      update['clearRecurrence'] = true;
      update['recurrence'] = null;
      update['seriesId'] = null;
      update['nextDue'] = null;
    } else {
      update['recurrence'] = rule.toJson();
      update['seriesId'] = _enquiry.seriesId ?? _enquiry.id;
      update['nextDue'] = rule.nextOccurrenceAfter(finalDateTime);
    }
    await provider.updateEnquiry(_enquiry.id, update);

    final newDeadline = Helpers.formatDate(finalDateTime);
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
      final msg = MessageModel(
        id: '',
        taskId: _enquiry.id,
        senderId: _currentUserId,
        text:
            '📅 $core$tail by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
        type: MessageType.system,
        createdAt: DateTime.now(),
      );
      provider.sendMessage(_enquiry.id, msg);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deadline updated: $newDeadline'),
          backgroundColor: _themeColor,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Edit Progress Inline ──────────────────────────────────────────────

  Future<void> _editProgressInline(BaseModuleProvider provider) async {
    final currentProgress = (_enquiry.progress * 100).toInt();
    double sliderValue = currentProgress.toDouble();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Row(
            children: [
              Icon(Icons.trending_up, color: _themeColor),
              const SizedBox(width: 8),
              const Text('Update Progress'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${sliderValue.toInt()}%',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: _themeColor,
                ),
              ),
              const SizedBox(height: 16),
              Slider(
                value: sliderValue,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${sliderValue.toInt()}%',
                activeColor: _themeColor,
                onChanged: (value) => setDialogState(() => sliderValue = value),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => setDialogState(() => sliderValue = 0),
                    child: const Text('0%'),
                  ),
                  TextButton(
                    onPressed: () => setDialogState(() => sliderValue = 25),
                    child: const Text('25%'),
                  ),
                  TextButton(
                    onPressed: () => setDialogState(() => sliderValue = 50),
                    child: const Text('50%'),
                  ),
                  TextButton(
                    onPressed: () => setDialogState(() => sliderValue = 75),
                    child: const Text('75%'),
                  ),
                  TextButton(
                    onPressed: () => setDialogState(() => sliderValue = 100),
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
                await provider.updateEnquiry(_enquiry.id, {
                  'progress': newProgress,
                });
                final oldProgress = currentProgress;
                final newProgressPercent = (newProgress * 100).toInt();
                // Only record a chat message when progress actually moved
                // (no 0% → 0% / same-value noise) — Task-detail parity.
                if (oldProgress != newProgressPercent) {
                  final msg = MessageModel(
                    id: '',
                    taskId: _enquiry.id,
                    senderId: _currentUserId,
                    text:
                        'Progress updated: ${oldProgress}% → $newProgressPercent% by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
                    type: MessageType.system,
                    createdAt: DateTime.now(),
                  );
                  provider.sendMessage(_enquiry.id, msg);
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Progress updated to $newProgressPercent%'),
                      backgroundColor: _themeColor,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    );
  }

  int _getEnquiryDurationDays() {
    if (_enquiry.deadline == null) return 0;
    return _enquiry.deadline!.difference(_enquiry.createdAt).inDays;
  }

  // ── Draft Activation Dialog ───────────────────────────────────────────

  Future<Map<String, String>?> _showDraftActivationDialog({
    required String suggestedTitle,
  }) async {
    final titleController = TextEditingController(text: suggestedTitle);
    return showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Activate Enquiry',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set a title for this enquiry:',
              style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              maxLength: 100,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Enter enquiry title',
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Skip'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(ctx, {'title': titleController.text.trim()}),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Activate'),
          ),
        ],
      ),
    );
  }

  // ── Activity Summary Log ──────────────────────────────────────────────

  /// One-time backfill: mirror pre-existing action messages into system_logs so
  /// enquiries created before the durable log existed recover one too (doc id =
  /// message id, so this is idempotent). Parity with Task's _backfillSystemLogs.
  void _backfillSystemLogs() {
    if (_systemLogBackfillDone || _messages.isEmpty) return;
    _systemLogBackfillDone = true;
    final known = <String>{for (final l in _recoveredLogs) l.id};
    var written = 0;
    for (final m in _messages) {
      if (written >= 200) break;
      if (known.contains(m.id)) continue;
      // Same gate the Activity log renders on, and the same action label the
      // provider's write-through uses, so a doc written twice is byte-identical.
      if (m.type != MessageType.system) continue;
      // Response notifications update the original card in place — never
      // mirror them as separate durable log rows.
      if (_isResponseNotificationText(m.text)) continue;
      written++;
      FirebaseService().writeModuleSystemLog(
        enquiryId: _enquiry.id,
        collection: _config.firestoreCollection,
        messageId: m.id,
        action: BaseModuleService.systemLogAction(m.text),
        performedBy: m.senderId,
        details: m.text,
        createdAt: m.createdAt,
      );
    }
  }

  /// Response notifications (Reply/Done/Resolve) — they update the original
  /// action card in place (chip flips to Actioned/Closed on the referenced
  /// bubble), so they must never appear as separate rows in the Activity log
  /// nor be mirrored into the durable system_logs. Delegates to
  /// _responseNoticeKind so the chat-line and log-gate signatures never drift.
  /// Mirrors task_detail_screen.dart _isResponseNotificationText.
  bool _isResponseNotificationText(String text) =>
      _responseNoticeKind(text) != null;

  Widget _buildActivityLog() {
    final allActions = _messages
        .where(
          (m) =>
              m.type == MessageType.system &&
              !_isResponseNotificationText(m.text),
        )
        .toList();

    // Merge recovered entries from the durable system_logs subcollection so a
    // chat swept by retention (or a device that lost its local data) still
    // shows its action history. Parity with Task's _getActionMessages; the
    // entries are reshaped into MessageModel so the chips, the per-type
    // numbering and the date grouping below all keep working untouched.
    final knownIds = <String>{for (final m in allActions) m.id};
    for (final log in _recoveredLogs) {
      if (knownIds.contains(log.id)) continue;
      if (log.details.trim().isEmpty) continue;
      // Skip legacy response-notification rows mirrored before the gate
      // excluded them — the outcome lives on the original card now.
      if (_isResponseNotificationText(log.details)) continue;
      allActions.add(
        MessageModel(
          id: log.id,
          taskId: log.taskId,
          senderId: log.performedBy,
          text: log.details,
          type: MessageType.system,
          createdAt: log.createdAt,
        ),
      );
    }
    allActions.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Parity with the Task module: synthesize a "Card created" entry from
    // the enquiry itself so the log always starts at creation. Never
    // persisted — rebuilt from createdAt/createdBy on every render.
    if (!allActions.any(
      (m) =>
          m.text.toLowerCase().contains('card created') ||
          m.text.toLowerCase().contains('enquiry created'),
    )) {
      allActions.add(
        MessageModel(
          id: _createdEntryId,
          taskId: _enquiry.id,
          senderId: _enquiry.createdBy,
          text: 'Card created',
          type: MessageType.system,
          createdAt: _enquiry.createdAt,
        ),
      );
      allActions.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    // Filter actions with the shared predicate so chips and rows agree
    var filteredActions = allActions;
    if (_selectedActivityFilter != null) {
      filteredActions = allActions
          .where((msg) => _activityMatchesFilter(msg, _selectedActivityFilter))
          .toList();
    }

    // Counts over ALL actions. A chip with 0 hits is hidden, so tapping any
    // visible chip always yields rows instead of "No <type> actions".
    final chipDefs = <({String label, IconData icon, String key})>[
      (label: 'Status', icon: Icons.flag, key: 'status'),
      (label: 'Progress', icon: Icons.trending_up, key: 'progress'),
      (label: 'Edits', icon: Icons.edit, key: 'edit'),
      (label: 'Reminders', icon: Icons.notifications, key: 'reminder'),
      (label: 'Escalations', icon: Icons.report_gmailerrorred, key: 'warning'),
      (label: 'Cash', icon: Icons.account_balance_wallet, key: 'cash'),
      (label: 'Request', icon: Icons.fact_check, key: 'request'),
    ];
    final chipCounts = <String, int>{
      for (final c in chipDefs)
        c.key: allActions
            .where((msg) => _activityMatchesFilter(msg, c.key))
            .length,
    };

    // Chronological per-type numbering so every log row shows "#N"
    // (computed over ALL actions so numbers survive filtering)
    final activityNumbers = <String, int>{};
    final typeCounts = <String, int>{};
    for (final msg in allActions) {
      // The created entry is unique and never numbered.
      if (msg.id == _createdEntryId) continue;
      final key = _getActivityActionInfo(msg).title;
      typeCounts[key] = (typeCounts[key] ?? 0) + 1;
      activityNumbers[msg.id] = typeCounts[key]!;
    }

    // Collapsed header stays informative: newest entry + when it landed
    final latestMsg = allActions.last;
    final latestNum = activityNumbers[latestMsg.id];
    final latestLabel =
        '${_getActivityActionInfo(latestMsg).title}'
        '${latestNum != null ? ' #$latestNum' : ''}'
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
                // count disagree with the visible rows (parity with task).
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
          // Filter chips — only types this enquiry actually has
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                children: [
                  _buildActivityChip(
                    'All',
                    Icons.filter_list,
                    null,
                    allActions.length,
                  ),
                  for (final c in chipDefs)
                    if ((chipCounts[c.key] ?? 0) > 0)
                      _buildActivityChip(
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
          // Grouped actions by date
          ..._buildGroupedActivityItems(filteredActions, activityNumbers),
        ],
      ],
    );
  }

  /// Single source of truth for the filter chips AND the filtered list, so a
  /// chip can never drift out of sync with its predicate.
  bool _activityMatchesFilter(MessageModel msg, String? filter) {
    if (filter == null) return true;
    final lower = msg.text.toLowerCase();
    switch (filter) {
      case 'status':
        return lower.contains('status');
      case 'progress':
        return lower.contains('progress');
      case 'edit':
        return lower.contains('changed title') ||
            lower.contains('changed description') ||
            lower.contains('changed priority') ||
            lower.contains('changed assignee') ||
            lower.contains('assignee added') ||
            lower.contains('assignee removed') ||
            lower.contains('assignee updated') ||
            lower.contains('deadline updated');
      case 'reminder':
        return lower.contains('reminder') || lower.contains('follow up');
      case 'warning':
        return lower.contains('warning') || lower.contains('escalation');
      case 'cash':
        return msg.text.contains('💵') || lower.startsWith('cash');
      case 'request':
        return lower.contains('approval requested');
      default:
        return true;
    }
  }

  /// One-line value summary for a log row so it says WHAT changed without a
  /// trip into chat: an explicit "old → new" pair, else "from X to Y", else the
  /// quoted note, else whatever follows the first colon ("₹5,000 · Bal ₹2,000").
  String? _activityValueLabel(MessageModel msg) {
    final text = msg.text.replaceAll('\n', ' · ').trim();
    String? value;
    final arrow = RegExp(
      r'([^:·\n]{1,24})\s*→\s*([^·\n]{1,24})',
    ).firstMatch(text);
    final fromTo = RegExp(
      r'from\s+(.+?)\s+to\s+(.+?)(?:\s+by\b|$)',
      caseSensitive: false,
    ).firstMatch(text);
    final quoted = RegExp(r'"([^"]+)"').firstMatch(text);
    if (arrow != null) {
      value = '${arrow.group(1)!.trim()} → ${arrow.group(2)!.trim()}';
    } else if (fromTo != null) {
      value = '${fromTo.group(1)!.trim()} → ${fromTo.group(2)!.trim()}';
    } else if (quoted != null) {
      value = quoted.group(1);
    } else {
      final colon = text.indexOf(':');
      if (colon > 0 && colon < text.length - 1) {
        value = text.substring(colon + 1).trim();
      }
    }
    value = value?.trim();
    if (value == null || value.isEmpty) return null;
    // Acronyms for compact one-line display
    value = value.replaceAll('Balance:', 'Bal:');
    return value.length > 40 ? '${value.substring(0, 39)}…' : value;
  }

  Widget _buildActivityChip(
    String label,
    IconData icon,
    String? filter, [
    int? count,
  ]) {
    final isSelected = _selectedActivityFilter == filter;
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
            Text(
              count == null ? label : '$label $count',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        selected: isSelected,
        selectedColor: _themeColor,
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: isSelected ? _themeColor : Colors.grey[300]!),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        onSelected: (selected) =>
            setState(() => _selectedActivityFilter = selected ? filter : null),
      ),
    );
  }

  List<Widget> _buildGroupedActivityItems(
    List<MessageModel> actions,
    Map<String, int> activityNumbers,
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
              'No ${_selectedActivityFilter ?? ""} actions',
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
    final groups = <String, List<MessageModel>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (final msg in visible) {
      final dateOnly = DateTime(
        msg.createdAt.year,
        msg.createdAt.month,
        msg.createdAt.day,
      );
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
      groups[groupLabel]!.add(msg);
    }

    // Build widgets
    final widgets = <Widget>[];
    groups.forEach((label, groupActions) {
      // Outside Today/Yesterday a group can span several days, so rows there
      // need their own date or the sequence reads out of order
      final showDate = label != 'Today' && label != 'Yesterday';
      // Date header
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
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
          _buildSlackStyleActivityItem(
            groupActions[i],
            activityNumbers[groupActions[i].id],
            showDate,
          ),
        );
        if (i < groupActions.length - 1) {
          widgets.add(const SizedBox(height: 4));
        }
      }

      // Divider after group
      widgets.add(const Divider(height: 24));
    });

    return widgets;
  }

  Widget _buildSlackStyleActivityItem(
    MessageModel msg, [
    int? number,
    bool showDate = false,
  ]) {
    final dateLabel = DateFormat('d MMM').format(msg.createdAt);
    // Time for single-day groups (header carries the date), date for the
    // multi-day groups — same slot behaviour as the Task module.
    final slotLabel = showDate
        ? dateLabel
        : DateFormat('h:mm a').format(msg.createdAt);
    // Actor shown as initials (Task-module parity, compact one-line rows)
    final actor = Helpers.nameInitials(_getSenderName(msg.senderId));
    final actionInfo = _getActivityActionInfo(msg);
    final title = number != null
        ? '${actionInfo.title} #$number'
        : actionInfo.title;
    final valueLabel = _activityValueLabel(msg);

    // Trailing tile only while the action still needs closure (query reply,
    // follow-up/approval/extension/blocker/call done) — Task-module parity:
    // informational and closed entries show no icon at the end of the row.
    final closed = msg.isReplied || msg.isFollowUpDone;
    final actionType = Helpers.detectActionType(msg.text);
    final needsClosure =
        !closed &&
        actionType != null &&
        CardActionIcons.closureTypes.contains(actionType);

    // Build a single-line summary: "· Actor · Title · value"
    final parts = <String>['· $actor', '· $title'];
    if (valueLabel != null) parts.add('· $valueLabel');
    final summary = parts.join(' ');

    return GestureDetector(
      // The created entry has no chat message to jump to.
      onTap: msg.id == _createdEntryId
          ? null
          : () => _scrollToMessageById(msg.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Date in a fixed-width slot so content aligns vertically
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
            const SizedBox(width: 6),
            if (needsClosure)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: actionInfo.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(actionInfo.icon, size: 12, color: actionInfo.color),
              )
            else
              const SizedBox(width: 24, height: 24),
          ],
        ),
      ),
    );
  }

  // ⚠️ Activity log row title/icon mapper — key-based via detectActionType
  // first, then keyword fallbacks; unmatched types show generic 'Action'.
  // New action types need a case here AND a filter chip/switch case above.
  _ActivityInfo _getActivityActionInfo(MessageModel msg) {
    final lower = msg.text.toLowerCase();
    // Synthesized creation entry (and any legacy creation messages).
    if (lower.contains('card created') || lower.contains('enquiry created')) {
      return _ActivityInfo(
        'Card created',
        Icons.add_task,
        const Color(0xFF2F9E44),
      );
    }
    // Sales-cycle actions (check before generic keywords — e.g. "💳 Payment"
    // details may also mention a reminder)
    final actionKey = Helpers.detectActionType(msg.text);
    final seq = msg.sequenceNumber;
    String numbered(String base) => seq != null ? '$base $seq' : base;
    switch (actionKey) {
      case 'quotation':
      case 'sitevisit':
        {
          // Config-driven so Service Teams reads "Estimate"/"Visit Schedule"
          // while Sales keeps the catalog label; numbered per occurrence.
          final def = _config.actionFor(actionKey!);
          return _ActivityInfo(
            numbered(def?.label ?? actionKey),
            def?.icon ?? Icons.flag,
            def?.color ?? _themeColor,
          );
        }
      case 'repaired':
      case 'verified':
        {
          final def = _config.actionFor(actionKey!);
          return _ActivityInfo(
            def?.label ?? actionKey,
            def?.icon ?? Icons.flag,
            def?.color ?? _themeColor,
          );
        }
      case 'meeting':
        return _ActivityInfo(
          numbered('Meeting'),
          Icons.groups,
          const Color(0xFF3B5BDB),
        );
      case 'call':
        if (lower.contains('call scheduled')) {
          return _ActivityInfo(
            msg.isFollowUpDone ? 'Call - Done' : 'Call Scheduled',
            Icons.call,
            const Color(0xFF0C8599),
          );
        }
        return _ActivityInfo('Call', Icons.call, const Color(0xFF0C8599));
      case 'whatsapp':
        return _ActivityInfo('WhatsApp', Icons.chat, const Color(0xFF25D366));
      case 'payment':
        return _ActivityInfo(
          numbered('Payment'),
          Icons.payments,
          const Color(0xFF7048E8),
        );
      case 'sample':
        return _ActivityInfo(
          numbered('Sample/Demo'),
          Icons.inventory_2_outlined,
          const Color(0xFFAE3EC9),
        );
      case 'delivery':
        {
          // Config-driven label/icon/color; shows a Done state once marked
          // delivered (mirrors repaired/verified). Numbered per occurrence.
          final def = _config.actionFor(actionKey!);
          return _ActivityInfo(
            msg.isFollowUpDone
                ? 'Delivery - Done'
                : numbered(def?.label ?? 'Delivery'),
            msg.isFollowUpDone
                ? Icons.check_circle
                : (def?.icon ?? Icons.local_shipping),
            def?.color ?? _themeColor,
          );
        }
      case 'collect':
        {
          // Collection (Service field flow) — mirrors delivery; Done once the
          // technician marks the pick-up. Config-driven label/icon/color.
          final def = _config.actionFor(actionKey!);
          return _ActivityInfo(
            msg.isFollowUpDone
                ? 'Collected - Done'
                : numbered(def?.label ?? 'Collected'),
            msg.isFollowUpDone
                ? Icons.check_circle
                : (def?.icon ?? Icons.call_received),
            def?.color ?? _themeColor,
          );
        }
      case 'negotiation':
        return _ActivityInfo(
          numbered('Negotiation'),
          Icons.local_offer_outlined,
          const Color(0xFFF08C00),
        );
      case 'won':
        return _ActivityInfo(
          numbered('Won'),
          Icons.emoji_events,
          const Color(0xFF2F9E44),
        );
      case 'lost':
        return _ActivityInfo(
          numbered('Lost'),
          Icons.cancel,
          const Color(0xFFE03131),
        );
      case 'dropped':
        return _ActivityInfo(
          numbered('Dropped'),
          Icons.remove_circle_outline,
          const Color(0xFF868E96),
        );
      case 'blocker':
        return _ActivityInfo('Blocker', Icons.block, const Color(0xFFC92A2A));
      case 'approval':
        return _ActivityInfo(
          msg.isFollowUpDone
              ? 'Request - Closed'
              : msg.isReplied
              ? 'Request - Actioned'
              : 'Request',
          Icons.fact_check,
          const Color(0xFF0B7285),
        );
      case 'extension':
        return _ActivityInfo(
          'Extension',
          Icons.more_time,
          const Color(0xFF3B5BDB),
        );
      case 'progress':
        return _ActivityInfo(
          'Progress Report',
          Icons.trending_up,
          const Color(0xFF7048E8),
        );
      case 'cash':
        return _ActivityInfo(
          numbered('Cash'),
          Icons.account_balance_wallet,
          const Color(0xFF099268),
        );
      case 'reminder':
        return _ActivityInfo(
          numbered('Reminder'),
          Icons.notifications_outlined,
          const Color(0xFFF59F00),
        );
      case 'warning':
        return _ActivityInfo(
          numbered('Escalation'),
          Icons.report_gmailerrorred,
          const Color(0xFFE03131),
        );
      case 'query':
        return _ActivityInfo(
          seq != null
              ? (msg.isReplied ? 'Query $seq - Replied' : 'Query $seq')
              : (msg.isReplied ? 'Query - Replied' : 'Query'),
          msg.isReplied ? Icons.check_circle : Icons.summarize,
          const Color(0xFF7048E8),
        );
    }
    if (lower.contains('status'))
      return _ActivityInfo('Status', Icons.flag, const Color(0xFF2F9E44));
    if (lower.contains('progress'))
      return _ActivityInfo('Progress', Icons.trending_up, _themeColor);
    if (lower.contains('changed title') ||
        lower.contains('changed description'))
      return _ActivityInfo('Title/Desc', Icons.edit, _themeColor);
    if (lower.contains('changed priority'))
      return _ActivityInfo('Priority', Icons.flag, const Color(0xFFF59F00));
    if (lower.contains('changed assignee') ||
        lower.contains('assignee added') ||
        lower.contains('assignee removed') ||
        lower.contains('assignee updated'))
      return _ActivityInfo(
        'Assignee',
        Icons.person_add_alt,
        const Color(0xFFF59F00),
      );
    if (lower.contains('deadline'))
      return _ActivityInfo('Deadline', Icons.schedule, const Color(0xFF1971C2));
    if (lower.contains('reminder'))
      return _ActivityInfo(
        'Reminder',
        Icons.notifications_outlined,
        const Color(0xFFF59F00),
      );
    if (lower.contains('follow up'))
      return _ActivityInfo(
        'Follow Up',
        Icons.event_note,
        const Color(0xFF1971C2),
      );
    if (lower.contains('warning') || lower.contains('escalation'))
      return _ActivityInfo(
        'Escalation',
        Icons.report_gmailerrorred,
        const Color(0xFFE03131),
      );
    if (lower.contains('completed') || lower.contains('uncompleted'))
      return _ActivityInfo('Milestone', Icons.check_circle, _themeColor);
    return _ActivityInfo('Action', Icons.info_outline, AppTheme.secondaryText);
  }

  // ── Contact Info ──────────────────────────────────────────────────────

  void _showContactInfo(String name, String? uid) {
    String? phone;
    if (uid == _enquiry.assignedToUid) phone = _enquiry.assignedToPhone;
    if (uid == _enquiry.createdBy) phone = _enquiry.createdByPhone;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: _themeColor.withOpacity(0.1),
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: _themeColor,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryText,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (phone != null && phone.isNotEmpty) ...[
                    InkWell(
                      onTap: () => launchUrl(Uri.parse('tel:$phone')),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.call,
                              color: Colors.green,
                              size: 24,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Call',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: () => launchUrl(Uri.parse('sms:$phone')),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _themeColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.message,
                              color: _themeColor,
                              size: 24,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Message',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Inline Editing ────────────────────────────────────────────────────

  // Field labels for the intake form. Service Teams reads as a complaint
  // ticket (Product / Problem); Sales keeps the enquiry wording. Customer
  // name is identical in both modules.
  String get _titleLabel =>
      _config.type == ModuleType.crm ? 'Product' : 'Sales Task';
  String get _descLabel =>
      _config.type == ModuleType.crm ? 'Problem' : 'Description';
  String get _titleHint =>
      _config.type == ModuleType.crm ? 'Enter product' : 'Enter enquiry title';

  // The full editable enquiry details card (same widget shown at the top of
  // the chat) presented in a bottom sheet behind the AppBar info button —
  // Task-module parity, so the 'i' opens the real card, not a read-only
  // summary. The flag guards against a double-open.
  bool _enquiryCardSheetOpen = false;
  // Version counter so an OPEN details-card sheet rebuilds when screen state
  // changes (a modal sheet's builder otherwise runs only once, so an edit made
  // FROM the sheet never showed up inside it). Same mechanism as the Task
  // module's task-card sheet.
  final ValueNotifier<int> _cardSheetVersion = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _cardSheetVersion.value++;
  }

  Future<void> _openEnquiryCardSheet() async {
    if (_enquiryCardSheetOpen) return;
    _enquiryCardSheetOpen = true;
    final provider = _readProvider(context);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.lightText.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: ValueListenableBuilder<int>(
                valueListenable: _cardSheetVersion,
                builder: (context, _, _) => SingleChildScrollView(
                  child: _buildEnquiryDetailsCard(provider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _enquiryCardSheetOpen = false;
  }

  void _editTitleInline(BaseModuleProvider provider) async {
    final controller = TextEditingController(text: _enquiry.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Edit Title',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter title',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _themeColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result == _enquiry.title) return;
    final oldTitle = _enquiry.title;
    final updates = <String, dynamic>{'title': result};
    // A titled enquiry is no longer a draft — clear the flag and assign an ID
    if (result.isNotEmpty && _enquiry.extraFields?['isDraft'] == true) {
      updates['extraFields.isDraft'] = false;
      if (_enquiry.displayId == null) {
        updates['displayId'] = await SequentialIdService().getNextId(
          provider.config.sequentialIdKey,
        );
      }
    }
    await provider.updateEnquiry(_enquiry.id, updates);
    await _refreshCurrentEnquiry();
    final userName = context.read<AuthProvider>().userModel?.name ?? 'User';
    final msg = MessageModel(
      id: '',
      taskId: _enquiry.id,
      senderId: _currentUserId,
      text: '$userName changed title from "$oldTitle" to "$result"',
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    provider.sendMessage(_enquiry.id, msg);
  }

  void _editDescriptionInline(BaseModuleProvider provider) async {
    final controller = TextEditingController(text: _enquiry.description);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Edit Description',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          maxLength: 1000,
          maxLines: 4,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter description',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _themeColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result == _enquiry.description) return;
    final oldDesc = _enquiry.description.isEmpty
        ? '(empty)'
        : _enquiry.description;
    await provider.updateEnquiry(_enquiry.id, {'description': result});
    await _refreshCurrentEnquiry();
    final userName = context.read<AuthProvider>().userModel?.name ?? 'User';
    final msg = MessageModel(
      id: '',
      taskId: _enquiry.id,
      senderId: _currentUserId,
      text: '$userName changed description from "$oldDesc" to "$result"',
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    provider.sendMessage(_enquiry.id, msg);
  }

  /// Opens the shared [CustomerEditDialog] (all five fields) — generalises the
  /// old name-only inline edit so Sales and CRM edit name/phone/email/company/
  /// address in one place. Persists every field via [CustomerInfo.toMap] and
  /// logs a concise "updated customer …" system message listing what changed.
  /// Distinct customers already used on this module's cards (name non-empty,
  /// de-duplicated by name, sorted) — feeds the edit dialog's "reuse a saved
  /// customer" picker so an existing customer can be picked instead of retyped.
  List<CustomerInfo> _savedCustomers(BaseModuleProvider provider) {
    final byName = <String, CustomerInfo>{};
    for (final e in provider.enquiries) {
      final info = e.customerInfo;
      if (!info.hasName) continue;
      byName.putIfAbsent(info.name.trim().toLowerCase(), () => info);
    }
    final list = byName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  void _editClientNameInline(BaseModuleProvider provider) async {
    final old = _enquiry.customerInfo;
    final next = await CustomerEditDialog.show(
      context,
      initial: old,
      accentColor: _themeColor,
      existingCustomers: _savedCustomers(provider),
    );
    if (next == null || next == old) return;
    await provider.updateEnquiry(_enquiry.id, next.toMap());
    // Repaint this screen AND any open details sheet with the saved customer
    // (the setState inside the refresh bumps the sheet's version counter).
    await _refreshCurrentEnquiry();
    final userName = context.read<AuthProvider>().userModel?.name ?? 'User';
    final changed = <String>[
      if (old.name != next.name) 'name',
      if (old.phone != next.phone) 'phone',
      if (old.email != next.email) 'email',
      if (old.company != next.company) 'company',
      if (old.address != next.address) 'address',
    ];
    final verb = (!old.hasName && next.hasName) ? 'added' : 'updated';
    final custName = next.name.trim();
    final msg = MessageModel(
      id: '',
      taskId: _enquiry.id,
      senderId: _currentUserId,
      // Quote the customer name so the card body shows WHO was added/updated
      // instead of a label-only tile.
      text:
          '$userName $verb customer${custName.isNotEmpty ? ' "$custName"' : ''}: ${changed.join(', ')}',
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    provider.sendMessage(_enquiry.id, msg);
  }

  /// Names of the user-defined header fields (Settings → Custom fields);
  /// blank name = that field is hidden everywhere.
  List<String> _customFieldLabels = const ['', '', ''];

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

  /// Urgency chip with the two user-named custom fields stacked under it
  /// (names from Settings; values live in extraFields per enquiry).
  Widget _buildUrgencyAndCustomFields(BaseModuleProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _showUrgencyMenu(provider),
          child: Builder(
            builder: (context) {
              final uState = _urgencyStateOf(_enquiry);
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
        ..._buildCustomFieldChips(provider),
      ],
    );
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
  List<Widget> _buildCustomFieldChips(BaseModuleProvider provider) {
    final chips = <Widget>[];
    for (int slot = 1; slot <= 3; slot++) {
      final label = _customFieldLabels[slot - 1].trim();
      if (label.isEmpty) continue;
      final value = (_enquiry.extraFields?['customField$slot'] as String? ?? '')
          .trim();
      chips.add(const SizedBox(height: 6));
      chips.add(
        GestureDetector(
          onTap: () => _editCustomField(slot, provider),
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
  /// sides of the enquiry see it after sync.
  Future<void> _editCustomField(int slot, BaseModuleProvider provider) async {
    final label = _customFieldLabels[slot - 1].trim();
    if (label.isEmpty) return;
    final current =
        (_enquiry.extraFields?['customField$slot'] as String? ?? '');
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
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final stored = result.trim().isEmpty ? null : result.trim();
    final extra = Map<String, dynamic>.from(_enquiry.extraFields ?? {});
    if (stored == null) {
      extra.remove('customField$slot');
    } else {
      extra['customField$slot'] = stored;
    }
    setState(() {
      _enquiry = _enquiry.copyWith(extraFields: extra);
    });
    await provider.updateEnquiry(_enquiry.id, {
      'extraFields.customField$slot': stored,
    });
  }

  // ── Urgency (four-state chooser — Task-module parity) ──────────────────
  // State lives in extraFields['urgencyState'] (none|attention|urgent|
  // blocked); 'urgent' also keeps isUrgent in sync for legacy card badges and
  // filters, and 'blocked' unifies with extraFields['isBlocked'] (the formal
  // blocker flag). Mirrors task_detail_screen's urgency engine exactly.

  String _urgencyStateOf(EnquiryModel e) {
    if (e.extraFields?['isBlocked'] == true) return 'blocked';
    final s = e.extraFields?['urgencyState'];
    if (s == 'attention' || s == 'urgent' || s == 'blocked' || s == 'none') {
      return s as String;
    }
    return e.isUrgent ? 'urgent' : 'none';
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

  /// Four-state urgency chooser sheet (None / Needs Attention / Urgent /
  /// Blocked) — same layout and options as the Task module's urgency menu.
  void _showUrgencyMenu(BaseModuleProvider provider) {
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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                      _urgencyOption('none', provider),
                      _urgencyOption('attention', provider),
                      _urgencyOption('urgent', provider),
                      _urgencyOption('blocked', provider),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// One tappable urgency option inside the chooser sheet.
  Widget _urgencyOption(String state, BaseModuleProvider provider) {
    final isSelected = _urgencyStateOf(_enquiry) == state;
    final color = _urgencyColor(state);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _applyUrgencyState(state, provider),
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

  /// Persist a new urgency state — mirror the model (urgencyState + isUrgent +
  /// the unified isBlocked flag), write through the provider, and log a plain
  /// system message. Same flow the Task module runs, adapted to enquiry
  /// partial updates.
  Future<void> _applyUrgencyState(
    String state,
    BaseModuleProvider provider,
  ) async {
    final oldState = _urgencyStateOf(_enquiry);
    Navigator.pop(context); // close the chooser sheet
    if (oldState == state) return;
    final extra = Map<String, dynamic>.from(_enquiry.extraFields ?? {});
    extra['urgencyState'] = state;
    extra['isBlocked'] = state == 'blocked';
    setState(() {
      _enquiry = _enquiry.copyWith(
        isUrgent: state == 'urgent',
        extraFields: extra,
        updatedAt: DateTime.now(),
      );
    });
    await provider.updateEnquiry(_enquiry.id, {
      'extraFields.urgencyState': state,
      'extraFields.isBlocked': state == 'blocked',
      'isUrgent': state == 'urgent',
    });
    final userName = context.read<AuthProvider>().userModel?.name ?? 'User';
    final msg = MessageModel(
      id: '',
      taskId: _enquiry.id,
      senderId: _currentUserId,
      text:
          '\u{1F525} Urgency changed: ${_urgencyLabel(oldState)} \u2192 ${_urgencyLabel(state)} by $userName at ${Helpers.formatDateTime(DateTime.now())}',
      type: MessageType.system,
      createdAt: DateTime.now(),
    );
    provider.sendMessage(_enquiry.id, msg);
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

  // ── Status Change ────────────────────────────────────────────────────

  /// Popup display order for the Change Status sheet: Demo is offered before
  /// Quotation (the funnel order users actually walk), while ModuleConfig keeps
  /// its own canonical order for pipeline / filters / colour mapping.
  List<String> get _statusMenuOrder {
    var names = List<String>.from(_config.statusNames);
    if (names.remove('demo') && names.contains('quotation')) {
      names.insert(names.indexOf('quotation'), 'demo');
    }
    // Sales "Closed" (key `cancel`) is a success-only archive state, not a
    // general terminal: it can only be entered from a won (Success) deal, and
    // from Closed the only move is to reactivate back to Success — never to
    // any other funnel stage. CRM has no `cancel` key, so it is untouched.
    if (names.contains('cancel')) {
      final cur = _enquiry.status;
      if (cur == 'cancel') {
        names = ['success'];
      } else if (cur != 'success') {
        names.remove('cancel');
      }
    }
    return names;
  }

  void _showStatusMenu(BaseModuleProvider provider) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Change Status',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            // Tracker-parity layout: a vertical list of full-width rows, each a
            // leading colored status icon + label (with a trailing check on the
            // current status) — the same icon+label grammar the Task module's
            // status popup uses, instead of the old pill-wrap of chips.
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _statusMenuOrder.map((status) {
                    final isSelected = _enquiry.status == status;
                    final color = _config.statusColorFor(status);
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      selectedTileColor: color.withOpacity(0.08),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      leading: Icon(_iconForStatus(status), color: color),
                      title: Text(
                        _statusLabel(status),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isSelected ? color : AppTheme.primaryText,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle, size: 20, color: color)
                          : null,
                      onTap: isSelected
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _changeStatus(provider, status);
                            },
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Update the enquiry pipeline status. [emitMessage] controls whether a
  /// standalone "📊 Status changed" card is posted: action-driven advances
  /// (Won/Demo/Quotation/Negotiation) pass false so the action card itself is
  /// the single record ("Status Change and Won should be together"); manual
  /// menu changes keep the card.
  void _changeStatus(
    BaseModuleProvider provider,
    String newStatus, {
    bool emitMessage = true,
  }) {
    // No-op guard: never re-set the same status (this caused the duplicate
    // "Success → Success" card when an outcome was marked twice).
    if (_enquiry.status == newStatus) return;
    // Capture the OLD label before the write so the card shows the transition.
    final oldStatus = _statusLabel(_enquiry.status);
    provider.updateEnquiry(_enquiry.id, {'status': newStatus});
    if (!emitMessage) return;
    // Same format as the blocked-toggle status card (📊 ... : old → new by
    // user at time) so the chat body-extraction renders the old → new pair.
    _dispatchActionMessage(
      provider,
      '📊 Status changed: $oldStatus → ${_statusLabel(newStatus)} by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
      _currentUserId,
    );
  }

  /// Service Teams billing categories offered by the Cash dialog
  /// (label = text stored in the note + cashCats map).
  static const List<(String, String)> _costCategories = [
    ('Visit Charge', 'Visit Charge'),
    ('Service Fee', 'Service Fee'),
    ('Parts', 'Parts'),
    ('Other', 'Other'),
  ];

  /// Money summary for the card. Two independent ledgers, never summed:
  /// • Cash — net in-hand from 💵 Added/Expense/Refund, broken down by the
  ///   CRM cost categories only when the ticket uses them (a plain Sales
  ///   enquiry has no categories, so just the Net shows — the meaningless
  ///   'Uncategorized' bucket is dropped).
  /// • Payments — 💳 receivables (Due · Collected · Outstanding). A payment
  ///   is money promised/collected against a due and never touches cash.
  /// Hidden entirely when the card carries neither kind of entry.
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
      _enquiry.extraFields?['cashCats'] ?? const {},
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
                          color: _themeColor.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _themeColor.withOpacity(0.15),
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
  void _openCashStatement() {
    showCashStatementSheet(
      context,
      title: 'Cash Transactions',
      entries: buildCashStatement(
        _messages,
        ledger: 'cash',
        includeSettledMarker: true,
        senderNameOf: _getSenderName,
      ),
      footerLabel: 'Net Cash Balance',
      footerValue: Helpers.formatCashAmount(
        Helpers.computeCashBalance(_messages.map((m) => m.text)),
      ),
      onJumpToMessage: _scrollToMessageById,
    );
  }

  /// Tap handler for the Payments summary row: date-wise 💳 receivables
  /// statement popup (Due · Collected rows, running Outstanding).
  void _openPaymentsStatement() {
    showCashStatementSheet(
      context,
      title: 'Payment Transactions',
      entries: buildCashStatement(
        _messages,
        ledger: 'payments',
        senderNameOf: _getSenderName,
      ),
      footerLabel: 'Outstanding',
      footerValue: Helpers.formatCashAmount(
        Helpers.computeReceivables(_messages.map((m) => m.text)).$3,
      ),
      onJumpToMessage: _scrollToMessageById,
    );
  }

  /// Whether the satisfaction (closure rating) section applies to this card:
  /// Service Teams tickets once the work is done — Resolved, or Closed with a
  /// resolution status. Sales keeps its own Won/Lost outcome flow instead.
  bool get _showSatisfactionSection {
    if (_config.type != ModuleType.crm) return false;
    return _enquiry.status == 'resolved' ||
        (_enquiry.isClosed && _config.isOpenStatus(_enquiry.status));
  }

  /// Inline ⭐ capture row shown on resolved/closed Service Teams tickets —
  /// same UX as the Task detail's star row. Tap a star to rate (tap the same
  /// star again to clear); everyone in the chat sees the rating card.
  Widget _buildSatisfactionSection(BaseModuleProvider provider) {
    if (!_showSatisfactionSection) return const SizedBox.shrink();
    final rating = _enquiry.rating ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.star_border, size: 16, color: Color(0xFFF59F00)),
              const SizedBox(width: 8),
              const Text(
                'Satisfaction',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryText,
                ),
              ),
              const Spacer(),
              Text(
                rating > 0 ? '$rating/5 · tap to change' : 'Rate the service',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: List.generate(5, (i) {
              final filled = rating > i;
              return GestureDetector(
                onTap: () => _setRating(provider, i + 1),
                child: Icon(
                  filled ? Icons.star : Icons.star_border,
                  size: 26,
                  color: filled ? const Color(0xFFF59F00) : AppTheme.lightText,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  /// Persist a 1–5 closure rating (same '⭐ Rating changed' card format as
  /// the Task module). Tapping the currently-rated star clears it again.
  void _setRating(BaseModuleProvider provider, int value) {
    final old = _enquiry.rating;
    final next = old == value ? null : value;
    setState(() {
      // -1 sentinel = clear (copyWith ignores null) — provider maps it back.
      _enquiry = _enquiry.copyWith(
        rating: next ?? -1,
        updatedAt: DateTime.now(),
      );
    });
    provider.updateEnquiry(_enquiry.id, {'rating': next});
    final msg = next == null
        ? '⭐ Rating cleared: $old → none by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}'
        : '⭐ Rating changed: ${old ?? 'none'} → $next★ by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}';
    _dispatchActionMessage(provider, msg, _currentUserId);
  }

  /// Compact star picker opened from the 3-dot 'Ratings' entry. Sales/CRM keep
  /// a single current rating on the enquiry, so this replaces the tracker's
  /// ratings-detail aggregation with set / change / clear in one dialog.
  void _showRatingEditor() {
    final provider = _readProvider(context);
    final current = _enquiry.rating ?? 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rate ${_config.itemName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                final filled = current > i;
                return IconButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _setRating(provider, i + 1);
                  },
                  icon: Icon(
                    filled ? Icons.star : Icons.star_border,
                    size: 32,
                    color: filled
                        ? const Color(0xFFF59F00)
                        : AppTheme.lightText,
                  ),
                );
              }),
            ),
            if (current > 0)
              TextButton(
                onPressed: () {
                  // Tapping the current value again clears the rating.
                  Navigator.pop(ctx);
                  _setRating(provider, current);
                },
                child: const Text('Clear rating'),
              ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(String status) {
    final index = _config.statusNames.indexOf(status);
    if (index >= 0 && index < _config.statusLabels.length) {
      return _config.statusLabels[index];
    }
    if (status.isEmpty) return 'Unknown';
    final formatted = status.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    return formatted[0].toUpperCase() + formatted.substring(1);
  }

  // ── Create New Sales Enquiry (AppBar + button) ──────────────────────

  void _createNewSalesEnquiry(BaseModuleProvider salesProvider) async {
    final auth = context.read<AuthProvider>();
    final user = auth.userModel;
    if (user == null) return;

    // Pick the assignee. "Unassigned — assign later" is offered so a ticket
    // can be created without an assignee (picked up later from the filter).
    final contact = await ContactPickerService().showContactPicker(
      context,
      allowUnassigned: true,
    );
    if (contact == null || !mounted) return;
    final bool isUnassigned = contact.isUnassigned;

    // Milestone templates are applied centrally in createEnquiry.
    final now = DateTime.now();

    final teamId = salesProvider.currentTeamId;

    final enquiry = EnquiryModel(
      id: '',
      title: '',
      clientName: '',
      createdBy: user.uid,
      createdByName: user.name,
      createdByPhone: user.phone,
      assignedTo: isUnassigned ? '' : contact.name,
      assignedToUid: isUnassigned ? null : contact.uid,
      assignedToPhone: isUnassigned
          ? null
          : (Helpers.normalizePhone(contact.phone ?? '') ?? contact.phone),
      createdAt: now,
      updatedAt: now,
      teamId: teamId,
      extraFields: {
        'isDraft': true,
        'assigneeNames': isUnassigned ? <String>[] : <String>[contact.name],
        'assigneeUids': isUnassigned ? <String>[] : <String>[contact.uid ?? ''],
        'assigneePhones': isUnassigned
            ? <String>[]
            : <String>[
                Helpers.normalizePhone(contact.phone ?? '') ??
                    contact.phone ??
                    '',
              ],
      },
    );

    try {
      final id = await salesProvider.createEnquiry(enquiry);
      if (!mounted) return;
      if (id == null) return; // Blocked by plan limit (dialog already shown)

      // Navigate with the persisted row (milestones applied in the provider).
      final persisted = await salesProvider.persistedEnquiry(enquiry, id);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SalesDetailScreen(enquiry: persisted, moduleConfig: _config),
        ),
      );
    } on PlanLimitException catch (e) {
      if (!mounted) return;
      await showPaywallDialog(context, feature: e.feature, detail: e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to create enquiry: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ── Media Gallery ────────────────────────────────────────────────────

  /// Reopen/clone flow applies only to settled cards: drafts and in-pipeline
  /// tickets already have their normal edit path. `!isOpenStatus` covers
  /// CRM (resolved/closed) and Sales (success/lost/dropped/cancel).
  bool get _canReopen {
    if (_enquiry.extraFields?['isDraft'] == true) return false;
    return !_config.isOpenStatus(_enquiry.status);
  }

  /// First-class reopen: move a resolved/closed card back into the working
  /// state. Reuses [_changeStatus] so the 📊 status card + optional 🔁 note
  /// land in the chat exactly like any other status transition.
  void _reopenEnquiry() async {
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reopen ${_config.itemName}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This moves "${_enquiry.title.isNotEmpty ? _enquiry.title : _enquiry.clientName}" '
              'back to ${_statusLabel(_config.defaultStatusName)} and keeps the full history.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _themeColor),
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = _readProvider(context);
    _changeStatus(provider, _config.defaultStatusName);
    final note = noteController.text.trim();
    if (note.isNotEmpty) {
      _dispatchActionMessage(
        provider,
        '🔁 Reopened: $note by $_currentUserName at ${Helpers.formatDateTime(DateTime.now())}',
        _currentUserId,
      );
    }
  }

  /// Clone-to-fresh-ticket for a recurring issue: a NEW card with the same
  /// customer, assignees, team and deadline — no messages, milestones or
  /// rating — cross-linked to this card so the history chain is visible from
  /// both sides (the 🔗 link messages are posted by ItemLinksService).
  void _cloneToNewEnquiry() async {
    final provider = _readProvider(context);
    final now = DateTime.now();
    // Carry only the people/context fields — drop status, rating, counts,
    // milestones and the draft flag; the pipeline template is re-applied by
    // createEnquiry for a fresh card.
    final freshExtra = <String, dynamic>{
      for (final key in ['assigneeNames', 'assigneeUids', 'assigneePhones'])
        if (_enquiry.extraFields?[key] != null) key: _enquiry.extraFields![key],
    };
    final clone = EnquiryModel(
      id: '',
      title: _enquiry.title,
      description: _enquiry.description,
      clientName: _enquiry.clientName,
      clientPhone: _enquiry.clientPhone,
      clientEmail: _enquiry.clientEmail,
      clientAddress: _enquiry.clientAddress,
      clientCompany: _enquiry.clientCompany,
      createdBy: _enquiry.createdBy,
      createdByName: _enquiry.createdByName,
      createdByPhone: _enquiry.createdByPhone,
      assignedTo: _enquiry.assignedTo,
      assignedToUid: _enquiry.assignedToUid,
      assignedToPhone: _enquiry.assignedToPhone,
      participants: List.of(_enquiry.participants),
      status: _config.defaultStatusName,
      priority: _enquiry.priority,
      isUrgent: _enquiry.isUrgent,
      deadline: _enquiry.deadline,
      tags: List.of(_enquiry.tags),
      category: _enquiry.category,
      extraFields: freshExtra.isEmpty ? null : freshExtra,
      createdAt: now,
      updatedAt: now,
      teamId: _enquiry.teamId,
    );
    try {
      final id = await provider.createEnquiry(clone);
      if (!mounted || id == null) return; // Blocked (paywall shown)
      final persisted = await provider.persistedEnquiry(clone, id);
      if (!mounted) return;
      // Bidirectional link + 🔗 system messages on both chats.
      await ItemLinksService().link(
        context,
        source: _selfLinkRef,
        target: LinkRef(
          module: _selfModule,
          id: id,
          title: persisted.title.isNotEmpty
              ? persisted.title
              : persisted.clientName,
          displayId: persisted.displayId,
        ),
      );
      if (!mounted) return;
      await _refreshCurrentEnquiry(); // Show the new 🔗 chip on this card
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SalesDetailScreen(enquiry: persisted, moduleConfig: _config),
        ),
      );
    } on PlanLimitException catch (e) {
      if (!mounted) return;
      await showPaywallDialog(context, feature: e.feature, detail: e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to create ticket: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// All chat messages carrying media attachments (images, files, voice).
  List<MessageModel> get _mediaMessages => _messages
      .where(
        (m) =>
            m.type == MessageType.image ||
            m.type == MessageType.file ||
            m.type == MessageType.voice,
      )
      .toList();

  /// Searchable gallery of all chat attachments (photos, files, voice notes)
  /// — shared widget with filters, sizes, page counts, select/forward/share/delete.
  void _showMediaGallery(BuildContext context) {
    showChatMediaGallery(
      context,
      MediaGalleryConfig(
        messages: () => _mediaMessages,
        themeColor: _themeColor,
        currentUserId: _currentUserId,
        senderName: _getSenderName,
        localPathFor: chatLocalPathFor,
        openImage: (m) => _openImageViewer(m.fileUrl ?? ''),
        openDocument: chatOpenDocument,
        openInChat: (m) => _scrollToMessageById(m.id),
        forward: _forwardMessage,
        deleteForMe: _galleryDeleteForMe,
        deleteForEveryone: _galleryDeleteForEveryone,
        canDeleteForEveryone: (m) =>
            m.senderId == _currentUserId &&
            DateTime.now().difference(m.createdAt).inMinutes < 60,
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

  // ── Options Menu ──────────────────────────────────────────────────────

  void _showEnquiryMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            // Chat menu parity with Task Detail's 3-dot sheet: the SAME six
            // rows in the SAME order — Search, Share, Export Chat,
            // Media & Attachments, Ratings, Delete — each divider-separated
            // (DetailChatMenuMixin powers the first three). Module actions
            // (status, renewals, enquiry management) live below this block.
            ListTile(
              leading: Icon(Icons.search, color: _themeColor),
              title: const Text('Search Messages'),
              onTap: () {
                Navigator.pop(ctx);
                toggleChatSearch();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.share, color: _themeColor),
              title: const Text('Share'),
              subtitle: const Text(
                'Chat screenshot',
                style: TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                shareChatScreenshot();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.download_outlined, color: _themeColor),
              title: const Text('Export Chat'),
              subtitle: const Text(
                'All messages, actions & edits • CSV / Excel / PDF',
                style: TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                exportChat();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.perm_media, color: _themeColor),
              title: const Text('Media & Attachments'),
              subtitle: const Text(
                'View & search photos, files and voice notes',
                style: TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showMediaGallery(context);
              },
            ),
            const Divider(height: 1),
            // Ratings — single menu entry (tracker standard). Sales/CRM keep
            // one current rating on the enquiry, so this opens a compact star
            // picker (set / change / clear). The amber star + count badge
            // mirror the Task menu's Ratings row.
            ListTile(
              leading: const Icon(Icons.star, color: Colors.amber),
              title: const Text('Ratings'),
              subtitle: Text(
                (_enquiry.rating ?? 0) > 0
                    ? 'Current: ${_enquiry.rating}/5 — tap to change'
                    : 'Rate this ${_config.itemName.toLowerCase()}',
                style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              trailing: (_enquiry.rating ?? 0) > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _themeColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_enquiry.rating}/5',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _showRatingEditor();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                'Delete ${_config.itemName}',
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete();
              },
            ),
            const Divider(height: 24),
            // ── Module actions (below the Task-parity chat block) ────────
            // Status is no longer an inline chip band here — it opens the
            // same dedicated Change Status popup as the status chip, so the
            // menu grammar matches the Task (tracker) module.
            ListTile(
              leading: Icon(Icons.swap_horiz, color: _themeColor),
              title: const Text('Change Status'),
              subtitle: Text(
                'Current: ${_statusLabel(_enquiry.status)}',
                style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showStatusMenu(_readProvider(context));
              },
            ),
            // First-class recurrence flow (mainly Service Teams): once a card
            // reaches a final state, Reopen continues the SAME ticket (warranty
            // callback) and Clone starts a FRESH ticket linked to this one
            // (new occurrence). Both hidden for drafts and open tickets.
            if (_canReopen) ...[
              ListTile(
                leading: Icon(Icons.refresh, color: _themeColor),
                title: Text('Reopen ${_config.itemName}'),
                subtitle: Text(
                  'Move back to ${_statusLabel(_config.defaultStatusName)} — keeps history',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.lightText,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _reopenEnquiry();
                },
              ),
              ListTile(
                leading: Icon(Icons.copy_all, color: _themeColor),
                title: Text('New ${_config.itemName} from This One'),
                subtitle: Text(
                  'Fresh ticket, same customer & team — linked to this one',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.lightText,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _cloneToNewEnquiry();
                },
              ),
            ],
            // New Enquiry / View All moved here from the AppBar (replaced by
            // the call icon, mirroring Task Detail)
            ListTile(
              leading: Icon(Icons.add, color: _themeColor),
              title: const Text('New Enquiry'),
              onTap: () {
                Navigator.pop(ctx);
                _createNewSalesEnquiry(_readProvider(context));
              },
            ),
            ListTile(
              leading: Icon(Icons.task_alt, color: _themeColor),
              title: const Text('View All Enquiries'),
              onTap: () {
                Navigator.pop(ctx);
                final currentUser = context.read<AuthProvider>().userModel;
                if (currentUser == null) return;
                final isCreator = _enquiry.createdBy == currentUser.uid;
                // If I am creator → show enquiries for the assignee
                // If I am assignee → show enquiries for the creator
                final targetPerson = isCreator
                    ? _enquiry.assignedTo
                    : (_enquiry.createdByName ?? _enquiry.createdBy);
                final otherPerson = isCreator
                    ? (_enquiry.createdByName ?? _enquiry.createdBy)
                    : _enquiry.assignedTo;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AssigneeSalesScreen(
                      personName: targetPerson,
                      otherPersonName: otherPerson,
                      moduleConfig: _config,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.edit, color: _themeColor),
              title: const Text('Edit Enquiry'),
              onTap: () {
                Navigator.pop(ctx);
                _editEnquiry();
              },
            ),
            ListTile(
              leading: Icon(Icons.flag_outlined, color: _themeColor),
              title: const Text('Milestone Settings'),
              subtitle: const Text(
                'Configure pipeline milestones',
                style: TextStyle(fontSize: 11, color: AppTheme.lightText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        SalesMilestoneSettingsScreen(moduleConfig: _config),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _editEnquiry() async {
    final titleController = TextEditingController(text: _enquiry.title);
    final nameController = TextEditingController(text: _enquiry.clientName);
    final descController = TextEditingController(text: _enquiry.description);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Edit Enquiry',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              maxLength: 100,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: _titleLabel,
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
              controller: nameController,
              maxLength: 100,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Customer Name',
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
              controller: descController,
              maxLength: 1000,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: _descLabel,
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true) {
      final provider = _readProvider(context);
      final newTitle = titleController.text.trim();
      final updates = <String, dynamic>{
        'title': newTitle,
        'clientName': nameController.text.trim(),
        'description': descController.text.trim(),
      };
      // A titled enquiry is no longer a draft — clear the flag and assign an ID
      if (newTitle.isNotEmpty && _enquiry.extraFields?['isDraft'] == true) {
        updates['extraFields.isDraft'] = false;
        if (_enquiry.displayId == null) {
          updates['displayId'] = await SequentialIdService().getNextId(
            provider.config.sequentialIdKey,
          );
        }
      }
      await provider.updateEnquiry(_enquiry.id, updates);
    }
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Enquiry?'),
        content: Text(
          'This will permanently delete "${_enquiry.title.isNotEmpty ? _enquiry.title : _enquiry.clientName}" and all its messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _readProvider(context).deleteEnquiry(_enquiry.id);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _ActivityInfo {
  final String title;
  final IconData icon;
  final Color color;
  _ActivityInfo(this.title, this.icon, this.color);
}

/// Result of the generic action composer dialog: the note text plus an
/// optional attachment that is uploaded right after the action card.
class _ActionComposeResult {
  final String text;
  final PickedChatAttachment? attachment;
  const _ActionComposeResult(this.text, {this.attachment});
}
