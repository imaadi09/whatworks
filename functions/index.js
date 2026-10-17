/**
 * Firebase Cloud Function: Cleanup Old Attachments
 *
 * Minimal Server Strategy — attachments are ephemeral delivery objects; the
 * local device (SQLite + file cache) is the permanent store. Clients delete
 * the server copy as soon as every recipient has downloaded it (see
 * StorageService.maybeDeleteServerAttachment). This daily sweep is the
 * safety net:
 *  a) Deletes files where ALL recipients have downloaded but the client-side
 *     delete failed or never ran.
 *  b) Deletes files nobody downloaded once the retention window passes
 *     (24 hours for every plan).
 *  c) Deletes orphaned Storage objects no live message references anymore
 *     (hard-deleted entities/messages, URL churn from upload retries).
 *
 * Covers all three chat modules: tasks, sales_enquiries, crm_records.
 *
 * Deploy: firebase deploy --only functions
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

const db = admin.firestore();
const storage = admin.storage();

// Attachment retention periods (in hours) -- minimum-grace floors only. The
// client deletes the server copy at download time; this sweep is the repair
// net and runs daily, so real-world lifetimes round up to the sweep cadence.
// 168h (7 days) matches MESSAGE_MAX_RETENTION_HOURS so a never-downloaded
// file survives exactly as long as its (never-read) parent message text.
const RETENTION_HOURS = {
  free: 168,   // Undownloaded files: delete after 7 days
  paid: 168,   // Undownloaded files: delete after 7 days
};

// All chat modules. One list drives the attachment sweep, the message sweep
// and the message-lifecycle triggers — adding a module is a one-line change.
const CHAT_COLLECTIONS = ['tasks', 'sales_enquiries', 'crm_records'];

// Sweeps only scan entities whose updatedAt falls inside a lookback window.
// Sending any message bumps the parent's updatedAt, so an entity with live
// messages or attachments always sits inside the window; the generous sizes
// tolerate multi-day scheduler outages. Keeps the scans cheap at scale.

// The attachment sweep window must EXCEED the retention ceiling plus the
// sweep cadence: an undownloaded attachment now survives RETENTION_HOURS
// (168h), and a dormant entity stops getting updatedAt bumps as soon as its
// last message was sent — exactly when its oldest un-downloaded file is
// crossing the ceiling. Past-ceiling files that fall out of the scan would
// linger forever.
const ATTACHMENT_SWEEP_LOOKBACK_HOURS = 240;

// Storage prefixes that hold chat attachments. Task uploads always land
// under tasks/; sales/CRM file-picker uploads land under sales/ (their
// image/voice uploads reuse tasks/ via StorageService).
const ATTACHMENT_STORAGE_PREFIXES = ['tasks/', 'sales/'];

// Orphan sweep: only delete unreferenced objects older than this many hours
// so in-flight uploads are never touched.
const ORPHAN_MIN_AGE_HOURS = 24;

/**
 * Scheduled function: Run once a day
 * Deletes attachments per the rules in the header comment.
 */
exports.cleanupOldAttachments = functions.pubsub
  .schedule('every 24 hours')
  .onRun(async (context) => {
    console.log('[Cleanup] Starting attachment cleanup...');

    try {
      const storageBucket = storage.bucket();
      const now = new Date();
      let deletedCount = 0;
      // Every Storage path still referenced by a live message doc.
      const referencedPaths = new Set();

      const cutoff = new Date(
        now.getTime() - ATTACHMENT_SWEEP_LOOKBACK_HOURS * 60 * 60 * 1000
      );

      for (const collectionName of CHAT_COLLECTIONS) {
        // Window the entity scan by updatedAt (see ATTACHMENT_SWEEP_LOOKBACK_HOURS).
        const entitiesSnapshot = await db
          .collection(collectionName)
          .where('updatedAt', '>', cutoff)
          .get();

        for (const entityDoc of entitiesSnapshot.docs) {
          const entityData = entityDoc.data();
          const entityId = entityDoc.id;

          const participants = entityParticipants(entityData);
          if (participants.length === 0) continue;

          // Check user plan types
          const userPlans = await getUserPlanTypes(participants);
          const isEnterprise = Object.values(userPlans).includes('enterprise');

          // Get retention period based on plan
          const retentionHours = isEnterprise
            ? RETENTION_HOURS.paid
            : RETENTION_HOURS.free;

          // Get all messages for this entity
          const messagesSnapshot = await db
            .collection(collectionName)
            .doc(entityId)
            .collection('messages')
            .get();

          for (const msgDoc of messagesSnapshot.docs) {
            const msgData = msgDoc.data();

            // Skip if no attachment
            if (!msgData.fileUrl) continue;

            const path = storagePathFromUrl(msgData.fileUrl);
            if (path) referencedPaths.add(path);

            if (shouldDeleteAttachment(
              msgData,
              participants,
              now,
              retentionHours,
              entityData
            )) {
              await deleteAttachment(storageBucket, msgData.fileUrl);

              // Remove fileUrl from message
              await msgDoc.ref.update({
                fileUrl: admin.firestore.FieldValue.delete(),
                fileName: admin.firestore.FieldValue.delete(),
              });

              deletedCount++;
              console.log(
                `[Cleanup] Deleted attachment for message: ${collectionName}/${entityId}/${msgDoc.id}`
              );
            }
          }
        }
      }

      // Orphan sweep: Storage objects older than ORPHAN_MIN_AGE_HOURS that no
      // live message references (deleted entity/message, URL churn after
      // upload retries) are removed. profile_images etc. are untouched —
      // only chat attachment prefixes are listed.
      let orphanCount = 0;
      for (const prefix of ATTACHMENT_STORAGE_PREFIXES) {
        const [files] = await storageBucket.getFiles({ prefix });
        for (const file of files) {
          if (referencedPaths.has(file.name)) continue;
          const created = new Date(file.metadata.timeCreated);
          const ageHours = (now.getTime() - created.getTime()) / (60 * 60 * 1000);
          if (ageHours < ORPHAN_MIN_AGE_HOURS) continue;
          try {
            await file.delete();
            orphanCount++;
            console.log(`[Cleanup] Orphan deleted (${ageHours.toFixed(1)}h old): ${file.name}`);
          } catch (error) {
            console.error(`[Cleanup] Error deleting orphan ${file.name}:`, error);
          }
        }
      }

      console.log(
        `[Cleanup] Complete. Deleted ${deletedCount} attachments, ${orphanCount} orphans`
      );
      return null;

    } catch (error) {
      console.error('[Cleanup] Error:', error);
      return null;
    }
  });

/**
 * Collect every UID that can participate in this entity's chat. Works for
 * task docs (participants + createdBy + assignedToUid + extraFields.assigneeUids)
 * and enquiry docs (createdBy + assignedToUid + extraFields.assigneeUids).
 */
function entityParticipants(data) {
  const uids = new Set();
  const add = (v) => {
    if (typeof v === 'string' && v.trim()) uids.add(v.trim());
  };
  add(data.createdBy);
  add(data.assignedToUid);
  if (Array.isArray(data.participants)) data.participants.forEach(add);
  const extra = data.extraFields;
  if (extra && Array.isArray(extra.assigneeUids)) extra.assigneeUids.forEach(add);
  return [...uids];
}

/**
 * Decide whether an attachment's server copy should be deleted:
 * 1. ALL recipients downloaded -> delete now (the client-side delete failed
 *    or never ran — this is the repair path).
 * 2. Retention window expired -> delete. This is the "nobody downloaded"
 *    case plus solo conversations (sender holds the original locally; the
 *    grace window only lets the sender's other devices pick it up).
 * 3. Entity closed/cancelled -> delete 1h after close.
 */
