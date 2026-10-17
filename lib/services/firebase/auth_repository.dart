import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/user.dart';
import '../../utils/helpers.dart';

class AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current Firebase user
  User? get firebaseUser => _auth.currentUser;

  // Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Sign in with Phone number
  /// Returns verification ID for SMS code verification
  Future<String> verifyPhone(
    String phoneNumber, {
    required Function(String verificationId) onCodeSent,
    required Function(FirebaseAuthException error) onError,
    Function()? onAutoVerified,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      verificationCompleted: (PhoneAuthCredential credential) async {
        // Auto-verification (some regions/devices)
        try {
          await _auth.signInWithCredential(credential);
          onAutoVerified?.call();
        } catch (e) {
          // Auto-verification failed, SMS flow may still work
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        onError(e);
      },
      codeSent: (String verificationId, int? resendToken) {
        onCodeSent(verificationId);
      },
      codeAutoRetrievalTimeout: (String verificationId) {},
    );
    return ''; // Verification ID is passed via callback
  }

  /// Verify SMS code and sign in
  Future<UserModel?> signInWithSmsCode({
    required String verificationId,
    required String smsCode,
  }) async {
    User? firebaseUser;

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );

      // Sign in — this is the critical auth step
      final userCredential = await _auth.signInWithCredential(credential);
      firebaseUser = userCredential.user;
    } catch (e) {
      // signInWithCredential may fail if auto-verification already signed in,
      // or the code was consumed. Check if user is already authenticated.
      firebaseUser = _auth.currentUser;
      if (firebaseUser == null) rethrow;
    }

    if (firebaseUser == null) return null;

    // Check if user profile exists in Firestore
    try {
      final userDoc = await _firestore
          .collection('users')
          .doc(firebaseUser.uid)
          .get();

      if (userDoc.exists) {
        return UserModel.fromMap(userDoc.data()!, userDoc.id);
      }

      // Create new user profile
      final newUser = UserModel(
        uid: firebaseUser.uid,
        name: firebaseUser.displayName ?? 'User',
        email: firebaseUser.email ?? '',
        phone: Helpers.normalizePhone(firebaseUser.phoneNumber) ?? '',
        avatarUrl: null,
        organization: '',
        createdAt: DateTime.now(),
      );

      await createUserProfile(newUser);

      // Enhancement 6: Auto-link tasks assigned by phone to this new user
      await _linkTasksByPhone(newUser.uid, newUser.phone);

      return newUser;
    } catch (e) {
      // Firestore read/write failed, but user is authenticated.
      // Return a minimal UserModel from Firebase Auth data so login succeeds.
      print(
        'Firestore profile read/write failed (user is still authenticated): $e',
      );
      return UserModel(
        uid: firebaseUser.uid,
        name: firebaseUser.displayName ?? 'User',
        email: firebaseUser.email ?? '',
        phone: Helpers.normalizePhone(firebaseUser.phoneNumber) ?? '',
        avatarUrl: null,
        organization: '',
        createdAt: DateTime.now(),
      );
    }
  }

  /// Get user profile from Firestore
  Future<UserModel?> getUserProfile(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();

      if (doc.exists && doc.data() != null) {
        return UserModel.fromMap(doc.data()!, doc.id);
      }

      return null;
    } catch (e) {
      print('Get user profile error: $e');
      return null;
    }
  }

  /// Create user profile in Firestore
  Future<void> createUserProfile(UserModel user) async {
    try {
      await _firestore.collection('users').doc(user.uid).set(user.toMap());
    } catch (e) {
      print('Create user profile error: $e');
      rethrow;
    }
  }

  /// Update user profile in Firestore.
  ///
  /// Writes [UserModel.toProfileUpdateMap] rather than the full map: billing and
  /// seat fields (planType/planExpiry/orgId) are Admin-SDK-owned, and sending a
  /// stale copy of them here would let a profile edit cancel the user's own
  /// paid plan. firestore.rules rejects such an update anyway.
  Future<void> updateUserProfile(UserModel user) async {
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .update(user.toProfileUpdateMap());
    } catch (e) {
      print('Update user profile error: $e');
      rethrow;
    }
  }

  /// Update user avatar URL
  Future<void> updateAvatar(String uid, String avatarUrl) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'avatarUrl': avatarUrl,
      });
    } catch (e) {
      print('Update avatar error: $e');
      rethrow;
    }
  }

  /// Get all users from Firestore
  Future<List<UserModel>> getAllUsers() async {
    try {
      final snapshot = await _firestore.collection('users').get();
      return snapshot.docs
          .map((doc) => UserModel.fromMap(doc.data(), doc.id))
          .toList();
    } catch (e) {
      print('Get all users error: $e');
      return [];
    }
  }

  /// Stream of user profile changes
  Stream<UserModel?> userProfileStream(String uid) {
    return _firestore.collection('users').doc(uid).snapshots().map((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        return UserModel.fromMap(snapshot.data()!, snapshot.id);
      }
      return null;
    });
  }

  /// Sign out
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (e) {
      print('Sign out error: $e');
      rethrow;
    }
  }

  /// Delete user account
  Future<void> deleteAccount() async {
    try {
      final user = _auth.currentUser;
      if (user != null) {
        // Delete user profile from Firestore
        await _firestore.collection('users').doc(user.uid).delete();

        // Delete Firebase auth account
        await user.delete();
      }
    } catch (e) {
      print('Delete account error: $e');
      rethrow;
    }
  }

  /// Check if user is logged in
  bool get isLoggedIn => _auth.currentUser != null;

  /// Get current user UID
  String? get currentUserId => _auth.currentUser?.uid;

  /// Enhancement 6: Auto-link tasks assigned by phone to a newly registered user.
  /// Finds tasks where assignedToPhone matches and assignedToUid is null,
  /// then updates them with the new user's UID.
  Future<void> _linkTasksByPhone(String uid, String phone) async {
    if (phone.isEmpty) return;
    try {
      final snapshot = await _firestore
          .collection('tasks')
          .where('assignedToPhone', isEqualTo: phone)
          .get();

      if (snapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      int count = 0;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        // Only update tasks that don't already have a UID
        if (data['assignedToUid'] == null || data['assignedToUid'] == '') {
          batch.update(doc.reference, {
            'assignedToUid': uid,
            'updatedAt': DateTime.now(),
          });
          count++;
        }
      }

      if (count > 0) {
        await batch.commit();
        print('Auto-linked $count task(s) to new user $uid (phone: $phone)');
      }
    } catch (e) {
      print('Error linking tasks by phone for new user: $e');
    }
  }
}
