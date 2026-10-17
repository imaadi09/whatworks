import 'package:flutter/material.dart';

import '../modules/sales/screens/sales_detail_screen.dart';
import '../modules/shared/module_config.dart';
import '../screens/task_detail/task_detail_screen.dart';
import 'local_database_service.dart';

/// Turns a tapped push/local notification into an in-app navigation to the
/// exact chat it came from (Task / Sales / CRM), auto-scrolling to the message.
///
/// The push Cloud Function already ships `data: {type, parentId, messageId}` on
/// every message + scheduled-call push, so this is purely a client-side resolver.
/// It is intentionally context-free: FCM tap callbacks fire outside the widget
/// tree, so navigation goes through [navKey] (the app's root navigator, wired
/// up once in `main.dart`) rather than a `BuildContext` that would pull
/// `main.dart` into an import cycle.
///
/// Cold start (app terminated → opened by tapping a notification) can deliver
/// the payload before Home is mounted, so a tap that cannot navigate yet is
/// parked on [pending] and drained by `HomeScreen` once it is ready.
class NotificationTap {
  NotificationTap._();

  /// Root navigator, set from `main.dart` after the MaterialApp is built.
  static GlobalKey<NavigatorState>? navKey;

  /// A resolved-but-not-yet-navigable tap, exposed so an already-mounted Home
  /// can drain it. `null` when nothing is waiting.
  static final ValueNotifier<Map<String, String>?> pending =
      ValueNotifier<Map<String, String>?>(null);

  /// Handle a tap that arrived while the app was already running: try to open
  /// immediately, and park it on [pending] if the navigator isn't ready yet.
  static void go(Map<String, String> data) {
    _open(data);
  }

  /// Park a tap discovered at cold start (getInitialMessage) for Home to drain.
  static void queue(Map<String, String> data) {
    if (data['parentId'] == null || data['parentId']!.isEmpty) return;
    pending.value = data;
  }

  /// Called by Home once it is mounted: navigate any parked tap, then clear it.
  static void drain() {
    final data = pending.value;
    if (data == null) return;
    if (_open(data)) pending.value = null;
  }

  /// Returns true when navigation was attempted with a resolvable route.
  static bool _open(Map<String, String> data) {
    final nav = navKey?.currentState;
    if (nav == null) return false;

    final type = data['type'] ?? '';
    final parentId = data['parentId'] ?? '';
    final messageId = (data['messageId']?.isEmpty ?? true)
        ? null
        : data['messageId'];
    if (parentId.isEmpty) return true; // nothing to open — treat as consumed

    switch (type) {
      case 'task':
        _openTask(nav, parentId, messageId);
        return true;
      case 'enquiry':
        _openEnquiry(nav, parentId, messageId, ModuleConfig.sales);
        return true;
      case 'crm':
        _openEnquiry(nav, parentId, messageId, ModuleConfig.crm);
        return true;
      default:
        return true; // unknown type — consume so it isn't retried forever
    }
  }

  static Future<void> _openTask(
    NavigatorState nav,
    String taskId,
    String? messageId,
  ) async {
    // SQLite is the permanent store, so the row is present even before the
    // Firestore delta-sync finishes on a cold open.
    final task = await LocalDatabaseService().getTaskById(taskId);
    if (task == null) return; // not on this device — leave the user on Home
    nav.push(
      MaterialPageRoute(
        builder: (_) => TaskDetailScreen(task: task, scrollToMessageId: messageId),
      ),
    );
  }

  static Future<void> _openEnquiry(
    NavigatorState nav,
    String enquiryId,
    String? messageId,
    ModuleConfig config,
  ) async {
    final enquiry = await LocalDatabaseService().getModuleEnquiryById(
      enquiryId,
      tableName: config.enquiriesTableName,
    );
    if (enquiry == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => SalesDetailScreen(
          enquiry: enquiry,
          moduleConfig: config,
          scrollToMessageId: messageId,
        ),
      ),
    );
  }
}
