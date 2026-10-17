import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user.dart';

/// In-memory cache of the CURRENT user's per-module subscription tiers
/// (`users/{uid}.modulePlans`) so paywall gates resolve a plan synchronously
/// instead of awaiting a Firestore `users` read on every create.
///
/// Served optimistically: [planFor] returns the cached tier immediately and
/// fires a throttled background refresh that converges the cache to the server.
/// There is no in-app purchase flow — `modulePlans` is written only by the
/// billing webhook (Admin SDK) — so this background refresh is the only
/// mid-session path that picks up an external purchase or an expiry without a
/// full restart.
///
/// The cache is hydrated for free from [AuthProvider]'s existing profile fetch
/// ([hydrate]), so it is already warm before the user can create anything and
/// the cold-cache fallback only applies on a truly cold/offline start. This
/// keeps the SQLite-first write path free of blocking network reads (design
/// rule R2: Firestore is never awaited by the UI).
class ModulePlanCache {
  static final ModulePlanCache _instance = ModulePlanCache._internal();
  factory ModulePlanCache() => _instance;
  ModulePlanCache._internal();

  /// Minimum gap between background refreshes so a burst of creates can't fan
  /// out into many `users` reads.
  static const Duration _refreshThrottle = Duration(minutes: 2);

  String _uid = '';
  Map<String, Map<String, dynamic>> _modulePlans = const {};

  /// True once [_modulePlans] reflects a real read/hydrate for [_uid]. A cold
  /// cache (never fetched) is distinguished from a warm-but-empty one (user
  /// genuinely has no module subscriptions) so gating stays fail-closed.
  bool _warm = false;
  DateTime? _lastRefresh;
  Future<void>? _inFlight;

  /// Warm the cache from an already-fetched profile — no extra Firestore read.
  /// Called by AuthProvider whenever the user doc lands. A null [modulePlans]
  /// (sign-out) clears the cache.
  void hydrate(String uid, Map<String, Map<String, dynamic>>? modulePlans) {
    if (uid.isEmpty || modulePlans == null) {
      clear();
      return;
    }
    _uid = uid;
    _modulePlans = modulePlans;
    _warm = true;
    _lastRefresh = DateTime.now();
  }

  /// Drop the cache (sign-out / account switch).
  void clear() {
    _uid = '';
    _modulePlans = const {};
    _warm = false;
    _lastRefresh = null;
    _inFlight = null;
  }

  /// The effective plan gating [module] ('task' | 'sale' | 'crm' | ...),
  /// served from cache without blocking. Always kicks a throttled background
  /// refresh so the value converges to the server.
  ///
  /// [fallback] is the tier older call sites already resolved from AuthProvider;
  /// it is returned only while the cache is cold (first create before any
  /// profile read, or offline) — mirroring the old failed-read branch so gating
  /// never hard-blocks on a missing cache and stays fail-closed to 'basic'.
  String? planFor(String uid, String module, {String? fallback}) {
    if (uid.isEmpty) return fallback;
    if (uid != _uid) {
      // Account switch: the previous user's tiers must not leak into this one.
      _uid = uid;
      _modulePlans = const {};
      _warm = false;
      _lastRefresh = null;
    }
    unawaited(refresh(uid));
    if (!_warm) {
      return (fallback != null && fallback.isNotEmpty) ? fallback : 'basic';
    }
    return _effectiveFor(module);
  }

  /// Resolve the plan gating ONE module ('task' | 'sale' | 'crm' | ...) for the
  /// signed-in user, served from the cache without blocking the SQLite-first
  /// write path. [planType] (the tier callers already resolved from AuthProvider)
  /// is the fallback while the cache is cold or the user is signed out. Shared by
  /// TaskProvider and BaseModuleProvider so every module gates identically;
  /// reading `currentUser.uid` is synchronous/local, so this honors rule R2.
  static Future<String?> effectivePlanForModule(
    String? planType,
    String module,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return planType;
    return ModulePlanCache().planFor(uid, module, fallback: planType);
  }

  /// Pull `users/{uid}.modulePlans` into the cache. Throttled and
  /// de-duplicated so concurrent callers share a single read.
  Future<void> refresh(String uid) async {
    if (uid.isEmpty) return;
    final now = DateTime.now();
    if (_warm &&
        _uid == uid &&
        _lastRefresh != null &&
        now.difference(_lastRefresh!) < _refreshThrottle) {
      return; // Fresh enough — skip the read.
    }
    final pending = _inFlight;
    if (pending != null) return pending; // Coalesce concurrent refreshes.

    final future = _fetch(uid);
    _inFlight = future;
    try {
      await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _fetch(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      // Guard against an account switch mid-read.
      if (_uid != uid) return;
      final data = snap.data();
      if (data == null) return; // No profile doc — stay as we are.
      // Reuse the model's tolerant parser (handles missing/malformed entries).
      _modulePlans = UserModel.fromMap(data, uid).modulePlans;
      _warm = true;
      _lastRefresh = DateTime.now();
    } catch (e) {
      debugPrint('[ModulePlanCache] background refresh failed: $e');
      // Keep the previous cache intact and do NOT stamp _lastRefresh, so the
      // next call retries sooner. Stays cold if it was never warm.
    }
  }

  /// Same resolution as [UserModel.effectivePlanTypeFor]: a module with no
  /// subscription, or one whose `expiryDate` has passed, reads 'basic'.
  String _effectiveFor(String module) {
    final entry = _modulePlans[module];
    if (entry != null) {
      final expiry = (entry['expiryDate'] as Timestamp?)?.toDate();
      if (expiry != null && expiry.isAfter(DateTime.now())) {
        final p = (entry['planType'] as String? ?? '').trim().toLowerCase();
        if (p == 'free') return 'basic';
        const valid = {'basic', 'premium', 'business', 'enterprise'};
        if (valid.contains(p)) return p;
      }
    }
    return 'basic';
  }
}
