# Message Forward Feature

## Current State
- **Task Detail** already has a `_forwardMessage()` and `_showForwardTaskSelector()` but it only shows tasks (no sales enquiries)
- **Sales Detail** has NO forward option in its message context menu at all
- File forwarding copies the `fileUrl` reference (same Firebase Storage URL) — works since URLs are publicly accessible

## Step 1: Create shared `ForwardTargetScreen`

Create `lib/screens/forward/forward_target_screen.dart` — a reusable screen that shows both tasks and sales enquiries with section headers, search, and multi-select checkboxes.

**Input:** `MessageModel message` (the message to forward), `String sourceParentId` (to exclude current conversation from targets)

**UI structure:**
- App bar with title "Forward to..." and a search field
- Two sections with headers: "Tasks" and "Sales Enquiries"
- Each item: checkbox + icon + title + subtitle (description/client name)
- Bottom bar with "Forward (N)" button
- Data loaded from `TaskProvider` (byMeTasks + toMeTasks) and `SalesProvider` (enquiries)

**Output:** Returns `List<ForwardTarget>` where each target has `{id, type: 'task'|'enquiry', title}`

## Step 2: Update Task Detail forward flow

In `task_detail_screen.dart`:
- Replace `_showForwardTaskSelector()` call with navigation to `ForwardTargetScreen`
- Update `_forwardMessage()` to handle both task and enquiry targets
- For task targets: use `taskProvider.sendMessage()`
- For enquiry targets: use `salesProvider.sendMessage()`
- Delete the old `_showForwardTaskSelector()` method

## Step 3: Add forward to Sales Detail

In `sales_detail_screen.dart`:
- Add "Forward" option in `_showMessageOptions()` bottom sheet (after the message preview, before Edit)
- Add `_forwardMessage(MessageModel message)` method — same logic as task detail version
- Navigate to `ForwardTargetScreen`, then forward to selected targets

## Step 4: Forward logic for all message types

For all message types (text, image, file, voice):
- **Text:** Copy text as-is
- **Image/File/Voice:** Create message with same `fileUrl`, `fileName`, `type` — the Firebase Storage URL is shared. The forwarded message follows SQLite-first write: save to local SQLite, then sync to Firestore
- Prefix for non-text: "📎 {fileName}" as text preview

## Files to create/modify
- **CREATE:** `lib/screens/forward/forward_target_screen.dart`
- **MODIFY:** `lib/screens/task_detail/task_detail_screen.dart` — replace forward selector, update `_forwardMessage()`
- **MODIFY:** `lib/modules/sales/screens/sales_detail_screen.dart` — add forward option + method
