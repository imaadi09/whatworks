import 'package:url_launcher/url_launcher.dart';

/// Every outward-facing link the app opens, in one place, so the domain lives
/// at exactly one address instead of being retyped at each call site.
///
/// ⚠️ These pages must exist on whatworks.pro before release. A missing page
/// still counts as a SUCCESSFUL launch (the browser opens and shows a 404), so
/// nothing in the app will warn you — only opening them yourself will.
class AppLinks {
  AppLinks._();

  static const String domain = 'https://whatworks.pro';

  static const String help = '$domain/help';
  static const String privacy = '$domain/privacy';
  static const String terms = '$domain/terms';
  static const String upgrade = '$domain/upgrade';
  static const String invite = '$domain/invite';

  /// Bug reports go to a mailbox, not a web form: no backend to build or
  /// secure, and the reply lands in the same thread the user wrote from.
  static const String supportEmail = 'support@whatworks.pro';

  /// Support WhatsApp. Mail is still the right channel for a reproducible bug
  /// (diagnostics attach to it), but a chat gets a same-day answer, so the
  /// Support section offers both. wa.me wants the international number with no
  /// '+' and no separators; [supportWhatsAppDisplay] is the human-readable
  /// form shown in the UI.
  static const String supportWhatsAppPhone = '917999387646';
  static const String supportWhatsAppDisplay = '+91 7999387646';

  /// Opens [url] externally. Returns false rather than throwing — Android
  /// raises a PlatformException when no app can handle the intent, and every
  /// caller wants the same "couldn't open it" message either way.
  static Future<bool> open(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// Opens a WhatsApp chat with the support number, [message] prefilled. Shares
  /// [open]'s launch mode and its return-false-instead-of-throw contract, so a
  /// device with no WhatsApp gets the same graceful fallback as every other
  /// outward link.
  static Future<bool> openSupportWhatsApp(String message) => open(
    'https://wa.me/$supportWhatsAppPhone'
    '?text=${Uri.encodeComponent(message)}',
  );

  /// Support mail with [subject] and [body] prefilled. The query is encoded by
  /// hand because Uri's queryParameters turns spaces into "+", which several
  /// Android mail clients render literally in the subject line.
  static Future<bool> openSupportEmail({
    required String subject,
    required String body,
  }) async {
    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query:
          'subject=${Uri.encodeComponent(subject)}'
          '&body=${Uri.encodeComponent(body)}',
    );
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
