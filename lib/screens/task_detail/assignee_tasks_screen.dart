import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/task.dart';
import '../../models/action_item.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/export_service.dart';
import '../../utils/paywall_constants.dart';
import '../../widgets/task_card.dart';
import '../../widgets/card_action_icons.dart';
import '../../providers/task_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/local_database_service.dart';
import '../../services/premium_status_service.dart';
import '../../services/contact_picker_service.dart';
import '../../services/firebase_service.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/actions_filter_ui.dart';
import '../../modules/shared/module_config.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/visibility_gated_tab.dart';
import '../../services/avatar_cache_service.dart';
import 'task_detail_screen.dart';

/// Lets the parent (home screen) forward its 3-dot menu VIEW/SORT
/// selections into the embedded assignee view.
class AssigneeTasksController {
  _AssigneeTasksScreenState? _state;
  void setStatusFilter(String value) => _state?._applyExternalFilter(value);
  void setSortBy(String value) => _state?._applyExternalSort(value);
}

class AssigneeTasksScreen extends StatefulWidget {
  final String assigneeName;
  final String assignerName;

  /// When true, renders without Scaffold/AppBar for embedding in the home
  /// ASSIGNEE tab. Defaults the person to the last message sender.
  final bool embedded;

  /// Notifies the parent (home screen) when the selected person changes.
  final ValueChanged<String>? onPersonChanged;

  /// Optional hook so the parent's 3-dot menu can drive filter/sort here.
  final AssigneeTasksController? controller;

  /// WhatsApp-style selection mode driven by the embedding home screen.
  final bool selectionMode;
  final Set<String> selectedTaskIds;

  /// Long-press hook for the embedding home screen (enters selection mode,
  /// mirroring the By Me tab). Falls back to the local options sheet when
  /// null (standalone usage).
  final void Function(TaskModel task)? onLongPressTask;

  /// Tap hook used while selection mode is active (toggles selection).
  final void Function(TaskModel task)? onToggleSelection;

  /// Notifies the embedding home screen when local chip clears reset the
  /// filter/sort, so the AppBar 'Filter:' subtitle disappears too.
  final VoidCallback? onLocalFiltersCleared;

  /// Whether this tab is the currently-visible one. The home [IndexedStack]
  /// keeps every visited tab mounted, so a hidden tab must NOT re-run its
  /// expensive tasks/actions queries on every sync notification — that is what
  /// froze the UI when several tabs were alive at once. A hidden tab only flags
  /// [_AssigneeTasksScreenState._pendingRefresh] and catches up once on becoming
  /// visible again. Defaults to true so a full-screen push always stays live.
  final bool isActive;

  const AssigneeTasksScreen({
    super.key,
    this.assigneeName = '',
    this.assignerName = '',
    this.embedded = false,
    this.onPersonChanged,
    this.controller,
    this.selectionMode = false,
    this.selectedTaskIds = const {},
    this.onLongPressTask,
    this.onToggleSelection,
    this.onLocalFiltersCleared,
    this.isActive = true,
  });

  @override
  State<AssigneeTasksScreen> createState() => _AssigneeTasksScreenState();
}

