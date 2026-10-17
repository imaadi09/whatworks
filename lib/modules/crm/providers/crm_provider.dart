import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../services/crm_service.dart';

/// Provider for the CRM module.
/// Extends BaseModuleProvider with CRM-specific configuration.
/// All state management, filtering, pagination, teams, messages, and CRUD
/// are handled by BaseModuleProvider using the CRM ModuleConfig.
class CrmProvider extends BaseModuleProvider {
  CrmProvider() : super(service: CrmService(), config: ModuleConfig.crm);
}
