import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
// Only FirebaseAuth is needed here; hide Firebase's own AuthProvider so it
// can't collide with the app's providers/auth_provider.dart AuthProvider.
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:provider/provider.dart';
import 'config/firebase_options.dart';
import 'providers/auth_provider.dart';
import 'providers/task_provider.dart';
import 'providers/organization_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/app_lock_controller.dart';
import 'services/notification_service.dart';
import 'services/notification_tap.dart';
import 'services/business_vocabulary.dart';
import 'services/local_database_service.dart';
import 'services/local_storage_service.dart';
import 'services/startup_trace.dart';
import 'services/upload_retry_service.dart';
import 'services/backup_service.dart';
import 'services/sync_telemetry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'modules/sales/providers/sales_provider.dart';
import 'modules/crm/providers/crm_provider.dart';
import 'modules/shared/recurrence_service.dart';
import 'modules/sales/services/milestone_settings_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/lock_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/settings/diagnostics_screen.dart';
import 'widgets/diagnostics/diagnostics_badge.dart';
import 'utils/constants.dart';

/// Background/terminated FCM handler. The message-push Cloud Function sends a
/// notification payload, so the OS renders the alert automatically; this
/// top-level entry point just satisfies the plugin contract.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No-op: notification payloads are shown by the system in the background.
}

/// Root navigator key so the app-root diagnostics badge — mounted ABOVE the
/// Navigator in [MaterialApp.builder], so it has no Navigator ancestor — can
/// still push the diagnostics panel.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // Chronological startup diagnostic — armed FIRST so every launch operation
  // inside the window is timestamped. Purely observational (see StartupTrace).
  StartupTrace.instance.init();

  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (required for production)
  final tFirebase = StartupTrace.instance.begin(
    'Firebase.initializeApp',
    kind: StartupTraceKind.job,
  );
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  StartupTrace.instance.end(tFirebase);

  // Register the background handler for message pushes received while the app
  // is terminated/backgrounded (must be set right after Firebase init).
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Configure Firestore for unlimited persistent cache.
  // SQLite is the permanent store; the Firestore cache only exists to feed
  // listener deltas, so bound it at 50 MB instead of UNLIMITED. Eviction is
  // safe: upsert tables (tasks/messages/enquiries) keep everything in SQLite,
  // and the replace-and-delete tables (system_logs/milestones) derive from
  // server snapshots regardless of cache state.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 50 * 1024 * 1024,
  );

  // Defer FCM init well past the first frames — requestPermission shows a
  // MODAL system dialog that swallows every tap, so firing it right after
  // the first frame made the app feel frozen. 6s keeps it clear of the
  // initial task load (t=0) and the Firestore sync burst (t=5s).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 6), () {
      StartupTrace.instance.instant(
        'job: FCM init',
        StartupTraceKind.job,
      );
      NotificationService().initialize();
    });
  });

  // NOTE: Contact pre-load happens post-auth in HomeScreen.initState —
  // doing it here too deserialized the whole phonebook twice at startup.

  // Backfill actions table from existing messages (one-time migration).
  // Deferred: when the actions table is empty this scans the ENTIRE messages
  // table on the UI isolate — must not compete with startup.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 9), () {
      StartupTrace.instance.instant(
        'job: actions backfill',
        StartupTraceKind.job,
      );
      _backfillActionsIfNeeded();
    });
  });

  // Storage hygiene, deferred behind every startup-critical job (t=0 SQLite
  // paint, t=5s sync arm, t=6s FCM, t=9s actions backfill): sweep the app's
  // own leftovers out of the cache dir and cap the durable action log.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 12), () {
      StartupTrace.instance.instant(
        'job: storage hygiene',
        StartupTraceKind.job,
      );
      _runStorageHygiene();
    });
  });

  // Idle prewarm of the shared list-snapshot cache, deferred PAST the t=5s
  // Firestore sync burst so it warms the post-sync state (a sync write bumps
  // the table revision and would invalidate anything cached earlier). Runs at
  // Priority.idle so it yields to every UI frame; a no-op when signed out.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 15), () {
      StartupTrace.instance.instant(
        'job: list-snapshot prewarm',
        StartupTraceKind.job,
      );
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return;
      SchedulerBinding.instance.scheduleTask(
        () => LocalDatabaseService().prewarmListSnapshots(uid),
        Priority.idle,
      );
    });
  });

  // Start background retry for pending uploads
  UploadRetryService().startPeriodicRetry();

  // Warm the milestone enable-flag cache so list cards can render the M0/M1
  // chip synchronously on the first frame (flag is checked in Tools settings).
  for (final module in ['task', 'sales', 'crm']) {
    MilestoneSettingsService(module: module).warmCache();
  }

  final tVocab = StartupTrace.instance.begin(
    'BusinessVocabulary.load',
    kind: StartupTraceKind.job,
  );
  // Only activate a persisted sector when the feature is enabled. With the
  // master switch off, `_current` stays null so every label getter resolves
  // to the built-in defaults — the app runs in "General" mode.
  if (kSectorTemplatesEnabled) {
    await BusinessVocabulary.load();
  }
  StartupTrace.instance.end(tVocab);

  // Restore the hidden diagnostics toggle state (persisted) before the first
  // frame, so the floating badge can mount immediately if a tester left it on.
  final tTel = StartupTrace.instance.begin(
    'SyncTelemetry.load',
    kind: StartupTraceKind.job,
  );
  await SyncTelemetry.instance.load();
  StartupTrace.instance.end(tTel);

  StartupTrace.instance.instant('runApp', StartupTraceKind.job);
  runApp(const WhatWorksApp());
}