function shouldDeleteAttachment(messageData, participants, now, retentionHours, entityData) {
  const createdAt = messageData.createdAt && messageData.createdAt.toDate
    ? messageData.createdAt.toDate()
    : null;
  if (!createdAt) return false;

  const downloadedBy = messageData.downloadedBy || {};
  const senderId = messageData.senderId || entityData.createdBy || '';
  const recipients = participants.filter((uid) => uid && uid !== senderId);
  const ageHours = (now.getTime() - createdAt.getTime()) / (60 * 60 * 1000);

  // 1) Everyone who needs it already has it.
  if (recipients.length > 0 && recipients.every((uid) => downloadedBy[uid] === true)) {
    console.log(`[Cleanup] All recipients downloaded, deleting: ${messageData.fileUrl}`);
    return true;
  }

  // 2) Retention expired (never-downloaded files and solo conversations).
  if (ageHours > retentionHours) {
    console.log(`[Cleanup] Retention expired (${ageHours.toFixed(1)}h > ${retentionHours}h), deleting: ${messageData.fileUrl}`);
    return true;
  }

  // 3) Entity completed/cancelled: shorter retention (1 hour after close).
  if (entityData.isClosed || entityData.isCancelled) {
    const completedAt = entityData.updatedAt && entityData.updatedAt.toDate
      ? entityData.updatedAt.toDate()
      : null;
    if (completedAt && now.getTime() - completedAt.getTime() > 60 * 60 * 1000) {
      console.log(`[Cleanup] Entity closed, retention expired: ${messageData.fileUrl}`);
      return true;
    }
  }

  return false;
}

/**
 * Get plan types for all participants. Resolves the per-module map first: a
 * user counts as paid if ANY module subscription is still within its own
 * expiry; otherwise falls back to the legacy top-level planType.
 */
async function getUserPlanTypes(userIds) {
  const plans = {};
  
  for (const userId of userIds) {
    try {
      const userDoc = await db.collection('users').doc(userId).get();
      if (userDoc.exists) {
        plans[userId] = resolvePaidPlanType(userDoc.data());
      } else {
        plans[userId] = 'basic';
      }
    } catch (error) {
      console.error(`[Cleanup] Error getting plan for user ${userId}:`, error);
      plans[userId] = 'basic';
    }
  }
  
  return plans;
}

/**
 * Derives a user's effective plan from their per-module subscriptions, then
 * the legacy top-level fields. Expired module entries never count.
 */
function resolvePaidPlanType(userData) {
  const now = new Date();
  const modulePlans = (userData && userData.modulePlans) || {};
  const TIER_RANK = { enterprise: 3, business: 2, premium: 1, basic: 0 };
  let best = null;
  for (const entry of Object.values(modulePlans)) {
    const expiry = entry && entry.expiryDate ? entry.expiryDate.toDate() : null;
    if (!entry || !expiry || expiry <= now) continue;
    if (!best || (TIER_RANK[entry.planType] || 0) > (TIER_RANK[best] || 0)) {
      best = entry.planType;
    }
  }
  if (best) return best;
  return (userData && userData.planType) || 'basic';
}

/**
 * Convert a Firebase Storage download URL to the bucket-relative object
 * path. Returns null for non-storage URLs.
 * URL format: https://firebasestorage.googleapis.com/v0/b/bucket/o/path%2Fto%2Ffile?token=...
 */
function storagePathFromUrl(fileUrl) {
  if (!fileUrl || typeof fileUrl !== 'string') return null;
  const urlParts = fileUrl.split('/o/');
  if (urlParts.length < 2) return null;
  return decodeURIComponent(urlParts[1].split('?')[0]);
}

/**
 * Delete attachment from Firebase Storage
 */
async function deleteAttachment(bucket, fileUrl) {
  try {
    const filePath = storagePathFromUrl(fileUrl);
    if (!filePath) return;

    const file = bucket.file(filePath);
    const [exists] = await file.exists();
    
    if (exists) {
      await file.delete();
      console.log(`[Cleanup] File deleted from storage: ${filePath}`);
    }
  } catch (error) {
    console.error('[Cleanup] Error deleting file:', error);
  }
}

// Message-lifecycle triggers, registered identically for every chat module.
// Soft delete: purge the Storage file and strip the URL fields.
// Hard delete ("for everyone"): purge the Storage file immediately.
for (const collectionName of CHAT_COLLECTIONS) {
  exports[`onMessageSoftDeleted_${collectionName}`] = functions.firestore
    .document(`${collectionName}/{parentId}/messages/{messageId}`)
    .onUpdate(async (change, context) => {
      const beforeData = change.before.data();
      const afterData = change.after.data();

      // Only trigger when 'deleted' field changes from false/missing to true
      if (beforeData.deleted === true) return null; // Already deleted before
      if (afterData.deleted !== true) return null;   // Not a delete update

      if (!afterData.fileUrl) return null;

      const fileUrl = afterData.fileUrl;
      console.log(
        `[Cleanup] ${collectionName} message soft-deleted, removing attachment: ${fileUrl}`
      );

      try {
        const storageBucket = storage.bucket();
        await deleteAttachment(storageBucket, fileUrl);

        // Also strip fileUrl/fileName from the document to save Firestore space
        await change.after.ref.update({
          fileUrl: admin.firestore.FieldValue.delete(),
          fileName: admin.firestore.FieldValue.delete(),
        });

        console.log(`[Cleanup] Attachment cleaned up after soft delete`);
      } catch (error) {
        console.error('[Cleanup] Error on soft-delete cleanup:', error);
      }

      return null;
    });

  exports[`onMessageDeleted_${collectionName}`] = functions.firestore
    .document(`${collectionName}/{parentId}/messages/{messageId}`)
    .onDelete(async (snapshot, context) => {
      const messageData = snapshot.data();

      if (!messageData || !messageData.fileUrl) return null;

      const fileUrl = messageData.fileUrl;
      console.log(
        `[Cleanup] ${collectionName} message deleted for everyone, removing attachment: ${fileUrl}`
      );

      try {
        const storageBucket = storage.bucket();
        await deleteAttachment(storageBucket, fileUrl);
        console.log(`[Cleanup] Attachment deleted from storage after message deletion`);
      } catch (error) {
        console.error('[Cleanup] Error deleting attachment on message delete:', error);
      }

      return null;
    });
}

/**
 * Trigger: Track when user downloads attachment
 */
exports.trackAttachmentDownload = functions.https.onCall(async (data, context) => {
  // Common for every chat module. Legacy callers send taskId; new callers
  // send entityId + collection. Unknown collections fall back to 'tasks'.
  const entityId = (data && (data.entityId || data.taskId)) || '';
  const messageId = (data && data.messageId) || '';
  const userId = (data && data.userId) || '';
  const collection = CHAT_COLLECTIONS.includes(data && data.collection)
    ? data.collection
    : 'tasks';

  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  
  try {
    const messageRef = db
      .collection(collection)
      .doc(entityId)
      .collection('messages')
      .doc(messageId);
    
    await messageRef.update({
      [`downloadedBy.${userId}`]: true,
    });
    
    console.log(`[Download] Tracked download for user ${userId} on message ${messageId}`);
    return { success: true };
  } catch (error) {
    console.error('[Download] Error tracking download:', error);
    throw new functions.https.HttpsError('internal', 'Failed to track download');
  }
});

// ─── MESSAGE CLEANUP ─────────────────────────────────────────────────────────

