import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/helpers.dart';
import 'local_storage_service.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  // Upload image from camera
  Future<String?> uploadCameraImage(String taskId) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image == null) return null;

      return await _uploadFile(
        File(image.path),
        taskId,
        'images',
      );
    } catch (e) {
      print('Error uploading camera image: $e');
      return null;
    }
  }

  // Upload image from gallery
  Future<String?> uploadGalleryImage(String taskId) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image == null) return null;

      return await _uploadFile(
        File(image.path),
        taskId,
        'images',
      );
    } catch (e) {
      print('Error uploading gallery image: $e');
      return null;
    }
  }

  // Upload file
  Future<String?> uploadFile(String taskId) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final file = File(result.files.single.path!);
      return await _uploadFile(file, taskId, 'files');
    } catch (e) {
      print('Error uploading file: $e');
      return null;
    }
  }

  // Upload voice note
  Future<String?> uploadVoiceNote(
    String taskId,
    File voiceFile, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      return await _uploadFile(
        voiceFile,
        taskId,
        'voice_notes',
        onProgress: onProgress,
      );
    } catch (e) {
      print('Error uploading voice note: $e');
      return null;
    }
  }

  // Upload an image that was already picked (file path known).
  // Used in SQLite-first flow: pick → save to SQLite → upload.
  Future<String?> uploadImageFromPath(
    String taskId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      return await _uploadFile(
        File(filePath),
        taskId,
        'images',
        onProgress: onProgress,
      );
    } catch (e) {
      print('Error uploading image from path: $e');
      return null;
    }
  }

  // Generic file upload with optional progress callback (0.0–1.0)
  Future<String> _uploadFile(
    File file,
    String taskId,
    String folder, {
    void Function(double progress)? onProgress,
  }) async {
    if (taskId.isEmpty) {
      throw Exception('Task ID is empty - cannot upload file');
    }

    final fileName = '${Helpers.generateId()}_${file.path.split('/').last}';
    final ref = _storage.ref().child('tasks/$taskId/$folder/$fileName');

    final uploadTask = ref.putFile(file);
    // Stream progress updates to caller
    if (onProgress != null) {
      uploadTask.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    final snapshot = await uploadTask.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw Exception(
        'Upload timed out. Check your connection and try again.',
      ),
    );

    // Check upload state before getting URL
    if (snapshot.state == TaskState.error) {
      throw Exception('Upload failed. Please try again.');
    }
    final downloadUrl = await snapshot.ref.getDownloadURL();
    return downloadUrl;
  }

  // Delete file
  Future<void> deleteFile(String url) async {
    try {
      final ref = _storage.refFromURL(url);
      await ref.delete();
    } catch (e) {
      print('Error deleting file: $e');
    }
  }

  // Track attachment download by user. [collection] is the Firestore root
  // collection the message lives under ('tasks', 'sales_enquiries', ...).
  Future<void> trackAttachmentDownload(
    String entityId,
    String messageId,
    String userId, {
    String collection = 'tasks',
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(entityId)
          .collection('messages')
          .doc(messageId)
          .update({'downloadedBy.$userId': true});

      print(
        '[Storage] Download tracked for user $userId on message $messageId',
      );
    } catch (e) {
      print('[Storage] Error tracking download: $e');
    }
  }

  // Download and cache attachment locally (on user tap — never automatic).
  // When [senderId]/[participants] are provided, the server copy is deleted
  // once every recipient has downloaded it (minimal-server policy).
  Future<String?> downloadAndCacheAttachment(
    String entityId,
    String messageId,
    String fileName,
    String fileUrl,
    String userId, {
    String collection = 'tasks',
    String? senderId,
    Set<String>? participants,
  }) async {
    try {
      final localStorage = LocalStorageService();

      // Check if already cached locally
      final localPath = await localStorage.getLocalAttachmentPath(
        entityId,
        fileName,
      );
      if (localPath != null) {
        print('[Storage] Attachment already cached locally: $localPath');
        // Backfill the download receipt — legacy caches recorded no
        // downloadedBy entry, which blocked server cleanup forever.
        // Fire-and-forget so cached opens stay instant.
        trackAttachmentDownload(
          entityId,
          messageId,
          userId,
          collection: collection,
        ).then((_) {
          if (senderId != null && participants != null) {
            maybeDeleteServerAttachment(
              collection: collection,
              entityId: entityId,
              messageId: messageId,
              fileUrl: fileUrl,
              senderId: senderId,
              participants: participants,
            );
          }
        });
        return localPath;
      }

      // Download from Firebase Storage
      final ref = _storage.refFromURL(fileUrl);
      final tempDir = await localStorage.getAttachmentDirectory();
      final localFile = File('${tempDir.path}/${entityId}_$fileName');

      try {
        await ref.writeToFile(localFile);
      } catch (dlError) {
        final msg = dlError.toString().toLowerCase();
        if (msg.contains('object-not-found') || msg.contains('no object')) {
          // Server copy already cleaned up (all recipients had it or the
          // retention sweep ran first). No receipt — nothing to retry.
          print('[Storage] Server file no longer exists for $messageId');
        }
        rethrow;
      }

      // Track download
      await trackAttachmentDownload(
        entityId,
        messageId,
        userId,
        collection: collection,
      );

      // Remove the server copy once all recipients have it (fire-and-forget)
      if (senderId != null && participants != null) {
        maybeDeleteServerAttachment(
          collection: collection,
          entityId: entityId,
          messageId: messageId,
          fileUrl: fileUrl,
          senderId: senderId,
          participants: participants,
        );
      }

      print('[Storage] Attachment downloaded and cached: ${localFile.path}');
      return localFile.path;
    } catch (e) {
      print('[Storage] Error downloading attachment: $e');
      return null;
    }
  }

  /// Delete the Storage object once every recipient (participants minus the
  /// sender, who already holds the original locally) appears in the message's
  /// `downloadedBy` map. Reads the doc fresh so concurrent downloads on other
  /// devices are counted. Safe to call repeatedly — a missing object is a
  /// no-op. Solo conversations (no recipients) delete immediately: the sender
  /// holds the original locally, so the server copy is pure redundancy.
  Future<void> maybeDeleteServerAttachment({
    required String collection,
    required String entityId,
    required String messageId,
    required String fileUrl,
    required String senderId,
    required Set<String> participants,
  }) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .doc(entityId)
          .collection('messages')
          .doc(messageId)
          .get();
      if (!snap.exists) return;
      final data = snap.data() ?? {};
      // Only clean real uploaded files; skip if the URL changed meanwhile.
      if (data['fileUrl'] != fileUrl) return;
      final downloadedBy = Map<String, dynamic>.from(
        data['downloadedBy'] as Map? ?? {},
      );
      final recipients = participants
          .where((uid) => uid.isNotEmpty && uid != senderId)
          .toSet();
      // Empty recipients == solo conversation -> vacuously all downloaded.
      final allDownloaded =
          recipients.isEmpty ||
          recipients.every((uid) => downloadedBy[uid] == true);
      if (!allDownloaded) return;

      await _deleteStorageObjectWithRetry(fileUrl);
      print(
        '[Storage] Server attachment deleted (all recipients downloaded): '
        '$collection/$entityId/$messageId',
      );
    } catch (e) {
      // object-not-found (already cleaned) and permission errors are non-fatal.
      // Persistent failures are caught by the hourly server cleanup sweep.
      print('[Storage] Server attachment cleanup skipped: $e');
    }
  }

  /// Deletes a Storage object with retries and backoff. An object-not-found
  /// error counts as success (another device or the server sweep got there
  /// first). Rethrows after the last attempt so callers can log it.
  Future<void> _deleteStorageObjectWithRetry(
    String fileUrl, {
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await _storage.refFromURL(fileUrl).delete();
        return;
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('object-not-found') || msg.contains('no object')) {
          return; // Already gone — success.
        }
        lastError = e;
        if (attempt < attempts) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    throw lastError ?? Exception('Storage delete failed for $fileUrl');
  }
}
