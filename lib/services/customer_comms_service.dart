import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../modules/shared/customer_info.dart';
import '../utils/helpers.dart';

/// Persists an action as a system message in the item's timeline.
///
/// Each module supplies its own recorder (Task → `_sendSystemMessage`,
/// Sales/CRM → `_dispatchActionMessage`), so the message TEXT stays
/// single-sourced here while persistence flows through the module's own path.
typedef CustomerActionRecorder = Future<void> Function(String text);

/// Single engine for customer communication actions shared by Task, Sales and
/// CRM. Centralises launch + system-message formatting + save-to-contacts so
/// every module records byte-identical text (which the action parsers in
/// `Helpers.detectActionType` and the ACTION-TYPE CHECKLIST rely on).
///
/// Recording policy (product decision):
/// - **Call** (📞) and **WhatsApp** (💬) are recorded timeline actions, exactly
///   like Follow-up. Call reuses the app's pre-existing message format so
///   historical messages keep matching; WhatsApp is a new informational action.
/// - **Copy number** and **Save to contacts** are silent (snackbar only).
///
/// Usage from any screen:
/// ```dart
/// CustomerCommsService.instance.whatsapp(context, item.customerInfo,
///     record: (t) => _sendSystemMessage(t), byName: _currentUserName);
/// ```
class CustomerCommsService {
  CustomerCommsService._();
  static final CustomerCommsService instance = CustomerCommsService._();

  /// Emoji prefixes — kept here so the format and the parser agree. These match
  /// `Helpers.detectActionType` ('📞' → call, '💬' → whatsapp).
  static const String callEmoji = '📞';
  static const String whatsappEmoji = '💬';

  /// "📞 Call made to …" — the EXACT format already used by task_detail_screen
  /// and sales_detail_screen, so old and new messages parse identically.
  String callText(CustomerInfo c, String byName) =>
      '$callEmoji Call made to ${c.name} (${c.phone}) by $byName '
      'at ${Helpers.formatDateTime(DateTime.now())}';

  /// "💬 WhatsApp message to …" — new informational action, mirrors the Call
  /// format so it reads consistently in the timeline.
  String whatsappText(CustomerInfo c, String byName) =>
      '$whatsappEmoji WhatsApp message to ${c.name} (${c.phone}) by $byName '
      'at ${Helpers.formatDateTime(DateTime.now())}';

  /// Launch the dialer (user picks their calling app); on success record a
  /// "📞 Call made" action. Mirrors the existing `_placeCall` behaviour.
  Future<void> call(
    BuildContext context,
    CustomerInfo c, {
    required CustomerActionRecorder record,
    required String byName,
  }) async {
    if (!c.hasPhone) {
      _snack(context, 'No phone number to call', error: true);
      return;
    }
    final uri = Uri.parse('tel:${c.phone}');
    var launched = false;
    try {
      launched = await launchUrl(uri);
    } catch (_) {
      launched = false;
    }
    if (launched) {
      await record(callText(c, byName));
    } else if (context.mounted) {
      _snack(context, 'Could not open the dialer', error: true);
    }
  }

  /// Launch WhatsApp (wa.me) for the customer's number; on success record a
  /// "💬 WhatsApp message" action.
  Future<void> whatsapp(
    BuildContext context,
    CustomerInfo c, {
    required CustomerActionRecorder record,
    required String byName,
  }) async {
    if (!c.hasPhone) {
      _snack(context, 'No phone number for WhatsApp', error: true);
      return;
    }
    final normalized = Helpers.normalizePhone(c.phone) ?? c.phone;
    final uri = Uri.parse('https://wa.me/$normalized');
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (launched) {
      await record(whatsappText(c, byName));
    } else if (context.mounted) {
      _snack(context, 'Could not open WhatsApp', error: true);
    }
  }

  /// Copy the customer's number to the clipboard (silent — not recorded).
  void copyNumber(BuildContext context, CustomerInfo c) {
    if (!c.hasPhone) {
      _snack(context, 'No phone number to copy', error: true);
      return;
    }
    Clipboard.setData(ClipboardData(text: c.phone));
    _snack(context, 'Number copied');
  }

  /// Save the customer to the device address book (silent — not recorded).
  /// Requests the contacts permission first; opens app settings when the
  /// permission is permanently denied so the user can recover.
  Future<void> saveToContacts(BuildContext context, CustomerInfo c) async {
    if (c.isEmpty) {
      _snack(context, 'No customer details to save', error: true);
      return;
    }
    final granted = await _ensureContactsPermission(context);
    if (!granted) return;
    try {
      final trimmed = c.name.trim();
      final parts = trimmed.isEmpty ? const <String>[] : trimmed.split(
        RegExp(r'\s+'),
      );
      final first = parts.isNotEmpty ? parts.first : '';
      final last = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      final displayName = c.hasName
          ? c.name
          : (c.hasPhone ? c.phone : 'Customer');
      final contact = Contact(
        displayName: displayName,
        name: Name(first: first, last: last),
        phones: c.hasPhone ? [Phone(c.phone)] : [],
        emails: c.hasEmail ? [Email(c.email)] : [],
        organizations: c.hasCompany ? [Organization(company: c.company)] : [],
        addresses: c.hasAddress ? [Address(c.address)] : [],
      );
      await contact.insert();
      if (context.mounted) {
        _snack(context, 'Saved to contacts');
      }
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not save the contact', error: true);
      }
    }
  }

  /// Ensure the contacts permission is granted, requesting it if needed.
  Future<bool> _ensureContactsPermission(BuildContext context) async {
    var status = await Permission.contacts.status;
    if (!status.isGranted) {
      status = await Permission.contacts.request();
    }
    if (status.isGranted) return true;
    if (context.mounted) {
      _snack(context, 'Contacts permission denied', error: true);
    }
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }

  void _snack(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }
}
