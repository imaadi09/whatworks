import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_lock_controller.dart';
import '../../services/app_lock_service.dart';
import '../../widgets/pin_pad.dart';

/// Full-screen PIN gate shown while [AppLockController.isLocked] is true.
///
/// Verifies the entered PIN against [AppLockService] and, on success, calls
/// [AppLockController.unlock] to reveal the underlying app.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final PinEntryController _pinController = PinEntryController();
  String? _error;
  bool _checking = false;

  Future<void> _onCompleted(String pin) async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await AppLockService.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      context.read<AppLockController>().unlock();
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
    return PopScope(
      // Block the system back button so it can't pop routes hidden behind the
      // lock (or exit the app) while the PIN gate is showing.
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: PinEntryView(
                controller: _pinController,
                title: 'Enter PIN',
                subtitle: 'Unlock WhatWorks to continue',
                pinLength: AppLockService.pinLength,
                errorText: _error,
                onCompleted: _onCompleted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
