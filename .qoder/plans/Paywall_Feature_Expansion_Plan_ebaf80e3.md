# Paywall Feature Expansion Plan

## Current State
- **Basic (Free)**: 20 contacts, 5 assignees, 200 MB storage, 1 sales team, no export/reports/backup
- **Premium (Enterprise)**: 100 contacts, 100 assignees, 500 MB storage, 10 sales teams, full features

---

## Tier 1: High-Value, Low-Effort (Quick Wins)

### 1.1 Message Scheduling (Send Later)
**What**: Schedule messages to be sent at a future time
**Implementation**:
- Add `scheduledAt` field to `MessageModel` in SQLite
- New `scheduled_messages` table with: `id`, `messageId`, `scheduledAt`, `status` (pending/sent/cancelled)
- Background service checks every 60s for due messages
- UI: Long-press send button → date/time picker
- Files: `message.dart`, `local_database_service.dart`, new `message_scheduler_service.dart`
**Effort**: 2-3 days
**Paywall**: Free = 5 scheduled messages, Premium = unlimited

### 1.2 Message Templates/Snippets
**What**: Save and reuse common message templates
**Implementation**:
- New `message_templates` table: `id`, `title`, `content`, `category`, `createdAt`
- Settings screen → Template management (CRUD)
- Chat input → Template picker button → Insert into text field
- Files: `local_database_service.dart`, `settings_screen.dart`, chat input widgets
**Effort**: 1-2 days
**Paywall**: Free = 3 templates, Premium = unlimited

### 1.3 Higher Storage Tiers
**What**: Offer multiple storage tiers beyond current 200/500 MB
**Implementation**:
- Update `PaywallLimits.storageQuotaMB()`: Free = 200 MB, Premium = 2 GB, Enterprise = 10 GB
- Add tier tracking in user profile
- Storage usage dashboard in Settings (current usage, limit, upgrade prompt)
- Files: `paywall_constants.dart`, `settings_screen.dart`, `storage_service.dart`
**Effort**: 0.5 days
**Paywall**: Already exists, just expand limits

### 1.4 Larger File Uploads
**What**: Increase max file size for premium users
**Implementation**:
- Update `AppValidator.maxFileSize` to be plan-aware
- Free = 100 MB (current), Premium = 500 MB, Enterprise = 1 GB
- Check plan before upload, show paywall dialog if exceeded
- Files: `validator.dart`, `task_detail_screen.dart`, `sales_detail_screen.dart`
**Effort**: 0.5 days
**Paywall**: Tiered by plan

---

## Tier 2: High-Value, Medium-Effort

### 2.1 Recurring Tasks/Enquiries
**What**: Create tasks that repeat on a schedule (daily, weekly, monthly)
**Implementation**:
- Add `recurrence` field to `TaskModel`: `type` (daily/weekly/monthly), `interval`, `endDate`
- New `task_recurrences` table: `taskId`, `recurrenceType`, `interval`, `nextDue`, `lastGenerated`
- Background service generates new task instances when due
- UI: Task creation → "Repeat" option → Recurrence picker
- Files: `task.dart`, `local_database_service.dart`, new `recurrence_service.dart`
**Effort**: 3-4 days
**Paywall**: Free = No recurring, Premium = Yes

### 2.2 Advanced Search (Full-Text + Filters)
**What**: Search across all messages, tasks, contacts with filters
**Implementation**:
- SQLite FTS5 virtual table on `messages` for full-text search
- Filter UI: date range, sender, file type, task status
- Search results screen with grouped results (messages, tasks, contacts)
- Files: `local_database_service.dart`, new `search_screen.dart`, FTS migration
**Effort**: 3-4 days
**Paywall**: Free = Basic search (last 30 days), Premium = Full history + filters

### 2.3 Custom Fields per Task Type
**What**: Define custom fields for different task categories
**Implementation**:
- New `custom_field_definitions` table: `id`, `name`, `type` (text/number/date/checkbox), `required`
- New `custom_field_values` table: `taskId`, `fieldId`, `value`
- Task creation/edit → Dynamic field rendering based on task type
- Files: `local_database_service.dart`, `task_creation_chat_screen.dart`, `task_edit_chat_screen.dart`
**Effort**: 4-5 days
**Paywall**: Free = 3 custom fields, Premium = unlimited

