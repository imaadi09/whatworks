import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:async';
import 'dart:io';
import '../models/user.dart';
import '../models/organization.dart';
import '../models/org_member.dart';
import '../services/firebase/auth_repository.dart';
import '../services/organization_service.dart';
import '../services/notification_service.dart';
import '../services/avatar_cache_service.dart';
import '../services/local_database_service.dart';
import '../services/local_storage_service.dart';
import '../services/firebase_service.dart';
import '../services/module_plan_cache.dart';
import '../utils/helpers.dart';

class AuthProvider extends ChangeNotifier {
  final AuthRepository _authRepository = AuthRepository();
  final OrganizationService _orgService = OrganizationService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? _firebaseUser;
  UserModel? _userModel;
  bool _isLoading = false;
  String? _errorMessage;
  StreamSubscription<User?>? _authSubscription;

  // Cached workspace (organization) context — membership info only, no
  // longer used for plan derivation.
  OrganizationModel? _org;
  OrgMemberModel? _orgMember;

  OrganizationModel? get organization => _org;
  OrgMemberModel? get orgMember => _orgMember;

  User? get firebaseUser => _firebaseUser;
  UserModel? get userModel => _userModel;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _userModel != null;
  String? get errorMessage => _errorMessage;

  /// The plan that actually gates features.
  ///
  /// B2C model: premium is a per-user attribute stored on [UserModel.planType].
  /// Workspace (organization) membership never grants or denies premium.
  ///
  /// Reads [UserModel.effectivePlanType], so a plan whose `planExpiry` has
  /// passed counts as free the moment it lapses — without waiting for the
  /// nightly `expirePremiumPlans` sweep to rewrite the Firestore doc.
  String get effectivePlanType => _userModel?.effectivePlanType ?? 'free';

  /// The plan gating ONE specific module ('task', 'sale', 'crm', 'inventory').
  /// Subscriptions are per module with their own start/expiry dates — see
  /// [UserModel.effectivePlanTypeFor].
  String effectivePlanTypeFor(String module) =>
      _userModel?.effectivePlanTypeFor(module) ?? 'basic';

