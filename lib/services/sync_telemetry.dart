import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Severity of a metric — drives the color coding in the diagnostics UI.
/// [ok] green, [warn] amber, [crit] red. Thresholds are heuristics tuned for
/// this app's local-first workload; they flag "worth a look", not hard limits.
enum TelSeverity { ok, warn, crit }

/// Timing + volume stats for one measured SQLite operation.
class OpStat {
  int count = 0;
  int lastMs = 0;
  int maxMs = 0;
  int totalMs = 0;
  int lastRows = 0;
  int maxRows = 0;

  int get avgMs => count == 0 ? 0 : totalMs ~/ count;

  void add(int ms, int rows) {
    count++;
    lastMs = ms;
    totalMs += ms;
    if (ms > maxMs) maxMs = ms;
    lastRows = rows;
    if (rows > maxRows) maxRows = rows;
  }

  void reset() {
    count = 0;
    lastMs = 0;
    maxMs = 0;
    totalMs = 0;
    lastRows = 0;
    maxRows = 0;
  }
}

/// Firestore delivery stats for one listener key (e.g. `messages_<taskId>`,
/// `tasks_byCreator_<uid>`). [initialDocs] is the attach cost — the full result
/// set Firestore bills when a listener is (re)created; [deltaDocs] is the
/// per-event cost afterwards. A large [maxInitialDocs] on a chat listener is the
/// signature of the unbounded full-conversation read.
class ListenerStat {
  int attaches = 0;
  int emissions = 0;
  int initialDocs = 0;
  int deltaDocs = 0;
  int maxInitialDocs = 0;

  int get totalDocs => initialDocs + deltaDocs;

  void reset() {
    attaches = 0;
    emissions = 0;
    initialDocs = 0;
    deltaDocs = 0;
    maxInitialDocs = 0;
  }
}

/// App-local performance / load telemetry for SQLite, sync and Firestore.
///
/// Purely observational: it never changes sync, read or write behaviour. Every
/// recorder short-circuits on a single boolean when [enabled] is false, so the
/// cost in production (locked + disabled) is negligible and there are no
/// hot-path prints. The diagnostics UI *polls* this singleton on a 1s timer
/// rather than listening, so recording never triggers a widget rebuild.
///
/// Instrumented at the SHARED layers — [FirebaseService] and
/// [LocalDatabaseService] plus the two provider families — so one implementation
/// reports Task, Sales and CRM together.
class SyncTelemetry {
  SyncTelemetry._();

  static final SyncTelemetry instance = SyncTelemetry._();

  static const _kUnlocked = 'diag_unlocked';
  static const _kEnabled = 'diag_enabled';
  static const _kBadge = 'diag_badge_visible';

  /// Hidden toggle discovered (tap the Settings version row 5x). Persisted.
  bool unlocked = false;

  /// Actively recording. Persisted so a tester enables it once.
  bool enabled = false;

  /// Floating badge shown over the app. Persisted. [badgeNotifier] mirrors this
  /// so the app-root [ValueListenableBuilder] can mount/unmount reactively.
  bool badgeVisible = false;
  final ValueNotifier<bool> badgeNotifier = ValueNotifier<bool>(false);

  // ── Firestore load ──────────────────────────────────────────────────
  int fsWrites = 0;
  int activeListeners = 0;
  final Map<String, ListenerStat> listeners = <String, ListenerStat>{};

  // ── SQLite ops ──────────────────────────────────────────────────────
  final Map<String, OpStat> db = <String, OpStat>{};

  // ── Provider / sync churn ───────────────────────────────────────────
  int reloadInvoked = 0;
  int reloadExecuted = 0;
  int reloadCoalesced = 0;
  int notifyCount = 0;
  int changeSetPatch = 0;
  int changeSetFullReload = 0;

  DateTime startedAt = DateTime.now();

  // ── Derived totals / rates ──────────────────────────────────────────
  int get fsReads {
    var t = 0;
    for (final s in listeners.values) {
      t += s.totalDocs;
    }
    return t;
  }

  int get elapsedSeconds {
    final s = DateTime.now().difference(startedAt).inSeconds;
    return s < 1 ? 1 : s;
  }

  double get readsPerMin => fsReads * 60.0 / elapsedSeconds;
  double get writesPerMin => fsWrites * 60.0 / elapsedSeconds;
  double get notifiesPerMin => notifyCount * 60.0 / elapsedSeconds;
  double get reloadsPerMin => reloadExecuted * 60.0 / elapsedSeconds;

  // ── Recording hooks (all no-op when disabled) ───────────────────────

  /// Start a gate for a timed section. Returns null when disabled so callers
  /// allocate nothing on the hot path.
  Stopwatch? startTimer() => enabled ? (Stopwatch()..start()) : null;

  /// Record a SQLite op duration + row count.
  void recordDb(String op, Stopwatch? w, int rows) {
    if (!enabled || w == null) return;
    db.putIfAbsent(op, OpStat.new).add(w.elapsedMilliseconds, rows);
  }

