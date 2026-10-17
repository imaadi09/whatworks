import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';

/// Local storage service for caching messages and attachments
/// Implements minimal server strategy - everything stored locally
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  static const String _messagesCacheKey = 'local_messages_cache';
  static const String _lastSyncKey = 'last_sync_timestamp';
  static const String _attachmentDir = 'attachments';

  // Image recompression bounds: camera originals (3-8 MB) are downsampled to
  // this long edge and re-encoded JPEG at this quality before being cached,
  // which shrinks the attachments dir, every backup and every upload/download.
  // Only JPEG-named files are recompressed: the cached name must stay
  // `${entityId}_$fileName` (the retry service rebuilds that exact path from
  // the message row), so re-encoding a .png into JPEG bytes would leave the
  // payload disagreeing with the extension the OS opener trusts.
  static const Set<String> _recompressExtensions = {'jpg', 'jpeg'};
  static const int _maxImageEdge = 1600;
  static const int _jpegQuality = 80;

  // Temp-dir sweep (startup hygiene): every file the app writes into the
  // system cache dir and never deletes — voice recordings, share previews,
  // task screenshots and CSV/XLSX/PDF exports.
  static const List<String> _tempPrefixes = [
    'voice_',
    'ww_share_',
    'task_screenshot_',
  ];
  static const List<String> _tempExportExtensions = ['csv', 'xlsx', 'pdf'];

  static bool _isRecompressibleImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _recompressExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Downsample to [_maxImageEdge] on the long edge and re-encode JPEG q80.
  /// Runs on a background isolate; returns null when the bytes are not a
  /// decodable still image so the caller keeps the original verbatim.
  static Uint8List? _downsampleToJpeg(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      var out = decoded;
      if (decoded.width > _maxImageEdge || decoded.height > _maxImageEdge) {
        out = img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? _maxImageEdge : null,
          height: decoded.height > decoded.width ? _maxImageEdge : null,
        );
      }
      return Uint8List.fromList(img.encodeJpg(out, quality: _jpegQuality));
    } catch (_) {
      return null;
    }
  }

  /// Downsample any decodable still image to a JPEG no larger than
  /// [_maxImageEdge] on its long edge at [_jpegQuality], off the UI isolate.
  /// Returns the compressed bytes ONLY when they are actually smaller than the
  /// source; otherwise null, so the caller uploads the original verbatim.
  ///
  /// Intended for profile avatars, whose Storage target is always `${uid}.jpg`
  /// — so the JPEG re-encode is correct regardless of the picked file's own
  /// extension (unlike the attachment path, which must preserve the cached
  /// name and is gated by [_isRecompressibleImage]).
  Future<Uint8List?> compressImageForUpload(File source) async {
    try {
      final bytes = await source.readAsBytes();
      final out = await Isolate.run(() => _downsampleToJpeg(bytes));
      if (out != null && out.length < bytes.length) return out;
    } catch (e) {
      print('[LocalStorage] Error compressing image for upload: $e');
    }
    return null;
  }

  /// Compress an image picked through the document picker (any decodable
  /// format — png/webp/bmp/gif/tiff/jpeg) and cache the JPEG result under
  /// `${entityId}_${base}.jpg`. Returns the cached path AND the adopted `.jpg`
  /// fileName, so the extension matches the re-encoded bytes and the message
  /// row (which the retry service rebuilds the cache path from) stays
  /// consistent. Returns null when the source is not a decodable still image
  /// (e.g. HEIC) or the JPEG would not be smaller — the caller then caches the
  /// original verbatim under its own name.
  Future<MapEntry<String, String>?> compressAndCacheImage(
    String entityId,
    String originalFileName,
    File source,
  ) async {
    final compressed = await compressImageForUpload(source);
    if (compressed == null) return null;
    try {
      final dot = originalFileName.lastIndexOf('.');
      final base = dot > 0
          ? originalFileName.substring(0, dot)
          : originalFileName;
      final jpgName = '$base.jpg';
      final dir = await getAttachmentDirectory();
      final localFile = File('${dir.path}/${entityId}_$jpgName');
      await localFile.writeAsBytes(compressed);
      print('[LocalStorage] Image compressed + cached: ${localFile.path}');
      return MapEntry(localFile.path, jpgName);
    } catch (e) {
      print('[LocalStorage] Error caching compressed image: $e');
      return null;
    }
  }

  // ─── MESSAGE CACHE ─────────────────────────────────────────────

  /// Cache messages locally for a task
  Future<void> cacheMessages(String taskId, List<MessageModel> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesJson = messages.map((m) => m.toMap()).toList();
      await prefs.setString(
        '${_messagesCacheKey}_$taskId',
        messagesJson.toString(),
      );

      // Update last sync time
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      print('[LocalStorage] Error caching messages: $e');
    }
  }

  /// Get cached messages for a task
  Future<List<MessageModel>?> getCachedMessages(String taskId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('${_messagesCacheKey}_$taskId');
      if (cached == null) return null;

      // Parse cached messages
      // Note: In production, use proper JSON parsing
      return null; // Placeholder - implement proper serialization
    } catch (e) {
      print('[LocalStorage] Error getting cached messages: $e');
      return null;
    }
  }

  /// Clear cached messages for a task
  Future<void> clearCachedMessages(String taskId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_messagesCacheKey}_$taskId');
    } catch (e) {
      print('[LocalStorage] Error clearing cached messages: $e');
    }
  }

  /// Get last sync timestamp
  Future<DateTime?> getLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt(_lastSyncKey);
      if (timestamp == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } catch (e) {
      print('[LocalStorage] Error getting last sync time: $e');
      return null;
    }
  }

  // ─── ATTACHMENT CACHE ──────────────────────────────────────────

  /// Get local attachments directory
  Future<Directory> getAttachmentDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final attachmentDir = Directory('${appDir.path}/$_attachmentDir');
    if (!await attachmentDir.exists()) {
      await attachmentDir.create(recursive: true);
    }
    return attachmentDir;
  }

  /// Save attachment locally
  Future<String> saveAttachmentLocally(
    String taskId,
    String fileName,
    File sourceFile,
  ) async {
    try {
      final dir = await getAttachmentDirectory();
      final localFile = File('${dir.path}/${taskId}_$fileName');

      // Recompress images before caching; only adopt the result when it is
      // actually smaller (already-small or odd images stay verbatim).
      File source = sourceFile;
      File? tempRecompressed;
      if (_isRecompressibleImage(fileName)) {
        final bytes = await sourceFile.readAsBytes();
        final out = await Isolate.run(() => _downsampleToJpeg(bytes));
        if (out != null && out.length < bytes.length) {
          tempRecompressed = File(
            '${dir.path}/.recompress_${taskId}_$fileName',
          );
          await tempRecompressed.writeAsBytes(out);
          source = tempRecompressed;
        }
      }

      // Copy file to local storage
      await source.copy(localFile.path);
      if (tempRecompressed != null) {
        try {
          await tempRecompressed.delete();
        } catch (_) {}
      }

      print('[LocalStorage] Attachment saved locally: ${localFile.path}');
      return localFile.path;
    } catch (e) {
      print('[LocalStorage] Error saving attachment: $e');
      return '';
    }
  }

  /// Get local attachment path
  Future<String?> getLocalAttachmentPath(String taskId, String fileName) async {
    try {
      final dir = await getAttachmentDirectory();
      final localFile = File('${dir.path}/${taskId}_$fileName');

      if (await localFile.exists()) {
        return localFile.path;
      }
      return null;
    } catch (e) {
      print('[LocalStorage] Error getting attachment path: $e');
      return null;
    }
  }

  /// Delete local attachment
  Future<void> deleteLocalAttachment(String taskId, String fileName) async {
    try {
      final dir = await getAttachmentDirectory();
      final localFile = File('${dir.path}/${taskId}_$fileName');

      if (await localFile.exists()) {
        await localFile.delete();
        print('[LocalStorage] Local attachment deleted: $fileName');
      }
    } catch (e) {
      print('[LocalStorage] Error deleting attachment: $e');
    }
  }

  /// Clear all local attachments (for logout or storage cleanup)
  Future<void> clearAllAttachments() async {
    try {
      final dir = await getAttachmentDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
        print('[LocalStorage] All attachments cleared');
      }
    } catch (e) {
      print('[LocalStorage] Error clearing attachments: $e');
    }
  }

  /// Get local storage usage (in bytes)
  Future<int> getLocalStorageUsage() async {
    try {
      final dir = await getAttachmentDirectory();
      if (!await dir.exists()) return 0;

      int totalSize = 0;
      await for (final file in dir.list(recursive: true)) {
        if (file is File) {
          totalSize += await file.length();
        }
      }
      return totalSize;
    } catch (e) {
      print('[LocalStorage] Error calculating storage usage: $e');
      return 0;
    }
  }

  // ─── SYNC LOGIC ────────────────────────────────────────────────

  /// Check if we need to sync with server
  Future<bool> needsSync() async {
    final lastSync = await getLastSyncTime();
    if (lastSync == null) return true;

    // Sync if last sync was more than 5 minutes ago
    final now = DateTime.now();
    return now.difference(lastSync).inMinutes > 5;
  }

  /// Mark sync as complete
  Future<void> markSyncComplete() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      print('[LocalStorage] Error marking sync complete: $e');
    }
  }

  // ─── CLEANUP ───────────────────────────────────────────────────

  /// Sweep the app's own leftovers out of the system cache dir. These files
  /// are written once and never deleted by their producers — a temp voice
  /// recording (its permanent copy lives in attachments/), a share/screenshot
  /// preview PNG, a CSV/XLSX/PDF export that was already handed to the share
  /// sheet — so without this the "Cache" line in Android's storage settings
  /// only ever grows. Only the app's own known names are touched, and only
  /// once they are older than [olderThanDays], so a share sheet that is still
  /// open on a fresh export keeps its file.
  ///
  /// Also clears `.recompress_*` scratch files left behind if an image save
  /// was interrupted mid-recompression.
  Future<int> pruneStaleTempFiles({int olderThanDays = 7}) async {
    int removed = 0;
    try {
      final cutoff = DateTime.now().subtract(Duration(days: olderThanDays));
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await for (final entity in tempDir.list(followLinks: false)) {
          if (entity is! File) continue; // Plugin-owned subdirs stay untouched
          final name = entity.uri.pathSegments.last.toLowerCase();
          final isAppTemp =
              _tempPrefixes.any(name.startsWith) ||
              _tempExportExtensions.contains(_extensionOf(name));
          if (!isAppTemp) continue;
          try {
            final stat = await entity.stat();
            if (stat.modified.isAfter(cutoff)) continue;
            await entity.delete();
            removed++;
          } catch (_) {
            // In use or already gone — the next launch retries.
          }
        }
      }

      // Interrupted-recompression scratch files have no age guard: their real
      // output either landed next to them or never will.
      final attachDir = await getAttachmentDirectory();
      if (await attachDir.exists()) {
        await for (final entity in attachDir.list(followLinks: false)) {
          if (entity is! File) continue;
          if (!entity.uri.pathSegments.last.startsWith('.recompress_')) continue;
          try {
            await entity.delete();
            removed++;
          } catch (_) {}
        }
      }

      if (removed > 0) {
        print('[LocalStorage] Pruned $removed stale temp/scratch files');
      }
    } catch (e) {
      print('[LocalStorage] Error pruning temp files: $e');
    }
    return removed;
  }

  static String _extensionOf(String lowerCaseName) {
    final dot = lowerCaseName.lastIndexOf('.');
    return dot < 0 ? '' : lowerCaseName.substring(dot + 1);
  }

  /// No-op: server removes old messages/attachments after delivery, so the phone
  /// is the ONLY permanent storage. Nothing is ever deleted locally.
  /// Kept for backward compatibility — called from HomeScreen initState.
  Future<void> cleanupOldMessages() async {
    print('[LocalStorage] Cleanup disabled — phone is permanent storage');
  }

  /// Clear all local data (for logout)
  Future<void> clearAllLocalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      await clearAllAttachments();

      print('[LocalStorage] All local data cleared');
    } catch (e) {
      print('[LocalStorage] Error clearing local data: $e');
    }
  }
}
