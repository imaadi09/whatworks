import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/enquiry.dart';
import '../providers/sales_provider.dart';
import '../widgets/sales_card.dart';
import '../../../providers/auth_provider.dart';
import '../../../utils/constants.dart';
import '../../../utils/helpers.dart';
import '../../../utils/export_service.dart';
import '../../../utils/paywall_constants.dart';
import '../../../services/local_database_service.dart';
import '../../../services/firebase_service.dart';
import '../../../services/avatar_cache_service.dart';
import '../../../services/contact_picker_service.dart';
import '../../../widgets/card_action_icons.dart';
import '../../../widgets/actions_filter_ui.dart';
import '../../../widgets/app_avatar.dart';
import '../../../widgets/visibility_gated_tab.dart';
import 'sales_detail_screen.dart';
import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../../crm/providers/crm_provider.dart';

/// Screen showing all sales enquiries for a specific person (as creator or assignee).
/// Opened from Sales Detail AppBar tick button, or embedded as the home
/// ASSIGNEE tab (embedded: true — no Scaffold/AppBar, defaults to the last
/// message sender).
class AssigneeSalesScreen extends StatefulWidget {
  final String personName; // The person whose sales we're viewing
  final String otherPersonName; // The other party (creator or assignee)
  final ModuleConfig moduleConfig;
  final bool embedded; // Rendered inside another Scaffold (home ASSIGNEE tab)

  /// WhatsApp-style selection hooks from the embedding home screen (mirrors
  /// AssigneeTasksScreen): long-press enters selection mode, taps toggle.
  final bool selectionMode;
  final Set<String> selectedEnquiryIds;
  final void Function(EnquiryModel enquiry)? onLongPressEnquiry;
  final void Function(EnquiryModel enquiry)? onToggleSelection;

  /// Whether this tab is the currently-visible one. The home [IndexedStack]
  /// keeps every visited tab mounted, so a hidden tab must NOT re-run its
  /// expensive enquiries scan on every sync notification — that is what froze
  /// the UI when several tabs were alive at once. A hidden tab only flags
  /// [_AssigneeSalesScreenState._pendingRefresh] and catches up once on becoming
  /// visible again. Defaults to true so a full-screen push always stays live.
  final bool isActive;

  const AssigneeSalesScreen({
    super.key,
    this.personName = '',
    this.otherPersonName = '',
    required this.moduleConfig,
    this.embedded = false,
    this.selectionMode = false,
    this.selectedEnquiryIds = const {},
    this.onLongPressEnquiry,
    this.onToggleSelection,
    this.isActive = true,
  });

  @override
  State<AssigneeSalesScreen> createState() => _AssigneeSalesScreenState();
}