// Maximum retention: force-delete a message after 7 days even if some
// recipient has never read it. Fully-read docs still die much earlier via the
// all-read rule and the client-side cleanup sweep; this is only the ceiling for
// the never-read tail, so an offline recipient gets a week to catch up.
const MESSAGE_MAX_RETENTION_HOURS = 168;

// The message sweep scans entities touched inside THIS window. An entity is
// only ever scanned while its newest message sits inside the lookback, so the
// window must comfortably exceed MESSAGE_MAX_RETENTION_HOURS (plus the 48h
// sweep cadence) or a dormant entity's 7-day-old never-read message would
// fall out of the scan before it ever crossed the ceiling and would linger on
// the server forever.
const MESSAGE_SWEEP_LOOKBACK_HOURS = 240;

/**
 * Common message sweep for one chat collection. Deletes message docs once
 * ALL participants have read them, or force-deletes after max retention.
 * The permanent copy lives in each device's SQLite -- Firestore is delivery
 * only. Shared by every module in CHAT_COLLECTIONS.
 */
async function sweepMessagesForCollection(collectionName, now) {
  let deletedCount = 0;
  let forceDeletedCount = 0;

  // Window the entity scan by updatedAt (see MESSAGE_SWEEP_LOOKBACK_HOURS —
  // deliberately wider than the attachment sweep so the never-read 7-day tail
  // is still reached before its ceiling).
  const cutoff = new Date(
    now.getTime() - MESSAGE_SWEEP_LOOKBACK_HOURS * 60 * 60 * 1000
  );
  const entitiesSnapshot = await db
    .collection(collectionName)
    .where('updatedAt', '>', cutoff)
    .get();

  for (const entityDoc of entitiesSnapshot.docs) {
    const entityData = entityDoc.data();
    const entityId = entityDoc.id;

    // Shared participant resolver: creator + assignees + participants.
    const allParticipants = entityParticipants(entityData);
    if (allParticipants.length === 0) continue;

    const messagesSnapshot = await db
      .collection(collectionName)
      .doc(entityId)
      .collection('messages')
      .get();

    for (const msgDoc of messagesSnapshot.docs) {
      const msgData = msgDoc.data();

      // Skip already soft-deleted messages
      if (msgData.deleted === true) continue;

      const createdAt = msgData.createdAt && msgData.createdAt.toDate
        ? msgData.createdAt.toDate()
        : null;
      if (!createdAt) continue;

      const ageHours = (now.getTime() - createdAt.getTime()) / (60 * 60 * 1000);

      // FORCE DELETE: past maximum retention regardless of read status
      if (ageHours > MESSAGE_MAX_RETENTION_HOURS) {
        await msgDoc.ref.delete();
        forceDeletedCount++;
        continue;
      }

      // Early delete: every participant has a readBy receipt.
      const readBy = msgData.readBy || {};
      const allRead = allParticipants.every((uid) => readBy[uid] !== undefined);
      if (allRead) {
        await msgDoc.ref.delete();
        deletedCount++;
      }
    }
  }

  console.log(
    `[MsgCleanup] ${collectionName}: deleted ${deletedCount}, force-deleted ${forceDeletedCount}`
  );
}

/**
 * Scheduled function: Run roughly every 48 hours (03:00 UTC, every 2nd day)
 * One common sweep for ALL chat modules (tasks, sales, CRM).
 */
exports.cleanupMessages = functions.pubsub
  .schedule('0 3 */2 * *')
  .onRun(async (context) => {
    console.log('[MsgCleanup] Starting message cleanup...');

    const now = new Date();
    for (const collectionName of CHAT_COLLECTIONS) {
      try {
        await sweepMessagesForCollection(collectionName, now);
      } catch (error) {
        // One collection failing must not starve the others.
        console.error(`[MsgCleanup] ${collectionName} sweep error:`, error);
      }
    }
    console.log('[MsgCleanup] Complete.');
    return null;
  });

// ─── ORGANIZATION MEMBERSHIP ─────────────────────────────────────────────────
//
// Subscriptions are purchased per organization on the billing WEBSITE (Admin
// SDK). The website owns planType/status/seats/dates/subscriptionCode. The app
// only lets users take/free seats through the callables below, which enforce
// the seat cap atomically. A user's effective plan is derived client-side from
// the org's active subscription + the user holding an active seat.

const ACTIVE_STATUSES = ['active', 'trialing'];

/**
 * Callable: joinOrganization({ orgCode })
 * Looks up an org by its short join code, verifies the subscription is active
 * and has a free seat, then atomically creates members/{uid}, sets
 * users/{uid}.orgId and increments seatsUsed.
 */
