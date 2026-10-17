import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/organization.dart';
import '../../models/org_member.dart';
import '../../providers/auth_provider.dart';
import '../../providers/organization_provider.dart';
import '../../utils/constants.dart';

/// Workspace screen reachable from Settings.
///
/// A workspace is a billing-free membership group: members join by code and
/// admins can remove members. Premium is a per-user plan and is never
/// derived from workspace membership.
class OrganizationScreen extends StatefulWidget {
  const OrganizationScreen({super.key});

  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  final TextEditingController _joinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
  }

  void _maybeLoad() {
    final auth = context.read<AuthProvider>();
    final orgId = auth.userModel?.orgId;
    final uid = auth.userModel?.uid;
    if (orgId != null && orgId.isNotEmpty && uid != null) {
      context.read<OrganizationProvider>().load(orgId, uid);
    }
  }

  @override
  void dispose() {
    _joinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orgProvider = context.watch<OrganizationProvider>();
    final auth = context.watch<AuthProvider>();
    final hasOrgId = (auth.userModel?.orgId ?? '').isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Workspace'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: !hasOrgId
          ? _buildJoinView(orgProvider, auth)
          : orgProvider.isLoading && orgProvider.organization == null
          ? const Center(child: CircularProgressIndicator())
          : orgProvider.organization == null
          ? _buildUnavailableView()
          : _buildOrgView(orgProvider, auth),
    );
  }

  // ── No-workspace: join panel ──────────────────────────────────────────

  Widget _buildJoinView(OrganizationProvider orgProvider, AuthProvider auth) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.groups_outlined, color: AppTheme.headerGreen),
                  SizedBox(width: 10),
                  Text(
                    'Join a workspace',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the workspace code shared by your teammate to join.',
                style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _joinController,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Workspace code',
                  hintText: 'e.g. ACME-7X2K',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                ),
              ),
              if (orgProvider.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  orgProvider.errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: orgProvider.isBusy
                      ? null
                      : () => _onJoin(orgProvider, auth),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: orgProvider.isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.login),
                  label: Text(orgProvider.isBusy ? 'Joining…' : 'Join'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _onJoin(
    OrganizationProvider orgProvider,
    AuthProvider auth,
  ) async {
    final code = _joinController.text.trim();
    if (code.isEmpty) return;
    final uid = auth.userModel?.uid ?? '';
    FocusScope.of(context).unfocus();
    final orgId = await orgProvider.join(code, uid);
    if (!mounted) return;
    if (orgId != null) {
      await auth.reloadOrgContext();
      if (!mounted) return;
      _joinController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Joined workspace successfully.'),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orgProvider.errorMessage ?? 'Could not join.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildUnavailableView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          child: Column(
            children: const [
              Icon(Icons.info_outline, color: AppTheme.secondaryText, size: 32),
              SizedBox(height: 12),
              Text(
                'Workspace details are unavailable right now. '
                'Please check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Has-workspace: full view ───────────────────────────────────────────

  Widget _buildOrgView(OrganizationProvider orgProvider, AuthProvider auth) {
    final org = orgProvider.organization!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildHeaderCard(org),
        const SizedBox(height: 12),
        _buildCodesCard(org),
        const SizedBox(height: 12),
        _buildMembersCard(orgProvider, auth),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildHeaderCard(OrganizationModel org) {
    return _card(
      child: Row(
        children: [
          const Icon(
            Icons.groups_outlined,
            color: AppTheme.headerGreen,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              org.name.isEmpty ? 'Workspace' : org.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodesCard(OrganizationModel org) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.qr_code_2, 'Join code'),
          const SizedBox(height: 4),
          const Text(
            'Share the workspace code so teammates can join.',
            style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
          ),
          const SizedBox(height: 12),
          _copyRow('Workspace code', org.orgCode),
        ],
      ),
    );
  }

  Widget _copyRow(String label, String value) {
    final display = value.isEmpty ? '—' : value;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.lightGrey,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  display,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          if (value.isNotEmpty)
            IconButton(
              icon: const Icon(
                Icons.copy,
                size: 18,
                color: AppTheme.headerGreen,
              ),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$label copied'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMembersCard(
    OrganizationProvider orgProvider,
    AuthProvider auth,
  ) {
    final members = orgProvider.members;
    final isAdmin = orgProvider.isAdmin;
    final myUid = auth.userModel?.uid;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.people_outline, 'Members (${members.length})'),
          const SizedBox(height: 4),
          if (members.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No members yet.',
                style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
              ),
            )
          else
            ...members.map(
              (m) => _memberTile(m, isAdmin, myUid, orgProvider, auth),
            ),
        ],
      ),
    );
  }

  Widget _memberTile(
    OrgMemberModel m,
    bool isAdmin,
    String? myUid,
    OrganizationProvider orgProvider,
    AuthProvider auth,
  ) {
    final canRemove = isAdmin && m.role != 'owner' && m.isActiveSeat;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppTheme.lightGrey,
            child: Text(
              (m.displayName.isNotEmpty ? m.displayName[0] : '?').toUpperCase(),
              style: const TextStyle(
                color: AppTheme.headerGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.displayName.isEmpty ? m.phone : m.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                ),
                const SizedBox(height: 2),
                _rolePill(m.role),
              ],
            ),
          ),
          if (canRemove)
            TextButton(
              onPressed: orgProvider.isBusy
                  ? null
                  : () => _onRemove(m, orgProvider, auth),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Remove'),
            ),
        ],
      ),
    );
  }

  Future<void> _onRemove(
    OrgMemberModel m,
    OrganizationProvider orgProvider,
    AuthProvider auth,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member'),
        content: Text(
          'Remove ${m.displayName.isEmpty ? m.phone : m.displayName} from the '
          'workspace?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await orgProvider.revoke(m.uid);
    if (!mounted) return;
    if (ok) {
      // If the admin removed themselves, refresh their workspace context.
      if (m.uid == auth.userModel?.uid) {
        await auth.reloadOrgContext();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Member removed.')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orgProvider.errorMessage ?? 'Could not remove member.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ── Small shared bits ───────────────────────────────────────────────────

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _cardTitle(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.headerGreen, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.primaryText,
          ),
        ),
      ],
    );
  }

  Widget _rolePill(String role) =>
      _pill(role.isEmpty ? 'member' : role, AppTheme.headerGreen);

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
