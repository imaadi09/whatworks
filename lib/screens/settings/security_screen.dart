import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_lock_controller.dart';
import '../../services/app_lock_service.dart';
import '../../utils/constants.dart';
import '../../widgets/pin_pad.dart';

/// Security settings — a local PIN app-lock (this app signs in with phone OTP,
/// so there is no password/2FA to manage here).
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppLockService.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      await _setupPin();
    } else {
      await _disablePin();
    }
  }

  Future<void> _setupPin() async {
    final pin = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _PinSetupScreen()),
    );
    if (pin == null) return;
    await AppLockService.setPin(pin);
    if (!mounted) return;
    await context.read<AppLockController>().refreshEnabled();
    if (!mounted) return;
    setState(() => _enabled = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('App Lock enabled')),
    );
  }

  Future<void> _disablePin() async {
    final ok = await _verifyCurrentPin('Enter PIN to turn off App Lock');
    if (!ok) return;
    await AppLockService.disable();
    if (!mounted) return;
    await context.read<AppLockController>().refreshEnabled();
    if (!mounted) return;
    setState(() => _enabled = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('App Lock disabled')),
    );
  }

  Future<void> _changePin() async {
    final ok = await _verifyCurrentPin('Enter current PIN');
    if (!ok) return;
    await _setupPin(); // reuse setup flow to capture + store a new PIN
  }

  /// Pushes a PIN entry screen and returns true only if the entered PIN matches
  /// the stored one.
  Future<bool> _verifyCurrentPin(String title) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _PinVerifyScreen(title: title)),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Security'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 8),
                Container(
                  color: Theme.of(context).cardColor,
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.lock_outline,
                          color: AppTheme.headerGreen,
                        ),
                        title: const Text('App Lock'),
                        subtitle: Text(
                          _enabled
                              ? 'A PIN is required to open the app'
                              : 'Require a PIN to open the app',
                        ),
                        value: _enabled,
                        activeColor: AppTheme.primaryGreen,
                        onChanged: _onToggle,
                      ),
                      if (_enabled) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(
                            Icons.pin_outlined,
                            color: AppTheme.headerGreen,
                          ),
                          title: const Text('Change PIN'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _changePin,
                        ),
                      ],
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'App Lock is a local PIN on this device. It does not affect '
                    'your account sign-in, which uses your phone number.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Two-step new-PIN capture: enter, then confirm. Pops the PIN string on match.
class _PinSetupScreen extends StatefulWidget {
  const _PinSetupScreen();

  @override
  State<_PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<_PinSetupScreen> {
  final PinEntryController _pinController = PinEntryController();
  String? _firstPin;
  String? _error;

  void _onCompleted(String pin) {
    if (_firstPin == null) {
      setState(() {
        _firstPin = pin;
        _error = null;
      });
      _pinController.clear();
    } else if (_firstPin == pin) {
      Navigator.pop(context, pin);
    } else {
      setState(() {
        _firstPin = null;
        _error = 'PINs did not match, start again';
      });
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_firstPin == null ? 'Set PIN' : 'Confirm PIN'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: PinEntryView(
              controller: _pinController,
              title: _firstPin == null ? 'Choose a PIN' : 'Re-enter PIN',
              subtitle: _firstPin == null
                  ? 'This ${AppLockService.pinLength}-digit PIN unlocks the app'
                  : 'Enter the same PIN again to confirm',
              pinLength: AppLockService.pinLength,
              errorText: _error,
              onCompleted: _onCompleted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Verifies the current PIN; pops true on success, false if the user backs out.
class _PinVerifyScreen extends StatefulWidget {
  final String title;
  const _PinVerifyScreen({required this.title});

  @override
  State<_PinVerifyScreen> createState() => _PinVerifyScreenState();
}

class _PinVerifyScreenState extends State<_PinVerifyScreen> {
  final PinEntryController _pinController = PinEntryController();
  String? _error;
  bool _checking = false;

  Future<void> _onCompleted(String pin) async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await AppLockService.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _error = 'Incorrect PIN, try again';
        _checking = false;
      });
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify PIN'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: PinEntryView(
              controller: _pinController,
              title: widget.title,
              pinLength: AppLockService.pinLength,
              errorText: _error,
              onCompleted: _onCompleted,
            ),
          ),
        ),
      ),
    );
  }
}
