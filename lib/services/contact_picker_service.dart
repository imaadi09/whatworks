import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart' as app_auth;
import '../services/avatar_cache_service.dart';
import '../services/firebase/auth_repository.dart';
import '../services/local_database_service.dart';
import '../services/premium_status_service.dart';
import '../utils/app_links.dart';
import '../utils/constants.dart';
import '../utils/helpers.dart';
import '../widgets/card_widgets.dart';
import '../widgets/app_avatar.dart';

/// Represents a contact that can be assigned a task.
/// Can be either an in-app team member or a phonebook contact.
class AssignableContact {
  final String name;
  final String? phone;
  final String? email;
  final String? avatarUrl;
  final bool isOnApp; // true = in-app team member, false = phonebook contact
  final String? uid; // non-null for in-app users

  /// Sentinel marker: the user chose "Unassigned — assign later" in an
  /// assignee picker. Never a real contact; never cached.
  final bool isUnassigned;

  AssignableContact({
    required this.name,
    this.phone,
    this.email,
    this.avatarUrl,
    required this.isOnApp,
    this.uid,
    this.isUnassigned = false,
  });

  /// The "assign later" option returned by assignee pickers that pass
  /// allowUnassigned: true. Callers treat it as "create with no assignee".
  factory AssignableContact.unassigned() =>
      AssignableContact(name: '', isOnApp: false, isUnassigned: true);

  /// Build from in-app UserModel
  factory AssignableContact.fromUser(UserModel user) {
    return AssignableContact(
      name: user.name,
      phone: user.phone,
      email: user.email,
      avatarUrl: user.avatarUrl,
      isOnApp: user.isOnApp,
      uid: user.uid,
    );
  }

  /// Serialize to map for local cache persistence
  Map<String, dynamic> toCacheMap() => {
    'name': name,
    'phone': phone ?? '',
    'email': email ?? '',
    'avatarUrl': avatarUrl ?? '',
    'isOnApp': isOnApp,
    'uid': uid ?? '',
  };

  /// Build from phonebook Contact
  factory AssignableContact.fromPhoneContact(Contact contact) {
    return AssignableContact(
      name: contact.displayName.isNotEmpty
          ? contact.displayName
          : (contact.phones.isNotEmpty
                ? contact.phones.first.number
                : 'Unknown'),
      phone: contact.phones.isNotEmpty ? contact.phones.first.number : null,
      email: contact.emails.isNotEmpty ? contact.emails.first.address : null,
      avatarUrl: contact.photo != null ? null : null, // photo as bytes, not URL
      isOnApp: false,
    );
  }
}

/// Service for picking assignees from team members or phonebook contacts.
class ContactPickerService {
  static final ContactPickerService _instance =
      ContactPickerService._internal();
  factory ContactPickerService() => _instance;
  ContactPickerService._internal();

  List<Contact>? _cachedContacts;
  List<UserModel>? _cachedTeamMembers;
  bool _isLoadingTeamMembers = false;

  /// Get cached team members for synchronous UID lookup.
  /// Returns null if not yet loaded.
  List<UserModel>? getCachedTeamMembers() => _cachedTeamMembers;

  /// Pre-resolve phonebook nicknames to their in-app avatar url so list cards
  /// can show a person's photo by the LOCAL contact name stored on a task
  /// (e.g. "Sonu") without scanning contacts during build.
  ///
  /// Runs only OFF the UI path (contact preload / sync / picker open), right
  /// after the caches it reads are populated. Each cached phonebook contact is
  /// resolved once through AvatarCacheService (uid -> phone -> url) and, when a
  /// photo is found, its nickname is indexed. Cards then resolve the leader via
  /// the ordinary AvatarCacheService.urlFor(name:) O(1) lookup.
  ///
  /// This replaces the former identityForName() per-card scan, which ran a full
  /// phonebook pass (with a toLowerCase allocation per contact) once per card
  /// per rebuild and froze the home / chat / assignee lists once the contact
  /// cache was populated.
  void _rebuildNicknameAvatarIndex() {
    final contacts = _cachedPhoneAssignableContacts;
    if (contacts == null) return; // keep any existing index until known
    final avatars = AvatarCacheService();
    final next = <String, String>{};
    for (final c in contacts) {
      final name = c.name.trim().toLowerCase();
      if (name.isEmpty) continue;
      final url = avatars.urlFor(uid: c.uid, phone: c.phone);
      if (url != null) next[name] = url;
    }
    // Single wholesale update: persists for cold start, warms the photos and
    // repaints the cards that were showing initials until now.
    avatars.applyNicknameIndex(next);
  }

  // Phonebook name lookup: normalized phone -> phonebook name
  Map<String, String> _phonebookNameLookup = {};

  // Recent contacts persistence
  static const String _recentContactsKey = 'recent_contacts';
  static const int _maxRecentContacts = 5;
  List<AssignableContact>? _cachedRecentContacts;

  // Phone contact cache with sync timestamp (Enhancement 3 & 4)
  static const String _phoneContactsCacheKey = 'phone_contacts_cache';
  static const String _phoneContactsCacheTimeKey = 'phone_contacts_cache_time';
  static const String _phoneContactsFingerprintKey = 'phone_contacts_cache_fp';

  /// A warm cache is trusted for this long before the phonebook is re-fetched.
  static const Duration _phoneContactsCacheTtl = Duration(hours: 1);
  List<AssignableContact>? _cachedPhoneAssignableContacts;
  DateTime? _phoneContactsLastSync;
  void Function()? _contactChangeListener;

