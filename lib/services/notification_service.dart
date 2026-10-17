import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;

import 'notification_tap.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // SharedPreferences keys for the Settings screen notification toggles
  static const String prefPushEnabled = 'notif_push_enabled';
  static const String prefTaskReminders = 'notif_task_reminders';
  static const String prefDeadlineAlerts = 'notif_deadline_alerts';
  static const String prefSound = 'notif_sound';
  static const String prefVibration = 'notif_vibration';

  // Per-type message/reminder toggles. The same keys are mirrored to the
  // user's Firestore `notifPrefs` map (see syncNotifPrefsToFirestore) so the
  // push Cloud Function can suppress disabled types even while the app is
  // closed/backgrounded, where the OS renders the payload directly.
  static const String prefTaskMessages = 'notif_type_task';
  static const String prefSalesMessages = 'notif_type_sales';
  static const String prefCrmMessages = 'notif_type_crm';
  static const String prefCallReminders = 'notif_type_calls';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Request permission
    await _messaging.requestPermission(alert: true, badge: true, sound: true);

    // Initialize local notifications
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      // Tapping a foreground-shown local popup opens the exact chat it came
      // from (payload is the {type,parentId,messageId} JSON set in
      // _showNotification).
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) {
            NotificationTap.go(
              decoded.map(
                (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
              ),
            );
          }
        } catch (_) {}
      },
    );

    // Timezone DB for zonedSchedule (deadline + scheduled-call reminders).
    // Without this tz.local throws and every scheduled notification silently
    // fails inside the callers' try/catch.
    tz.initializeTimeZones();

    // Persist this device's FCM token to the current user's doc so the
    // message-push Cloud Function can target it, and keep it fresh on refresh.
    await saveTokenForCurrentUser();
    // Push the current type toggles up so the server gate is never stale after
    // a reinstall/refresh that re-saved the token.
    await syncNotifPrefsToFirestore();
    _messaging.onTokenRefresh.listen((token) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) _writeToken(uid, token);
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((message) {
      final d = message.data;
      _showNotification(
        message.notification?.title ?? 'New Notification',
        message.notification?.body ?? '',
        type: d['type'],
        category: d['category'],
        parentId: d['parentId'],
        messageId: d['messageId'],
      );
    });

    // App opened from the background by tapping a notification → its chat.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      NotificationTap.go(_dataToStringMap(message.data));
    });

    // App was fully terminated and launched by a notification tap: park the
    // route until Home is mounted and drains it (see NotificationTap.drain).
    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      NotificationTap.queue(_dataToStringMap(initial.data));
    }

    _isInitialized = true;
  }

  /// FCM ships data payloads as `Map<String, dynamic>`, but every value is a
  /// string — coerce for the tap router, which keys on `type`/`parentId`.
  Map<String, String> _dataToStringMap(Map<String, dynamic> src) =>
      src.map((k, v) => MapEntry(k, v?.toString() ?? ''));

  // ── FCM token persistence ─────────────────────────────────────────────
  // Tokens are stored as an array on users/{uid} so a user can receive
  // pushes on every device they are signed in on.

  /// Save the current device's FCM token to the signed-in user's doc.
  /// Safe to call repeatedly (e.g. after login); no-op when signed out.
  Future<void> saveTokenForCurrentUser() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final token = await _messaging.getToken();
      if (token == null) return;
      await _writeToken(uid, token);
    } catch (e) {
      print('[Notifications] Failed to fetch/save FCM token: $e');
    }
  }

  Future<void> _writeToken(String uid, String token) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[Notifications] Failed to persist FCM token: $e');
    }
  }

  /// Remove this device's token from the signed-in user's doc (call on sign-out
  /// so a logged-out device stops receiving that account's message pushes).
  Future<void> removeTokenForCurrentUser() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final token = await _messaging.getToken();
      if (token == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayRemove([token]),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[Notifications] Failed to remove FCM token: $e');
    }
  }

  // Show local notification
  Future<void> _showNotification(
    String title,
    String body, {
    String? type,
    String? category,
    String? parentId,
    String? messageId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Push toggle in Settings gates all foreground popups
    if (!(prefs.getBool(prefPushEnabled) ?? true)) return;
    // Per-type toggle: drop a foreground popup whose type the user disabled.
    final typeKey = _typePrefKey(category, type);
    if (typeKey != null && !(prefs.getBool(typeKey) ?? true)) return;
    final sound = prefs.getBool(prefSound) ?? true;
    final vibration = prefs.getBool(prefVibration) ?? true;

    final androidDetails = AndroidNotificationDetails(
      'whatworks_channel',
      'WhatWorks Notifications',
      channelDescription: 'Notifications for task updates',
      importance: Importance.high,
      priority: Priority.high,
      playSound: sound,
      enableVibration: vibration,
    );

    const iosDetails = DarwinNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Encode routing so tapping this local popup opens the originating chat.
    final payload = (parentId != null && parentId.isNotEmpty)
        ? jsonEncode({
            'type': type ?? '',
            'parentId': parentId,
            'messageId': messageId ?? '',
          })
        : null;

    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Maps a push's category + module type to the SharedPreferences toggle that
  /// gates it. Scheduled calls have their own switch regardless of module.
  /// Returns null for anything unrecognized (never gated).
  String? _typePrefKey(String? category, String? type) {
    if (category == 'call') return prefCallReminders;
    switch (type) {
      case 'task':
        return prefTaskMessages;
      case 'enquiry':
        return prefSalesMessages;
      case 'crm':
        return prefCrmMessages;
      default:
        return null;
    }
  }

  /// Current per-type on/off map, keyed for the Firestore `notifPrefs` doc the
  /// push Cloud Function consults. Absent = enabled (default true).
  Future<Map<String, bool>> readTypeMap() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'task': prefs.getBool(prefTaskMessages) ?? true,
      'sales': prefs.getBool(prefSalesMessages) ?? true,
      'crm': prefs.getBool(prefCrmMessages) ?? true,
      'calls': prefs.getBool(prefCallReminders) ?? true,
    };
  }

  /// Push the local toggles up to users/{uid}.notifPrefs so the Cloud Function
  /// can suppress disabled types even while the app is closed. No-op signed out.
  Future<void> syncNotifPrefsToFirestore() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final map = await readTypeMap();
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'notifPrefs': map,
      }, SetOptions(merge: true));
    } catch (e) {
      print('[Notifications] Failed to sync notifPrefs: $e');
    }
  }

  // Schedule deadline reminder
  Future<void> scheduleDeadlineReminder({
    required String title,
    required String body,
    required DateTime scheduledDate,
    int? id,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'deadline_channel',
      'Deadline Reminders',
      channelDescription: 'Reminders for task deadlines',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    // Convert DateTime to TZDateTime for timezone-aware scheduling
    final tzScheduledDate = tz.TZDateTime.from(scheduledDate, tz.local);

    await _localNotifications.zonedSchedule(
      id ?? DateTime.now().millisecond,
      title,
      body,
      tzScheduledDate,
      details,
      // Inexact: the manifest does not request SCHEDULE_EXACT_ALARM, and
      // Android 12+ throws at schedule time for exact alarms without it.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // Cancel all notifications
  Future<void> cancelAllNotifications() async {
    await _localNotifications.cancelAll();
  }

  // ── Task deadline reminders ───────────────────────────────────────────
  // Stable per-task notification ids so re-scheduling replaces the old
  // reminders instead of stacking duplicates.
  int _taskNotifId(String taskId) => taskId.hashCode & 0x3fffffff;

  /// Sync local deadline reminders for a task: schedules a 1-day-before
  /// reminder (9 AM) and a deadline-day alert (9 AM). Cancels existing ones
  /// first, so calling with a changed/removed deadline updates correctly.
  /// Honors the Settings toggles (deadline alerts / task reminders).
  Future<void> syncDeadlineReminders({
    required String taskId,
    required String taskTitle,
    DateTime? deadline,
  }) async {
    try {
      final baseId = _taskNotifId(taskId);
      await _localNotifications.cancel(baseId);
      await _localNotifications.cancel(baseId + 1);
      if (deadline == null) return;

      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(prefDeadlineAlerts) ?? true)) return;
      final remindersOn = prefs.getBool(prefTaskReminders) ?? true;

      final now = DateTime.now();
      // Deadline-day alert at 9 AM (deadlines are stored as 23:59)
      final dayOf = DateTime(deadline.year, deadline.month, deadline.day, 9);
      if (dayOf.isAfter(now)) {
        await scheduleDeadlineReminder(
          id: baseId,
          title: 'Deadline today',
          body: '"$taskTitle" is due today',
          scheduledDate: dayOf,
        );
      }
      // Day-before reminder at 9 AM
      final dayBefore = dayOf.subtract(const Duration(days: 1));
      if (remindersOn && dayBefore.isAfter(now)) {
        await scheduleDeadlineReminder(
          id: baseId + 1,
          title: 'Deadline tomorrow',
          body: '"$taskTitle" is due tomorrow',
          scheduledDate: dayBefore,
        );
      }
    } catch (e) {
      // Never let reminder scheduling break task save flows
      print('[Notifications] Failed to sync deadline reminders: $e');
    }
  }

  /// Remove any scheduled reminders for a task (e.g. completed/deleted).
  Future<void> cancelDeadlineReminders(String taskId) async {
    final baseId = _taskNotifId(taskId);
    await _localNotifications.cancel(baseId);
    await _localNotifications.cancel(baseId + 1);
  }
}
