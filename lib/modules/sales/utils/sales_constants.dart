import 'package:flutter/material.dart';
import '../models/enquiry.dart';

/// Sales module primary theme color.
const Color salesThemeColor = Color(0xFF1971C2); // Blue

/// Default sales pipeline milestones (configurable later via settings).
const List<String> defaultSalesMilestoneTitles = [
  'Initial Contact',
  'Needs Assessment',
  'Follow-up Sent',
  'Demo/Presentation',
  'Proposal Sent',
  'Negotiation',
  'Closing',
  'Payment Received',
  'Delivered / Handed Over',
];

/// Build default MilestoneModel list from titles.
List<MilestoneModel> buildDefaultMilestones() {
  return defaultSalesMilestoneTitles.asMap().entries.map((entry) {
    return MilestoneModel(
      id: 'milestone_${entry.key}',
      title: entry.value,
      order: entry.key,
    );
  }).toList();
}

/// Sales status colors.
Color salesStatusColor(String status) {
  switch (status) {
    case SalesStatus.active:
      return const Color(0xFF1971C2); // Blue
    case SalesStatus.quotation:
      return const Color(0xFF0C8599); // Teal
    case SalesStatus.demo:
      return const Color(0xFFAE3EC9); // Grape
    case SalesStatus.negotiation:
      return const Color(0xFFF08C00); // Amber
    case SalesStatus.success:
      return const Color(0xFF2F9E44); // Green
    case SalesStatus.lost:
      return const Color(0xFFE03131); // Red
    case SalesStatus.dropped:
      return const Color(0xFF868E96); // Grey
    case SalesStatus.cancel:
      return const Color(0xFF495057); // Dark grey
    default:
      return const Color(0xFF1971C2); // Default blue
  }
}