/// Backfill actions table from existing messages if empty.
/// Guarded by a SharedPreferences flag so a legitimately-empty actions table
/// (e.g. no action messages yet) never re-scans all messages on every launch.
void _backfillActionsIfNeeded() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('actions_backfill_done') ?? false) return;

    final db = LocalDatabaseService();
    // Cheap emptiness check — avoid loading every action row at startup
    final actionCount = await db.getActionCount();
    if (actionCount > 0) {
      await prefs.setBool('actions_backfill_done', true);
      return; // Already populated
    }

    // Fresh install: messages haven't synced down yet — do NOT latch the
    // flag on an empty DB, or the backfill can never index messages that
    // arrive later through non-write-through routes (bug: icons missing
    // after the com.whatworks.app side-by-side install).
    final messageCount = await db.getTotalMessageCount();
    if (messageCount == 0) return;

    debugPrint('[Migration] Actions table empty, backfilling from messages...');
    final count = await db.backfillActionsFromMessages();
    debugPrint('[Migration] Backfilled $count actions from messages');
    await prefs.setBool('actions_backfill_done', true);
  } catch (e) {
    debugPrint('[Migration] Error backfilling actions: $e');
  }
}

/// Cache-dir sweep + system_logs retention prune.
///
/// The temp sweep is cheap (stat a handful of files) and runs every launch —
/// without it the voice/share/screenshot/export files the app writes into the
/// system cache dir are never reclaimed and Android's "Cache" line only grows.
/// The DB prune is gated on a daily stamp: it walks system_logs and can free
/// enough pages to trigger a VACUUM (handled inside the DB layer), which is far
/// too heavy to pay for on every launch.
void _runStorageHygiene() async {
  try {
    await LocalStorageService().pruneStaleTempFiles();

    final prefs = await SharedPreferences.getInstance();
    const stampKey = 'db_hygiene_last_run_ms';
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastRun = prefs.getInt(stampKey) ?? 0;
    if (now - lastRun < const Duration(days: 1).inMilliseconds) return;

    await LocalDatabaseService().pruneSystemLogs();
    // Stamped only after the prune succeeds, so a failed run retries next
    // launch instead of silently skipping a day.
    await prefs.setInt(stampKey, now);
  } catch (e) {
    debugPrint('[Hygiene] Error running storage hygiene: $e');
  }
}

