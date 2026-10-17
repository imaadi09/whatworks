# 🎮 WhatWorks - Demo Mode Guide

## ✅ Mock Data is Now Active!

The app is now configured with **comprehensive dummy data** so you can test all UI and functionality **without Firebase setup**.

## 🚀 Run the App Immediately

```bash
cd "g:\flutter projects\whatworks"
flutter run
```

That's it! The app will auto-login with mock data and show you the full UI.

## 👤 Mock User Account

**Current User:**
- **Name:** Aditya Sharma
- **Email:** aditya@whatworks.com
- **Phone:** 9876543210
- **Company:** Sharma Enterprises
- **Role:** Team Lead / Manager

## 📋 Pre-loaded Tasks

### Tasks Created By You (By Me Tab) - 6 Tasks

1. **Q3 Sales Report Preparation** 🔥⭐⭐⭐
   - Assigned to: Shalu Gupta
   - Deadline: Tomorrow (1 day left)
   - Progress: 65%
   - Status: Urgent

2. **Customer Delivery - Mumbai Order #4521** ⭐⭐⭐
   - Assigned to: Rahul Verma
   - Deadline: 3 days left
   - Progress: 40%
   - Extra: Order #4521, Kapoor Industries

3. **Monthly Invoice Generation** ⭐⭐
   - Assigned to: Priya Singh
   - Deadline: 7 days left
   - Progress: 25%

4. **Site Visit - Noida Project** 🔥⭐⭐
   - Assigned to: Amit Patel
   - Deadline: **OVERDUE** (-1 day)
   - Progress: 15%

5. **New Client Enquiry - Tata Motors** ⭐⭐⭐
   - Assigned to: Shalu Gupta
   - Deadline: 5 days left
   - Progress: 50%
   - Extra: Deal Value ₹25,00,000

6. **Quality Check - Batch #789** ⭐⭐
   - Assigned to: Rahul Verma
   - Deadline: 10 days left
   - Progress: 0% (Not started)

### Tasks Assigned to You (To Me Tab) - 4 Tasks

1. **Marketing Presentation for Expo** 🔥⭐⭐⭐
   - Created by: Rahul Verma
   - Deadline: 2 days left
   - Progress: 70%

2. **Cash Collection - Delhi Clients** ⭐⭐⭐
   - Created by: Priya Singh
   - Deadline: 4 days left
   - Progress: 33%
   - Extra: ₹8,50,000 from 3 clients

3. **Steel Stock Audit - Warehouse A** ⭐⭐
   - Created by: Amit Patel
   - Deadline: 8 days left
   - Progress: 45%

4. **Legal Case Filing - Supplier Dispute** 🔥⭐⭐⭐
   - Created by: Shalu Gupta
   - Deadline: **OVERDUE** (-2 days)
   - Progress: 20%
   - Extra: Case #CS-2026-045, Claim ₹15,00,000

## 🧪 What You Can Test

### ✅ Working Features

1. **Authentication Flow**
   - Auto-login on app start
   - User avatar with initials
   - Demo mode badge in header

2. **Home Screen**
   - Two tabs: "By Me" and "To Me"
   - Tab switching works
   - Pull-to-refresh (simulated)

3. **Task Cards**
   - ✅ Avatar with initials
   - ✅ Priority stars (color-coded)
   - ✅ Urgency badges (🔥 URGENT)
   - ✅ Progress bars with percentages
   - ✅ Deadline badges (green/yellow/red)
   - ✅ Task title and description preview
   - ✅ Visual distinction for overdue tasks

4. **Search & Filter**
   - ✅ Live search by task title/description
   - ✅ Filter chips:
     - All
     - Deadlines Nearing
     - Overdue (shows 2 overdue tasks)
     - High Priority (shows 5 ★★★ tasks)
     - Urgent Only (shows 3 urgent tasks)
     - Longest Pending
   - ✅ Sort options:
     - Deadline
     - Priority
     - Latest Activity
     - Oldest

5. **Task Creation**
   - ✅ Complete form with validation
   - ✅ 10 industry templates
   - ✅ Quick deadline selection
   - ✅ Priority and urgency toggles
   - ✅ Creates task and adds to list
   - ✅ Success notification

6. **UI/UX Elements**
   - ✅ WhatsApp-inspired green theme
   - ✅ Smooth animations
   - ✅ Loading states
   - ✅ Empty states (when search has no results)
   - ✅ Error handling
   - ✅ Snackbar notifications

## 🎯 Test Scenarios

