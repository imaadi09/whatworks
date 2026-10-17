# Firestore Phone Number Indexes - Deployment Guide

## Overview
This document explains how to deploy Firestore indexes for the phone-first assignee identification system.

## Indexes Created

### 1. Users Collection - Phone Lookup
**Purpose**: Fast user lookup by phone number
**Fields**: 
- `phone` (ASCENDING)
- `isOnApp` (ASCENDING)

**Used for**: Finding if a phone number belongs to an app user

### 2. Tasks Collection - Assignee Phone + Status
**Purpose**: Query tasks assigned to a specific phone number, filtered by status
**Fields**:
- `assignedToPhone` (ASCENDING)
- `isClosed` (ASCENDING)

**Used for**: "To Me" tab - showing active tasks assigned to current user

### 3. Tasks Collection - Assignee Phone + Date
**Purpose**: Query tasks assigned to a phone number, sorted by creation date
**Fields**:
- `assignedToPhone` (ASCENDING)
- `createdAt` (DESCENDING)

**Used for**: Showing tasks assigned to a user, newest first

### 4. Tasks Collection - Creator + Assignee Phone
**Purpose**: Query tasks created by user and assigned to specific phone
**Fields**:
- `createdBy` (ASCENDING)
- `assignedToPhone` (ASCENDING)

**Used for**: "By Me" tab with phone-based assignee filtering

## Deployment Steps

### Option 1: Using Firebase CLI (Recommended)

1. **Install Firebase CLI** (if not already installed):
   ```bash
   npm install -g firebase-tools
   ```

2. **Login to Firebase**:
   ```bash
   firebase login
   ```

3. **Deploy indexes only**:
   ```bash
   firebase deploy --only firestore:indexes
   ```

4. **Wait for index creation**:
   - Indexes take 5-15 minutes to build
   - Check status in Firebase Console → Firestore → Indexes tab
   - Queries will fail until indexes show "Enabled" status

### Option 2: Manual Creation via Firebase Console

If you prefer not to use Firebase CLI, create indexes manually:

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Select your project
3. Navigate to **Firestore Database** → **Indexes** tab
4. Click **Create Index** for each index above
5. Fill in the collection group and fields as specified

## Verification

After deployment, verify indexes are working:

1. **Check Index Status**:
   - Go to Firebase Console → Firestore → Indexes
   - All indexes should show "Enabled" status (green checkmark)

2. **Test Queries**:
   ```dart
   // This query should now be fast with indexes
   final tasks = await FirebaseFirestore.instance
       .collection('tasks')
       .where('assignedToPhone', isEqualTo: '+919876543210')
       .where('isClosed', isEqualTo: false)
       .get();
   ```

## Performance Benefits

**Before Indexes**:
- Full collection scan: O(n) where n = total documents
- Slow queries on large datasets (1000+ documents)
- Potential timeout errors

**After Indexes**:
- Indexed lookup: O(log n)
- Fast queries even with 10,000+ documents
- No timeout errors
- Lower Firestore read costs

## Maintenance

- Indexes are automatically maintained by Firestore
- No manual intervention needed
- Monitor index usage in Firebase Console
- Remove unused indexes to reduce storage costs

## Troubleshooting

### "Index not found" error
- Wait 5-15 minutes for index to build
- Check Firebase Console for build status
- Verify field names match exactly (case-sensitive)

### "Failed to deploy" error
- Ensure you're logged in: `firebase login`
- Check you have editor/owner permissions on the project
- Verify firebase.json references correct file paths

### Queries still slow after indexing
- Ensure query matches index fields exactly
- Check query uses supported operators (==, <, >, etc.)
- Verify you're not using unsupported combinations

## Cost Impact

- Indexes increase storage slightly (~10-20% of data size)
- Significantly reduce read costs (fewer documents scanned)
- Overall cost reduction for phone-based queries

## Support

For issues, check:
- [Firebase Index Documentation](https://firebase.google.com/docs/firestore/query-data/indexing)
- [Firestore Pricing](https://firebase.google.com/pricing)
