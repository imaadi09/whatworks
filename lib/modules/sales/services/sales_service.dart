import '../../shared/base_module_service.dart';

/// Firestore CRUD for sales enquiries and sales teams.
/// Extends BaseModuleService with sales-specific collection names.
class SalesService extends BaseModuleService {
  static final SalesService _instance = SalesService._internal();
  factory SalesService() => _instance;

  SalesService._internal()
    : super(
        collectionName: 'sales_enquiries',
        teamsCollectionName: 'sales_teams',
        logTag: 'SalesService',
        enquiriesTableName: 'enquiries',
        teamsTableName: 'sales_teams',
      );
}
