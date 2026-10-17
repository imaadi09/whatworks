import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../models/message.dart';
import '../../services/local_database_service.dart';
import '../../services/local_storage_service.dart';
import '../../services/storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';

/// Shared attachment + voice-recording pipeline used by Task Detail (base
/// module) and Sales/CRM Detail. Extracted verbatim from Task Detail;
/// screen-specific data, sync and theming are provided via chat* hooks.
///
/// Provides concrete implementations of [chatLocalPathFor] and
/// [chatRetryUpload] required by DetailChatBubblesMixin, so apply this
/// mixin AFTER DetailChatBubblesMixin in the `with` clause.
mixin DetailChatAttachmentsMixin<T extends StatefulWidget> on State<T> {
  // Voice recording state
  final AudioRecorder audioRecorder = AudioRecorder();
  final AudioPlayer voicePreviewPlayer = AudioPlayer();
  bool isRecording = false;
  String? recordingPath;
  int recordingSeconds = 0;
  Timer? recordingTimer;
  bool voicePreviewVisible = false;

  /// Call from the host screen's dispose().
  void disposeDetailChatAttachments() {
    recordingTimer?.cancel();
    audioRecorder.dispose();
    voicePreviewPlayer.dispose();
  }

  // ---- Data hooks ----
  String get chatEntityId;
  String get chatCurrentUserId;
  Map<String, double> get chatUploadProgress;
  List<MessageModel> get chatMessages;
  void chatRefreshMessages();
  void chatScrollToBottom();
  Future<void> chatSyncMessage(MessageModel message);

  // ---- Storage hooks ----
  String get chatStorageFolder; // 'tasks' | 'sales'
  String? get chatSqliteParentType; // null | 'enquiry'

  // ---- Theme hooks ----
  Color get chatAccentColor;

  // Memoized local paths keyed by message id so rebuilds resolve
  // synchronously and never flash the network image for cached files.
  final Map<String, String?> _chatLocalPathCache = {};

  // Synchronous lookup of a previously resolved local path.
  String? chatCachedLocalPath(MessageModel message) {
    final cached = _chatLocalPathCache[message.id];
    if (cached != null && File(cached).existsSync()) return cached;
    return null;
  }

  // Get local cached image path if available
  Future<String?> chatLocalPathFor(MessageModel message) async {
    if (message.fileUrl == null || message.fileName == null) return null;

    final cached = _chatLocalPathCache[message.id];
    if (cached != null && File(cached).existsSync()) return cached;

    try {
      final localStorage = LocalStorageService();
      final localPath = await localStorage.getLocalAttachmentPath(
        chatEntityId,
        message.fileName!,
      );

      if (localPath != null) _chatLocalPathCache[message.id] = localPath;
      return localPath;
    } catch (e) {
      print('[DetailChat] Error getting local image path: $e');
      return null;
    }
  }

  /// Retry uploading a failed attachment message.
  Future<void> chatRetryUpload(MessageModel message) async {
    final localDb = LocalDatabaseService();
    final storage = StorageService();

    // Reset to pending
    await localDb.clearMessageUploadError(message.id);
    setState(() {
      final idx = chatMessages.indexWhere((m) => m.id == message.id);
      if (idx != -1) {
        chatMessages[idx] = message.copyWith(
          fileUrl: 'pending',
          uploadError: null,
        );
        chatRefreshMessages();
      }
    });

    // Show progress in bubble
    void onProgress(double p) {
      if (!mounted) return;
      setState(() => chatUploadProgress[message.id] = p);
    }

    try {
      String? downloadUrl;
      final localPath = await chatLocalPathFor(message);

      switch (message.type) {
        case MessageType.image:
          if (localPath != null && await File(localPath).exists()) {
            downloadUrl = await storage.uploadImageFromPath(
              chatEntityId,
              localPath,
              onProgress: onProgress,
            );
          } else {
            throw Exception('Local file not found for retry');
          }
          break;
        case MessageType.file:
          if (localPath != null && await File(localPath).exists()) {
            final fileRef = FirebaseStorage.instance.ref().child(
              '$chatStorageFolder/$chatEntityId/files/${message.id}_${message.fileName}',
            );
            final uploadTask = fileRef.putFile(File(localPath));
            uploadTask.snapshotEvents.listen((s) {
              if (s.totalBytes > 0)
                onProgress(s.bytesTransferred / s.totalBytes);
            });
            final snapshot = await uploadTask.timeout(
              const Duration(seconds: 60),
              onTimeout: () => throw Exception(
                'Upload timed out. Check your connection and try again.',
              ),
            );
            if (snapshot.state == TaskState.error)
              throw Exception('Upload failed. Please try again.');
            downloadUrl = await snapshot.ref.getDownloadURL();
          } else {
            throw Exception('Local file not found for retry');
          }
          break;
        case MessageType.voice:
          if (localPath != null && await File(localPath).exists()) {
            downloadUrl = await storage.uploadVoiceNote(
              chatEntityId,
              File(localPath),
              onProgress: onProgress,
            );
          } else {
            // Try cached voice file
            final localStorage = LocalStorageService();
            final dir = await localStorage.getAttachmentDirectory();
            final cachedVoice = File('${dir.path}/voice_${message.id}.m4a');
            if (await cachedVoice.exists()) {
              downloadUrl = await storage.uploadVoiceNote(
                chatEntityId,
                cachedVoice,
                onProgress: onProgress,
              );
            } else {
              throw Exception('Voice file not found for retry');
            }
          }
          break;
        default:
          throw Exception('Unsupported message type for retry');
      }

      if (!mounted) return;
      chatUploadProgress.remove(message.id);

      if (downloadUrl != null) {
        await localDb.updateMessageFileUrl(message.id, downloadUrl);
        final updatedMsg = message.copyWith(
          fileUrl: downloadUrl,
          uploadError: null,
        );
        setState(() {
          final idx = chatMessages.indexWhere((m) => m.id == message.id);
          if (idx != -1) chatMessages[idx] = updatedMsg;
          chatRefreshMessages();
        });
        // Sync to Firestore
        try {
          chatSyncMessage(updatedMsg);
        } catch (e) {
          print('[DetailChat] Error syncing retried message: $e');
        }
      } else {
        markMessageUploadFailed(message.id, 'Upload returned no URL');
      }
    } catch (e) {
      if (!mounted) return;
      chatUploadProgress.remove(message.id);
      markMessageUploadFailed(
        message.id,
        e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// Mark a message as upload-failed in both local DB and in-memory list.
  void markMessageUploadFailed(String messageId, String error) {
    final localDb = LocalDatabaseService();
    localDb.markMessageUploadFailed(messageId, error);
    setState(() {
      final idx = chatMessages.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        chatMessages[idx] = chatMessages[idx].copyWith(
          fileUrl: 'failed',
          uploadError: error,
        );
        chatRefreshMessages();
      }
    });
    // Show error SnackBar
    if (mounted) {
      showAttachmentErrorSnackBar(messageId, error);
    }
  }

  /// Show brief SnackBar for attachment upload failures (retry is on the bubble).
  void showAttachmentErrorSnackBar(String messageId, String error) {
    String displayError;
    if (error.contains('timed out') || error.contains('timeout')) {
      displayError = 'Upload timed out — will retry automatically';
    } else {
      displayError = 'Upload pending — will retry when connected';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(displayError),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // VOICE RECORDING — tap to start, tap to stop, preview, send
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> startRecording() async {
    try {
      // Check permission
      if (!await audioRecorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission required'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Get temp directory
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${Helpers.generateId()}.m4a';

      // Start recording
      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      setState(() {
        isRecording = true;
        recordingSeconds = 0;
        recordingPath = path;
        voicePreviewVisible = false;
      });

      // Start timer
      recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() => recordingSeconds = timer.tick);
        }
      });

      print('[DetailChat] Recording started: $path');
    } catch (e) {
      print('[DetailChat] Error starting recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot start recording: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> stopRecording() async {
    try {
      recordingTimer?.cancel();
      final path = await audioRecorder.stop();

      if (path != null) {
        setState(() {
          isRecording = false;
          recordingPath = path;
          voicePreviewVisible = true;
        });
        print('[DetailChat] Recording stopped: $path (${recordingSeconds}s)');
      } else {
        // Recording was cancelled
        setState(() {
          isRecording = false;
          recordingPath = null;
          voicePreviewVisible = false;
        });
      }
    } catch (e) {
      print('[DetailChat] Error stopping recording: $e');
      setState(() {
        isRecording = false;
        voicePreviewVisible = false;
      });
    }
  }

  void cancelRecording() {
    recordingTimer?.cancel();
    // The abandoned take is never uploaded, so its temp file is pure leak —
    // delete it once the recorder has flushed and released the handle.
    final discardedPath = recordingPath;
    audioRecorder.stop().then((_) async {
      if (discardedPath != null) {
        try {
          await File(discardedPath).delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          isRecording = false;
          recordingPath = null;
          recordingSeconds = 0;
          voicePreviewVisible = false;
        });
      }
    });
  }

  Future<void> sendVoiceMessage() async {
    if (recordingPath == null || recordingSeconds < 1) {
      setState(() {
        voicePreviewVisible = false;
        recordingPath = null;
      });
      return;
    }

    final recordedFile = File(recordingPath!);
    if (!await recordedFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording file not found'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        voicePreviewVisible = false;
        recordingPath = null;
      });
      return;
    }

    // Reset UI immediately
    setState(() {
      voicePreviewVisible = false;
      recordingPath = null;
    });

    try {
      final msgId = Helpers.generateId();
      final fileName = 'voice_$msgId.m4a';

      // 1. Cache voice file locally FIRST (before upload)
      File uploadFile = recordedFile;
      try {
        final localStorage = LocalStorageService();
        final attachDir = await localStorage.getAttachmentDirectory();
        final cachedVoice = File('${attachDir.path}/voice_${msgId}.m4a');
        await recordedFile.copy(cachedVoice.path);
        // Upload from the permanent copy — it is the exact path the retry
        // service rebuilds from the message row, so a failed first attempt
        // retries the same bytes.
        uploadFile = cachedVoice;
      } catch (e) {
        print(
          '[DetailChat] Error caching voice file locally before upload: $e',
        );
      }
      // The temp recording has served its purpose once the permanent copy
      // exists; without this the cache dir grows by one m4a per voice note.
      if (uploadFile != recordedFile) {
        try {
          await recordedFile.delete();
        } catch (_) {}
      }

      // 2. Save to SQLite with pending URL
      final voiceMessage = MessageModel(
        id: msgId,
        taskId: chatEntityId,
        senderId: chatCurrentUserId,
        text: '',
        type: MessageType.voice,
        fileUrl: 'pending',
        fileName: fileName,
        duration: recordingSeconds,
        createdAt: DateTime.now(),
      );
      await LocalDatabaseService().saveMessage(
        voiceMessage,
        parentType: chatSqliteParentType,
      );
      setState(() {
        chatMessages.add(voiceMessage);
        chatRefreshMessages();
      });
      chatScrollToBottom();

      // 3. Upload to Firebase Storage with progress tracking
      final downloadUrl = await StorageService().uploadVoiceNote(
        chatEntityId,
        uploadFile,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => chatUploadProgress[msgId] = p);
        },
      );

      chatUploadProgress.remove(msgId);

      if (downloadUrl != null) {
        // 4. Update SQLite with real URL
        await LocalDatabaseService().updateMessageFileUrl(msgId, downloadUrl);

        final updatedMsg = MessageModel(
          id: voiceMessage.id,
          taskId: voiceMessage.taskId,
          senderId: voiceMessage.senderId,
          text: voiceMessage.text,
          type: voiceMessage.type,
          fileUrl: downloadUrl,
          fileName: voiceMessage.fileName,
          duration: voiceMessage.duration,
          createdAt: voiceMessage.createdAt,
        );
        setState(() {
          final idx = chatMessages.indexWhere((m) => m.id == msgId);
          if (idx != -1) chatMessages[idx] = updatedMsg;
          chatRefreshMessages();
        });

        // 5. Sync to Firestore
        try {
          await chatSyncMessage(updatedMsg);
        } catch (e) {
          print('[DetailChat] Error saving voice message: $e');
        }
      } else {
        // Upload failed — mark failed so the retry overlay shows
        markMessageUploadFailed(msgId, 'Upload returned no URL');
      }
    } catch (e) {
      print('[DetailChat] Error sending voice message: $e');
      if (mounted) {
        final errorMsg = e.toString().replaceAll('Exception: ', '');
        // Find the last voice message with pending state
        final pendingMsg = chatMessages.lastWhere(
          (m) =>
              m.type == MessageType.voice &&
              (m.fileUrl == 'pending' || m.fileUrl == 'failed'),
          orElse: () => chatMessages.first,
        );
        markMessageUploadFailed(pendingMsg.id, errorMsg);
      }
    }
  }

  String formatRecordingTime(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Widget buildRecordingOverlay() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          // Pulsing red dot
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          // Recording text + time
          Expanded(
            child: Row(
              children: [
                const Text(
                  'Recording',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatRecordingTime(recordingSeconds),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ),
          // Cancel button
          GestureDetector(
            onTap: cancelRecording,
            child: Container(
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close, color: Colors.red, size: 20),
            ),
          ),
          const SizedBox(width: 8),
          // Stop button
          GestureDetector(
            onTap: stopRecording,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.stop, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildVoicePreview() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: chatAccentColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: chatAccentColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          // Play/pause button
          GestureDetector(
            onTap: toggleVoicePreviewPlayback,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: chatAccentColor,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Waveform bars
          Expanded(
            child: SizedBox(
              height: 28,
              child: Row(
                children: List.generate(30, (i) {
                  final height = 4.0 + (i % 5) * 3.0 + (i % 3) * 2.0;
                  return Container(
                    width: 3,
                    height: height,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: chatAccentColor.withOpacity(
                        i < (recordingSeconds * 2) ? 0.8 : 0.3,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Duration
          Text(
            formatRecordingTime(recordingSeconds),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppTheme.secondaryText,
            ),
          ),
          const SizedBox(width: 8),
          // Delete button (discard recording)
          GestureDetector(
            onTap: () {
              setState(() {
                voicePreviewVisible = false;
                recordingPath = null;
                recordingSeconds = 0;
              });
            },
            child: const Icon(
              Icons.delete_outline,
              color: Colors.red,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> toggleVoicePreviewPlayback() async {
    if (recordingPath == null) return;
    try {
      if (voicePreviewPlayer.state == PlayerState.playing) {
        await voicePreviewPlayer.pause();
      } else {
        await voicePreviewPlayer.play(DeviceFileSource(recordingPath!));
      }
    } catch (e) {
      print('[DetailChat] Error playing voice preview: $e');
    }
  }

  // Pick image from gallery — SQLite-first, then Firebase Storage upload
  Future<void> attachImage() async {
    String? msgId;
    try {
      // 1. Pick image first
      final pickedFile = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile == null) return;

      msgId = Helpers.generateId();
      final fileName = 'image_$msgId.jpg';

      // 2. Cache image locally FIRST (before upload) so it can be opened even
      // if upload fails. The cache step also downsamples the gallery original
      // (1600px / JPEG q80), so the upload — and every recipient's download —
      // carries the compressed bytes while the original never leaves the picker.
      String uploadPath = pickedFile.path;
      try {
        final cachedPath = await LocalStorageService().saveAttachmentLocally(
          chatEntityId,
          fileName,
          File(pickedFile.path),
        );
        if (cachedPath.isNotEmpty) uploadPath = cachedPath;
      } catch (e) {
        print('[DetailChat] Error caching image locally before upload: $e');
      }

      // 3. Save to SQLite with pending URL
      final imageMessage = MessageModel(
        id: msgId,
        taskId: chatEntityId,
        senderId: chatCurrentUserId,
        text: '',
        type: MessageType.image,
        fileUrl: 'pending',
        fileName: fileName,
        createdAt: DateTime.now(),
      );
      await LocalDatabaseService().saveMessage(
        imageMessage,
        parentType: chatSqliteParentType,
      );
      setState(() {
        chatMessages.add(imageMessage);
        chatRefreshMessages();
      });
      chatScrollToBottom();

      // 4. Upload to Firebase Storage with progress tracking
      final downloadUrl = await StorageService().uploadImageFromPath(
        chatEntityId,
        uploadPath,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => chatUploadProgress[msgId!] = p);
        },
      );

      if (!mounted) return;
      chatUploadProgress.remove(msgId);

      if (downloadUrl != null) {
        // 5. Update SQLite with real URL
        await LocalDatabaseService().updateMessageFileUrl(msgId, downloadUrl);

        final updatedMsg = MessageModel(
          id: imageMessage.id,
          taskId: imageMessage.taskId,
          senderId: imageMessage.senderId,
          text: imageMessage.text,
          type: imageMessage.type,
          fileUrl: downloadUrl,
          fileName: imageMessage.fileName,
          duration: imageMessage.duration,
          createdAt: imageMessage.createdAt,
        );
        setState(() {
          final idx = chatMessages.indexWhere((m) => m.id == msgId);
          if (idx != -1) chatMessages[idx] = updatedMsg;
          chatRefreshMessages();
        });

        // 6. Sync to Firestore
        try {
          await chatSyncMessage(updatedMsg);
        } catch (e) {
          print('[DetailChat] Error saving image message: $e');
        }
      } else {
        // Upload failed — mark failed so the retry overlay shows
        markMessageUploadFailed(msgId, 'Upload returned no URL');
      }
    } catch (e) {
      print('[DetailChat] Error picking/uploading image: $e');
      if (mounted) {
        final errorMsg = e.toString().replaceAll('Exception: ', '');
        markMessageUploadFailed(msgId!, errorMsg);
      }
    }
  }

  // Take photo with camera — SQLite-first, then Firebase Storage upload
  Future<void> attachCamera() async {
    String? msgId;
    try {
      // 1. Take photo first
      final pickedFile = await ImagePicker().pickImage(
        source: ImageSource.camera,
      );
      if (pickedFile == null) return;

      msgId = Helpers.generateId();
      final fileName = 'camera_$msgId.jpg';

      // 2. Cache camera image locally FIRST (before upload), downsampled —
      // camera JPEGs are the biggest single thing this app ever uploads.
      String uploadPath = pickedFile.path;
      try {
        final cachedPath = await LocalStorageService().saveAttachmentLocally(
          chatEntityId,
          fileName,
          File(pickedFile.path),
        );
        if (cachedPath.isNotEmpty) uploadPath = cachedPath;
      } catch (e) {
        print(
          '[DetailChat] Error caching camera image locally before upload: $e',
        );
      }

      // 3. Save to SQLite with pending URL
      final cameraMessage = MessageModel(
        id: msgId,
        taskId: chatEntityId,
        senderId: chatCurrentUserId,
        text: '',
        type: MessageType.image,
        fileUrl: 'pending',
        fileName: fileName,
        createdAt: DateTime.now(),
      );
      await LocalDatabaseService().saveMessage(
        cameraMessage,
        parentType: chatSqliteParentType,
      );
      setState(() {
        chatMessages.add(cameraMessage);
        chatRefreshMessages();
      });
      chatScrollToBottom();

      // 4. Upload to Firebase Storage with progress tracking
      final downloadUrl = await StorageService().uploadImageFromPath(
        chatEntityId,
        uploadPath,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => chatUploadProgress[msgId!] = p);
        },
      );

      if (!mounted) return;
      chatUploadProgress.remove(msgId);

      if (downloadUrl != null) {
        // 5. Update SQLite with real URL
        await LocalDatabaseService().updateMessageFileUrl(msgId, downloadUrl);

        final updatedMsg = MessageModel(
          id: cameraMessage.id,
          taskId: cameraMessage.taskId,
          senderId: cameraMessage.senderId,
          text: cameraMessage.text,
          type: cameraMessage.type,
          fileUrl: downloadUrl,
          fileName: cameraMessage.fileName,
          duration: cameraMessage.duration,
          createdAt: cameraMessage.createdAt,
        );
        setState(() {
          final idx = chatMessages.indexWhere((m) => m.id == msgId);
          if (idx != -1) chatMessages[idx] = updatedMsg;
          chatRefreshMessages();
        });

        // 6. Sync to Firestore
        try {
          await chatSyncMessage(updatedMsg);
        } catch (e) {
          print('[DetailChat] Error saving camera message: $e');
        }
      } else {
        // Upload failed — mark failed so the retry overlay shows
        markMessageUploadFailed(msgId, 'Upload returned no URL');
      }
    } catch (e) {
      print('[DetailChat] Error taking/uploading photo: $e');
      if (mounted) {
        final errorMsg = e.toString().replaceAll('Exception: ', '');
        markMessageUploadFailed(msgId!, errorMsg);
      }
    }
  }

  // Pick document/file — SQLite-first, then Firebase Storage upload
  Future<void> attachFile() async {
    String? msgId;
    try {
      // 1. Pick file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final fileName = file.name;
      final filePath = file.path;
      final fileSize = file.size;

      if (filePath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to access file'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // File size validation (100 MB max)
      const maxFileSize = 100 * 1024 * 1024;
      if (fileSize > maxFileSize) {
        final sizeMB = (fileSize / (1024 * 1024)).toStringAsFixed(1);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File too large ($sizeMB MB). Maximum is 100 MB.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final entityId = chatEntityId;
      if (entityId.isEmpty) {
        throw Exception('Entity ID is empty - cannot upload file');
      }

      msgId = Helpers.generateId();

      // 2. Cache file locally FIRST (before upload) so it can be opened even
      // if upload fails. Image picks (any decodable format) are downsampled to
      // 1600px/JPEG q80 and re-named to .jpg so the cached bytes match the
      // extension the OS opener trusts; every other document type is copied
      // verbatim. `uploadName` is what the message row and Storage path use, so
      // the retry service rebuilds the same cache path and object name.
      String uploadPath = filePath;
      String uploadName = fileName;
      const imageExts = {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'bmp',
        'gif',
        'tif',
        'tiff',
      };
      final isImagePick = imageExts.contains(
        fileName.split('.').last.toLowerCase(),
      );
      try {
        String? cachedPath;
        if (isImagePick) {
          final compressed = await LocalStorageService().compressAndCacheImage(
            entityId,
            fileName,
            File(filePath),
          );
          if (compressed != null) {
            uploadPath = compressed.key;
            uploadName = compressed.value;
          } else {
            // Undecodable (e.g. HEIC) or no size win — cache the original.
            cachedPath = await LocalStorageService().saveAttachmentLocally(
              entityId,
              fileName,
              File(filePath),
            );
          }
        } else {
          cachedPath = await LocalStorageService().saveAttachmentLocally(
            entityId,
            fileName,
            File(filePath),
          );
        }
        if (cachedPath != null && cachedPath.isNotEmpty)
          uploadPath = cachedPath;
      } catch (e) {
        print('[DetailChat] Error caching file locally before upload: $e');
      }

      // 3. Save to SQLite with pending URL
      final fileMessage = MessageModel(
        id: msgId,
        taskId: entityId,
        senderId: chatCurrentUserId,
        text: '',
        type: MessageType.file,
        fileUrl: 'pending',
        fileName: uploadName,
        createdAt: DateTime.now(),
      );
      await LocalDatabaseService().saveMessage(
        fileMessage,
        parentType: chatSqliteParentType,
      );
      setState(() {
        chatMessages.add(fileMessage);
        chatRefreshMessages();
      });
      chatScrollToBottom();

      // 4. Upload to Firebase Storage with progress tracking
      final storageRef = FirebaseStorage.instance.ref();
      final storagePath =
          '$chatStorageFolder/$entityId/files/${msgId}_$uploadName';
      final fileRef = storageRef.child(storagePath);

      final localFile = File(uploadPath);
      print('[DetailChat] Uploading file to: $storagePath');
      final uploadTask = fileRef.putFile(localFile);
      uploadTask.snapshotEvents.listen((snapshot) {
        if (!mounted || snapshot.totalBytes <= 0) return;
        setState(
          () => chatUploadProgress[msgId!] =
              snapshot.bytesTransferred / snapshot.totalBytes,
        );
      });
      final snapshot = await uploadTask.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw Exception(
          'Upload timed out. Check your connection and try again.',
        ),
      );

      if (snapshot.state == TaskState.error) {
        print('[DetailChat] Upload failed with state: ${snapshot.state}');
        throw Exception('Upload failed - check Firebase Storage configuration');
      }
      print('[DetailChat] Upload successful, getting download URL...');
      chatUploadProgress.remove(msgId);
      final downloadUrl = await snapshot.ref.getDownloadURL();
      print('[DetailChat] Download URL: $downloadUrl');

      if (!mounted) return;

      // 5. Update SQLite with real URL
      await LocalDatabaseService().updateMessageFileUrl(msgId, downloadUrl);

      final updatedMsg = MessageModel(
        id: fileMessage.id,
        taskId: fileMessage.taskId,
        senderId: fileMessage.senderId,
        text: fileMessage.text,
        type: fileMessage.type,
        fileUrl: downloadUrl,
        fileName: fileMessage.fileName,
        duration: fileMessage.duration,
        createdAt: fileMessage.createdAt,
      );
      setState(() {
        final idx = chatMessages.indexWhere((m) => m.id == msgId);
        if (idx != -1) chatMessages[idx] = updatedMsg;
        chatRefreshMessages();
      });

      // 6. Sync to Firestore
      try {
        await chatSyncMessage(updatedMsg);
      } catch (e) {
        print('[DetailChat] Error saving file message: $e');
      }
    } catch (e) {
      print('[DetailChat] Error picking/uploading file: $e');
      if (mounted) {
        final errorMsg = e.toString().replaceAll('Exception: ', '');
        markMessageUploadFailed(msgId!, errorMsg);
      }
    }
  }

  // ---- Location & contact sharing ----
  // Text-typed "attachments". They belong in this mixin because the attachment
  // sheet offers the same six tiles in Task, Sales and CRM — the only things
  // that differ are the parent id, the SQLite parentType and the sync target,
  // which is exactly what the chat* hooks already abstract.

  /// Share a location as a location-pin prefixed text message: the user types a
  /// place name or pastes a Google Maps link.
  Future<void> chatShareLocation() async {
    final locationController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.location_on, color: Colors.green, size: 24),
            SizedBox(width: 8),
            Text(
              'Share Location',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter a place name or paste a Google Maps link:',
              style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: locationController,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText:
                    'e.g. Central Park, New York or https://maps.google.com/...',
                hintStyle: const TextStyle(fontSize: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.green, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = locationController.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx, text);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Send', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    await chatSendSharedText('\ud83d\udccd Location: $result');
  }

  /// Share a phonebook contact as a bust-in-silhouette prefixed text message.
  Future<void> chatShareContact() async {
    try {
      final hasPermission = await FlutterContacts.requestPermission(
        readonly: true,
      );
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contacts permission denied'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final contact = await FlutterContacts.openExternalPick();
      if (contact == null) return;

      final phones = contact.phones
          .map((p) => p.number)
          .where((n) => n.isNotEmpty)
          .toList();
      final emails = contact.emails
          .map((e) => e.address)
          .where((e) => e.isNotEmpty)
          .toList();

      final buffer = StringBuffer('\ud83d\udc64 ${contact.displayName}');
      if (phones.isNotEmpty) {
        buffer.write('\n\ud83d\udcde ${phones.join(", ")}');
      }
      if (emails.isNotEmpty) {
        buffer.write('\n\u2709\ufe0f ${emails.join(", ")}');
      }

      await chatSendSharedText(buffer.toString());
    } catch (e) {
      print('[DetailChat] Error picking contact: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking contact: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Persist + optimistically show + sync a plain text message, following the
  /// same order the image / camera / voice paths above use: SQLite first (the
  /// local-first source of truth), then the on-screen list, then Firestore.
  Future<void> chatSendSharedText(String text) async {
    final message = MessageModel(
      id: Helpers.generateId(),
      taskId: chatEntityId,
      senderId: chatCurrentUserId,
      text: text,
      type: MessageType.text,
      createdAt: DateTime.now(),
      deliveryMethod: 'in-app',
    );
    await LocalDatabaseService().saveMessage(
      message,
      parentType: chatSqliteParentType,
    );
    if (!mounted) return;
    setState(() {
      chatMessages.add(message);
      chatRefreshMessages();
    });
    chatScrollToBottom();
    try {
      await chatSyncMessage(message);
    } catch (e) {
      print('[DetailChat] Error sending shared text message: $e');
    }
  }

  // ── Deferred attachment (compose in a dialog, ride inside the action card) ─
  // Open the source sheet, pick an image/file and return it WITHOUT uploading,
  // so an action composer can attach it to the card it is about to post. Then
  // [chatAttachToExistingMessage] runs the local-first pipeline (SQLite → UI →
  // Firebase Storage → Firestore) on the already-picked file.
  Future<PickedChatAttachment?> chatPickAttachment() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Photo / Gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('Document'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return null;
    if (source == 'file') {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      final f = result.files.first;
      if (f.path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to access file'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return null;
      }
      const maxFileSize = 100 * 1024 * 1024;
      if (f.size > maxFileSize) {
        final sizeMB = (f.size / (1024 * 1024)).toStringAsFixed(1);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File too large ($sizeMB MB). Maximum is 100 MB.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return null;
      }
      return PickedChatAttachment(
        path: f.path!,
        name: f.name,
        type: MessageType.file,
      );
    }
    final picked = await ImagePicker().pickImage(
      source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
    if (picked == null) return null;
    final name = source == 'camera'
        ? 'camera_${Helpers.generateId()}.jpg'
        : 'image_${Helpers.generateId()}.jpg';
    return PickedChatAttachment(
      path: picked.path,
      name: name,
      type: MessageType.image,
    );
  }

  /// The "Add attachment (optional)" row shown inside action compose dialogs
  /// (Sales generic composer and the Task action dialogs). Tapping it opens
  /// [chatPickAttachment] and reports the pick back through [onChanged] —
  /// the host dialog owns the state (wrap its builder in a StatefulBuilder).
  /// Extracted verbatim from the Sales composer so both modules stay in
  /// lock-step on look and behaviour.
  Widget buildChatAttachmentRow({
    required PickedChatAttachment? picked,
    required ValueChanged<PickedChatAttachment?> onChanged,
    required Color accentColor,
  }) {
    return InkWell(
      onTap: () async {
        final result = await chatPickAttachment();
        if (result != null) {
          onChanged(result);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              Icons.attach_file,
              size: 18,
              color: picked == null ? AppTheme.lightText : accentColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                picked == null
                    ? 'Add attachment (optional)'
                    : '${picked.type == MessageType.image ? '📷' : '📎'} ${picked.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: picked == null
                      ? AppTheme.lightText
                      : AppTheme.primaryText,
                ),
              ),
            ),
            if (picked != null)
              GestureDetector(
                onTap: () => onChanged(null),
                child: const Icon(
                  Icons.close,
                  size: 16,
                  color: AppTheme.lightText,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Upload an already-picked file onto an EXISTING message — the action-card
  /// flow posts the card first with fileUrl='pending' (ONE message carries
  /// both the action and its document), then this runs the same local-first
  /// pipeline attachImage/attachFile use and patches the download URL
  /// back onto that same message id (SQLite row, in-memory list, sync).
  Future<void> chatAttachToExistingMessage(
    MessageModel message,
    PickedChatAttachment a,
  ) async {
    final msgId = message.id;
    try {
      final entityId = chatEntityId;
      if (entityId.isEmpty) {
        throw Exception('Entity ID is empty - cannot upload file');
      }

      // Cache locally first so it opens even if the upload fails; images are
      // downsampled by saveAttachmentLocally (1600px / JPEG q80).
      String uploadPath = a.path;
      try {
        final cached = await LocalStorageService().saveAttachmentLocally(
          entityId,
          a.name,
          File(a.path),
        );
        if (cached.isNotEmpty) uploadPath = cached;
      } catch (e) {
        print('[DetailChat] Error caching action attachment: $e');
      }

      String? downloadUrl;
      if (a.type == MessageType.image) {
        downloadUrl = await StorageService().uploadImageFromPath(
          entityId,
          uploadPath,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => chatUploadProgress[msgId] = p);
          },
        );
      } else {
        final fileRef = FirebaseStorage.instance.ref().child(
          '$chatStorageFolder/$entityId/files/${msgId}_${a.name}',
        );
        final uploadTask = fileRef.putFile(File(uploadPath));
        uploadTask.snapshotEvents.listen((s) {
          if (!mounted || s.totalBytes <= 0) return;
          setState(
            () => chatUploadProgress[msgId] = s.bytesTransferred / s.totalBytes,
          );
        });
        final snapshot = await uploadTask.timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw Exception(
            'Upload timed out. Check your connection and try again.',
          ),
        );
        if (snapshot.state == TaskState.error) {
          throw Exception(
            'Upload failed - check Firebase Storage configuration',
          );
        }
        downloadUrl = await snapshot.ref.getDownloadURL();
      }

      if (!mounted) return;
      chatUploadProgress.remove(msgId);
      if (downloadUrl == null) {
        markMessageUploadFailed(msgId, 'Upload returned no URL');
        return;
      }
      await LocalDatabaseService().updateMessageFileUrl(msgId, downloadUrl);
      final updated = message.copyWith(fileUrl: downloadUrl);
      setState(() {
        final idx = chatMessages.indexWhere((m) => m.id == msgId);
        if (idx != -1) chatMessages[idx] = updated;
        chatRefreshMessages();
      });
      try {
        await chatSyncMessage(updated);
      } catch (e) {
        print('[DetailChat] Error syncing action attachment: $e');
      }
    } catch (e) {
      print('[DetailChat] Error attaching to action message: $e');
      if (mounted) {
        markMessageUploadFailed(
          msgId,
          e.toString().replaceAll('Exception: ', ''),
        );
      }
    }
  }
}

/// A file chosen in a composer dialog that has NOT been uploaded or sent yet.
class PickedChatAttachment {
  final String path;
  final String name;
  final MessageType type; // image | file
  const PickedChatAttachment({
    required this.path,
    required this.name,
    required this.type,
  });
}
