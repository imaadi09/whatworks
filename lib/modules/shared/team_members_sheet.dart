import 'package:flutter/material.dart';
import '../../services/contact_picker_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../widgets/app_avatar.dart';
import 'team_model.dart';

/// Shared bottom sheet for managing the members of a personal team.
///
/// Teams are personal: the creator adds contacts (by UID) to organize their own
/// view. Members never see this team; the list only drives the creator's
/// grouping and each member's viewer-side card placement.
///
/// Module-agnostic — reused by the Task, Sales and CRM team settings screens.
class TeamMembersSheet extends StatefulWidget {
  final TeamModel team;
  final Color themeColor;

  /// Called with the member key to add (UID, or `phone:<normalized>` for
  /// phonebook contacts not on the app yet). The parent provider persists it.
  final Future<void> Function(String uid) onAdd;

  /// Called with the UID to remove. The parent provider persists the change.
  final Future<void> Function(String uid) onRemove;

  const TeamMembersSheet({
    super.key,
    required this.team,
    required this.themeColor,
    required this.onAdd,
    required this.onRemove,
  });

  /// Convenience launcher.
  static Future<void> show(
    BuildContext context, {
    required TeamModel team,
    required Color themeColor,
    required Future<void> Function(String uid) onAdd,
    required Future<void> Function(String uid) onRemove,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => TeamMembersSheet(
        team: team,
        themeColor: themeColor,
        onAdd: onAdd,
        onRemove: onRemove,
      ),
    );
  }

  @override
  State<TeamMembersSheet> createState() => _TeamMembersSheetState();
}

class _TeamMembersSheetState extends State<TeamMembersSheet> {
  late List<String> _members;
  List<AssignableContact> _allUsers = [];
  List<AssignableContact> _phoneContacts = [];
  bool _isLoading = true;
  Map<String, AssignableContact> _userByUid = {};
  Map<String, AssignableContact> _contactByPhone = {};

  @override
  void initState() {
    super.initState();
    _members = List.of(widget.team.members);
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      // Fetch in-app users AND the device phonebook so contacts can be
      // added even when they haven't joined the app yet.
      final results = await Future.wait([
        ContactPickerService().getTeamMembers(),
        ContactPickerService().getPhoneContacts(),
      ]);
      if (!mounted) return;
      setState(() {
        _allUsers = results[0];
        _phoneContacts = results[1];
        _userByUid = {
          for (final u in _allUsers)
            if (u.uid != null) u.uid!: u,
        };
        _contactByPhone = {
          for (final c in _phoneContacts)
            if ((Helpers.normalizePhone(c.phone) ?? '').isNotEmpty)
              Helpers.normalizePhone(c.phone)!: c,
        };
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _isPhoneKey(String key) => key.startsWith(TeamModel.phonePrefix);

  String _phoneFromKey(String key) =>
      key.substring(TeamModel.phonePrefix.length);

  String _nameFor(String uid) => _userByUid[uid]?.name ?? _shortUid(uid);

  String _displayNameFor(String key) {
    if (_isPhoneKey(key)) {
      final phone = _phoneFromKey(key);
      return _contactByPhone[phone]?.name ?? phone;
    }
    return _nameFor(key);
  }

  /// Member key for a candidate: UID when on the app, else a phone key so
  /// phonebook contacts can organize the team before they register.
  String _keyFor(AssignableContact c) {
    if (c.isOnApp && c.uid != null && c.uid!.isNotEmpty) return c.uid!;
    final norm = Helpers.normalizePhone(c.phone) ?? c.phone ?? '';
    return norm.isEmpty ? '' : '${TeamModel.phonePrefix}$norm';
  }

  String _shortUid(String uid) =>
      uid.length > 10 ? '${uid.substring(0, 6)}…' : uid;

  Future<void> _pickAndAddMember() async {
    final taken = _members.toSet();
    final seenKeys = <String>{};
    final candidates = <AssignableContact>[];

    // In-app users (added by UID)
    for (final u in _allUsers) {
      final key = _keyFor(u);
      if (key.isEmpty || taken.contains(key) || !seenKeys.add(key)) continue;
      candidates.add(u);
    }

    // Phonebook contacts: on-app matches add by UID, the rest by phone key
    for (final c in _phoneContacts) {
      final key = _keyFor(c);
      if (key.isEmpty || taken.contains(key) || !seenKeys.add(key)) continue;
      candidates.add(c);
    }

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No more contacts available to add.')),
      );
      return;
    }

    final selected = await showModalBottomSheet<AssignableContact>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.6,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.person_add_alt_1, color: widget.themeColor),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Add Team Member',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: candidates.length,
                itemBuilder: (_, i) {
                  final c = candidates[i];
                  return ListTile(
                    leading: AppAvatar(
                      avatarUrl: c.avatarUrl,
                      initials: c.name.isNotEmpty
                          ? c.name[0].toUpperCase()
                          : '?',
                      radius: 18,
                      color: widget.themeColor,
                      fontSize: 14,
                    ),
                    title: Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: c.phone != null
                        ? Text(
                            c.isOnApp ? c.phone! : '${c.phone!} · not on app',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.lightText,
                            ),
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (selected == null) return;
    final key = _keyFor(selected);
    if (key.isEmpty || (_isPhoneKey(key) && _phoneFromKey(key).isEmpty)) {
      return;
    }
    if (!mounted) return;
    setState(() => _members.add(key));
    await widget.onAdd(key);
  }

  Future<void> _removeMember(String uid) async {
    if (!mounted) return;
    setState(() => _members.remove(uid));
    await widget.onRemove(uid);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Handle + header
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 16, right: 16),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.lightGrey,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.group, color: widget.themeColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${widget.team.name} · Members',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryText,
                        ),
                      ),
                    ),
                    Text(
                      '${_members.length}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: widget.themeColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Members organize your view. They won’t see this team.',
                    style: TextStyle(fontSize: 12, color: AppTheme.lightText),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Add member button
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.themeColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.add, color: widget.themeColor, size: 20),
            ),
            title: Text(
              'Add member',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.themeColor,
              ),
            ),
            onTap: _isLoading ? null : _pickAndAddMember,
          ),
          const Divider(height: 1),
          // Members list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.secondaryText,
                    ),
                  )
                : _members.isEmpty
                ? const Center(
                    child: Text(
                      'No members yet.\nAdd contacts to organize this team.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: AppTheme.lightText),
                    ),
                  )
                : ListView.builder(
                    itemCount: _members.length,
                    itemBuilder: (_, i) {
                      final key = _members[i];
                      final isPhone = _isPhoneKey(key);
                      final contact = isPhone
                          ? _contactByPhone[_phoneFromKey(key)]
                          : _userByUid[key];
                      final name = _displayNameFor(key);
                      final phone = isPhone
                          ? _phoneFromKey(key)
                          : contact?.phone;
                      return ListTile(
                        leading: AppAvatar(
                          avatarUrl: contact?.avatarUrl,
                          initials: name.isNotEmpty
                              ? name[0].toUpperCase()
                              : '?',
                          radius: 18,
                          color: widget.themeColor,
                          fontSize: 14,
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: phone != null
                            ? Text(
                                isPhone ? '$phone · not on app' : phone,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.lightText,
                                ),
                              )
                            : null,
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                            size: 22,
                          ),
                          tooltip: 'Remove',
                          onPressed: () => _removeMember(key),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