class _AssigneeSalesScreenState extends State<AssigneeSalesScreen>
    with SingleTickerProviderStateMixin, VisibilityGatedTabState {
  ModuleConfig get _config => widget.moduleConfig;
  bool get _isCrm => _config.type == ModuleType.crm;
  BaseModuleProvider _readProvider(BuildContext ctx) =>
      _isCrm ? ctx.read<CrmProvider>() : ctx.read<SalesProvider>();
  Color get _themeColor => _config.themeColor;
  late TabController _tabController;
  List<EnquiryModel> _allEnquiries = [];
  List<EnquiryModel> _filteredEnquiries = [];
  /// Person-scoped, VIEW-filter–unapplied list the summary strip tallies
  /// (Task-module parity: `_allTasks`). `_filteredEnquiries` carries the
  /// shared VIEW filter on top and `_allEnquiries` is the whole team, so
  /// neither is the right basis for a per-person strip that reports archived
  /// separately.
  List<EnquiryModel> _personEnquiries = [];

  /// Ids of enquiries where the selected person is on the ASSIGNEE side
  /// (the person filter also admits creator-side enquiries, but the
  /// Archived stat must count only what this person owns as assignee).
  final Set<String> _personAsAssigneeIds = {};
  String _resolvedPerson = '';
  String _resolvedOther = '';

  /// Sentinel "person" in the Select Assignee picker: views every card the
  /// current user created that is still unassigned (mirrors the 'Unassigned'
  /// VIEW filter set, reachable as a picker entry too).
  static const String _unassignedPerson = 'Unassigned';
  bool get _isUnassignedView =>
      _resolvedPerson.toLowerCase() == _unassignedPerson.toLowerCase();

  /// Pinned "Me" entry at the top of the picker — views every card the
  /// current user touches (as creator or assignee). The user's own name is
  /// stripped from the letter list below so it can never appear twice
  /// (parity with the Task module's assignee picker).
  static const String _mePerson = 'Me';
  bool get _isMeView =>
      _resolvedPerson.toLowerCase() == _mePerson.toLowerCase();
  bool _isLoading = true;
  String _selectedTab = 'sales';
  bool _autoPickerShown = false;

  // Precomputed picker index (people → enquiry counts) so the assignee
  // picker opens instantly instead of scanning all enquiries on tap.
  // Keys are the canonical (merged) person key — the same person can appear
  // under several names across enquiries, so identities are clustered by
  // shared UID/phone (same approach as the task module).
  final Map<String, int> _pickerCounts = {};
  final Map<String, String> _pickerDisplay = {};
  // canonical key → every name variant (lowercase) merged into that person
  final Map<String, Set<String>> _pickerAliases = {};
  // canonical key → UIDs / normalized phones owned by that merged person
  final Map<String, Set<String>> _pickerUids = {};
  final Map<String, Set<String>> _pickerPhones = {};
  // Per-person status stats shown under the name in the picker sheet
  final Map<String, int> _pickerActive = {};
  final Map<String, int> _pickerOverdue = {};
  final Map<String, DateTime> _pickerLastSeen = {};
  List<String> _pickerKeys = [];
  // Picker sheet sort mode, persisted so the app remembers the choice.
  String _pickerSortMode = 'name'; // 'name' | 'tasks' | 'recent'
  static const String _pickerSortPrefKey = 'assignee_picker_sort_mode';
  // Remembers the last person chosen in the Select Assignee picker, per module,
  // so the embedded Sales/CRM tab reopens on that person instead of popping the
  // picker sheet on every entry.
  String get _lastPersonPrefKey =>
      _isCrm ? 'assignee_crm_last_person' : 'assignee_sales_last_person';
  // Attention mode (header toggle): cards show PENDING actions and
  // enquiries needing attention float to the top. The bell also selects the
  // 'Needs Attention' time chip on the Actions tab, so one toggle narrows
  // both lists. Session-only: it clears with a second bell tap.
  bool _attentionMode = false;
  final Set<String> _expandedEnquiryCards = {};

  // Visibility gating (see [VisibilityGatedTabState]): a hidden tab defers its
  // full-scan reload and catches up once when shown again.
  @override
  bool get isActiveTab => widget.isActive;
  @override
  void onTabBecameActive() {
    if (_resolvedPerson.isNotEmpty) _filterEnquiries();
  }

  // Re-apply the shared 3-dot VIEW/SORT when it changes in the provider.
  BaseModuleProvider? _listenedProvider;
  String _appliedStatusFilter = 'All';
  String _appliedSortBy = 'Last Action';
  // Cheap fingerprint of the provider's enquiry set, so [_onProviderChanged]
  // re-filters only when an enquiry actually moved (add/remove or a reply /
  // status edit bumping updatedAt) — not on unread-count / action-icon notifies.
  int _appliedItemsSig = 0;
  // The enquiry-signature gate above deliberately ignores action-icon-only
  // notifies to avoid re-decoding every card — but that also dropped the LATE
  // icon-cache refresh (backfill / message-recovery / sync landing after the
  // initial preload), leaving cards stuck with no chips while the Actions tab
  // (a live stream on the actions table) showed them. Watch the provider's
  // [actionIconsVersion] counter so an actual chip-strip change rebuilds the
  // list, without un-gating the no-op notifies.
  int _appliedIconsVersion = 0;

  // Actions tab — lean two-axis filter: a time-chip row plus an optional
  // action-type override (value == the _ActionItem.type string). No counts,
  // no date picker, no extra toggles.
  String _timeFilter = kActionTimeToday;
  String? _typeFilter;

  // Time chips (axis 1) and action-type sheet entries (axis 2).
  static const _timeOptions = kActionTimeOptions;
  // Derive the Type filter from THIS module's action catalog (Sales or CRM via
  // _config) so each module lists only its own actions with canonical labels —
  // CRM's 'quotation' reads 'Estimate', and neither surface leaks the other's
  // types or the never-creatable generic types (blocker/extension/progress).
  // Sales/CRM rows store `followup` but expose it as `followUp` in their action
  // row mapping, so map the value to match the type-axis comparison.
  List<ActionFilterOption> get _typeOptions => actionTypeFilterOptions(
    _config.actionTypes,
    valueFor: (k) => k == 'followup' ? 'followUp' : k,
  );

  @override
  void initState() {
    super.initState();
    _resolvedPerson = widget.personName;
    _resolvedOther = widget.otherPersonName;
    _tabController = TabController(length: 2, vsync: this);
    _loadPickerSortPref();
    _tabController.addListener(() {
      setState(() {
        _selectedTab = _tabController.index == 0 ? 'sales' : 'actions';
      });
    });
    if (widget.embedded && _resolvedPerson.isEmpty) {
      _initDefaultPerson();
    } else {
      _filterEnquiries();
    }
    // Live reload: re-filter when the provider's enquiry data or the home
    // screen's 3-dot VIEW/SORT changes. The provider (via the shared
    // ChangeSetConsumer) already coalesces sync / recovery write bursts and
    // patches only the changed rows in memory — listening to IT instead of
    // re-reading the whole enquiries table on every raw tableChanges2 event is
    // what stops the assignee tab from decoding the table on each write (the
    // 12s/15s identity-repair + message-recovery sweeps froze the UI that way).
    _listenedProvider = _readProvider(context);
    _appliedStatusFilter = _listenedProvider!.statusFilter;
    _appliedSortBy = _listenedProvider!.sortBy;
    _appliedItemsSig = _itemsSignature(_listenedProvider!);
    _appliedIconsVersion = _listenedProvider!.actionIconsVersion;
    _listenedProvider!.addListener(_onProviderChanged);

    // Repaint the header the instant the shared avatar index fills (cold-start
    // race with the contact sync) — same mechanism the cards use, so a missed
    // first lookup is corrected rather than negative-cached as "no photo".
    AvatarCacheService().addListener(_onAvatarCacheChanged);
  }

  /// Repaint when the avatar index resolves this person's photo.
  void _onAvatarCacheChanged() {
    if (!mounted || _isMeView || _resolvedPerson.isEmpty) return;
    final canonical = _canonicalKeyFor(_resolvedPerson.toLowerCase());
    final uids = _pickerUids[canonical] ?? const <String>{};
    final phones = _pickerPhones[canonical] ?? const <String>{};
    final next = AvatarCacheService().urlFor(
      uid: uids.isEmpty ? null : uids.first,
      phone: phones.isEmpty ? null : phones.first,
      name: _resolvedPerson,
    );
    if (next != _personAvatarUrl) setState(() => _personAvatarUrl = next);
  }

  @override
  void dispose() {
    _listenedProvider?.removeListener(_onProviderChanged);
    AvatarCacheService().removeListener(_onAvatarCacheChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Cheap fingerprint of the provider's enquiry set: a rolling hash over each
  /// row's id + updatedAt. Recomputed on every provider notify (pure int math
  /// over already-decoded rows — no DB read), so [_onProviderChanged] can tell
  /// a real enquiry change (add/remove, a reply or status edit) apart from the
  /// many no-op notifies (unread counts, action icons) the provider also fires.
  int _itemsSignature(BaseModuleProvider p) {
    final list = p.enquiries;
    var sig = list.length;
    for (final e in list) {
      sig = Object.hash(sig, e.id, e.updatedAt.microsecondsSinceEpoch);
    }
    return sig;
  }

  /// The provider notifies for many reasons (sync, unread counts, action
  /// icons…). Re-filter only when the enquiry set actually moved or the 3-dot
  /// VIEW/SORT changed; a hidden tab defers and catches up on becoming active
  /// via [onTabBecameActive]. Cheap now that [_filterEnquiries] reads the
  /// provider's in-memory list instead of re-decoding the whole table.
  void _onProviderChanged() {
    final p = _listenedProvider;
    if (p == null || !mounted) return;
    final filtersChanged =
        p.statusFilter != _appliedStatusFilter || p.sortBy != _appliedSortBy;
    final iconsChanged = p.actionIconsVersion != _appliedIconsVersion;
    final sig = _itemsSignature(p);
    if (!filtersChanged && !iconsChanged && sig == _appliedItemsSig) return;
    _appliedStatusFilter = p.statusFilter;
    _appliedSortBy = p.sortBy;
    _appliedItemsSig = sig;
    _appliedIconsVersion = p.actionIconsVersion;
    if (isTabHidden) {
      deferRefresh();
      return;
    }
    if (widget.embedded && _resolvedPerson.isEmpty) {
      _initDefaultPerson();
    } else if (_resolvedPerson.isNotEmpty) {
      _filterEnquiries();
    }
  }

  Future<void> _filterEnquiries() async {
    final salesProvider = _readProvider(context);
    final authProvider = context.read<AuthProvider>();
    final userId = authProvider.userModel?.uid ?? '';

    // Render from the provider's in-memory list — already kept current by the
    // shared ChangeSetConsumer — instead of re-reading and decoding the whole
    // enquiries table here (the source of the sync-burst freeze). The provider
    // list is the current team, which also scopes this tab like the Task
    // assignee screen and the rest of the module (the old full-table read
    // leaked other teams' enquiries into this person view).
    final allEnquiries = List<EnquiryModel>.of(salesProvider.enquiries);
    _allEnquiries = allEnquiries;
    _rebuildPickerIndex(allEnquiries);
    if (!mounted) return;
    if (_resolvedPerson.isEmpty) {
      // No person selected yet (embedded mode) — just cache the list
      setState(() {
        _filteredEnquiries = [];
        _personEnquiries = [];
        _isLoading = false;
      });
      return;
    }

    // "Me" pinned person: everything I created or am assigned to. UID-based
    // so legacy docs with a missing/compressed name still match; the general
    // alias path below deliberately can't resolve my own UID (Task parity).
    if (_isMeView) {
      _personAsAssigneeIds.clear();
      final scoped = allEnquiries
          .where(
            (e) =>
                e.createdBy == userId ||
                e.assignedToUid == userId ||
                (e.extraFields?['assigneeUids'] is List &&
                    (e.extraFields!['assigneeUids'] as List).contains(userId)),
          )
          .toList();
      _personEnquiries = scoped;
      // Count once per person as assignee so the Archived stat stays honest.
      for (final e in scoped) {
        if (e.assignedToUid == userId ||
            (e.extraFields?['assigneeUids'] is List &&
                (e.extraFields!['assigneeUids'] as List).contains(userId))) {
          _personAsAssigneeIds.add(e.id);
        }
      }
      setState(() {
        _filteredEnquiries = salesProvider.applyFiltersTo(scoped);
        _isLoading = false;
      });
      unawaited(_resolvePersonProfile());
      return;
    }

    // "Unassigned" sentinel person: my own cards still waiting for an
    // assignee — same predicate as the provider's 'Unassigned' filter.
    // The shared VIEW filter/sort still applies on top of the set.
    if (_isUnassignedView) {
      _personAsAssigneeIds.clear();
      final scoped = allEnquiries
          .where((e) => e.createdBy == userId && e.assignedTo.isEmpty)
          .toList();
      _personEnquiries = scoped;
      setState(() {
        _filteredEnquiries = salesProvider.applyFiltersTo(scoped);
        _isLoading = false;
      });
      unawaited(_resolvePersonProfile());
      return;
    }
    final personLower = _resolvedPerson.toLowerCase();

    // Show enquiries where personName is either creator or assignee (including multi-assignee)
    _personAsAssigneeIds.clear();
    final filtered = _personScoped(allEnquiries, personLower);
    _personEnquiries = filtered;

    // Apply the shared 3-dot VIEW filter + SORT (held in the provider) so
    // this tab honors the same menu selections as My Enquiries. Default
    // sort ('Last Action') matches the previous hard-coded last-activity
    // ordering, so behavior is unchanged until a filter is picked.
    final visible = salesProvider.applyFiltersTo(filtered);

    setState(() {
      _filteredEnquiries = visible;
      _isLoading = false;
    });
    unawaited(_resolvePersonProfile());
  }

  /// Profile photo and designation of the selected person, shown in the header
  /// (Task-module parity — the tracker resolves both through one chain).
  /// The photo has a SINGLE source like the cards: [AvatarCacheService] plus
  /// the same listener, so it paints the instant the index fills — there is no
  /// parallel header cache that could negative-cache a cold-start miss and
  /// then keep showing initials after the cards got the photo. Designation
  /// isn't the avatar system's job, so its small session cache stays.
  String? _personDesignation;
  String? _personAvatarUrl;
  // Session cache keyed by person name (lowercase); a null VALUE means
  // "looked up, none found", so switching people never re-queries.
  static final Map<String, String?> _designationCache = {};

  /// Photo from the shared [AvatarCacheService] index (uid → phone → name,
  /// same trio the picker rows and cards use); designation from the small
  /// session cache → cached team members. The users doc is consulted only as
  /// a backfill and its result is written BACK into the shared index, so the
  /// header can never disagree with the cards. Phonebook photos are not used
  /// (contacts load withPhoto: false app-wide for performance).
  Future<void> _resolvePersonProfile() async {
    final name = _resolvedPerson;
    // "Me" view: my own photo/designation — the name-keyed caches below would
    // miss under the 'me' sentinel key and leave a stale other-person photo.
    if (_isMeView) {
      final me = context.read<AuthProvider>().userModel;
      if (!mounted) return;
      setState(() {
        _personAvatarUrl = me?.avatarUrl;
        _personDesignation = me?.designation;
      });
      return;
    }
    if (name.isEmpty) {
      if (mounted && (_personAvatarUrl != null || _personDesignation != null)) {
        setState(() {
          _personAvatarUrl = null;
          _personDesignation = null;
        });
      }
      return;
    }
    final key = name.toLowerCase();
    final canonical = _canonicalKeyFor(key);

    // Photo: the shared avatar index only, resolved with the full identity
    // trio (uid → phone → name) exactly like the picker rows and cards.
    final personUid = (_pickerUids[canonical] ?? const <String>{}).isEmpty
        ? null
        : _pickerUids[canonical]!.first;
    final personPhone = (_pickerPhones[canonical] ?? const <String>{}).isEmpty
        ? null
        : _pickerPhones[canonical]!.first;
    String? url = AvatarCacheService().urlFor(
      uid: personUid,
      phone: personPhone,
      name: name,
    );

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

    // Users doc by UID is a BACKFILL only, for the photo: a fetched photo is
    // written into the shared index (upsertUser repaints every consumer)
    // instead of a private map, so the header never diverges from the cards
    // and a cold-start miss is never negative-cached. Designation rides the
    // same fetch while still uncached. Offline simply resolves nothing — the
    // listener repaints on a later fill.
    if ((url == null || designation == null) && personUid != null) {
      try {
        final user = await FirebaseService().getUser(personUid);
        if (user != null) {
          if (url == null && (user.avatarUrl?.isNotEmpty ?? false)) {
            AvatarCacheService().upsertUser(
              uid: personUid,
              phone: personPhone,
              name: user.name,
              url: user.avatarUrl,
            );
            url = user.avatarUrl;
          }
          if (user.designation?.isNotEmpty ?? false) {
            designation = user.designation;
            _designationCache[key] = designation;
          }
        }
      } catch (_) {
        // Offline — nothing cached; a later cache fill or reload retries.
      }
    }

    if (!mounted || _resolvedPerson != name) return;
    if (url != _personAvatarUrl || designation != _personDesignation) {
      setState(() {
        _personAvatarUrl = url;
        _personDesignation = designation;
      });
    }
  }

  /// Enquiries where the person behind [personLower] is the creator or an
  /// assignee. Matches every merged identity of that person — all name
  /// aliases, UIDs and normalized phones — so enquiries filed under a
  /// different name variant of the same contact are included.
  List<EnquiryModel> _personScoped(List<EnquiryModel> src, String personLower) {
    final canonical = _canonicalKeyFor(personLower);
    final aliases = _pickerAliases[canonical] ?? {personLower};
    final uids = _pickerUids[canonical] ?? const <String>{};
    final phones = _pickerPhones[canonical] ?? const <String>{};

    bool matchesName(String? raw) {
      final n = raw?.trim().toLowerCase() ?? '';
      return n.isNotEmpty && aliases.contains(n);
    }

    bool matchesUid(String? raw) {
      final u = raw ?? '';
      // Legacy rows stored a UID in the name slot, so keep the direct compare
      return u.isNotEmpty &&
          (uids.contains(u) || u.toLowerCase() == personLower);
    }

    bool matchesPhone(String? raw) {
      final p = Helpers.normalizePhone(raw) ?? '';
      return p.isNotEmpty && phones.contains(p);
    }

    return src.where((e) {
      final isCreator =
          matchesName(e.createdByName) ||
          matchesUid(e.createdBy) ||
          matchesPhone(e.createdByPhone);
      final isAssignee =
          matchesName(e.assignedTo) ||
          matchesUid(e.assignedToUid) ||
          matchesPhone(e.assignedToPhone) ||
          e.assigneeNames.any(matchesName) ||
          e.assigneeUids.any(matchesUid) ||
          e.assigneePhones.any(matchesPhone);
      if (isAssignee) _personAsAssigneeIds.add(e.id);
      return isCreator || isAssignee;
    }).toList();
  }

  /// The canonical (merged) picker key for any name variant of a person.
  String _canonicalKeyFor(String name) {
    final lower = name.trim().toLowerCase();
    for (final entry in _pickerAliases.entries) {
      if (entry.value.contains(lower)) return entry.key;
    }
    return lower;
  }

  /// True when the picker person `key` resolves to the current user (their
  /// merged cluster carries my UID or normalized phone). Used to strip my
  /// own row from the letter list — the pinned 'Me' entry above it is the
  /// selection affordance instead (Task module parity).
  bool _pickerOwns(String key, String myUid, Set<String> myPhones) {
    final c = _canonicalKeyFor(key);
    if (myUid.isNotEmpty &&
        (_pickerUids[c] ?? const <String>{}).contains(myUid)) {
      return true;
    }
    final phones = _pickerPhones[c] ?? const <String>{};
    return phones.intersection(myPhones).isNotEmpty;
  }

  bool _looksLikeUid(String s) =>
      s.length >= 20 &&
      !s.contains(' ') &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

  /// Embedded mode: default to the sender of the most recent message;
  /// if unresolvable, open the searchable picker instead.
  Future<void> _initDefaultPerson() async {
    final uid = context.read<AuthProvider>().userModel?.uid ?? '';
    // Land back on the person last chosen in the picker (per module) so
    // re-entering the Sales/CRM tab shows their cards instead of popping the
    // Select Assignee sheet. Only when nothing was remembered yet do we fall
    // back to the last message sender, and only if that too is absent does the
    // picker auto-open below.
    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(_lastPersonPrefKey) ?? '';
    if (remembered.isNotEmpty) {
      _resolvedPerson = remembered;
    } else {
      final name = await LocalDatabaseService().getLastMessageSenderName(
        parentType: _isCrm ? 'crm' : 'sales',
        excludeUid: uid,
      );
      if (name != null && name.isNotEmpty) {
        _resolvedPerson = name;
      }
    }
    if (!mounted) return;
    await _filterEnquiries();
    if (!mounted) return;
    if (_resolvedPerson.isEmpty && !_autoPickerShown) {
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

  /// Switch the viewed person and refresh both tabs.
  void _selectPerson(String name) {
    if (name.toLowerCase() == _resolvedPerson.toLowerCase()) return;
    setState(() {
      _resolvedPerson = name;
      _resolvedOther = name.toLowerCase() == widget.personName.toLowerCase()
          ? widget.otherPersonName
          : '';
      // Drop the previous person's header photo/designation — the async
      // resolver would otherwise paint the old person's face under the new
      // name until it lands (Task-module parity).
      _personAvatarUrl = null;
      _personDesignation = null;
      _isLoading = true;
    });
    // Remember this pick so the tab reopens on the same person next time
    // instead of showing the Select Assignee picker.
    SharedPreferences.getInstance().then(
      (p) => p.setString(_lastPersonPrefKey, name),
    );
    _filterEnquiries();
  }

  /// Single pass over [source] building the picker's people/count index.
  /// Runs during enquiry load (off the sheet-open path) so the picker is
  /// instant regardless of how many enquiries or users exist.
  ///
  /// The same person can appear under different names across enquiries (the
  /// creator's contact-book name vs their app profile name), so names are
  /// clustered by shared UID/phone and merged into a single entry.
  void _rebuildPickerIndex(List<EnquiryModel> source) {
    _pickerCounts.clear();
    _pickerDisplay.clear();
    _pickerAliases.clear();
    _pickerUids.clear();
    _pickerPhones.clear();
    _pickerActive.clear();
    _pickerOverdue.clear();
    _pickerLastSeen.clear();

    final myUid = context.read<AuthProvider>().userModel?.uid ?? '';

    // Per-name identity gathered from every enquiry mention.
    final display = <String, String>{};
    final nameUids = <String, Set<String>>{};
    final namePhones = <String, Set<String>>{};
    // How often the current user assigned enquiries under this name — the name
    // the user picked from their own contacts wins as the display name.
    final pickedByMe = <String, int>{};
    // People mentioned per enquiry (for counting each once per merged person)
    final enquiryPeople = <Set<String>>[];

    for (final e in source) {
      final people = <String>{};
      void note(
        String? rawName, {
        String? uid,
        String? phone,
        bool assigneeOnMyEnquiry = false,
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
        if (assigneeOnMyEnquiry) pickedByMe[key] = (pickedByMe[key] ?? 0) + 1;
      }

      final mine = myUid.isNotEmpty && e.createdBy == myUid;
      final creatorNameLower = (e.createdByName ?? '').trim().toLowerCase();
      note(e.createdByName, uid: e.createdBy, phone: e.createdByPhone);

      final assigneeNames = e.extraFields?['assigneeNames'];
      final isMulti = assigneeNames is List && assigneeNames.length > 1;
      if (!isMulti) {
        // Single assignee — primary fields are trustworthy, except a
        // creator UID stored on a non-creator name (legacy corruption).
        var primaryUid = e.assignedToUid;
        if (primaryUid == e.createdBy &&
            e.assignedTo.trim().toLowerCase() != creatorNameLower) {
          primaryUid = null;
        }
        note(
          e.assignedTo,
          uid: primaryUid,
          phone: e.assignedToPhone,
          assigneeOnMyEnquiry: mine,
        );
      } else {
        // Multi-assignee — primary UID/phone can hold another assignee's
        // identity on corrupt docs, so only trust index-aligned slots.
        // Read the raw lists (the model getters drop empty entries, which
        // would break index alignment).
        final uids = e.extraFields?['assigneeUids'];
        final phones = e.extraFields?['assigneePhones'];
        final uidsAligned = uids is List && uids.length == assigneeNames.length;
        final phonesAligned =
            phones is List && phones.length == assigneeNames.length;
        for (int i = 0; i < assigneeNames.length; i++) {
          final slotName = assigneeNames[i]?.toString().trim() ?? '';
          var slotUid = uidsAligned ? (uids[i]?.toString() ?? '') : '';
          if (slotUid == e.createdBy &&
              slotName.toLowerCase() != creatorNameLower) {
            slotUid = ''; // creator UID in an assignee slot — corruption
          }
          note(
            slotName,
            uid: slotUid,
            phone: phonesAligned ? phones[i]?.toString() : null,
            assigneeOnMyEnquiry: mine,
          );
        }
      }
      enquiryPeople.add(people);
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
    // corrupt UID matches, so veto a UID-based merge whenever both names have
    // phones and none are shared.
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

    // A UID claimed by two unmerged clusters (the corruption above) must not
    // widen either person's filter, so keep only unambiguously owned UIDs.
    final rootsByUid = <String, Set<String>>{};
    for (final k in display.keys) {
      for (final uid in nameUids[k] ?? const <String>{}) {
        (rootsByUid[uid] ??= {}).add(find(k));
      }
    }

    final rootKeyFor = <String, String>{};
    for (final entry in members.entries) {
      final sorted = entry.value
        ..sort((a, b) {
          final byPicked = (pickedByMe[b] ?? 0).compareTo(pickedByMe[a] ?? 0);
          return byPicked != 0 ? byPicked : a.compareTo(b);
        });
      final canonical = sorted.first;
      _pickerDisplay[canonical] = display[canonical]!;
      _pickerAliases[canonical] = entry.value.toSet();
      _pickerUids[canonical] = {
        for (final m in entry.value)
          ...(nameUids[m] ?? const <String>{}).where(
            (u) => (rootsByUid[u]?.length ?? 0) == 1,
          ),
      };
      _pickerPhones[canonical] = {
        for (final m in entry.value) ...(namePhones[m] ?? const <String>{}),
      };
      for (final m in entry.value) {
        rootKeyFor[m] = canonical;
      }
    }

    // Count enquiries once per merged person + per-person status stats.
    for (int i = 0; i < enquiryPeople.length; i++) {
      final e = source[i];
      final roots = enquiryPeople[i].map((k) => rootKeyFor[k]!).toSet();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isBlocked = e.extraFields?['isBlocked'] == true;
      final open = !e.isClosed && _config.isOpenStatus(e.status);
      final isOverdue =
          open &&
          e.deadline != null &&
          DateTime(
            e.deadline!.year,
            e.deadline!.month,
            e.deadline!.day,
          ).isBefore(today);
      final last = e.lastMessageTime ?? e.updatedAt;
      for (final r in roots) {
        _pickerCounts[r] = (_pickerCounts[r] ?? 0) + 1;
        // Same disjoint partition as the summary strip so the picker and
        // the assignee view always agree.
        if (!e.isDeleted && !e.isArchived && open && !isBlocked) {
          if (isOverdue) {
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

  /// Bottom sheet with search to pick another assignee/creator to view.
  void _showAssigneePicker() {
    // Always rebuild the people index from the provider's current enquiry set.
    // The cached index is filled during load, but `provider.enquiries` can
    // still be landing (local-first rows then the Firestore delta) when this
    // screen first opens — so a snapshot taken too early left the picker
    // showing only the first few assignees until some later action (like
    // selecting one) happened to re-run the rebuild. Re-running here is a
    // cheap single in-memory pass over already-decoded rows, and it fires only
    // on the explicit tap that opens the sheet — never in the hot
    // [_filterEnquiries] path the freeze fix deliberately kept light. Refresh
    // [_allEnquiries] too so the pinned Me/Unassigned counts match the list.
    if (mounted) {
      _allEnquiries = List<EnquiryModel>.of(_readProvider(context).enquiries);
    }
    _rebuildPickerIndex(_allEnquiries);
    final display = _pickerDisplay;
    final keys = _pickerKeys;
    // Authoritative person-scoped counts for the selected row — matches the
    // header strip; the name-cluster preview can under-count UID/phone.
    final selCounts = _summaryCounts();

    // Count for the pinned "Unassigned" row — my own cards that still have
    // no assignee (same predicate as the sentinel view in _filterEnquiries).
    // Must exclude soft-deleted/archived cards: the sentinel view renders
    // through applyFiltersTo, which strips those, so counting them here made
    // the label read one higher than the cards actually shown.
    final myUid = context.read<AuthProvider>().userModel?.uid ?? '';
    final myName = context.read<AuthProvider>().userModel?.name ?? 'Me';
    final unassignedCount = _allEnquiries
        .where(
          (e) =>
              e.createdBy == myUid &&
              e.assignedTo.isEmpty &&
              !e.isDeleted &&
              !e.isArchived,
        )
        .length;
    // Count for the pinned "Me" row — same exclusion basis as the view
    // (applyFiltersTo strips deleted/archived rows).
    final meCount = _allEnquiries
        .where(
          (e) =>
              !e.isDeleted &&
              !e.isArchived &&
              (e.createdBy == myUid ||
                  e.assignedToUid == myUid ||
                  (e.extraFields?['assigneeUids'] is List &&
                      (e.extraFields!['assigneeUids'] as List).contains(
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
                      // row, which is stripped out below (Task parity).
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
                            color: _themeColor,
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
                            '$meCount ${meCount == 1 ? 'card' : 'cards'} · mine (created + assigned)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          trailing: _isMeView
                              ? Icon(
                                  Icons.check_circle,
                                  size: 20,
                                  color: _themeColor,
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
                            backgroundColor: _themeColor.withValues(
                              alpha: 0.12,
                            ),
                            child: Icon(
                              Icons.person_off_outlined,
                              size: 18,
                              color: _themeColor,
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
                            '$unassignedCount ${unassignedCount == 1 ? 'card' : 'cards'} · assign later',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                          trailing: _isUnassignedView
                              ? Icon(
                                  Icons.check_circle,
                                  size: 20,
                                  color: _themeColor,
                                )
                              : null,
                          onTap: () {
                            // Switch FIRST, then dismiss — guarantees the
                            // person/list update even if the sheet dismiss
                            // misbehaves on this context (parity with Task).
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
                              // Compare on the merged key so an alias-named
                              // selection still ticks its canonical row
                              final isSelected =
                                  key == _canonicalKeyFor(_resolvedPerson);
                              return ListTile(
                                dense: true,
                                leading: AppAvatar(
                                  avatarUrl: AvatarCacheService().urlFor(
                                    uid:
                                        (_pickerUids[key] ?? const <String>{})
                                            .isEmpty
                                        ? null
                                        : (_pickerUids[key] ?? const <String>{})
                                              .first,
                                    phone:
                                        (_pickerPhones[key] ?? const <String>{})
                                            .isEmpty
                                        ? null
                                        : (_pickerPhones[key] ??
                                                  const <String>{})
                                              .first,
                                    name: name,
                                  ),
                                  initials: Helpers.getInitials(name),
                                  radius: 16,
                                  color: _themeColor,
                                  fontSize: 12,
                                ),
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  '${isSelected ? selCounts.active : (_pickerActive[key] ?? 0)} Active | '
                                  '${isSelected ? selCounts.overdue : (_pickerOverdue[key] ?? 0)} Overdue'
                                  '${_pickerLastSeen[key] == null ? '' : ' · ${_formatAgo(_pickerLastSeen[key]!)}'}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.secondaryText,
                                  ),
                                ),
                                trailing: isSelected
                                    ? Icon(
                                        Icons.check_circle,
                                        size: 20,
                                        color: _themeColor,
                                      )
                                    : null,
                                onTap: () {
                                  // Switch FIRST, then dismiss (see the
                                  // 'Unassigned' row above) — parity with Task.
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
    // to a couple of words — the long sentences wrapped across the snackbar
    // and read as clutter (user feedback).
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _attentionMode ? 'Needs Attention' : 'Showing all enquiries',
          ),
          backgroundColor: _attentionMode
              ? const Color(0xFFC92A2A)
              : AppTheme.primaryGreen,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Pending action count for one enquiry: only actions that still need a
  /// response or closure count — informational actions are ignored. A reply
  /// closes queries/requests/extensions; follow-ups, blockers and calls stay
  /// open until marked done (same rule as the Pending line and the bell
  /// chips). Straight from the action-icons cache — no extra queries.
  int _pendingActionCount(String enquiryId) {
    try {
      final rows = _readProvider(context).getActionIcons(enquiryId);
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

  /// An enquiry needs attention when it is blocked, urgent, overdue or
  /// still has pending actions.
  bool _needsAttention(EnquiryModel e) {
    if (e.isDeleted || e.isArchived || e.isClosed) return false;
    if (e.extraFields?['isBlocked'] == true) return true;
    if (e.isUrgent) return true;
    final d = e.deadline;
    if (d != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (DateTime(d.year, d.month, d.day).isBefore(today)) return true;
    }
    return _pendingActionCount(e.id) > 0;
  }

  /// Filtered list with attention-first partitioning when attention mode
  /// is on (chosen sort order stays intact inside each group).
  List<EnquiryModel> get _displayedEnquiries {
    if (!_attentionMode) return _filteredEnquiries;
    final attention = _filteredEnquiries.where(_needsAttention).toList();
    final rest = _filteredEnquiries.where((e) => !_needsAttention(e)).toList();
    return [...attention, ...rest];
  }

  /// Disjoint status partition of the current view's enquiry list
  /// ([_personEnquiries]). Shared by the header summary strip and the
  /// assignee picker's selected row so the two always agree for the person
  /// being viewed. The picker's per-person preview is built from name
  /// clusters (see [_rebuildPickerIndex]), which can under-count a person
  /// whose enquiries are matched here by resolved UID/phone as well — so the
  /// selected row overrides its preview with these authoritative numbers.
  ({int active, int blocked, int overdue, int done, int archived})
  _summaryCounts() {
    int active = 0, blocked = 0, overdue = 0, done = 0, archived = 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final e in _personEnquiries) {
      if (e.isDeleted) continue;
      if (e.isArchived) {
        // Archived counts only the selected person's assignee-side
        // enquiries — creator-side pairs would inflate the stat.
        if (_personAsAssigneeIds.contains(e.id)) archived++;
        continue;
      }
      final isBlocked = e.extraFields?['isBlocked'] == true;
      final open = !e.isClosed && _config.isOpenStatus(e.status);
      if (!open) {
        done++;
      } else if (isBlocked) {
        blocked++;
      } else if (e.deadline != null) {
        final d = e.deadline!;
        if (DateTime(d.year, d.month, d.day).isBefore(today)) {
          overdue++;
        } else {
          active++;
        }
      } else {
        active++;
      }
    }
    return (
      active: active,
      blocked: blocked,
      overdue: overdue,
      done: done,
      archived: archived,
    );
  }

  /// Brief summary strip: how many enquiries are Active, Blocked or
  /// Overdue, plus how many actions are still pending (Task-module parity).
  Widget _buildSummaryStrip() {
    // Disjoint partition of this person's enquiries so the four working
    // columns (Active + Blocked + Overdue + Done) always total to the header
    // count; Archived is reported separately (assignee-side only).
    final (
      active: active,
      blocked: blocked,
      overdue: overdue,
      done: done,
      archived: archived,
    ) = _summaryCounts();

    // Calm inline summary (Task-module parity): one quiet centred line, no
    // tinted band and no dividers. All count numbers render in black (matching
    // the CRM view) — colour no longer flags Blocked/Overdue, so the strip
    // stays uniform regardless of the counts. The numbers remain a disjoint
    // partition that totals the header count.
    // One Wrap child per stat (Task-module parity). A single Text.rich let the
    // line break between a count and its label, so each stat carries its own
    // leading dot and moves down as one unit when the row does not fit.
    final stats = <(int, String, Color?)>[
      (active, 'Active', null),
      (blocked, 'Blkd', null),
      (overdue, 'Over', null),
      (done, 'Done', null),
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
                ? _themeColor.withOpacity(0.12)
                : AppTheme.lightGrey.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? _themeColor
                  : AppTheme.lightText.withOpacity(0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? _themeColor : AppTheme.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  /// Export the currently filtered enquiries
  void _exportCurrentView() {
    if (_filteredEnquiries.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No enquiries to export')));
      return;
    }

    final planType = context.read<AuthProvider>().effectivePlanType;
    if (!PaywallLimits.canExport(planType)) {
      showPaywallDialog(
        context,
        feature: 'Export is a Premium feature.',
        detail: 'Upgrade to Premium to export enquiries to CSV, Excel and PDF.',
      );
      return;
    }

    final headers = [
      '#',
      'Title',
      'Client',
      'Status',
      'Priority',
      'Created By',
      'Assigned To',
      'Deadline',
      'Progress',
      'Created',
    ];
    final rows = _filteredEnquiries.map((e) {
      final status = e.status[0].toUpperCase() + e.status.substring(1);
      final priority = e.priority == 3
          ? 'High'
          : e.priority == 2
          ? 'Medium'
          : 'Low';
      final progress = '${(e.progress * 100).toInt()}%';
      final deadline = e.deadline != null
          ? DateFormat('dd/MM/yyyy').format(e.deadline!)
          : '';
      final created = DateFormat('dd/MM/yyyy').format(e.createdAt);
      return [
        e.displayId?.toString() ?? '',
        e.title,
        e.clientName,
        status,
        priority,
        e.createdByName ?? '',
        e.assignedTo,
        deadline,
        progress,
        created,
      ];
    }).toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Assignee Sales',
      filterLabel: _resolvedPerson,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = context.read<AuthProvider>().userModel?.uid ?? '';
    final currentName = context.read<AuthProvider>().userModel?.name ?? '';
    final currentPhone = context.read<AuthProvider>().userModel?.phone ?? '';

    if (widget.embedded) {
      return Column(
        children: [
          _buildEmbeddedHeader(),
          _buildEmbeddedTabBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _resolvedPerson.isEmpty
                ? _buildNoPersonState()
                : _selectedTab == 'actions'
                ? _buildActionsTab()
                : _buildSalesTab(currentUid, currentName, currentPhone),
          ),
        ],
      );
    }

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
        title: InkWell(
          onTap: _showAssigneePicker,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _resolvedPerson,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 20,
                    color: Colors.white,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _resolvedOther.isNotEmpty
                    ? '${_filteredEnquiries.length} Enquiries with $_resolvedOther'
                    : '${_filteredEnquiries.length} Enquiries',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // Pending-actions summary shows only while the bell
              // (attention mode) is on. The AppBar title is far too narrow for
              // the full sentence, so it gets the compact one-liner.
              if (_attentionMode)
                _buildNeedsAttentionStrip(
                  textColor: Colors.white.withOpacity(0.85),
                  iconColor: Colors.white,
                  padding: EdgeInsets.zero,
                  compact: true,
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_search_outlined),
            tooltip: 'Change assignee',
            onPressed: _showAssigneePicker,
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Export',
            onPressed: _exportCurrentView,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withOpacity(0.6),
          labelStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          tabs: const [
            Tab(text: 'ASSIGNEE SALES'),
            Tab(text: 'ACTIONS'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _selectedTab == 'actions'
          ? _buildActionsTab()
          : _buildSalesTab(currentUid, currentName, currentPhone),
    );
  }

  // ── Embedded (home ASSIGNEE tab) widgets ────────────────────────

  /// Attention-mode summary (Task-module parity). In Sales the bell PARTITIONS
  /// the list — enquiries needing attention float to the top and nothing is
  /// hidden — so the copy says that instead of implying a filter. It never
  /// vanishes: "nothing needs attention" is itself the answer. [compact]
  /// collapses it to one short line for the narrow AppBar title.
  Widget _buildNeedsAttentionStrip({
    Color textColor = AppTheme.secondaryText,
    Color iconColor = const Color(0xFFC92A2A),
    EdgeInsets padding = const EdgeInsets.fromLTRB(16, 0, 16, 2),
    bool compact = false,
  }) {
    final teamId = _readProvider(context).currentTeamId;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: LocalDatabaseService().watchSalesActions(
        teamId,
        table: _config.actionsTableName,
      ),
      builder: (context, snapshot) {
        final personEnquiryIds = _filteredEnquiries.map((e) => e.id).toSet();
        // Mirror the task module: only OPEN, non-draft enquiries contribute
        // to the summary — pending actions on closed/archived/deleted
        // enquiries never show as chips on the cards, so counting them here
        // would make the summary disagree with the chips.
        final openIds = _filteredEnquiries
            .where(
              (e) =>
                  !e.isDeleted &&
                  !e.isArchived &&
                  !e.isClosed &&
                  _config.isOpenStatus(e.status) &&
                  e.extraFields?['isDraft'] != true,
            )
            .map((e) => e.id)
            .toSet();
        final pending = _actionsFromRows(
          (snapshot.data ?? [])
              .where(
                (r) =>
                    personEnquiryIds.contains(r['parentId'] as String?) &&
                    openIds.contains(r['parentId'] as String?),
              )
              .toList(),
        ).where(_isPendingAction).toList();
        // Pending is already decided by the shared _isPendingAction above; the
        // tally canonicalizes each display type back to its actions-table key
        // and renders from the one module-agnostic label map, so it can't drift
        // from the Needs Attention filter or the nav badge.
        final counts = <String, int>{};
        for (final i in pending) {
          final key = Helpers.actionKeyFromDisplay(i.type);
          counts[key] = (counts[key] ?? 0) + 1;
        }
        final parts = Helpers.actionAttentionLabels.entries
            .where((e) => (counts[e.key] ?? 0) > 0)
            .map((e) => '${counts[e.key]} ${e.value}')
            .toList();

        // `attention` is what the partition actually floats to the top, so it
        // — not `parts` — drives the wording.
        final total = _filteredEnquiries.length;
        final attention = _filteredEnquiries.where(_needsAttention).length;
        final String headline;
        String? detail;
        if (attention == 0) {
          headline = 'Nothing needs attention';
        } else if (compact) {
          headline = '$attention of $total need action';
        } else {
          headline = 'Needs attention first: $attention of $total';
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

  Widget _buildEmbeddedHeader() {
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
                  // Selected person's photo when resolved, initials fallback
                  // (also on load failure — e.g. offline, revoked URL). Same
                  // AppAvatar the cards and the picker use, so a contact looks
                  // identical everywhere (Task-module parity).
                  _resolvedPerson.isEmpty
                      ? CircleAvatar(
                          radius: 18,
                          backgroundColor: _themeColor.withOpacity(0.15),
                          child: Icon(
                            Icons.person_search,
                            size: 18,
                            color: _themeColor,
                          ),
                        )
                      : AppAvatar(
                          avatarUrl: _personAvatarUrl,
                          initials: Helpers.getInitials(_resolvedPerson),
                          radius: 18,
                          color: _themeColor,
                          fontSize: 13,
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
                                _resolvedPerson.isEmpty
                                    ? 'Select Assignee'
                                    : _resolvedPerson,
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
                        if (_resolvedPerson.isNotEmpty &&
                            (_personDesignation?.isNotEmpty ?? false))
                          Text(
                            // First-letter capital per style guide
                            // ('director' → 'Director').
                            _personDesignation!.isEmpty
                                ? _personDesignation!
                                : _personDesignation![0].toUpperCase() +
                                      _personDesignation!.substring(1),
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (_resolvedPerson.isNotEmpty)
                          Text(
                            '${_filteredEnquiries.length} ${_filteredEnquiries.length == 1 ? 'Enquiry' : 'Enquiries'}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                        // Pending-actions summary moved to the full-width slot
                        // below the header — it truncated in this narrow column.
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Attention-mode toggle (Task-module parity): cards switch to
          // pending actions and attention enquiries float to the top.
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
        // Both summaries share this one full-width slot below the header —
        // parity with the Task module, where the attention line was moved out
        // of the cramped header column for the same reason.
        //
        // Sales tab only: this strip tallies the ENQUIRY list the bell
        // partitions. On the Actions tab the bell works through the 'Needs
        // Attention' time chip instead, which is already visible in the
        // filter row.
        if (_resolvedPerson.isNotEmpty && _selectedTab == 'sales')
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
        indicatorColor: _themeColor,
        indicatorWeight: 3,
        labelColor: _themeColor,
        unselectedLabelColor: AppTheme.secondaryText,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        tabs: const [
          Tab(text: 'ASSIGNEE SALES'),
          Tab(text: 'ACTIONS'),
        ],
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
            icon: Icon(Icons.search, size: 18, color: _themeColor),
            label: Text(
              'Select Assignee',
              style: TextStyle(color: _themeColor, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesTab(String currentUid, String currentName, String currentPhone) {
    if (_filteredEnquiries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'No enquiries found',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Text(
              'with $_resolvedPerson',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      // No horizontal padding — SalesCard carries its own 16px padding, so
      // the progress bar/badge column lines up flush right like TaskCard.
      // Bottom clearance keeps the last card above the system nav bar.
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 96),
      // Pre-render beyond the viewport so flings never hit a blank slot
      // (parity with the Task module's Assignee tab).
      cacheExtent: 800,
      itemCount: _displayedEnquiries.length,
      itemBuilder: (context, index) {
        final enquiry = _displayedEnquiries[index];
        final isCreator = enquiry.createdBy == currentUid;
        Widget card = SalesCard(
          enquiry: enquiry,
          showAssigner: !isCreator,
          // Show the FIRST (main) assignee's name + avatar on every card as a
          // rule; the list still includes deals where the selected person is
          // any assignee or the creator.
          showAssigneeName: true,
          currentUid: currentUid,
          currentName: currentName,
          currentPhone: currentPhone,
          pendingActions: _attentionMode,
          // Pass the screen's module config so the card resolves the RIGHT
          // provider: without it SalesCard defaults _config to ModuleConfig
          // .sales and reads SalesProvider — empty for CRM enquiry ids, so
          // CRM assignee cards showed no action chips (the Actions tab and
          // home cards were fine because they thread the real config).
          moduleConfig: _config,
          onTap: () {
            if (widget.selectionMode && widget.onToggleSelection != null) {
              widget.onToggleSelection!(enquiry);
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    SalesDetailScreen(enquiry: enquiry, moduleConfig: _config),
              ),
            );
          },
          onLongPress: () => widget.onLongPressEnquiry?.call(enquiry),
          isSelected:
              widget.selectionMode &&
              widget.selectedEnquiryIds.contains(enquiry.id),
        );

        // Swipe parity with the Task module's Assignee tab: deleted cards
        // swipe to purge permanently, drafts swipe to delete, archived cards
        // swipe back to normal views, every other card swipes to archive.
        final provider = _readProvider(context);
        final bool isDraftEnquiry =
            (enquiry.extraFields?['isDraft'] == true) &&
            enquiry.title.trim().isEmpty;
        if (enquiry.isDeleted) {
          // Deleted view: swipe purges the card permanently.
          card = Dismissible(
            key: Key(enquiry.id),
            direction: DismissDirection.endToStart,
            // Less sensitive: require ~75% of the width dragged before the
            // swipe fires (default 0.4 archived cards on a short flick).
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
            onDismissed: (_) async {
              try {
                await provider.deleteEnquiry(enquiry.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Card deleted forever'),
                      backgroundColor: Color(0xFFC92A2A),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to delete card: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: card,
          );
        } else if (enquiry.isArchived) {
          card = Dismissible(
            key: Key(enquiry.id),
            direction: DismissDirection.endToStart,
            // Less sensitive: require ~75% of the width dragged before the
            // swipe fires (default 0.4 archived cards on a short flick).
            dismissThresholds: const {DismissDirection.endToStart: 0.75},
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: AppTheme.primaryGreen,
              child: const Icon(
                Icons.unarchive_outlined,
                color: Colors.white,
                size: 24,
              ),
            ),
            onDismissed: (_) async {
              try {
                await provider.unarchiveEnquiry(enquiry.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Card unarchived'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to unarchive card: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: card,
          );
        } else if (isDraftEnquiry) {
          // Draft cards swipe away to delete — same as draft tasks.
          card = Dismissible(
            key: Key(enquiry.id),
            direction: DismissDirection.endToStart,
            // Less sensitive: require ~75% of the width dragged before the
            // swipe fires (default 0.4 archived cards on a short flick).
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
            onDismissed: (_) async {
              try {
                await provider.softDeleteEnquiry(enquiry.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Draft moved to Deleted'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to delete draft: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: card,
          );
        } else {
          card = Dismissible(
            key: Key(enquiry.id),
            direction: DismissDirection.endToStart,
            // Less sensitive: require ~75% of the width dragged before the
            // swipe fires (default 0.4 archived cards on a short flick).
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
            onDismissed: (_) async {
              try {
                await provider.archiveEnquiry(enquiry.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Card archived'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to archive card: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: card,
          );
        }
        return card;
      },
    );
  }

  // ── Actions Tab ──────────────────────────────────────────────────────

  Widget _buildActionsTab() {
    final teamId = _readProvider(context).currentTeamId;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: LocalDatabaseService().watchSalesActions(
        teamId,
        table: _config.actionsTableName,
      ),
      builder: (context, snapshot) {
        final actionRows = snapshot.data ?? [];
        // Only actions belonging to the selected person's enquiries
        final personEnquiryIds = _filteredEnquiries.map((e) => e.id).toSet();
        final personRows = actionRows
            .where((r) => personEnquiryIds.contains(r['parentId'] as String?))
            .toList();
        final allActions = _actionsFromRows(personRows);
        final filtered = _applyActionFilter(allActions);

        // Sort by scheduled date descending (latest first)
        filtered.sort(
          (a, b) => CardActionIcons.compareActions(
            a.scheduledDate,
            a.createdAt,
            b.scheduledDate,
            b.createdAt,
          ),
        );

        // Group by enquiry
        final enquiryActions = <String, List<_ActionItem>>{};
        for (final item in filtered) {
          enquiryActions.putIfAbsent(item.enquiryId, () => []).add(item);
        }

        // Sort enquiry groups by most recent action first
        final sortedEnquiryIds = enquiryActions.keys.toList();
        sortedEnquiryIds.sort((a, b) {
          final actionsA = enquiryActions[a]!;
          final actionsB = enquiryActions[b]!;
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

        // Build enquiry map
        final enquiryMap = <String, EnquiryModel>{};
        for (final e in _filteredEnquiries) {
          enquiryMap[e.id] = e;
        }

        return Column(
          children: [
            _buildActionsFilterRow(),

            if (allActions.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 64,
                        color: AppTheme.lightText,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No action items yet',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Actions in $_resolvedPerson\'s enquiries will appear here',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.lightText,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (sortedEnquiryIds.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    'No actions matching filter',
                    style: TextStyle(fontSize: 14, color: AppTheme.lightText),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 500,
                  // Bottom clearance keeps the last card above the nav bar.
                  padding: const EdgeInsets.only(top: 8, bottom: 96),
                  itemCount: sortedEnquiryIds.length,
                  itemBuilder: (context, index) {
                    final enquiryId = sortedEnquiryIds[index];
                    final actions = enquiryActions[enquiryId]!;
                    final enquiry = enquiryMap[enquiryId];
                    if (enquiry == null) return const SizedBox.shrink();
                    return _buildEnquiryActionCard(enquiry, actions);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildActionsFilterRow() {
    return Container(
      color: Colors.white,
      child: buildActionFilterDropdowns(
        timeOptions: _timeOptions,
        selectedTime: _timeFilter,
        onTimeChanged: (v) => setState(() => _timeFilter = v),
        typeOptions: _typeOptions,
        selectedType: _typeFilter,
        onTypeChanged: (v) => setState(() => _typeFilter = v),
      ),
    );
  }

  /// Convert action table rows to _ActionItem list.
  List<_ActionItem> _actionsFromRows(List<Map<String, dynamic>> rows) {
    final items = <_ActionItem>[];
    for (final row in rows) {
      final messageText = row['text'] as String? ?? '';
      // Skip "deadline updated" actions - not relevant for Actions tab
      if (messageText.toLowerCase().contains('deadline updated')) continue;

      final actionType = row['actionType'] as String;
      final type = actionType == 'followup' ? 'followUp' : actionType;
      final scheduledMs = row['scheduledDate'] as int?;
      final createdMs = row['createdAt'] as int;
      items.add(
        _ActionItem(
          enquiryId: row['parentId'] as String,
          clientName: row['clientName'] as String? ?? '',
          enquiryTitle: row['parentTitle'] as String? ?? '',
          type: type,
          message: messageText,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
          scheduledDate: scheduledMs != null
              ? DateTime.fromMillisecondsSinceEpoch(scheduledMs)
              : DateTime.fromMillisecondsSinceEpoch(createdMs),
          hasScheduledDate: scheduledMs != null,
          isReplied: (row['isReplied'] as int) == 1,
          isFollowUpDone: (row['isDone'] as int) == 1,
          messageId: row['id'] as String? ?? '',
          seqNo: row['seqNo'] as int?,
        ),
      );
    }
    return items;
  }

  bool _isPendingAction(_ActionItem i) => Helpers.isActionPending(
    Helpers.actionKeyFromDisplay(i.type),
    isDone: i.isFollowUpDone ?? false,
    isReplied: i.isReplied ?? false,
  );

  List<_ActionItem> _applyActionFilter(List<_ActionItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

    // Axis 1 — time chip.
    List<_ActionItem> out;
    switch (_timeFilter) {
      case 'Overdue':
        out = items
            .where(
              (i) =>
                  // Overdue = a still-PENDING action past a REAL scheduled
                  // date (hasScheduledDate), so undated actions aging on their
                  // write date (and informational logs) never pile here.
                  i.hasScheduledDate &&
                  dayOf(i.scheduledDate).isBefore(today) &&
                  _isPendingAction(i),
            )
            .toList();
        break;
      case 'Today':
        out = items.where((i) => dayOf(i.scheduledDate) == today).toList();
        break;
      case 'Upcoming':
        out = items
            .where((i) => dayOf(i.scheduledDate).isAfter(today))
            .toList();
        break;
      // No time filter — the type axis below still applies.
      case kActionTimeAll:
        out = items;
        break;
      case 'Needs Attention':
      default:
        out = items.where(_isPendingAction).toList();
        break;
    }

    // Axis 2 — optional action-type override (value == _ActionItem.type).
    if (_typeFilter != null) {
      out = out.where((i) => i.type == _typeFilter).toList();
    }
    return out;
  }

  Widget _buildEnquiryActionCard(
    EnquiryModel enquiry,
    List<_ActionItem> actions,
  ) {
    final currentUid = context.read<AuthProvider>().userModel?.uid ?? '';
    final currentName = context.read<AuthProvider>().userModel?.name ?? '';
    final isAssignedToMe =
        enquiry.assignedToUid == currentUid ||
        enquiry.assignedTo == currentName ||
        enquiry.assignedTo.toLowerCase() == 'me' ||
        enquiry.assigneeUids.contains(currentUid);

    final displayInitials = Helpers.getInitials(
      enquiry.clientName.isNotEmpty
          ? enquiry.clientName
          : (isAssignedToMe ? 'Me' : enquiry.assignedTo),
    );
    final accentColor = isAssignedToMe ? _themeColor : const Color(0xFF1976D2);
    // directionIcon/directionLabel/directionColor removed - card now matches SalesCard layout

    // Deadline calculation matching SalesCard format
    String daysToDeadline = '';
    Color deadlineColor = AppTheme.lightText;
    String daysFromStart = '';
    int totalDays = 0;
    if (enquiry.deadline != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final deadlineDate = DateTime(
        enquiry.deadline!.year,
        enquiry.deadline!.month,
        enquiry.deadline!.day,
      );
      final startDate = DateTime(
        enquiry.createdAt.year,
        enquiry.createdAt.month,
        enquiry.createdAt.day,
      );
      final difference = deadlineDate.difference(today).inDays;
      totalDays = deadlineDate.difference(startDate).inDays;
      final elapsedDays = today.difference(startDate).inDays;
      daysFromStart = elapsedDays >= 0 ? '${elapsedDays}d' : '0d';

      if (difference < 0) {
        daysToDeadline = '-${difference.abs()}d';
        deadlineColor = Colors.red;
      } else if (difference == 0) {
        final hoursLeft = enquiry.deadline!.difference(now).inHours;
        daysToDeadline = hoursLeft > 0 && hoursLeft < 24
            ? '${hoursLeft}h'
            : '0d';
        deadlineColor = AppTheme.deadlineNearing;
      } else if (difference == 1) {
        daysToDeadline = '1d';
        deadlineColor = AppTheme.deadlineNearing;
      } else {
        daysToDeadline = '${difference}d';
        deadlineColor = AppTheme.onTime;
      }
    }

    // Milestone count
    final completedMilestones = enquiry.completedMilestoneCount;
    final totalMilestones = enquiry.milestones.length;

    final expanded = _expandedEnquiryCards.contains(enquiry.id);
    final visibleActions = actions;
    if (visibleActions.isEmpty) return const SizedBox.shrink();
    visibleActions.sort(
      (a, b) => CardActionIcons.compareActions(
        a.scheduledDate,
        a.createdAt,
        b.scheduledDate,
        b.createdAt,
      ),
    );

    // Running "#N" per base type (chronological) for the one-line rows.
    String baseOfAction(_ActionItem a) {
      const keys = {
        'quotation',
        'meeting',
        'sitevisit',
        'repaired',
        'verified',
        'call',
        'payment',
        'sample',
        'delivery',
        'collect',
        'negotiation',
        'won',
        'lost',
        'dropped',
        'cash',
      };
      if (keys.contains(a.type)) {
        final def = _config.actionFor(a.type);
        if (def != null) return def.label;
      }
      final lower = a.message.toLowerCase();
      if (a.type == 'warning' ||
          lower.contains('warning') ||
          lower.contains('escalation')) {
        return 'Escalation';
      }
      return CardActionIcons.actionBaseLabel(
        typeName: a.type,
        message: a.message,
      );
    }

    final chrono = List<_ActionItem>.from(visibleActions)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final seq = <String, int>{};
    final actionNumbers = <_ActionItem, int>{};
    for (final a in chrono) {
      final b = baseOfAction(a);
      // Cash/Payment sub-types share one family counter (cards-numbering
      // parity) — see CardActionIcons.numberingGroupKey.
      final group = CardActionIcons.numberingGroupKey(b);
      final n = (seq[group] ?? 0) + 1;
      seq[group] = n;
      actionNumbers[a] = n;
    }

    final enquiryTitle = enquiry.title.isNotEmpty ? enquiry.title : 'Enquiry';

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
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    SalesDetailScreen(enquiry: enquiry, moduleConfig: _config),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: accentColor.withOpacity(0.15),
                    child: Text(
                      displayInitials,
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1: Enquiry title + milestone chip + days badge + priority flag
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                enquiryTitle,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (totalMilestones > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _themeColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'M$completedMilestones',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _themeColor.withOpacity(0.7),
                                  ),
                                ),
                              ),
                            ],
                            if (enquiry.deadline != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: deadlineColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: totalDays > 0
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 18,
                                            child: Text(
                                              daysFromStart,
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: const Color(0xFF2F9E44),
                                              ),
                                            ),
                                          ),
                                          Text(
                                            ' | ',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: deadlineColor,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 18,
                                            child: Text(
                                              '${totalDays}d',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      )
                                    : Text(
                                        daysToDeadline,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: deadlineColor,
                                        ),
                                      ),
                              ),
                            ],
                            // Urgency flag slot (fixed width) — always reserved
                            // so the chips keep a constant position whether or
                            // not the enquiry is urgent
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: enquiry.isUrgent
                                  ? const Icon(
                                      Icons.flag,
                                      size: 14,
                                      color: Colors.red,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                        // Line 2: Client name
                        if (enquiry.clientName.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 10,
                                color: _themeColor.withOpacity(0.7),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  enquiry.clientName,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: _themeColor.withOpacity(0.8),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ...(expanded ? visibleActions : visibleActions.take(3)).map((action) {
            final lower = action.message.toLowerCase();
            // Exact-type catalog lookup for sales-cycle actions (checked first
            // — their details may mention generic keywords like 'follow up')
            const newTypeKeys = {
              'quotation',
              'meeting',
              'sitevisit',
              'repaired',
              'verified',
              'call',
              'payment',
              'sample',
              'delivery',
              'collect',
              'negotiation',
              'won',
              'lost',
              'dropped',
              'cash',
            };
            final catalogDef = newTypeKeys.contains(action.type)
                ? _config.actionFor(action.type)
                : null;
            final isWarning =
                action.type == 'warning' ||
                (catalogDef == null &&
                    (lower.contains('warning') ||
                        lower.contains('escalation')));
            final isFollowup =
                catalogDef == null &&
                (action.type == 'followUp' ||
                    lower.contains('follow-up') ||
                    lower.contains('followup') ||
                    lower.contains('follow up'));
            final isQuery =
                catalogDef == null &&
                (action.type == 'query' ||
                    lower.startsWith('query') ||
                    lower.contains('status request'));

            IconData icon;
            Color iconColor;
            String label; // ignore: unused_local_variable
            if (catalogDef != null) {
              icon = catalogDef.icon;
              iconColor = catalogDef.color;
              label = catalogDef.label;
            } else if (isWarning) {
              icon = Icons.report_gmailerrorred;
              iconColor = const Color(0xFFE03131);
              label = 'Escalation';
            } else if (isQuery) {
              icon = Icons.summarize;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = (action.isReplied ?? false) ? 'Query - Replied' : 'Query';
            } else if (isFollowup) {
              icon = Icons.event_repeat;
              iconColor = (action.isFollowUpDone ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF1976D2);
              label = (action.isFollowUpDone ?? false)
                  ? 'Follow-up - Done'
                  : 'Follow-up';
            } else if (action.type == 'blocker') {
              icon = Icons.block;
              iconColor = (action.isFollowUpDone ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFFC92A2A);
              label = (action.isFollowUpDone ?? false)
                  ? 'Blocker - Resolved'
                  : 'Blocker';
            } else if (action.type == 'approval') {
              icon = Icons.fact_check;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF0B7285);
              label = (action.isReplied ?? false)
                  ? 'Request - Actioned'
                  : 'Request Action';
            } else if (action.type == 'extension') {
              icon = Icons.more_time;
              iconColor = (action.isReplied ?? false)
                  ? const Color(0xFF2F9E44)
                  : const Color(0xFF3B5BDB);
              label = (action.isReplied ?? false)
                  ? 'Extension - Actioned'
                  : 'Extension Requested';
            } else if (action.type == 'progressReport') {
              icon = Icons.trending_up;
              iconColor = const Color(0xFF7048E8);
              label = 'Progress Report';
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
              typeName: action.type,
            );
            final closed =
                (action.isReplied ?? false) || (action.isFollowUpDone ?? false);
            final base = catalogDef != null
                ? catalogDef.label
                : (isWarning
                      ? 'Escalation'
                      : CardActionIcons.actionBaseLabel(
                          typeName: action.type,
                          message: action.message,
                        ));
            // Same status suffixes as the Task module's compact action rows.
            final statusWord = closed
                ? const {
                        'query': ' Replied',
                        'followUp': ' Done',
                        'extension': '',
                        'approval': ' Actioned',
                        'blocker': ' Resolved',
                      }[action.type] ??
                      ''
                : '';
            // Prefer the baked occurrence number (matches the chat card and is
            // stable under filtering); fall back to the recomputed family
            // counter for legacy rows without a seqNo.
            final number = action.seqNo ?? (actionNumbers[action] ?? 1);
            final lineText = detail.isNotEmpty
                ? '$base$statusWord $number | $detail'
                : '$base$statusWord $number';

            return InkWell(
              onTap: () {
                // Warm Firestore → SQLite so the target message is on device
                // when the chat opens (Task module fetchMessagesOnce parity)
                FirebaseService().fetchModuleMessagesOnceFor(
                  enquiry.id,
                  _config.firestoreCollection,
                );
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SalesDetailScreen(
                      enquiry: enquiry,
                      moduleConfig: _config,
                      scrollToMessageId: action.messageId.isEmpty
                          ? null
                          : action.messageId,
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
                      done: closed,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
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
                    const Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: AppTheme.lightText,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
          if (visibleActions.length > 3)
            InkWell(
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedEnquiryCards.remove(enquiry.id);
                  } else {
                    _expandedEnquiryCards.add(enquiry.id);
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
                        color: _themeColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        expanded
                            ? 'Show less'
                            : '+${visibleActions.length - 3} more actions',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _themeColor,
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

  String _formatActionDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final actionDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
    if (actionDate == today)
      return 'Today ${DateFormat('hh:mm a').format(dateTime)}';
    final yesterday = today.subtract(const Duration(days: 1));
    if (actionDate == yesterday)
      return 'Yesterday ${DateFormat('hh:mm a').format(dateTime)}';
    final difference = today.difference(actionDate).inDays;
    if (difference < 7 && difference > 1) return '${difference}d ago';
    return DateFormat('MMM dd, hh:mm a').format(dateTime);
  }

  Color _getScheduledDateColor(DateTime scheduledDate) {
    return AppTheme.lightText;
  }
}

/// Lightweight action item for the Actions tab.
class _ActionItem {
  final String enquiryId;
  final String clientName;
  final String enquiryTitle;
  final String type;
  final String message;
  final DateTime createdAt;
  final DateTime scheduledDate;

  /// Whether [scheduledDate] is a real committed date or the write-date
  /// fallback. Overdue must never fire on an undated action aging on its
  /// creation date, so the Overdue filter gates on this. Defaults true.
  final bool hasScheduledDate;
  final bool? isReplied;
  final bool? isFollowUpDone;

  /// Id of the originating chat message (`actions.id` IS the message id) —
  /// lets rows deep-link into the conversation (Task module parity).
  final String messageId;

  /// Baked occurrence number from the message (via the actions index `seqNo`).
  /// Preferred over the recomputed family counter; null falls back to it.
  final int? seqNo;

  _ActionItem({
    required this.enquiryId,
    required this.clientName,
    this.enquiryTitle = '',
    required this.type,
    required this.message,
    required this.createdAt,
    required this.scheduledDate,
    this.hasScheduledDate = true,
    this.isReplied,
    this.isFollowUpDone,
    this.messageId = '',
    this.seqNo,
  });
}
