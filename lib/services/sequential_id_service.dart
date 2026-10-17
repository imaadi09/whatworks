import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Service to generate sequential display IDs for tasks and sales enquiries.
/// Uses Firestore counter documents with transactions for atomic increments.
class SequentialIdService {
  static final SequentialIdService _instance = SequentialIdService._internal();
  factory SequentialIdService() => _instance;
  SequentialIdService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Get the next sequential ID for a given counter type ('task', 'sales' or
  /// 'crm'). The counter is namespaced per acting user (`<type>_<uid>`) so the
  /// display # is a per-user, per-module sequence (each user's first task is
  /// #1000, second #1001, ...) rather than one global stream. Falls back to a
  /// shared 'global' bucket if nobody is signed in (shouldn't happen in-app).
  /// Returns a 4-digit number (starts at 1000, increments atomically).
  Future<int> getNextId(String counterType) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'global';
    final counterRef =
        _firestore.collection('app_counters').doc('${counterType}_$uid');

    return await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(counterRef);

      int currentValue;
      if (!snapshot.exists) {
        // Start at 1000 for 4-digit display
        currentValue = 1000;
        transaction.set(counterRef, {'currentValue': currentValue});
      } else {
        currentValue = (snapshot.data()?['currentValue'] ?? 999) as int;
        currentValue += 1;
        transaction.update(counterRef, {'currentValue': currentValue});
      }

      return currentValue;
    });
  }

  /// Format the display ID as a 4+ digit string (e.g., 1000 -> "#1000").
  static String formatId(int? id) {
    if (id == null) return '';
    return '#$id';
  }
}
