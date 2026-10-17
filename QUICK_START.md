# 🚀 Quick Start Guide - WhatWorks

## Getting the App Running in 10 Minutes

### Step 1: Install Dependencies (1 min)
```bash
cd "g:\flutter projects\whatworks"
flutter pub get
```

### Step 2: Setup Firebase (5 mins)

**Option A: Using FlutterFire CLI (Recommended)**
```bash
# Install FlutterFire CLI globally
dart pub global activate flutterfire_cli

# Navigate to project
cd "g:\flutter projects\whatworks"

# Configure Firebase (interactive)
flutterfire configure
```

This will:
- Create a Firebase project (or use existing)
- Register your app for Android/iOS
- Generate `firebase_options.dart` automatically
- Replace placeholder values

**Option B: Manual Setup**
1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create new project or select existing
3. Add Android app:
   - Package name: `com.example.whatworks`
   - Download `google-services.json`
   - Place in `android/app/google-services.json`
4. Add iOS app (if needed):
   - Bundle ID: `com.example.whatworks`
   - Download `GoogleService-Info.plist`
   - Place in `ios/Runner/GoogleService-Info.plist`
5. Manually update `lib/config/firebase_options.dart` with your credentials

### Step 3: Enable Firebase Services (2 mins)

In Firebase Console:

1. **Authentication**
   - Go to Authentication > Sign-in method
   - Enable **Google** sign-in method
   - Save

2. **Firestore Database**
   - Go to Firestore Database
   - Click "Create database"
   - Start in **production mode**
   - Choose location (closest to your users)

3. **Cloud Storage**
   - Go to Storage
   - Click "Get started"
   - Start in **production mode**

4. **Update Firestore Rules**
   - Go to Firestore Database > Rules
   - Copy-paste the rules from README.md
   - Publish

### Step 4: Run the App (1 min)

```bash
# Run on connected device or emulator
flutter run

# Or specify platform
flutter run -d windows    # Windows
flutter run -d chrome     # Web browser
flutter run -d android    # Android device/emulator
```

## 🎉 That's It!

You should now see:
1. Login screen with Google Sign-In
2. After login: Home screen with "By Me" and "To Me" tabs
3. Floating "+" button to create tasks
4. Search and filter functionality

## 📱 Testing the App

### Test Flow:
1. **Sign In** → Click "Sign in with Google"
2. **Create Task** → Tap "+" button
   - Enter title: "Sales Report"
   - Assign to: "John Doe"
   - Select priority: High ★★★
   - Set deadline: Pick a date
   - Choose template: "Sales Report"
   - Tap "Assign Now"
3. **View Task** → See task in "By Me" tab
4. **Search** → Type in search bar
5. **Filter** → Tap filter chips (Overdue, High Priority, etc.)
6. **Sort** → Change sort order

## 🔧 Troubleshooting

### Build Fails
```bash
flutter clean
flutter pub get
flutter run
```

### Google Sign-In Not Working
**Android:**
```bash
# Get SHA-1 fingerprint
cd android
gradlew signingReport

# Copy SHA-1 and add to Firebase Console:
# Project Settings > Your apps > Add fingerprint
```

**iOS:**
- Ensure URL schemes are configured in `Info.plist`
- Add reversed client ID from `GoogleService-Info.plist`

### Firebase Not Initialized
```bash
# Re-run Firebase configuration
flutterfire configure
```

### Hot Reload Not Working
```bash
# Stop the app and restart
flutter run
```

## 🎨 Customization

### Change App Name
Edit `lib/utils/constants.dart`:
```dart
class AppConstants {
  static const String appName = 'YourAppName';
}
```

### Change Theme Colors
Edit `lib/utils/constants.dart`:
```dart
class AppTheme {
  static const primaryGreen = Color(0xFFYOURCOLOR);
  // ...
}
```

### Add More Templates
Edit `lib/utils/constants.dart`:
```dart
static const List<Map<String, String>> taskTemplates = [
  {'title': 'Your Template', 'icon': '🎯', 'category': 'Your Category'},
  // ...
];
```

## 📊 Current Features

✅ **Working:**
- Google Sign-In
- Create tasks with templates
- View tasks (By Me / To Me)
- Search tasks
- Filter tasks (6 types)
- Sort tasks (4 types)
- Priority system
- Urgency badges
- Progress tracking
- Deadline management
- Real-time sync (Firebase)

🚧 **Coming Next:**
- Task detail/chat screen
- Message sending
- File attachments
- Voice notes
- Milestone tracking
- Profile settings

## 📚 Learn More

- **Full Documentation**: See `README.md`
- **Implementation Status**: See `IMPLEMENTATION_STATUS.md`
- **Architecture Plan**: See plan file

## 🆘 Need Help?

Common issues and solutions are in `README.md` under "Troubleshooting" section.

---

**Ready to build?** Run `flutter run` and start creating tasks! 🚀
