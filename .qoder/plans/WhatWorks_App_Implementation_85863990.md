# WhatWorks App Implementation Plan

## Phase 1: Project Setup & Firebase Integration

### 1.1 Configure Firebase
- Add Firebase dependencies to `pubspec.yaml`:
  - `firebase_core`, `firebase_auth`, `cloud_firestore`, `firebase_storage`
  - `flutter_local_notifications` for push notifications
- Create Firebase project and add `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
- Initialize Firebase in `main.dart`

### 1.2 Update Dependencies
```yaml
dependencies:
  flutter:
    sdk: flutter
  firebase_core: ^2.24.0
  firebase_auth: ^4.15.0
  cloud_firestore: ^4.13.0
  firebase_storage: ^11.5.0
  provider: ^6.1.1
  intl: ^0.19.0
  image_picker: ^1.0.7
  file_picker: ^6.1.1
  google_sign_in: ^6.2.1
  cached_network_image: ^3.3.1
  flutter_slidable: ^3.0.1
  timeline_tile: ^2.0.0
  googleapis: ^13.0.0  # For Google Drive integration
  record: ^5.0.4  # Voice notes
  audioplayers: ^5.2.1  # Play voice notes
```

### 1.3 Project Structure
```
lib/
├── main.dart
├── config/
│   ├── firebase_options.dart
│   └── routes.dart
├── models/
│   ├── user.dart
│   ├── task.dart
│   ├── message.dart
│   ├── milestone.dart
│   └── system_log.dart
├── providers/
│   ├── auth_provider.dart
│   ├── task_provider.dart
│   └── chat_provider.dart
├── screens/
│   ├── auth/
│   │   └── login_screen.dart
│   ├── home/
│   │   └── home_screen.dart
│   ├── task/
│   │   └── task_detail_screen.dart
│   └── new_task/
│       └── new_task_screen.dart
├── widgets/
│   ├── task_card.dart
│   ├── chat_bubble.dart
│   ├── milestone_row.dart
│   ├── quick_action_chips.dart
│   ├── filter_chips.dart
│   └── template_selector.dart
├── services/
│   ├── firebase_service.dart
│   ├── storage_service.dart
│   └── notification_service.dart
└── utils/
    ├── constants.dart
    ├── helpers.dart
    └── validators.dart
