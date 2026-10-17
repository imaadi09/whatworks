import 'package:flutter/material.dart';
import '../../shared/module_config.dart';

/// CRM module primary theme color.
const Color crmThemeColor = Color(0xFF0C8599); // Teal

/// CRM ticket statuses.
enum CrmStatus { open, inProgress, resolved, closed, escalated }

/// Default CRM milestones (field-service complaint pipeline).
const List<String> defaultCrmMilestoneTitles = [
  'Ticket',
  'Visited',
  'Estimate',
  'Repaired',
  'Closed',
];

/// CRM status colors.
Color crmStatusColor(String statusName) {
  return ModuleConfig.crm.statusColorFor(statusName);
}

/// Get CRM status label from name.
String crmStatusLabel(String statusName) {
  return ModuleConfig.crm.statusLabelFor(statusName);
}
