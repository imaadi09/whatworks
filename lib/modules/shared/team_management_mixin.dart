import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/local_database_service.dart';
import '../../utils/paywall_constants.dart';
import 'team_model.dart';
import 'team_service.dart';

/// Shared team state management for every module (Tasks, Sales, CRM).
///
/// Teams are PERSONAL (creator-owned) and SQLite-only — they never touch
/// Firestore. This mixin owns the in-memory team list, the currently
/// selected team and its SharedPreferences persistence, and delegates row
/// CRUD to the module's [TeamService] (parameterized by table name:
/// `task_teams` / `sales_teams` / `crm_teams`).
///
/// The host provider supplies the module-specific hooks:
///   * [teamService]     — SQLite CRUD for this module's team table.
///   * [teamPrefKey]     — SharedPreferences key for the selected team.
///   * [cardCountInTeam] — deletion guard: cards still placed in the team.
///   * [onTeamSwitched]  — reload cards after the active team changes.
///   * [reportTeamError] — surface errors (default: print).
mixin TeamManagementMixin on ChangeNotifier {
  // ── Host hooks ───────────────────────────────────────────────────────────

  TeamService get teamService;
  String get teamPrefKey;

  /// Number of cards currently placed in [teamId]; > 0 blocks deletion.
  Future<int> cardCountInTeam(String teamId);

  /// Called after the active team changes so the host reloads its cards.
  void onTeamSwitched();

  /// Error surfacing — sales/CRM set their errorMessage, tasks just log.
  void reportTeamError(String message) => print('[Teams] $message');

  // ── State ────────────────────────────────────────────────────────────────

  List<TeamModel> _teams = [];
  String? _currentTeamId;
  String? _currentTeamName;
  bool _teamsLoaded = false;
  bool _defaultTeamEnsured = false;
  String? _teamsUserId; // uid the team state belongs to (account-switch guard)
  bool _isCreatingTeam = false;
  StreamSubscription<TableChange>? _teamsTableSub;

  List<TeamModel> get teams => _teams;
  String? get currentTeamId => _currentTeamId;
  String? get currentTeamName => _currentTeamName;
  bool get teamsLoaded => _teamsLoaded;

  /// The default "My Team" id, falling back to the first team, else empty.
  String get defaultTeamId {
    if (_teams.isEmpty) return '';
    for (final t in _teams) {
      if (t.isDefault) return t.id;
    }
    return _teams.first.id;
  }

  // ── Loading / selection ──────────────────────────────────────────────────

  /// Load teams — SQLite only. Teams are local-only (no Firestore sync).
  Future<void> loadTeams(String userId) async {
    try {
      _teamsTableSub?.cancel();

      // Account switch: drop the previous user's team state and re-arm the
      // default-team latch so the new account gets a fresh "My Team".
      if (_teamsUserId != null && _teamsUserId != userId) {
        _teams = [];
        _currentTeamId = null;
        _currentTeamName = null;
        _defaultTeamEnsured = false;
      }
      _teamsUserId = userId;

      _teams = await teamService.getTeamsFromLocal(userId);
      _teamsLoaded = true;
      await _restoreSelectedTeam();
      notifyListeners();

      // Listen for SQLite changes
      _teamsTableSub = LocalDatabaseService().tableChanges2
          .where((c) => c.table == teamService.tableName)
          .listen((_) async {
            _teams = await teamService.getTeamsFromLocal(userId);
            _teamsLoaded = true;
            await _restoreSelectedTeam();
            notifyListeners();
          });
    } catch (e) {
      reportTeamError('Failed to load teams: $e');
    }
  }

  /// Restore the last selected team from SharedPreferences.
  Future<void> _restoreSelectedTeam() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTeamId = prefs.getString(teamPrefKey);

    if (savedTeamId != null && _teams.any((t) => t.id == savedTeamId)) {
      final team = _teams.firstWhere((t) => t.id == savedTeamId);
      _currentTeamId = team.id;
      _currentTeamName = team.name;
    } else if (_teams.isNotEmpty) {
      _currentTeamId = defaultTeamId;
      final team = _teams.firstWhere((t) => t.id == _currentTeamId);
      _currentTeamName = team.name;
      await prefs.setString(teamPrefKey, _currentTeamId!);
    } else {
      _currentTeamId = null;
      _currentTeamName = null;
    }
  }

  /// Ensure a default "My Team" exists (created locally if missing).
  Future<void> ensureDefaultTeam(
    String userId, {
    String planType = 'basic',
  }) async {
    if (_defaultTeamEnsured) return;
    _defaultTeamEnsured = true;
    if (_teams.isEmpty) {
      await loadTeams(userId);
    }
    if (_teams.isEmpty) {
      await createTeam('My Team', userId, planType: planType);
    }
  }

  // ── CRUD ─────────────────────────────────────────────────────────────────

  /// Create a team (gated by [PaywallLimits.maxTeams]).
  Future<String?> createTeam(
    String name,
    String userId, {
    String planType = 'basic',
  }) async {
    if (_isCreatingTeam) return null;
    _isCreatingTeam = true;
    try {
      final maxTeams = PaywallLimits.maxTeams(planType);
      if (_teams.length >= maxTeams) {
        final higherCap = PaywallLimits.maxTeams('enterprise');
        reportTeamError(
          higherCap > maxTeams
              ? 'Team limit reached on ${PaywallLimits.planLabel(planType)} plan. Upgrade to create up to $higherCap teams.'
              : 'Team limit reached. This is the maximum number of teams on all plans.',
        );
        return null;
      }

      final now = DateTime.now();
      final team = TeamModel(
        id: '',
        name: name,
        createdBy: userId,
        createdAt: now,
        updatedAt: now,
      );
      final teamId = await teamService.createTeam(team);
      _teams.add(team.copyWith(id: teamId));

      if (_teams.length == 1) {
        _currentTeamId = teamId;
        _currentTeamName = name;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(teamPrefKey, teamId);
      }

      notifyListeners();
      return teamId;
    } catch (e) {
      reportTeamError('Failed to create team: $e');
      return null;
    } finally {
      _isCreatingTeam = false;
    }
  }

  /// Rename a team.
  Future<void> renameTeam(String teamId, String newName) async {
    try {
      await teamService.updateTeam(teamId, {'name': newName});
      final index = _teams.indexWhere((t) => t.id == teamId);
      if (index != -1) {
        _teams[index] = _teams[index].copyWith(name: newName);
        if (_currentTeamId == teamId) {
          _currentTeamName = newName;
        }
      }
      notifyListeners();
    } catch (e) {
      reportTeamError('Failed to rename team: $e');
    }
  }

  /// Delete a team (blocked while cards are still placed in it).
  Future<bool> deleteTeam(String teamId) async {
    try {
      final count = await cardCountInTeam(teamId);
      if (count > 0) {
        reportTeamError('Delete all cards in this team first');
        return false;
      }

      await teamService.deleteTeam(teamId);
      _teams.removeWhere((t) => t.id == teamId);

      if (_currentTeamId == teamId) {
        if (_teams.isNotEmpty) {
          _currentTeamId = defaultTeamId;
          final team = _teams.firstWhere((t) => t.id == _currentTeamId);
          _currentTeamName = team.name;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(teamPrefKey, _currentTeamId!);
        } else {
          _currentTeamId = null;
          _currentTeamName = null;
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      reportTeamError('Failed to delete team: $e');
      return false;
    }
  }

  /// Switch the active team (allowed when the plan permits multiple teams).
  Future<bool> switchTeam(String teamId, {String planType = 'basic'}) async {
    if (_teams.length > 1 && PaywallLimits.maxTeams(planType) < 2) {
      reportTeamError('Upgrade your plan to switch teams');
      return false;
    }
    if (!_teams.any((t) => t.id == teamId)) return false;
    final team = _teams.firstWhere((t) => t.id == teamId);
    _currentTeamId = team.id;
    _currentTeamName = team.name;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(teamPrefKey, teamId);

    onTeamSwitched();
    return true;
  }

  /// Add a contact (UID or phone:<number> key) as a member of [teamId]
  /// (creator-only in the UI). Personal teams: the member never sees this
  /// team; it only organizes the creator's view and drives the member's
  /// viewer-side card placement.
  Future<void> addTeamMember(String teamId, String memberKey) async {
    final index = _teams.indexWhere((t) => t.id == teamId);
    if (index == -1 || memberKey.isEmpty) return;
    if (_teams[index].hasMember(memberKey)) return;
    final updated = _teams[index].copyWith(
      members: [..._teams[index].members, memberKey],
      updatedAt: DateTime.now(),
    );
    _teams[index] = updated;
    notifyListeners();
    try {
      await teamService.addTeamMember(teamId, memberKey);
    } catch (e) {
      reportTeamError('Failed to add member: $e');
    }
  }

  /// Remove a member (UID or phone:<number> key) from [teamId].
  Future<void> removeTeamMember(String teamId, String memberKey) async {
    final index = _teams.indexWhere((t) => t.id == teamId);
    if (index == -1 || memberKey.isEmpty) return;
    final updated = _teams[index].copyWith(
      members: _teams[index].members.where((m) => m != memberKey).toList(),
      updatedAt: DateTime.now(),
    );
    _teams[index] = updated;
    notifyListeners();
    try {
      await teamService.removeTeamMember(teamId, memberKey);
    } catch (e) {
      reportTeamError('Failed to remove member: $e');
    }
  }

  /// Cancel the teams-table subscription (call from the host's dispose).
  void disposeTeams() {
    _teamsTableSub?.cancel();
    _teamsTableSub = null;
  }
}