### Scenario 1: Browse Tasks
1. Launch app → Auto-logs in as Aditya
2. See "By Me" tab with 6 tasks
3. Tap "To Me" tab → See 4 tasks
4. Notice different deadline colors:
   - 🔴 Red = Overdue
   - 🟡 Yellow = Due soon (1-2 days)
   - 🟢 Green = On time

### Scenario 2: Search & Filter
1. Type "sales" in search bar
   - Shows only sales-related tasks
2. Clear search
3. Tap "Overdue" filter chip
   - Shows 2 overdue tasks
4. Tap "High Priority" filter
   - Shows 5 tasks with ★★★
5. Tap "Urgent Only" filter
   - Shows 3 urgent tasks

### Scenario 3: Sort Tasks
1. Change sort to "Deadline"
   - Tasks ordered by deadline date
2. Change sort to "Priority"
   - High priority tasks first
3. Change sort to "Oldest"
   - Oldest tasks first

### Scenario 4: Create New Task
1. Tap "+" button
2. Fill form:
   - Title: "Follow up with client"
   - Assign to: "John Doe"
   - Priority: High ★★★
   - Urgency: Toggle on
   - Deadline: Tap "3 Days" chip
   - Description: "Important follow-up call"
3. Tap "Assign Now"
4. See success message
5. Task appears in "By Me" list

### Scenario 5: Use Templates
1. Tap "+" button
2. Scroll template row
3. Tap "Sales Report" template
   - Title auto-fills
4. Tap "Customer Delivery" template
   - Title changes
5. Complete and create task

### Scenario 6: Test Edge Cases
1. Search for "xyz123" (non-existent)
   - Shows "No matching tasks" empty state
2. Try to create task without title
   - Shows validation error
3. Try to create task without assignee
   - Shows error message
4. Try to create task without deadline
   - Shows error message

## 🎨 Visual Elements to Notice

### Color Coding
- **Priority Stars:**
  - ★★★ (High) = Red/Orange
  - ★★ (Mid) = Orange/Yellow

- **Deadline Badges:**
  - Overdue = Red background + border
  - Nearing (1-2 days) = Yellow/Orange
  - On-time = Green
  - No deadline = Grey

- **Urgency:**
  - 🔥 URGENT badge = Red background
  - Visible on 3 tasks

### Progress Bars
- Green fill for active tasks
- Grey fill for closed tasks
- Percentage shown on right

### Card Layout
- Clean WhatsApp-style design
- Avatar with initials
- Truncated descriptions
- Last message preview icon

## 📊 Mock Data Structure

The app includes:
- **5 Team Members**: Aditya, Shalu, Rahul, Priya, Amit
- **10 Total Tasks**: 6 created by you, 4 assigned to you
- **Various States**: Overdue, urgent, high priority, in-progress, not started
- **Different Templates**: Sales, Delivery, Finance, Operations, Legal
- **Realistic Data**: Indian names, companies, phone numbers, currency

## 🔧 Switching to Real Firebase

When you're ready to use real Firebase:

1. **Setup Firebase** (see README.md)
2. **Update AuthProvider:**
   ```dart
   bool _useMockData = false; // Change this
   ```
3. **Update TaskProvider:**
   ```dart
   bool _useMockData = false; // Change this
   ```
4. **Uncomment Firebase code** in both providers
5. **Restart app**

## 🐛 Troubleshooting

### No Tasks Showing
- Pull down to refresh
- Check if you're on the right tab
- Clear search bar

### App Crashes on Startup
```bash
flutter clean
flutter pub get
flutter run
```

### Search Not Working
- Make sure you're typing in task titles/descriptions from the mock data
- Try "sales", "delivery", "invoice"

### Can't Create Task
- Check all required fields are filled
- Title must be 3+ characters
- Description must be 10+ characters
- Assignee and deadline are required

## 📱 Screenshots You'll See

1. **Login Screen**: WhatWorks branding with Google Sign-In
2. **Home Screen**: 
   - Yellow "DEMO" badge in top-right
   - User avatar "AS" (Aditya Sharma)
   - "By Me" tab with 6 task cards
   - Search bar and filter chips
   - Green "+" floating button
3. **New Task Screen**: Complete form with templates

## 🎉 You're All Set!

The app is fully functional with mock data. You can:
- ✅ Test all UI elements
- ✅ Verify search and filtering
- ✅ Test task creation
- ✅ Check responsive design
- ✅ Validate animations
- ✅ Review color schemes
- ✅ Test error handling

**Next Step:** Run `flutter run` and start exploring! 🚀

---

**Note:** This is a demo mode. Data won't persist between app restarts. To enable persistence, setup Firebase and switch `_useMockData = false`.
