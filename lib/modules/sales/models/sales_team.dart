import '../../shared/team_model.dart';

export '../../shared/team_model.dart' show TeamModel;

/// Backwards-compatible alias.
///
/// The team model moved to the shared module (`team_model.dart`) so the Task,
/// Sales and CRM modules all use one implementation with an explicit `members`
/// list. Existing `SalesTeam` references continue to compile via this typedef.
typedef SalesTeam = TeamModel;
