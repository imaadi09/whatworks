import '../../shared/base_module_provider.dart';
import '../../shared/module_config.dart';
import '../services/sales_service.dart';

/// Provider for the Sales module.
/// Extends BaseModuleProvider with sales-specific configuration.
/// All state management, filtering, pagination, teams, messages, and CRUD
/// are handled by BaseModuleProvider using the sales ModuleConfig.
class SalesProvider extends BaseModuleProvider {
  SalesProvider() : super(service: SalesService(), config: ModuleConfig.sales);
}
