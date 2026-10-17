import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/auth_provider.dart';
import '../../services/backup_service.dart';
import '../../services/public_storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/paywall_constants.dart';

/// Screen for creating and restoring encrypted backups.
class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  final BackupService _backupService = BackupService();

  // Export fields
  final TextEditingController _exportPasswordController =
      TextEditingController();
  final TextEditingController _exportConfirmPasswordController =
      TextEditingController();
  bool _obscureExportPassword = true;
  bool _obscureExportConfirmPassword = true;

  // Import fields
  final TextEditingController _importPasswordController =
      TextEditingController();
  bool _obscureImportPassword = true;
  String? _selectedFilePath;

  // State
  bool _isProcessing = false;
  String _statusMessage = '';
  bool _isSuccess = false;
  bool _isError = false;

  // Auto-backup settings
  bool _autoBackupEnabled = false;

  /// 'download' = public Download/WhatWorks via MediaStore (survives app
  /// deletion — the default), 'local' = inside app storage, 'folder' = the
  /// device folder in [_autoBackupFolderPath], 'google_drive' = still Coming
  /// Soon (disabled). Legacy 'cloud' normalizes to the new 'download' default
  /// on load (Firebase Storage backup was never implemented).
  String _autoBackupLocation = 'download';
  String? _autoBackupFolderPath; // Chosen via the folder picker
  String? _lastAutoBackupPath; // Where the newest snapshot actually landed
  String _autoBackupFrequency = 'weekly'; // 'daily', 'weekly', 'monthly'
  String? _autoSelectedLabel; // Set when restore pre-picks the newest backup

  @override
  void initState() {
    super.initState();
    _loadAutoBackupSettings();
    _autoSelectLatestBackup();
  }

  /// Pre-pick the newest auto backup so restoring is "type password → Restore":
  /// the fixed-name file is looked up in Download/WhatWorks first (that lookup
  /// works even after a reinstall, which is the whole point of the public
  /// folder), then in the last-used disk location and app storage.
  Future<void> _autoSelectLatestBackup() async {
    final path = await _backupService.findLatestAutoBackupPath();
    if (path == null || !mounted || _selectedFilePath != null) return;
    final inPublic = await PublicStorageService.instance
        .backupExists(BackupService.autoBackupFileName);
    if (!mounted || _selectedFilePath != null) return;
    setState(() {
      _selectedFilePath = path;
      _autoSelectedLabel = inPublic
          ? '${PublicStorageService.folderLabel}/'
                '${BackupService.autoBackupFileName} (auto-selected)'
          : path;
    });
  }

  Future<void> _loadAutoBackupSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _autoBackupEnabled = prefs.getBool('auto_backup_enabled') ?? false;
        final saved = prefs.getString('auto_backup_location') ?? 'download';
        _autoBackupLocation = switch (saved) {
          'folder' => 'folder',
          'local' => 'local',
          _ => 'download',
        };
        _autoBackupFolderPath = prefs.getString('auto_backup_folder_path');
        _lastAutoBackupPath = prefs.getString('auto_backup_last_path');
        _autoBackupFrequency =
            prefs.getString('auto_backup_frequency') ?? 'weekly';
      });
    }
  }

  Future<void> _saveAutoBackupSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_backup_enabled', _autoBackupEnabled);
    await prefs.setString('auto_backup_location', _autoBackupLocation);
    await prefs.setString('auto_backup_frequency', _autoBackupFrequency);
    // Persist the picked folder here too so a location change and its path are
    // always written together (an empty string means "no folder chosen yet").
    await prefs.setString('auto_backup_folder_path', _autoBackupFolderPath ?? '');
  }

  /// Choose a device folder for auto backups. On Android a tree picked through
  /// SAF is often returned as a `content://` URI (or a path the app cannot
  /// write without MANAGE_EXTERNAL_STORAGE), so the pick is validated by
  /// actually creating and deleting a probe file — a folder that fails the
  /// probe is rejected here instead of being silently ignored at backup time
  /// ([BackupService.resolveAutoBackupDir] keeps the same fallback rule).
  Future<void> _pickBackupFolder() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose Backup Folder',
      );
    } catch (_) {
      path = null; // Not supported on this platform
    }
    if (path == null || path.isEmpty) return;
    if (!mounted) return;

    final probe = File('$path${Platform.pathSeparator}.whatworks_write_test');
    try {
      await probe.writeAsBytes(const [0], flush: true);
      await probe.delete();
    } catch (_) {
      setState(() {
        _isSuccess = false;
        _isError = true;
        _statusMessage =
            'That folder is not writable by the app. Pick another one, '
            'or keep backups in app storage.';
      });
      return;
    }

    setState(() {
      _autoBackupFolderPath = path;
      _autoBackupLocation = 'folder';
      _isError = false;
      _statusMessage = 'Auto backups will be saved to the selected folder.';
    });
    await _saveAutoBackupSettings();
  }

  /// Enabling auto-backup requires an encryption password (backups are
  /// always AES-encrypted). Stored locally; the same password is needed
  /// to restore an auto-backup file.
  Future<void> _onAutoBackupToggled(bool value) async {
    if (!value) {
      setState(() => _autoBackupEnabled = false);
      await _saveAutoBackupSettings();
      return;
    }

    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Backup Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Auto backups are encrypted. You will need this password to restore them.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Password (min 4 characters)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Enable'),
          ),
        ],
      ),
    );

    if (password == null || password.length < 4) {
      if (password != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password must be at least 4 characters'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return; // Toggle stays off
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auto_backup_password', password);
    // Reset schedule so the first auto backup runs the next time the app goes to
    // the background — backups never run while the user is in the app.
    await prefs.setInt('auto_backup_last_run', 0);
    if (mounted) {
      setState(() => _autoBackupEnabled = true);
      await _saveAutoBackupSettings();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Auto backup enabled — runs next time the app goes to the background',
          ),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  @override
  void dispose() {
    _exportPasswordController.dispose();
    _exportConfirmPasswordController.dispose();
    _importPasswordController.dispose();
    super.dispose();
  }

  Future<void> _exportBackup() async {
    final password = _exportPasswordController.text.trim();
    final confirmPassword = _exportConfirmPasswordController.text.trim();

    if (password.isEmpty) {
      _showError('Please enter a password');
      return;
    }
    if (password.length < 4) {
      _showError('Password must be at least 4 characters');
      return;
    }
    if (password != confirmPassword) {
      _showError('Passwords do not match');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Choosing save location...';
      _isSuccess = false;
      _isError = false;
    });

    String? savePath;
    // On mobile FilePicker.saveFile is unavailable — we save to internal
    // storage and then open the share sheet so the user can put the file
    // somewhere accessible (Downloads, Drive, WhatsApp...).
    bool shareAfterSave = false;

    // Try FilePicker saveFile first (works on desktop)
    try {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Backup',
        fileName:
            'whatworks_backup_${DateTime.now().millisecondsSinceEpoch}.whatworksbackup',
        type: FileType.any,
      );
    } catch (e) {
      // saveFile not supported on this platform, use fallback
      print('[Backup] saveFile not supported, using fallback: $e');
    }

    // Fallback: Save to app's documents directory (mobile platforms)
    if (savePath == null) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final backupDir = Directory('${appDir.path}/backups');
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        savePath =
            '${backupDir.path}/whatworks_backup_${DateTime.now().millisecondsSinceEpoch}.whatworksbackup';
        shareAfterSave = true;

        if (mounted) {
          setState(() {
            _statusMessage = 'Saving to local storage...';
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _statusMessage = 'Failed to determine save location: $e';
            _isError = true;
          });
        }
        return;
      }
    }

    try {
      await _backupService.exportBackup(
        password,
        savePath,
        onProgress: (message) {
          if (mounted) setState(() => _statusMessage = message);
        },
      );

      // On mobile, hand the file to the share sheet so the user can
      // actually save it somewhere they can find it again.
      if (shareAfterSave && mounted) {
        setState(() => _statusMessage = 'Choose where to save your backup...');
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(savePath)],
            subject: 'WhatWorks Backup',
          ),
        );
      }

      // Show user-friendly path
      final displayPath = savePath.contains('/backups/')
          ? 'shared via the system share sheet (also kept in app storage)'
          : savePath;

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Backup created — $displayPath';
          _isSuccess = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Backup failed: $e';
          _isError = true;
        });
      }
    }
  }

  Future<void> _pickImportFile() async {
    // Open the system picker in the folder the last on-disk backup landed in,
    // so the fixed-name file is the first thing the user sees. (A content-URI
    // or cache path is not a browsable directory, so it is skipped.)
    String? initialDir;
    final last = _lastAutoBackupPath;
    if (last != null &&
        last.startsWith(Platform.pathSeparator) &&
        Directory(File(last).parent.path).existsSync()) {
      initialDir = File(last).parent.path;
    }
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select Backup File',
      type: FileType.any,
      allowMultiple: false,
      initialDirectory: initialDir,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _selectedFilePath = result.files.first.path;
        _autoSelectedLabel = null; // An explicit pick replaces the auto-pick.
        _isSuccess = false;
        _isError = false;
        _statusMessage = '';
      });
    }
  }

  Future<void> _importBackup() async {
    if (_selectedFilePath == null) {
      _showError('Please select a backup file');
      return;
    }

    final password = _importPasswordController.text.trim();
    if (password.isEmpty) {
      _showError('Please enter the backup password');
      return;
    }

    // Confirm before restoring
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Backup'),
        content: const Text(
          'This will merge backup data into your current app data. '
          'Existing data with the same IDs will be overwritten.\n\n'
          'Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Restore',
              style: TextStyle(color: AppTheme.primaryGreen),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Starting restore...';
      _isSuccess = false;
      _isError = false;
    });

    try {
      await _backupService.importBackup(
        password,
        _selectedFilePath!,
        onProgress: (message) {
          if (mounted) setState(() => _statusMessage = message);
        },
      );

      setState(() {
        _isProcessing = false;
        _statusMessage =
            'Restore complete! Please restart the app for all changes to take effect.';
        _isSuccess = true;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Restore failed: $e';
        _isError = true;
      });
    }
  }

  void _showError(String message) {
    setState(() {
      _statusMessage = message;
      _isError = true;
      _isSuccess = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup & Restore'),
        backgroundColor: AppTheme.primaryGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildExportSection(),
            const SizedBox(height: 24),
            _buildAutoBackupSection(),
            const SizedBox(height: 24),
            _buildImportSection(),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildStatusCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildExportSection() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  color: AppTheme.primaryGreen,
                  size: 28,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Create Backup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Export all your data (messages, tasks, settings, attachments) to an encrypted file.',
              style: TextStyle(color: AppTheme.lightText, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _exportPasswordController,
              obscureText: _obscureExportPassword,
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: 'Enter a password to protect backup',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureExportPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                  onPressed: () => setState(
                    () => _obscureExportPassword = !_obscureExportPassword,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _exportConfirmPasswordController,
              obscureText: _obscureExportConfirmPassword,
              decoration: InputDecoration(
                labelText: 'Confirm Password',
                hintText: 'Re-enter the password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureExportConfirmPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                  onPressed: () => setState(
                    () => _obscureExportConfirmPassword =
                        !_obscureExportConfirmPassword,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _exportBackup,
                icon: const Icon(Icons.backup),
                label: const Text('Create Backup'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoBackupSection() {
    final planType = context.read<AuthProvider>().effectivePlanType;
    // Auto backup is a real Premium-only feature — gate with the always-active
    // plan check, not the disabled legacy isPremium
    final isPremium = PaywallLimits.isPremiumUser(planType);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_sync_outlined,
                  color: AppTheme.primaryGreen,
                  size: 28,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Auto Backup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!isPremium)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.workspace_premium,
                          color: Colors.amber.shade700,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Premium',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber.shade800,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Switch(
                    value: _autoBackupEnabled,
                    onChanged: (value) => _onAutoBackupToggled(value),
                    activeColor: AppTheme.primaryGreen,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isPremium
                  ? 'Automatically backup your data at scheduled intervals, in the background — never while you are using the app.'
                  : 'Protect your data with automatic cloud backups. Required if you lose your phone or reinstall the app.',
              style: const TextStyle(color: AppTheme.lightText, fontSize: 13),
            ),
            if (!isPremium) ...[
              const SizedBox(height: 12),
              // Premium feature preview (disabled)
              Opacity(
                opacity: 0.5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    _buildRadioTile(
                      title: 'Download Folder',
                      subtitle: 'Safe even if the app is deleted',
                      value: 'download',
                      icon: Icons.download_for_offline_outlined,
                      enabled: false,
                    ),
                    _buildRadioTile(
                      title: 'Selected Folder',
                      subtitle: 'Choose a folder on your device',
                      value: 'folder',
                      icon: Icons.folder_outlined,
                      enabled: false,
                    ),
                    _buildRadioTile(
                      title: 'App Storage',
                      subtitle: 'Deleted when the app is uninstalled',
                      value: 'local',
                      icon: Icons.lock_outline,
                      enabled: false,
                    ),
                    _buildRadioTile(
                      title: 'Google Drive',
                      subtitle: 'Backup to your Google Drive',
                      value: 'google_drive',
                      icon: Icons.cloud_outlined,
                      enabled: false,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    showPaywallDialog(
                      context,
                      feature: 'Auto Backup to Cloud',
                      detail:
                          'Protect your data with automatic cloud backups. If you lose your phone or reinstall the app, your messages and tasks will be safe.',
                    );
                  },
                  icon: const Icon(Icons.workspace_premium, size: 18),
                  label: const Text('Upgrade to Premium'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
            if (isPremium && _autoBackupEnabled) ...[
              const SizedBox(height: 16),
              // Backup location
              const Text(
                'Backup Location',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              _buildRadioTile(
                title: 'Download Folder (Recommended)',
                subtitle:
                    'Saves ${BackupService.autoBackupFileName} in '
                    '${PublicStorageService.folderLabel} — safe even if the '
                    'app is deleted',
                value: 'download',
                icon: Icons.download_for_offline_outlined,
              ),
              _buildRadioTile(
                title: 'Selected Folder',
                subtitle:
                    _autoBackupFolderPath ?? 'No folder selected yet',
                value: 'folder',
                icon: Icons.folder_outlined,
              ),
              // The folder radio is only meaningful once a real, writable
              // folder has been chosen, so the picker lives right under it.
              if (_autoBackupLocation == 'folder')
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _pickBackupFolder,
                      icon: const Icon(Icons.drive_folder_upload, size: 18),
                      label: Text(
                        _autoBackupFolderPath == null
                            ? 'Choose Folder'
                            : 'Change Folder',
                      ),
                    ),
                  ),
                ),
              _buildRadioTile(
                title: 'App Storage',
                subtitle: 'Private to the app — deleted when the app is '
                    'uninstalled',
                value: 'local',
                icon: Icons.lock_outline,
              ),
              _buildRadioTile(
                title: 'Google Drive (Coming Soon)',
                subtitle: 'Backup to your Google Drive',
                value: 'google_drive',
                icon: Icons.cloud_outlined,
                enabled: false,
              ),
              const SizedBox(height: 16),
              // Backup frequency
              const Text(
                'Backup Frequency',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              _buildFrequencyRadio('Daily', 'daily'),
              _buildFrequencyRadio('Weekly', 'weekly'),
              _buildFrequencyRadio('Monthly', 'monthly'),
              const SizedBox(height: 8),
              const Text(
                'When the interval passes and your data changed, the app asks '
                'before backing up. Each backup OVERWRITES the same file ('
                'whatworks_backup.whatworksbackup), so only the latest '
                'snapshot is kept in the location above.',
                style: TextStyle(fontSize: 12, color: AppTheme.lightText),
              ),
              // Where the newest snapshot actually landed. A 'Selected Folder'
              // pick that was unwritable silently falls back to app storage at
              // backup time, so this is the ground truth the user should see.
              if (_lastAutoBackupPath != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Last backup: ${_lastAutoBackupPath!}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.lightText,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRadioTile({
    required String title,
    required String value,
    required IconData icon,
    String? subtitle,
    bool enabled = true,
  }) {
    return RadioListTile<String>(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          color: enabled ? null : AppTheme.lightText,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: enabled
                    ? AppTheme.lightText
                    : AppTheme.lightText.withOpacity(0.5),
              ),
            )
          : null,
      secondary: Icon(
        icon,
        color: enabled
            ? AppTheme.primaryGreen
            : AppTheme.lightText.withOpacity(0.5),
      ),
      value: value,
      groupValue: _autoBackupLocation,
      onChanged: enabled
          ? (val) {
              if (val != null) {
                setState(() => _autoBackupLocation = val);
                _saveAutoBackupSettings();
              }
            }
          : null,
      contentPadding: EdgeInsets.zero,
      activeColor: AppTheme.primaryGreen,
    );
  }

  Widget _buildFrequencyRadio(String label, String value) {
    return RadioListTile<String>(
      title: Text(label, style: const TextStyle(fontSize: 14)),
      value: value,
      groupValue: _autoBackupFrequency,
      onChanged: (val) {
        if (val != null) {
          setState(() => _autoBackupFrequency = val);
          _saveAutoBackupSettings();
        }
      },
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeColor: AppTheme.primaryGreen,
    );
  }

  Widget _buildImportSection() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_download_outlined,
                  color: AppTheme.primaryGreen,
                  size: 28,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Restore Backup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Import a previously created backup file. You will need the password used when creating the backup.',
              style: TextStyle(color: AppTheme.lightText, fontSize: 13),
            ),
            const SizedBox(height: 16),
            // File picker
            OutlinedButton.icon(
              onPressed: _isProcessing ? null : _pickImportFile,
              icon: const Icon(Icons.folder_open),
              label: Text(
                _selectedFilePath != null
                    ? 'Change File'
                    : 'Select Backup File',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryGreen,
                side: const BorderSide(color: AppTheme.primaryGreen),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
            if (_selectedFilePath != null) ...[
              const SizedBox(height: 8),
              Text(
                _autoSelectedLabel ??
                    _selectedFilePath!.split(Platform.pathSeparator).last,
                style: const TextStyle(fontSize: 12, color: AppTheme.lightText),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _importPasswordController,
              obscureText: _obscureImportPassword,
              decoration: InputDecoration(
                labelText: 'Backup Password',
                hintText: 'Enter the password used for this backup',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureImportPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                  onPressed: () => setState(
                    () => _obscureImportPassword = !_obscureImportPassword,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _importBackup,
                icon: const Icon(Icons.restore),
                label: const Text('Restore Backup'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    Color bgColor;
    Color textColor;
    IconData icon;

    if (_isSuccess) {
      bgColor = Colors.green.shade50;
      textColor = Colors.green.shade800;
      icon = Icons.check_circle_outline;
    } else if (_isError) {
      bgColor = Colors.red.shade50;
      textColor = Colors.red.shade800;
      icon = Icons.error_outline;
    } else {
      bgColor = Colors.blue.shade50;
      textColor = Colors.blue.shade800;
      icon = Icons.info_outline;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          if (_isProcessing)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, color: textColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
