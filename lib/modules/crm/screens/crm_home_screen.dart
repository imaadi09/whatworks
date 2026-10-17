import 'package:flutter/material.dart';
import '../../shared/module_config.dart';
import '../../sales/screens/sales_home_screen.dart';

/// CRM home screen — thin wrapper around the shared SalesHomeScreen
/// configured with CRM module settings.
class CrmHomeScreen extends StatelessWidget {
  const CrmHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SalesHomeScreen(moduleConfig: ModuleConfig.crm);
  }
}
