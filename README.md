# WhatWorks - Work Assignment & Tracking App

A lightweight, WhatsApp-style mobile app for work assignment, progress tracking, and follow-up, built specifically for Indian SMB teams and non-tech users.

## 🚀 Features

### Core Features (Implemented)
- ✅ **Two-Tab Home Screen**: "By Me" (tasks you created) and "To Me" (tasks assigned to you)
- ✅ **Task Cards**: WhatsApp-style cards showing person name, priority stars, progress bar, deadline badges
- ✅ **Fast Task Creation**: Quick form with industry-specific templates
- ✅ **Google Authentication**: Secure sign-in with Google
- ✅ **Real-time Updates**: Firebase Firestore for live data sync
- ✅ **Search & Filters**: Live search, filter chips (Overdue, High Priority, Urgent, etc.)
- ✅ **Sorting**: Sort by deadline, priority, latest activity, oldest
- ✅ **Priority System**: Mid (★★) and High (★★★) priority levels
- ✅ **Urgency Badges**: Mark tasks as urgent with visual indicators
- ✅ **Progress Tracking**: Visual progress bars for each task
- ✅ **Deadline Management**: Color-coded deadline badges (green/yellow/red)
- ✅ **Industry Templates**: Pre-built templates for common tasks (Sales, Delivery, Finance, etc.)

### Data Models (Complete)
- ✅ User Model
- ✅ Task Model with helper methods
- ✅ Message Model (for chat threads)
- ✅ Milestone Model
- ✅ System Log Model (for auditability)

### Services (Complete)
- ✅ Firebase Service (Firestore CRUD operations)
- ✅ Storage Service (Image/file uploads)
- ✅ Notification Service (Push notifications - needs Firebase setup)

## 📱 Screens Implemented

1. **Login Screen** - Google Sign-In with app features showcase
2. **Home Screen** - Two-tab interface with search, filters, and task list
3. **New Task Screen** - Fast task creation form with templates
4. **Task Detail Screen** - (Stub created, full implementation needed)

## 🏗️ Project Structure

```
lib/
├── main.dart                          # App entry point with Firebase init
├── config/
│   ├── firebase_options.dart          # Firebase configuration (placeholder)
│   └── routes.dart                    # App route constants
├── models/
│   ├── user.dart                      # User data model
│   ├── task.dart                      # Task data model
│   ├── message.dart                   # Message data model
│   ├── milestone.dart                 # Milestone data model
│   └── system_log.dart                # System log data model
├── providers/
│   ├── auth_provider.dart             # Authentication state management
│   └── task_provider.dart             # Task state management
├── screens/
│   ├── auth/
│   │   └── login_screen.dart          # Google login screen
│   ├── home/
│   │   └── home_screen.dart           # Main dashboard with tabs
│   └── new_task/
│       └── new_task_screen.dart       # Task creation form
├── widgets/
│   └── task_card.dart                 # WhatsApp-style task card
├── services/
│   ├── firebase_service.dart          # Firebase Firestore operations
│   ├── storage_service.dart           # File/image upload service
│   └── notification_service.dart      # Push notification service
└── utils/
    ├── constants.dart                 # App constants and theme
    ├── helpers.dart                   # Helper functions
    └── validators.dart                # Form validation
```

## 🔧 Setup Instructions

### Prerequisites
- Flutter SDK 3.10.8 or higher
- Dart 3.10.8 or higher
- Android Studio / VS Code with Flutter extensions
- Firebase account

### Step 1: Clone and Install Dependencies

```bash
cd "g:\flutter projects\whatworks"
flutter pub get
```

### Step 2: Firebase Setup

