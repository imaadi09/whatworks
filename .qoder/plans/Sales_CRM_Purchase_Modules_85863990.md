# WhatWorks Module System

## App Architecture

WhatWorks is a multi-module app. Each module is **fully independent** — own data (Firestore collection), own code (directory), own screens, own provider, own service. No shared business logic between modules. They only share the auth layer and visual theme.

```
lib/
  main.dart                          (shared: auth, providers, theme)
  providers/auth_provider.dart       (shared)
  services/firebase_service.dart     (shared auth only)
  utils/constants.dart               (shared theme)
  
  # Main Module - Task Management (existing)
  models/task.dart
  providers/task_provider.dart
  screens/home/
  screens/task_detail/
  screens/new_task/
  
  # Sales Module (new - build now)
  modules/sales/
    models/enquiry.dart
    services/sales_service.dart
    providers/sales_provider.dart
    screens/sales_home_screen.dart
    screens/sales_detail_screen.dart
    widgets/sales_card.dart
  
  # CRM Module (provision - skeleton only)
  modules/crm/
    (placeholder)
  
  # Vendor Module (provision - skeleton only)
  modules/vendor/
    (placeholder)
```

Each `modules/{name}/` directory is a self-contained mini-app. No cross-imports between modules.

---

## Phase 1: Sales Module (Build Now)

### 1. EnquiryModel

**File:** `lib/modules/sales/models/enquiry.dart`

Independent model for sales enquiries:
- `id`, `clientName` (replaces title), `description`
- `createdBy`, `createdByName`, `createdByPhone`
- `assignedTo`, `assignedToUid`, `assignedToPhone`
- `status`: enum `SalesStatus { active, success, lost, dropped, cancel }`
- `milestones`: `List<SalesMilestone>` (preset sales stages)
- `priority`, `deadline`, `progress`, `tags`
- `createdAt`, `updatedAt`, `isClosed`
- `lastMessageText`, `lastMessageTime`
- `extraFields` for future extensibility
- Factory `fromMap` / `toMap` for Firestore

**SalesMilestone** (embedded in EnquiryModel):
- `id`, `title`, `order`, `isCompleted`, `completedAt`

**Default milestones** (stored in `lib/modules/sales/utils/sales_constants.dart`):
1. Initial Contact
2. Needs Assessment
3. Demo/Presentation
4. Proposal Sent
5. Negotiation
6. Closing

---

### 2. Sales Firestore Service

**File:** `lib/modules/sales/services/sales_service.dart`

All operations scoped to `sales_enquiries` collection only:
- `createEnquiry(EnquiryModel)` -> `sales_enquiries`
- `updateEnquiry(id, data)`
- `deleteEnquiry(id)`
- `getEnquiries(userId)` - where createdBy or assignedTo matches
- `getMessages(enquiryId)` -> `sales_enquiries/{id}/messages`
- `sendMessage(enquiryId, message)`
- `getSystemMessages(enquiryId)` -> `sales_enquiries/{id}/system_messages`

No references to main `tasks` collection.

---

### 3. SalesProvider

**File:** `lib/modules/sales/providers/sales_provider.dart`

- `SalesProvider extends ChangeNotifier`
- Own state: `_enquiries`, `_cachedMessages`, `_statusFilter`, `_sortBy`
- `loadEnquiries(userId)` - fetches from `sales_enquiries`
- `getCachedMessages(enquiryId)` - returns cached messages
- `prefetchMessages(enquiryIds)` - batch loads messages
- Filter: All / Active / Success / Lost / Dropped / Cancel
- Sort: Last Action / Due Date / Priority / Created / Name / Client

---

### 4. Sales Home Screen

**File:** `lib/modules/sales/screens/sales_home_screen.dart`

**AppBar:** Title "Sales Team", green header with white tab bar below.

**Two tabs (no ToMe):**
- **SALES tab** - Enquiry cards showing `clientName`, milestone progress, status badge. 3-dot menu for filter/sort. Floating + button for new enquiry.
- **ACTIONS tab** - Dropdown filter: All Actions, Reminders, Follow Up, Follow Up - Pending, Query, Pending Query, Replied Query, Warning.

