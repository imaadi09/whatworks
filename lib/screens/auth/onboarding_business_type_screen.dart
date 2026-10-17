import 'package:flutter/material.dart';
import '../../services/business_vocabulary.dart';
import '../../utils/constants.dart';
import 'onboarding_first_task_screen.dart';

/// Screen between the welcome and first-task steps of onboarding.
///
/// Asks "What does your business do?" and lets the new user pick a sector.
/// The choice is a FRAMING layer only: it relabels module vocabularies (e.g.
/// "Task" → "Job") and pre-seeds the milestone pipelines that fit the sector.
/// It never adds capabilities the app doesn't have, so every option maps to a
/// real, working configuration. Skippable — skipping keeps the "general"
/// defaults (exactly the pre-picker app).
class OnboardingBusinessTypeScreen extends StatefulWidget {
  const OnboardingBusinessTypeScreen({super.key});

  @override
  State<OnboardingBusinessTypeScreen> createState() =>
      _OnboardingBusinessTypeScreenState();
}

class _OnboardingBusinessTypeScreenState
    extends State<OnboardingBusinessTypeScreen> {
  String _selectedId = SectorTemplates.all.first.id; // 'general'
  bool _isSaving = false;

  Future<void> _onContinue() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      // Persist + update the in-memory vocabulary + seed milestones. 'general'
      // clears the preference (a no-op), so this is safe for every choice.
      await BusinessVocabulary.set(_selectedId);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save choice: $e')),
        );
        return;
      }
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingFirstTaskScreen()),
    );
  }

  void _onSkip() {
    // Leave the vocabulary at its default (general) and move on.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingFirstTaskScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),

              // Skip (top-right) — stays general, fully changeable later in
              // Settings.
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: _isSaving ? null : _onSkip,
                  child: const Text(
                    'Skip',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.secondaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),

              // Heading
              const Text(
                'What does your business do?',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryText,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "We'll name things and set up tracking steps to match. "
                'You can change this anytime in Settings.',
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.secondaryText,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),

              // Sector list — grouped by front-door module ("what kind of work
              // do you run?") instead of one long flat catalog of overlapping
              // archetypes. Retired broad sectors are excluded by the picker
              // view; General stays at the top as the neutral default.
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final group in SectorTemplates.pickerGroups) ...[
                      _GroupHeader(
                        title: group.title,
                        subtitle: group.subtitle,
                      ),
                      const SizedBox(height: 10),
                      for (final sector in group.sectors) ...[
                        _SectorTile(
                          sector: sector,
                          isSelected: sector.id == _selectedId,
                          onTap: () => setState(() => _selectedId = sector.id),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ],
                ),
              ),

              // Continue
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _onContinue,
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
                              'Continue',
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
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header for a group of sectors that share a front-door module (Option A).
class _GroupHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _GroupHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: AppTheme.headerGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppTheme.primaryText,
                ),
              ),
            ],
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.secondaryText,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One selectable sector row: icon, label, blurb, and a trailing radio check.
class _SectorTile extends StatelessWidget {
  final SectorTemplate sector;
  final bool isSelected;
  final VoidCallback onTap;

  const _SectorTile({
    required this.sector,
    required this.isSelected,
    required this.onTap,
  });

  static const Map<String, IconData> _icons = {
    'general': Icons.apps_outlined,
    'field-service': Icons.handyman_outlined,
    'distribution': Icons.local_shipping_outlined,
    'projects': Icons.architecture_outlined,
    'design': Icons.palette_outlined,
    'news': Icons.public_outlined,
    'consulting': Icons.gavel_outlined,
    'property-facility': Icons.apartment_outlined,
    'guarding-security': Icons.security_outlined,
    'equipment-maintenance': Icons.precision_manufacturing_outlined,
    // Phase-2E concrete SME sectors
    'ac-hvac-service': Icons.ac_unit,
    'cctv-electrical-solar': Icons.solar_power,
    'repair-maintenance': Icons.build_outlined,
    'it-support': Icons.support_agent,
    'distributors-wholesale': Icons.inventory_2_outlined,
    'building-material': Icons.holiday_village,
    'ca-accounting-tax': Icons.calculate_outlined,
    'interior-fitout': Icons.chair_outlined,
    'construction-civil': Icons.construction,
    'marketing-agency': Icons.campaign_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.headerGreen;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.06) : Colors.white,
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withOpacity(isSelected ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _icons[sector.id] ?? Icons.sell_outlined,
                color: color,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sector.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? color : AppTheme.primaryText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sector.blurb,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.secondaryText,
                      height: 1.3,
                    ),
                  ),
                  if (sector.examples.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      sector.examples,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.lightText,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: color, size: 22)
            else
              Icon(
                Icons.radio_button_unchecked,
                color: Colors.grey.shade400,
                size: 22,
              ),
          ],
        ),
      ),
    );
  }
}
