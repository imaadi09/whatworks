import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and verifies the local app-lock PIN.
///
/// The PIN is never stored in plaintext: a random per-install salt is generated
/// and only `sha256(salt:pin)` is kept in SharedPreferences. This is a local
/// device lock (not an account credential), so SharedPreferences is adequate.
class AppLockService {
  static const String _kEnabled = 'app_lock_enabled';
  static const String _kHash = 'app_lock_pin_hash';
  static const String _kSalt = 'app_lock_pin_salt';

  /// Minimum/maximum PIN length enforced by the UI.
  static const int pinLength = 4;

  /// True only when the lock is switched on AND a PIN hash is present.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_kEnabled) ?? false) &&
        prefs.getString(_kHash) != null;
  }

  /// Store a new PIN (overwrites any existing one) and enable the lock.
  static Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = _generateSalt();
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kHash, _hash(pin, salt));
    await prefs.setBool(_kEnabled, true);
  }

  /// Constant-target comparison of the entered PIN against the stored hash.
  static Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kSalt);
    final hash = prefs.getString(_kHash);
    if (salt == null || hash == null) return false;
    return _hash(pin, salt) == hash;
  }

  /// Disable the lock and wipe the stored hash + salt.
  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    await prefs.setBool(_kEnabled, false);
  }

  static String _generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _hash(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }
}
