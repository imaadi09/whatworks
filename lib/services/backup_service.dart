import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ConflictAlgorithm (restore path) — the fingerprint no longer uses
// Sqflite.firstIntValue.
import 'package:sqflite/sqflite.dart';
import 'local_database_service.dart';
import 'public_storage_service.dart';
import '../models/message.dart';
import '../models/task.dart';
import '../modules/sales/models/enquiry.dart';
import '../modules/sales/models/sales_team.dart';

/// Service for creating and restoring encrypted backups of all app data.
///
/// Backup reads/writes 100% from local SQLite — Firebase is NOT used.
/// SQLite is the permanent source of truth; Firebase is transient delivery only.
///
/// Includes:
/// - All local SQLite tables (messages, tasks, enquiries, crm_enquiries,
///   teams (task/sales/crm), drafts, milestones, system_logs, actions,
///   sales_actions, crm_actions, categories)
/// - SharedPreferences data (settings, milestone templates, caches)
/// - Local attachment files
///
/// The backup is encrypted with AES-256-CBC using a password-derived key (PBKDF2).
class BackupService {
  // File extension used for backup files
  static const String _backupExtension = '.whatworksbackup';

  /// Fixed name of the auto-backup snapshot: every run overwrites the same
  /// file (weekly by default), so exactly one snapshot lives in the target
  /// folder — and a fresh install can find it by NAME without any stored
  /// prefs (see [findLatestAutoBackupPath]).
  static const String autoBackupFileName = 'whatworks_backup$_backupExtension';
  static const int _backupVersion =
      4; // v4 = module teams, categories, CRM tables
  static const int _pbkdf2Iterations = 100000;
  static const int _saltLength = 32;

  /// Every SQLite table a backup captures — also the set the auto-backup
  /// fingerprint walks. Keep in sync with [exportBackup]/[importBackup].
  static const List<String> _backupTables = [
    'messages',
    'tasks',
    'enquiries',
    'crm_enquiries',
    'sales_teams',
    'task_teams',
    'crm_teams',
    'task_drafts',
    'milestones',
    'system_logs',
    'actions',
    'sales_actions',
    'crm_actions',
    'categories',
  ];

  // ─── EXPORT (100% SQLite) ────────────────────────────────────────────────

  /// Create an encrypted backup file at [savePath] protected by [password].
  /// All data is read from local SQLite — Firebase is never touched.
  Future<void> exportBackup(
    String password,
    String savePath, {
    void Function(String message)? onProgress,
    bool includeAttachments = true,
  }) async {
    final localDb = LocalDatabaseService();
    final db = await localDb.database;

    // Export all SQLite tables
    onProgress?.call('Exporting messages...');
    final messagesData = await _exportTable(db, 'messages');

    onProgress?.call('Exporting tasks...');
    final tasksData = await _exportTable(db, 'tasks');

    onProgress?.call('Exporting enquiries...');
    final enquiriesData = await _exportTable(db, 'enquiries');

    onProgress?.call('Exporting teams...');
    final teamsData = await _exportTable(db, 'sales_teams');

    onProgress?.call('Exporting task teams...');
    final taskTeamsData = await _exportTable(db, 'task_teams');

    onProgress?.call('Exporting CRM teams...');
    final crmTeamsData = await _exportTable(db, 'crm_teams');

    onProgress?.call('Exporting drafts...');
    final draftsData = await _exportTable(db, 'task_drafts');

    onProgress?.call('Exporting milestones...');
    final milestonesData = await _exportTable(db, 'milestones');

    onProgress?.call('Exporting system logs...');
    final systemLogsData = await _exportTable(db, 'system_logs');

    onProgress?.call('Exporting actions...');
    final actionsData = await _exportTable(db, 'actions');

    onProgress?.call('Exporting sales actions...');
    final salesActionsData = await _exportTable(db, 'sales_actions');

    onProgress?.call('Exporting CRM actions...');
    final crmActionsData = await _exportTable(db, 'crm_actions');

    onProgress?.call('Exporting CRM records...');
    final crmEnquiriesData = await _exportTable(db, 'crm_enquiries');

    onProgress?.call('Exporting categories...');
    final categoriesData = await _exportTable(db, 'categories');

    onProgress?.call('Exporting settings...');
    final prefsData = await _exportSharedPreferences();

    onProgress?.call(
      includeAttachments ? 'Exporting attachments...' : 'Skipping attachments...',
    );
    // Auto-backups skip attachments (they already live on this device; the
    // auto-backup's job is DB + prefs recovery). Manual exports keep them.
    final attachmentFiles = includeAttachments
        ? await _collectAttachmentFiles()
        : <Map<String, dynamic>>[];

    onProgress?.call('Creating archive...');

    // Build manifest — all data from SQLite only
    final manifest = {
      'version': _backupVersion,
      'timestamp': DateTime.now().toIso8601String(),
      'messages': messagesData,
      'tasks': tasksData,
      'enquiries': enquiriesData,
      'crm_enquiries': crmEnquiriesData,
      'teams': teamsData,
      'task_teams': taskTeamsData,
      'crm_teams': crmTeamsData,
      'drafts': draftsData,
      'milestones': milestonesData,
      'system_logs': systemLogsData,
      'actions': actionsData,
      'sales_actions': salesActionsData,
      'crm_actions': crmActionsData,
      'categories': categoriesData,
      'preferences': prefsData,
    };

    // ZIP + PBKDF2(100k) + AES are the heaviest CPU work in the app and used
    // to run on the UI isolate, freezing it for seconds on a large database.
    // Relocate them to a background isolate — the crypto is byte-for-byte
    // identical, it just no longer blocks the UI. manifest, the raw attachment
    // bytes and the password are all sendable across the isolate boundary.
    onProgress?.call('Encrypting...');
    final encrypted = await Isolate.run(() {
      final zipBytes = _createZip(manifest, attachmentFiles);
      return _encrypt(zipBytes, password);
    });

    // Write to file
    final file = File(savePath);
    await file.writeAsBytes(encrypted);

    onProgress?.call('Backup complete!');
  }

