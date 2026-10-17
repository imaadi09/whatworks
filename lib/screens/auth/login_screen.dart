import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../utils/app_links.dart';
import '../../utils/constants.dart';
import 'register_screen.dart';
import 'phone_verification_screen.dart';
import 'onboarding_welcome_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  String _phoneNumber = '';

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  /// Opens a legal page. Consent has to be verifiable, so the two documents the
  /// text claims the user agreed to must actually be reachable from here.
  Future<void> _openLegal(String url) async {
    final ok = await AppLinks.open(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the page.')),
      );
    }
  }

  Future<void> _loginWithPhone() async {
    if (_phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your phone number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Format phone number with country code if not present
    String phoneNumber = _phoneController.text.trim();
    if (!phoneNumber.startsWith('+')) {
      // Assume India (+91) if no country code
      phoneNumber = '+91$phoneNumber';
    }

    setState(() {
      _phoneNumber = phoneNumber;
    });

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.verifyPhone(_phoneNumber);

    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            authProvider.errorMessage ??
                'Failed to send verification code. Please check your phone number and try again.',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      // Check if auto-verified (no verification ID means user is already signed in)
      if (authProvider.currentVerificationId == null) {
        // Auto-verified — skip SMS code, go to onboarding or home
        final user = authProvider.userModel;
        if (user != null && (user.name.isEmpty || user.name == 'User')) {
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => const OnboardingWelcomeScreen(),
              ),
            );
          }
        } else {
          if (mounted) {
            // Pop back to AuthenticationWrapper which auto-shows home when authenticated
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        }
      } else {
        // Navigate to SMS verification screen
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  PhoneVerificationScreen(phoneNumber: _phoneNumber),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            children: [
              const Spacer(),

              // Branding: app name + tagline only (user declutter request —
              // the logo circle and the explainer lines above the input were
              // removed; the field's own label already says what to enter).
              const Text(
                'WhatWorks',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.headerGreen,
                ),
              ),
              const SizedBox(height: 8),

              // Tagline
              const Text(
                'For Winning Teams',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.secondaryText,
                  letterSpacing: 0.4,
                  height: 1.4,
                ),
              ),

              const Spacer(),

              // Phone Number Input
              Column(
                children: [
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      hintText: '98765 43210',
                      prefixIcon: Icon(Icons.phone_outlined),
                      prefixText: '+91 ',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    onChanged: (value) {
                      // Auto-format: ensure number doesn't start with + or 0
                      if (value.startsWith('0')) {
                        _phoneController.text = value.substring(1);
                        _phoneController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _phoneController.text.length),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 24),

                  // Continue button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: authProvider.isLoading
                          ? null
                          : _loginWithPhone,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      child: authProvider.isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Text(
                              'Continue',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Footer text — Terms and Privacy are real, tappable links.
              // Built with Wrap + GestureDetector rather than TextSpan
              // recognizers, which would need disposing on every rebuild.
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'By continuing, you agree to our ',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.lightText,
                      height: 1.4,
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openLegal(AppLinks.terms),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Terms',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: AppTheme.primaryGreen,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: AppTheme.primaryGreen,
                        ),
                      ),
                    ),
                  ),
                  const Text(
                    ' & ',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.lightText,
                      height: 1.4,
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openLegal(AppLinks.privacy),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Privacy Policy',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: AppTheme.primaryGreen,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: AppTheme.primaryGreen,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Register link
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RegisterScreen(),
                    ),
                  );
                },
                child: RichText(
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: "Don't have an account? ",
                        style: TextStyle(color: AppTheme.secondaryText),
                      ),
                      TextSpan(
                        text: 'Register',
                        style: TextStyle(
                          color: AppTheme.primaryGreen,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