exports.joinOrganization = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be signed in.');
  }
  const uid = context.auth.uid;
  const orgCode = (data && data.orgCode ? String(data.orgCode) : '').trim();
  if (!orgCode) {
    throw new functions.https.HttpsError('invalid-argument', 'An organization code is required.');
  }

  // Resolve org by code (outside the transaction; code is immutable-ish).
  const orgQuery = await db
    .collection('organizations')
    .where('orgCode', '==', orgCode)
    .limit(1)
    .get();

  if (orgQuery.empty) {
    throw new functions.https.HttpsError('not-found', 'No organization found with that code.');
  }

  const orgRef = orgQuery.docs[0].ref;
  const orgId = orgRef.id;

  // Read the joining user's profile for the member record.
  const userSnap = await db.collection('users').doc(uid).get();
  const userData = userSnap.exists ? userSnap.data() : {};
  const displayName = userData.name || '';
  const phone = userData.phone || userData.mobileNumber || '';

  await db.runTransaction(async (tx) => {
    const orgDoc = await tx.get(orgRef);
    if (!orgDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Organization no longer exists.');
    }
    const org = orgDoc.data();

    // Subscription must be active/trialing and not expired.
    const status = org.status || 'expired';
    if (!ACTIVE_STATUSES.includes(status)) {
      throw new functions.https.HttpsError('failed-precondition', 'This subscription is not active.');
    }
    const expiry = org.expiryDate ? org.expiryDate.toDate() : null;
    if (expiry && expiry.getTime() < Date.now()) {
      throw new functions.https.HttpsError('failed-precondition', 'This subscription has expired.');
    }

    const memberRef = orgRef.collection('members').doc(uid);
    const memberDoc = await tx.get(memberRef);
    const alreadyActive = memberDoc.exists && memberDoc.data().seatStatus === 'active';
    if (alreadyActive) {
      throw new functions.https.HttpsError('already-exists', 'You are already a member of this organization.');
    }

    const seatsTotal = Number(org.seatsTotal || 0);
    const seatsUsed = Number(org.seatsUsed || 0);
    // Rejoining a revoked seat reuses the existing slot (no extra seat).
    const takesNewSeat = !memberDoc.exists;
    if (takesNewSeat && seatsUsed >= seatsTotal) {
      throw new functions.https.HttpsError('resource-exhausted', 'All seats are currently in use.');
    }

    const role = org.ownerUid === uid ? 'owner' : 'member';
    tx.set(memberRef, {
      uid: uid,
      displayName: displayName,
      phone: phone,
      role: role,
      seatStatus: 'active',
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(db.collection('users').doc(uid), { orgId: orgId }, { merge: true });

    if (takesNewSeat) {
      tx.update(orgRef, {
        seatsUsed: admin.firestore.FieldValue.increment(1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

  console.log(`[Org] User ${uid} joined organization ${orgId}`);
  return { orgId: orgId };
});

/**
 * Callable: revokeMember({ orgId, uid })
 * Admin-only. Marks the member's seat 'revoked', clears users/{uid}.orgId and
 * decrements seatsUsed, freeing the seat for reuse.
 */
exports.revokeMember = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be signed in.');
  }
  const callerUid = context.auth.uid;
  const orgId = data && data.orgId ? String(data.orgId) : '';
  const targetUid = data && data.uid ? String(data.uid) : '';
  if (!orgId || !targetUid) {
    throw new functions.https.HttpsError('invalid-argument', 'orgId and uid are required.');
  }

  const orgRef = db.collection('organizations').doc(orgId);

  await db.runTransaction(async (tx) => {
    const orgDoc = await tx.get(orgRef);
    if (!orgDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Organization not found.');
    }
    const org = orgDoc.data();

    const isAdmin = org.ownerUid === callerUid ||
      (Array.isArray(org.adminUids) && org.adminUids.includes(callerUid));
    if (!isAdmin) {
      throw new functions.https.HttpsError('permission-denied', 'Only admins can revoke seats.');
    }
    if (org.ownerUid === targetUid) {
      throw new functions.https.HttpsError('failed-precondition', 'The owner seat cannot be revoked.');
    }

    const memberRef = orgRef.collection('members').doc(targetUid);
    const memberDoc = await tx.get(memberRef);
    if (!memberDoc.exists || memberDoc.data().seatStatus !== 'active') {
      throw new functions.https.HttpsError('failed-precondition', 'That member does not hold an active seat.');
    }

    tx.update(memberRef, { seatStatus: 'revoked' });
    tx.set(db.collection('users').doc(targetUid), { orgId: null }, { merge: true });

    const seatsUsed = Number(org.seatsUsed || 0);
    if (seatsUsed > 0) {
      tx.update(orgRef, {
        seatsUsed: admin.firestore.FieldValue.increment(-1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

  console.log(`[Org] Admin ${callerUid} revoked ${targetUid} from ${orgId}`);
  return { success: true };
});

/**
 * Trigger: self-heal seatsUsed on organization writes.
 * Recomputes seatsUsed from the count of active members and only writes back
 * when it drifts, so the website's Admin SDK updates and our transactions stay
 * consistent. The equality guard prevents infinite re-triggering.
 */
exports.onOrganizationWrite = functions.firestore
  .document('organizations/{orgId}')
  .onWrite(async (change, context) => {
    const after = change.after.exists ? change.after.data() : null;
    if (!after) return null; // Org deleted; nothing to do.

    const orgRef = change.after.ref;
    try {
      const membersSnap = await orgRef
        .collection('members')
        .where('seatStatus', '==', 'active')
        .get();
      const activeCount = membersSnap.size;
      const current = Number(after.seatsUsed || 0);
      if (current !== activeCount) {
        await orgRef.update({ seatsUsed: activeCount });
        console.log(`[Org] Reconciled seatsUsed for ${context.params.orgId}: ${current} -> ${activeCount}`);
      }
    } catch (error) {
      console.error('[Org] seatsUsed reconciliation error:', error);
    }
    return null;
  });

// ─── MESSAGE PUSH NOTIFICATIONS ──────────────────────────────────────────────
//
// When a new message document is created under a task, sales enquiry or CRM
// record, push an FCM alert to every participant except the sender. Recipient
// device tokens live in an `fcmTokens` array on each users/{uid} doc (written
// by the app).

/**
 * Build a short human-readable preview of a message for the push body.
 */
function messagePreview(msgData) {
  const type = msgData.type || 'text';
  switch (type) {
    case 'image':
      return '\uD83D\uDCF7 Photo';
    case 'file':
      return msgData.fileName ? `\uD83D\uDCCE ${msgData.fileName}` : '\uD83D\uDCCE Attachment';
    case 'voice':
      return '\uD83C\uDFA4 Voice message';
    default: {
      const t = (msgData.text || '').trim();
      if (!t) return 'New message';
      return t.length > 120 ? `${t.substring(0, 120)}\u2026` : t;
    }
  }
}

/**
 * Collect all FCM tokens for a set of recipient UIDs.
 * Returns { tokens: [...], owners: { token: uid }, prefs: { uid: notifPrefs } }
 * so invalid tokens can be traced back to the user doc they came from for
 * cleanup, and each recipient's per-type notification preferences can be
 * consulted before sending.
 */
async function collectTokens(recipientUids) {
  const tokens = [];
  const owners = {};
  const prefs = {};
  await Promise.all(
    recipientUids.map(async (uid) => {
      try {
        const snap = await db.collection('users').doc(uid).get();
        if (!snap.exists) return;
        prefs[uid] = snap.data().notifPrefs || {};
        const arr = snap.data().fcmTokens;
        if (Array.isArray(arr)) {
          for (const tk of arr) {
            if (typeof tk === 'string' && tk && !(tk in owners)) {
              tokens.push(tk);
              owners[tk] = uid;
            }
          }
        }
      } catch (e) {
        console.error(`[Push] token read failed for ${uid}:`, e);
      }
    })
  );
  return { tokens, owners, prefs };
}

/**
 * Which users/{uid}.notifPrefs flag gates a per-module message push. A
 * `category === 'call'` push is gated separately (scheduled calls have their own
 * switch regardless of module). Absent pref = enabled, so users who never opened
 * the new toggles keep receiving everything.
 */
const PREF_KEY_BY_DATATYPE = {
  task: 'task',
  enquiry: 'sales',
  crm: 'crm',
};

/**
 * Resolve recipients, build the payload, send the multicast, and prune any
 * tokens FCM reports as permanently invalid.
 */
async function sendMessagePush({
  recipients,
  senderId,
  title,
  msgData,
  dataType,
  parentId,
  messageId,
  category = 'message',
}) {
  // Skip tombstones and non-regular system messages (reminders/actions are
  // surfaced locally, not as chat pushes).
  if (msgData.deleted === true) return;
  const systemType = msgData.systemType || 'regular';
  if (systemType !== 'regular') return;

  const uniqueRecipients = [...new Set((recipients || []).filter(Boolean))].filter(
    (uid) => uid !== senderId
  );
  if (uniqueRecipients.length === 0) return;

  // Resolve the sender's display name for the notification body.
  let senderName = 'Someone';
  try {
    const senderSnap = await db.collection('users').doc(senderId).get();
    if (senderSnap.exists && senderSnap.data().name) {
      senderName = senderSnap.data().name;
    }
  } catch (e) {
    // keep default name
  }

  const { tokens, owners, prefs } = await collectTokens(uniqueRecipients);

  // Per-type suppression: the client mirrors its Settings toggles to
  // users/{uid}.notifPrefs. Drop every token whose owning recipient disabled
  // this notification type. This is what makes a disabled type truly silent
  // even when the app is closed and the OS would otherwise render the payload.
  const prefKey = category === 'call' ? 'calls' : PREF_KEY_BY_DATATYPE[dataType];
  const targetTokens = prefKey
    ? tokens.filter((tk) => {
        const uid = owners[tk];
        return !uid || (prefs[uid] || {})[prefKey] !== false;
      })
    : tokens;
  if (targetTokens.length === 0) return;

  const body = `${senderName}: ${messagePreview(msgData)}`;
  const message = {
    tokens: targetTokens,
    notification: { title: title || 'New message', body },
    data: {
      type: dataType,
      category,
      parentId: parentId || '',
      messageId: messageId || '',
      senderId: senderId || '',
    },
    android: {
      priority: 'high',
      // One pending notification per chat: while the device is offline a
      // burst (e.g. action card + its status-change twin) collapses to the
      // newest. Nothing is lost — the delta-bound sync delivers every
      // message on next open; this only caps tray noise.
      collapseKey: parentId || 'default',
      notification: { channelId: 'whatworks_channel', sound: 'default' },
    },
    apns: { payload: { aps: { sound: 'default' } } },
  };

  try {
    const resp = await admin.messaging().sendEachForMulticast(message);

    // Prune tokens that FCM reports as permanently invalid.
    const staleByUser = {};
    resp.responses.forEach((r, i) => {
      if (!r.success && r.error) {
        const code = r.error.code || '';
        if (
          code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token' ||
          code === 'messaging/invalid-argument'
        ) {
          const tk = targetTokens[i];
          const uid = owners[tk];
          if (uid) (staleByUser[uid] = staleByUser[uid] || []).push(tk);
        }
      }
    });
    await Promise.all(
      Object.entries(staleByUser).map(([uid, staleTokens]) =>
        db
          .collection('users')
          .doc(uid)
          .set(
            { fcmTokens: admin.firestore.FieldValue.arrayRemove(...staleTokens) },
            { merge: true }
          )
          .catch(() => {})
      )
    );

    console.log(`[Push] Sent ${resp.successCount}/${targetTokens.length} for ${dataType} ${parentId}`);
  } catch (e) {
    console.error('[Push] send failed:', e);
  }
}

/**
 * Trigger: push notification on new task chat message.
 */
exports.onTaskMessageCreated = functions.firestore
  .document('tasks/{taskId}/messages/{messageId}')
  .onCreate(async (snapshot, context) => {
    const msgData = snapshot.data();
    if (!msgData || !msgData.senderId) return null;
    const { taskId, messageId } = context.params;

    try {
      const taskSnap = await db.collection('tasks').doc(taskId).get();
      if (!taskSnap.exists) return null;
      const task = taskSnap.data();
      const recipients = [task.createdBy, ...(task.participants || [])];

      await sendMessagePush({
        recipients,
        senderId: msgData.senderId,
        title: task.title || 'New message',
        msgData,
        dataType: 'task',
        parentId: taskId,
        messageId,
      });
    } catch (e) {
      console.error('[Push] task message error:', e);
    }
    return null;
  });

/**
 * Trigger: push notification on new sales enquiry chat message.
 */
exports.onEnquiryMessageCreated = functions.firestore
  .document('sales_enquiries/{enquiryId}/messages/{messageId}')
  .onCreate(async (snapshot, context) => {
    const msgData = snapshot.data();
    if (!msgData || !msgData.senderId) return null;
    const { enquiryId, messageId } = context.params;

    try {
      const enquirySnap = await db.collection('sales_enquiries').doc(enquiryId).get();
      if (!enquirySnap.exists) return null;
      const enquiry = enquirySnap.data();
      const recipients = [
        enquiry.createdBy,
        enquiry.assignedToUid,
        ...(enquiry.participants || []),
      ];

      await sendMessagePush({
        recipients,
        senderId: msgData.senderId,
        title: enquiry.title || enquiry.clientName || 'New enquiry message',
        msgData,
        dataType: 'enquiry',
        parentId: enquiryId,
        messageId,
      });
    } catch (e) {
      console.error('[Push] enquiry message error:', e);
    }
    return null;
  });

/**
 * Trigger: push notification on new CRM (Service Teams) record chat message.
 * Third of the CHAT_COLLECTIONS trio — CRM chats previously ran silent while
 * the app was closed. Reuses entityParticipants (creator + assignees +
 * participants), the same resolver the cleanup sweeps use.
 */
exports.onCrmMessageCreated = functions.firestore
  .document('crm_records/{recordId}/messages/{messageId}')
  .onCreate(async (snapshot, context) => {
    const msgData = snapshot.data();
    if (!msgData || !msgData.senderId) return null;
    const { recordId, messageId } = context.params;

    try {
      const recordSnap = await db.collection('crm_records').doc(recordId).get();
      if (!recordSnap.exists) return null;
      const record = recordSnap.data();

      await sendMessagePush({
        recipients: entityParticipants(record),
        senderId: msgData.senderId,
        title: record.title || record.clientName || 'New service update',
        msgData,
        dataType: 'crm',
        parentId: recordId,
        messageId,
      });
    } catch (e) {
      console.error('[Push] crm message error:', e);
    }
    return null;
  });

// ─── SCHEDULED CALL REMINDERS ────────────────────────────────────────────────
//
// When someone schedules a call the client writes a system message with
// systemType 'call' + scheduledAt. The scheduler's own device gets a local
// notification; this sweep covers the OTHER side: every 15 minutes it pushes
// an FCM alert to every participant except the sender once scheduledAt has
// passed, then marks the message reminded so it fires exactly once.
//
// Both range bounds hit the SAME field (scheduledAt), so the query rides the
// automatic single-field index — no composite index needed. Docs without
// scheduledAt never enter the index, keeping the scan tiny.
const CALL_REMINDER_LOOKBACK_DAYS = 7;
const CALL_DATA_TYPE_BY_COLLECTION = {
  tasks: 'task',
  sales_enquiries: 'enquiry',
  crm_records: 'crm',
};

exports.remindScheduledCalls = functions.pubsub
  .schedule('every 15 minutes')
  .onRun(async () => {
    const now = Date.now();
    const floor = admin.firestore.Timestamp.fromMillis(
      now - CALL_REMINDER_LOOKBACK_DAYS * 24 * 60 * 60 * 1000
    );
    const ceil = admin.firestore.Timestamp.fromMillis(now);

    for (const collectionName of CHAT_COLLECTIONS) {
      let snap;
      try {
        snap = await db
          .collection(collectionName)
          .where('scheduledAt', '>=', floor)
          .where('scheduledAt', '<=', ceil)
          .limit(200)
          .get();
      } catch (e) {
        console.error(`[CallReminder] query failed for ${collectionName}:`, e);
        continue;
      }

      for (const msgDoc of snap.docs) {
        const msg = msgDoc.data();
        if (msg.systemType !== 'call' || msg.callReminded === true) continue;

        try {
          const entityId = msgDoc.ref.parent.parent.id;
          const entitySnap = await db
            .collection(collectionName)
            .doc(entityId)
            .get();

          if (entitySnap.exists) {
            const entity = entitySnap.data();
            const recipients = entityParticipants(entity).filter(
              (uid) => uid !== msg.senderId
            );
            const { tokens, owners, prefs } = await collectTokens(recipients);
            // Suppress scheduled-call pushes for recipients who turned the
            // "Scheduled calls" toggle off. The message is still marked reminded
            // below, so it never re-fires were they to re-enable it later.
            const callTokens = tokens.filter(
              (tk) => (prefs[owners[tk]] || {}).calls !== false
            );

            if (callTokens.length > 0) {
              let senderName = 'Someone';
              try {
                const senderSnap = await db
                  .collection('users')
                  .doc(msg.senderId)
                  .get();
                if (senderSnap.exists && senderSnap.data().name) {
                  senderName = senderSnap.data().name;
                }
              } catch (e) {
                // keep default name
              }

              const entityTitle = entity.title || entity.clientName || '';
              const body = entityTitle
                ? `${senderName}: call now — ${entityTitle}`
                : `${senderName}: call now`;

              await admin.messaging().sendEachForMulticast({
                tokens: callTokens,
                notification: {
                  title: '\uD83D\uDCDE Scheduled call',
                  body,
                },
                data: {
                  type: CALL_DATA_TYPE_BY_COLLECTION[collectionName],
                  category: 'call',
                  parentId: entityId,
                  messageId: msgDoc.id,
                  senderId: msg.senderId || '',
                },
                android: {
                  priority: 'high',
                  notification: {
                    channelId: 'whatworks_channel',
                    sound: 'default',
                  },
                },
                apns: { payload: { aps: { sound: 'default' } } },
              });
            }
          }

          // Mark reminded even when the entity is gone so the sweep never
          // retries this message.
          await msgDoc.ref.update({
            callReminded: true,
            callRemindedAt: admin.firestore.Timestamp.now(),
          });
          console.log(
            `[CallReminder] reminded ${collectionName}/${entityId}/${msgDoc.id}`
          );
        } catch (e) {
          console.error(
            `[CallReminder] failed for ${collectionName}/${msgDoc.id}:`,
            e
          );
        }
      }
    }
    return null;
  });

// ============================================================================
// BILLING (whatworks.pro) — Razorpay orders, webhook activation, expiry sweep
// ============================================================================
//
// Money rules that must not be relaxed:
//  1. Amounts come from ./plans.js, never from the browser.
//  2. Identity comes from the OTP session (context.auth) and travels to the
//     webhook inside the Razorpay order's `notes`. The browser is never asked
//     who paid.
//  3. Activation happens in the WEBHOOK, not on the success redirect. A closed
//     tab, a dead battery or a hostile client cannot prevent or fake it.
//  4. users/{uid}.planType and .planExpiry are written only here (Admin SDK
//     bypasses firestore.rules, which denies those fields to clients).

const crypto = require('crypto');
const Razorpay = require('razorpay');
const {
  priceFor,
  priceForItems,
  publicCatalogue,
  GST,
  MODULES,
} = require('./plans');

/**
 * Secrets, set with:
 *   firebase functions:config:set razorpay.key_id="..." \
 *     razorpay.key_secret="..." razorpay.webhook_secret="..."
 * Only key_id is public and may reach the browser.
 */
function razorpayConfig() {
  return (functions.config() || {}).razorpay || {};
}

/**
 * Adds whole months, clamping the day instead of overflowing: 31 Jan + 1 month
 * is 28 Feb, not 3 March (which is what Date.setMonth would give and would hand
 * out three free days every time).
 */
function addMonths(date, months) {
  const result = new Date(date.getTime());
  const targetDay = result.getDate();
  result.setDate(1);
  result.setMonth(result.getMonth() + months);
  const lastDayOfTargetMonth = new Date(
    result.getFullYear(),
    result.getMonth() + 1,
    0
  ).getDate();
  result.setDate(Math.min(targetDay, lastDayOfTargetMonth));
  return result;
}

/**
 * Callable: getPlanCatalogue()
 * Lets the site render prices from the same source that charges them, so the
 * page cannot quietly display a stale number. Public on purpose — prices are
 * not a secret.
 */
exports.getPlanCatalogue = functions.https.onCall(async () => {
  return publicCatalogue();
});

/**
 * Callable: createRazorpayOrder({ planId, durationMonths, modules })
 * Returns { orderId, keyId, currency, baseAmount, gstAmount, totalAmount, ... }
 *
 * Pricing is per module: total = per-module price x selected modules. Any
 * amount the caller sends is ignored; the price is looked up server-side.
 */
exports.createRazorpayOrder = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      'unauthenticated',
      'Sign in with your mobile number before paying.'
    );
  }

  const { key_id: keyId, key_secret: keySecret } = razorpayConfig();
  if (!keyId || !keySecret) {
    console.error('[Billing] razorpay.key_id / key_secret not configured');
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Payments are not configured yet. Please contact support.'
    );
  }

  const uid = context.auth.uid;

  // Each module can carry its OWN plan and duration ("items"). Older clients
  // send one planId + durationMonths + modules[]; that becomes a basket where
  // every module shares the same plan and duration. The browser only picks;
  // it never states a price.
  const validIds = MODULES.map((m) => m.id);
  let items = [];
  if (Array.isArray(data && data.items) && data.items.length) {
    items = data.items.map((it) => ({
      module: String((it && it.module) || ''),
      planId: String((it && it.planId) || ''),
      durationMonths: it && it.durationMonths,
    }));
  } else {
    const legacyModules = [
      ...new Set((Array.isArray(data && data.modules) ? data.modules : [])
        .map((m) => String(m))
        .filter((m) => validIds.includes(m))),
    ];
    items = legacyModules.map((m) => ({
      module: m,
      planId: data && data.planId ? String(data.planId) : '',
      durationMonths: data && data.durationMonths,
    }));
  }

  const price = priceForItems(items);
  if (!price) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Select at least one module with a valid plan and duration.'
    );
  }
  const modules = price.perItem.map((i) => i.module);

  // Phone is stored for the invoice only; it is read from Firestore, not from
  // the request, so it cannot be spoofed.
  const userSnap = await db.collection('users').doc(uid).get();
  const phone = userSnap.exists ? userSnap.data().phone || '' : '';

  const instance = new Razorpay({ key_id: keyId, key_secret: keySecret });

  let order;
  try {
    order = await instance.orders.create({
      amount: price.totalAmount, // paise
      currency: price.currency,
      // Razorpay caps receipt at 40 chars.
      receipt: `ww_${uid.substring(0, 12)}_${Date.now()}`.substring(0, 40),
      // The webhook reads identity back out of these notes. Values must be
      // strings — Razorpay rejects/stringifies anything else.
      notes: {
        uid,
        planId: price.planId,
        durationMonths: String(price.durationMonths),
        // Notes values must be strings; the webhook splits this back out.
        modules: modules.join(','),
        // Compact per-module basket, in case the payments doc is missing.
        items: price.perItem
          .map((i) => `${i.module}:${i.planId}:${i.durationMonths}`)
          .join(','),
      },
    });
  } catch (e) {
    console.error('[Billing] Razorpay order creation failed:', e);
    throw new functions.https.HttpsError(
      'internal',
      'Could not start the payment. Please try again.'
    );
  }

  await db.collection('payments').doc(order.id).set({
    uid,
    phone,
    modules,
    moduleCount: modules.length,
    items: price.perItem,
    planId: price.perItem[0].planId,
    planLabel: price.perItem[0].planLabel,
    durationMonths: price.perItem[0].durationMonths,
    durationLabel: price.perItem[0].durationLabel,
    baseAmount: price.baseAmount,
    gstAmount: price.gstAmount,
    totalAmount: price.totalAmount,
    gstEnabled: price.gstEnabled,
    gstRatePercent: price.gstRatePercent,
    currency: price.currency,
    status: 'pending',
    razorpayOrderId: order.id,
    razorpayPaymentId: null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    orderId: order.id,
    keyId, // publishable key — safe to hand to the browser
    modules,
    items: price.perItem,
    currency: price.currency,
    baseAmount: price.baseAmount,
    gstAmount: price.gstAmount,
    totalAmount: price.totalAmount,
    gstEnabled: price.gstEnabled,
    gstRatePercent: price.gstRatePercent,
  };
});

/**
 * HTTP: razorpayWebhook — the only thing that activates a plan.
 * Reachable at https://whatworks.pro/api/webhook/razorpay (firebase.json rewrite).
 * Subscribe it to payment.captured (and optionally payment.failed) in the
 * Razorpay dashboard using the same secret as razorpay.webhook_secret.
 */
exports.razorpayWebhook = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  const { webhook_secret: webhookSecret } = razorpayConfig();
  if (!webhookSecret) {
    console.error('[Billing] razorpay.webhook_secret not configured');
    res.status(500).send('Webhook not configured');
    return;
  }

  // Signature is over the RAW BYTES. Re-serialising req.body changes them
  // (key order, spacing) and the signature would never match.
  const signature = req.get('X-Razorpay-Signature') || '';
  const expected = crypto
    .createHmac('sha256', webhookSecret)
    .update(req.rawBody)
    .digest('hex');

  const sigBuf = Buffer.from(signature, 'utf8');
  const expBuf = Buffer.from(expected, 'utf8');
  if (sigBuf.length !== expBuf.length || !crypto.timingSafeEqual(sigBuf, expBuf)) {
    console.warn('[Billing] Webhook signature mismatch — ignoring payload');
    res.status(400).send('Invalid signature');
    return;
  }

  const event = (req.body && req.body.event) || '';
  const payment =
    (req.body && req.body.payload && req.body.payload.payment &&
      req.body.payload.payment.entity) || null;

  // Anything we do not handle must still be 200'd, or Razorpay retries it
  // forever.
  if (!payment || (event !== 'payment.captured' && event !== 'payment.failed')) {
    res.status(200).send('Ignored');
    return;
  }

  const orderId = payment.order_id;
  if (!orderId) {
    res.status(200).send('No order id');
    return;
  }

  try {
    await db.runTransaction(async (tx) => {
      const payRef = db.collection('payments').doc(orderId);
      const paySnap = await tx.get(payRef);

      // An order we never created (or a different environment's order).
      if (!paySnap.exists) {
        console.warn(`[Billing] Webhook for unknown order ${orderId}`);
        return;
      }
      const pay = paySnap.data();

      // Idempotency: Razorpay delivers at least once, so a replay lands here
      // with status already terminal. Doing nothing is the whole mechanism.
      if (pay.status !== 'pending') {
        console.log(`[Billing] Order ${orderId} already ${pay.status}; skipping`);
        return;
      }

      if (event === 'payment.failed') {
        tx.update(payRef, {
          status: 'failed',
          razorpayPaymentId: payment.id || null,
          failureReason: payment.error_description || 'payment_failed',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return;
      }

      // Never activate for less than the catalogue price.
      if (Number(payment.amount) !== Number(pay.totalAmount)) {
        console.error(
          `[Billing] Amount mismatch on ${orderId}: paid ${payment.amount}, ` +
            `expected ${pay.totalAmount}`
        );
        tx.update(payRef, {
          status: 'failed',
          razorpayPaymentId: payment.id || null,
          failureReason: 'amount_mismatch',
          paidAmount: Number(payment.amount) || 0,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return;
      }

      const uid = (payment.notes && payment.notes.uid) || pay.uid;

      // Subscriptions are PER MODULE, and each module in one order can carry
      // its OWN plan and duration ("items"). Every module keeps its own plan
      // type, start date and expiry under users/{uid}.modulePlans.<moduleId>.
      // Renewing a module that is still active EXTENDS from its own expiry;
      // one whose expiry has passed starts a fresh period today.
      let grants = []; // { module, months, planType }
      if (Array.isArray(pay.items) && pay.items.length) {
        grants = pay.items.map((it) => ({
          module: String(it.module || ''),
          months: Number(it.durationMonths),
          planType:
            it.grantsPlanType ||
            (priceFor(it.planId, it.durationMonths, 1) || {}).grantsPlanType ||
            'premium',
        }));
      } else if (payment.notes && payment.notes.items) {
        grants = String(payment.notes.items)
          .split(',')
          .map((s) => s.split(':'))
          .filter((p) => p.length === 3)
          .map(([mod, plan, dur]) => ({
            module: mod,
            months: Number(dur),
            planType:
              (priceFor(plan, Number(dur), 1) || {}).grantsPlanType || 'premium',
          }));
      }
      if (grants.length === 0) {
        // Orders predating per-item billing: one plan + duration for all.
        let legacyModules = Array.isArray(pay.modules) ? pay.modules : [];
        if (legacyModules.length === 0 && payment.notes && payment.notes.modules) {
          legacyModules = String(payment.notes.modules)
            .split(',')
            .map((m) => m.trim())
            .filter(Boolean);
        }
        if (legacyModules.length === 0) legacyModules = MODULES.map((m) => m.id);
        const months = Number(pay.durationMonths);
        const grantedPlanType =
          (priceFor(pay.planId, months, 1) || {}).grantsPlanType || 'premium';
        grants = legacyModules.map((m) => ({
          module: m,
          months,
          planType: grantedPlanType,
        }));
      }
      const modules = grants.map((g) => g.module);

      // All reads must precede all writes inside a transaction.
      const userRef = db.collection('users').doc(uid);
      const userSnap = await tx.get(userRef);
      const userData = userSnap.exists ? userSnap.data() : {};
      const existingModules = userData.modulePlans || {};
      const now = new Date();

      const moduleUpdates = {};
      for (const g of grants) {
        const entry = existingModules[g.module] || {};
        const prevExpiry = entry.expiryDate ? entry.expiryDate.toDate() : null;
        const periodStart =
          prevExpiry && prevExpiry > now ? prevExpiry : now;
        const periodEnd = addMonths(periodStart, g.months);
        moduleUpdates[g.module] = {
          planType: g.planType,
          startDate: admin.firestore.Timestamp.fromDate(periodStart),
          expiryDate: admin.firestore.Timestamp.fromDate(periodEnd),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
      }

      // Derived overall fields for legacy readers (badges, cleanup jobs):
      // highest tier among modules active after this purchase, and the latest
      // expiry among them.
      const merged = Object.assign({}, existingModules, moduleUpdates);
      const TIER_RANK = { enterprise: 3, business: 2, premium: 1, basic: 0 };
      let overallType = 'basic';
      let overallExpiry = null;
      for (const entry of Object.values(merged)) {
        const expiry = entry.expiryDate ? entry.expiryDate.toDate() : null;
        if (!expiry || expiry <= now) continue;
        if ((TIER_RANK[entry.planType] || 0) > (TIER_RANK[overallType] || 0)) {
          overallType = entry.planType;
        }
        if (!overallExpiry || expiry > overallExpiry) overallExpiry = expiry;
      }

      // Per-year invoice sequence, incremented in this same transaction so two
      // concurrent activations cannot share a number.
      const year = now.getFullYear();
      const counterRef = db.collection('counters').doc(`invoices-${year}`);
      const counterSnap = await tx.get(counterRef);
      const nextSeq = ((counterSnap.exists && counterSnap.data().seq) || 0) + 1;
      const invoiceNo = `WW-${year}-${String(nextSeq).padStart(4, '0')}`;

      tx.set(counterRef, { seq: nextSeq }, { merge: true });

      tx.update(payRef, {
        status: 'paid',
        razorpayPaymentId: payment.id || null,
        paymentMethod: payment.method || null,
        invoiceNo,
        modules,
        gstin: GST.enabled ? GST.gstin || null : null,
        paidAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const userUpdate = {};
      for (const [mod, entry] of Object.entries(moduleUpdates)) {
        userUpdate[`modulePlans.${mod}`] = entry;
      }
      userUpdate.planType = overallType;
      userUpdate.planExpiry = overallExpiry
        ? admin.firestore.Timestamp.fromDate(overallExpiry)
        : null;
      userUpdate.planUpdatedAt = admin.firestore.FieldValue.serverTimestamp();
      tx.set(userRef, userUpdate, { merge: true });

      console.log(
        `[Billing] Activated ${uid} (${modules.join(', ')}) — ` +
          Object.entries(moduleUpdates)
            .map(([m, e]) => `${m} until ${e.expiryDate.toDate().toISOString()}`)
            .join(', ') +
          ` (${invoiceNo})`
      );
    });
  } catch (e) {
    // 500 asks Razorpay to retry, which is what we want for a transient
    // Firestore failure — the transaction above is idempotent.
    console.error('[Billing] Webhook processing failed:', e);
    res.status(500).send('Processing error');
    return;
  }

  res.status(200).send('OK');
});

/**
 * Scheduled: expirePremiumPlans — daily downgrade of lapsed plans.
 *
 * The app already treats an elapsed planExpiry as free (UserModel
 * .effectivePlanType), but OTHER users' badges are read straight from these
 * docs, and no client can evaluate someone else's expiry against its own clock.
 * This keeps Firestore truthful.
 *
 * Needs the composite index on users (planType, planExpiry) in
 * firestore.indexes.json.
 */
exports.expirePremiumPlans = functions.pubsub
  .schedule('every 24 hours')
  .onRun(async () => {
    const now = admin.firestore.Timestamp.now();
    let downgraded = 0;

    try {
      const snap = await db
        .collection('users')
        .where('planType', 'in', ['premium', 'business', 'enterprise'])
        .where('planExpiry', '<', now)
        .limit(2000)
        .get();

      // Batches cap at 500 writes.
      let batch = db.batch();
      let inBatch = 0;
      for (const doc of snap.docs) {
        batch.update(doc.ref, {
          planType: 'basic',
          planUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        inBatch += 1;
        downgraded += 1;
        if (inBatch === 400) {
          await batch.commit();
          batch = db.batch();
          inBatch = 0;
        }
      }
      if (inBatch > 0) await batch.commit();

      console.log(`[Billing] Expiry sweep downgraded ${downgraded} user(s)`);

      // Per-module sweep: each module under users/{uid}.modulePlans keeps its
      // own expiry. Reset lapsed entries to 'basic' and refresh the derived
      // top-level planType from whatever is still active.
      const paidSnap = await db
        .collection('users')
        .where('planType', 'in', ['premium', 'business', 'enterprise'])
        .limit(2000)
        .get();

      const TIER_RANK = { enterprise: 3, business: 2, premium: 1, basic: 0 };
      let modBatch = db.batch();
      let modInBatch = 0;
      let moduleFixes = 0;
      for (const doc of paidSnap.docs) {
        const data = doc.data() || {};
        const modulePlans = data.modulePlans || {};
        if (Object.keys(modulePlans).length === 0) continue;

        const updates = {};
        let bestType = 'basic';
        let bestExpiry = null;
        let changed = false;
        for (const [mod, entry] of Object.entries(modulePlans)) {
          const expiry = entry && entry.expiryDate ? entry.expiryDate.toDate() : null;
          if (expiry && expiry < now.toDate() && entry.planType !== 'basic') {
            updates[`modulePlans.${mod}.planType`] = 'basic';
            changed = true;
            continue;
          }
          if (expiry && expiry > now.toDate()) {
            if ((TIER_RANK[entry.planType] || 0) > (TIER_RANK[bestType] || 0)) {
              bestType = entry.planType;
            }
            if (!bestExpiry || expiry > bestExpiry) bestExpiry = expiry;
          }
        }
        if (!changed) continue;

        updates.planType = bestType;
        updates.planExpiry = bestExpiry
          ? admin.firestore.Timestamp.fromDate(bestExpiry)
          : admin.firestore.FieldValue.delete();
        updates.planUpdatedAt = admin.firestore.FieldValue.serverTimestamp();
        modBatch.update(doc.ref, updates);
        modInBatch += 1;
        moduleFixes += 1;
        if (modInBatch === 400) {
          await modBatch.commit();
          modBatch = db.batch();
          modInBatch = 0;
        }
      }
      if (modInBatch > 0) await modBatch.commit();

      console.log(`[Billing] Expiry sweep reset ${moduleFixes} module subscription(s)`);
    } catch (e) {
      console.error('[Billing] Expiry sweep failed:', e);
    }
    return null;
  });

/**
 * Free 3-month Premium trial — granted once, automatically, to every brand-new
 * account. No card, no promo code, no opt-in, and (by product decision) no
 * in-app countdown or "N days left" nagging: the trial lifts the paywall
 * silently and, when it lapses, the SAME silent path a paid subscription uses
 * drops the account back to Free. Existing data is never touched — the gates
 * are create-only — so an ex-trial user keeps everything and simply can't
 * create beyond the Free caps.
 *
 * Why a Firestore onCreate trigger: premium is a *dated* grant and only the
 * Admin SDK may write planType/planExpiry/modulePlans (firestore.rules deny
 * clients). A new users/{uid} doc is created by the app with planType 'free';
 * this trigger fires once on that creation and rewrites it. onCreate fires
 * exactly once per document, so the trial is inherently one-time per account —
 * no separate ledger needed.
 *
 * Both enforcement axes are covered so the trial behaves like a real Premium
 * subscription for its run, matching what the billing webhook writes:
 *   - top-level planType + planExpiry  → the GLOBAL axis (export, reports,
 *     premium badge/settings), checked by UserModel.effectivePlanType offline.
 *   - a modulePlans entry per gated module → the PER-MODULE axis (create/assign
 *     /team capacity gates) resolved by ModulePlanCache.effectivePlanForModule.
 *     A module with no entry reads 'basic' even when the global plan is premium,
 *     so the entries are what actually raise the capacity caps.
 *
 * Expiry needs no bespoke code: the client's isPlanExpired / module expiryDate
 * checks bite immediately and offline, and the existing daily expirePremiumPlans
 * sweep rewrites the stored doc so other users' server-read badges stay
 * truthful. TRIAL_MODULES lists the modules the app gates on today; adding a
 * module there simply extends the trial to it.
 */
const TRIAL_MONTHS = 3;
const TRIAL_MODULES = ['task', 'sale', 'crm'];

exports.grantFreeTrialOnSignup = functions.firestore
  .document('users/{uid}')
  .onCreate(async (snapshot, context) => {
    const data = snapshot.data() || {};

    // Never touch an account that already carries a plan (e.g. created via an
    // org invite or a pre-seeded paid doc). Guard on any real subscription
    // signal so a legitimate purchase is never overwritten by a trial.
    const storedPlan = (data.planType || '').toString().trim().toLowerCase();
    const alreadyPaid = ['premium', 'business', 'enterprise'].includes(storedPlan);
    const hasModulePlans =
      data.modulePlans && Object.keys(data.modulePlans).length > 0;
    if (data.trialGranted || alreadyPaid || hasModulePlans || data.planExpiry) {
      return null;
    }

    const startDate = new Date();
    const expiryDate = addMonths(startDate, TRIAL_MONTHS);
    const startTs = admin.firestore.Timestamp.fromDate(startDate);
    const expiryTs = admin.firestore.Timestamp.fromDate(expiryDate);

    // Per-module entries have the SAME shape the billing webhook writes, so
    // both the offline expiry checks and the server sweeps treat a trial
    // exactly like a paid month — nothing downstream needs trial-specific
    // branching.
    const modulePlans = {};
    for (const module of TRIAL_MODULES) {
      modulePlans[module] = {
        planType: 'premium',
        startDate: startTs,
        expiryDate: expiryTs,
        updatedAt: startTs,
      };
    }

    try {
      await snapshot.ref.update({
        planType: 'premium',
        planExpiry: expiryTs,
        modulePlans,
        trialGranted: true,
        trialStartsAt: startTs,
        planUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(
        `[Trial] Granted ${TRIAL_MONTHS}-month Premium trial to new user ${context.params.uid}`
      );
    } catch (e) {
      console.error(`[Trial] Failed to grant trial to ${context.params.uid}:`, e);
    }
    return null;
  });