  /// Export all rows from a SQLite table as a list of maps.
  Future<List<Map<String, dynamic>>> _exportTable(
    dynamic db,
    String tableName,
  ) async {
    try {
      final rows = await db.query(tableName);
      // messages.changeKey is a derived local fingerprint (see
      // LocalDatabaseService._messageChangeKey): it is recomputed by
      // _messageToRow on import, so archiving it would only bloat the ZIP.
      return rows
          .map((row) => Map<String, dynamic>.from(row)..remove('changeKey'))
          .toList();
    } catch (e) {
      debugPrint('[BackupService] Error exporting $tableName: $e');
      return [];
    }
  }

  /// Export all SharedPreferences as a Map.
  Future<Map<String, dynamic>> _exportSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final data = <String, dynamic>{};

    for (final key in keys) {
      final value = prefs.get(key);
      if (value is int) {
        data[key] = {'type': 'int', 'value': value};
      } else if (value is bool) {
        data[key] = {'type': 'bool', 'value': value};
      } else if (value is double) {
        data[key] = {'type': 'double', 'value': value};
      } else if (value is String) {
        data[key] = {'type': 'string', 'value': value};
      } else if (value is List<String>) {
        data[key] = {'type': 'stringList', 'value': value};
      }
    }

    return data;
  }

  /// Collect all local attachment files.
  Future<List<Map<String, dynamic>>> _collectAttachmentFiles() async {
    final files = <Map<String, dynamic>>[];
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final attachDir = Directory('${appDir.path}/attachments');
      if (await attachDir.exists()) {
        await for (final entity in attachDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = entity.path.substring(appDir.path.length + 1);
            final bytes = await entity.readAsBytes();
            // Keep raw bytes — base64 round-tripping cost ~33% extra peak
            // memory and two full passes over every attachment.
            files.add({'relativePath': relativePath, 'bytes': bytes});
          }
        }
      }
    } catch (e) {
      debugPrint('[Backup] Error collecting attachments: $e');
    }
    return files;
  }

  /// Create a ZIP archive from manifest JSON and attachment files.
  /// Static so it can run inside [Isolate.run] without capturing `this`.
  static Uint8List _createZip(
    Map<String, dynamic> manifest,
    List<Map<String, dynamic>> attachments,
  ) {
    final archive = Archive();

    // Add manifest.json
    final manifestJson = jsonEncode(manifest);
    archive.addFile(
      ArchiveFile(
        'manifest.json',
        manifestJson.length,
        utf8.encode(manifestJson),
      ),
    );

    // Add attachment files (already raw bytes — no base64 decode)
    for (final file in attachments) {
      final path = file['relativePath'] as String;
      final bytes = file['bytes'] as Uint8List;
      archive.addFile(ArchiveFile('attachments/$path', bytes.length, bytes));
    }

    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  // ─── ENCRYPTION ──────────────────────────────────────────────────────────

  /// Encrypt data with AES-256-CBC using password.
  /// Format: [32-byte salt][16-byte IV][encrypted data]
  /// Static so it can run inside [Isolate.run] without capturing `this`.
  static Uint8List _encrypt(Uint8List data, String password) {
    final random = Random.secure();
    final salt = Uint8List(_saltLength);
    for (var i = 0; i < _saltLength; i++) {
      salt[i] = random.nextInt(256);
    }

    final key = _deriveKey(password, salt);
    final iv = encrypt.IV(
      Uint8List.fromList(List.generate(16, (_) => random.nextInt(256))),
    );
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc),
    );
    final encrypted = encrypter.encryptBytes(data, iv: iv);

    // Combine: salt + iv + encrypted
    final result = BytesBuilder();
    result.add(salt);
    result.add(iv.bytes);
    result.add(encrypted.bytes);
    return result.toBytes();
  }

  /// Decrypt data with AES-256-CBC using password.
  Uint8List _decrypt(Uint8List data, String password) {
    final salt = data.sublist(0, _saltLength);
    final ivBytes = data.sublist(_saltLength, _saltLength + 16);
    final encryptedBytes = data.sublist(_saltLength + 16);

    final key = _deriveKey(password, salt);
    final iv = encrypt.IV(ivBytes);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc),
    );
    final decrypted = encrypter.decryptBytes(
      encrypt.Encrypted(encryptedBytes),
      iv: iv,
    );

    return Uint8List.fromList(decrypted);
  }

  /// Derive a 256-bit key from password using PBKDF2.
  /// Static so it can run inside [Isolate.run] without capturing `this`.
  static encrypt.Key _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, 32));
    final keyBytes = pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
    return encrypt.Key(keyBytes);
  }

  // ─── IMPORT (100% SQLite) ────────────────────────────────────────────────

  /// Restore from an encrypted backup file.
  /// All data is written to local SQLite — Firebase is never touched.
  /// Supports both v2 (SQLite-only) and v1 (legacy Firestore) backup formats.
  Future<void> importBackup(
    String password,
    String filePath, {
    void Function(String message)? onProgress,
  }) async {
    final file = File(filePath);
    final encryptedData = await file.readAsBytes();

    onProgress?.call('Decrypting...');
    Uint8List zipBytes;
    try {
      zipBytes = _decrypt(Uint8List.fromList(encryptedData), password);
    } catch (e) {
      throw Exception('Incorrect password or corrupted backup file');
    }

    onProgress?.call('Extracting archive...');
    final archive = ZipDecoder().decodeBytes(zipBytes);

    // Find and parse manifest
    Map<String, dynamic> manifest;
    final manifestFile = archive.firstWhere(
      (f) => f.name == 'manifest.json',
      orElse: () => throw Exception('Invalid backup: manifest.json not found'),
    );
    manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));

    final version = manifest['version'] as int;
    if (version > _backupVersion) {
      throw Exception(
        'Backup version $version is newer than supported version $_backupVersion',
      );
    }

    final localDb = LocalDatabaseService();
    final db = await localDb.database;

    if (version >= 2) {
      // v2 format: all data is raw SQLite rows
      onProgress?.call('Restoring messages...');
      await _restoreTable(db, 'messages', manifest['messages'] as List);

      onProgress?.call('Restoring tasks...');
      await _restoreTable(db, 'tasks', manifest['tasks'] as List);

      onProgress?.call('Restoring enquiries...');
      await _restoreTable(db, 'enquiries', manifest['enquiries'] as List);

      onProgress?.call('Restoring teams...');
      await _restoreTable(db, 'sales_teams', manifest['teams'] as List);

      // v4 added per-module team tables — guard for older backups
      if (manifest.containsKey('task_teams')) {
        onProgress?.call('Restoring task teams...');
        await _restoreTable(db, 'task_teams', manifest['task_teams'] as List);
      }
      if (manifest.containsKey('crm_teams')) {
        onProgress?.call('Restoring CRM teams...');
        await _restoreTable(db, 'crm_teams', manifest['crm_teams'] as List);
      }

      onProgress?.call('Restoring drafts...');
      await _restoreTable(db, 'task_drafts', manifest['drafts'] as List);

      onProgress?.call('Restoring milestones...');
      await _restoreTable(db, 'milestones', manifest['milestones'] as List);

      onProgress?.call('Restoring system logs...');
      await _restoreTable(db, 'system_logs', manifest['system_logs'] as List);

      onProgress?.call('Restoring actions...');
      if (manifest.containsKey('actions')) {
        await _restoreTable(db, 'actions', manifest['actions'] as List);
      }

      // v4 tables — guarded so v2/v3 backups still restore cleanly
      if (manifest.containsKey('crm_enquiries')) {
        onProgress?.call('Restoring CRM records...');
        await _restoreTable(
          db,
          'crm_enquiries',
          manifest['crm_enquiries'] as List,
        );
      }
      if (manifest.containsKey('sales_actions')) {
        onProgress?.call('Restoring sales actions...');
        await _restoreTable(
          db,
          'sales_actions',
          manifest['sales_actions'] as List,
        );
      }
      if (manifest.containsKey('crm_actions')) {
        onProgress?.call('Restoring CRM actions...');
        await _restoreTable(db, 'crm_actions', manifest['crm_actions'] as List);
      }
      if (manifest.containsKey('categories')) {
        onProgress?.call('Restoring categories...');
        await _restoreTable(db, 'categories', manifest['categories'] as List);
      }
    } else {
      // v1 legacy format: only restore local_* SQLite data (skip Firestore data)
      if (manifest.containsKey('local_messages')) {
        onProgress?.call('Restoring messages from legacy backup...');
        await _restoreLegacyLocalMessages(manifest['local_messages'] as Map);
      }
      if (manifest.containsKey('local_tasks')) {
        onProgress?.call('Restoring tasks from legacy backup...');
        await _restoreLegacyLocalModels(
          manifest['local_tasks'] as List,
          'tasks',
        );
      }
      if (manifest.containsKey('local_enquiries')) {
        onProgress?.call('Restoring enquiries from legacy backup...');
        await _restoreLegacyLocalModels(
          manifest['local_enquiries'] as List,
          'enquiries',
        );
      }
      if (manifest.containsKey('local_teams')) {
        onProgress?.call('Restoring teams from legacy backup...');
        await _restoreLegacyLocalModels(
          manifest['local_teams'] as List,
          'sales_teams',
        );
      }
    }

    onProgress?.call('Restoring settings...');
    await _restoreSharedPreferences(manifest['preferences'] as Map);

    // v2 restore inserts messages with raw batch writes (no action
    // write-through), and the prefs restore above re-imports the old
    // device's actions_backfill_done latch. If the backup predates the
    // actions table, rebuild the index here — otherwise card icon strips
    // and the Actions tabs stay empty after restore.
    if (version >= 2 && !manifest.containsKey('actions')) {
      onProgress?.call('Rebuilding actions index...');
      await localDb.backfillActionsFromMessages();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('actions_backfill_done', true);
    }

    onProgress?.call('Restoring attachments...');
    await _restoreAttachments(archive);

    onProgress?.call('Restore complete!');
  }

  /// Restore rows into a SQLite table from backup data.
  Future<void> _restoreTable(dynamic db, String tableName, List rows) async {
    if (rows.isEmpty) return;
    try {
      final batch = db.batch();
      int count = 0;
      for (final row in rows) {
        final data = Map<String, dynamic>.from(row as Map);
        batch.insert(
          tableName,
          data,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        count++;
        if (count % 500 == 0) {
          await batch.commit(noResult: true);
        }
      }
      if (count % 500 != 0 || count == 0) {
        await batch.commit(noResult: true);
      }
      debugPrint('[BackupService] Restored $count rows into $tableName');
    } catch (e) {
      debugPrint('[BackupService] Error restoring $tableName: $e');
    }
  }

  /// Restore messages from v1 legacy backup (Firestore-format → MessageModel → SQLite).
  Future<void> _restoreLegacyLocalMessages(Map localMessagesData) async {
    try {
      final localDb = LocalDatabaseService();
      int totalMessages = 0;
      for (final entry in localMessagesData.entries) {
        final taskId = entry.key as String;
        final messagesList = entry.value as List;
        for (final msgData in messagesList) {
          final data = Map<String, dynamic>.from(msgData as Map);
          final messageId =
              data.remove('_docId') ?? data.remove('id') as String?;
          if (messageId == null) continue;
          try {
            final message = _legacyMapToMessageModel(data, messageId, taskId);
            await localDb.saveMessage(message);
            totalMessages++;
          } catch (_) {}
        }
      }
      debugPrint(
        '[BackupService] Restored $totalMessages legacy messages to local DB',
      );
    } catch (e) {
      debugPrint('[BackupService] Error restoring legacy messages: $e');
    }
  }

  /// Convert a legacy backup map to MessageModel.
  MessageModel _legacyMapToMessageModel(
    Map<String, dynamic> data,
    String id,
    String taskId,
  ) {
    return MessageModel(
      id: id,
      taskId: taskId,
      senderId: data['senderId'] ?? '',
      text: data['text'] ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => MessageType.text,
      ),
      fileUrl: data['fileUrl'],
      fileName: data['fileName'],
      duration: data['duration'],
      createdAt: _parseLegacyDateTime(data['createdAt']) ?? DateTime.now(),
      searchableContent: data['searchableContent'],
      deliveryMethod: data['deliveryMethod'],
      isEdited: data['isEdited'] == true,
      deleted: data['deleted'] == true,
      deletedFor: data['deletedFor'] != null
          ? List<String>.from(data['deletedFor'])
          : [],
      systemType: SystemMessageType.values.firstWhere(
        (e) => e.name == data['systemType'],
        orElse: () => SystemMessageType.regular,
      ),
    );
  }

  /// Restore tasks/enquiries/teams from v1 legacy backup.
  Future<void> _restoreLegacyLocalModels(
    List modelsData,
    String tableName,
  ) async {
    try {
      final localDb = LocalDatabaseService();
      int count = 0;
      for (final item in modelsData) {
        try {
          final data = Map<String, dynamic>.from(item as Map);
          final id = data.remove('_docId') ?? data.remove('id') as String?;
          if (id == null) continue;
          final deserialized = _legacyDeserializeForModel(data);
          if (tableName == 'tasks') {
            final task = TaskModel.fromMap(deserialized, id);
            await localDb.saveTask(task);
          } else if (tableName == 'enquiries') {
            final enquiry = EnquiryModel.fromMap(deserialized, id);
            await localDb.saveEnquiry(enquiry);
          } else if (tableName == 'sales_teams') {
            final team = SalesTeam.fromMap(deserialized, id);
            await localDb.saveTeam(team);
          }
          count++;
        } catch (_) {}
      }
      debugPrint('[BackupService] Restored $count models into $tableName');
    } catch (e) {
      debugPrint('[BackupService] Error restoring legacy $tableName: $e');
    }
  }

  /// Parse a legacy DateTime value (could be ISO string, Timestamp map, or int).
  DateTime? _parseLegacyDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Map && value['_type'] == 'DateTime') {
      return DateTime.tryParse(value['iso'] as String);
    }
    if (value is Map && value['_type'] == 'Timestamp') {
      return DateTime.fromMillisecondsSinceEpoch(
        (value['seconds'] as int) * 1000 +
            (value['nanoseconds'] as int) ~/ 1000000,
      );
    }
    if (value is String) return DateTime.tryParse(value);
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  /// Convert legacy backup data back to model-compatible types.
  Map<String, dynamic> _legacyDeserializeForModel(Map<String, dynamic> data) {
    final result = <String, dynamic>{};
    for (final entry in data.entries) {
      result[entry.key] = _legacyDeserializeValue(entry.value);
    }
    return result;
  }

  dynamic _legacyDeserializeValue(dynamic value) {
    if (value is Map && value['_type'] != null) {
      switch (value['_type']) {
        case 'Timestamp':
          return Timestamp(
            value['seconds'] as int,
            value['nanoseconds'] as int,
          );
        case 'DateTime':
          return DateTime.tryParse(value['iso'] as String);
        case 'GeoPoint':
          return GeoPoint(
            value['latitude'] as double,
            value['longitude'] as double,
          );
      }
    } else if (value is Map) {
      return value.map(
        (k, v) => MapEntry(k.toString(), _legacyDeserializeValue(v)),
      );
    } else if (value is List) {
      return value.map(_legacyDeserializeValue).toList();
    }
    return value;
  }

  /// Restore SharedPreferences from backup data.
  Future<void> _restoreSharedPreferences(Map prefsData) async {
    final prefs = await SharedPreferences.getInstance();

    for (final entry in prefsData.entries) {
      final key = entry.key;
      final wrapper = entry.value as Map;
      final type = wrapper['type'] as String;
      final value = wrapper['value'];

      switch (type) {
        case 'int':
          await prefs.setInt(key, value as int);
        case 'bool':
          await prefs.setBool(key, value as bool);
        case 'double':
          await prefs.setDouble(key, value as double);
        case 'string':
          await prefs.setString(key, value as String);
        case 'stringList':
          await prefs.setStringList(key, List<String>.from(value as List));
      }
    }
  }

  /// Restore attachment files from the ZIP archive.
  Future<void> _restoreAttachments(Archive archive) async {
    final appDir = await getApplicationDocumentsDirectory();

    for (final file in archive) {
      if (file.name.startsWith('attachments/') && !file.isFile) continue;
      if (!file.name.startsWith('attachments/')) continue;

      final relativePath = file.name.substring('attachments/'.length);
      final targetFile = File('${appDir.path}/$relativePath');

      // Create parent directories
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(file.content as List<int>);
    }
  }

  // ─── AUTO BACKUP ─────────────────────────────────────────────────────────

  /// The timestamp column that ACTUALLY exists on each backup table, so count
  /// and newest row come back in ONE statement per table. Keep in sync with the
  /// CREATE TABLE blocks in LocalDatabaseService: seven of these tables have no
  /// `updatedAt` column at all, and the old probe-then-fallback loop paid a
  /// thrown SQLite error per table on top of two separate scans.
  static const Map<String, String> _fingerprintTimeColumn = {
    'messages': 'createdAt',
    'tasks': 'updatedAt',
    'enquiries': 'updatedAt',
    'crm_enquiries': 'updatedAt',
    'sales_teams': 'updatedAt',
    'task_teams': 'updatedAt',
    'crm_teams': 'updatedAt',
    'task_drafts': 'updatedAt',
    'milestones': 'createdAt',
    'system_logs': 'createdAt',
    'actions': 'createdAt',
    'sales_actions': 'createdAt',
    'crm_actions': 'createdAt',
    'categories': 'createdAt',
  };

  /// Fingerprint of everything an auto-backup would capture: per-table row
  /// count + newest timestamp, plus the pref-key count. Lets the background run
  /// skip an unchanged database with a string compare instead of a full export.
  ///
  /// Attachments are deliberately NOT part of this. Auto-backups pass
  /// `includeAttachments: false`, so counting media bytes made the fingerprint
  /// describe data the snapshot never contains — one new photo re-triggered a
  /// "due" backup on an otherwise unchanged database. It also cost a recursive
  /// walk of the attachments dir with a `length()` await per file.
  ///
  /// Fourteen statements, each a full scan (only crm_enquiries indexes its
  /// timestamp), all serialized on sqflite's single DB thread. That is why this
  /// is reachable ONLY from the background gate — never from the launch path.
  Future<String> _computeDataFingerprint() async {
    final db = await LocalDatabaseService().database;
    final parts = <String>[];
    for (final table in _backupTables) {
      final col = _fingerprintTimeColumn[table] ?? 'createdAt';
      try {
        final r = await db.rawQuery(
          'SELECT COUNT(*) AS c, MAX($col) AS m FROM $table',
        );
        final row = r.isEmpty ? const <String, dynamic>{} : r.first;
        parts.add('$table:${row['c']}:${row['m']}');
      } catch (_) {
        parts.add('$table:err');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      parts.add('prefs:${prefs.getKeys().length}');
    } catch (_) {}

    return parts.join('|');
  }

  // Guards against overlapping auto-backup runs: two backgroundings in quick
  // succession, or a background run racing a manual export from Settings.
  // Static because [BackupService] is instantiated per call.
  static bool _autoBackupRunning = false;

  /// Auto-backup gate. Returns whether a snapshot is due plus the fingerprint
  /// that decided it, so [runAutoBackupIfDue] can hand it straight to
  /// [performAutoBackup] instead of paying for a second full scan.
  ///
  /// Due only when auto-backup is enabled, a password is set, the configured
  /// interval has elapsed AND the data fingerprint changed since the last
  /// snapshot. The first three tests are three pref reads, so a backgrounding
  /// inside the interval never touches the database at all; when nothing changed
  /// the stamp advances and the next check short-circuits the same way.
  ///
  /// BACKGROUND ONLY: past the interval gate this scans every backup table, so
  /// it must never be called while the user is looking at the app.
  Future<(bool, String?)> _autoBackupDueCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('auto_backup_enabled') ?? false)) {
        return (false, null);
      }
      final password = prefs.getString('auto_backup_password') ?? '';
      if (password.isEmpty) return (false, null); // Not configured yet

      final frequency = prefs.getString('auto_backup_frequency') ?? 'weekly';
      final intervalDays = switch (frequency) {
        'daily' => 1,
        'monthly' => 30,
        _ => 7,
      };
      final lastRun = prefs.getInt('auto_backup_last_run') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastRun < intervalDays * 24 * 60 * 60 * 1000) {
        return (false, null);
      }

      // Skip the export entirely when nothing changed since the last snapshot.
      // The fingerprint is orders of magnitude cheaper than materialising every
      // table and running zip/PBKDF2/AES over it — but it is still a scan, hence
      // the background-only contract above.
      final fingerprint = await _computeDataFingerprint();
      if (prefs.getString('auto_backup_fingerprint') == fingerprint) {
        await prefs.setInt('auto_backup_last_run', now);
        debugPrint('[Backup] Auto backup skipped — no data change');
        return (false, null);
      }
      return (true, fingerprint);
    } catch (e) {
      debugPrint('[Backup] Auto backup due-check failed: $e');
      return (false, null);
    }
  }

  /// The ONLY entry point to auto-backup, called from
  /// [AppLifecycleState.paused] so the scan and the export run while the app is
  /// not in use. There is no prompt and nothing on the launch path: enabling
  /// auto-backup in Settings IS the consent.
  ///
  /// Idempotent via [_autoBackupRunning] and the post-export stamp. A run the OS
  /// cuts short by freezing the process stamps nothing, so it simply retries on
  /// the next backgrounding.
  Future<void> runAutoBackupIfDue() async {
    final (due, fingerprint) = await _autoBackupDueCheck();
    if (!due) return;
    await performAutoBackup(fingerprint: fingerprint);
  }

  /// Directory the next auto backup goes to — the Settings choice is honored
  /// here, which it previously was NOT ([performAutoBackup] always wrote to app
  /// storage no matter what the location radio said).
  ///
  /// `auto_backup_location == 'folder'` means "the folder in
  /// `auto_backup_folder_path`". Anything else (including the legacy `'cloud'`
  /// and `'google_drive'` values the UI still shows as Coming Soon) stays in
  /// app storage. A chosen folder that cannot actually be written — deleted,
  /// unmounted SD card, or a SAF/content:// pick that `dart:io` has no
  /// permission for — falls back instead of failing: losing the snapshot is
  /// worse than storing it somewhere less convenient.
  Future<Directory> resolveAutoBackupDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final fallback = Directory('${appDir.path}/backups');

    String? chosen;
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('auto_backup_location') ?? 'local') == 'folder') {
        chosen = prefs.getString('auto_backup_folder_path');
      }
    } catch (_) {}
    if (chosen == null || chosen.isEmpty) return fallback;

    try {
      final dir = Directory(chosen);
      if (!await dir.exists()) await dir.create(recursive: true);
      // Writability probe: exists() alone passes for read-only trees.
      final probe = File('${dir.path}/.whatworks_write_test');
      await probe.writeAsBytes(const [0], flush: true);
      await probe.delete();
      return dir;
    } catch (e) {
      debugPrint('[Backup] Chosen folder unusable ($chosen): $e');
      return fallback;
    }
  }

  /// Heavy half of the auto-backup: materialises + encrypts the export into
  /// a cache-dir staging file, then publishes it under the FIXED
  /// [autoBackupFileName] — each run OVERWRITES the earlier snapshot (weekly
  /// by default). With `auto_backup_location == 'download'` the publish goes
  /// through [PublicStorageService] into `Download/WhatWorks`, a public folder
  /// that survives app deletion; a failed publish falls back to the chosen
  /// folder / app storage instead of losing the snapshot. Stamps the
  /// fingerprint and `auto_backup_last_run` only AFTER a successful export,
  /// so an interrupted run retries on the next backgrounding. Pass the
  /// [fingerprint] the due-check already computed to avoid a second scan.
  /// Returns the user-facing location the file landed in, or null when nothing
  /// ran.
  Future<String?> performAutoBackup({String? fingerprint}) async {
    if (_autoBackupRunning) return null;
    _autoBackupRunning = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final password = prefs.getString('auto_backup_password') ?? '';
      if (password.isEmpty) return null; // Not configured yet

      // Fingerprint before export so the stored value matches what we write.
      // [runAutoBackupIfDue] has already computed it — reusing that keeps a
      // background run to ONE scan of every table instead of two.
      final fp = fingerprint ?? await _computeDataFingerprint();

      // Stage in the cache dir: MediaStore cannot be written through a plain
      // path, and staging keeps every destination a cheap file copy.
      final cacheDir = await getTemporaryDirectory();
      final staging = File('${cacheDir.path}/$autoBackupFileName');
      if (await staging.exists()) await staging.delete();

      // Attachments excluded: they are already on-device, and bundling them
      // made every auto-backup a full multi-MB duplicate of the media dir.
      await exportBackup(password, staging.path, includeAttachments: false);

      String savedLocation;
      final location = prefs.getString('auto_backup_location') ?? 'download';
      String? publicRef;
      if (location == 'download') {
        publicRef = await PublicStorageService.instance.saveBackup(
          autoBackupFileName,
          staging.path,
        );
      }
      if (publicRef != null) {
        savedLocation =
            '${PublicStorageService.folderLabel}/$autoBackupFileName';
      } else {
        // 'folder' pick (validated by resolveAutoBackupDir) or app storage.
        final backupDir = await resolveAutoBackupDir();
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        final dest = File('${backupDir.path}/$autoBackupFileName');
        await staging.copy(dest.path);
        savedLocation = dest.path;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt('auto_backup_last_run', now);
      await prefs.setString('auto_backup_fingerprint', fp);
      // Where the newest snapshot actually landed (the UI shows it, and a
      // folder/download pick that silently fell back would otherwise be
      // invisible).
      await prefs.setString('auto_backup_last_path', savedLocation);

      try {
        await staging.delete();
      } catch (_) {}
      // One-time migration sweep: drop the old timestamped snapshots so the
      // single overwritten file is the only auto-backup left anywhere.
      await _pruneLegacyAutoBackups();
      debugPrint('[Backup] Auto backup saved: $savedLocation');
      return savedLocation;
    } catch (e) {
      debugPrint('[Backup] Auto backup failed: $e');
      return null;
    } finally {
      _autoBackupRunning = false;
    }
  }

  /// Deletes the pre-fixed-name `whatworks_auto_*` snapshots from the app
  /// backups dir and the custom folder (when one is configured).
  Future<void> _pruneLegacyAutoBackups() async {
    final dirs = <Directory>[];
    final appDir = await getApplicationDocumentsDirectory();
    dirs.add(Directory('${appDir.path}/backups'));
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('auto_backup_location') ?? '') == 'folder') {
        final chosen = prefs.getString('auto_backup_folder_path') ?? '';
        if (chosen.isNotEmpty) dirs.add(Directory(chosen));
      }
    } catch (_) {}
    for (final dir in dirs) {
      try {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync()) {
          if (entity is File && entity.path.contains('whatworks_auto_')) {
            await entity.delete();
          }
        }
      } catch (_) {}
    }
  }

  /// Locates the newest auto-backup snapshot for the restore screen, in
  /// discovery order: the public `Download/WhatWorks` file (a FRESH install
  /// can still see and read it through the MediaStore query even though an
  /// earlier install published it — that is the app-deletion safety net),
  /// the stored last path (folder / app storage), then the fixed name inside
  /// app storage. Returns a readable local file path, or null when absent.
  Future<String?> findLatestAutoBackupPath() async {
    if (await PublicStorageService.instance.backupExists(autoBackupFileName)) {
      final cachePath = await PublicStorageService.instance.readBackup(
        autoBackupFileName,
      );
      if (cachePath != null) return cachePath;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString('auto_backup_last_path') ?? '';
      if (last.isNotEmpty &&
          !last.startsWith(PublicStorageService.folderLabel) &&
          File(last).existsSync()) {
        return last;
      }
      final appDir = await getApplicationDocumentsDirectory();
      final inApp = File('${appDir.path}/backups/$autoBackupFileName');
      if (inApp.existsSync()) return inApp.path;
    } catch (_) {}
    return null;
  }
}
