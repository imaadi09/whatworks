import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';

/// Dedicated screen for switching the login phone number.
///
/// The Firebase Auth credential is updated on the SAME UID, so tasks,
/// messages and teams never change hands. After verification the local
/// SQLite phone references are migrated (AuthProvider) and the user's
/// Firestore task docs are swept in the background (TaskProvider).
class ChangePhoneScreen extends StatefulWidget {
  const ChangePhoneScreen({super.key});

  @override
  State<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends State<ChangePhoneScreen> {
  final _newPhoneController = TextEditingController();
  String? _phoneVerificationId;
  bool _isBusy = false;

  @override
  void dispose() {
    _newPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().userModel;
    final currentPhone = user?.phone ?? '';

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppTheme.primaryGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Change Phone Number',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Info card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.primaryGreen.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  color: AppTheme.primaryGreen,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your account ID stays the same, so all your tasks, '
                    'messages, teams and data move with you automatically. '
                    'Only your login number changes. You will need to verify '
                    'the new number with an OTP.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Current phone
          const Text(
            'CURRENT NUMBER',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTheme.lightText,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.lightGrey.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.lightGrey, width: 1),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.phone_android_outlined,
                  size: 18,
                  color: AppTheme.secondaryText,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentPhone.isEmpty ? 'Not set' : currentPhone,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.primaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // New phone input
          const Text(
            'NEW NUMBER',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTheme.lightText,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _newPhoneController,
            keyboardType: TextInputType.phone,
            maxLength: 13,
            decoration: InputDecoration(
              hintText: 'Enter new mobile number',
              counterText: '',
              prefixIcon: const Icon(Icons.phone_outlined),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _startPhoneChange,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: _isBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.security),
              label: Text(_isBusy ? 'Working...' : 'Verify & Switch Number'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startPhoneChange() async {
    final raw = _newPhoneController.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the new phone number')),
      );
      return;
    }

    final newPhone = raw.startsWith('+') ? raw : '+91$raw';
    final currentPhone = context.read<AuthProvider>().userModel?.phone ?? '';
    final currentNorm = Helpers.normalizePhone(currentPhone) ?? currentPhone;
    final newNorm = Helpers.normalizePhone(newPhone) ?? newPhone;

    if (currentNorm.isNotEmpty && currentNorm == newNorm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New number is the same as your current number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final confirmed = await _showConfirmDialog(currentPhone, newPhone);
    if (!confirmed || !mounted) return;

    setState(() => _isBusy = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Sending verification code...'),
          ],
        ),
      ),
    );

    try {
      await firebase_auth.FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: newPhone,
        verificationCompleted:
            (firebase_auth.PhoneAuthCredential credential) async {
              if (!mounted) return;
              Navigator.pop(context); // dismiss progress dialog
              await _applyChange(credential, newPhone);
            },
        verificationFailed: (firebase_auth.FirebaseAuthException e) {
          if (!mounted) return;
          Navigator.pop(context); // dismiss progress dialog
          setState(() => _isBusy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Verification failed: ${e.message}'),
              backgroundColor: Colors.red,
            ),
          );
        },
        codeSent: (String verificationId, int? resendToken) {
          if (!mounted) return;
          Navigator.pop(context); // dismiss progress dialog
          setState(() {
            _phoneVerificationId = verificationId;
            _isBusy = false;
          });
          _showSmsCodeDialog(newPhone);
        },
        codeAutoRetrievalTimeout: (String verificationId) {},
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss progress dialog
      setState(() => _isBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Apply the credential: update Auth + profile + local SQLite, then sweep
  /// the user's Firestore task docs in the background.
  Future<void> _applyChange(
    firebase_auth.PhoneAuthCredential credential,
    String newPhone,
  ) async {
    final authProvider = context.read<AuthProvider>();
    final oldPhone = authProvider.userModel?.phone ?? '';

    setState(() => _isBusy = true);
    try {
      await authProvider.changePhoneNumber(credential, newPhone);

      // Background sweep of Firestore task docs (creator/assignee phone
      // fields). Local SQLite was already migrated inside changePhoneNumber.
      if (oldPhone.isNotEmpty && mounted) {
        unawaited(
          context.read<TaskProvider>().migrateOwnPhone(
            oldPhone: oldPhone,
            newPhone: newPhone,
          ),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone number changed. All your data moved with you.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to change phone number: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<bool> _showConfirmDialog(String current, String next) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Change Phone Number?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You are about to change your login phone number.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text('Current: $current'),
            const SizedBox(height: 4),
            Text('New: $next'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your tasks, messages, teams and all data will remain '
                      'intact. Only your login number will change.',
                      style: TextStyle(fontSize: 13, color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showSmsCodeDialog(String newPhone) {
    final codeController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Verify New Number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the 6-digit code sent to $newPhone',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Verification Code',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final smsCode = codeController.text.trim();
              if (smsCode.length != 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter 6-digit code')),
                );
                return;
              }
              try {
                final credential = firebase_auth.PhoneAuthProvider.credential(
                  verificationId: _phoneVerificationId!,
                  smsCode: smsCode,
                );
                Navigator.pop(ctx);
                await _applyChange(credential, newPhone);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Verification error: ${e.toString()}'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }
}
