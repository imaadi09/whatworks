import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/user.dart';
import '../utils/helpers.dart';
import 'local_database_service.dart';

/// In-memory avatarUrl lookup so cards and pickers can resolve the shown
/// person's avatar synchronously during build (photos + preset avatars).
///
/// Populated from three sources, mirroring [PremiumStatusService]:
/// - SQLite users cache at startup ([ensureLoaded]) so avatars work offline
/// - SQLite nickname index at startup, so cards resolve a leader's photo by
///   local contact name instantly instead of waiting on the contacts reload
/// - Fresh Firestore user list on every contact sync ([updateFromUsers])
///
/// Exposed as a [ChangeNotifier] so the list cards (TaskCard/SalesCard) can
/// repaint the moment an index fill resolves an avatar they were showing as
/// initials — instead of waiting for the next scroll-driven rebuild.
class AvatarCacheService extends ChangeNotifier {
  static final AvatarCacheService _instance = AvatarCacheService._internal();
  factory AvatarCacheService() => _instance;
  AvatarCacheService._internal();

  final Map<String, String> _byUid = {};
  final Map<String, String> _byPhone = {};
  final Map<String, String> _byName = {}; // lowercase PROFILE name key
  // lowercase phonebook NICKNAME -> in-app avatar url. A task often stores the
  // local contact name ("Sonu") rather than the person's app profile name, so
  // the profile-name map misses it. ContactPickerService fills this off the UI
  // path after a contact sync, letting cards resolve the leader's photo by
  // nickname with a plain O(1) lookup instead of scanning contacts per build.
  final Map<String, String> _byNickname = {};
  bool _loaded = false;

  // Network avatar urls already handed to CachedNetworkImage this session, so
  // the post-sync warm never re-resolves the same photo. Bounded to keep the
  // set from growing without limit on very large teams.
  final Set<String> _warmed = {};
  static const int _warmCap = 150;

