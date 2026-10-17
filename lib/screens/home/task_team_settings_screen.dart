import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../modules/shared/team_members_sheet.dart';
import '../../modules/shared/team_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../utils/constants.dart';
import '../../utils/paywall_constants.dart';

/// Screen for managing task teams: create, rename, delete + members.
/// Port of the sales team settings screen with the task theme color.
class TaskTeamSettingsScreen extends StatefulWidget {
  const TaskTeamSettingsScreen({super.key});

  @override
  State<TaskTeamSettingsScreen> createState() => _TaskTeamSettingsScreenState();
}

class _TaskTeamSettingsScreenState extends State<TaskTeamSettingsScreen> {
  final Color _themeColor = AppTheme.primaryGreen;
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    final auth = context.watch<AuthProvider>();
    final planType = auth.effectivePlanTypeFor('task');
    final maxTeams = PaywallLimits.maxTeams(planType);
    final canMultiTeam = maxTeams > 1;
    final teams = provider.teams;
    final currentTeamId = provider.currentTeamId;
    final canCreateMore = teams.length < maxTeams;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'WorkTracker Teams',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Info banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _themeColor.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _themeColor.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: _themeColor, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          canMultiTeam
                              ? 'Create up to $maxTeams teams to organize your task cards. '
                                    'Add contacts as members in a team. '
                                    'A team can only be deleted after all its tasks are removed.'
                              : 'Your ${PaywallLimits.planLabel(planType)} plan allows 1 team. '
                                    'Upgrade for multiple teams and members. '
                                    'A team can only be deleted after all its tasks are removed.',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Team list
                Expanded(
                  child: teams.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.group_work_outlined,
                                size: 64,
                                color: AppTheme.lightText.withOpacity(0.4),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'No teams yet',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppTheme.secondaryText,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Tap + to create your first team',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.lightText,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          itemCount: teams.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final team = teams[index];
                            final isCurrent = team.id == currentTeamId;
                            return _buildTeamTile(team, isCurrent, provider);
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (canCreateMore) {
            _showCreateTeamDialog(provider);
          } else {
            showPaywallDialog(
              context,
              feature: 'Create multiple teams to organize your task cards.',
              detail: 'Premium unlocks up to ${PaywallLimits.maxTeams('premium')} teams per module.',
            );
          }
        },
        backgroundColor: _themeColor,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildTeamTile(TeamModel team, bool isCurrent, TaskProvider provider) {
    return Container(
      decoration: BoxDecoration(
        color: isCurrent ? _themeColor.withOpacity(0.05) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCurrent ? _themeColor.withOpacity(0.3) : AppTheme.lightGrey,
          width: 1,
        ),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: _themeColor.withOpacity(0.15),
          child: Text(
            _getTeamInitials(team.name),
            style: TextStyle(
              color: _themeColor,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        title: Text(
          team.name,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: AppTheme.primaryText,
          ),
        ),
        subtitle: Text(
          isCurrent
              ? 'Active team · ${team.members.length} member${team.members.length == 1 ? '' : 's'}'
              : '${team.members.length} member${team.members.length == 1 ? '' : 's'}',
          style: TextStyle(
            fontSize: 12,
            color: isCurrent ? _themeColor : AppTheme.lightText,
            fontWeight: isCurrent ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
        onTap: () => _showMembersSheet(team, provider),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Members button
            IconButton(
              icon: Icon(Icons.group_outlined, size: 20, color: _themeColor),
              onPressed: () => _showMembersSheet(team, provider),
              tooltip: 'Members',
            ),
            // Rename button
            IconButton(
              icon: const Icon(
                Icons.edit_outlined,
                size: 20,
                color: AppTheme.secondaryText,
              ),
              onPressed: () => _showRenameDialog(team, provider),
              tooltip: 'Rename',
            ),
            // Delete button
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 20,
                color: Colors.red,
              ),
              onPressed: () => _confirmDeleteTeam(team, provider),
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }

  void _showMembersSheet(TeamModel team, TaskProvider provider) {
    TeamMembersSheet.show(
      context,
      team: team,
      themeColor: _themeColor,
      onAdd: (uid) => provider.addTeamMember(team.id, uid),
      onRemove: (uid) => provider.removeTeamMember(team.id, uid),
    );
  }

  String _getTeamInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.length >= 2
        ? name.substring(0, 2).toUpperCase()
        : name.toUpperCase();
  }

  void _showCreateTeamDialog(TaskProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Team'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: InputDecoration(
            hintText: 'Enter team name',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);

              final auth = context.read<AuthProvider>();
              final userId = auth.userModel?.uid ?? '';
              final planType = auth.effectivePlanTypeFor('task');
              await provider.createTeam(name, userId, planType: planType);

              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Team "$name" created')));
              }
            },
            style: TextButton.styleFrom(foregroundColor: _themeColor),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(TeamModel team, TaskProvider provider) {
    final controller = TextEditingController(text: team.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Team'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: InputDecoration(
            hintText: 'Enter new name',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isEmpty || newName == team.name) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx);
              await provider.renameTeam(team.id, newName);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Team renamed to "$newName"')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: _themeColor),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteTeam(TeamModel team, TaskProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Team'),
        content: Text(
          'Are you sure you want to delete "${team.name}"?\n\n'
          'A team can only be deleted if it has no tasks remaining.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _isLoading = true);

              final success = await provider.deleteTeam(team.id);

              setState(() => _isLoading = false);

              if (mounted) {
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Team "${team.name}" deleted')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Cannot delete: team still has tasks. Delete all tasks first.',
                      ),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
