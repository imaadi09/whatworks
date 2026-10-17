import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/task.dart';
import '../../providers/auth_provider.dart';
import '../../providers/task_provider.dart';
import '../../services/contact_picker_service.dart';
import '../../services/business_vocabulary.dart';
import '../../modules/shared/module_config.dart';
import '../../modules/sales/screens/sales_home_screen.dart';
import '../../modules/crm/screens/crm_home_screen.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../../utils/paywall_constants.dart';

/// Screen 2 of post-auth onboarding:
/// Pick a contact + enter one task title. Creates a REAL task (SQLite-first),
/// so the home Assignee tab opens showing that person with 1 task.
class OnboardingFirstTaskScreen extends StatefulWidget {
  const OnboardingFirstTaskScreen({super.key});

  @override
  State<OnboardingFirstTaskScreen> createState() =>
      _OnboardingFirstTaskScreenState();
}

class _OnboardingFirstTaskScreenState extends State<OnboardingFirstTaskScreen> {
  final _titleController = TextEditingController();
  AssignableContact? _selectedContact;
  bool _isSaving = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      _titleController.text.trim().isNotEmpty && _selectedContact != null;

  Future<void> _pickContact() async {
    final contact = await ContactPickerService().showContactPicker(context);
    if (contact != null && mounted) {
      setState(() => _selectedContact = contact);
    }
  }

  Future<void> _onCreate() async {
    if (!_canCreate || _isSaving) return;
    setState(() => _isSaving = true);

    try {
      final authProvider = context.read<AuthProvider>();
      final taskProvider = context.read<TaskProvider>();
      final user = authProvider.userModel;
      final contact = _selectedContact!;
      if (user == null) throw Exception('Not signed in');

      final now = DateTime.now();
      final task = TaskModel(
        id: '',
        title: _titleController.text.trim(),
        description: '',
        createdBy: user.uid,
        createdByName: user.name,
        createdByPhone: user.phone,
        assignedTo: contact.name,
        assignedToUid: contact.uid,
        assignedToPhone: Helpers.normalizePhone(contact.phone),
        participants: [
          user.uid,
          if (contact.uid != null && contact.uid!.isNotEmpty) contact.uid!,
        ],
        createdAt: now,
        updatedAt: now,
      );
      final taskId = await taskProvider.createTask(
        task,
        planType: authProvider.effectivePlanTypeFor('task'),
      );
      if (taskId == null) throw Exception('Failed to create task');
    } on PlanLimitException catch (e) {
      if (mounted) {
        await showPaywallDialog(context, feature: e.feature, detail: e.message);
        setState(() => _isSaving = false);
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create task: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isSaving = false);
        return;
      }
    }

    if (!mounted) return;
    await _goToHome();
  }

  void _onSkip() => _goToHome();

  /// Finish onboarding. Pop to the root HomeScreen, then bounce into the
  /// sector's front-door module IN THIS SESSION: the root HomeScreen mounts
  /// the instant auth flips (before the business-type pick), so its one-time
  /// startup restore has already run and won't re-fire. We only bounce when
  /// there's no real 'last module' yet — a first-time user lands on the front
  /// door; thereafter the standing rule is "reopen the last opened module."
  Future<void> _goToHome() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final target =
        prefs.getString('last_home_module') ??
        prefs.getString('preferred_home_module');

    // Capture the navigator before popping — this screen's context dies on
    // pop, but the root navigator it came from survives.
    final nav = Navigator.of(context, rootNavigator: true);
    nav.popUntil((route) => route.isFirst);

    // Sales/CRM aren't the root screen, so replace the revealed HomeScreen
    // with that module home (mirrors the drawer's pushReplacement model:
    // exactly one module home on the stack, so Back exits the app).
    if (target == 'sales' || target == 'crm') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nav.pushReplacement(
          MaterialPageRoute(
            builder: (_) => target == 'sales'
                ? const SalesHomeScreen(moduleConfig: ModuleConfig.sales)
                : const CrmHomeScreen(),
          ),
        );
      });
    }
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
              const SizedBox(height: 24),

              // Skip button (top-right)
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: _onSkip,
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
              const SizedBox(height: 16),

              // Title
              Text(
                'Create your first ${BusinessVocabulary.taskItemName.toLowerCase()}',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Assign one ${BusinessVocabulary.taskItemName.toLowerCase()} to someone and start tracking it right away.',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.secondaryText,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),

              // Assignee picker tile
              InkWell(
                onTap: _pickContact,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _selectedContact != null
                          ? AppTheme.headerGreen
                          : Colors.grey.shade400,
                      width: _selectedContact != null ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        color: AppTheme.headerGreen,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _selectedContact?.name ?? 'Assign to…',
                          style: TextStyle(
                            fontSize: 15,
                            color: _selectedContact != null
                                ? AppTheme.primaryText
                                : AppTheme.lightText,
                            fontWeight: _selectedContact != null
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(
                        Icons.arrow_drop_down,
                        color: AppTheme.secondaryText,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Task title field
              TextFormField(
                controller: _titleController,
                maxLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: BusinessVocabulary.taskItemName,
                  hintText: 'e.g., Collect payment from vendor',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.lightText,
                  ),
                  prefixIcon: const Icon(
                    Icons.task_alt,
                    color: AppTheme.headerGreen,
                    size: 22,
                  ),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                ),
                onChanged: (_) {
                  // Rebuild to update button state
                  if (mounted) setState(() {});
                },
                onFieldSubmitted: (_) => _onCreate(),
              ),

              const Spacer(),

              // Create button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : (_canCreate ? _onCreate : null),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.primaryGreen.withOpacity(
                      0.3,
                    ),
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
                      : Text(
                          _canCreate
                              ? 'Create & Start'
                              : (_selectedContact == null
                                    ? 'Pick a contact and enter a ${BusinessVocabulary.taskItemName.toLowerCase()}'
                                    : 'Enter a ${BusinessVocabulary.taskItemName.toLowerCase()}'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
