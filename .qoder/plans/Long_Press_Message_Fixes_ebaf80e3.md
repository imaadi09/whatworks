# Attachment & Long Press Message Fixes

## Summary

Fix 3 attachment issues (image upload/preview, audio playback, document Firebase error) and complete remaining long-press message plan items (ForwardTargetScreen tabs + build).

---

## 5. Fix Image Upload & Preview

**Root cause:** After uploading image to Firebase Storage, the original picked file is NOT cached to the local attachment directory. So `_getLocalImagePath()` always returns null and the bubble falls back to `CachedNetworkImage`. If the network image fails to load (Firebase URL inaccessible, slow network), no preview is shown.

**File:** `lib/screens/task_detail/task_detail_screen.dart`

In `_attachImage()` (line ~11293) and `_attachCamera()` (line ~11392), after successful upload:
1. Copy the picked file to the local attachment directory using `LocalStorageService`:
```dart
// Cache locally so _getLocalImagePath can find it
final localStorage = LocalStorageService();
final dir = await localStorage.getAttachmentDirectory();
final cachedFile = File('${dir.path}/${_currentTask.id}_$fileName');
await File(pickedFile.path).copy(cachedFile.path);
```
2. This goes right after `updateMessageFileUrl` and before the Firestore sync.

Same fix for `_attachCamera()`.

---

## 6. Fix Audio Playback

**Root cause:** Voice bubble playback downloads from Firebase Storage to `{attachmentDir}/voice_{id}.m4a`. Two issues:
1. The attachment directory might not exist yet (never created for this task).
2. If download/play fails, error is swallowed silently — user taps play and nothing happens.

**File:** `lib/screens/task_detail/task_detail_screen.dart`

In `_toggleVoiceBubblePlayback()` (line ~3541):
1. Ensure directory exists before writing:
```dart
if (!await dir.exists()) await dir.create(recursive: true);
```
2. Add user-visible error feedback when playback fails (SnackBar).
3. Also cache the voice file locally after upload in `_sendVoiceMessage()` (line ~4716), same pattern as images.

---

## 7. Fix Document "Firebase Object Missing" Error

**Root cause:** When user taps a document bubble, `_openDocumentViewer` tries to download from `message.fileUrl`. If `fileUrl` is still `'pending'` (upload hasn't completed), `refFromURL('pending')` throws. Also, if the Firestore sync failed, the message might be stuck with `'pending'` URL permanently.

**File:** `lib/screens/task_detail/task_detail_screen.dart`

In `_openDocumentViewer()` (line ~13382):
1. Add explicit `'pending'` check before trying to download:
```dart
if (message.fileUrl == 'pending') {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('File is still uploading...'), ...),
  );
  return;
}
```
2. In `_attachFile()` (line ~11528), add better error handling if upload fails — update message to show error state instead of permanent "pending".
3. Also cache the file locally after upload (same pattern as images) so `_getLocalImagePath` can find it.

---

## 8. Remaining: ForwardTargetScreen ByMe/ToMe tabs

(Deferred from previous plan — task lp8)

---

## 9. Build and Verify

Build arm64-v8a APK and verify all fixes.

---

## Files Changed

| File | Changes |
|------|--------|
| `lib/screens/task_detail/task_detail_screen.dart` | Cache images/voice/files locally after upload; fix audio playback dir creation; fix document pending check |
| `lib/screens/forward/forward_target_screen.dart` | Add ByMe/ToMe tabs (deferred) |