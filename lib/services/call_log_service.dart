import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/helpers.dart';

/// Represents a contact identified as a favorite/starred contact.
class CallLogContact {
  final String name;
  final String? phone;
  final String? uid;
  final bool isOnApp;
  final int callCount;

  CallLogContact({
    required this.name,
    this.phone,
    this.uid,
    this.isOnApp = false,
    this.callCount = 0,
  });
}

/// Service that reads starred (favorite) contacts from the phonebook.
/// Used for onboarding: generates draft task suggestions for new users.
class CallLogService {
  static final CallLogService _instance = CallLogService._internal();
  factory CallLogService() => _instance;
  CallLogService._internal();

  /// Returns the user's starred (favorite) contacts, up to [limit].
  /// Uses only READ_CONTACTS permission (already required by the app).
  Future<List<CallLogContact>> getTopContacts({
    int limit = 5,
    int days = 90, // unused, kept for API compatibility
  }) async {
    try {
      final hasPerms = await Permission.contacts.status.isGranted;
      if (!hasPerms) {
        final result = await Permission.contacts.request();
        if (!result.isGranted) return [];
      }

      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      // Filter to starred/favorite contacts
      final starred = contacts.where((c) => c.isStarred).toList();

      if (starred.isEmpty) {
        print('No starred contacts found');
        return [];
      }

      // Cross-reference against Firebase users via ContactPickerService cache
      final results = <CallLogContact>[];
      final taken = starred.take(limit);

      for (final contact in taken) {
        final phone = contact.phones.isNotEmpty
            ? contact.phones.first.number
            : null;
        final normalized = phone != null
            ? Helpers.normalizePhone(phone)
            : null;

        results.add(CallLogContact(
          name: contact.displayName.isNotEmpty
              ? contact.displayName
              : (phone ?? 'Unknown'),
          phone: normalized ?? phone,
          uid: null,
          isOnApp: false,
          callCount: 0,
        ));
      }

      print('Found ${results.length} starred contacts for onboarding');
      return results;
    } catch (e) {
      print('Error reading starred contacts: $e');
      return [];
    }
  }
}
