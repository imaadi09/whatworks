import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the [MainActivity] public-storage MethodChannel.
///
/// Publishes/read the auto-backup file in `Download/WhatWorks` — a folder the
/// user can open in any file manager that SURVIVES app deletion (MediaStore
/// Downloads rows are kept on uninstall by design). All methods are no-ops
/// outside Android (desktop keeps using plain paths through the service).
class PublicStorageService {
  PublicStorageService._();
  static final PublicStorageService instance = PublicStorageService._();

  static const MethodChannel _channel =
      MethodChannel('com.whatworks.app/public_storage');

  /// User-facing label of the public backup folder.
  static const String folderLabel = 'Download/WhatWorks';

  bool get supported => Platform.isAndroid;

  /// Copies the staged file at [srcPath] to `Download/WhatWorks/[fileName]`,
  /// overwriting any earlier file with the same name. Returns the published
  /// reference (content URI on Android 10+, real path on older), or null when
  /// unsupported/failed — callers must then fall back to app storage.
  Future<String?> saveBackup(String fileName, String srcPath) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('saveBackup', {
        'fileName': fileName,
        'srcPath': srcPath,
      });
    } on PlatformException catch (e) {
      debugPrint('[PublicStorage] saveBackup failed: ${e.message}');
      return null;
    }
  }

  /// True when `Download/WhatWorks/[fileName]` exists.
  Future<bool> backupExists(String fileName) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('backupExists', {
            'fileName': fileName,
          }) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[PublicStorage] backupExists failed: ${e.message}');
      return false;
    }
  }

  /// Copies the public backup into the app cache dir and returns the local
  /// path (so path-based import code can read it), or null when absent. After
  /// a reinstall this still finds files the previous install published — the
  /// MediaStore QUERY sees them; only raw path access is install-scoped.
  Future<String?> readBackup(String fileName) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('readBackup', {
        'fileName': fileName,
      });
    } on PlatformException catch (e) {
      debugPrint('[PublicStorage] readBackup failed: ${e.message}');
      return null;
    }
  }

  /// Removes `Download/WhatWorks/[fileName]` (used when auto-backup is turned
  /// off entirely, so stale snapshots don't linger).
  Future<void> deleteBackup(String fileName) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('deleteBackup', {
        'fileName': fileName,
      });
    } on PlatformException catch (e) {
      debugPrint('[PublicStorage] deleteBackup failed: ${e.message}');
    }
  }
}
