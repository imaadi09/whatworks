import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:random_avatar/random_avatar.dart';
import 'dart:io';
import '../../providers/auth_provider.dart';
import '../../utils/constants.dart';
import '../../utils/paywall_constants.dart';
import '../../utils/avatar_presets.dart';
import '../../widgets/app_avatar.dart';
import 'upgrade_screen.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _mobileController;
  late TextEditingController _organizationController;
  late TextEditingController _designationController;

  File? _profileImage;
  // Preset avatar picked from the local library (`avatar:<id>` string);
  // mutually exclusive with _profileImage.
  String? _selectedPresetUrl;
  bool _hasChanges = false;
  bool _phoneVerified = false;
  String? _phoneVerificationId;
  late String _originalPhone; // Track original phone to detect changes

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().userModel;
    _nameController = TextEditingController(text: user?.name ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _originalPhone = user?.phone ?? user?.mobileNumber ?? '';
    _mobileController = TextEditingController(text: _originalPhone);
    _organizationController = TextEditingController(
      text: user?.organization ?? '',
    );
    _designationController = TextEditingController(
      text: user?.designation ?? '',
    );
    // If user already has a verified phone from Firebase Auth, mark as verified
    _phoneVerified = _originalPhone.isNotEmpty;

    // Listen for phone field edits to reset verification
    _mobileController.addListener(_onPhoneFieldChanged);
  }

  void _onPhoneFieldChanged() {
    final currentPhone = _mobileController.text.trim();
    final normalizedCurrent = _normalizeForComparison(currentPhone);
    final normalizedOriginal = _normalizeForComparison(_originalPhone);

    if (normalizedCurrent != normalizedOriginal) {
      // Phone changed — require re-verification
      if (_phoneVerified) {
        setState(() {
          _phoneVerified = false;
          _hasChanges = true;
        });
      }
    }
    setState(() => _hasChanges = true);
  }

  /// Normalize phone for comparison (strip +, spaces, country code prefix)
  String _normalizeForComparison(String phone) {
    return phone.replaceAll(RegExp(r'[\s\-\+]'), '');
  }

  bool get _isPhoneChanged =>
      _normalizeForComparison(_mobileController.text.trim()) !=
      _normalizeForComparison(_originalPhone);

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _mobileController.removeListener(_onPhoneFieldChanged);
    _mobileController.dispose();
    _organizationController.dispose();
    _designationController.dispose();
    super.dispose();
  }

  Future<void> _pickProfileImage() async {
    final picker = ImagePicker();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Profile Picture'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.emoji_emotions_outlined,
                color: AppTheme.headerGreen,
              ),
              title: const Text('Choose an Avatar'),
              onTap: () {
                Navigator.pop(context);
                _choosePresetAvatar();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                final image = await picker.pickImage(
                  source: ImageSource.gallery,
                  maxWidth: 512,
                  maxHeight: 512,
                  imageQuality: 80,
                );
                if (image != null && mounted) {
                  final file = File(image.path);
                  final size = await file.length();
                  if (size > 5 * 1024 * 1024) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Image too large. Maximum 5 MB allowed.'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }
                  setState(() {
                    _profileImage = file;
                    _selectedPresetUrl = null;
                    _hasChanges = true;
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take a Photo'),
              onTap: () async {
                Navigator.pop(context);
                final image = await picker.pickImage(
                  source: ImageSource.camera,
                  maxWidth: 512,
                  maxHeight: 512,
                  imageQuality: 80,
                );
                if (image != null && mounted) {
                  final file = File(image.path);
                  final size = await file.length();
                  if (size > 5 * 1024 * 1024) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Image too large. Maximum 5 MB allowed.'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }
                  setState(() {
                    _profileImage = file;
                    _selectedPresetUrl = null;
                    _hasChanges = true;
                  });
                }
              },
            ),
            if (context.read<AuthProvider>().userModel?.avatarUrl != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Remove Current Photo'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _profileImage = null;
                    _selectedPresetUrl = null;
                    // TODO: Clear avatarUrl in provider
                    _hasChanges = true;
                  });
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Grid of local multiavatar characters — no upload, syncs as an
  /// `avatar:mav:<seed>` string and renders instantly on every device.
  void _choosePresetAvatar() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Choose an Avatar',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                    itemCount: AvatarPresets.mavSeeds.length,
                    itemBuilder: (context, index) {
                      final seed = AvatarPresets.mavSeeds[index];
                      final url = AvatarPresets.mavUrlFor(seed);
                      final isSelected = _selectedPresetUrl == url;
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() {
                            _selectedPresetUrl = url;
                            _profileImage = null;
                            _hasChanges = true;
                          });
                        },
                        child: Container(
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
                            child: RandomAvatar(seed, height: 52, width: 52),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    // If phone changed but not verified, block save
    if (_isPhoneChanged && !_phoneVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please verify the new phone number first'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final authProvider = context.read<AuthProvider>();
    final mobileNumber = _mobileController.text.trim();

    setState(() {});

    // If phone is verified, save it to both phone and mobileNumber fields
    await authProvider.updateProfile(
      name: _nameController.text.trim(),
      organization: _organizationController.text.trim().isEmpty
          ? null
          : _organizationController.text.trim(),
      designation: _designationController.text.trim().isEmpty
          ? null
          : _designationController.text.trim(),
      phone: _phoneVerified && mobileNumber.isNotEmpty
          ? mobileNumber
          : null, // Save verified phone
      mobileNumber: mobileNumber.isEmpty ? null : mobileNumber,
      // File path → uploaded in provider; preset `avatar:<id>` string is
      // stored as-is (no upload) and rendered locally everywhere.
      avatarUrl: _profileImage?.path ?? _selectedPresetUrl,
    );

    if (!mounted) return;

    // Update original phone after successful save
    _originalPhone = mobileNumber;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Profile updated successfully!'),
        backgroundColor: AppTheme.primaryGreen,
      ),
    );

    setState(() {
      _hasChanges = false;
    });
  }

  Future<void> _verifyPhone() async {
    final phone = _mobileController.text.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter phone number first')),
      );
      return;
    }

    // If phone number changed, show confirmation dialog
    if (_isPhoneChanged) {
      final confirmed = await _showPhoneChangeConfirmation();
      if (!confirmed) return;
    }

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
        phoneNumber: phone.startsWith('+') ? phone : '+91$phone',
        verificationCompleted:
            (firebase_auth.PhoneAuthCredential credential) async {
              Navigator.pop(context);

              if (_isPhoneChanged) {
                // Phone change: update Firebase Auth on existing account (keeps same UID)
                try {
                  await context.read<AuthProvider>().changePhoneNumber(
                    credential,
                    phone.startsWith('+') ? phone : '+91$phone',
                  );
                  final verifiedPhone = firebase_auth
                      .FirebaseAuth
                      .instance
                      .currentUser
                      ?.phoneNumber;
                  setState(() {
                    _phoneVerified = true;
                    _hasChanges = true;
                    if (verifiedPhone != null) {
                      _mobileController.text = verifiedPhone;
                    }
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Phone number changed and verified successfully',
                      ),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to update phone: ${e.toString()}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } else {
                // First-time verification: just sign in
                await firebase_auth.FirebaseAuth.instance.signInWithCredential(
                  credential,
                );
                final verifiedPhone = firebase_auth
                    .FirebaseAuth
                    .instance
                    .currentUser
                    ?.phoneNumber;
                setState(() {
                  _phoneVerified = true;
                  _hasChanges = true;
                  if (verifiedPhone != null) {
                    _mobileController.text = verifiedPhone;
                  }
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Phone number verified automatically'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
        verificationFailed: (firebase_auth.FirebaseAuthException e) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Verification failed: ${e.message}'),
              backgroundColor: Colors.red,
            ),
          );
        },
        codeSent: (String verificationId, int? resendToken) {
          Navigator.pop(context);
          setState(() {
            _phoneVerificationId = verificationId;
          });
          _showSmsCodeDialog();
        },
        codeAutoRetrievalTimeout: (String verificationId) {},
      );
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Show confirmation dialog before changing phone number
  Future<bool> _showPhoneChangeConfirmation() async {
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
            Text('Current: $_originalPhone'),
            const SizedBox(height: 4),
            Text('New: ${_mobileController.text.trim()}'),
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
                      'Your tasks, messages, and all data will remain intact. Only your login number will change.',
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

  // Build plan feature row
  Widget _buildPlanFeature(String icon, String text, bool enabled) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            icon,
            style: TextStyle(
              fontSize: 14,
              color: enabled ? Colors.green : Colors.red,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: enabled ? AppTheme.primaryText : AppTheme.lightText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Open the B2C upgrade screen (benefits + billing website link).
  void _showUpgradeDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UpgradeScreen()),
    );
  }

  void _showSmsCodeDialog() {
    final codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Verify Phone Number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the 6-digit code sent to ${_mobileController.text}',
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

                if (_isPhoneChanged) {
                  // Phone change: update Firebase Auth on existing account (keeps same UID)
                  await context.read<AuthProvider>().changePhoneNumber(
                    credential,
                    _mobileController.text.trim().startsWith('+')
                        ? _mobileController.text.trim()
                        : '+91${_mobileController.text.trim()}',
                  );

                  final verifiedPhone = firebase_auth
                      .FirebaseAuth
                      .instance
                      .currentUser
                      ?.phoneNumber;

                  Navigator.pop(ctx);
                  setState(() {
                    _phoneVerified = true;
                    _hasChanges = true;
                    if (verifiedPhone != null) {
                      _mobileController.text = verifiedPhone;
                    }
                  });

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Phone number changed successfully'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } else {
                  // First-time verification: sign in
                  await firebase_auth.FirebaseAuth.instance
                      .signInWithCredential(credential);

                  final verifiedPhone = firebase_auth
                      .FirebaseAuth
                      .instance
                      .currentUser
                      ?.phoneNumber;

                  Navigator.pop(ctx);
                  setState(() {
                    _phoneVerified = true;
                    _hasChanges = true;
                    if (verifiedPhone != null) {
                      _mobileController.text = verifiedPhone;
                    }
                  });

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Phone number verified successfully'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Invalid code: ${e.toString()}'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.userModel;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Edit Profile'),
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_hasChanges)
            TextButton(
              onPressed: authProvider.isLoading ? null : _saveProfile,
              child: authProvider.isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'SAVE',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Profile Picture Section
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _pickProfileImage,
                      child: Stack(
                        children: [
                          // Local file preview beats everything; otherwise
                          // AppAvatar handles preset / photo URL / initials.
                          _profileImage != null
                              ? CircleAvatar(
                                  radius: 60,
                                  backgroundColor: AppTheme.lightGrey,
                                  backgroundImage: FileImage(_profileImage!),
                                )
                              : AppAvatar(
                                  avatarUrl:
                                      _selectedPresetUrl ?? user?.avatarUrl,
                                  initials:
                                      user?.name
                                          .substring(0, 1)
                                          .toUpperCase() ??
                                      'U',
                                  radius: 60,
                                  color: AppTheme.headerGreen,
                                  fontSize: 48,
                                ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: AppTheme.primaryGreen,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.camera_alt,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Tap to change profile picture',
                      style: TextStyle(
                        color: AppTheme.secondaryText,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Personal Information Section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Personal Information',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Name Field
                    TextFormField(
                      controller: _nameController,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Full Name *',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Name is required';
                        }
                        if (value.trim().length < 2) {
                          return 'Name must be at least 2 characters';
                        }
                        return null;
                      },
                      onChanged: (_) => setState(() => _hasChanges = true),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),

                    // Email Field (Read-only)
                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        prefixIcon: const Icon(Icons.email_outlined),
                        border: const OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.grey[100],
                        helperText: 'Email cannot be changed',
                      ),
                      enabled: false,
                    ),
                    const SizedBox(height: 16),

                    // Mobile Number Field with Verify Button
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _mobileController,
                            maxLength: 15,
                            decoration: const InputDecoration(
                              labelText: 'Mobile Number',
                              prefixIcon: Icon(Icons.phone_outlined),
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return null; // Optional
                              }
                              final phoneRegex = RegExp(r'^\+?[0-9]{10,15}$');
                              if (!phoneRegex.hasMatch(value.trim())) {
                                return 'Please enter a valid phone number';
                              }
                              return null;
                            },
                            onChanged: (_) =>
                                setState(() => _hasChanges = true),
                            keyboardType: TextInputType.phone,
                            textInputAction: TextInputAction.next,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _phoneVerified && !_isPhoneChanged
                              ? null
                              : _verifyPhone,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _phoneVerified && !_isPhoneChanged
                                ? Colors.green
                                : _isPhoneChanged
                                ? Colors.orange
                                : null,
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 16,
                            ),
                          ),
                          child: _phoneVerified && !_isPhoneChanged
                              ? const Icon(Icons.check, color: Colors.white)
                              : _isPhoneChanged
                              ? const Text('Change')
                              : const Text('Verify'),
                        ),
                      ],
                    ),
                    if (_phoneVerified && !_isPhoneChanged)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '✓ Phone verified',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    if (_phoneVerified && _isPhoneChanged)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '✓ New phone verified — tap Save to apply',
                          style: TextStyle(
                            color: Colors.orange.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Professional Information Section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Professional Information',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Organization Field
                    TextFormField(
                      controller: _organizationController,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Organization',
                        prefixIcon: Icon(Icons.business_outlined),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() => _hasChanges = true),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),

                    // Designation Field
                    TextFormField(
                      controller: _designationController,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Designation',
                        prefixIcon: Icon(Icons.work_outline),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() => _hasChanges = true),
                      textInputAction: TextInputAction.done,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Subscription Plan Section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: PaywallLimits.isPremium(user?.planType ?? '')
                        ? Colors.amber
                        : Colors.grey.shade300,
                    width: PaywallLimits.isPremium(user?.planType ?? '')
                        ? 2
                        : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PaywallLimits.isPremium(user?.planType ?? '')
                              ? Icons.workspace_premium
                              : Icons.account_circle_outlined,
                          color: PaywallLimits.isPremium(user?.planType ?? '')
                              ? Colors.amber
                              : AppTheme.secondaryText,
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Subscription Plan',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryText,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: PaywallLimits.isPremium(user?.planType ?? '')
                                ? Colors.amber.withOpacity(0.1)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            PaywallLimits.isPremium(user?.planType ?? '')
                                ? 'PREMIUM'
                                : 'BASIC',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color:
                                  PaywallLimits.isPremium(user?.planType ?? '')
                                  ? Colors.amber.shade800
                                  : AppTheme.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!PaywallLimits.isPremium(user?.planType ?? '')) ...[
                      // Basic plan features
                      _buildPlanFeature(
                        '✓',
                        'Up to 20 contacts (main module)',
                        true,
                      ),
                      _buildPlanFeature(
                        '✓',
                        'Up to 5 contacts (other modules)',
                        true,
                      ),
                      _buildPlanFeature('✓', '200 MB attachment storage', true),
                      _buildPlanFeature('✗', 'Export to CSV/PDF', false),
                      _buildPlanFeature('✗', 'Reports & Analytics', false),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: () => _showUpgradeDialog(),
                          icon: const Icon(Icons.upgrade, size: 20),
                          label: const Text(
                            'Upgrade to Premium',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      // Premium plan features
                      _buildPlanFeature(
                        '✓',
                        'Up to 100 contacts (main module)',
                        true,
                      ),
                      _buildPlanFeature(
                        '✓',
                        'Unlimited contacts (other modules)',
                        true,
                      ),
                      _buildPlanFeature('✓', '500 MB attachment storage', true),
                      _buildPlanFeature('✓', 'Export to CSV/PDF', true),
                      _buildPlanFeature('✓', 'Reports & Analytics', true),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: Colors.amber,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'All Premium features active.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.amber.shade800,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Save Button (Mobile)
              if (_hasChanges)
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: authProvider.isLoading ? null : _saveProfile,
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
                            'Save Changes',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