```

---

## Phase 2: Data Models

### 2.1 Create User Model
**File**: `lib/models/user.dart`
```dart
class UserModel {
  String uid;
  String name;
  String email;
  String? phone;
  String? avatarUrl;
  String? company;
  DateTime createdAt;
}
```

### 2.2 Create Task Model
**File**: `lib/models/task.dart`
```dart
class TaskModel {
  String id;
  String title;
  String description;
  String createdBy;
  String assignedTo;
  int priority; // 1=Low, 2=Mid, 3=High
  bool isUrgent;
  DateTime? deadline;
  double progress; // 0.0 to 1.0
  List<String> tags; // Industry-specific
  Map<String, dynamic>? extraFields; // Deal Value, Case Number, etc.
  DateTime createdAt;
  DateTime updatedAt;
  bool isClosed;
  int? rating;
  String? template;
}
```

### 2.3 Create Message Model
**File**: `lib/models/message.dart`
```dart
class MessageModel {
  String id;
  String taskId;
  String senderId;
  String text;
  MessageType type; // text, image, file, voice, system
  String? fileUrl;
  String? fileName;
  int? duration; // For voice notes
  DateTime createdAt;
}
```

### 2.4 Create Milestone Model
**File**: `lib/models/milestone.dart`
```dart
class MilestoneModel {
  String id;
  String taskId;
  String title;
  DateTime? dueDate;
  bool isCompleted;
  DateTime? completedAt;
  double progress; // 0.0 to 1.0
}
```

### 2.5 Create System Log Model
**File**: `lib/models/system_log.dart`
```dart
class SystemLogModel {
  String id;
  String taskId;
  String action; // "priority_changed", "person_added", "warning_issued", etc.
  String performedBy;
  String details;
  DateTime createdAt;
}
```

---

## Phase 3: Authentication & User Management

### 3.1 Login Screen
**File**: `lib/screens/auth/login_screen.dart`
- Google Sign-In integration
- Phone number authentication fallback
- Simple, clean UI with WhatWorks branding
- Auto-create user profile on first login

### 3.2 Auth Provider
**File**: `lib/providers/auth_provider.dart`
- Manage authentication state
- User profile CRUD operations
- Team member management (add/remove contacts)

### 3.3 Profile/Settings Screen
- User avatar upload
- Edit name, phone, company
- Notification preferences
- Storage usage display
- Logout button

---

## Phase 4: Home Screen (Screen 1)

### 4.1 Home Screen Layout
**File**: `lib/screens/home/home_screen.dart`

**Components**:
- **TopAppBar**: App logo + user avatar (tap → Settings)
- **TabBar**: "By Me" | "To Me" with green active underline
- **SearchBar**: Live filtering as user types
- **Filter Chips**: Horizontal scrollable
  - All
  - ⏰ Deadlines Nearing
  - 🔥 Overdue
  - ⭐ High Priority
  - Urgent Only
  - Longest Pending
- **Sort Dropdown**: Deadline, Priority, Latest Activity, Oldest
- **Task List**: Pull-to-refresh enabled
- **FloatingActionButton**: Green + button → New Task Screen

### 4.2 Task Card Widget
**File**: `lib/widgets/task_card.dart`

**Layout**:
```
┌─────────────────────────────────────┐
│ [Avatar] Person Name    ★★★ 🔥     │
│          Task Title                 │
│          Short description preview  │
│          [>>>> 65%]                 │
│          Last message preview...    │
│                        📅 15/10/1d │
└─────────────────────────────────────┘
```

**Features**:
- Tap → Open Task Detail Screen
- Long press → Quick actions (Remind, Mark Urgent, Archive)
- Color-coded deadline badge (green/yellow/red)
- Priority stars display
- Progress bar visualization
- Days since last activity indicator

### 4.3 Task Provider
**File**: `lib/providers/task_provider.dart`
- Firestore streams for real-time updates
- Filter logic (By Me / To Me)
- Search and sort implementations
- Filter chip logic
- Pull-to-refresh handler
- Archive/delete operations

---

## Phase 5: Task Detail / Chat Screen (Screen 2 - Core)

### 5.1 Task Detail Screen Layout
**File**: `lib/screens/task/task_detail_screen.dart`

**Top Section**:
- Task title + assigned person name
- Priority stars + urgency badge
- Progress bar
- Deadline display

**Main Area** (WhatsApp-style chat):
- Reverse chronological message list
- Date separators
- Green bubbles (user messages)
- White/grey bubbles (other person)
- Grey italic system logs
- File/image/voice previews
- Milestone rows inline

**Bottom Input Bar**:
- Text input field
- Attach button (camera/gallery/Google Drive)
- Voice note button
- Send button

### 5.2 Chat Bubble Widget
**File**: `lib/widgets/chat_bubble.dart`
- Message type handling (text/image/file/voice/system)
- Timestamp display
- Read receipts (optional)
- Tap to expand files/images

### 5.3 Quick Action Chips
**File**: `lib/widgets/quick_action_chips.dart`
- Horizontal scrollable row
- Actions:
  - Ask for Update
  - Need by Today?
  - Improve it Further
  - Reminder
  - Warning
  - Add Milestone
  - Add/Remove Person
  - Change Priority
  - Set Urgency
  - Rate Work (stars)
  - Rate & Close

**Behavior**:
- Tap action → Show dialog/modal if needed
- Auto-log as system message in thread
- Trigger notifications to assignee

### 5.4 Milestone Row Widget
**File**: `lib/widgets/milestone_row.dart`
- Display: "PO Received – Due 12 Jun – 75%"
- Check button to mark complete
- Edit due date option
- Progress indicator

### 5.5 Chat Provider
**File**: `lib/providers/chat_provider.dart`
- Firestore stream for task messages
- Send message (text/file/voice)
- Upload to Firebase Storage
- System log generation
- Milestone CRUD operations
- Quick action handlers

---

## Phase 6: New Task Screen (Screen 3)

### 6.1 New Task Screen Layout
**File**: `lib/screens/new_task/new_task_screen.dart`

**Form Fields** (top to bottom):
1. **Task Title**: Large input, auto-focused
2. **Assign To**: 
   - Searchable people list
   - "+ Add new contact" button
3. **Priority Toggle**: High ★★★ / Mid ★★
4. **Urgency Chips**: Normal / Today / This Week / ASAP
5. **Deadline**: 
   - Date picker
   - Quick chips: 1 day, 3 days, 1 week, 15 days
6. **Description/Details**: Multi-line text input
7. **Templates Row**: Horizontal scrollable
   - Sales Report
   - Cust Delivery
   - Pick Cash
   - Make Presentation
   - Steel Stock
   - New Enquiry
   - Case Filing
   - (Custom templates from Firestore)
8. **Attach Files**: Camera/Gallery/Google Drive
9. **Add Milestones**: Button → Milestone editor
10. **Toggle**: "Also send via WhatsApp if they don't have Noted" (disabled for now, show "Coming Soon")
11. **Assign Now Button**: Large green button at bottom

### 6.2 Template Selector Widget
**File**: `lib/widgets/template_selector.dart`
- Industry-specific template cards
- Tap to pre-fill form fields
- Store templates in Firestore for easy updates
- Allow custom template creation (future)

### 6.3 Task Creation Logic
- Validate required fields
- Create task in Firestore
- Create initial system log: "Task created by [User]"
- Add initial milestones if provided
- Notify assignee (Firebase Cloud Messaging)
- Navigate back to Home Screen with success snackbar

---

## Phase 7: Firebase Integration & Services

### 7.1 Firebase Service
**File**: `lib/services/firebase_service.dart`
- Firestore collection references
- CRUD operations for tasks, messages, users
- Stream builders for real-time data
- Error handling

### 7.2 Storage Service
**File**: `lib/services/storage_service.dart`
- File upload to Firebase Storage
- Image compression before upload
- Voice note storage
- Google Drive integration (optional, later phase)
- Thumbnail generation for previews

### 7.3 Notification Service
**File**: `lib/services/notification_service.dart`
- Firebase Cloud Messaging setup
- Push notification on task assignment
- Push on mention/reminder/warning
- Notification tap → Navigate to task
- Local notifications for deadlines

### 7.4 Firestore Schema
```
users/
  {uid}/
    - name, email, phone, avatarUrl, company, createdAt

