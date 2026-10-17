import '../../shared/base_module_service.dart';

/// CRM module Firestore service.
/// Points to `crm_records` and `crm_teams` collections.
class CrmService extends BaseModuleService {
  static final CrmService _instance = CrmService._internal();
  factory CrmService() => _instance;

  CrmService._internal()
    : super(
        collectionName: 'crm_records',
        teamsCollectionName: 'crm_teams',
        logTag: 'CrmService',
        enquiriesTableName: 'crm_enquiries',
        teamsTableName: 'crm_teams',
      );
}
