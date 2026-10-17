import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:random_avatar/random_avatar.dart';
import '../../providers/auth_provider.dart';
import '../../utils/constants.dart';
import '../../utils/avatar_presets.dart';
import '../../services/business_vocabulary.dart';
import 'onboarding_business_type_screen.dart';
import 'onboarding_first_task_screen.dart';

/// Screen 1 of post-auth onboarding:
/// Shows WhatWorks branding + asks for the user's name.
class OnboardingWelcomeScreen extends StatefulWidget {
  const OnboardingWelcomeScreen({super.key});

  @override
  State<OnboardingWelcomeScreen> createState() =>
      _OnboardingWelcomeScreenState();
}

class _OnboardingWelcomeScreenState extends State<OnboardingWelcomeScreen> {
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;

  // Multiavatar character chosen from the local library (optional). Stored as
  // an `avatar:mav:<seed>` string in the users doc — no upload, renders
  // instantly and identically on every device.
  String? _selectedSeed;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _onNext() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your name to continue'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final authProvider = context.read<AuthProvider>();
      await authProvider.updateUserName(
        name,
        avatarUrl: _selectedSeed != null
            ? AvatarPresets.mavUrlFor(_selectedSeed!)
            : null,
      );

      if (!mounted) return;

      // When the sector feature is on, route through the business-type picker
      // (which then leads to the first-task step). With it disabled, go
      // straight to the first-task step — the app stays in "General" mode.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => kSectorTemplatesEnabled
              ? const OnboardingBusinessTypeScreen()
              : const OnboardingFirstTaskScreen(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save name: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        // Scrollable so the avatar strip + name field stay reachable when
        // the keyboard is open; Spacers still expand on tall screens.
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        const Spacer(flex: 2),

                        // Logo
                        Container(
                          width: 90,
                          height: 90,
                          decoration: const BoxDecoration(
                            color: AppTheme.headerGreen,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.task_alt,
                            size: 50,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // App name
                        const Text(
                          'WhatWorks',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.headerGreen,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Tagline
                        const Text(
                          'By simply messaging, you can manage tasks effectively.\nLet WhatWorks manage everything for you.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            color: AppTheme.secondaryText,
                            height: 1.5,
                          ),
                        ),

                        const Spacer(flex: 1),

                        // Feature highlights
                        _buildFeatureRow(
                          Icons.chat_bubble_outline,
                          'Assign tasks by sending a message',
                        ),
                        const SizedBox(height: 12),
                        _buildFeatureRow(
                          Icons.notifications_active_outlined,
                          'Get reminders & follow-ups automatically',
                        ),
                        const SizedBox(height: 12),
                        _buildFeatureRow(
                          Icons.track_changes,
                          'Track progress without any extra apps',
                        ),

                        const Spacer(flex: 1),

                        // Avatar library — pick one with a single tap (optional)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _selectedSeed == null
                                ? 'Pick your avatar'
                                : 'Avatar selected',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 56,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: AvatarPresets.mavSeeds.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final seed = AvatarPresets.mavSeeds[index];
                              final isSelected = _selectedSeed == seed;
                              return GestureDetector(
                                onTap: () => setState(
                                  () => _selectedSeed = isSelected
                                      ? null
                                      : seed,
                                ),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 52,
                                  height: 52,
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isSelected
                                          ? AppTheme.primaryGreen
                                          : Colors.transparent,
                                      width: 2.5,
                                    ),
                                  ),
                                  child: ClipOval(
                                    child: RandomAvatar(
                                      seed,
                                      height: 48,
                                      width: 48,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Name input
                        Form(
                          key: _formKey,
                          child: TextFormField(
                            controller: _nameController,
                            autofocus: true,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Your Name',
                              hintText: 'Enter your full name',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: AppTheme.headerGreen,
                                  width: 2,
                                ),
                              ),
                              prefixIcon: const Icon(
                                Icons.person_outline,
                                color: AppTheme.headerGreen,
                              ),
                            ),
                            onFieldSubmitted: (_) => _onNext(),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Next button
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _isSaving ? null : _onNext,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryGreen,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                              ),
                            ),
                            child: _isSaving
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Next',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Icon(Icons.arrow_forward, size: 20),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String text) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.headerGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: AppTheme.headerGreen),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: AppTheme.primaryText),
          ),
        ),
      ],
    );
  }
}