**3-dot filter statuses:** All Enquiries, Active, Success, Lost, Dropped, Cancel, Overdue, High Priority.

**Sales card** shows:
- Client name (primary text, replaces task title)
- Status badge (color-coded: Active=blue, Success=green, Lost=red, Dropped=grey, Cancel=dark grey)
- Milestone progress bar
- Label reads "Enquiry" (not "Task")

---

### 5. Sales Detail Screen

**File:** `lib/modules/sales/screens/sales_detail_screen.dart`

Independent screen with:
- Client name header
- Sales milestone checklist (preset stages, checkable, ordered)
- Chat area (WhatsApp-style messages, same rendering pattern)
- Status change chips: Active, Success, Lost, Dropped, Cancel
- Actions: Reminder, Follow Up, Query, Warning
- No references to TaskDetailScreen code

---

### 6. Sales Card Widget

**File:** `lib/modules/sales/widgets/sales_card.dart`

Independent card widget styled like TaskCard:
- Client name as primary text
- Sales status badge (color-coded)
- Milestone progress bar (e.g., "3/6 stages")
- Deadline indicator, unread count
- Tap navigates to SalesDetailScreen

---

## Phase 2: DEMO Button Entry Point

**File:** `lib/screens/home/home_screen.dart` (modification only)

Make the static DEMO `Container` (line ~437) clickable:

```dart
GestureDetector(
  onTap: () => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SalesHomeScreen()),
  ),
  child: Container(...), // existing DEMO styling
),
```

---

## Phase 3: Provider Registration

**File:** `lib/main.dart` (modification only)

Add `SalesProvider` to `MultiProvider`:
```dart
ChangeNotifierProvider(create: (_) => SalesProvider()),
```

---

## Provision: CRM Module (Skeleton)

**Directory:** `lib/modules/crm/`

Empty skeleton files with TODOs:
- `models/lead.dart` - LeadModel placeholder
- `services/crm_service.dart` - `crm_leads` collection placeholder
- `providers/crm_provider.dart` - CRMProvider placeholder
- `screens/crm_home_screen.dart` - Placeholder screen with "Coming Soon"

Same independence pattern as Sales: own collection, own provider, own screens.

---

## Provision: Vendor Module (Skeleton)

**Directory:** `lib/modules/vendor/`

Empty skeleton files with TODOs:
- `models/vendor_order.dart` - VendorOrderModel placeholder
- `services/vendor_service.dart` - `vendor_orders` collection placeholder
- `providers/vendor_provider.dart` - VendorProvider placeholder
- `screens/vendor_home_screen.dart` - Placeholder screen with "Coming Soon"

---

## File Summary

**New files - Sales Module (8):**
- `lib/modules/sales/models/enquiry.dart`
- `lib/modules/sales/services/sales_service.dart`
- `lib/modules/sales/providers/sales_provider.dart`
- `lib/modules/sales/screens/sales_home_screen.dart`
- `lib/modules/sales/screens/sales_detail_screen.dart`
- `lib/modules/sales/widgets/sales_card.dart`
- `lib/modules/sales/utils/sales_constants.dart`

**New files - CRM Skeleton (4):**
- `lib/modules/crm/models/lead.dart`
- `lib/modules/crm/services/crm_service.dart`
- `lib/modules/crm/providers/crm_provider.dart`
- `lib/modules/crm/screens/crm_home_screen.dart`

**New files - Vendor Skeleton (4):**
- `lib/modules/vendor/models/vendor_order.dart`
- `lib/modules/vendor/services/vendor_service.dart`
- `lib/modules/vendor/providers/vendor_provider.dart`
- `lib/modules/vendor/screens/vendor_home_screen.dart`

**Modified files (2):**
- `lib/screens/home/home_screen.dart` - DEMO button becomes clickable
- `lib/main.dart` - Register SalesProvider
