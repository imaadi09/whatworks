# Organization Membership Database

## Decision: keep it organization-wise (yes)
A subscription is purchased per organization (one membership type, N seats, one expiry/renewal). Users do NOT store their own plan; a user's effective plan is DERIVED from: org subscription is active + not expired + the user holds a seat. This matches "seats subscribed for" and "members join in via code" far better than the current flat per-user `planType` in `lib/models/user.dart`.

Ownership split:
- Billing WEBSITE owns (writes via Admin SDK, app treats read-only): membership type, seatsTotal, status, start/renewal/expiry dates, subscriptionCode, and all payment records.
- APP owns (writes): members joining/leaving via org code, seat assignment/revocation by admins, org display name.

## Firestore schema (same project)
`organizations/{orgId}`
- name, orgCode (short unique join code e.g. "ACME-7X2K"), subscriptionCode (license key from website)
- ownerUid, adminUids: [uid]
- planType: 'free' | 'enterprise' (same tokens `PaywallLimits` already expects) -- website-owned
- status: 'active' | 'expired' | 'cancelled' | 'trialing' -- website-owned
- seatsTotal: int -- website-owned
- seatsUsed: int -- maintained by Cloud Function
- billingCycle: 'monthly' | 'annual', startDate, renewalDate, expiryDate (Timestamps) -- website-owned
- createdAt, updatedAt

`organizations/{orgId}/payments/{paymentId}` (website-owned, app read-only, admins only)
- amount, currency, method, transactionId, invoiceUrl, periodStart, periodEnd, status ('paid'|'pending'|'failed'|'refunded'), createdAt

`organizations/{orgId}/members/{uid}` (app-owned)
- uid, displayName, phone, role ('owner'|'admin'|'member'), seatStatus ('active'|'invited'|'revoked'), joinedAt

`users/{uid}` (extend existing doc in `lib/models/user.dart`)
- add `orgId: String?` (the org the user belongs to). Keep existing `planType` as legacy fallback for users with no org.

## Effective plan resolution
Add to `AuthProvider` a cached `String get effectivePlanType`:
- If `userModel.orgId != null`: load org (cached) -> if `status == 'active'` AND `now < expiryDate` AND member `seatStatus == 'active'` -> return `org.planType`; else `'free'`.
- Else fall back to `userModel.planType`.
Route the ~dozen existing paywall call sites (in `home_screen.dart`, `sales_home_screen.dart`, `assignee_tasks_screen.dart`) through `effectivePlanType` instead of reading `userModel.planType` directly, so all `PaywallLimits`/`isPremium` gating becomes org-driven with zero change to `PaywallLimits` itself.

## Flutter models & service
- New `lib/models/organization.dart` - `OrganizationModel` (+ `SubscriptionInfo` getters like `isActive`, `daysUntilRenewal`, `seatsAvailable`).
- New `lib/models/org_member.dart` - `OrgMemberModel`.
- New `lib/models/payment_record.dart` - `PaymentRecord` (read-only display).
- New `lib/services/organization_service.dart` - read org by id, stream members, read payments (admin), plus `joinByCode` and `revokeSeat` wrappers that call Cloud Functions.
- New `lib/providers/organization_provider.dart` - holds current org + members, exposes derived subscription state; loaded on auth.

## In-app UI (Settings)
New `lib/screens/settings/organization_screen.dart` reachable from Settings:
- Subscription card: org name, membership type (`PaywallLimits.planLabel`), status badge, seats used/total, start / renewal / expiry dates (read-only; note "Managed on the billing website").
- Codes card: organization code and subscription code with copy-to-clipboard, shown so members can join.
- Members list: name/role/seat status; owner/admin can revoke a seat (frees it).
- Join panel (users with no org): enter org code -> join -> occupy a seat.
- Payment history (admin only): read-only list from `payments` subcollection.
Payment and plan-type changes are intentionally NOT editable in-app (deep-link/button to the website instead).

## Cloud Functions (`functions/index.js`)
- `joinOrganization({ orgCode })` callable: look up org by code, verify `status=='active'` and `seatsUsed < seatsTotal`, atomically create `members/{uid}` (seatStatus active), set `users/{uid}.orgId`, increment `seatsUsed`. Returns seat-full/expired errors. Using a function keeps clients from having to query `organizations` by code and enforces the seat cap atomically.
- `revokeMember({ orgId, uid })` callable (admin only): set seatStatus 'revoked', clear `users/{uid}.orgId`, decrement `seatsUsed`.
- Trigger on `organizations/{orgId}` write (website updates): optional recompute of `seatsUsed` / propagate status.

## Security rules (`firestore.rules`)
- `organizations/{orgId}`: read if `request.auth.uid` in members or `adminUids`; client writes limited to `name`/`adminUids` by admins; website-owned fields (planType/status/seats/dates/subscriptionCode) deny client writes (only Admin SDK).
- `payments`: read by admins only; all client writes denied.
- `members/{uid}`: read by org members; create/update via Cloud Function (Admin SDK) only.
- Add composite index if any collectionGroup query on members is needed (avoided by storing `orgId` on the user doc).

## Website contract (documented for the separate site)
On purchase/renewal the website (Admin SDK) must: upsert `organizations/{orgId}` with planType, status, seatsTotal, subscriptionCode, start/renewal/expiry; append a `payments/{id}` record; on expiry set `status='expired'`. The app reacts automatically via `effectivePlanType`.

## Back-compat & migration
- Existing users keep working via `planType` fallback (no org).
- No breaking change to `PaywallLimits`.
- `UserModel.fromMap/toMap/copyWith` extended with `orgId`.

## Assumptions
- Website and app share one Firebase project; website uses Admin SDK (bypasses rules).
- One active subscription per org; all seated members share its plan.
- No in-app payment processing.

## Test Plan
- `flutter analyze` on new/edited files; `flutter build apk --release --target-platform android-arm64`.
- Manual: seed an org doc (simulating the website) with 2 seats + active status; join with a second account via org code -> becomes premium; fill seats -> 3rd join blocked; set expiry in past -> members drop to free; revoke a seat -> frees it and reverts that user to free.