  /// Load avatar maps from the SQLite users + nickname caches (once per
  /// session). Safe to call repeatedly — subsequent calls are no-ops.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    var changed = false;
    try {
      final rows = await LocalDatabaseService().getCachedUserAvatars();
      for (final row in rows) {
        final url = (row['avatarUrl'] as String?)?.trim() ?? '';
        if (url.isEmpty) continue;
        _index(
          uid: row['uid'] as String?,
          phone: row['phone'] as String?,
          name: row['name'] as String?,
          url: url,
        );
        changed = true;
      }
    } catch (e) {
      print('[AvatarCache] Failed to load cached avatars: $e');
    }
    // Restore the persisted phonebook-nickname index so a legacy group task
    // stored under a local name ("Sonu") resolves its photo on the very first
    // build — before contacts re-hydrate and rebuild it off the UI path.
    try {
      final nicks = await LocalDatabaseService().getCachedAvatarNicknames();
      for (final row in nicks) {
        final name = (row['name'] as String?)?.trim().toLowerCase() ?? '';
        final url = (row['avatarUrl'] as String?)?.trim() ?? '';
        if (name.isEmpty || url.isEmpty) continue;
        _byNickname[name] = url;
        changed = true;
      }
    } catch (e) {
      print('[AvatarCache] Failed to load nickname index: $e');
    }
    // Cards that already painted as initials can now resolve; repaint them.
    if (changed) notifyListeners();
  }

  /// Replace the avatar maps from a fresh full user list (contact sync).
  /// getAllUsers returns every user, so replace semantics are correct.
  void updateFromUsers(List<UserModel> users) {
    _loaded = true;
    _byUid.clear();
    _byPhone.clear();
    _byName.clear();
    for (final user in users) {
      final url = user.avatarUrl?.trim() ?? '';
      if (url.isEmpty) continue;
      _index(uid: user.uid, phone: user.phone, name: user.name, url: url);
    }
    // Fresh team-member urls — warm the disk cache for the frequent assignees
    // (people on cards) so their photos are already downloaded by first paint.
    _warmAll();
    notifyListeners();
  }

  void _index({String? uid, String? phone, String? name, required String url}) {
    final u = uid?.trim() ?? '';
    if (u.isNotEmpty) _byUid[u] = url;
    final p = Helpers.normalizePhone(phone) ?? '';
    if (p.isNotEmpty) _byPhone[p] = url;
    final n = name?.trim().toLowerCase() ?? '';
    if (n.isNotEmpty) _byName[n] = url;
  }

  /// Upsert a single user's avatar into the live maps (e.g. after the current
  /// user changes their own avatar) so every card/picker resolves the new
  /// value on the next build, without waiting for a contact sync. Passing an
  /// empty [url] removes any cached entries for that identity.
  void upsertUser({String? uid, String? phone, String? name, String? url}) {
    final u = (url ?? '').trim();
    if (u.isEmpty) {
      final uk = uid?.trim() ?? '';
      if (uk.isNotEmpty) _byUid.remove(uk);
      final pk = Helpers.normalizePhone(phone) ?? '';
      if (pk.isNotEmpty) _byPhone.remove(pk);
      final nk = name?.trim().toLowerCase() ?? '';
      if (nk.isNotEmpty) _byName.remove(nk);
      notifyListeners();
      return;
    }
    _index(uid: uid, phone: phone, name: name, url: u);
    notifyListeners();
  }

  /// Replace the phonebook-nickname index wholesale. Built off the UI path by
  /// [ContactPickerService] after a contact sync (each cached contact resolved
  /// once through [urlFor]), so a card can later resolve the leader's photo by
  /// the local name stored on a task without scanning contacts during build.
  /// The incoming [next] is the complete current set, so old entries are
  /// dropped. Persists the index for cold start, warms the newly-resolved
  /// photos and repaints cards that were showing initials.
  void applyNicknameIndex(Map<String, String> next) {
    _byNickname
      ..clear()
      ..addAll(next);
    _loaded = true;
    unawaited(_persistNicknames(next));
    _warmUrls(next.values);
    notifyListeners();
  }

  Future<void> _persistNicknames(Map<String, String> map) async {
    try {
      await LocalDatabaseService().replaceAvatarNicknames(map);
    } catch (e) {
      print('[AvatarCache] Failed to persist nickname index: $e');
    }
  }

  /// Warm the CachedNetworkImage disk cache for the current team-member urls
  /// (the people most likely on cards). Fire-and-forget; a bounded set so a
  /// large team never kicks off hundreds of downloads at once.
  void _warmAll() {
    _warmUrls(_byUid.values);
    _warmUrls(_byPhone.values);
  }

  void _warmUrls(Iterable<String> urls) {
    for (final url in urls) {
      if (_warmed.length >= _warmCap) return;
      if (url.isEmpty || !url.startsWith('http')) continue;
      if (!_warmed.add(url)) continue;
      try {
        // resolve() without a BuildContext still triggers the download + disk
        // cache; hold a listener so the fetch isn't dropped before it lands.
        final stream = CachedNetworkImageProvider(url).resolve(
          ImageConfiguration.empty,
        );
        stream.addListener(
          ImageStreamListener((_, __) {}, onError: (_, __) {}),
        );
      } catch (_) {
        // Warming is best-effort — never let it break the sync path.
      }
    }
  }

  /// The avatarUrl (photo URL or `avatar:<id>` preset) of the person
  /// identified by [uid] / [phone] / [name], or null if unknown.
  String? urlFor({String? uid, String? phone, String? name}) {
    final u = uid?.trim() ?? '';
    if (u.isNotEmpty) {
      final hit = _byUid[u];
      if (hit != null) return hit;
    }
    final p = Helpers.normalizePhone(phone) ?? '';
    if (p.isNotEmpty) {
      final hit = _byPhone[p];
      if (hit != null) return hit;
    }
    final n = name?.trim().toLowerCase() ?? '';
    if (n.isNotEmpty) {
      // Profile name first, then the phonebook nickname index.
      return _byName[n] ?? _byNickname[n];
    }
    return null;
  }
}
