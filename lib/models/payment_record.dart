import 'package:cloud_firestore/cloud_firestore.dart';

/// A read-only payment record for an organization's subscription.
/// Stored in `organizations/{orgId}/payments/{paymentId}`.
///
/// Website-owned (written via Admin SDK). The app only displays these to
/// admins; all client writes are denied by security rules.
class PaymentRecord {
  final String id;
  final num amount;
  final String currency;
  final String method; // e.g. 'card', 'upi', 'bank_transfer'
  final String transactionId;
  final String? invoiceUrl;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final String status; // 'paid' | 'pending' | 'failed' | 'refunded'
  final DateTime createdAt;

  PaymentRecord({
    required this.id,
    required this.amount,
    required this.currency,
    required this.method,
    required this.transactionId,
    this.invoiceUrl,
    this.periodStart,
    this.periodEnd,
    required this.status,
    required this.createdAt,
  });

  factory PaymentRecord.fromMap(Map<String, dynamic> map, String id) {
    return PaymentRecord(
      id: id,
      amount: (map['amount'] as num?) ?? 0,
      currency: map['currency'] ?? 'INR',
      method: map['method'] ?? '',
      transactionId: map['transactionId'] ?? '',
      invoiceUrl: map['invoiceUrl'],
      periodStart: (map['periodStart'] as Timestamp?)?.toDate(),
      periodEnd: (map['periodEnd'] as Timestamp?)?.toDate(),
      status: map['status'] ?? 'paid',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
