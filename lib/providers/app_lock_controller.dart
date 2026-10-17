import 'package:flutter/foundation.dart';
import '../services/app_lock_service.dart';

/// Tracks whether the app is currently locked behind the PIN gate.
///
/// - On cold start, if the lock is enabled the app begins locked.
/// - When the app is backgrounded it re-locks (checked on next resume).
/// - [unlock] is called by the lock screen after a correct PIN.
/// - [refreshEnabled] is called after the user turns the lock on/off in
///   Settings so the gate reflects the new state immediately.
class AppLockController extends ChangeNotifier {
  bool _enabled = false;
  bool _locked = false;
  bool _ready = false;

  bool get isEnabled => _enabled;

  /// True once [load] has resolved the stored enabled state. Until then the
  /// gate stays closed to avoid flashing private content on cold start.
  bool get isReady => _ready;

  /// Locked while the enabled state is still unknown, or when the lock is
  /// enabled and armed.
  bool get isLocked => !_ready || (_enabled && _locked);

  Future<void> load() async {
    _enabled = await AppLockService.isEnabled();
    _locked = _enabled; // require PIN on cold start
    _ready = true;
    notifyListeners();
  }

  /// Called when the app goes to the background — arm the lock so the next
  /// foreground brings up the PIN screen.
  void markBackgrounded() {
    if (_enabled && !_locked) {
      _locked = true;
      notifyListeners();
    }
  }

  void unlock() {
    if (_locked) {
      _locked = false;
      notifyListeners();
    }
  }

  /// Re-read the enabled flag after a Settings change. Newly enabled locks are
  /// NOT auto-locked (the user just authenticated to set them up); disabling
  /// clears any pending lock.
  Future<void> refreshEnabled() async {
    _enabled = await AppLockService.isEnabled();
    if (!_enabled) _locked = false;
    notifyListeners();
  }
}