1. **Create a Firebase Project**
   - Go to [Firebase Console](https://console.firebase.google.com/)
   - Click "Add project" and follow the wizard
   - Enable Authentication, Firestore, and Storage

2. **Install FlutterFire CLI**
   ```bash
   dart pub global activate flutterfire_cli
   ```

3. **Configure Firebase for Flutter**
   ```bash
   flutterfire configure
   ```
   This will:
   - Register your app with Firebase
   - Generate `firebase_options.dart` automatically
   - Replace the placeholder values in `lib/config/firebase_options.dart`

4. **Enable Firebase Services**
   - **Authentication**: Enable Google Sign-In method
   - **Firestore Database**: Create database in production mode
   - **Storage**: Enable Cloud Storage

5. **Add google-services.json (Android)**
   - Download from Firebase Console > Project Settings > Your apps
   - Place in `android/app/google-services.json`

6. **Add GoogleService-Info.plist (iOS)**
   - Download from Firebase Console
   - Place in `ios/Runner/GoogleService-Info.plist`

### Step 3: Run the App

```bash
# For Android
flutter run

# For iOS (Mac only)
flutter run -d ios

# For Web
flutter run -d chrome

# For Windows
flutter run -d windows
```

## 🎨 Theme & Customization

The app uses a WhatsApp-inspired green theme. Customize in `lib/utils/constants.dart`:

```dart
class AppTheme {
  static const primaryGreen = Color(0xFF25D366);
  static const darkGreen = Color(0xFF128C7E);
  static const tealGreen = Color(0xFF075E54);
  // ... more colors
}
```

## 📋 Firestore Database Structure

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
    - senderId, text, type, fileUrl, fileName, duration, createdAt

tasks/{taskId}/milestones/
  {milestoneId}/
    - title, dueDate, isCompleted, completedAt, progress

tasks/{taskId}/system_logs/
  {logId}/
    - action, performedBy, details, createdAt
```

## 🔐 Firestore Security Rules

Add these rules in Firebase Console > Firestore Database > Rules:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can read/write their own profile
    match /users/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Tasks: authenticated users can read/write
    match /tasks/{taskId} {
      allow read: if request.auth != null;
      allow create, update, delete: if request.auth != null;
      
      // Subcollections
      match /messages/{messageId} {
        allow read, write: if request.auth != null;
      }
      
      match /milestones/{milestoneId} {
        allow read, write: if request.auth != null;
      }
      
      match /system_logs/{logId} {
        allow read, write: if request.auth != null;
      }
    }
  }
}
```

## 🚧 What's Next (Remaining Work)

### High Priority
1. **Task Detail Screen**: Complete WhatsApp-style chat interface
   - Chat bubbles (green/white)
   - Message input with attachments
   - Quick action chips
   - Milestone display and management
   - System log messages

2. **Chat Provider**: Message sending/receiving logic
   - Real-time message streams
   - File/voice note uploads
   - System log generation

3. **Additional Widgets**:
   - ChatBubble widget
   - MilestoneRow widget
   - QuickActionChips widget
   - FilterChips widget (enhanced)
   - TemplateSelector widget

### Medium Priority
4. **Profile/Settings Screen**
   - User profile editing
   - Notification preferences
   - Storage usage display

5. **Offline Support**
   - Local caching with Hive
   - Queue actions when offline
   - Sync on reconnection

6. **Performance Optimization**
   - Pagination for old messages
   - Image compression
   - Lazy loading

### Future Enhancements (Post-MVP)
7. **SMS/WhatsApp Bridge**
   - Twilio API integration
   - WhatsApp Business API
   - SMS reply parsing

8. **Advanced Features**
   - Team analytics dashboard
   - Custom templates per industry
   - Bulk task operations
   - Task dependencies
   - Recurring tasks

## 🐛 Troubleshooting

### Common Issues

**Error: Firebase not initialized**
- Run `flutterfire configure` to generate proper Firebase configuration
- Ensure `google-services.json` is in `android/app/`

**Error: Google Sign-In fails**
- Add SHA-1 fingerprint to Firebase Console
- For Android: `cd android && ./gradlew signingReport`
- For iOS: Ensure URL schemes are configured in Info.plist

**Error: Firestore permission denied**
- Check Firestore security rules
- Ensure user is authenticated before accessing data

**Build fails after adding dependencies**
- Run `flutter clean`
- Run `flutter pub get`
- Rebuild the app

## 📦 Dependencies

### Core
- `firebase_core` - Firebase initialization
- `firebase_auth` - Authentication
- `cloud_firestore` - Database
- `firebase_storage` - File storage
- `firebase_messaging` - Push notifications
- `provider` - State management

### UI & Utilities
- `google_sign_in` - Google authentication
- `image_picker` - Camera/gallery access
- `file_picker` - File selection
- `cached_network_image` - Image caching
- `flutter_slidable` - Swipeable cards
- `intl` - Date formatting
- `flutter_local_notifications` - Local notifications

### Media
- `record` - Voice recording
- `audioplayers` - Audio playback

## 📝 License

This project is proprietary. All rights reserved.

## 👥 Team

Built for Indian SMB teams who currently rely on chaotic WhatsApp groups for work management.

## 📞 Support

For issues or questions, please create an issue in the repository.

---

**Status**: MVP Foundation Complete ✅
**Completion**: ~60%
**Next Steps**: Complete Task Detail Screen, Chat Provider, and additional widgets