  /// Record one Firestore listener emission. [isFirst] sizes the attach read
  /// (full result set); later emissions only bill the changed docs.
  void recordEmission(
    String key,
    int snapshotDocs,
    int changedDocs,
    bool isFirst,
  ) {
    if (!enabled) return;
    final s = listeners.putIfAbsent(key, ListenerStat.new);
    s.emissions++;
    if (isFirst) {
      s.initialDocs += snapshotDocs;
      if (snapshotDocs > s.maxInitialDocs) s.maxInitialDocs = snapshotDocs;
    } else {
      s.deltaDocs += changedDocs;
    }
  }

  /// Record that a listener was actually created (a re-attach = a fresh read).
  void recordAttach(String key) {
    if (!enabled) return;
    listeners.putIfAbsent(key, ListenerStat.new).attaches++;
  }

  void recordWrite([int n = 1]) {
    if (enabled) fsWrites += n;
  }

  void setActiveListeners(int n) {
    if (enabled) activeListeners = n;
  }

  void recordReloadInvoked() {
    if (enabled) reloadInvoked++;
  }

  void recordReloadExecuted() {
    if (enabled) reloadExecuted++;
  }

  void recordReloadCoalesced() {
    if (enabled) reloadCoalesced++;
  }

  void recordNotify() {
    if (enabled) notifyCount++;
  }

  void recordChangeSetPatch(int rows) {
    if (enabled) changeSetPatch += rows;
  }

  void recordChangeSetFullReload() {
    if (enabled) changeSetFullReload++;
  }

  // ── Severity (color coding) ─────────────────────────────────────────

  // avg-ms thresholds per SQLite op: [warn, crit]. Anything unlisted falls back
  // to the default pair.
  static const Map<String, List<int>> _dbThresholds = {
    'getTasks': [40, 100],
    'getModuleEnquiries': [40, 100],
    'getMessages': [20, 60],
    'saveMessages': [50, 150],
    'saveTasks': [50, 150],
    'saveModuleEnquiries': [50, 150],
  };
  static const List<int> _dbDefault = [50, 150];

  TelSeverity severityDb(String op) {
    final s = db[op];
    if (s == null || s.count == 0) return TelSeverity.ok;
    final t = _dbThresholds[op] ?? _dbDefault;
    if (s.avgMs > t[1]) return TelSeverity.crit;
    if (s.avgMs > t[0]) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  /// A listener whose attach delivered a big result set (the unbounded message
  /// conversation read) is the main Firestore-read cost.
  TelSeverity severityListener(ListenerStat s) {
    if (s.maxInitialDocs > 400) return TelSeverity.crit;
    if (s.maxInitialDocs > 150) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  TelSeverity get severityActiveListeners {
    if (activeListeners > 16) return TelSeverity.crit;
    if (activeListeners > 10) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  TelSeverity get severityNotifyRate {
    if (notifiesPerMin > 180) return TelSeverity.crit;
    if (notifiesPerMin > 90) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  TelSeverity get severityReloadRate {
    if (reloadsPerMin > 120) return TelSeverity.crit;
    if (reloadsPerMin > 60) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  TelSeverity get severityWriteRate {
    if (writesPerMin > 150) return TelSeverity.crit;
    if (writesPerMin > 60) return TelSeverity.warn;
    return TelSeverity.ok;
  }

  /// Worst severity across every tracked metric — used to color the badge edge.
  TelSeverity worstSeverity() {
    var w = TelSeverity.ok;
    void bump(TelSeverity s) {
      if (s.index > w.index) w = s;
    }

    for (final op in db.keys) {
      bump(severityDb(op));
    }
    for (final s in listeners.values) {
      bump(severityListener(s));
    }
    bump(severityActiveListeners);
    bump(severityNotifyRate);
    bump(severityReloadRate);
    bump(severityWriteRate);
    return w;
  }

  // ── Lifecycle / persistence ─────────────────────────────────────────

  void reset() {
    fsWrites = 0;
    activeListeners = 0;
    for (final s in listeners.values) {
      s.reset();
    }
    listeners.clear();
    for (final s in db.values) {
      s.reset();
    }
    db.clear();
    reloadInvoked = 0;
    reloadExecuted = 0;
    reloadCoalesced = 0;
    notifyCount = 0;
    changeSetPatch = 0;
    changeSetFullReload = 0;
    startedAt = DateTime.now();
  }

  /// Restore the persisted toggle state at startup (before runApp).
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    unlocked = p.getBool(_kUnlocked) ?? false;
    enabled = p.getBool(_kEnabled) ?? false;
    badgeVisible = p.getBool(_kBadge) ?? false;
    badgeNotifier.value = enabled && badgeVisible;
    if (enabled) startedAt = DateTime.now();
  }

  Future<void> setUnlocked(bool v) async {
    unlocked = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kUnlocked, v);
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    if (v) startedAt = DateTime.now();
    badgeNotifier.value = v && badgeVisible;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  Future<void> setBadgeVisible(bool v) async {
    badgeVisible = v;
    badgeNotifier.value = enabled && v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBadge, v);
  }
}