  AuthProvider() {
    // Listen to Firebase auth state changes
    _authSubscription = _authRepository.authStateChanges.listen(
      _onAuthStateChanged,
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  // Login with phone number (Firebase Phone Auth)
  Future<bool> loginWithPhone({
    required String phoneNumber,
    required String verificationId,
    required String smsCode,
  }) async {
    try {
      _errorMessage = null;
      _isLoading = true;
      notifyListeners();

      // Real Firebase phone authentication
      final user = await _authRepository.signInWithSmsCode(
        verificationId: verificationId,
        smsCode: smsCode,
      );

      if (user != null) {
        _firebaseUser = _authRepository.firebaseUser;
        _userModel = user;
        // Register this device for message push notifications.
        NotificationService().saveTokenForCurrentUser();
      }

      _isLoading = false;
      notifyListeners();
      return user != null;
    } catch (e) {
      // Fallback: user may already be signed in via auto-verification
      final currentUser = _authRepository.firebaseUser;
      if (currentUser != null) {
        _firebaseUser = currentUser;
        try {
          final existingUser = await _authRepository.getUserProfile(
            currentUser.uid,
          );
          _userModel =
              existingUser ??
              UserModel(
                uid: currentUser.uid,
                name: currentUser.displayName ?? 'User',
                email: currentUser.email ?? '',
                phone: Helpers.normalizePhone(currentUser.phoneNumber) ?? '',
                avatarUrl: null,
                organization: '',
                createdAt: DateTime.now(),
              );
        } catch (_) {
          _userModel = UserModel(
            uid: currentUser.uid,
            name: currentUser.displayName ?? 'User',
            email: currentUser.email ?? '',
            phone: Helpers.normalizePhone(currentUser.phoneNumber) ?? '',
            avatarUrl: null,
            organization: '',
            createdAt: DateTime.now(),
          );
        }
        _isLoading = false;
        notifyListeners();
        // Register this device for message push notifications.
        NotificationService().saveTokenForCurrentUser();
        return true;
      }
      _errorMessage = 'Login failed: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Verify phone number (sends SMS)
  Future<bool> verifyPhoneNumber({
    required String phoneNumber,
    required Function(String verificationId) onCodeSent,
    required Function(FirebaseAuthException error) onError,
  }) async {
    try {
      _errorMessage = null;
      _isLoading = true;
      notifyListeners();

      // Real Firebase phone verification
      await _authRepository.verifyPhone(
        phoneNumber,
        onCodeSent: onCodeSent,
        onError: onError,
      );

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Verification failed: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Simplified verify phone for login screen (returns verificationId via Future)
  Future<bool> verifyPhone(String phoneNumber) async {
    try {
      _errorMessage = null;
      _isLoading = true;
      notifyListeners();

      // Use Completers to wait for async callbacks
      final verificationIdCompleter = Completer<String>();
      final errorCompleter = Completer<FirebaseAuthException>();
      final autoVerifiedCompleter = Completer<bool>();

      await _authRepository.verifyPhone(
        phoneNumber,
        onCodeSent: (verificationId) {
          if (!verificationIdCompleter.isCompleted) {
            verificationIdCompleter.complete(verificationId);
          }
        },
        onError: (error) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
        onAutoVerified: () {
          if (!autoVerifiedCompleter.isCompleted) {
            autoVerifiedCompleter.complete(true);
          }
        },
      );

      // Wait for either code sent, error, or auto-verification (with timeout)
      String? receivedVerificationId;
      FirebaseAuthException? receivedError;
      bool autoVerified = false;

      try {
        // Wait for error first (if it fails quickly)
        receivedError = await errorCompleter.future.timeout(
          const Duration(seconds: 2),
        );
      } on TimeoutException {
        // No error within 2 seconds, continue waiting for verification ID
      } catch (_) {
        // Other error, ignore
      }

      if (receivedError != null) {
        // Check if user was auto-verified despite error
        if (_authRepository.firebaseUser != null) {
          autoVerified = true;
        } else {
          _isLoading = false;
          notifyListeners();
          _errorMessage = 'Verification failed: ${receivedError.message}';
          return false;
        }
      }

      if (!autoVerified) {
        // Wait for verification ID or auto-verification
        try {
          final result = await Future.any([
            verificationIdCompleter.future.then((id) => ('id', id)),
            autoVerifiedCompleter.future.then((_) => ('auto', true)),
          ]).timeout(const Duration(seconds: 30));

          if (result.$1 == 'auto') {
            autoVerified = true;
          } else {
            receivedVerificationId = result.$2 as String?;
          }
        } on TimeoutException {
          // Final fallback: check if user is already authenticated
          if (_authRepository.firebaseUser != null) {
            autoVerified = true;
          } else {
            _isLoading = false;
            notifyListeners();
            _errorMessage = 'Verification timed out. Please try again.';
            return false;
          }
        }
      }

      // Handle auto-verification: user is already signed in
      if (autoVerified) {
        _firebaseUser = _authRepository.firebaseUser;
        try {
          final existingUser = await _authRepository.getUserProfile(
            _firebaseUser!.uid,
          );
          _userModel =
              existingUser ??
              UserModel(
                uid: _firebaseUser!.uid,
                name: _firebaseUser!.displayName ?? 'User',
                email: _firebaseUser!.email ?? '',
                phone: Helpers.normalizePhone(_firebaseUser!.phoneNumber) ?? '',
                avatarUrl: null,
                organization: '',
                createdAt: DateTime.now(),
              );
        } catch (_) {
          _userModel = UserModel(
            uid: _firebaseUser!.uid,
            name: _firebaseUser!.displayName ?? 'User',
            email: _firebaseUser!.email ?? '',
            phone: Helpers.normalizePhone(_firebaseUser!.phoneNumber) ?? '',
            avatarUrl: null,
            organization: '',
            createdAt: DateTime.now(),
          );
        }
        _isLoading = false;
        notifyListeners();
        // Return special value: verificationId is null but we're signed in
        _currentVerificationId = null;
        _currentPhoneNumber = phoneNumber;
        return true;
      }

      _isLoading = false;
      notifyListeners();

      if (receivedVerificationId == null) {
        _errorMessage = 'Failed to send verification code';
        return false;
      }

      // Store verification ID for later use
      _currentVerificationId = receivedVerificationId;
      _currentPhoneNumber = phoneNumber;

      return true;
    } catch (e) {
      _errorMessage = 'Verification failed: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Store current verification state
  String? _currentVerificationId;
  String? _currentPhoneNumber;

  String? get currentVerificationId => _currentVerificationId;
  String? get currentPhoneNumber => _currentPhoneNumber;
  Future<bool> registerWithEmail({
    required String name,
    required String email,
    required String password,
    required String mobileNumber, // Now required
    String? organization,
    String? designation,
    File? profileImage,
  }) async {
    try {
      _errorMessage = null;
      _isLoading = true;
      notifyListeners();

      // Real Firebase registration
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      _firebaseUser = credential.user;

      if (_firebaseUser != null) {
        String? avatarUrl;

        if (profileImage != null) {
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('profile_images')
              .child('${_firebaseUser!.uid}.jpg');

          // Downsample before upload: the avatar target is always `${uid}.jpg`,
          // so a compressed JPEG is correct and keeps profile_images tiny.
          // Falls back to the original file when compression isn't smaller.
          final compressed = await LocalStorageService()
              .compressImageForUpload(profileImage);
          if (compressed != null) {
            await storageRef.putData(compressed);
          } else {
            await storageRef.putFile(profileImage);
          }
          avatarUrl = await storageRef.getDownloadURL();
        }

        final newUser = UserModel(
          uid: _firebaseUser!.uid,
          name: name,
          email: email,
          phone: Helpers.normalizePhone(mobileNumber) ?? mobileNumber,
          organization: organization,
          designation: designation,
          mobileNumber: Helpers.normalizePhone(mobileNumber) ?? mobileNumber,
          avatarUrl: avatarUrl,
          createdAt: DateTime.now(),
          isOnApp: true,
          planType: 'free', // Default to free plan
        );

        await _authRepository.createUserProfile(newUser);
        _userModel = newUser;
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _errorMessage = _getAuthErrorMessage(e.code);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = 'Registration failed: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Login with email and password
  Future<bool> loginWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      _errorMessage = null;
      _isLoading = true;
      notifyListeners();

      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      _firebaseUser = credential.user;

      if (_firebaseUser != null) {
        final existingUser = await _authRepository.getUserProfile(
          _firebaseUser!.uid,
        );
        if (existingUser != null) {
          _userModel = existingUser;
        } else {
          final newUser = UserModel(
            uid: _firebaseUser!.uid,
            name: _firebaseUser!.displayName ?? '',
            email: _firebaseUser!.email ?? '',
            phone: Helpers.normalizePhone(_firebaseUser!.phoneNumber) ?? '',
            createdAt: DateTime.now(),
            isOnApp: true,
            planType: 'free', // Default to free plan
          );
          await _authRepository.createUserProfile(newUser);
          _userModel = newUser;
        }
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _errorMessage = _getAuthErrorMessage(e.code);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = 'Login failed: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  String _getAuthErrorMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'This email is already registered.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'operation-not-allowed':
        return 'Email/password accounts are not enabled.';
      case 'weak-password':
        return 'Password should be at least 6 characters.';
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'too-many-requests':
        return 'Too many failed attempts. Try again later.';
      default:
        return 'Authentication failed. Please try again.';
    }
  }

  Future<void> _onAuthStateChanged(User? user) async {
    _firebaseUser = user;
    if (user != null) {
      // Optimistic route: build a provisional profile from cached Auth data
      // so the home screen shows instantly — the Firestore profile + org
      // reads below refresh it in the background instead of gating startup
      if (_userModel == null || _userModel!.uid != user.uid) {
        _userModel = UserModel(
          uid: user.uid,
          name: user.displayName ?? 'User',
          email: user.email ?? '',
          phone: Helpers.normalizePhone(user.phoneNumber) ?? '',
          avatarUrl: user.photoURL,
          organization: '',
          createdAt: DateTime.now(),
        );
        notifyListeners();
      }
      // Local-first gate: hydrate the plan cache and the provisional profile
      // from SQLite before the network read, so paywall limits are correct on a
      // cold start and while offline (the fetch below refreshes + re-persists).
      await _seedPlanFromLocal(user.uid);
      final fetched = await _authRepository.getUserProfile(user.uid);
      // Keep the provisional model if the read failed or the user changed
      if (fetched != null && _firebaseUser?.uid == user.uid) {
        _userModel = fetched;
        // Warm the paywall module-plan cache from the profile we just fetched
        // (no extra Firestore read) so create gates resolve synchronously.
        ModulePlanCache().hydrate(user.uid, fetched.modulePlans);
        // Cache the authoritative server plan for the next cold/offline start.
        await _persistPlanToLocal(fetched);
      }
      await _loadOrgContext();
    } else {
      _userModel = null;
      _org = null;
      _orgMember = null;
      ModulePlanCache().clear();
    }
    notifyListeners();
  }

  /// Load (or refresh) the cached organization context that drives
  /// [effectivePlanType]. Silently degrades to the per-user plan on error.
  Future<void> _loadOrgContext() async {
    final user = _userModel;
    final orgId = user?.orgId;
    if (user == null || orgId == null || orgId.isEmpty) {
      _org = null;
      _orgMember = null;
      return;
    }
    try {
      final results = await Future.wait([
        _orgService.getOrganization(orgId),
        _orgService.getMember(orgId, user.uid),
      ]);
      _org = results[0] as OrganizationModel?;
      _orgMember = results[1] as OrgMemberModel?;
    } catch (_) {
      // Leave any previously cached values; effectivePlanType falls back safely.
    }
  }

  /// Public hook to refresh org context after joining/leaving an org so that
  /// [effectivePlanType] reflects the change immediately.
  Future<void> reloadOrgContext() async {
    // Pull the latest user doc so a newly-set orgId is picked up.
    final uid = _firebaseUser?.uid ?? _userModel?.uid;
    if (uid != null && uid.isNotEmpty) {
      final refreshed = await _authRepository.getUserProfile(uid);
      if (refreshed != null) {
        _userModel = refreshed;
        ModulePlanCache().hydrate(uid, refreshed.modulePlans);
        // Keep the local plan row authoritative for offline cold starts.
        await _persistPlanToLocal(refreshed);
      }
    }
    await _loadOrgContext();
    notifyListeners();
  }

  /// Cold-start / offline plan seed: read the cached plan bundle from SQLite and
  /// feed BOTH consumers of module gating — [ModulePlanCache] (the synchronous
  /// create gates) and the provisional [_userModel] (the UI's
  /// `effectivePlanTypeFor` getter) — so a returning user is gated correctly
  /// before any network reply. A missing row (fresh install) leaves the cache
  /// cold, which stays fail-closed to 'basic' exactly as before.
  Future<void> _seedPlanFromLocal(String uid) async {
    final stored = await LocalDatabaseService().getUserPlan(uid);
    if (stored == null) return;
    ModulePlanCache().hydrate(uid, stored.modulePlans);
    if (_userModel != null && _userModel!.uid == uid) {
      _userModel = _userModel!.copyWith(
        planType: stored.planType,
        planExpiry: stored.planExpiry,
        modulePlans: stored.modulePlans,
      );
      notifyListeners();
    }
  }

  /// Persist the authoritative server profile's plan bundle to SQLite so the
  /// next cold start can gate offline. Never let a write failure block auth —
  /// the following successful fetch re-persists.
  Future<void> _persistPlanToLocal(UserModel u) async {
    try {
      await LocalDatabaseService().saveUserPlan(
        u.uid,
        planType: u.planType,
        planExpiry: u.planExpiry,
        modulePlans: u.modulePlans,
      );
    } catch (_) {
      // Non-fatal by design.
    }
  }

  // Sign in with Google
  Future<bool> signInWithGoogle() async {
    try {
      // Real Firebase sign in with Google
      _isLoading = true;
      notifyListeners();

      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // User cancelled the sign-in
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      _firebaseUser = userCredential.user;

      // Create or update user profile in Firestore
      if (_firebaseUser != null) {
        final existingUser = await _authRepository.getUserProfile(
          _firebaseUser!.uid,
        );
        if (existingUser == null) {
          // New user - create profile with Google data (no mandatory fields)
          final newUser = UserModel(
            uid: _firebaseUser!.uid,
            name: _firebaseUser!.displayName ?? '',
            email: _firebaseUser!.email ?? '',
            phone: Helpers.normalizePhone(_firebaseUser!.phoneNumber) ?? '',
            avatarUrl: _firebaseUser!.photoURL,
            createdAt: DateTime.now(),
            isOnApp: true,
            planType: 'free', // Default to free plan
          );
          await _authRepository.createUserProfile(newUser);
          _userModel = newUser;
        } else {
          _userModel = existingUser;
        }
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      print('Error signing in with Google: $e');

      // Provide more specific error messages
      String errorMsg = 'Google Sign-In failed';
      if (e.toString().contains('DEVELOPER_ERROR')) {
        errorMsg =
            'Google Sign-In not configured. Please add SHA-1 fingerprint to Firebase Console.';
      } else if (e.toString().contains('sign_in_failed')) {
        errorMsg =
            'Google Sign-In failed. Make sure Google is enabled in Firebase Console.';
      } else if (e.toString().contains('network_error')) {
        errorMsg = 'Network error. Please check your internet connection.';
      } else {
        errorMsg = 'Google Sign-In failed: ${e.toString()}';
      }

      _errorMessage = errorMsg;
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Sign out
  Future<void> signOut() async {
    // Flip the UI to the login screen first — nothing below may delay it.
    _firebaseUser = null;
    _userModel = null;
    _org = null;
    _orgMember = null;
    notifyListeners();

    // Stop Firestore listeners and wipe the local cache so the next account
    // on this device never sees this account's tasks/messages/actions.
    try {
      FirebaseService().stopAllSync();
    } catch (e) {
      print('Error stopping syncs on sign out: $e');
    }
    try {
      await LocalDatabaseService().clearSessionData();
    } catch (e) {
      print('Error clearing local data on sign out: $e');
    }

    // Best-effort remote cleanup. Each step is isolated so one failure
    // (offline, no Play services) can never abort the sign-out. The token
    // removal must run before the Firebase sign-out while currentUser exists.
    try {
      await NotificationService().removeTokenForCurrentUser();
    } catch (e) {
      print('Error removing FCM token on sign out: $e');
    }
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      print('Error signing out of Google: $e');
    }
    try {
      await _auth.signOut();
    } catch (e) {
      print('Error signing out of Firebase: $e');
    }
  }

  // Update user profile
  //
  // Deliberately has no planType parameter: premium is granted only by the
  // payment webhook through the Admin SDK, and firestore.rules rejects a client
  // write that changes planType/planExpiry/orgId.
  Future<void> updateProfile({
    String? name,
    String? phone,
    String? organization,
    String? designation,
    String? mobileNumber,
    String? avatarUrl, // Can be a File path or URL
  }) async {
    if (_userModel == null) return;

    _isLoading = true;
    notifyListeners();

    String? finalAvatarUrl = avatarUrl;

    // If avatarUrl is a local file path, upload to Firebase Storage
    if (avatarUrl != null && avatarUrl.startsWith('/')) {
      try {
        final file = File(avatarUrl);
        if (await file.exists()) {
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('profile_images')
              .child('${_userModel!.uid}.jpg');

          // Downsample before upload (same as registration): the target is a
          // fixed `${uid}.jpg`, so a compressed JPEG is always correct.
          final compressed =
              await LocalStorageService().compressImageForUpload(file);
          if (compressed != null) {
            await storageRef.putData(compressed);
          } else {
            await storageRef.putFile(file);
          }
          finalAvatarUrl = await storageRef.getDownloadURL();
          // The Storage path is fixed per user, so a re-uploaded photo keeps
          // the same URL and Flutter's image cache would serve the OLD bitmap.
          // Append a version param so the new photo is fetched immediately.
          final v = DateTime.now().millisecondsSinceEpoch;
          finalAvatarUrl =
              '$finalAvatarUrl${finalAvatarUrl.contains('?') ? '&' : '?'}v=$v';
        }
      } catch (e) {
        debugPrint('Error uploading profile image: $e');
        // Continue with update even if upload fails
      }
    }

    final updatedUser = _userModel!.copyWith(
      name: name,
      phone: phone != null ? (Helpers.normalizePhone(phone) ?? phone) : null,
      organization: organization,
      designation: designation,
      mobileNumber: mobileNumber != null
          ? (Helpers.normalizePhone(mobileNumber) ?? mobileNumber)
          : null,
      avatarUrl: finalAvatarUrl,
    );

    if (!_userModel!.uid.isEmpty) {
      await _authRepository.updateUserProfile(updatedUser);
    }
    _userModel = updatedUser;
    _cacheOwnAvatar(updatedUser);

    _isLoading = false;
    notifyListeners();
  }

  /// After the current user changes their own avatar, refresh the in-memory
  /// [AvatarCacheService] and the SQLite users cache so every card and picker
  /// resolves the new avatar immediately (they read from the cache, not the
  /// AuthProvider model) and it survives an offline restart.
  void _cacheOwnAvatar(UserModel user) {
    AvatarCacheService().upsertUser(
      uid: user.uid,
      phone: user.phone,
      name: user.name,
      url: user.avatarUrl,
    );
    final phone = Helpers.normalizePhone(user.phone) ?? user.phone;
    // The SQLite users table requires a non-empty phone (NOT NULL / UNIQUE).
    if (phone.isNotEmpty) {
      LocalDatabaseService()
          .cacheUsers([
            {
              'uid': user.uid,
              'phone': phone,
              'name': user.name,
              'planType': user.planType,
              'avatarUrl': user.avatarUrl,
            },
          ])
          .catchError((e) => debugPrint('Error caching own avatar: $e'));
    }
  }

  /// Change the phone number on the Firebase Auth account.
  /// This updates the login credential without changing the UID,
  /// so all tasks, messages, and data remain intact. Local SQLite phone
  /// references are re-pointed to the new number so phone-based matching
  /// keeps working.
  Future<void> changePhoneNumber(
    PhoneAuthCredential credential,
    String newPhone,
  ) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No authenticated user');

    final oldPhone = _userModel?.phone ?? '';

    // Update phone on the existing Firebase Auth account (keeps same UID)
    await user.updatePhoneNumber(credential);

    // Update the user model and Firestore profile
    final normalized = Helpers.normalizePhone(newPhone) ?? newPhone;
    final updatedUser = _userModel!.copyWith(
      phone: normalized,
      mobileNumber: normalized,
    );
    await _authRepository.updateUserProfile(updatedUser);

    // Re-point local SQLite phone references (denormalized columns +
    // extraFields JSON) from the old number to the new one.
    if (oldPhone.isNotEmpty && oldPhone != normalized) {
      try {
        await LocalDatabaseService().migrateUserPhone(
          uid: updatedUser.uid,
          oldPhone: oldPhone,
          newPhone: normalized,
        );
      } catch (e) {
        debugPrint('[PhoneSwitch] Local migration failed: $e');
      }
    }
    _cacheOwnAvatar(updatedUser);

    _userModel = updatedUser;
    _firebaseUser = _auth.currentUser;
    notifyListeners();
  }

  /// Update just the user's name (used after phone auth). Optionally sets
  /// a preset avatar (`avatar:<id>` string) chosen during onboarding.
  Future<void> updateUserName(String name, {String? avatarUrl}) async {
    if (_userModel == null) return;

    final updatedUser = _userModel!.copyWith(
      name: name,
      avatarUrl: avatarUrl ?? _userModel!.avatarUrl,
    );

    if (_userModel!.uid.isNotEmpty) {
      await _authRepository.updateUserProfile(updatedUser);
    }
    _userModel = updatedUser;
    _cacheOwnAvatar(updatedUser);
    notifyListeners();
  }
}