tasks/
  {taskId}/
    - title, description, createdBy, assignedTo
    - priority, isUrgent, deadline, progress
    - tags, extraFields, createdAt, updatedAt
    - isClosed, rating, template

tasks/{taskId}/messages/
  {messageId}/
    - senderId, text, type, fileUrl, fileName
    - duration, createdAt

tasks/{taskId}/milestones/
  {milestoneId}/
    - title, dueDate, isCompleted, completedAt, progress

tasks/{taskId}/system_logs/
  {logId}/
    - action, performedBy, details, createdAt
```

---

## Phase 8: UI/UX Polish & Theming

### 8.1 Theme Configuration
**File**: `lib/utils/constants.dart`
```dart
class AppTheme {
  static const primaryGreen = Color(0xFF25D366); // WhatsApp-like green
  static const darkGreen = Color(0xFF128C7E);
  static const lightGrey = Color(0xFFF0F2F5);
  static const chatBubbleGreen = Color(0xFFDCF8C6);
  static const chatBubbleWhite = Colors.white;
  // ... more colors
}
```

### 8.2 Responsive Design
- Optimize for various screen sizes
- Tablet support with sidebar for task list
- Safe area handling
- Keyboard avoidance in chat input

### 8.3 Animations & Transitions
- Smooth tab switching
- Card tap animation
- Message send animation
- Pull-to-refresh indicator
- Loading spinners

### 8.4 Empty States
- No tasks yet → Illustration + "Create your first task" button
- No messages → "Start the conversation" placeholder
- No search results → "No matching tasks" message

---

## Phase 9: Offline Support & Caching

### 9.1 Local Database Setup
- Add `hive` or `sqflite` for offline caching
- Cache recent tasks and messages
- Queue actions when offline
- Sync when connection restored

### 9.2 Image & File Caching
- `cached_network_image` for avatar and file thumbnails
- Don't auto-download full files (low data usage)
- Tap to download full file on demand

### 9.3 Storage Management
- 500 MB free shared storage tracking
- Auto-delete old closed tasks (configurable)
- Show storage usage in Settings
- Warning when approaching limit

---

## Phase 10: Testing & Quality Assurance

### 10.1 Unit Tests
- Model serialization/deserialization
- Provider logic (filtering, sorting)
- Helper functions and validators

### 10.2 Widget Tests
- Task card rendering
- Chat bubble display
- Form validation in New Task screen
- Filter chip behavior

### 10.3 Integration Tests
- Full task creation flow
- Chat message sending
- File upload workflow
- Navigation between screens

### 10.4 Performance Optimization
- Lazy loading for message lists
- Pagination for old messages
- Image compression
- Minimize Firestore reads with proper indexing

---

## Phase 11: Deployment Preparation

### 11.1 App Configuration
- App icon and splash screen
- App name: "WhatWorks"
- Version management
- Environment configs (dev/prod)

### 11.2 Android Setup
- Update `AndroidManifest.xml` with required permissions
  - Camera, Storage, Microphone, Internet
- ProGuard/R8 rules for Firebase
- Release build configuration
- Generate signing key

### 11.3 iOS Setup
- Update `Info.plist` with permissions
  - Camera, Photo Library, Microphone
- App Store Connect setup
- iOS icons and launch screen
- Release build configuration

### 11.4 Firebase Setup
- Enable Firestore, Authentication, Storage, FCM
- Set up security rules
- Configure Cloud Functions (if needed for notifications)
- Set up Firestore indexes

---

## Phase 12: Future Enhancements (Post-MVP)

### 12.1 SMS/WhatsApp Bridge
- Twilio API integration
- WhatsApp Business API
- SMS reply parsing and thread matching
- Formatted message templates

### 12.2 Advanced Features
- Team analytics dashboard
- Performance reports
- Custom templates per industry
- Bulk task operations
- Task dependencies
- Recurring tasks

### 12.3 Integrations
- Google Calendar sync
- Slack notifications
- Email notifications
- Export to Excel/PDF

---

## Implementation Order & Timeline

**Week 1-2**: Phase 1-3 (Setup, Models, Auth)
**Week 3-4**: Phase 4 (Home Screen)
**Week 5-6**: Phase 5 (Task Detail/Chat - Core Feature)
**Week 7**: Phase 6 (New Task Screen)
**Week 8**: Phase 7 (Firebase Integration)
**Week 9**: Phase 8-9 (UI Polish, Offline Support)
**Week 10**: Phase 10-11 (Testing, Deployment)

**Total Estimated Time**: 10 weeks for MVP

---

## Key Technical Decisions

1. **State Management**: Provider (simple, well-supported)
2. **Backend**: Firebase (real-time, auth, storage, notifications)
3. **Local Storage**: Hive for caching (fast, NoSQL)
4. **Navigation**: Named routes with arguments
5. **Form Validation**: Manual validation with helper functions
6. **Image Handling**: Image compression before upload, thumbnail caching
7. **Voice Notes**: Record package + Firebase Storage
8. **Real-time Updates**: Firestore streams throughout
9. **Error Handling**: Try-catch with user-friendly snackbars
10. **Low Data Usage**: Thumbnail previews, no auto-download, smart caching

---

## Files to Create (Summary)

**Models** (5 files):
- `lib/models/user.dart`
- `lib/models/task.dart`
- `lib/models/message.dart`
- `lib/models/milestone.dart`
- `lib/models/system_log.dart`

**Providers** (3 files):
- `lib/providers/auth_provider.dart`
- `lib/providers/task_provider.dart`
- `lib/providers/chat_provider.dart`

**Screens** (4 files):
- `lib/screens/auth/login_screen.dart`
- `lib/screens/home/home_screen.dart`
- `lib/screens/task/task_detail_screen.dart`
- `lib/screens/new_task/new_task_screen.dart`

**Widgets** (6 files):
- `lib/widgets/task_card.dart`
- `lib/widgets/chat_bubble.dart`
- `lib/widgets/milestone_row.dart`
- `lib/widgets/quick_action_chips.dart`
- `lib/widgets/filter_chips.dart`
- `lib/widgets/template_selector.dart`

**Services** (3 files):
- `lib/services/firebase_service.dart`
- `lib/services/storage_service.dart`
- `lib/services/notification_service.dart`

**Utils** (3 files):
- `lib/utils/constants.dart`
- `lib/utils/helpers.dart`
- `lib/utils/validators.dart`

**Config** (2 files):
- `lib/config/firebase_options.dart`
- `lib/config/routes.dart`

**Total**: ~26 new files + update `main.dart`