  /// Save a contact to recent contacts list
  Future<void> _saveToRecentContacts(AssignableContact contact) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load current recents
      final existing = await _loadRecentContactsFromStorage();

      // Remove duplicate if the SAME person is already present. Match by
      // normalized phone first, then UID, then name — so a contact saved once
      // under their phonebook name ("Sonu") and once under their app profile
      // name ("Sudarshna Bhatnagar") can't both linger as separate chips for
      // one number.
      final newPhone = Helpers.normalizePhone(contact.phone ?? '') ?? '';
      final newUid = contact.uid ?? '';
      existing.removeWhere((c) {
        final p = Helpers.normalizePhone(c.phone ?? '') ?? '';
        if (p.isNotEmpty && newPhone.isNotEmpty) return p == newPhone;
        final u = c.uid ?? '';
        if (u.isNotEmpty && newUid.isNotEmpty) return u == newUid;
        return c.name.toLowerCase() == contact.name.toLowerCase();
      });

      // Add to front
      existing.insert(0, contact);

      // Keep only max recent
      if (existing.length > _maxRecentContacts) {
        existing.removeRange(_maxRecentContacts, existing.length);
      }

      // Serialize and save
      final jsonList = existing
          .map(
            (c) => {
              'name': c.name,
              'phone': c.phone ?? '',
              'email': c.email ?? '',
              'isOnApp': c.isOnApp,
              'uid': c.uid ?? '',
            },
          )
          .toList();

