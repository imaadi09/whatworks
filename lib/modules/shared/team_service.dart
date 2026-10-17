import '../../services/local_database_service.dart';
import '../../utils/helpers.dart';
import 'team_model.dart';

/// Local (SQLite-only) team CRUD for a single module.
///
/// Teams are PERSONAL (creator-owned). Queries filter on `createdBy == uid`
/// only — a member added by someone else never sees that person's team. The
/// parameterized [tableName] lets one implementation serve `task_teams`,
/// `sales_teams` and `crm_teams`.
///
/// Teams never touch Firestore: they only organize the creator's own view,
/// so local storage is the single source of truth (matches the app's
/// local-first philosophy). Cards carry the stamped `teamId` and sync as
/// usual — placement on other devices is recomputed from that user's own
/// local teams.
class TeamService {
  final String tableName; // SQLite table (e.g. 'task_teams')
  final String logTag;

  TeamService({
    @Deprecated('Teams are local-only; collectionName is ignored')
    String? collectionName,
    required this.tableName,
    this.logTag = 'TeamService',
  });

  // ── CRUD (SQLite) ────────────────────────────────────────────────────────

  Future<String> createTeam(TeamModel team) async {
    final teamId = team.id.isNotEmpty ? team.id : Helpers.generateId();
    final teamWithId = team.copyWith(id: teamId);
    await _saveTeamsToLocal([teamWithId]);
    return teamId;
  }

  /// Teams for the user — local read (kept for API compatibility).
  Future<List<TeamModel>> getTeams(String userId) => getTeamsFromLocal(userId);

  /// Apply partial updates (e.g. `{'name': ...}`) to a local team.
  Future<void> updateTeam(String id, Map<String, dynamic> data) async {
    final existing = await getModuleTeamById(id);
    if (existing == null) return;
    var updated = existing;
    if (data['name'] is String) {
      updated = updated.copyWith(name: data['name'] as String);
    }
    if (data['members'] is List<String>) {
      updated = updated.copyWith(members: data['members'] as List<String>);
    }
    await _saveTeamsToLocal([updated.copyWith(updatedAt: DateTime.now())]);
  }

  Future<void> deleteTeam(String id) async {
    await LocalDatabaseService().deleteModuleTeam(id, tableName: tableName);
  }

  /// Add a member UID to a team (creator-only in the UI).
  Future<void> addTeamMember(String teamId, String uid) async {
    final team = await getModuleTeamById(teamId);
    if (team == null || team.members.contains(uid)) return;
    await _saveTeamsToLocal([
      team.copyWith(members: [...team.members, uid], updatedAt: DateTime.now()),
    ]);
  }

  /// Remove a member UID from a team (creator-only in the UI).
  Future<void> removeTeamMember(String teamId, String uid) async {
    final team = await getModuleTeamById(teamId);
    if (team == null || !team.members.contains(uid)) return;
    await _saveTeamsToLocal([
      team.copyWith(
        members: team.members.where((m) => m != uid).toList(),
        updatedAt: DateTime.now(),
      ),
    ]);
  }

  // ── Local reads ──────────────────────────────────────────────────────────

  Future<List<TeamModel>> getTeamsFromLocal(String userId) async {
    try {
      return await LocalDatabaseService().getModuleTeams(
        userId,
        tableName: tableName,
      );
    } catch (e) {
      print('[$logTag] Failed to get teams from local DB: $e');
      return [];
    }
  }

  /// Fetch one team by id regardless of creator (teams are local rows).
  Future<TeamModel?> getModuleTeamById(String id) async {
    try {
      final db = await LocalDatabaseService().database;
      final rows = await db.query(
        tableName,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return LocalDatabaseService().teamFromRow(rows.first);
    } catch (e) {
      print('[$logTag] Failed to read team $id from local DB: $e');
      return null;
    }
  }

  Future<void> _saveTeamsToLocal(List<TeamModel> teams) async {
    if (teams.isEmpty) return;
    try {
      await LocalDatabaseService().saveModuleTeams(teams, tableName: tableName);
    } catch (e) {
      print('[$logTag] Failed to save teams to local DB: $e');
    }
  }

  /// Save a single team locally after an optimistic member edit.
  Future<void> saveTeamLocal(TeamModel team) => _saveTeamsToLocal([team]);
}
