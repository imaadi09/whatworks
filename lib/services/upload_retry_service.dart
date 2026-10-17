import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/widgets.dart';
import '../models/message.dart';
import 'local_database_service.dart';
import 'local_storage_service.dart';
import 'storage_service.dart';

/// Background service that retries uploading pending/failed attachments.
///
/// Event-driven instead of a fixed 30 s poll: it runs one pass at startup,
/// reacts to `messages` table changes (debounced ~10 s), and while work
/// remains reschedules itself with exponential backoff (30 s -> 60 s -> 120 s
/// -> 5 min cap, reset on a successful upload). Each pass starts with an
/// index-only COUNT gate so the common launch with nothing pending is nearly
/// free. It also observes the app lifecycle: the timer is cancelled while
/// paused and re-armed on resume, so a backgrounded device does no work.
class UploadRetryService with WidgetsBindingObserver {
  static final UploadRetryService _instance = UploadRetryService._internal();
  factory UploadRetryService() => _instance;
  UploadRetryService._internal();

  Timer? _retryTimer;
  Timer? _debounce;
  StreamSubscription<TableChange>? _messageChangesSub;
  bool _isRetrying = false;
  bool _started = false;
  bool _paused = false;

  /// Backoff ladder used while retryable work remains. Reset to the first step
  /// whenever an upload actually succeeds.
  static const List<Duration> _backoffSteps = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(minutes: 5),
  ];
  int _backoffIndex = 0;
  static const Duration _debounceWindow = Duration(seconds: 10);

  /// Start event-driven retry: one immediate pass, then react to `messages`
  /// table changes. Safe to call more than once. (Name kept for callers.)
  void startPeriodicRetry() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    // A burst of message writes (e.g. several queued attachments) collapses
    // into one pass after a quiet window instead of one pass per row.
    _messageChangesSub = LocalDatabaseService()
        .tableChanges2
        .where((c) => c.table == 'messages')
        .listen((_) {
          _debounce?.cancel();
          _debounce = Timer(_debounceWindow, () {
            _backoffIndex = 0; // A real change deserves a prompt attempt.
            retryPendingUploads();
          });
        });

    // One pass at startup.
    retryPendingUploads();
  }

  /// Stop retrying; release the lifecycle observer and subscriptions.
  void stopPeriodicRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _debounce?.cancel();
    _debounce = null;
    _messageChangesSub?.cancel();
    _messageChangesSub = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _started = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _paused = false;
      // Re-arm on resume; backoff continues if work is still pending.
      retryPendingUploads();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Nothing uploads usefully in the background — drop the pending timer.
      _paused = true;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    // inactive: brief (app switcher / incoming call) — leave the timer alone.
  }

  /// Run one retry pass behind an index-only COUNT gate, then reschedule.
  Future<void> retryPendingUploads() async {
    if (_isRetrying) return;
    _isRetrying = true;

    var didUpload = false;
    try {
      final localDb = LocalDatabaseService();
      // Cheap gate: most launches have zero pending uploads and should not pay
      // for a full row query.
      if (await localDb.getRetryableUploadCount() == 0) {
        _backoffIndex = 0;
        return;
      }

      final pendingMessages = await localDb.getRetryableUploadMessages();
      if (pendingMessages.isEmpty) {
        _backoffIndex = 0;
        return;
      }

      print(
        '[UploadRetry] Found ${pendingMessages.length} retryable upload(s), retrying...',
      );

      for (final row in pendingMessages) {
        try {
          if (await _retrySingleUpload(row)) didUpload = true;
        } catch (e) {
          print('[UploadRetry] Failed to retry ${row['id']}: $e');
          // Stay pending, will retry next cycle
        }
      }
    } catch (e) {
      print('[UploadRetry] Error checking pending uploads: $e');
    } finally {
      _isRetrying = false;
    }

    _scheduleNext(didUpload);
  }

  /// Reschedule the next pass. A successful upload resets the backoff ladder;
  /// otherwise it steps toward the 5-minute cap. Skipped while paused — resume
  /// re-arms it.
  void _scheduleNext(bool didUpload) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_paused) return;
    if (didUpload) _backoffIndex = 0;
    final delay =
        _backoffSteps[_backoffIndex.clamp(0, _backoffSteps.length - 1)];
    if (!didUpload && _backoffIndex < _backoffSteps.length - 1) {
      _backoffIndex++;
    }
    _retryTimer = Timer(delay, retryPendingUploads);
  }

  Future<bool> _retrySingleUpload(Map<String, dynamic> row) async {
    final messageId = row['id'] as String;
    final taskId = row['taskId'] as String;
    final typeStr = row['type'] as String;
    final fileName = row['fileName'] as String?;
    final type = MessageType.values.firstWhere(
      (e) => e.toString() == 'MessageType.$typeStr',
      orElse: () => MessageType.text,
    );

    final storage = StorageService();
    final localDb = LocalDatabaseService();
    final localStorage = LocalStorageService();
    final dir = await localStorage.getAttachmentDirectory();

    // Resolve the parent Firestore collection once; reused for the delivery
    // write below and to look up a superseded object.
    final collection = await _resolveParentCollection(localDb, taskId);

    // Superseded-object cleanup: every upload writes a fresh randomly-named
    // Storage object, so if an earlier attempt uploaded AND delivered its URL
    // to Firestore while the LOCAL row stayed 'pending'/'failed' (process
    // killed before updateMessageFileUrl, or that local write failed), this
    // retry would create a second object and orphan the first — nothing else
    // records its URL, so the all-recipients-downloaded sweep can never reclaim
    // it. Capture that URL now and delete it once the new URL is durably
    // recorded. Best-effort read: offline or a missing doc just means there is
    // nothing to clean.
    String? supersededUrl;
    if (collection != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection(collection)
            .doc(taskId)
            .collection('messages')
            .doc(messageId)
            .get();
        final existing = doc.data()?['fileUrl'];
        if (existing is String && existing.startsWith('http')) {
          supersededUrl = existing;
        }
      } catch (_) {}
    }

    String? downloadUrl;

    switch (type) {
      case MessageType.image:
        final imagePath =
            '${dir.path}/${taskId}_${fileName ?? 'image_$messageId.jpg'}';
        if (await File(imagePath).exists()) {
          downloadUrl = await storage.uploadImageFromPath(taskId, imagePath);
        } else {
          print('[UploadRetry] Image file not found: $imagePath');
          return false;
        }
        break;

      case MessageType.file:
        final localFilePath =
            '${dir.path}/${taskId}_${fileName ?? 'file_$messageId'}';
        if (await File(localFilePath).exists()) {
          // Try sales path first, then task path
          String? url = await _tryUploadFile(
            File(localFilePath),
            'sales/$taskId/files/${messageId}_${fileName ?? 'file'}',
          );
          if (url == null) {
            url = await _tryUploadFile(
              File(localFilePath),
              'tasks/$taskId/files/${messageId}_${fileName ?? 'file'}',
            );
          }
          downloadUrl = url;
        } else {
          print('[UploadRetry] File not found: $localFilePath');
          return false;
        }
        break;

      case MessageType.voice:
        final voicePath = '${dir.path}/voice_$messageId.m4a';
        if (await File(voicePath).exists()) {
          downloadUrl = await storage.uploadVoiceNote(taskId, File(voicePath));
        } else {
          print('[UploadRetry] Voice file not found: $voicePath');
          return false;
        }
        break;

      default:
        print('[UploadRetry] Unsupported message type for retry: $type');
        return false;
    }

    if (downloadUrl == null) return false;

    await localDb.updateMessageFileUrl(messageId, downloadUrl);
    print('[UploadRetry] Successfully uploaded $messageId');
    // Deliver to Firestore so the attachment reaches other devices.
    var delivered = false;
    try {
      final msg = localDb.messageFromRow({
        ...row,
        'fileUrl': downloadUrl,
        'uploadError': null,
      });
      if (collection != null) {
        await FirebaseFirestore.instance
            .collection(collection)
            .doc(taskId)
            .collection('messages')
            .doc(messageId)
            .set(msg.toMap());
      }
      delivered = true;
    } catch (e) {
      print('[UploadRetry] Firestore delivery failed for $messageId: $e');
    }

    // Only reclaim the superseded object once the new URL is what Firestore
    // serves: if delivery failed the doc still points at [supersededUrl], and
    // deleting it would break the link for every other device. deleteFile
    // tolerates object-not-found (another device or the sweep got there first).
    if (delivered && supersededUrl != null && supersededUrl != downloadUrl) {
      await storage.deleteFile(supersededUrl);
      print('[UploadRetry] Deleted superseded object for $messageId');
    }
    return true;
  }

  /// Resolve the Firestore collection for a message's parent entity:
  /// tasks → 'tasks', sales enquiries → 'sales_enquiries',
  /// CRM enquiries → 'crm_records'. Returns null if parent not found.
  Future<String?> _resolveParentCollection(
    LocalDatabaseService localDb,
    String parentId,
  ) async {
    try {
      final db = await localDb.database;
      final tasks = await db.query(
        'tasks',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (tasks.isNotEmpty) return 'tasks';
      final enquiries = await db.query(
        'enquiries',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (enquiries.isNotEmpty) return 'sales_enquiries';
      final crm = await db.query(
        'crm_enquiries',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (crm.isNotEmpty) return 'crm_records';
    } catch (e) {
      print('[UploadRetry] Error resolving parent collection: $e');
    }
    return null;
  }

  /// Try uploading to a specific Firebase Storage path. Returns null on failure.
  Future<String?> _tryUploadFile(File file, String storagePath) async {
    try {
      final fileRef = FirebaseStorage.instance.ref().child(storagePath);
      final uploadTask = fileRef.putFile(file);
      final snapshot = await uploadTask.timeout(const Duration(seconds: 60));
      if (snapshot.state == TaskState.error) return null;
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      return null;
    }
  }

  void dispose() {
    stopPeriodicRetry();
  }
}