### 2.4 Advanced Reporting/Analytics
**What**: Charts and insights on task completion, response times, team performance
**Implementation**:
- New `reports_screen.dart` with charts (using `fl_chart` package)
- Metrics: Tasks completed/week, avg response time, overdue tasks, assignee workload
- Date range picker, export report as PDF
- Files: New `reports_screen.dart`, `reports_service.dart`, add `fl_chart` to `pubspec.yaml`
**Effort**: 5-6 days
**Paywall**: Free = Basic (last 7 days), Premium = Full history + export

---

## Tier 3: Medium-Value, Medium-Effort

### 3.1 Auto-Assign Rules
**What**: Automatically assign tasks based on rules (e.g., client → assignee)
**Implementation**:
- New `auto_assign_rules` table: `id`, `condition` (client/keyword/task type), `assigneeUid`, `priority`
- Rule evaluation on task creation
- Settings → Rule management UI
- Files: `local_database_service.dart`, new `auto_assign_service.dart`, `settings_screen.dart`
**Effort**: 3-4 days
**Paywall**: Free = No auto-assign, Premium = Yes

### 3.2 Task Dependencies/Linking
**What**: Link tasks with dependencies (Task B starts after Task A completes)
**Implementation**:
- New `task_dependencies` table: `taskId`, `dependsOnTaskId`, `type` (finish-to-start, etc.)
- UI: Task detail → "Dependencies" section → Link existing tasks
- Block task start if dependency not met (show warning)
- Files: `task.dart`, `local_database_service.dart`, `task_detail_screen.dart`
**Effort**: 3-4 days
**Paywall**: Free = No dependencies, Premium = Yes

### 3.3 Broadcast Messages
**What**: Send same message to multiple contacts/tasks at once
**Implementation**:
- New `broadcast_messages` table: `id`, `text`, `recipientTaskIds` (JSON array), `sentAt`
- UI: New broadcast screen → Select recipients → Compose → Send
- Loop through recipients, create message for each
- Files: New `broadcast_screen.dart`, `local_database_service.dart`
**Effort**: 2-3 days
**Paywall**: Free = No broadcast, Premium = Yes

### 3.4 Audit Logs
**What**: Track all user actions for compliance/debugging
**Implementation**:
- New `audit_logs` table: `id`, `userId`, `action`, `targetType`, `targetId`, `timestamp`, `metadata`
- Log key actions: task created/deleted, message sent/deleted, file uploaded
- Settings → Audit log viewer (filterable, searchable)
- Files: `local_database_service.dart`, new `audit_service.dart`, `settings_screen.dart`
**Effort**: 3-4 days
**Paywall**: Free = No audit logs, Premium = 30 days, Enterprise = unlimited

---

## Tier 4: Medium-Value, High-Effort

### 4.1 Workflow Automation
**What**: If-then rules (e.g., "If task status = Completed, send message to client")
**Implementation**:
- New `workflows` table: `id`, `trigger`, `condition`, `action`, `enabled`
- Workflow engine listens to events (task status change, message received)
- UI: Workflow builder (trigger → condition → action picker)
- Files: New `workflow_service.dart`, `workflow_builder_screen.dart`, `local_database_service.dart`
**Effort**: 7-10 days
**Paywall**: Free = No workflows, Premium = 5 workflows, Enterprise = unlimited

### 4.2 Role-Based Permissions
**What**: Define roles (Admin, Manager, Member) with granular permissions
**Implementation**:
- New `roles` table: `id`, `name`, `permissions` (JSON array)
- New `user_roles` table: `userId`, `roleId`
- Permission checks throughout app (can delete task, can export, etc.)
- Settings → Role management UI
- Files: `local_database_service.dart`, new `permission_service.dart`, `settings_screen.dart`
**Effort**: 5-7 days
**Paywall**: Free = No roles (all same), Premium = Custom roles