class WhatWorksApp extends StatefulWidget {
  const WhatWorksApp({super.key});

  @override
  State<WhatWorksApp> createState() => _WhatWorksAppState();
}

class _WhatWorksAppState extends State<WhatWorksApp>
    with WidgetsBindingObserver {
  final ThemeProvider _themeProvider = ThemeProvider();
  final AppLockController _lockController = AppLockController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Own the deep-link plumbing here at the app root: this State is always
    // alive for the app's lifetime (module homes are pushReplacement-ed over
    // it, so a Home-owned listener would be disposed before it could drain a
    // cold-start tap). Give NotificationTap the root navigator and drain any
    // parked notification the moment FCM's getInitialMessage queues one.
    NotificationTap.navKey = rootNavigatorKey;
    NotificationTap.pending.addListener(_onPendingNotification);
    // Theme now always follows the device (see ThemeProvider) — nothing to load.
    _lockController.load();
    // NOTE: no auto-backup work of ANY kind on the launch path. A +20s due-check
    // used to run here, but that check scans every backup table and froze the
    // app for seconds — and the launch path is precisely when the user is
    // looking. Backups now run only from didChangeAppLifecycleState below.
    // Recurrence materialization (Phase-2A), owned here at the app root for the
    // same reason as the backup trigger: Sales/CRM homes are pushed via
    // pushReplacement, so a module-owned timer would be disposed before it
    // fires. Time-driven and deferred past the startup critical path (+18s,
    // after the sync arm and prewarm). It generates only near-term occurrences
    // for due series and is a complete no-op when no recurrence exists (the
    // indexed nextDue query returns zero rows), so it costs a user who never
    // creates a recurring item nothing beyond one empty index-backed query.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 18), _runRecurrenceMaterialization);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationTap.pending.removeListener(_onPendingNotification);
    super.dispose();
  }

  /// Open the chat a notification was tapped from (queued at cold start).
  void _onPendingNotification() => NotificationTap.drain();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Arm the lock whenever the app leaves the foreground so the next resume
    // requires the PIN again.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _lockController.markBackgrounded();
    }
    // Auto-backup runs ONLY here — when the app is not in use. The gate costs
    // three pref reads until the interval has actually elapsed, so an ordinary
    // backgrounding touches nothing; only a due run pays for the table scan and
    // the export. Enabling auto-backup in Settings IS the consent, so there is
    // no prompt and no launch-path check. Gated on a signed-in user so a
    // logged-out background never stamps auto_backup_last_run. Skipped on
    // `detached` — the process is already being killed, so a heavy export could
    // not finish; an interrupted run stamps nothing and retries next time.
    if (state == AppLifecycleState.paused &&
        FirebaseAuth.instance.currentUser != null) {
      BackupService().runAutoBackupIfDue();
    }
  }

  /// Generate near-term occurrences for any due recurring series (Phase-2A).
  /// Runs at Priority.idle so it yields to UI frames. Each occurrence is
  /// created through the owning module's EXISTING create path with an explicit,
  /// deterministic id (`rec_<seriesId>_<yyyy-MM-dd>`), so repeated runs,
  /// restarts and multiple devices converge on the same row/doc instead of
  /// duplicating — and every occurrence inherits milestone templates, deadline
  /// reminders, SQLite-first persistence and the Firestore relay for free. A
  /// create that returns null (transient failure) is rethrown so the engine
  /// does NOT advance past it and retries on the next run. No-op when signed
  /// out, when the root context is gone, or when no series are due.
  void _runRecurrenceMaterialization() async {
    try {
      if (!mounted) return;
      if (FirebaseAuth.instance.currentUser == null) return;
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null) return;

      final db = LocalDatabaseService();
      final taskProvider = Provider.of<TaskProvider>(ctx, listen: false);
      final salesProvider = Provider.of<SalesProvider>(ctx, listen: false);
      final crmProvider = Provider.of<CrmProvider>(ctx, listen: false);

      await SchedulerBinding.instance.scheduleTask(
        () async {
          // Phase-2B: converge any LEGACY completion-driven Task recurrence
          // (extraFields['recurrence']) onto the time-driven column BEFORE
          // materializing, so freshly-migrated anchors generate occurrences in
          // the same pass. Bounded + idempotent; a no-op once nothing legacy
          // remains (the candidate query returns zero rows).
          await RecurrenceService.instance.migrateLegacyTaskRecurrence(
            limit: 100,
          );
          return RecurrenceService.instance.materializeAll(
            task: (row) async {
              final id = row['id'] as String;
              final created = await taskProvider.createTask(
                db.taskFromRow(row),
                explicitId: id,
              );
              if (created == null) throw StateError('createTask failed: $id');
            },
            sales: (row) async {
              final id = row['id'] as String;
              final created = await salesProvider.createEnquiry(
                db.enquiryFromRow(row),
                explicitId: id,
              );
              if (created == null) throw StateError('createEnquiry failed: $id');
            },
            crm: (row) async {
              final id = row['id'] as String;
              final created = await crmProvider.createEnquiry(
                db.enquiryFromRow(row),
                explicitId: id,
              );
              if (created == null) throw StateError('createEnquiry failed: $id');
            },
          );
        },
        Priority.idle,
      );
    } catch (e) {
      debugPrint('[Recurrence] Materialization error: $e');
    }
  }

  /// Open the diagnostics panel from the floating badge. The badge is mounted
  /// above the Navigator, so it has no Navigator ancestor — push through the
  /// root [rootNavigatorKey] instead.
  void _openDiagnostics() {
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => SalesProvider()),
        ChangeNotifierProvider(create: (_) => CrmProvider()),
        ChangeNotifierProvider(create: (_) => OrganizationProvider()),
        ChangeNotifierProvider.value(value: _themeProvider),
        ChangeNotifierProvider.value(value: _lockController),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) => MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: theme.themeMode,
          navigatorKey: rootNavigatorKey,
          // Gate lives in `builder` so the lock overlays the ENTIRE Navigator
          // (every pushed route, dialog and sheet), not just the home route.
          // The diagnostics badge rides alongside it — above the Navigator so
          // it floats over every route — and only mounts when a tester has
          // enabled it (badgeNotifier = enabled && badgeVisible).
          builder: (context, child) => Stack(
            children: [
              Positioned.fill(
                child: _AppLockGate(child: child ?? const SizedBox.shrink()),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: SyncTelemetry.instance.badgeNotifier,
                builder: (context, show, _) => show
                    ? DiagnosticsBadge(onOpen: _openDiagnostics)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          home: const AuthenticationWrapper(),
        ),
      ),
    );
  }
}

/// Overlays the [LockScreen] whenever the app-lock is armed, otherwise shows
/// [child]. The underlying tree stays alive so unlocking is instant.
class _AppLockGate extends StatelessWidget {
  final Widget child;
  const _AppLockGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppLockController>();
    // Until the stored enabled-state is known, keep the app hidden behind a
    // blank surface so private content can't flash on a cold start. Users with
    // no PIN see only this brief blank frame, never the keypad.
    if (!controller.isReady) {
      return const ColoredBox(color: Colors.black);
    }
    return Stack(
      children: [
        child,
        if (controller.isLocked) const LockScreen(),
      ],
    );
  }
}

class AuthenticationWrapper extends StatelessWidget {
  const AuthenticationWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    // Check if user is authenticated
    if (authProvider.isAuthenticated) {
      return const HomeScreen();
    } else {
      return const LoginScreen();
    }
  }
}