      await prefs.setString(_recentContactsKey, jsonEncode(jsonList));
      _cachedRecentContacts = existing;
      print('Saved ${existing.length} recent contacts');
    } catch (e) {
      print('Error saving recent contacts: $e');
    }
  }

  /// Load recent contacts from SharedPreferences
  Future<List<AssignableContact>> _loadRecentContactsFromStorage() async {
    if (_cachedRecentContacts != null) return List.from(_cachedRecentContacts!);

    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_recentContactsKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];

      final jsonList = jsonDecode(jsonStr) as List;
      final contacts = jsonList
          .map((item) {
            final map = Map<String, dynamic>.from(item);
            return AssignableContact(
              name: map['name'] ?? '',
              phone: (map['phone']?.toString().isNotEmpty == true)
                  ? map['phone']
                  : null,
              email: (map['email']?.toString().isNotEmpty == true)
                  ? map['email']
                  : null,
              isOnApp: map['isOnApp'] ?? false,
              uid: (map['uid']?.toString().isNotEmpty == true)
                  ? map['uid']
                  : null,
            );
          })
          .where((c) => c.name.isNotEmpty)
          .toList();

      _cachedRecentContacts = contacts;
      return contacts;
    } catch (e) {
      print('Error loading recent contacts: $e');
      return [];
    }
  }

  /// Get recent contacts (public method)
  Future<List<AssignableContact>> getRecentContacts() async {
    return _loadRecentContactsFromStorage();
  }

  // --- Enhancement 1: Phone-to-Firebase user matching ---

  /// Build a lookup map from cached team members by normalized phone number.
  Map<String, UserModel> _getTeamMemberPhoneMap() {
    final map = <String, UserModel>{};
    if (_cachedTeamMembers != null) {
      for (final user in _cachedTeamMembers!) {
        final normalized = Helpers.normalizePhone(user.phone);
        if (normalized != null && normalized.isNotEmpty) {
          map[normalized] = user;
        }
      }
    }
    return map;
  }

  /// Build phonebook name lookup from cached contacts.
  /// Maps normalized phone number -> phonebook display name.
  /// If useCachedOnly is true, only uses existing cache (non-blocking).
  Future<void> _buildPhonebookNameLookup({bool useCachedOnly = false}) async {
    if (_phonebookNameLookup.isNotEmpty) return; // Already built

    // If we have cached AssignableContacts, build lookup from them (fast)
    if (_cachedPhoneAssignableContacts != null &&
        _cachedPhoneAssignableContacts!.isNotEmpty) {
      _phonebookNameLookup = {};
      for (final contact in _cachedPhoneAssignableContacts!) {
        final normalized = Helpers.normalizePhone(contact.phone);
        if (normalized != null && normalized.isNotEmpty) {
          _phonebookNameLookup[normalized] = contact.name;
        }
      }
      print(
        'Built phonebook name lookup from cache with ${_phonebookNameLookup.length} entries',
      );
      return;
    }

    // If useCachedOnly, don't load fresh contacts
    if (useCachedOnly) return;

    try {
      // Load phonebook contacts if not already cached
      _cachedContacts ??= await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      _phonebookNameLookup = {};
      for (final contact in _cachedContacts!) {
        if (contact.phones.isNotEmpty) {
          for (final phone in contact.phones) {
            final normalized = Helpers.normalizePhone(phone.number);
            if (normalized != null && normalized.isNotEmpty) {
              // Use displayName if available, otherwise use first phone
              final name = contact.displayName.isNotEmpty
                  ? contact.displayName
                  : phone.number;
              _phonebookNameLookup[normalized] = name;
            }
          }
        }
      }
      print(
        'Built phonebook name lookup with ${_phonebookNameLookup.length} entries',
      );
    } catch (e) {
      print('Error building phonebook name lookup: $e');
    }
  }

  // --- Enhancement 3: Local phone contact cache ---

  /// Save phone contacts to local SharedPreferences cache.
  ///
  /// The megabyte-scale contact blob is only rewritten when the phonebook
  /// actually changed: an order-independent fingerprint (count + commutative
  /// hash of normalised phone/name/uid) is compared against the stored one and
  /// the blob write is skipped on a match. The tiny sync-time key is always
  /// refreshed so the 1-hour TTL resets either way.
  Future<void> _savePhoneContactsCache(List<AssignableContact> contacts) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedPhoneAssignableContacts = contacts;
      _rebuildNicknameAvatarIndex();
      _phoneContactsLastSync = DateTime.now();
      await prefs.setString(
        _phoneContactsCacheTimeKey,
        _phoneContactsLastSync!.toIso8601String(),
      );

      final fingerprint = _contactsFingerprint(contacts);
      if (prefs.getString(_phoneContactsFingerprintKey) == fingerprint &&
          (prefs.getString(_phoneContactsCacheKey)?.isNotEmpty ?? false)) {
        return; // Unchanged phonebook — skip the megabyte write.
      }

      final jsonList = contacts.map((c) => c.toCacheMap()).toList();
      await prefs.setString(_phoneContactsCacheKey, jsonEncode(jsonList));
      await prefs.setString(_phoneContactsFingerprintKey, fingerprint);
    } catch (e) {
      print('Error saving phone contacts cache: $e');
    }
  }

  /// Order-independent fingerprint of a contact list: the count plus an XOR
  /// (commutative) hash of each contact's normalised phone, name and uid, so
  /// list ordering never affects the result.
  String _contactsFingerprint(List<AssignableContact> contacts) {
    var hash = 0;
    for (final c in contacts) {
      final phone = Helpers.normalizePhone(c.phone) ?? '';
      // XOR is commutative → order-independent.
      hash ^= Object.hash(phone, c.name.toLowerCase(), c.uid ?? '');
    }
    return '${contacts.length}:$hash';
  }

  /// Load phone contacts from local cache (returns null if no cache)
  Future<List<AssignableContact>?> _loadPhoneContactsCache() async {
    if (_cachedPhoneAssignableContacts != null) {
      return List.from(_cachedPhoneAssignableContacts!);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_phoneContactsCacheKey);
      final timeStr = prefs.getString(_phoneContactsCacheTimeKey);
      if (jsonStr == null || jsonStr.isEmpty) return null;
      final jsonList = jsonDecode(jsonStr) as List;
      final contacts = jsonList
          .map((item) {
            final map = Map<String, dynamic>.from(item);
            return AssignableContact(
              name: map['name'] ?? '',
              phone: (map['phone']?.toString().isNotEmpty == true)
                  ? map['phone']
                  : null,
              email: (map['email']?.toString().isNotEmpty == true)
                  ? map['email']
                  : null,
              isOnApp: map['isOnApp'] ?? false,
              uid: (map['uid']?.toString().isNotEmpty == true)
                  ? map['uid']
                  : null,
            );
          })
          .where((c) => c.name.isNotEmpty)
          .toList();
      _cachedPhoneAssignableContacts = _sortByName(contacts);
      _rebuildNicknameAvatarIndex();
      if (timeStr != null) _phoneContactsLastSync = DateTime.tryParse(timeStr);
      return contacts;
    } catch (e) {
      print('Error loading phone contacts cache: $e');
      return null;
    }
  }

  // --- Enhancement 4: Background contact change listener ---

  /// Start listening for phonebook changes. Call once at app startup.
  void startContactChangeListener() {
    if (_contactChangeListener != null) return; // Already listening
    _contactChangeListener = _onContactsChanged;
    FlutterContacts.addListener(_contactChangeListener!);
  }

  /// Stop listening for phonebook changes
  void stopContactChangeListener() {
    if (_contactChangeListener != null) {
      FlutterContacts.removeListener(_contactChangeListener!);
      _contactChangeListener = null;
    }
  }

  /// Callback invoked when the phone's contact database changes
  void _onContactsChanged() {
    print('Phone contacts changed — invalidating cache');
    _cachedContacts = null;
    _cachedPhoneAssignableContacts = null;
    _phoneContactsLastSync = null;
    // Clear persisted cache so next load fetches fresh
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove(_phoneContactsCacheKey);
      prefs.remove(_phoneContactsCacheTimeKey);
      prefs.remove(_phoneContactsFingerprintKey);
    });
  }

  // --- Enhancement 5: SMS invite ---

  /// Send an SMS invite to a phone contact who is not on the app
  Future<bool> inviteContactViaSms(AssignableContact contact) async {
    if (contact.phone == null || contact.phone!.isEmpty) return false;
    final message =
        'Hey ${contact.name.split(' ').first}! I use WhatWorks to manage tasks and collaborate. Join me: ${AppLinks.invite}';
    final uri = Uri.parse(
      'sms:${contact.phone}?body=${Uri.encodeComponent(message)}',
    );
    try {
      final launched = await launchUrl(uri);
      if (launched) {
        print('SMS invite sent to ${contact.name} (${contact.phone})');
      }
      return launched;
    } catch (e) {
      print('Error sending SMS invite: $e');
      return false;
    }
  }

  /// Request contacts permission
  Future<bool> requestPermission() async {
    final status = await Permission.contacts.request();
    return status.isGranted;
  }

  /// Check if contacts permission is granted
  Future<bool> hasPermission() async {
    final status = await Permission.contacts.status;
    return status.isGranted;
  }

  /// Look up a phone number in the local phonebook and return the saved name.
  /// Returns null if the phone is not found in the phonebook.
  /// This is used for phonebook-first creator name resolution.
  Future<String?> getPhonebookName(String phoneNumber) async {
    if (phoneNumber.isEmpty) return null;

    final hasPerms = await hasPermission();
    if (!hasPerms) return null;

    final normalizedTarget = Helpers.normalizePhone(phoneNumber) ?? phoneNumber;

    // Use cached contacts if available
    if (_cachedContacts != null) {
      for (final contact in _cachedContacts!) {
        for (final phone in contact.phones) {
          final normalizedContact =
              Helpers.normalizePhone(phone.number) ?? phone.number;
          if (normalizedContact == normalizedTarget) {
            return contact.displayName;
          }
        }
      }
      return null; // Not found in cache
    }

    // Load contacts fresh
    try {
      _cachedContacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      for (final contact in _cachedContacts!) {
        for (final phone in contact.phones) {
          final normalizedContact =
              Helpers.normalizePhone(phone.number) ?? phone.number;
          if (normalizedContact == normalizedTarget) {
            return contact.displayName;
          }
        }
      }
    } catch (e) {
      print('[ContactPickerService] getPhonebookName error: $e');
    }

    return null;
  }

  /// Sort contacts alphabetically by name (case-insensitive) in place.
  List<AssignableContact> _sortByName(List<AssignableContact> contacts) {
    contacts.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return contacts;
  }

  /// Get all in-app team members (excluding current user)
  /// Loads from Firebase and caches for future use.
  /// Uses phonebook names when available for better display.
  Future<List<AssignableContact>> getTeamMembers() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    // Build phonebook name lookup from cache only (non-blocking)
    await _buildPhonebookNameLookup(useCachedOnly: true);

    // Return cached data if available
    if (_cachedTeamMembers != null && !_isLoadingTeamMembers) {
      return _sortByName(
        _cachedTeamMembers!
            .where((u) => u.uid != currentUserId)
            .map((u) => _teamMemberToContact(u))
            .toList(),
      );
    }

    // Prevent multiple simultaneous loads
    if (_isLoadingTeamMembers) {
      return [];
    }

    _isLoadingTeamMembers = true;

    try {
      // Load from Firebase
      final authRepo = AuthRepository();
      _cachedTeamMembers = await authRepo.getAllUsers();

      print('Loaded ${_cachedTeamMembers!.length} users from Firebase');

      // Refresh the Premium/Basic bit and avatar lookup on every contact
      // update: rebuild the in-memory lookups and persist plan types +
      // avatars to the SQLite users cache (fire-and-forget) so badges and
      // avatars survive offline restarts.
      PremiumStatusService().updateFromUsers(_cachedTeamMembers!);
      AvatarCacheService().updateFromUsers(_cachedTeamMembers!);
      // Avatar urls just refreshed from Firestore — re-resolve the phonebook
      // nickname index so list cards show photos by local contact name.
      _rebuildNicknameAvatarIndex();
      final userRows = _cachedTeamMembers!
          .map(
            (u) => {
              'uid': u.uid,
              'phone': Helpers.normalizePhone(u.phone) ?? u.phone,
              'name': u.name,
              // Cache the EFFECTIVE plan: the cached row has no expiry column,
              // so an expired plan must be collapsed to 'free' here rather than
              // read back as premium on the next offline start.
              'planType': u.effectivePlanType,
              'avatarUrl': u.avatarUrl,
            },
          )
          .where((r) => (r['phone'] ?? '').isNotEmpty)
          .toList();
      LocalDatabaseService().cacheUsers(userRows).catchError((e) {
        print('Error caching user plans: $e');
      });

      // Filter out current user and convert (using phonebook names)
      return _sortByName(
        _cachedTeamMembers!
            .where((u) => u.uid != currentUserId)
            .map((u) => _teamMemberToContact(u))
            .toList(),
      );
    } catch (e) {
      print('Error loading team members from Firebase: $e');
      // Return empty if Firebase fails
      return [];
    } finally {
      _isLoadingTeamMembers = false;
    }
  }

  // ── Scoped team (contact picker "Team Members" section) ──────────
  // The picker's Team section shows only people the current user has already
  // interacted with (co-participants / assignees / creators / chat senders on
  // their local tasks, enquiries and CRM records). Registered-but-unrelated
  // users stay discoverable via the "On App" badge on phonebook rows, so this
  // filter never shrinks _cachedTeamMembers (which powers that matching).
  Set<String> _interactedUids = {};

  /// Load the interacted set and return the scoped Team list. Ensures the full
  /// registered-user cache is populated first (for the On App badge + premium
  /// / avatar matching) by calling [getTeamMembers].
  Future<List<AssignableContact>> getScopedTeamMembers() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _interactedUids = await LocalDatabaseService().getInteractedUids(
      currentUid,
    );
    // Populate _cachedTeamMembers (all registered users) without returning it.
    await getTeamMembers();
    return _scopedTeamList();
  }

  /// Team contacts limited to [currentUid]-interacted people, built from the
  /// full registered-user cache. Falls back to an empty list until the cache
  /// and interacted set are both loaded.
  List<AssignableContact> _scopedTeamList() {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final cache = _cachedTeamMembers;
    if (cache == null) return [];
    return _sortByName(
      cache
          .where(
            (u) =>
                u.uid != currentUid &&
                u.uid.isNotEmpty &&
                _interactedUids.contains(u.uid),
          )
          .map((u) => _teamMemberToContact(u))
          .toList(),
    );
  }

  /// Convert UserModel to AssignableContact, using phonebook name if available.
  AssignableContact _teamMemberToContact(UserModel user) {
    final normalizedPhone = Helpers.normalizePhone(user.phone);
    // Use phonebook name if available, otherwise fall back to Firebase name
    final displayName =
        (normalizedPhone != null &&
            _phonebookNameLookup.containsKey(normalizedPhone))
        ? _phonebookNameLookup[normalizedPhone]!
        : user.name;

    return AssignableContact(
      name: displayName,
      phone: user.phone,
      email: user.email,
      avatarUrl: user.avatarUrl,
      isOnApp: user.isOnApp,
      uid: user.uid,
    );
  }

  /// Fetch phonebook contacts (requires permission).
  /// Cross-references against Firebase users to mark who is on the app (Enhancement 1).
  Future<List<AssignableContact>> getPhoneContacts({
    String? searchQuery,
    bool forceRefresh = false,
  }) async {
    final hasPerms = await hasPermission();
    if (!hasPerms) {
      final granted = await requestPermission();
      if (!granted) return [];
    }

    // Clear cache if force refresh requested
    if (forceRefresh) {
      _cachedContacts = null;
      _cachedPhoneAssignableContacts = null;
      print('Cleared contact cache - forcing refresh');
    }

    // Use cached raw contacts if available
    _cachedContacts ??= await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false, // Skip photo for performance
    );

    var contacts = _cachedContacts!;
    print(
      'Loaded ${contacts.length} phonebook contacts (cached: ${!forceRefresh})',
    );

    // Filter by search query
    if (searchQuery != null && searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      contacts = contacts.where((c) {
        return c.displayName.toLowerCase().contains(q) ||
            (c.phones.isNotEmpty && c.phones.any((p) => p.number.contains(q)));
      }).toList();
    }

    // Convert to AssignableContacts
    final assignableContacts = contacts
        .map((c) => AssignableContact.fromPhoneContact(c))
        .toList();

    // Ensure team members are loaded for matching
    if (_cachedTeamMembers == null) {
      await getTeamMembers();
    }

    // Enhancement 1: Cross-reference with Firebase users by normalized phone
    final teamPhoneMap = _getTeamMemberPhoneMap();
    for (var i = 0; i < assignableContacts.length; i++) {
      final contact = assignableContacts[i];
      final normalized = Helpers.normalizePhone(contact.phone);
      if (normalized != null && teamPhoneMap.containsKey(normalized)) {
        final matchedUser = teamPhoneMap[normalized]!;
        assignableContacts[i] = AssignableContact(
          name: contact.name,
          phone: contact.phone,
          email: contact.email,
          avatarUrl: matchedUser.avatarUrl ?? contact.avatarUrl,
          isOnApp: true,
          uid: matchedUser.uid,
        );
      }
    }

    // Cache matched contacts locally (Enhancement 3)
    if (searchQuery == null || searchQuery.isEmpty) {
      _savePhoneContactsCache(assignableContacts);
    }

    return _sortByName(assignableContacts);
  }

  /// Pre-load contacts in background at app startup.
  /// Call once after auth to warm up caches.
  Future<void> preLoadContacts() async {
    try {
      // Warm the Premium/Basic and avatar lookups from the SQLite cache so
      // badges/avatars show immediately (fresh data replaces them after
      // getTeamMembers below)
      await PremiumStatusService().ensureLoaded();
      await AvatarCacheService().ensureLoaded();

      // Cache-first startup: a warm cache within the 1-hour TTL rebuilds the
      // in-memory name lookup from the persisted AssignableContacts with zero
      // platform-channel traffic. Only a cold or stale cache pays for a full
      // FlutterContacts fetch (which deserialises the whole phonebook on this
      // isolate). Permission is never requested here.
      final cached = await _loadPhoneContactsCache();
      final isFresh =
          _phoneContactsLastSync != null &&
          DateTime.now().difference(_phoneContactsLastSync!) <
              _phoneContactsCacheTtl;

      if (cached != null && cached.isNotEmpty && isFresh) {
        await _buildPhonebookNameLookup(useCachedOnly: true);
        print(
          '[PreLoad] Contacts warm from cache (${cached.length}); skipped fetch',
        );
      } else if (await hasPermission()) {
        // Cold or stale — do the full fetch.
        _cachedContacts = await FlutterContacts.getContacts(
          withProperties: true,
          withPhoto: false,
        );
        // Build name lookup from loaded contacts
        _phonebookNameLookup = {};
        for (final contact in _cachedContacts!) {
          if (contact.phones.isNotEmpty) {
            for (final phone in contact.phones) {
              final normalized = Helpers.normalizePhone(phone.number);
              if (normalized != null && normalized.isNotEmpty) {
                final name = contact.displayName.isNotEmpty
                    ? contact.displayName
                    : phone.number;
                _phonebookNameLookup[normalized] = name;
              }
            }
          }
        }
        // Build assignable contacts and cache them in memory. The persisted
        // (cross-referenced) cache is written by getPhoneContacts when the
        // picker opens — fingerprint-gated so an unchanged phonebook is free.
        final assignableContacts = _cachedContacts!
            .map((c) => AssignableContact.fromPhoneContact(c))
            .toList();
        if (assignableContacts.isNotEmpty &&
            _cachedPhoneAssignableContacts == null) {
          _cachedPhoneAssignableContacts = _sortByName(assignableContacts);
          _rebuildNicknameAvatarIndex();
        }
        print(
          '[PreLoad] Phonebook: ${_cachedContacts!.length} contacts, lookup: ${_phonebookNameLookup.length}',
        );
      }
      // Pre-cache team members from Firebase
      await getTeamMembers();
      // Start listening for contact changes
      startContactChangeListener();
      print('[PreLoad] Contacts pre-loaded successfully');
    } catch (e) {
      print('[PreLoad] Error pre-loading contacts: $e');
    }
  }

  /// Clear cached contacts (useful for forcing refresh)
  void clearContactCache() {
    _cachedContacts = null;
    _cachedTeamMembers = null;
    _cachedPhoneAssignableContacts = null;
    _phoneContactsLastSync = null;
    _phonebookNameLookup = {}; // Clear phonebook name lookup
    stopContactChangeListener();
    // Clear persisted cache
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove(_phoneContactsCacheKey);
      prefs.remove(_phoneContactsCacheTimeKey);
      prefs.remove(_phoneContactsFingerprintKey);
    });
    print('Contact cache cleared');
  }

  /// Show a WhatsApp-style contact picker bottom sheet
  /// Returns the selected AssignableContact or null if cancelled
  Future<AssignableContact?> showContactPicker(
    BuildContext context, {
    bool allowUnassigned = false,
  }) async {
    String searchQuery = '';
    final searchController = TextEditingController();
    Timer? searchDebounce; // Debounce timer for search filtering
    bool showPhoneContacts = true; // Auto-show phonebook section
    bool isLoadingContacts = true; // Start loading immediately
    bool isLoadingTeamMembers = true;
    bool isLoadingRecents = true;
    List<AssignableContact> phoneContacts = [];
    List<AssignableContact> teamMembers = [];
    List<AssignableContact> recentContacts = [];
    AssignableContact? meContact; // "Me" contact for self-assignment
    int phoneDisplayLimit = 50; // Limit initial rendering for performance
    int teamDisplayLimit = 50;

    // Start loading team members and recent contacts in background
    // (will complete inside the modal builder via Future.microtask)
    final teamMembersFuture = getScopedTeamMembers();
    final recentContactsFuture = getRecentContacts();

    // Pre-populate team member phone map for matching in getPhoneContacts()
    // (getTeamMembers already cached _cachedTeamMembers)

    // Enhancement 3 & 4: Load cached phone contacts + start change listener
    startContactChangeListener();
    final cachedPhoneContacts = await _loadPhoneContactsCache();

    // Use cached contacts immediately for faster display
    if (cachedPhoneContacts != null && cachedPhoneContacts.isNotEmpty) {
      phoneContacts = cachedPhoneContacts;
      isLoadingContacts = false;
    }

    final result = await showModalBottomSheet<AssignableContact>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          // Resolve team members and recent contacts in background
          if (isLoadingTeamMembers || isLoadingRecents) {
            Future.microtask(() async {
              final results = await Future.wait([
                teamMembersFuture,
                recentContactsFuture,
              ]);
              setModalState(() {
                teamMembers = results[0];
                recentContacts = results[1];
                isLoadingTeamMembers = false;
                isLoadingRecents = false;
              });
            });
          }

          // Auto-refresh phonebook in background if not showing cached data
          // or if cache is stale (older than the TTL)
          final shouldRefresh =
              phoneContacts.isEmpty ||
              (_phoneContactsLastSync != null &&
                  DateTime.now().difference(_phoneContactsLastSync!) >
                      _phoneContactsCacheTtl);

          if (shouldRefresh && !isLoadingContacts) {
            Future.microtask(() async {
              final hasPerms = await hasPermission();
              if (hasPerms) {
                final contacts = await getPhoneContacts();
                // Only update if we got different/newer data
                if (contacts.isNotEmpty) {
                  // Re-resolve team member names with fresh phonebook data
                  await _buildPhonebookNameLookup(); // Use full load now
                  final updatedTeam = _scopedTeamList();

                  setModalState(() {
                    phoneContacts = contacts;
                    teamMembers = updatedTeam;
                  });
                }
              }
            });
          }

          // Auto-load phonebook on first build (only if no cached data)
          if (isLoadingContacts && phoneContacts.isEmpty) {
            Future.microtask(() async {
              final hasPerms = await hasPermission();
              if (hasPerms) {
                final contacts = await getPhoneContacts();
                // Re-resolve team member names with fresh phonebook data
                await _buildPhonebookNameLookup();
                final updatedTeam = _scopedTeamList();

                setModalState(() {
                  phoneContacts = contacts;
                  teamMembers = updatedTeam;
                  isLoadingContacts = false;
                });
              } else {
                final granted = await requestPermission();
                if (granted) {
                  final contacts = await getPhoneContacts();
                  await _buildPhonebookNameLookup();
                  final updatedTeam = _scopedTeamList();

                  setModalState(() {
                    phoneContacts = contacts;
                    teamMembers = updatedTeam;
                    isLoadingContacts = false;
                  });
                } else {
                  setModalState(() {
                    isLoadingContacts = false;
                  });
                }
              }
            });
          }

          // Get current user info for "Me" contact
          final authProvider = Provider.of<app_auth.AuthProvider>(
            context,
            listen: false,
          );
          if (meContact == null && authProvider.userModel != null) {
            meContact = AssignableContact(
              name: authProvider
                  .userModel!
                  .name, // Store actual name, not "Me (Name)"
              phone: authProvider.userModel!.phone,
              email: authProvider.userModel!.email,
              isOnApp: true,
              uid: authProvider.userModel!.uid,
            );
          }

          // Filtered lists
          final q = searchQuery.toLowerCase();
          final filteredTeam = q.isEmpty
              ? teamMembers
              : teamMembers
                    .where(
                      (c) =>
                          c.name.toLowerCase().contains(q) ||
                          (c.phone?.contains(q) ?? false),
                    )
                    .toList();

          final filteredPhone = q.isEmpty
              ? phoneContacts
              : phoneContacts
                    .where(
                      (c) =>
                          c.name.toLowerCase().contains(q) ||
                          (c.phone?.contains(q) ?? false),
                    )
                    .toList();

          // Filter "Me" contact
          final showMeContact =
              meContact != null &&
              (q.isEmpty ||
                  meContact!.name.toLowerCase().contains(q) ||
                  (meContact!.phone?.contains(q) ?? false));

          // Limit displayed items for performance (avoid building 500+ widgets)
          // When searching, show all results; otherwise cap at limit
          final displayTeam = q.isNotEmpty
              ? filteredTeam
              : filteredTeam.length > teamDisplayLimit
              ? filteredTeam.sublist(0, teamDisplayLimit)
              : filteredTeam;
          final displayPhone = q.isNotEmpty
              ? filteredPhone
              : filteredPhone.length > phoneDisplayLimit
              ? filteredPhone.sublist(0, phoneDisplayLimit)
              : filteredPhone;

          Future<void> loadPhoneContacts() async {
            setModalState(() {
              isLoadingContacts = true;
              showPhoneContacts = true;
            });
            final contacts = await getPhoneContacts(
              forceRefresh: true,
            ); // Force refresh
            setModalState(() {
              phoneContacts = contacts;
              isLoadingContacts = false;
            });
          }

          return Container(
            height: MediaQuery.of(context).size.height * 0.75,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: AppTheme.headerGreen,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Handle bar
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.person_add, color: Colors.white),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Select Assignee',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Search bar
                      TextField(
                        controller: searchController,
                        decoration: InputDecoration(
                          hintText: 'Search name or phone...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white70,
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.15),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(color: Colors.white),
                        onChanged: (value) {
                          searchDebounce?.cancel();
                          searchDebounce = Timer(
                            const Duration(milliseconds: 150),
                            () {
                              setModalState(() {
                                searchQuery = value;
                              });
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // Content
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      // "Assign later": only offered by assignee pickers
                      // (creation), so a card can be saved with no assignee and
                      // picked up later from the "Assign later" filter.
                      if (allowUnassigned) ...[
                        ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFF868E96),
                            child: Icon(
                              Icons.person_off_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          title: const Text(
                            'Assign later',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          onTap: () => Navigator.pop(
                            ctx,
                            AssignableContact.unassigned(),
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                      // "Me" contact (always at top)
                      if (showMeContact) ...[
                        _buildSectionHeader(
                          'Assign to Yourself',
                          '',
                          icon: Icons.person_pin,
                          color: const Color(0xFF2196F3),
                        ),
                        _buildContactTile(
                          meContact!,
                          onTap: () => Navigator.pop(ctx, meContact),
                          isMeContact: true,
                        ),
                        const Divider(height: 1),
                      ],

                      // Recent Contacts section (at top)
                      if (!isLoadingRecents &&
                          recentContacts.isNotEmpty &&
                          searchQuery.isEmpty) ...[
                        _buildSectionHeader(
                          'Recent',
                          '${recentContacts.length} contacts',
                          icon: Icons.history,
                          color: const Color(0xFF6C5CE7),
                        ),
                        SizedBox(
                          height: 80,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: recentContacts.length,
                            itemBuilder: (context, index) {
                              final contact = recentContacts[index];
                              return _buildRecentContactChip(
                                contact,
                                onTap: () => Navigator.pop(ctx, contact),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                      ],

                      // Loading indicator for team members
                      if (isLoadingTeamMembers) ...[
                        const Padding(
                          padding: EdgeInsets.all(32.0),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                  color: AppTheme.headerGreen,
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'Loading contacts...',
                                  style: TextStyle(
                                    color: AppTheme.secondaryText,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ]
                      // Team Members section
                      else if (filteredTeam.isNotEmpty) ...[
                        _buildSectionHeader(
                          'Team Members',
                          '${filteredTeam.length} available',
                          icon: Icons.people,
                          color: AppTheme.headerGreen,
                        ),
                        ...displayTeam.map(
                          (contact) => _buildContactTile(
                            contact,
                            onTap: () => Navigator.pop(ctx, contact),
                          ),
                        ),
                        if (filteredTeam.length > teamDisplayLimit && q.isEmpty)
                          _buildShowMoreButton(
                            remaining: filteredTeam.length - teamDisplayLimit,
                            onTap: () => setModalState(() {
                              teamDisplayLimit += 50;
                            }),
                          ),
                      ],

                      // Phonebook section
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        color: AppTheme.lightGrey,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.contacts,
                              size: 20,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'From Phonebook',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.secondaryText,
                                ),
                              ),
                            ),
                            if (!showPhoneContacts || phoneContacts.isEmpty)
                              TextButton.icon(
                                icon: Icon(
                                  showPhoneContacts
                                      ? Icons.refresh
                                      : Icons.sync,
                                  size: 16,
                                  color: AppTheme.headerGreen,
                                ),
                                label: Text(
                                  showPhoneContacts
                                      ? 'Refresh'
                                      : 'Load Contacts',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.headerGreen,
                                  ),
                                ),
                                onPressed: () => loadPhoneContacts(),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      if (isLoadingContacts)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: AppTheme.headerGreen,
                            ),
                          ),
                        ),

                      if (showPhoneContacts && filteredPhone.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.contact_phone,
                                  size: 48,
                                  color: AppTheme.lightText,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  searchQuery.isEmpty
                                      ? 'No phone contacts found'
                                      : 'No matches for "$searchQuery"',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppTheme.lightText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      if (showPhoneContacts && filteredPhone.isNotEmpty) ...[
                        ...displayPhone.map(
                          (contact) => _buildContactTile(
                            contact,
                            onTap: () => Navigator.pop(ctx, contact),
                            onInvite: !contact.isOnApp
                                ? () => inviteContactViaSms(contact)
                                : null,
                          ),
                        ),
                        if (filteredPhone.length > phoneDisplayLimit &&
                            q.isEmpty)
                          _buildShowMoreButton(
                            remaining: filteredPhone.length - phoneDisplayLimit,
                            onTap: () => setModalState(() {
                              phoneDisplayLimit += 50;
                            }),
                          ),
                      ],

                      // Permission denied / manual entry option
                      const SizedBox(height: 8),
                      ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.headerGreen.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.edit,
                            size: 20,
                            color: AppTheme.headerGreen,
                          ),
                        ),
                        title: const Text(
                          'Type Manually',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Enter name and phone number directly',
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          final result = await _showManualEntryDialog(context);
                          if (result != null) {
                            // Use the result directly - pop the outer future
                            if (context.mounted) {
                              Navigator.maybePop(context, result);
                            }
                          }
                        },
                      ),

                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    // Save selected contact to recent contacts
    if (result != null) {
      await _saveToRecentContacts(result);
    }

    return result;
  }

  Widget _buildShowMoreButton({
    required int remaining,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.expand_more, size: 18, color: AppTheme.headerGreen),
            const SizedBox(width: 6),
            Text(
              'Show $remaining more',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.headerGreen,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    String subtitle, {
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: AppTheme.lightText),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentContactChip(
    AssignableContact contact, {
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Photo / preset avatar when the contact has one; initials tint
            AppAvatar(
              avatarUrl: contact.avatarUrl,
              initials: contact.name.isNotEmpty
                  ? contact.name[0].toUpperCase()
                  : '?',
              radius: 24,
              color: contact.isOnApp
                  ? AppTheme.headerGreen
                  : const Color(0xFF6C5CE7),
              fontSize: 16,
            ),
            const SizedBox(height: 4),
            Text(
              contact.name.split(' ').first, // First name only
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppTheme.primaryText,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactTile(
    AssignableContact contact, {
    required VoidCallback onTap,
    bool isMeContact = false,
    VoidCallback? onInvite,
  }) {
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          // Photo / preset avatar when the contact has one; initials tint
          AppAvatar(
            avatarUrl: contact.avatarUrl,
            initials: contact.name.isNotEmpty
                ? contact.name[0].toUpperCase()
                : '?',
            radius: 20,
            color: isMeContact
                ? const Color(0xFF2196F3)
                : contact.isOnApp
                ? AppTheme.headerGreen
                : Colors.grey,
            fontSize: 16,
          ),
          // Badge for "Me" contact
          if (isMeContact)
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: const Color(0xFF2196F3),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Icon(Icons.person, size: 8, color: Colors.white),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              isMeContact
                  ? 'Me'
                  : contact.name, // Show "Me" in UI, but store actual name
              style: TextStyle(
                fontSize: 15,
                fontWeight: isMeContact ? FontWeight.w700 : FontWeight.w500,
                color: isMeContact
                    ? const Color(0xFF2196F3)
                    : AppTheme.primaryText,
              ),
            ),
          ),
          // Premium crown for users on a premium plan
          if (PremiumStatusService().isPremium(
            uid: contact.uid,
            phone: contact.phone,
          ))
            const PremiumBadge(size: 14),
          // "ME" badge
          if (isMeContact)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2196F3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'ME',
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "On App" badge for matched phonebook contacts (Enhancement 2)
          if (!isMeContact && contact.isOnApp)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'On App',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.primaryGreen,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (contact.phone != null && contact.phone!.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.phone, size: 12, color: AppTheme.lightText),
                const SizedBox(width: 4),
                Text(
                  contact.phone!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.lightText,
                  ),
                ),
              ],
            ),
          ],
          if (contact.email != null && contact.email!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.email, size: 12, color: AppTheme.lightText),
                const SizedBox(width: 4),
                Text(
                  contact.email!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.lightText,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      trailing: isMeContact
          ? const Icon(Icons.how_to_reg, size: 20, color: Color(0xFF2196F3))
          : contact.isOnApp
          ? const Icon(
              Icons.check_circle,
              size: 20,
              color: AppTheme.primaryGreen,
            )
          : onInvite != null
          ? InkWell(
              onTap: onInvite,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.send, size: 14, color: AppTheme.headerGreen),
                    SizedBox(width: 3),
                    Text(
                      'Invite',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.headerGreen,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const Icon(Icons.sms, size: 20, color: AppTheme.lightText),
      onTap: onTap,
    );
  }

  /// Manual entry dialog for typing name + phone directly
  Future<AssignableContact?> _showManualEntryDialog(
    BuildContext context,
  ) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    return showDialog<AssignableContact>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.person_add, color: AppTheme.headerGreen),
            SizedBox(width: 8),
            Text('Add Contact', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'Enter contact name',
                prefixIcon: const Icon(
                  Icons.person,
                  color: AppTheme.secondaryText,
                ),
                filled: true,
                fillColor: AppTheme.lightGrey,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneController,
              decoration: InputDecoration(
                labelText: 'Phone Number',
                hintText: '9876543210',
                prefixIcon: const Icon(
                  Icons.phone,
                  color: AppTheme.secondaryText,
                ),
                filled: true,
                fillColor: AppTheme.lightGrey,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              keyboardType: TextInputType.phone,
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
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(
                ctx,
                AssignableContact(
                  name: name,
                  phone: phoneController.text.trim().isNotEmpty
                      ? phoneController.text.trim()
                      : null,
                  isOnApp: false,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.headerGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
