# Message Upload and Send Error Handling

## Current Issues
- Uploads (`ref.putFile`) have no timeout -- can hang forever
- Failed uploads leave messages stuck as `fileUrl: 'pending'` with no retry option
- Error SnackBar is inconsistent: voice/file show it, image does not
- Text/system messages use fire-and-forget `_saveMessageToFirebase` -- failures only printed, never shown to user
- No `failed` state -- only `pending` exists
- No auto-cleanup of stale pending messages

## Step 1: Add upload timeout to StorageService

**File:** `lib/services/storage_service.dart`

In `_uploadFile` (line ~117), wrap the upload with a timeout:
```dart
final snapshot = await uploadTask.timeout(
  const Duration(seconds: 60),
  onTimeout: () => throw Exception('Upload timed out. Check your connection and try again.'),
);
```

Also improve the error state check to throw a more descriptive error:
```dart
if (snapshot.state == TaskState.error) {
  throw Exception('Upload failed. Please try again.');
}
```

## Step 2: Add `failed` state support to MessageModel

**File:** `lib/models/message.dart`

Add a `uploadError` field to track failure reason:
- `final String? uploadError;` -- null when OK, contains error message when failed
- Update `fromMap`, `toMap`, `copyWith` accordingly
- Add convenience: `bool get isUploadFailed => fileUrl == 'failed' || uploadError != null`

Convention:
- `fileUrl == 'pending'` -- upload in progress
- `fileUrl == 'failed'` -- upload failed (with `uploadError` describing why)
- `fileUrl` is a real URL -- upload succeeded

## Step 3: Add retry and error handling to attachment uploads in TaskDetailScreen

**File:** `lib/screens/task_detail/task_detail_screen.dart`

For `_attachImage` (line ~2050), `_attachFile` (line ~2170), `_sendVoiceMessage` (line ~4844):

**Pattern change** (same for all three):
1. Wrap upload in try/catch
2. On failure: update SQLite message to `fileUrl: 'failed'` with `uploadError` set
3. Update local `_messages` list to reflect failed state
4. Show consistent error SnackBar with "Retry" action
5. Retry action re-triggers upload with the same message

Add a shared `_retryAttachmentUpload(MessageModel message)` method that:
- Reads the local file path from `message.localFilePath` (already stored)
- Sets `fileUrl` back to `'pending'`, clears `uploadError`
- Calls the appropriate `StorageService.upload*` method with timeout
- On success: updates SQLite + Firestore, updates `_messages`
- On failure: sets back to `'failed'`, shows SnackBar again

Add a `_showUploadErrorSnackBar(MessageModel message)` helper that:
- Parses `uploadError` for known patterns (quota, timeout, network)
- Shows quota-specific message: "Storage limit reached. Upgrade your plan."
- Shows timeout message: "Upload timed out. Check connection."
- Shows generic: "Upload failed. Tap to retry."
- Always includes a "Retry" action that calls `_retryAttachmentUpload`

## Step 4: Update bubble rendering for failed state

**File:** `lib/screens/task_detail/task_detail_screen.dart`

**Image bubble** (`_buildImageBubble`):
- When `fileUrl == 'failed'`: show the local image (from `localFilePath`) with a red error overlay/icon and "Tap to retry" text
- When `fileUrl == 'pending'`: keep existing loading indicator

**File bubble** (`_buildFileBubble`):
- When `fileUrl == 'failed'`: show file icon with red tint, error text, and "Tap to retry"
- Make the entire bubble tappable for retry when failed

**Voice bubble** (`_buildVoiceBubble`):
- When `fileUrl == 'failed'`: show waveform area with red error icon and "Tap to retry"

Add `onTap` handler on each failed bubble to call `_retryAttachmentUpload(message)`.

## Step 5: Fix text/system message send failures

**File:** `lib/screens/task_detail/task_detail_screen.dart`

Change `_saveMessageToFirebase` (line ~2122) from fire-and-forget to properly handle errors:

```dart
void _saveMessageToFirebase(MessageModel message) {
  // ... existing scroll logic ...
  try {
    final taskProvider = context.read<TaskProvider>();
    taskProvider.sendMessage(_currentTask.id, message).catchError((e) {
      print('[TaskDetail] Error saving message: $e');
      // Show error SnackBar for failed message sends
      if (mounted) {
        _showMessageSendErrorSnackBar(message, e);
      }
    });
  } catch (e) {
    print('[TaskDetail] Error saving message: $e');
  }
}
```

Add `_showMessageSendErrorSnackBar(MessageModel message, dynamic error)`:
- For text messages: show "Message failed to send" with "Retry" action
- For system messages: show "Status update failed" with "Retry" action
- Retry calls `_saveMessageToFirebase(message)` again

Also update `TaskProvider.sendMessage` (line ~565) to propagate the Firestore error instead of swallowing it:
```dart
_firebaseService.sendMessage(taskId, message, messageId: msgId).then((_) {}).catchError((e) {
  print('Error sending message in Firestore: $e');
  // Mark message as failed in local DB so UI can show it
  LocalDatabaseService().updateMessageFileUrl(msgId, 'failed');
});
```

## Step 6: Apply same fixes to SalesDetailScreen

**File:** `lib/modules/sales/screens/sales_detail_screen.dart`

Mirror the changes from Steps 3-5:
- `_attachImage`, `_attachFile`, `_sendVoiceMessage`: add failed state handling, retry, consistent SnackBar
- `_saveMessageToFirebase`: add error callback with SnackBar
- Bubble rendering: add failed state overlay for image/file/voice bubbles
- Add shared `_retryAttachmentUpload` and `_showUploadErrorSnackBar` helpers

## Step 7: Auto-cleanup of stale pending messages

**File:** `lib/services/local_database_service.dart`

Add `cleanupStalePendingMessages({int maxAgeMinutes = 30})`:
- Finds all messages where `fileUrl = 'pending'` AND `createdAt < (now - maxAgeMinutes)`
- Updates them to `fileUrl = 'failed'` with `uploadError = 'Upload timed out'`
- Returns the list of cleaned-up message IDs (so caller can show notification)

**File:** `lib/providers/task_provider.dart`

Call `cleanupStalePendingMessages()` on initialization (same place `_purgeOldDeletedTasks` is called). If any stale messages are found, notify the UI so a SnackBar can inform the user.

## Step 8: Build and verify

Build arm64-v8a APK and verify no compile errors.