class _AssigneeTasksScreenState extends State<AssigneeTasksScreen>
    with SingleTickerProviderStateMixin, VisibilityGatedTabState {
  late TabController _tabController;
  List<TaskModel> _allTasks = [];

  /// Ids of tasks where the selected person is on the ASSIGNEE side (the
  /// pair filter also admits creator-side tasks, but the Archived stat must
  /// count only what this person owns as assignee). Rebuilt on every load.
  final Set<String> _personAsAssigneeIds = {};

  String _resolvedAssignee = '';
  String _resolvedAssigner = '';

  /// Sentinel "person" in the Select Assignee picker: views every card the
  /// current user created that is still unassigned (mirrors the 'Unassigned'
  /// VIEW filter set, reachable as a picker entry too).
  static const String _unassignedPerson = 'Unassigned';
  bool get _isUnassignedView =>
      _resolvedAssignee.toLowerCase() == _unassignedPerson.toLowerCase();

  /// Pinned "Me" entry at the top of the picker — views every task the
  /// current user touches (as creator or assignee; the same person set the
  /// byMe/toMe/participant source already guarantees). The user's own name
  /// is stripped from the letter list below so it can never appear twice.
  static const String _mePerson = 'Me';
  bool get _isMeView =>
      _resolvedAssignee.toLowerCase() == _mePerson.toLowerCase();

  // Profile photo of the selected person (tokenized Firebase download URL
  // from their users doc — survives reinstall, unlike local file paths).
  String? _assigneeAvatarUrl;
  // Designation of the selected person (from their users doc), shown
  // below the name in the header.
  String? _assigneeDesignation;
  // Session cache: person name (lowercase) -> designation (null = none).
  // The photo has NO parallel cache — it resolves through
  // AvatarCacheService (the single source the cards use) and repaints via
  // its listener, so the header can never disagree with the cards.
  static final Map<String, String?> _designationCache = {};

  String _selectedTab = 'tasks'; // Tab: tasks / actions
  String _statusFilter = 'All';
  String _sortBy = 'Last Action';

  // Actions tab state — lean two-axis filter: a time-chip row plus an
  // optional action-type override. No per-option counts and no date picker
  // (both would force extra scans/state on every rebuild).
  String _timeFilter = kActionTimeToday;
  String? _typeFilter;

  // Time chips (axis 1) and action-type sheet entries (axis 2). Values match
  // the switches in [_applyActionFilter] / [_typeFilterToActionType].
  static const _timeOptions = kActionTimeOptions;
  // Derive the Type filter from Task's OWN action catalog (ModuleConfig.task)
  // so this tab lists exactly the actions Task offers with canonical labels —
  // parity with the main Task Actions tab. Warning / Extension / Progress are
  // no longer Task actions, so they drop out; legacy rows of those types still
  // show under 'All types'. Values are catalog keys, resolved to ActionType by
  // [_typeFilterToActionType].
  List<ActionFilterOption> get _typeOptions =>
      actionTypeFilterOptions(ModuleConfig.task.actionTypes);
  List<ActionItem> _currentActionItems =
      []; // Currently visible actions (for export)
  Future<List<ActionItem>>? _actionsFuture; // Cache actions query future
  Set<String> _actionsTaskIds =
      {}; // Task-id set the cached future was built for
  // Task cards whose full action history is expanded (more link).
  final Set<String> _expandedActionCards = {};
  StreamSubscription? _actionsTableSub; // Listen for actions table changes
  Timer? _providerReloadDebounce; // Coalesce TaskProvider notification bursts

  // Visibility gating (see [VisibilityGatedTabState]): a hidden tab defers its
  // full-scan reload and catches up once when shown again.
  @override
  bool get isActiveTab => widget.isActive;
  @override
  void onTabBecameActive() {
    _loadTasks();
    if (mounted) setState(() => _actionsFuture = null);
  }

  // Pagination: render at most this many task cards in the Actions tab,
  // growing as the user scrolls near the bottom.
  static const int _actionCardsPageSize = 50;
  int _visibleActionCards = _actionCardsPageSize;

  // All tasks visible to the current user (for the assignee picker)
  List<TaskModel> _allAvailableTasks = [];
  bool _autoPickerShown = false;

  /// Remembers the last person chosen in the Select Assignee picker so the
  /// embedded ASSIGNEE tab reopens on that person instead of defaulting to the
  /// latest message sender (Sales/CRM-module parity).
  static const String _lastPersonPrefKey = 'assignee_task_last_person';

  // Precomputed assignee-picker index (people + task counts), rebuilt once
  // per task load so opening the picker never scans the task list.
  // Names sharing a UID or phone are merged into one person entry;
  // _pickerAliases maps each entry key to all its known name variants
  // (e.g. contact-book 'Sonu' + profile 'Sudarshna Bhatnagar').
  final Map<String, int> _pickerCounts = {};
  final Map<String, String> _pickerDisplay = {};
  final Map<String, Set<String>> _pickerAliases = {};
  // Premium bit per merged person entry (crown in the picker sheet)
  final Map<String, bool> _pickerPremium = {};
  // Per-person status stats shown under the name in the picker sheet
  final Map<String, int> _pickerActive = {};
  final Map<String, int> _pickerOverdue = {};
  final Map<String, int> _pickerBlocked = {};
  final Map<String, DateTime> _pickerLastSeen = {};
  // Identity hints so avatars resolve from the SQLite cache (uid/phone)
  final Map<String, String> _pickerUids = {};
  final Map<String, String> _pickerPhones = {};
  List<String> _pickerKeys = [];
  // Picker sheet sort mode, persisted so the app remembers the choice.
  String _pickerSortMode = 'name'; // 'name' | 'tasks' | 'recent'
  static const String _pickerSortPrefKey = 'assignee_picker_sort_mode';
  // Attention mode (header bell, embedded variant only): FILTERS the task list
  // to open tasks that still have a pending action AND selects the 'Needs
  // Attention' time chip on the Actions tab, so one toggle narrows both lists.
  // Session-only: it persists across the two sub-tabs and clears with a second
  // bell tap (or when the home screen rebuilds the view).
  bool _attentionMode = false;

  // Cached provider reference. `context.read` must NOT run in dispose(): by
  // then the element is defunct and the provider lookup throws
  // "Null check operator used on a null value" (Element.widget -> _widget!),
  // crashing the screen on back-navigation. Grab it once in initState.
  TaskProvider? _taskProvider;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _tabController = TabController(length: 2, vsync: this);
    _loadPickerSortPref();
    _resolveNames();
    if (widget.embedded && _resolvedAssignee.isEmpty) {
      _initDefaultPerson();
    } else {
      _loadTasks();
    }

    // Listen for TaskProvider changes (same pattern as home screen)
    _taskProvider = context.read<TaskProvider>();
    _taskProvider!.addListener(_onTaskProviderChanged);

    // Listen for avatar index fills so a photo that resolved after our first
    // lookup (cold-start race with the contact sync) repaints the header —
    // same mechanism the cards use; no parallel-cache negative caching.
    AvatarCacheService().addListener(_onAvatarCacheChanged);

    // Listen for actions table changes to refresh the Actions tab. Debounced
    // so a burst of action writes triggers a single reload, not one per row.
    _actionsTableSub = LocalDatabaseService()
        .tableChangesDebounced('actions')
        .listen((_) {
          if (!mounted) return;
          // Hidden tab: don't re-fetch (the reload is a full tasks scan); just
          // remember to catch up when the tab is shown again.
          if (isTabHidden) {
            deferRefresh();
            return;
          }
          // Invalidate cached future so FutureBuilder re-fetches
          setState(() => _actionsFuture = null);
        });
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _taskProvider?.removeListener(_onTaskProviderChanged);
    AvatarCacheService().removeListener(_onAvatarCacheChanged);
    _actionsTableSub?.cancel();
    _providerReloadDebounce?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  /// Re-filter tasks when TaskProvider data changes (e.g., after returning
  /// from chat). Debounced: sync bursts fire many notifications and each
  /// _loadTasks re-reads all tasks + rebuilds the picker index.
  void _onTaskProviderChanged() {
    if (!mounted) return;
    // Hidden tab: defer the full re-scan; catch up when shown again.
    if (isTabHidden) {
      deferRefresh();
      return;
    }
    _providerReloadDebounce?.cancel();
    _providerReloadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadTasks();
    });
  }

  void _resolveNames() {
    // Resolve assigner name (may be UID)
    final assigner = widget.assignerName;
    if (_looksLikeUid(assigner)) {
      // Try to get name from first task's createdByName
      _resolvedAssigner = assigner; // Will update after tasks load
    } else {
      _resolvedAssigner = assigner;
    }

    // Resolve assignee name (may be UID)
    final assignee = widget.assigneeName;
    if (_looksLikeUid(assignee)) {
      _resolvedAssignee = assignee; // Will update after tasks load
    } else {
      _resolvedAssignee = assignee;
    }
  }

  Future<void> _loadTasks() async {
    final allTasks = <TaskModel>[];
    _personAsAssigneeIds.clear();
    String? personUidForAvatar;

    try {
      final taskProvider = context.read<TaskProvider>();
      final currentUser = context.read<AuthProvider>();

      if (currentUser.userModel != null) {
        final userId = currentUser.userModel!.uid;
        final assigneeLower = _resolvedAssignee.toLowerCase();

        // Load ALL tasks (not just paginated first page), scoped to the
        // currently selected team so switching teams in the AppBar changes
        // this view exactly like the By Me / To Me lists.
        final allAvailableTasks = (await taskProvider.getAllTasks(
          userId,
        )).where(taskProvider.isInCurrentTeam).toList();
        _allAvailableTasks = allAvailableTasks;
        _rebuildPickerIndex(allAvailableTasks);

        // The same person can appear under multiple names (contact-book
        // name vs profile name) — match against all merged aliases.
        final personAliases = _aliasesFor(_resolvedAssignee);

        // Helper: check if a name matches the target person (case-insensitive)
        bool matchesPerson(String? name) =>
            name != null && personAliases.contains(name.toLowerCase());

        // No person selected yet (embedded mode) — nothing to filter
        if (assigneeLower.isEmpty) {
          if (mounted) setState(() => _allTasks = []);
          return;
        }

        // "Me" pinned person: everything I touch as creator or assignee.
        // UID-based (not name) so legacy docs with a compressed/missing name
        // still match. The general alias-resolution path below can't do this
        // — it deliberately refuses to resolve the current user's own UID.
        if (_isMeView) {
          _personAsAssigneeIds.clear();
          final mineAll = allAvailableTasks
              .where(
                (t) =>
                    t.createdBy == userId ||
                    t.assignedToUid == userId ||
                    (t.extraFields?['assigneeUids'] is List &&
                        (t.extraFields!['assigneeUids'] as List).contains(
                          userId,
                        )),
              )
              .toList();
          // Archived stat counts assignee-side only — record where I am the
          // assignee (same basis as the general path above).
          for (final t in mineAll) {
            if (t.assignedToUid == userId ||
                (t.extraFields?['assigneeUids'] is List &&
                    (t.extraFields!['assigneeUids'] as List).contains(
                      userId,
                    ))) {
              _personAsAssigneeIds.add(t.id);
            }
          }
          if (mounted) {
            setState(() {
              _allTasks = mineAll;
            });
          }
          // My own photo/designation in the header (the shared call site at
          // the bottom of _loadTasks is never reached from this branch).
          unawaited(_resolveAssigneeAvatar(null));
          return;
        }

        // "Unassigned" sentinel person: my own cards still waiting for an
        // assignee — same predicate as the 'Unassigned' case below in
        // _applyStatusFilter. No person identity resolution needed.
        if (_isUnassignedView) {
          if (mounted) {
            setState(() {
              _allTasks = allAvailableTasks
                  .where((t) => t.createdBy == userId && t.assignedTo.isEmpty)
                  .toList();
            });
          }
          return;
        }

        // Resolve the person's UID and phone(s) from tasks where their name
        // appears as an assignee — links contact-book names (e.g. 'Sonu') to
        // the same person's profile-name/UID identity on other tasks.
        // Never accept the current user's own UID here: legacy corruption
        // stored the creator's UID in assignee slots, which would make the
        // person match every task the current user touches.
        String? resolvedPersonUid;
        final personPhones = <String>{};
        for (final task in allAvailableTasks) {
          if (matchesPerson(task.assignedTo)) {
            if (resolvedPersonUid == null &&
                task.assignedToUid != null &&
                task.assignedToUid!.isNotEmpty &&
                task.assignedToUid != userId) {
              resolvedPersonUid = task.assignedToUid;
            }
            final phone = Helpers.normalizePhone(task.assignedToPhone) ?? '';
            if (phone.isNotEmpty) personPhones.add(phone);
          }
          // Also check multi-assignee entries. Legacy tasks stored UID/phone
          // lists compressed (only resolved entries), so index attribution is
          // only safe when the list length matches assigneeNames.
          final assigneeUids = task.extraFields?['assigneeUids'];
          final assigneeNamesList = task.extraFields?['assigneeNames'];
          final assigneePhonesList = task.extraFields?['assigneePhones'];
          if (assigneeNamesList is List) {
            final uidsAligned =
                assigneeUids is List &&
                assigneeUids.length == assigneeNamesList.length;
            final phonesAligned =
                assigneePhonesList is List &&
                assigneePhonesList.length == assigneeNamesList.length;
            for (int i = 0; i < assigneeNamesList.length; i++) {
              if (!matchesPerson(assigneeNamesList[i]?.toString())) continue;
              if (resolvedPersonUid == null && uidsAligned) {
                final uid = assigneeUids[i]?.toString() ?? '';
                if (uid.isNotEmpty && uid != userId && uid != task.createdBy) {
                  resolvedPersonUid = uid;
                }
              }
              if (phonesAligned) {
                final phone =
                    Helpers.normalizePhone(assigneePhonesList[i]?.toString()) ??
                    '';
                if (phone.isNotEmpty) personPhones.add(phone);
              }
            }
          }
        }

        bool matchesPersonUid(String? uid) =>
            resolvedPersonUid != null &&
            uid != null &&
            uid == resolvedPersonUid;
        personUidForAvatar = resolvedPersonUid;
        bool matchesPersonPhone(String? phone) {
          final normalized = Helpers.normalizePhone(phone) ?? '';
          return normalized.isNotEmpty && personPhones.contains(normalized);
        }

        for (final task in allAvailableTasks) {
          if (allTasks.any((t) => t.id == task.id)) continue;

          // Check if person A is involved (as assignee or creator)
          // Check primary assignee field (name, UID, or phone)
          final isPrimaryAssignee =
              matchesPerson(task.assignedTo) ||
              matchesPersonUid(task.assignedToUid) ||
              matchesPersonPhone(task.assignedToPhone);

          // Check multi-assignee fields (extraFields) by name, UID, or phone
          final assigneeNames = task.extraFields?['assigneeNames'];
          final assigneeUids = task.extraFields?['assigneeUids'];
          final assigneePhones = task.extraFields?['assigneePhones'];
          final isInMultiAssignee =
              (assigneeNames is List &&
                  assigneeNames.any((n) => matchesPerson(n?.toString()))) ||
              (assigneeUids is List &&
                  assigneeUids.any((u) => matchesPersonUid(u?.toString()))) ||
              (assigneePhones is List &&
                  assigneePhones.any((p) => matchesPersonPhone(p?.toString())));

          final isAssignee = isPrimaryAssignee || isInMultiAssignee;
          if (isAssignee) _personAsAssigneeIds.add(task.id);

          // Check if person A is the creator (by name, UID, or phone)
          final isCreator =
              matchesPerson(task.createdByName) ||
              task.createdBy.toLowerCase() == assigneeLower ||
              matchesPersonUid(task.createdBy) ||
              matchesPersonPhone(task.createdByPhone);

          // Include tasks where person A is assignee OR creator
          // (current user is already guaranteed to be involved since we're filtering from byMe/toMe/participant tasks)
          if (isAssignee || isCreator) {
            allTasks.add(task);
          }
        }
      }
    } catch (e) {
      print('Error loading from TaskProvider: $e');
    }

    if (!mounted) return;
    setState(() {
      _allTasks = allTasks;
    });

    // Try to resolve names from task data if they look like UIDs
    if (allTasks.isNotEmpty) {
      final firstTask = allTasks.first;
      if (_looksLikeUid(_resolvedAssigner)) {
        final name = firstTask.createdByName;
        if (name != null && name.isNotEmpty && name.toLowerCase() != 'user') {
          setState(() => _resolvedAssigner = name);
        }
      }
      if (_looksLikeUid(_resolvedAssignee)) {
        final name = firstTask.assignedTo;
        if (name.isNotEmpty &&
            !_looksLikeUid(name) &&
            name.toLowerCase() != 'user') {
          setState(() => _resolvedAssignee = name);
        }
      }
    }

    // Fetch the person's profile photo (fire-and-forget — header shows
    // initials until/unless a photo resolves). Identity comes from the merged
    // picker index inside the resolver, so nothing extra is passed.
    unawaited(_resolveAssigneeAvatar(personUidForAvatar));
  }

  /// Find the merged-person root that owns [nameLower] in the picker index,
  /// so `_pickerUids`/`_pickerPhones` (keyed by union-find root) resolve for a
  /// person known under any of their aliases. Falls back to the name itself.
  String _pickerRootFor(String nameLower) {
    for (final e in _pickerAliases.entries) {
      if (e.value.contains(nameLower)) return e.key;
    }
    return nameLower;
  }

  /// Repaint when the avatar index fills — mirrors the card listener so a
  /// late-resolving photo reaches the header instead of only the cards.
  void _onAvatarCacheChanged() {
    if (!mounted || _isMeView || _resolvedAssignee.isEmpty) return;
    final root = _pickerRootFor(_resolvedAssignee.toLowerCase());
    final next = AvatarCacheService().urlFor(
      uid: _pickerUids[root],
      phone: _pickerPhones[root],
      name: _resolvedAssignee,
    );
    // Skip the rebuild when this person still resolves to the same URL.
    if (next != _assigneeAvatarUrl) setState(() => _assigneeAvatarUrl = next);
  }

  /// Resolve the selected person's profile photo URL — single source: the
  /// shared [AvatarCacheService] index resolved with the full identity trio
  /// (uid → phone → name) exactly like the cards and picker rows. Designation
  /// keeps its small session cache (not the avatar system's job). The users
  /// doc is a BACKFILL only: a fetched photo is written back into the shared
  /// index via upsertUser (which repaints every consumer) instead of a
  /// private map — so a cold-start miss can never be negative-cached as
  /// "no photo forever". Phonebook photos are intentionally not used
  /// (contacts load withPhoto: false app-wide for performance).
  Future<void> _resolveAssigneeAvatar(String? personUid) async {
    final name = _resolvedAssignee;
    // "Me" view: show my own profile photo/designation — the generic chain
    // below would read the caches under the 'me' key (empty) and leave the
    // header on a stale other-person photo.
    if (_isMeView) {
      final me = context.read<AuthProvider>().userModel;
      if (!mounted) return;
      setState(() {
        _assigneeAvatarUrl = me?.avatarUrl;
        _assigneeDesignation = me?.designation;
      });
      return;
    }
    if (name.isEmpty) {
      if (mounted &&
          (_assigneeAvatarUrl != null || _assigneeDesignation != null)) {
        setState(() {
          _assigneeAvatarUrl = null;
          _assigneeDesignation = null;
        });
      }
      return;
    }
    final key = name.toLowerCase();
    final root = _pickerRootFor(key);

    // Photo: the shared avatar index only. Prefer the picker-index identity
    // (merged across aliases); fall back to the UID resolved from this
    // person's task rows.
    final uid = (personUid != null && personUid.isNotEmpty)
        ? personUid
        : _pickerUids[root];
    final phone = _pickerPhones[root];
    String? url = AvatarCacheService().urlFor(uid: uid, phone: phone, name: name);

    String? designation = _designationCache[key];
    if (designation == null && !_designationCache.containsKey(key)) {
      // Cached team members already carry designation from the users docs.
      final members = ContactPickerService().getCachedTeamMembers();
      if (members != null) {
        for (final m in members) {
          if (m.name.toLowerCase() != key) continue;
          if (m.designation?.isNotEmpty ?? false) {
            designation = m.designation;
            break;
          }
        }
      }
      _designationCache[key] = designation;
    }

    // Users doc by UID: backfill photo into the shared index + designation.
    // Offline simply resolves nothing — a later cache fill or reload retries.
    if ((url == null || designation == null) &&
        uid != null &&
        uid.isNotEmpty) {
      try {
        final user = await FirebaseService().getUser(uid);
        if (user != null) {
          if (url == null && (user.avatarUrl?.isNotEmpty ?? false)) {
            AvatarCacheService().upsertUser(
              uid: uid,
              phone: phone,
              name: user.name,
              url: user.avatarUrl,
            );
            url = user.avatarUrl;
          }
          if (designation == null &&
              (user.designation?.isNotEmpty ?? false)) {
            designation = user.designation;
            _designationCache[key] = designation;
          }
        }
      } catch (_) {
        // Offline — nothing cached; the listener/reload retries.
      }
    }

    if (!mounted || _resolvedAssignee != name) return;
    if (url != _assigneeAvatarUrl || designation != _assigneeDesignation) {
      setState(() {
        _assigneeAvatarUrl = url;
        _assigneeDesignation = designation;
      });
    }
  }

  bool _looksLikeUid(String s) =>
      s.length >= 20 &&
      !s.contains(' ') &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

  // ── Assignee selection (embedded mode) ──────────────────────────

  /// Default the person to the last one chosen in the picker; if nothing was
  /// remembered yet, fall back to whoever sent the most recent task message
  /// (excluding the current user). Opens the picker if still unresolvable.
  Future<void> _initDefaultPerson() async {
    final uid = context.read<AuthProvider>().userModel?.uid ?? '';
    // Land back on the person last chosen in the picker so re-entering the
    // ASSIGNEE tab shows their cards instead of defaulting to the latest
    // message sender. Only when nothing was remembered yet do we fall back to
    // the last message sender (and only if that too is absent does the picker
    // auto-open below).
    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(_lastPersonPrefKey) ?? '';
    if (remembered.isNotEmpty) {
      _resolvedAssignee = remembered;
      widget.onPersonChanged?.call(remembered);
    } else {
      final name = await LocalDatabaseService().getLastMessageSenderName(
        parentType: 'task',
        excludeUid: uid,
      );
      if (name != null && name.isNotEmpty) {
        _resolvedAssignee = name;
        widget.onPersonChanged?.call(name);
      }
    }
    if (!mounted) return;
    await _loadTasks();
    if (!mounted) return;
    if (_resolvedAssignee.isEmpty && !_autoPickerShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Only auto-open when this screen is actually on top — never over a
        // foreign route (e.g. SMS verification/onboarding pushed above Home)
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        if (_autoPickerShown) return;
        _autoPickerShown = true;
        _showAssigneePicker();
      });
    }
  }

  /// Switch to viewing another person's tasks.
  void _selectPerson(String name) {
    if (name.toLowerCase() == _resolvedAssignee.toLowerCase()) return;
    setState(() {
      _resolvedAssignee = name;
      _resolvedAssigner = '';
      _assigneeAvatarUrl = null; // Clear old person's photo until re-resolved
      _assigneeDesignation = null;
    });
    widget.onPersonChanged?.call(name);
    // Remember this pick so the tab reopens on the same person next time
    // instead of defaulting to the latest message sender (Sales/CRM parity).
    SharedPreferences.getInstance().then(
      (p) => p.setString(_lastPersonPrefKey, name),
    );
    _loadTasks();
  }

  /// Single pass over [source] building the picker's people/count index.
  /// Runs during task load (off the sheet-open path) so the picker is
  /// instant regardless of how many tasks or users exist.
  ///
  /// The same person can appear under different names across tasks (the
  /// creator's contact-book name vs their app profile name), so names are
  /// clustered by shared UID/phone and merged into a single entry.
  void _rebuildPickerIndex(List<TaskModel> source) {
    _pickerCounts.clear();
    _pickerDisplay.clear();
    _pickerAliases.clear();
    _pickerPremium.clear();
    _pickerActive.clear();
    _pickerOverdue.clear();
    _pickerBlocked.clear();
    _pickerLastSeen.clear();
    _pickerUids.clear();
    _pickerPhones.clear();

    final myUid = context.read<AuthProvider>().userModel?.uid ?? '';

    // Per-name identity gathered from every task mention.
    final display = <String, String>{};
    final nameUids = <String, Set<String>>{};
    final namePhones = <String, Set<String>>{};
    // How often the current user assigned tasks under this name — the name
    // the user picked from their own contacts wins as the display name.
    final pickedByMe = <String, int>{};
    // People mentioned per task (for counting tasks once per merged person)
    final taskPeople = <Set<String>>[];

    for (final t in source) {
      final people = <String>{};
      void note(
        String? rawName, {
        String? uid,
        String? phone,
        bool assigneeOnMyTask = false,
      }) {
        final name = rawName?.trim() ?? '';
        if (name.isEmpty ||
            name.toLowerCase() == 'user' ||
            _looksLikeUid(name)) {
          return;
        }
        final key = name.toLowerCase();
        people.add(key);
        display.putIfAbsent(key, () => name);
        if (uid != null && uid.isNotEmpty) {
          (nameUids[key] ??= {}).add(uid);
        }
        // Contact-book and profile phone formats differ (spaces, +91) —
        // compare normalized forms only.
        final p = Helpers.normalizePhone(phone) ?? '';
        if (p.isNotEmpty) (namePhones[key] ??= {}).add(p);
        if (assigneeOnMyTask) pickedByMe[key] = (pickedByMe[key] ?? 0) + 1;
      }

      final mine = myUid.isNotEmpty && t.createdBy == myUid;
      final creatorNameLower = (t.createdByName ?? '').trim().toLowerCase();
      note(t.createdByName, uid: t.createdBy, phone: t.createdByPhone);

      final assigneeNames = t.extraFields?['assigneeNames'];
      final isMulti = assigneeNames is List && assigneeNames.length > 1;
      if (!isMulti) {
        // Single assignee — primary fields are trustworthy, except a
        // creator UID stored on a non-creator name (legacy corruption).
        var primaryUid = t.assignedToUid;
        if (primaryUid == t.createdBy &&
            t.assignedTo.trim().toLowerCase() != creatorNameLower) {
          primaryUid = null;
        }
        note(
          t.assignedTo,
          uid: primaryUid,
          phone: t.assignedToPhone,
          assigneeOnMyTask: mine,
        );
      } else {
        // Multi-assignee — primary UID/phone can hold another assignee's
        // identity on corrupt docs, so only trust index-aligned slots.
        final uids = t.extraFields?['assigneeUids'];
        final phones = t.extraFields?['assigneePhones'];
        final uidsAligned = uids is List && uids.length == assigneeNames.length;
        final phonesAligned =
            phones is List && phones.length == assigneeNames.length;
        for (int i = 0; i < assigneeNames.length; i++) {
          final slotName = assigneeNames[i]?.toString().trim() ?? '';
          var slotUid = uidsAligned ? (uids[i]?.toString() ?? '') : '';
          if (slotUid == t.createdBy &&
              slotName.toLowerCase() != creatorNameLower) {
            slotUid = ''; // creator UID in an assignee slot — corruption
          }
          note(
            slotName,
            uid: slotUid,
            phone: phonesAligned ? phones[i]?.toString() : null,
            assigneeOnMyTask: mine,
          );
        }
      }
      taskPeople.add(people);
    }

    // Union-find: merge names sharing any UID or phone.
    final parent = <String, String>{for (final k in display.keys) k: k};
    String find(String k) {
      var root = k;
      while (parent[root] != root) {
        root = parent[root]!;
      }
      var cur = k;
      while (parent[cur] != root) {
        final next = parent[cur]!;
        parent[cur] = root;
        cur = next;
      }
      return root;
    }

    void union(String a, String b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    // Phones are the most reliable identity signal (some legacy docs stamped
    // the wrong UID onto a contact), so union by shared phone first and
    // unconditionally.
    final ownerByPhone = <String, String>{};
    for (final k in display.keys) {
      for (final phone in namePhones[k] ?? const <String>{}) {
        final seen = ownerByPhone[phone];
        if (seen == null) {
          ownerByPhone[phone] = k;
        } else {
          union(seen, k);
        }
      }
    }

    // Two names carrying different known phones are different people even if a
    // corrupt UID matches — e.g. 'Aaru Rihansh' was wrongly tagged with Sonu's
    // UID. Veto a UID-based merge whenever both names have phones and none are
    // shared, so the corruption can't collapse two people into one.
    bool phonesConflict(String a, String b) {
      final pa = namePhones[a], pb = namePhones[b];
      if (pa == null || pb == null || pa.isEmpty || pb.isEmpty) return false;
      return pa.intersection(pb).isEmpty;
    }

    final ownerByUid = <String, String>{};
    for (final k in display.keys) {
      for (final uid in nameUids[k] ?? const <String>{}) {
        final seen = ownerByUid[uid];
        if (seen == null) {
          ownerByUid[uid] = k;
        } else if (!phonesConflict(seen, k)) {
          union(seen, k);
        }
      }
    }

    // Cluster members per root; pick the display name the current user
    // assigns under most often (their contact-book name), else alphabetical.
    final members = <String, List<String>>{};
    for (final k in display.keys) {
      (members[find(k)] ??= []).add(k);
    }
    final rootKeyFor = <String, String>{};
    final premiumSvc = PremiumStatusService();
    for (final entry in members.entries) {
      final sorted = entry.value
        ..sort((a, b) {
          final byPicked = (pickedByMe[b] ?? 0).compareTo(pickedByMe[a] ?? 0);
          return byPicked != 0 ? byPicked : a.compareTo(b);
        });
      final canonical = sorted.first;
      _pickerDisplay[canonical] = display[canonical]!;
      _pickerAliases[canonical] = entry.value.toSet();
      // Remember the first known uid/phone so the avatar cache can resolve
      // this person even when the display name is a contact-book variant.
      for (final m in entry.value) {
        if ((_pickerUids[canonical] ?? '').isEmpty) {
          final uids = nameUids[m];
          if (uids != null && uids.isNotEmpty)
            _pickerUids[canonical] = uids.first;
        }
        if ((_pickerPhones[canonical] ?? '').isEmpty) {
          final phones = namePhones[m];
          if (phones != null && phones.isNotEmpty) {
            _pickerPhones[canonical] = phones.first;
          }
        }
      }
      // Premium bit: any alias identity hitting the premium lookup marks
      // the whole merged person as premium
      _pickerPremium[canonical] = entry.value.any(
        (m) =>
            (nameUids[m] ?? const <String>{}).any(
              (u) => premiumSvc.isPremium(uid: u),
            ) ||
            (namePhones[m] ?? const <String>{}).any(
              (p) => premiumSvc.isPremium(phone: p),
            ),
      );
      for (final m in entry.value) {
        rootKeyFor[m] = canonical;
      }
    }

    // Count tasks once per merged person, plus per-person status stats.
    for (int i = 0; i < taskPeople.length; i++) {
      final t = source[i];
      final roots = taskPeople[i].map((k) => rootKeyFor[k]!).toSet();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isClosed = t.isClosed;
      final isCancelled = t.isCancelled;
      final isBlocked = t.extraFields?['isBlocked'] == true;
      final isOverdue =
          !isClosed &&
          !isCancelled &&
          t.deadline != null &&
          DateTime(
            t.deadline!.year,
            t.deadline!.month,
            t.deadline!.day,
          ).isBefore(today);
      final last = t.lastMessageTime ?? t.updatedAt;
      for (final r in roots) {
        _pickerCounts[r] = (_pickerCounts[r] ?? 0) + 1;
        // Same disjoint partition as the summary strip so the picker and
        // the assignee view always agree.
        if (!t.isDeleted && !t.isArchived && !isClosed && !isCancelled) {
          if (isBlocked) {
            _pickerBlocked[r] = (_pickerBlocked[r] ?? 0) + 1;
          } else if (isOverdue) {
            _pickerOverdue[r] = (_pickerOverdue[r] ?? 0) + 1;
          } else {
            _pickerActive[r] = (_pickerActive[r] ?? 0) + 1;
          }
        }
        final prev = _pickerLastSeen[r];
        if (prev == null || last.isAfter(prev)) {
          _pickerLastSeen[r] = last;
        }
      }
    }

    _pickerKeys = _pickerCounts.keys.toList()
      ..sort(
        (a, b) => _pickerDisplay[a]!.toLowerCase().compareTo(
          _pickerDisplay[b]!.toLowerCase(),
        ),
      );
  }

  /// All known name variants (lowercase) for the given person name.
  Set<String> _aliasesFor(String name) {
    final lower = name.trim().toLowerCase();
    for (final aliases in _pickerAliases.values) {
      if (aliases.contains(lower)) return aliases;
    }
    return {lower};
  }

  /// True when the picker person `key` resolves to the current user: any
  /// alias name in their cluster carries my UID or normalized phone (the
  /// same identity the union-find merged in _rebuildPickerIndex). Used to
  /// strip my own row from the letter list — the pinned 'Me' entry above
  /// it is the selection affordance instead.
  bool _pickerOwns(String key, String myUid, Set<String> myPhones) {
    final aliases = _pickerAliases[key] ?? {key};
    for (final a in aliases) {
      if (myUid.isNotEmpty && _pickerUids[a] == myUid) return true;
      final phone = _pickerPhones[a];
      if (phone != null && phone.isNotEmpty && myPhones.contains(phone)) {
        return true;
      }
    }
    return false;
  }

  /// Bottom sheet with search to pick another assignee/creator to view.
  void _showAssigneePicker() {
    // Use the precomputed index; rebuild only if it hasn't been built yet
    // (e.g. picker opened before the first task load completed)
    if (_pickerKeys.isEmpty) {
      _rebuildPickerIndex(
        _allAvailableTasks.isNotEmpty ? _allAvailableTasks : _allTasks,
      );
    }
    // Authoritative counts for the person currently being viewed — the
    // selected picker row shows these (matching the header strip) instead of
    // its name-cluster preview, which can under-count UID/phone matches.
    final selCounts = _summaryCounts();
    final display = _pickerDisplay;
    final keys = _pickerKeys;

    // Count for the pinned "Unassigned" row — my own cards that still have
    // no assignee (same predicate as the sentinel view in _loadTasks).
    // Must exclude soft-deleted/archived cards: the sentinel view renders
    // through _applyStatusFilter, which strips those, so counting them here
    // made the label read higher than the tasks actually shown.
    final myUid = context.read<AuthProvider>().userModel?.uid ?? '';
    final myName = context.read<AuthProvider>().userModel?.name ?? 'Me';
    final unassignedSource = _allAvailableTasks.isNotEmpty
        ? _allAvailableTasks
        : _allTasks;
    final unassignedCount = unassignedSource
        .where(
          (t) =>
              t.createdBy == myUid &&
              t.assignedTo.isEmpty &&
              !t.isDeleted &&
              !t.isArchived,
        )
        .length;
    // Count for the pinned "Me" row — same exclusion basis as the view
    // itself (the list renders through _applyStatusFilter, which strips
    // deleted/archived rows).
    final meCount = unassignedSource
        .where(
          (t) =>
              !t.isDeleted &&
              !t.isArchived &&
              (t.createdBy == myUid ||
                  t.assignedToUid == myUid ||
                  (t.extraFields?['assigneeUids'] is List &&
                      (t.extraFields!['assigneeUids'] as List).contains(
                        myUid,
                      ))),
        )
        .length;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        String query = '';
        // The current user's own identities — their letter-list row is
        // replaced by the pinned 'Me' entry above it.
        final myPhones = {
          if (myUid.isNotEmpty) myUid,
          Helpers.normalizePhone(
                context.read<AuthProvider>().userModel?.phone ?? '',
              ) ??
              '',
        };
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final visible = _sortPickerKeys(
              keys
                  .where((k) => display[k]!.toLowerCase().contains(query))
                  .where((k) => !_pickerOwns(k, myUid, myPhones))
                  .toList(),
            );
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.7,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(top: 10, bottom: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.lightText.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const Text(
                        'Select Assignee',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          onChanged: (v) => setSheetState(
                            () => query = v.trim().toLowerCase(),
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search assignee...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: AppTheme.lightGrey),
                            ),
                            filled: true,
                            fillColor: AppTheme.lightGrey.withOpacity(0.3),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Row(
                          children: [
                            const Text(
                              'Sort by:',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.lightText,
                              ),
                            ),
                            const SizedBox(width: 6),
                            _sortModeChip(setSheetState, 'name', 'Name'),
                            _sortModeChip(setSheetState, 'tasks', 'Tasks'),
                            _sortModeChip(setSheetState, 'recent', 'Recent'),
                          ],
                        ),
                      ),
                      // Pinned "Me" entry — views everything I created or
                      // am assigned to. Shown instead of my own letter-list
                      // row, which is stripped out below.
                      if (query.isEmpty ||
                          'me'.contains(query) ||
                          myName.toLowerCase().contains(query))
                        ListTile(
                          dense: true,
                          leading: AppAvatar(
                            avatarUrl: context
                                .read<AuthProvider>()
                                .userModel
                                ?.avatarUrl,
                            initials: Helpers.getInitials(myName),
                            radius: 16,
                            color: AppTheme.headerGreen,
                            fontSize: 12,
                          ),
                          title: Text(
                            myName == _mePerson
                                ? _mePerson
                                : '$_mePerson ($myName)',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '$meCount ${meCount == 1 ? 'task' : 'tasks'} · mine (created + assigned)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          trailing: _isMeView
                              ? const Icon(
                                  Icons.check_circle,
                                  size: 20,
                                  color: AppTheme.headerGreen,
                                )
                              : null,
                          onTap: () {
                            // Switch FIRST, then dismiss (see 'Unassigned').
                            _selectPerson(_mePerson);
                            if (Navigator.of(ctx).canPop()) {
                              Navigator.of(ctx).pop();
                            }
                          },
                        ),
                      // Pinned "Unassigned" entry — views every card the
                      // creator made that still awaits an assignee (same
                      // set as the VIEW ▸ Unassigned filter).
                      if (query.isEmpty ||
                          _unassignedPerson.toLowerCase().contains(query))
                        ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: AppTheme.headerGreen.withValues(
                              alpha: 0.12,
                            ),
                            child: const Icon(
                              Icons.person_off_outlined,
                              size: 18,
                              color: AppTheme.headerGreen,
                            ),
                          ),
                          title: const Text(
                            _unassignedPerson,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            '$unassignedCount ${unassignedCount == 1 ? 'task' : 'tasks'} · assign later',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          trailing: _isUnassignedView
                              ? const Icon(
                                  Icons.check_circle,
                                  size: 20,
                                  color: AppTheme.headerGreen,
                                )
                              : null,
                          onTap: () {
                            // Switch FIRST, then dismiss. Applying the change
                            // before the pop guarantees the view updates even
                            // if the dismiss on this sheet context ever
                            // misbehaves (previously a throw in pop aborted
                            // before _selectPerson and nothing appeared to
                            // happen).
                            _selectPerson(_unassignedPerson);
                            if (Navigator.of(ctx).canPop()) {
                              Navigator.of(ctx).pop();
                            }
                          },
                        ),
                      if (visible.isEmpty &&
                          query.isNotEmpty &&
                          !_unassignedPerson.toLowerCase().contains(query) &&
                          !('me'.contains(query) ||
                              myName.toLowerCase().contains(query)))
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No matching person',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.lightText,
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final key = visible[index];
                              final name = display[key]!;
                              final isSelected = _aliasesFor(
                                _resolvedAssignee,
                              ).contains(key);
                              return ListTile(
                                dense: true,
                                leading: AppAvatar(
                                  avatarUrl: AvatarCacheService().urlFor(
                                    uid: _pickerUids[key],
                                    phone: _pickerPhones[key],
                                    name: name,
                                  ),
                                  initials: Helpers.getInitials(name),
                                  radius: 16,
                                  color: AppTheme.headerGreen,
                                  fontSize: 12,
                                ),
                                title: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (_pickerPremium[key] == true)
                                      const PremiumBadge(size: 14),
                                  ],
                                ),
                                subtitle: Text(
                                  '${isSelected ? selCounts.active : (_pickerActive[key] ?? 0)} Active | '
                                  '${isSelected ? selCounts.overdue : (_pickerOverdue[key] ?? 0)} Overdue | '
                                  '${isSelected ? selCounts.blocked : (_pickerBlocked[key] ?? 0)} Blocked'
                                  '${_pickerLastSeen[key] == null ? '' : ' · ${_formatAgo(_pickerLastSeen[key]!)}'}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.secondaryText,
                                  ),
                                ),
                                trailing: isSelected
                                    ? const Icon(
                                        Icons.check_circle,
                                        size: 20,
                                        color: AppTheme.headerGreen,
                                      )
                                    : null,
                                onTap: () {
                                  // Switch FIRST, then dismiss (see the
                                  // 'Unassigned' row above) — guarantees the
                                  // person and list update even if the sheet
                                  // dismiss misbehaves on this context.
                                  _selectPerson(name);
                                  if (Navigator.of(ctx).canPop()) {
                                    Navigator.of(ctx).pop();
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Relative "time ago" for the last activity shown in the picker sheet.
  String _formatAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return Helpers.formatDate(t);
  }

  /// Restore the remembered picker sort mode (name / tasks / recent).
  Future<void> _loadPickerSortPref() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_pickerSortPrefKey);
    if ((mode == 'name' || mode == 'tasks' || mode == 'recent') &&
        mode != _pickerSortMode &&
        mounted) {
      setState(() => _pickerSortMode = mode!);
    }
  }

  void _toggleAttentionMode() {
    setState(() {
      _attentionMode = !_attentionMode;
      // The bell also initiates the Actions-tab filter: it selects the same
      // 'Needs Attention' time-chip value, so the chip row visibly shows the
      // mode instead of the bell appearing to do nothing there.
      _timeFilter = _attentionMode ? 'Needs Attention' : kActionTimeToday;
    });
    // Confirm the view switch so the re-sort is obvious to the user. Keep it
    // to a couple of words — the long sentence wrapped across the snackbar
    // and read as clutter (user feedback).
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_attentionMode ? 'Needs Attention' : 'Showing all tasks'),
          backgroundColor: _attentionMode
              ? const Color(0xFFC92A2A)
              : AppTheme.primaryGreen,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Pending action count for one task: only actions that still need a
  /// response or closure count — informational actions are ignored.
  /// A reply closes queries/requests/extensions; follow-ups and blockers
  /// stay open until marked done (same rule as the Pending line and the
  /// bell chips). Straight from the action-icons cache — no extra queries.
  int _pendingActionCount(String taskId) {
    try {
      final rows = context.read<TaskProvider>().getActionIcons(taskId);
      if (rows == null || rows.isEmpty) return 0;
      return rows
          .where(
            (r) => Helpers.isActionPending(
              r['actionType'] as String?,
              isDone: ((r['isDone'] as int?) ?? 0) != 0,
              isReplied: ((r['isReplied'] as int?) ?? 0) != 0,
            ),
          )
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// Disjoint status partition of the current view's task list ([_allTasks]).
  /// Shared by the header summary strip and the assignee picker's selected
  /// row so the two always agree for the person being viewed. The picker's
  /// per-person preview is built from name clusters (see
  /// [_rebuildPickerIndex]), which can under-count a person whose tasks are
  /// matched here by resolved UID/phone as well — so the selected row
  /// overrides its preview with these authoritative numbers.
  /// Single source of truth for how a task is bucketed, shared by the summary
  /// strip and the status filter menu so the two can never disagree.
  /// Returns one of: active | blocked | overdue | done | cancelled. Active
  /// deliberately EXCLUDES overdue (separate columns); Done = any closed task
  /// regardless of progress; Cancelled is its own bucket (not folded into Done).
  String _bucketOf(TaskModel t, {required DateTime today}) {
    if (t.isCancelled && !t.isClosed) return 'cancelled';
    if (t.isClosed) return 'done';
    if (t.extraFields?['isBlocked'] == true) return 'blocked';
    final d = t.deadline;
    if (d != null && DateTime(d.year, d.month, d.day).isBefore(today)) {
      return 'overdue';
    }
    return 'active';
  }

  ({int active, int blocked, int overdue, int done, int cancelled, int archived})
  _summaryCounts() {
    int active = 0, blocked = 0, overdue = 0, done = 0, cancelled = 0, archived = 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final t in _allTasks) {
      if (t.isDeleted) continue;
      if (t.isArchived) {
        // Archived counts only the selected person's assignee-side tasks —
        // creator-side pairs would inflate the stat for someone else's work.
        if (_personAsAssigneeIds.contains(t.id)) archived++;
        continue;
      }
      final bucket = _bucketOf(t, today: today);
      if (bucket == 'active') {
        active++;
      } else if (bucket == 'blocked') {
        blocked++;
      } else if (bucket == 'overdue') {
        overdue++;
      } else if (bucket == 'done') {
        done++;
      } else if (bucket == 'cancelled') {
        cancelled++;
      }
    }
    return (
      active: active,
      blocked: blocked,
      overdue: overdue,
      done: done,
      cancelled: cancelled,
      archived: archived,
    );
  }

  /// Brief summary strip for the Assignee home: how many tasks are Active,
  /// Blocked or Overdue, plus how many actions are still pending.
  Widget _buildSummaryStrip() {
    // Disjoint partition of this person's tasks so the five working columns
    // (Active + Blocked + Overdue + Done + Cancelled) always total to the
    // header count; Archived is reported separately (assignee-side only).
    final (
      active: active,
      blocked: blocked,
      overdue: overdue,
      done: done,
      cancelled: cancelled,
      archived: archived,
    ) = _summaryCounts();

    // Calm inline summary: one quiet centred line, no tinted band and no
    // dividers. All count numbers render in black (matching the CRM view) —
    // colour is no longer used to flag Blocked/Overdue, so the strip stays
    // uniform regardless of the counts. The numbers remain a disjoint
    // partition that totals the header "N tasks".
    // One Wrap child per stat. A single Text.rich let the line break between a
    // count and its label ("... · 10" / "Archived" on the next line), so each
    // stat now carries its own leading dot and moves down as one unit when the
    // five columns do not fit the width.
    final stats = <(int, String, Color?)>[
      (active, 'Active', null),
      (blocked, 'Blkd', null),
      (overdue, 'Over', null),
      (done, 'Done', null),
      (cancelled, 'Canc', null),
      (archived, 'Arch', null),
    ];

    Widget stat(int i) {
      final (n, label, alert) = stats[i];
      final color = (alert != null && n > 0) ? alert : null;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 7),
              child: Text(
                '·',
                style: TextStyle(fontSize: 11.5, color: AppTheme.lightText),
              ),
            ),
          Text(
            '$n ',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color ?? AppTheme.primaryText,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: color ?? AppTheme.secondaryText,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 7),
      child: Wrap(
        alignment: WrapAlignment.center,
        runSpacing: 2,
        children: [for (var i = 0; i < stats.length; i++) stat(i)],
      ),
    );
  }

  /// Sort picker person-keys by the currently selected (persisted) mode.
  List<String> _sortPickerKeys(List<String> keys) {
    final sorted = List<String>.of(keys);
    switch (_pickerSortMode) {
      case 'tasks':
        sorted.sort((a, b) {
          final byCount = (_pickerCounts[b] ?? 0).compareTo(
            _pickerCounts[a] ?? 0,
          );
          return byCount != 0
              ? byCount
              : _pickerDisplay[a]!.toLowerCase().compareTo(
                  _pickerDisplay[b]!.toLowerCase(),
                );
        });
        break;
      case 'recent':
        sorted.sort((a, b) {
          final ta = _pickerLastSeen[a];
          final tb = _pickerLastSeen[b];
          if (ta == null && tb == null) return 0;
          if (ta == null) return 1;
          if (tb == null) return -1;
          return tb.compareTo(ta);
        });
        break;
      default:
        sorted.sort(
          (a, b) => _pickerDisplay[a]!.toLowerCase().compareTo(
            _pickerDisplay[b]!.toLowerCase(),
          ),
        );
    }
    return sorted;
  }

  /// Small selectable chip for the picker sheet sort toggle.
  Widget _sortModeChip(
    void Function(void Function()) setSheetState,
    String mode,
    String label,
  ) {
    final selected = _pickerSortMode == mode;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () {
          setSheetState(() => _pickerSortMode = mode);
          SharedPreferences.getInstance().then(
            (p) => p.setString(_pickerSortPrefKey, mode),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.headerGreen.withOpacity(0.12)
                : AppTheme.lightGrey.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppTheme.headerGreen
                  : AppTheme.lightText.withOpacity(0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? AppTheme.headerGreen : AppTheme.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  /// Apply a VIEW filter forwarded from the home screen's 3-dot menu.
  void _applyExternalFilter(String value) {
    if (!mounted) return;
    setState(() => _statusFilter = value);
  }

  /// Reset the status filter locally (chip × or Clear all) and tell the
  /// embedding home screen to drop its AppBar 'Filter:' subtitle too.
  void _clearLocalStatusFilter() {
    setState(() => _statusFilter = 'All');
    widget.onLocalFiltersCleared?.call();
  }

  /// Clear all (filter + sort) from the chip bar.
  void _clearAllLocalFilters() {
    setState(() {
      _statusFilter = 'All';
      _sortBy = 'Last Action';
    });
    widget.onLocalFiltersCleared?.call();
  }

  /// Apply a SORT option forwarded from the home screen's 3-dot menu.
  void _applyExternalSort(String value) {
    // Map home-only sort labels to the ones supported here
    var mapped = value;
    if (value == 'Deadline') mapped = 'Due Date';
    if (value == 'Start Date') mapped = 'Created';
    if (!mounted) return;
    setState(() => _sortBy = mapped);
  }

  /// Apply the status filter (from the 3-dot menu)
  List<TaskModel> _applyStatusFilter(List<TaskModel> tasks) {
    // Deleted tasks are only visible in the dedicated Deleted view
    if (_statusFilter == 'Deleted') {
      return tasks.where((t) => t.isDeleted).toList();
    }
    // Archived tasks are only visible in the dedicated Archived view
    if (_statusFilter == 'Archived') {
      return tasks.where((t) => t.isArchived && !t.isDeleted).toList();
    }
    tasks = tasks.where((t) => !t.isDeleted && !t.isArchived).toList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_statusFilter) {
      case 'Active':
        return tasks
            .where((t) => _bucketOf(t, today: today) == 'active')
            .toList();
      case 'Blocked':
        return tasks
            .where((t) => _bucketOf(t, today: today) == 'blocked')
            .toList();
      case 'Scheduled':
        return tasks.where((t) {
          final extra = t.extraFields;
          return extra != null &&
              extra['isDraft'] == true &&
              extra['scheduledDate'] != null;
        }).toList();
      case 'Completed':
        return tasks
            .where((t) => _bucketOf(t, today: today) == 'done')
            .toList();
      case 'Cancelled':
        return tasks
            .where((t) => _bucketOf(t, today: today) == 'cancelled')
            .toList();
      case 'Overdue':
        return tasks
            .where((t) => _bucketOf(t, today: today) == 'overdue')
            .toList();
      case 'High Priority':
        return tasks.where((t) => t.priority == 3).toList();
      case 'Urgent':
        return tasks.where((t) => t.isUrgent).toList();
      case 'Unassigned':
        // My own tasks still waiting to be assigned (assign-later).
        final myUid = context.read<AuthProvider>().userModel?.uid ?? '';
        return tasks
            .where((t) => t.createdBy == myUid && t.assignedTo.isEmpty)
            .toList();
      case 'All':
      default:
        return tasks;
    }
  }

  /// Apply sort
  List<TaskModel> _applySort(List<TaskModel> tasks) {
    final sorted = List<TaskModel>.from(tasks);
    switch (_sortBy) {
      case 'Due Date':
        sorted.sort((a, b) {
          if (a.deadline == null && b.deadline == null) return 0;
          if (a.deadline == null) return 1;
          if (b.deadline == null) return -1;
          return a.deadline!.compareTo(b.deadline!);
        });
        break;
      case 'Priority':
        sorted.sort((a, b) => b.priority.compareTo(a.priority));
        break;
      case 'Created':
        sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case 'Name':
        sorted.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        break;
      case 'Progress':
        sorted.sort((a, b) => a.progress.compareTo(b.progress));
        break;
      case 'Last Action':
      default:
        // Sort by the same key the card displays (lastMessageTime ?? updatedAt)
        // so list order always matches the visible "ago" timestamps.
        sorted.sort(
          (a, b) => (b.lastMessageTime ?? b.updatedAt).compareTo(
            a.lastMessageTime ?? a.updatedAt,
          ),
        );
        break;
    }
    return sorted;
  }

  // Per-build memo of the filter+search+sort pass: the header count and the
  // list itself both read _displayedTasks, and every scroll rebuild would
  // otherwise re-filter and re-sort the full task list multiple times.
  // Invalidated by _allTasks identity change, filter/sort/search change, or
  // the explicit clear in _dismissTask (which mutates _allTasks in place).
  List<TaskModel>? _displayedCache;
  List<TaskModel>? _displayedCacheSource;
  String? _displayedCacheFilter;
  String? _displayedCacheSort;
  String? _displayedCacheQuery;
  bool? _displayedCacheAttention;

  /// How many tasks the bell filter ran against — after the status filter and
  /// search, before the pending-action filter — so the attention summary can
  /// say "showing N of M" truthfully under any filter. Written by
  /// [_displayedTasks] on every cache miss; a cache hit means the same key set,
  /// so the value stays correct.
  int _attentionUniverse = 0;

  List<TaskModel> get _displayedTasks {
    final q = context.read<TaskProvider>().searchQuery.trim().toLowerCase();
    final cached = _displayedCache;
    if (cached != null &&
        identical(_displayedCacheSource, _allTasks) &&
        _displayedCacheFilter == _statusFilter &&
        _displayedCacheSort == _sortBy &&
        _displayedCacheAttention == _attentionMode &&
        _displayedCacheQuery == q) {
      return cached;
    }

    var tasks = _applyStatusFilter(_allTasks);

    // Apply the home search bar here too — TaskProvider filters the My
    // Tasks lists but this screen loads its own query, so match search on
    // title, description, category, assignee, tags and milestone titles.
    if (q.isNotEmpty) {
      tasks = tasks.where((task) {
        if (task.title.toLowerCase().contains(q)) return true;
        if (task.description.toLowerCase().contains(q)) return true;
        if (task.assignedTo.toLowerCase().contains(q)) return true;
        if ((task.category ?? '').toLowerCase().contains(q)) return true;
        if (task.tags.any((tag) => tag.toLowerCase().contains(q))) {
          return true;
        }
        if (task.milestones.any((m) => m.title.toLowerCase().contains(q))) {
          return true;
        }
        return false;
      }).toList();
    }

    var result = _applySort(tasks);
    _attentionUniverse = result.length;
    // Attention mode (bell): show EVERY open task that still has a pending
    // action — most recent first, per the active sort. No cap: the bell
    // promises "all tasks needing action", so hiding any would lie.
    if (_attentionMode) {
      result = result
          .where(
            (t) =>
                !t.isClosed &&
                !t.isCancelled &&
                !t.isDeleted &&
                !t.isArchived &&
                _pendingActionCount(t.id) > 0,
          )
          .toList();
    }
    _displayedCache = result;
    _displayedCacheSource = _allTasks;
    _displayedCacheFilter = _statusFilter;
    _displayedCacheSort = _sortBy;
    _displayedCacheAttention = _attentionMode;
    _displayedCacheQuery = q;
    return result;
  }

  bool get _hasActiveFilters =>
      _statusFilter != 'All' || _sortBy != 'Last Action';

  // ── Action items extraction ─────────────────────────────────────────────

  Future<List<ActionItem>> _extractActionItems() async {
    // Build task map for createdBy/assignedTo lookup
    final taskMap = <String, TaskModel>{};
    for (final task in _allTasks) {
      taskMap[task.id] = task;
    }

    // Query only this person's tasks' actions via a parentId IN (...) query,
    // instead of loading every action row and discarding non-matching parents
    // in Dart. Scales with this person's task count, not the whole DB.
    final actionRows = await LocalDatabaseService().getActionsForParents(
      taskMap.keys.toList(),
    );

    final allActionItems = <ActionItem>[];
    for (final row in actionRows) {
      final parentId = row['parentId'] as String;
      final task = taskMap[parentId];
      // Skip actions for tasks not in our list (this person's tasks only)
      if (task == null) continue;

      final actionTypeStr = row['actionType'] as String;
      final messageText = row['text'] as String;

      // Skip "deadline updated" actions - not relevant for Actions tab
      if (messageText.toLowerCase().contains('deadline updated')) continue;

      final ActionType actionType;
      switch (actionTypeStr) {
        case 'reminder':
          actionType = ActionType.reminder;
          break;
        case 'followup':
          actionType = ActionType.followUp;
          break;
        case 'warning':
          actionType = ActionType.warning;
          break;
        case 'query':
          actionType = ActionType.query;
          break;
        case 'blocker':
          actionType = ActionType.blocker;
          break;
        case 'approval':
          actionType = ActionType.approval;
          break;
        case 'extension':
          actionType = ActionType.extension;
          break;
        case 'progress':
          actionType = ActionType.progressReport;
          break;
        case 'cash':
        // 💳 receivable cards ride the Cash tile (Sales parity).
        case 'payment':
          actionType = ActionType.cash;
          break;
        case 'call':
          actionType = ActionType.call;
          break;
        case 'meeting':
          actionType = ActionType.meeting;
          break;
        case 'sitevisit':
          actionType = ActionType.siteVisit;
          break;
        default:
          continue;
      }

      final scheduledDateMs = row['scheduledDate'] as int?;
      final createdAtMs = row['createdAt'] as int;
      final scheduledDate = scheduledDateMs != null
          ? DateTime.fromMillisecondsSinceEpoch(scheduledDateMs)
          : DateTime.fromMillisecondsSinceEpoch(createdAtMs);

      allActionItems.add(
        ActionItem(
          id: row['id'] as String,
          taskId: parentId,
          taskTitle: row['parentTitle'] as String? ?? task.title,
          type: actionType,
          message: row['text'] as String,
          scheduledDate: scheduledDate,
          hasScheduledDate: scheduledDateMs != null,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
          createdBy: task.createdBy,
          assignedTo: task.assignedTo,
          isCompleted: false,
          messageId: row['id'] as String,
          isReplied: (row['isReplied'] as int) == 1,
          isFollowUpDone: (row['isDone'] as int) == 1,
          seqNo: row['seqNo'] as int?,
        ),
      );
    }

    allActionItems.sort(
      (a, b) => CardActionIcons.compareActions(
        a.scheduledDate,
        a.createdAt,
        b.scheduledDate,
        b.createdAt,
      ),
    );
    return allActionItems;
  }

  void _ensureActionsFuture() {
    final taskIds = _allTasks.map((t) => t.id).toSet();
    if (_actionsFuture == null ||
        taskIds.length != _actionsTaskIds.length ||
        !taskIds.containsAll(_actionsTaskIds)) {
      _actionsTaskIds = taskIds;
      _actionsFuture = _extractActionItems();
      _visibleActionCards = _actionCardsPageSize;
    }
  }

  /// Attention-mode summary. States plainly what the bell did — in the Task
  /// module it FILTERS the list to open tasks that still have a pending action
  /// — and it never vanishes: an empty result has to say so, otherwise a red
  /// bell over a blank list reads as a bug. [compact] collapses it to one short
  /// line for the narrow AppBar title.
  Widget _buildNeedsAttentionStrip({
    Color textColor = AppTheme.secondaryText,
    Color iconColor = const Color(0xFFC92A2A),
    EdgeInsets padding = const EdgeInsets.fromLTRB(16, 0, 16, 2),
    bool compact = false,
  }) {
    return FutureBuilder<List<ActionItem>>(
      future: _actionsFuture,
      builder: (context, snap) {
        // Only open tasks can have "pending" actions — closed/archived
        // cards show no chips, so counting them here would make the
        // summary disagree with what the cards display.
        final openIds = _allTasks
            .where(
              (t) =>
                  !t.isClosed &&
                  !t.isCancelled &&
                  !t.isDeleted &&
                  !t.isArchived,
            )
            .map((t) => t.id)
            .toSet();
        final pending = (snap.data ?? [])
            .where((i) => openIds.contains(i.taskId) && _isPendingAction(i))
            .toList();
        // Pending is already decided by the shared _isPendingAction above; the
        // tally just renders per canonical key from the one module-agnostic
        // label map so this strip can't drift from the Needs Attention filter.
        final counts = <String, int>{};
        for (final i in pending) {
          final key = i.type.key;
          counts[key] = (counts[key] ?? 0) + 1;
        }
        final parts = Helpers.actionAttentionLabels.entries
            .where((e) => (counts[e.key] ?? 0) > 0)
            .map((e) => '${counts[e.key]} ${e.value}')
            .toList();

        // `shown` is what the list actually renders, so it — not `parts` —
        // drives the empty-state wording. Keep every line short: the full
        // sentences wrapped over three or four lines on narrow phones and
        // read as clutter (user feedback).
        final shown = _displayedTasks.length;
        final total = _attentionUniverse;
        final String headline;
        String? detail;
        if (shown == 0) {
          headline = 'Nothing needs attention';
        } else if (compact) {
          headline = '$shown of $total · ${pending.length} pending';
        } else {
          headline = 'Needs Attention: $shown of $total tasks';
          if (parts.isNotEmpty) {
            detail = parts.join(' · ');
          }
        }

        return Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.pending_actions, size: 13, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 11.5, color: textColor),
                    children: [
                      TextSpan(
                        text: headline,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (detail != null) TextSpan(text: '\n$detail'),
                    ],
                  ),
                  maxLines: compact ? 1 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        children: [
          _buildEmbeddedHeader(),
          _buildEmbeddedTabBar(),
          Expanded(
            child: _resolvedAssignee.isEmpty
                ? _buildNoPersonState()
                : _buildTabContent(),
          ),
        ],
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null &&
            details.primaryVelocity! < -500) {
          _handleBackPress();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: AppTheme.headerGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackPress,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Assignee Tasks',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              Text(
                'For $_resolvedAssignee • By $_resolvedAssigner',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              // Meaningful only with the bell on — and this standalone AppBar
              // has no bell toggle, so it stays empty here. Gated for parity
              // with the Sales AppBar, and compact because an AppBar title is
              // far too narrow for the full sentence.
              if (_attentionMode)
                _buildNeedsAttentionStrip(
                  textColor: Colors.white.withOpacity(0.85),
                  iconColor: Colors.white,
                  padding: EdgeInsets.zero,
                  compact: true,
                ),
            ],
          ),
          actions: [
            if (_selectedTab == 'tasks')
              IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onPressed: () => _showFilterMenu(context),
              ),
            if (_selectedTab == 'actions')
              IconButton(
                icon: const Icon(Icons.download_outlined, color: Colors.white),
                tooltip: 'Export Current View',
                onPressed: _exportActions,
              ),
          ],
        ),
        body: PopScope(
          // On the ACTIONS tab, system back returns to the ASSIGNEE TASKS
          // tab first instead of leaving the screen.
          canPop: _selectedTab != 'actions',
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _switchToTab('tasks');
          },
          child: Column(
            children: [
              // White tab bar
              Container(
                color: Colors.white,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: AppTheme.headerGreen,
                  indicatorWeight: 3,
                  labelColor: AppTheme.headerGreen,
                  unselectedLabelColor: AppTheme.secondaryText,
                  labelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  tabs: const [
                    Tab(text: 'ASSIGNEE TASKS'),
                    Tab(text: 'ACTIONS'),
                  ],
                  onTap: (index) {
                    setState(() {
                      _selectedTab = index == 0 ? 'tasks' : 'actions';
                    });
                  },
                ),
              ),
              // Content
              Expanded(child: _buildTabContent()),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _createNewTask(),
          backgroundColor: AppTheme.headerGreen,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  /// Back-press handling: on the ACTIONS tab, return to the ASSIGNEE TASKS
  /// tab first; only leave the screen from the tasks tab. Used by the AppBar
  /// back button, the system back button (via PopScope) and the left swipe.
  void _handleBackPress() {
    if (_selectedTab == 'actions') {
      _switchToTab('tasks');
    } else {
      Navigator.pop(context);
    }
  }

  void _switchToTab(String tab) {
    setState(() => _selectedTab = tab);
    _tabController.animateTo(tab == 'tasks' ? 0 : 1);
  }

  /// Content of the current sub-tab (tasks with filter chips, or actions).
  Widget _buildTabContent() {
    return _selectedTab == 'actions'
        ? _buildActionsTab()
        : Column(
            children: [
              // Brief summary lives under the assignee name in the embedded
              // header; the standalone screen keeps it above the list. The
              // standalone AppBar has no bell toggle, so _attentionMode is
              // always false here and this strip always shows.
              if (!widget.embedded && !_attentionMode) _buildSummaryStrip(),
              // Active filter chip bar (shown when filters are active)
              if (_hasActiveFilters)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: AppTheme.headerGreen.withOpacity(0.05),
                  child: Row(
                    children: [
                      if (_statusFilter != 'All')
                        _buildFilterChip(
                          label: _statusFilter,
                          onClear: _clearLocalStatusFilter,
                        ),
                      if (_sortBy != 'Last Action') ...[
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          label: '↕ $_sortBy',
                          onClear: () =>
                              setState(() => _sortBy = 'Last Action'),
                        ),
                      ],
                      const Spacer(),
                      TextButton(
                        onPressed: _clearAllLocalFilters,
                        child: const Text(
                          'Clear all',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              // Purge notice for the Deleted view
              if (_statusFilter == 'Deleted')
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: Colors.grey.withOpacity(0.08),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.auto_delete_outlined,
                        size: 14,
                        color: AppTheme.lightText,
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Swipe a card to delete it forever. Unused deletes are purged after 30 days.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.lightText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Info notice for the Archived view
              if (_statusFilter == 'Archived')
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: AppTheme.headerGreen.withOpacity(0.08),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.archive_outlined,
                        size: 14,
                        color: AppTheme.secondaryText,
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Swipe a card to unarchive it back to the normal views.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Task list
              Expanded(child: _buildTaskList()),
            ],
          );
  }

  // ── Embedded (home ASSIGNEE tab) widgets ────────────────────────────

  Widget _buildEmbeddedHeader() {
    _ensureActionsFuture();
    final headerRow = Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _showAssigneePicker,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  // Person's photo / preset avatar when resolved; initials
                  // fallback (also on load failure — e.g. offline, revoked
                  // URL). AppAvatar understands `avatar:<id>` preset strings.
                  _assigneeAvatarUrl != null || _resolvedAssignee.isNotEmpty
                      ? AppAvatar(
                          avatarUrl: _assigneeAvatarUrl,
                          initials: Helpers.getInitials(_resolvedAssignee),
                          radius: 18,
                          color: AppTheme.headerGreen,
                          fontSize: 13,
                        )
                      : CircleAvatar(
                          radius: 18,
                          backgroundColor: AppTheme.headerGreen.withOpacity(
                            0.15,
                          ),
                          child: const Icon(
                            Icons.person_search,
                            size: 18,
                            color: AppTheme.headerGreen,
                          ),
                        ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _resolvedAssignee.isEmpty
                                    ? 'Select Assignee'
                                    : _resolvedAssignee,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: AppTheme.secondaryText,
                            ),
                          ],
                        ),
                        if (_resolvedAssignee.isNotEmpty &&
                            (_assigneeDesignation?.isNotEmpty ?? false))
                          Text(
                            _assigneeDesignation!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (_resolvedAssignee.isNotEmpty)
                          Text(
                            '${_displayedTasks.length} ${_displayedTasks.length == 1 ? 'task' : 'tasks'}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Attention-mode toggle (replaced the old export button): cards
          // switch to pending actions and attention tasks float to the top.
          IconButton(
            icon: Icon(
              _attentionMode
                  ? Icons.notifications_active
                  : Icons.notifications_active_outlined,
              color: _attentionMode
                  ? const Color(0xFFC92A2A)
                  : AppTheme.secondaryText,
            ),
            tooltip: _attentionMode
                ? 'Attention mode on — tap to turn off'
                : 'Needs attention',
            onPressed: _toggleAttentionMode,
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        headerRow,
        // Both summaries share this one full-width slot below the header. The
        // attention line used to sit inside the header column next to the
        // avatar, where the narrow width truncated it — that is why the bell
        // summary read as unclear.
        //
        // Tasks tab only: this strip tallies the TASK list the bell filters.
        // On the Actions tab the bell works through the 'Needs Attention'
        // time chip instead, which is already visible in the filter row.
        if (_resolvedAssignee.isNotEmpty && _selectedTab == 'tasks')
          _attentionMode
              ? _buildNeedsAttentionStrip(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                )
              : _buildSummaryStrip(),
      ],
    );
  }

  Widget _buildEmbeddedTabBar() {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        indicatorColor: AppTheme.headerGreen,
        indicatorWeight: 3,
        labelColor: AppTheme.headerGreen,
        unselectedLabelColor: AppTheme.secondaryText,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        tabs: const [
          Tab(text: 'ASSIGNEE TASKS'),
          Tab(text: 'ACTIONS'),
        ],
        onTap: (index) {
          setState(() {
            _selectedTab = index == 0 ? 'tasks' : 'actions';
          });
        },
      ),
    );
  }

  Widget _buildNoPersonState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_search_outlined, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'No assignee selected',
            style: TextStyle(fontSize: 16, color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _showAssigneePicker,
            icon: const Icon(
              Icons.search,
              size: 18,
              color: AppTheme.headerGreen,
            ),
            label: const Text(
              'Select Assignee',
              style: TextStyle(
                color: AppTheme.headerGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.headerGreen.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.headerGreen.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.headerGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onClear,
            child: const Icon(
              Icons.close,
              size: 12,
              color: AppTheme.headerGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList() {
    final tasks = _displayedTasks;

    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.task_alt,
              size: 80,
              color: AppTheme.lightText.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              _statusFilter != 'All' ? 'No tasks matching filter' : 'No tasks',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.lightText.withOpacity(0.6),
              ),
            ),
            if (_statusFilter != 'All') ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _statusFilter = 'All'),
                child: const Text('Clear filter'),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      key: const PageStorageKey('assigneeTaskList'),
      // Bottom clearance so the last card never collides with the system
      // navigation bar / FAB.
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 96),
      // Pre-build ~10 cards off-screen so card construction cost is paid
      // before the card scrolls into view (smoother fast scrolls).
      cacheExtent: 800,
      itemCount: tasks.length,
      itemBuilder: (context, index) => _buildTaskCard(tasks[index]),
    );
  }

  Widget _buildTaskCard(TaskModel task) {
    final authProvider = context.read<AuthProvider>();
    final currentUid = authProvider.userModel?.uid ?? '';
    final currentName = authProvider.userModel?.name ?? '';
    final currentPhone = authProvider.userModel?.phone ?? '';

    final Widget card = TaskCard(
      task: task,
      isSelected:
          widget.selectionMode && widget.selectedTaskIds.contains(task.id),
      onTap: () {
        if (widget.selectionMode && widget.onToggleSelection != null) {
          widget.onToggleSelection!(task);
          return;
        }
        if (task.isDeleted) {
          _showDeletedTaskDialog(task);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)),
          );
        }
      },
      onLongPress: () {
        if (widget.onLongPressTask != null) {
          widget.onLongPressTask!(task);
          return;
        }
        if (task.isDeleted) {
          _showDeletedTaskDialog(task);
        } else {
          _showTaskOptionsSheet(task);
        }
      },
      showAssigner: false,
      // Show the FIRST (main) assignee's name + avatar on every card as a
      // rule; the list still includes tasks where the selected person is any
      // assignee or the creator.
      showAssigneeName: true,
      currentUid: currentUid,
      currentName: currentName,
      currentPhone: currentPhone,
      pendingActions: _attentionMode,
    );

    // No swipe gestures while multi-selecting cards.
    if (widget.selectionMode) return card;

    final bool isNewDraft = task.extraFields?['isDraft'] == true;
    // Deleted view purges first — a deleted task may still carry the
    // isDraft flag, and soft-deleting it again would snap the card back.
    if (task.isDeleted) {
      // Deleted view: swipe purges the card permanently.
      return Dismissible(
        key: Key(task.id),
        direction: DismissDirection.endToStart,
        // Less sensitive: require ~75% of the width dragged before the swipe
        // fires (Flutter's default 0.4 archived cards on a short flick).
        dismissThresholds: const {DismissDirection.endToStart: 0.75},
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: const Color(0xFFC92A2A),
          child: const Icon(
            Icons.delete_forever_outlined,
            color: Colors.white,
            size: 24,
          ),
        ),
        onDismissed: (_) => _dismissTask(task, action: 'purge'),
        child: card,
      );
    }
    if (isNewDraft) {
      // Drafts swipe away to delete.
      return Dismissible(
        key: Key(task.id),
        direction: DismissDirection.endToStart,
        // Less sensitive: require ~75% of the width dragged before the swipe
        // fires (Flutter's default 0.4 archived cards on a short flick).
        dismissThresholds: const {DismissDirection.endToStart: 0.75},
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: const Color(0xFFE03131),
          child: const Icon(
            Icons.delete_outline,
            color: Colors.white,
            size: 24,
          ),
        ),
        onDismissed: (_) => _dismissTask(task, action: 'delete'),
        child: card,
      );
    }
    if (task.isArchived) {
      // Archived view: swipe unarchives the card back to normal views.
      return Dismissible(
        key: Key(task.id),
        direction: DismissDirection.endToStart,
        // Less sensitive: require ~75% of the width dragged before the swipe
        // fires (Flutter's default 0.4 archived cards on a short flick).
        dismissThresholds: const {DismissDirection.endToStart: 0.75},
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: AppTheme.headerGreen,
          child: const Icon(
            Icons.unarchive_outlined,
            color: Colors.white,
            size: 24,
          ),
        ),
        onDismissed: (_) => _dismissTask(task, action: 'unarchive'),
        child: card,
      );
    }

    // Real tasks swipe away to archive.
    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.endToStart,
      // Less sensitive: require ~75% of the width dragged before the swipe
      // fires (Flutter's default 0.4 archived cards on a short flick).
      dismissThresholds: const {DismissDirection.endToStart: 0.75},
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: const Color(0xFFF59F00),
        child: const Icon(
          Icons.archive_outlined,
          color: Colors.white,
          size: 24,
        ),
      ),
      onDismissed: (_) => _dismissTask(task, action: 'archive'),
      child: card,
    );
  }

  /// Shared swipe handler for the task list: removes the card from the local
  /// list immediately (so the dismissal sticks), then persists the action.
  /// action: 'delete' (draft), 'archive', 'unarchive' or 'purge' (forever).
  Future<void> _dismissTask(TaskModel task, {required String action}) async {
    setState(() {
      _allTasks.removeWhere((t) => t.id == task.id);
      // In-place mutation keeps the list identity — drop the displayed-tasks
      // memo so the swipe-away shows up immediately instead of snapping back.
      _displayedCache = null;
    });
    try {
      final taskProvider = context.read<TaskProvider>();
      switch (action) {
        case 'purge':
          await taskProvider.permanentlyDeleteTask(task.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Task deleted forever'),
                backgroundColor: Color(0xFFC92A2A),
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
        case 'unarchive':
          await taskProvider.unarchiveTask(task.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Task unarchived'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
        case 'archive':
          await taskProvider.archiveTask(task.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Task archived'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
        default:
          await taskProvider.deleteTask(task.id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to ${action == 'purge' ? 'delete' : action} task: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Restore / permanently delete dialog for a soft-deleted task.
  void _showDeletedTaskDialog(TaskModel task) {
    final taskProvider = context.read<TaskProvider>();
    final deletedDate = task.deletedAt != null
        ? Helpers.formatDate(task.deletedAt!)
        : 'unknown date';
    final myUid = context.read<AuthProvider>().userModel?.uid ?? '';
    // Restore / permanent-delete allowed for the creator OR the person who
    // deleted the task (parity with home_screen deleted dialog).
    final canManage = task.createdBy == myUid || task.deletedBy == myUid;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Deleted Task'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Deleted on $deletedDate',
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryText,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Deleted tasks are permanently removed 30 days after deletion.',
              style: TextStyle(fontSize: 12, color: AppTheme.lightText),
            ),
            if (!canManage) ...[
              const SizedBox(height: 8),
              const Text(
                'Only the task creator or the person who deleted it can restore or permanently remove it.',
                style: TextStyle(fontSize: 12, color: AppTheme.lightText),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (canManage)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await taskProvider.restoreTask(task.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Task restored'),
                      backgroundColor: AppTheme.primaryGreen,
                    ),
                  );
                }
              },
              child: const Text(
                'Restore',
                style: TextStyle(color: AppTheme.primaryGreen),
              ),
            ),
          if (canManage)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await taskProvider.permanentlyDeleteTask(task.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Task permanently deleted'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete Forever'),
            ),
        ],
      ),
    );
  }

  /// Long-press options for a (non-deleted) task card.
  void _showTaskOptionsSheet(TaskModel task) {
    final isCreator =
        task.createdBy == (context.read<AuthProvider>().userModel?.uid ?? '');
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                task.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.open_in_new,
                size: 20,
                color: AppTheme.headerGreen,
              ),
              title: const Text('Open Task', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TaskDetailScreen(task: task),
                  ),
                );
              },
            ),
            if (isCreator)
              ListTile(
                dense: true,
                leading: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Colors.red,
                ),
                title: const Text(
                  'Delete Task',
                  style: TextStyle(fontSize: 14, color: Colors.red),
                ),
                subtitle: const Text(
                  'Restorable for 30 days, then removed permanently',
                  style: TextStyle(fontSize: 10, color: AppTheme.lightText),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await context.read<TaskProvider>().deleteTask(task.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Task deleted — restore from the Deleted view within 30 days',
                        ),
                        backgroundColor: AppTheme.primaryGreen,
                      ),
                    );
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Actions Tab ─────────────────────────────────────────────────────────

  Widget _buildActionsTab() {
    // Cache the actions future (same pattern as task_actions_screen) so
    // provider-notification rebuilds don't discard the in-flight query and
    // pin the tab on the spinner. Recreate it only when the visible task
    // set changes (person switch / task reload) — the actions-table
    // listener already invalidates it on new action writes.
    _ensureActionsFuture();

    // Filter row outside FutureBuilder — never rebuilds on data changes
    return Column(
      children: [
        _buildActionsFilterRow(),

        Expanded(
          child: FutureBuilder<List<ActionItem>>(
            future: _actionsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                print('[ActionsTab] Error loading actions: ${snapshot.error}');
              }

              final allActionItems = snapshot.data ?? [];
              final actionItems = _applyActionFilter(allActionItems);
              // Cache for export
              _currentActionItems = actionItems;

              if (allActionItems.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 64,
                        color: AppTheme.lightText,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No action items',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Reminders, follow-ups and queries will appear here',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.lightText,
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (actionItems.isEmpty) {
                return Center(
                  child: Text(
                    'No actions matching filter',
                    style: TextStyle(fontSize: 14, color: AppTheme.lightText),
                  ),
                );
              }

              // Group actions by task
              final taskActions = <String, List<ActionItem>>{};
              for (final item in actionItems) {
                taskActions.putIfAbsent(item.taskId, () => []).add(item);
              }

              // Sort task groups by most recent action
              final sortedTaskIds = taskActions.keys.toList();
              sortedTaskIds.sort((a, b) {
                final actionsA = taskActions[a]!;
                final actionsB = taskActions[b]!;
                final keyA = actionsA
                    .map(
                      (x) => CardActionIcons.actionSortTuple(
                        x.scheduledDate,
                        x.createdAt,
                      ),
                    )
                    .reduce(CardActionIcons.minActionTuple);
                final keyB = actionsB
                    .map(
                      (x) => CardActionIcons.actionSortTuple(
                        x.scheduledDate,
                        x.createdAt,
                      ),
                    )
                    .reduce(CardActionIcons.minActionTuple);
                final cmp = keyA.$1.compareTo(keyB.$1);
                return cmp != 0 ? cmp : keyA.$2.compareTo(keyB.$2);
              });

              // Build task map
              final taskMap = <String, TaskModel>{};
              for (final t in _allTasks) {
                taskMap[t.id] = t;
              }

              // Pagination: render only the first N task cards, growing on scroll.
              final visibleCount = _visibleActionCards.clamp(
                0,
                sortedTaskIds.length,
              );
              final hasMore = visibleCount < sortedTaskIds.length;

              return NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (hasMore &&
                      n.metrics.pixels >= n.metrics.maxScrollExtent - 600 &&
                      mounted) {
                    setState(
                      () => _visibleActionCards =
                          (visibleCount + _actionCardsPageSize).clamp(
                            0,
                            sortedTaskIds.length,
                          ),
                    );
                  }
                  return false;
                },
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
                  itemCount: visibleCount + (hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= visibleCount) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final taskId = sortedTaskIds[index];
                    final task = taskMap[taskId];
                    final actions = taskActions[taskId]!;
                    if (task == null) return const SizedBox.shrink();
                    return _buildTaskActionCard(task, actions);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  bool _isPendingAction(ActionItem i) => Helpers.isActionPending(
    i.type.key,
    isDone: i.isFollowUpDone,
    isReplied: i.isReplied,
  );

  List<ActionItem> _applyActionFilter(List<ActionItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Axis 1 — time chip.
    List<ActionItem> out;
    switch (_timeFilter) {
      case 'Overdue':
        out = items.where((i) {
          final d = DateTime(
            i.scheduledDate.year,
            i.scheduledDate.month,
            i.scheduledDate.day,
          );
          // Overdue = a still-PENDING action past a REAL scheduled date
          // (hasScheduledDate): undated actions aging on their write date, and
          // informational logs, never pile here (see shared note on the main tab).
          return i.hasScheduledDate && d.isBefore(today) && _isPendingAction(i);
        }).toList();
        break;
      case 'Today':
        out = items.where((i) {
          final d = DateTime(
            i.scheduledDate.year,
            i.scheduledDate.month,
            i.scheduledDate.day,
          );
          return d == today;
        }).toList();
        break;
      case 'Upcoming':
        out = items.where((i) {
          final d = DateTime(
            i.scheduledDate.year,
            i.scheduledDate.month,
            i.scheduledDate.day,
          );
          return d.isAfter(today);
        }).toList();
        break;
      // No time filter — every action on this person's tasks; the sort below
      // still orders them, and the type axis still applies.
      case kActionTimeAll:
        out = items;
        break;
      case 'Needs Attention':
      default:
        out = items.where(_isPendingAction).toList();
        break;
    }

    // Axis 2 — optional action-type override.
    final type = _typeFilterToActionType(_typeFilter);
    if (type != null) out = out.where((i) => i.type == type).toList();
    return out;
  }

  /// Maps the type-sheet value to its [ActionType]; null means "all types".
  ActionType? _typeFilterToActionType(String? filter) {
    // The Type dropdown values are Task's catalog keys (see [_typeOptions]),
    // so map each key straight to its ActionType enum for the type-axis
    // filter. Warning / Extension / Progress have no case: they are no longer
    // Task actions, so they can never be selected from the dropdown.
    switch (filter) {
      case 'reminder':
        return ActionType.reminder;
      case 'followup':
        return ActionType.followUp;
      case 'query':
        return ActionType.query;
      case 'blocker':
        return ActionType.blocker;
      case 'approval':
        return ActionType.approval;
      case 'cash':
        return ActionType.cash;
      case 'call':
        return ActionType.call;
      case 'meeting':
        return ActionType.meeting;
      case 'sitevisit':
        return ActionType.siteVisit;
      default:
        return null;
    }
  }

  Widget _buildActionsFilterRow() {
    return Container(
      color: Colors.white,
      child: buildActionFilterDropdowns(
        timeOptions: _timeOptions,
        selectedTime: _timeFilter,
        onTimeChanged: (v) => setState(() {
          _timeFilter = v;
          _visibleActionCards = _actionCardsPageSize;
        }),
        typeOptions: _typeOptions,
        selectedType: _typeFilter,
        onTypeChanged: (v) => setState(() {
          _typeFilter = v;
          _visibleActionCards = _actionCardsPageSize;
        }),
      ),
    );
  }

  // Build grouped task action card (matching Main Actions tab UI)
  Widget _buildTaskActionCard(TaskModel task, List<ActionItem> actions) {
    final expanded = _expandedActionCards.contains(task.id);
    final sortedActions = actions
      ..sort(
        (a, b) => CardActionIcons.compareActions(
          a.scheduledDate,
          a.createdAt,
          b.scheduledDate,
          b.createdAt,
        ),
      );

    // Running "#N" per base type (chronological) for the one-line rows.
    final chrono = List<ActionItem>.from(actions)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final seq = <String, int>{};
    final actionNumbers = <ActionItem, int>{};
    for (final a in chrono) {
      final base = CardActionIcons.actionBaseLabel(
        typeName: a.type.name,
        message: a.message,
      );
      // Cash/Payment sub-types share one family counter (cards-numbering
      // parity) — see CardActionIcons.numberingGroupKey.
      final group = CardActionIcons.numberingGroupKey(base);
      final n = (seq[group] ?? 0) + 1;
      seq[group] = n;
      actionNumbers[a] = n;
    }
    final accentColor = AppTheme.headerGreen;

    // Deadline chip (shared human-readable label — CardWidgets); overdue
    // days stop accruing once the task is closed/cancelled.
    final deadlineData = DeadlineChipData.compute(
      task.createdAt,
      task.deadline,
      isOpen: !task.isClosed && !task.isCancelled,
    );

    final displayInitials = Helpers.getInitials(task.assignedTo);

    // Photo/preset avatar of the assignee, resolved from the same cache the
    // task cards use. Prefer the index-aligned multi-assignee identity: the
    // primary assignedToUid/Phone can be blank on a group task, so the same
    // person showed a photo on one card and initials on another (the
    // actions-tab twin of the task-card fix). 'Me' has no by-name cache entry,
    // so it falls back to the selected person's header avatar — exactly who
    // this screen is showing.
    String? assigneeUid = task.assignedToUid;
    String? assigneePhone = task.assignedToPhone;
    final aNames = task.extraFields?['assigneeNames'];
    final aUids = task.extraFields?['assigneeUids'];
    final aPhones = task.extraFields?['assigneePhones'];
    if (aNames is List) {
      final names = aNames.map((e) => e?.toString().trim() ?? '').toList();
      final idx = names.indexOf(task.assignedTo.trim());
      if (idx >= 0) {
        if (aUids is List && aUids.length == names.length) {
          final u = aUids[idx]?.toString().trim() ?? '';
          if (u.isNotEmpty) assigneeUid = u;
        }
        if (aPhones is List && aPhones.length == names.length) {
          final p = aPhones[idx]?.toString().trim() ?? '';
          if (p.isNotEmpty) assigneePhone = p;
        }
      }
    }
    String? assigneeAvatarUrl = AvatarCacheService().urlFor(
      uid: assigneeUid,
      phone: assigneePhone,
      name: task.assignedTo,
    );
    assigneeAvatarUrl ??= task.assignedTo.toLowerCase() == 'me'
        ? _assigneeAvatarUrl
        : null;

    // Compute creator display name for From/To line
    final bool createdByLooksLikeUid =
        task.createdBy.length >= 20 &&
        !task.createdBy.contains(' ') &&
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(task.createdBy);
    final creatorName =
        task.createdByName?.isNotEmpty == true &&
            task.createdByName!.toLowerCase() != 'user'
        ? task.createdByName!
        : (createdByLooksLikeUid ? 'Someone' : task.createdBy);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card header
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  AppAvatar(
                    avatarUrl: assigneeAvatarUrl,
                    initials: displayInitials,
                    radius: 24,
                    color: accentColor,
                    fontSize: 17,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1: urgent flag + title + deadline pill on the
                        // same row, so the pill never squeezes the name line.
                        Row(
                          children: [
                            if (task.isUrgent) ...[
                              const Icon(
                                Icons.flag,
                                size: 14,
                                color: AppTheme.mutedRed,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                task.title,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DeadlineChip(data: deadlineData),
                          ],
                        ),
                        // Line 2: From → To
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              creatorName,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.secondaryText,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward,
                              size: 10,
                              color: AppTheme.lightText,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                task.assignedTo,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: accentColor,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // Compact action rows
          ...(expanded ? sortedActions : sortedActions.take(3)).map(
            (action) => _buildCompactActionRow(
              action,
              task,
              action.seqNo ?? (actionNumbers[action] ?? 1),
            ),
          ),
          if (sortedActions.length > 3)
            InkWell(
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedActionCards.remove(task.id);
                  } else {
                    _expandedActionCards.add(task.id);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: AppTheme.headerGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        expanded
                            ? 'Show less'
                            : '+${sortedActions.length - 3} more actions',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.headerGreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Compact action row (matching Main Actions tab UI)
  // ⚠️ Icon chain parses ActionType + message text — a type missing here
  // falls to the generic Reminder bell (this was the cash icon bug). Keep in
  // sync with the twin chain in task_actions_screen.dart and the checklist
  // at task_detail_screen.dart _getActionMessages.
  Widget _buildCompactActionRow(ActionItem action, TaskModel task, int number) {
    final lower = action.message.toLowerCase();
    final isWarning = lower.startsWith('warning') || lower.contains('warning');
    final isFollowup =
        lower.contains('follow-up') ||
        lower.contains('followup') ||
        lower.contains('follow up');
    final isQuery =
        action.type == ActionType.query ||
        lower.startsWith('query') ||
        lower.contains('status request');
    final isStatus = lower.startsWith('status report');

    IconData icon;
    Color iconColor;
    String label; // ignore: unused_local_variable
    if (isWarning) {
      icon = Icons.warning_amber_rounded;
      iconColor = const Color(0xFFE03131);
      label = 'Warning';
    } else if (isQuery) {
      icon = Icons.summarize;
      iconColor = action.isReplied
          ? const Color(0xFF2F9E44)
          : const Color(0xFF1976D2);
      label = action.isReplied ? 'Query - Replied' : 'Query';
    } else if (isStatus) {
      icon = Icons.summarize;
      iconColor = const Color(0xFF2F9E44);
      label = 'Status Report';
    } else if (isFollowup) {
      icon = Icons.event_repeat;
      iconColor = action.isFollowUpDone
          ? const Color(0xFF2F9E44)
          : const Color(0xFF1976D2);
      label = action.isFollowUpDone ? 'Follow-up - Done' : 'Follow-up';
    } else if (action.type == ActionType.blocker) {
      icon = Icons.block;
      iconColor = action.isFollowUpDone
          ? const Color(0xFF2F9E44)
          : const Color(0xFFC92A2A);
      label = action.isFollowUpDone ? 'Blocker - Resolved' : 'Blocker';
    } else if (action.type == ActionType.approval) {
      icon = Icons.fact_check;
      iconColor = action.isReplied
          ? const Color(0xFF2F9E44)
          : const Color(0xFF0B7285);
      label = action.isReplied ? 'Request - Actioned' : 'Request Action';
    } else if (action.type == ActionType.extension) {
      icon = Icons.more_time;
      iconColor = action.isReplied
          ? const Color(0xFF2F9E44)
          : const Color(0xFF3B5BDB);
      label = action.isReplied ? 'Extension - Actioned' : 'Extension Requested';
    } else if (action.type == ActionType.progressReport) {
      icon = Icons.trending_up;
      iconColor = const Color(0xFF7048E8);
      label = 'Progress Report';
    } else if (action.message.contains('💳') || lower.startsWith('payment')) {
      // 💳 receivable card (Cash/Payment dialog) — checked before the wallet
      // catch since payment rows carry ActionType.cash.
      icon = Icons.payments;
      iconColor = const Color(0xFF7048E8);
      final payFirstLine = action.message.split('\n').first;
      label = payFirstLine.contains('Due')
          ? 'Payment - Due'
          : payFirstLine.contains('Collected')
          ? 'Payment - Collected'
          : 'Payment';
    } else if (action.type == ActionType.cash ||
        action.message.contains('💵') ||
        lower.startsWith('cash')) {
      icon = Icons.account_balance_wallet;
      iconColor = const Color(0xFF099268);
      if (action.message.contains('Cash Added')) {
        label = 'Cash Added';
      } else if (action.message.contains('Cash Expense')) {
        label = 'Cash Expense';
      } else if (action.message.contains('Cash Refund')) {
        label = 'Cash Refund';
      } else if (action.message.contains('Cash Settled')) {
        label = 'Cash Settled';
      } else {
        label = 'Cash';
      }
    } else if (action.type == ActionType.call) {
      icon = Icons.call;
      iconColor = const Color(0xFF0C8599);
      label = action.isFollowUpDone ? 'Call - Done' : 'Call';
    } else if (action.type == ActionType.meeting) {
      icon = Icons.groups;
      iconColor = const Color(0xFF3B5BDB);
      label = action.isFollowUpDone ? 'Meeting - Done' : 'Meeting';
    } else if (action.type == ActionType.siteVisit) {
      icon = Icons.handyman;
      iconColor = const Color(0xFF1098AD);
      label = action.isFollowUpDone ? 'Visit - Done' : 'Visit';
    } else {
      icon = Icons.notifications_active;
      iconColor = const Color(0xFFF59F00);
      label = 'Reminder';
      final qm = RegExp(r'"([^"]+)"').firstMatch(action.message);
      if (qm != null) label = 'Reminder "${qm.group(1)!}"';
    }

    final timeStr = _formatActionDateTime(action.scheduledDate);
    final dateColor = _getScheduledDateColor(action.scheduledDate);

    // One-line description: "Query Replied#1 | <summary>" + date badge.
    final detail = CardActionIcons.compactDetail(
      action.message,
      typeName: action.type.name,
    );
    final closed = action.isReplied || action.isFollowUpDone;
    final base = CardActionIcons.actionBaseLabel(
      typeName: action.type.name,
      message: action.message,
    );
    final statusWord = closed
        ? const {
                'query': ' Replied',
                'followUp': ' Done',
                'extension': '',
                'approval': ' Actioned',
                'blocker': ' Resolved',
                'call': ' Done',
                'meeting': ' Done',
                'siteVisit': ' Done',
              }[action.type.name] ??
              ''
        : '';
    final lineText = detail.isNotEmpty
        ? '$base$statusWord $number | $detail'
        : '$base$statusWord $number';

    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TaskDetailScreen(task: task, scrollToMessageId: action.messageId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Done/replied actions keep their icon + ✓ badge
            CardActionIcons.withDoneBadge(
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 13, color: iconColor),
              ),
              done: action.isReplied || action.isFollowUpDone,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                lineText,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.primaryText,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: dateColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                timeStr,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: dateColor,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: AppTheme.lightText),
          ],
        ),
      ),
    );
  }

  String _formatActionDateTime(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(dateDay).inDays;
    if (diff < 0) return '${-diff}d left'; // scheduled in the future
    if (diff == 0) return DateFormat('h:mm a').format(date);
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return '${diff}d ago';
    return DateFormat('MMM d').format(date);
  }

  Color _getScheduledDateColor(DateTime date) {
    return AppTheme.lightText;
  }

  // ── Filter menu bottom sheet ──────────────────────────────────────────────

  /// Export the currently displayed tasks
  void _exportCurrentView() {
    final tasks = _displayedTasks;
    if (tasks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No tasks to export')));
      return;
    }

    final headers = [
      '#',
      'Title',
      'Status',
      'Priority',
      'Created By',
      'Assigned To',
      'Deadline',
      'Progress',
      'Created',
      'Last Activity',
    ];
    final rows = tasks.map((task) {
      final status = task.isClosed
          ? 'Completed'
          : task.isCancelled
          ? 'Cancelled'
          : 'Active';
      final priority = task.priority == 3
          ? 'High'
          : task.priority == 2
          ? 'Medium'
          : 'Low';
      final progress = '${(task.progress * 100).toInt()}%';
      final deadline = task.deadline != null
          ? DateFormat('dd/MM/yyyy').format(task.deadline!)
          : '';
      final created = DateFormat('dd/MM/yyyy').format(task.createdAt);
      final lastActivity = task.lastMessageTime != null
          ? DateFormat('dd/MM/yyyy').format(task.lastMessageTime!)
          : '';
      return [
        task.displayId?.toString() ?? '',
        task.title,
        status,
        priority,
        task.createdByName ?? '',
        task.assignedTo,
        deadline,
        progress,
        created,
        lastActivity,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Assignee Tasks',
      filterLabel: _statusFilter == 'All'
          ? 'All'
          : (_statusFilter == 'Unassigned' ? 'Assign later' : _statusFilter),
    );
  }

  /// Export the currently visible action items (Actions tab)
  void _exportActions() {
    final planType = context.read<AuthProvider>().effectivePlanType;
    if (!PaywallLimits.canExport(planType)) {
      showPaywallDialog(
        context,
        feature: 'Export is a Premium feature.',
        detail: 'Upgrade to Premium to export actions to CSV, Excel and PDF.',
      );
      return;
    }

    final items = List<ActionItem>.from(_currentActionItems);
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No actions to export')));
      return;
    }

    String typeLabel(ActionItem a) {
      switch (a.type) {
        case ActionType.reminder:
          return 'Reminder';
        case ActionType.followUp:
          return a.isFollowUpDone ? 'Follow-up (Done)' : 'Follow-up';
        case ActionType.warning:
          return 'Warning';
        case ActionType.query:
          return a.isReplied ? 'Query (Replied)' : 'Query';
        case ActionType.blocker:
          return a.isFollowUpDone ? 'Blocker (Resolved)' : 'Blocker';
        case ActionType.approval:
          return a.isReplied ? 'Request - Actioned' : 'Request Action';
        case ActionType.extension:
          return a.isReplied ? 'Extension (Actioned)' : 'Extension Request';
        case ActionType.progressReport:
          return 'Progress Report';
        case ActionType.cash:
          return 'Cash';
        case ActionType.call:
          return a.isFollowUpDone ? 'Call (Done)' : 'Call';
        case ActionType.meeting:
          return a.isFollowUpDone ? 'Meeting (Done)' : 'Meeting';
        case ActionType.siteVisit:
          return a.isFollowUpDone ? 'Visit (Done)' : 'Visit';
      }
    }

    final headers = [
      '#',
      'Type',
      'Task',
      'Detail',
      'Scheduled',
      'Created By',
      'Assigned To',
      'Status',
    ];
    final df = DateFormat('dd/MM/yyyy hh:mm a');
    var i = 1;
    final rows = items.map((a) {
      final status = a.type == ActionType.query
          ? (a.isReplied ? 'Replied' : 'Pending')
          : a.type == ActionType.followUp
          ? (a.isFollowUpDone ? 'Done' : 'Pending')
          : (a.isCompleted ? 'Done' : 'Pending');
      return [
        '${i++}',
        typeLabel(a),
        a.taskTitle,
        a.message,
        df.format(a.scheduledDate),
        a.createdBy,
        a.assignedTo,
        status,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Assignee Actions',
      filterLabel: _typeFilter != null
          ? '$_timeFilter / ${ModuleConfig.task.actionFor(_typeFilter!)?.label ?? _typeFilter!}'
          : _timeFilter,
    );
  }

  void _showFilterMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.filter_list,
                        color: AppTheme.headerGreen,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'FILTER & SORT',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // ── STATUS FILTER SECTION ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        color: AppTheme.headerGreen,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'VIEW TASKS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'All Tasks',
                  Icons.folder_outlined,
                  'Show all tasks',
                  'All',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Active',
                  Icons.play_circle_outline,
                  'In progress',
                  'Active',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Scheduled',
                  Icons.calendar_today,
                  'Future scheduled',
                  'Scheduled',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Completed',
                  Icons.check_circle_outline,
                  'Done tasks',
                  'Completed',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Cancelled',
                  Icons.cancel_outlined,
                  'Cancelled tasks',
                  'Cancelled',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Blocked',
                  Icons.block,
                  'Open blocker raised',
                  'Blocked',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Deleted',
                  Icons.delete_outline,
                  'Restorable for 30 days',
                  'Deleted',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Overdue',
                  Icons.warning_amber_rounded,
                  'Past deadline',
                  'Overdue',
                ),
                _filterOption(
                  ctx,
                  setSheetState,
                  'Urgent',
                  Icons.local_fire_department,
                  'Marked urgent',
                  'Urgent',
                ),

                const Divider(height: 1, indent: 16, endIndent: 16),

                // ── SORT SECTION ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      Icon(Icons.sort, color: AppTheme.headerGreen, size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'SORT BY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Last Action',
                  Icons.update,
                  'Most recent first',
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Due Date',
                  Icons.calendar_today,
                  'Earliest deadline first',
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Priority',
                  Icons.star,
                  'Highest first',
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Created',
                  Icons.access_time,
                  'Newest first',
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Name',
                  Icons.sort_by_alpha,
                  'Alphabetical',
                ),
                _sortOption(
                  ctx,
                  setSheetState,
                  'Progress',
                  Icons.trending_up,
                  'Lowest first',
                ),

                const Divider(height: 1, indent: 16, endIndent: 16),

                // ── EXPORT SECTION ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.download_outlined,
                        color: AppTheme.headerGreen,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'EXPORT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(
                    horizontal: 0,
                    vertical: -2,
                  ),
                  leading: const Icon(
                    Icons.download_outlined,
                    size: 18,
                    color: AppTheme.headerGreen,
                  ),
                  title: const Text(
                    'Export Current View',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  subtitle: Text(
                    PaywallLimits.canExport(
                          context.read<AuthProvider>().effectivePlanType,
                        )
                        ? 'CSV / Excel / PDF'
                        : 'Premium feature',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.lightText,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    final planType = context
                        .read<AuthProvider>()
                        .effectivePlanType;
                    if (!PaywallLimits.canExport(planType)) {
                      showPaywallDialog(
                        context,
                        feature: 'Export is a Premium feature.',
                        detail:
                            'Upgrade to Premium to export tasks to CSV, Excel and PDF.',
                      );
                      return;
                    }
                    _exportCurrentView();
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterOption(
    BuildContext ctx,
    StateSetter setSheetState,
    String label,
    IconData icon,
    String subtitle,
    String value,
  ) {
    final isSelected = _statusFilter == value;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? AppTheme.headerGreen : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? AppTheme.headerGreen : AppTheme.primaryText,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 10, color: AppTheme.lightText),
      ),
      trailing: isSelected
          ? const Icon(
              Icons.check_circle,
              size: 16,
              color: AppTheme.headerGreen,
            )
          : null,
      onTap: () {
        setState(() => _statusFilter = value);
        Navigator.pop(ctx);
      },
    );
  }

  Widget _sortOption(
    BuildContext ctx,
    StateSetter setSheetState,
    String label,
    IconData icon,
    String subtitle,
  ) {
    final isSelected = _sortBy == label;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: Icon(
        icon,
        size: 18,
        color: isSelected ? AppTheme.headerGreen : AppTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected ? AppTheme.headerGreen : AppTheme.primaryText,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 10, color: AppTheme.lightText),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, size: 16, color: AppTheme.headerGreen)
          : null,
      onTap: () {
        setState(() => _sortBy = label);
        Navigator.pop(ctx);
      },
    );
  }

  // ── Create new task ─────────────────────────────────────────────────────

  Future<void> _createNewTask() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.userModel;
    if (user == null) return;

    // Check if user has a valid name
    final userName = user.name;
    if (userName.isEmpty || userName == 'User') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please set your name first in settings'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Use the current assignee as the default assignee for the new task.
    // Take identity only from a task where this person is the PRIMARY
    // assignee with a UID that isn't the current user's (legacy corruption
    // stored the creator's UID in assignee fields).
    final assigneeName = _resolvedAssignee;
    final aliases = _aliasesFor(assigneeName);
    String assigneePhone = '';
    String? assigneeUid;
    for (final t in _allTasks) {
      if (!aliases.contains(t.assignedTo.trim().toLowerCase())) continue;
      final uid = t.assignedToUid ?? '';
      if (assigneeUid == null &&
          uid.isNotEmpty &&
          uid != user.uid &&
          uid != t.createdBy) {
        assigneeUid = uid;
      }
      if (assigneePhone.isEmpty) {
        assigneePhone = t.assignedToPhone?.trim() ?? '';
      }
      if (assigneeUid != null && assigneePhone.isNotEmpty) break;
    }

    // Fallback: resolve identity from the in-app user directory (same source
    // the contact picker uses). The task-history scan above misses assignees
    // whose older tasks predate UID stamping or used a different name
    // variant -- without a UID/phone the task would never be delivered to
    // the assignee's device.
    if (assigneeUid == null) {
      try {
        final members = await ContactPickerService().getTeamMembers();
        final lower = assigneeName.trim().toLowerCase();
        for (final m in members) {
          if ((m.uid ?? '').isEmpty) continue;
          if (m.name.trim().toLowerCase() != lower) continue;
          assigneeUid = m.uid;
          if (assigneePhone.isEmpty) {
            assigneePhone = Helpers.normalizePhone(m.phone) ?? (m.phone ?? '');
          }
          break;
        }
      } catch (e) {
        print('[AssigneeTasks] Directory assignee resolution failed: $e');
      }
    }

    final taskProvider = context.read<TaskProvider>();
    final scaffoldTask = TaskModel(
      id: '',
      title: '',
      description: '',
      createdBy: user.uid,
      createdByName: user.name,
      createdByPhone: user.phone,
      assignedTo: assigneeName,
      assignedToUid: assigneeUid,
      assignedToPhone: assigneePhone.isNotEmpty
          ? (Helpers.normalizePhone(assigneePhone) ?? assigneePhone)
          : '',
      participants: [
        user.uid,
        if (assigneeUid != null && assigneeUid.isNotEmpty) assigneeUid,
      ],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      extraFields: {'isDraft': true},
    );

    try {
      final realId = await taskProvider.createTask(
        scaffoldTask,
        planType: authProvider.effectivePlanTypeFor('task'),
      );
      if (realId == null) throw Exception('Failed to create task');
      // Reload from SQLite so the detail screen sees applied default
      // milestones / team stamp.
      final realTask = await taskProvider.persistedTask(scaffoldTask, realId);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TaskDetailScreen(task: realTask),
        ),
      );
    } on PlanLimitException catch (e) {
      if (!mounted) return;
      await showPaywallDialog(context, feature: e.feature, detail: e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to create task: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