### 4.3 Two-Factor Authentication (2FA)
**What**: Require second factor (SMS/email code) on login
**Implementation**:
- Integrate with Firebase Authentication phone/email verification
- Settings → Enable 2FA → Setup flow
- Login flow → If 2FA enabled, show code entry screen
- Files: `login_screen.dart`, new `two_factor_screen.dart`, `auth_service.dart`
**Effort**: 3-4 days
**Paywall**: Free = No 2FA, Premium = Yes

### 4.4 SSO (Google/Microsoft)
**What**: Single sign-on with Google Workspace or Microsoft Azure AD
**Implementation**:
- Integrate `google_sign_in` and `msal_auth` packages
- Settings → SSO configuration (domain, client ID)
- Login screen → SSO button → OAuth flow
- Files: `login_screen.dart`, `auth_service.dart`, add packages to `pubspec.yaml`
**Effort**: 4-5 days
**Paywall**: Free = No SSO, Premium = Yes

---

## Tier 5: Nice-to-Have, High-Effort

### 5.1 Voice/Video Call Integration
**What**: Initiate WhatsApp/Zoom calls from task chat
**Implementation**:
- Task detail → "Call" button → Open WhatsApp/Zoom with pre-filled message
- Or integrate Twilio/ Agora SDK for in-app calls
- Files: `task_detail_screen.dart`, new `call_service.dart`
**Effort**: 5-7 days (deep link), 15-20 days (in-app)
**Paywall**: Free = No calls, Premium = Deep links only

### 5.2 Webhook Integrations
**What**: Send/receive webhooks to external services (Slack, Zapier)
**Implementation**:
- New `webhooks` table: `id`, `url`, `events`, `secret`
- Webhook sender service (POST on events)
- Settings → Webhook management UI
- Files: `local_database_service.dart`, new `webhook_service.dart`, `settings_screen.dart`
**Effort**: 4-5 days
**Paywall**: Free = No webhooks, Premium = Yes

### 5.3 API Access
**What**: REST API for third-party integrations
**Implementation**:
- Cloud Functions HTTP endpoints (GET/POST tasks, messages)
- API key generation in Settings
- API documentation (Swagger/OpenAPI)
- Files: `functions/index.js`, new `api_keys_screen.dart`
**Effort**: 7-10 days
**Paywall**: Free = No API, Premium = Read-only, Enterprise = Read/Write

### 5.4 Custom Branding
**What**: White-label with custom logo, colors
**Implementation**:
- Settings → Branding → Upload logo, pick colors
- Store in user profile, apply throughout app
- Files: `settings_screen.dart`, theme service, all screens (theme-aware)
**Effort**: 5-7 days
**Paywall**: Free = No branding, Premium = Yes

---

## Implementation Priority Recommendation

**Phase 1 (Month 1)**: Tier 1 features (quick wins, immediate value)
- Message scheduling, templates, storage tiers, larger uploads
- **Total effort**: 4-6 days

**Phase 2 (Month 2)**: Tier 2 high-value features
- Recurring tasks, advanced search, custom fields
- **Total effort**: 10-13 days

**Phase 3 (Month 3)**: Tier 2 + Tier 3
- Advanced reporting, auto-assign, task dependencies
- **Total effort**: 12-15 days

**Phase 4 (Month 4+)**: Tier 4 + Tier 5
- Workflows, roles, 2FA, SSO, webhooks
- **Total effort**: 25-35 days

---

## Technical Considerations

**Database Migrations**: Most features require new SQLite tables → bump DB version, add migration logic in `local_database_service.dart`

**Background Services**: Scheduling, recurrence, workflows need background execution → use `workmanager` or `android_alarm_manager` packages

**UI Consistency**: All paywall-gated features should show upgrade prompt (use existing `showPaywallDialog`) when limit reached

**Testing**: Each feature needs unit tests (services) + widget tests (UI) + integration tests (end-to-end)

**Performance**: Full-text search, audit logs, reports → ensure queries are indexed, avoid N+1 problems
