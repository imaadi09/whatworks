import 'package:cloud_firestore/cloud_firestore.dart';

/// A single milestone on a task/enquiry card — the ONE milestone type shared
/// by Task, Sales and CRM (the former `SalesMilestone` was merged into it).
/// [createdAt] is nullable and only Task populates it; Sales/CRM milestones
/// omit it, so [toMap] writes the key only when present — keeping each
/// module's serialized shape byte-identical to before the merge.
///
/// [toMap] never returns `Timestamp` (the map is jsonEncode'd into SQLite
/// rows), and [fromMap] tolerates Timestamp / int-ms / DateTime so Firestore
/// snapshots and SQLite round trips both decode cleanly.
class MilestoneModel {
  /// Well-known [kind] values — a milestone can be tagged as a payment or a
  /// delivery step so lists can filter "paid yet?" / "delivered yet?" without
  /// depending on the exact title the user chose.
  static const String kindPayment = 'payment';
  static const String kindDelivery = 'delivery';

  final String id;
  final String title;
  final int order;
  final bool isCompleted;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final DateTime? deadline;

  /// 'payment' | 'delivery' | null — set from the milestone template at
  /// creation; the user still ticks completion manually.
  final String? kind;

  MilestoneModel({
    required this.id,
    required this.title,
    this.order = 0,
    this.isCompleted = false,
    this.completedAt,
    this.createdAt,
    this.deadline,
    this.kind,
  });

  /// The tag to filter/render by: the stored [kind], or — for milestones
  /// created before tagging existed — a title hint ('Payment Received',
  /// 'Delivered / Handed Over' …), so old cards filter correctly with no
  /// migration.
  String? get effectiveKind {
    if (kind != null) return kind;
    final t = title.toLowerCase();
    if (t.contains('payment')) return kindPayment;
    if (t.contains('deliver')) return kindDelivery;
    return null;
  }

  // Create from Firestore document or SQLite JSON row
  factory MilestoneModel.fromMap(Map<String, dynamic> map, String id) {
    return MilestoneModel(
      id: id,
      title: map['title'] ?? '',
      order: map['order'] ?? 0,
      isCompleted: map['isCompleted'] ?? false,
      completedAt: _parseDateTime(map['completedAt']),
      createdAt: _parseDateTime(map['createdAt']),
      deadline: _parseDateTime(map['deadline']),
      kind: map['kind'] as String?,
    );
  }

  /// Handles Timestamp (from Firestore), int ms (from JSON/SQLite), or DateTime.
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is DateTime) return value;
    return null;
  }

  // Convert to Firestore document / SQLite JSON
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'order': order,
      'isCompleted': isCompleted,
      'completedAt': completedAt?.millisecondsSinceEpoch,
      if (createdAt != null) 'createdAt': createdAt!.millisecondsSinceEpoch,
      'deadline': deadline?.millisecondsSinceEpoch,
      // Omitted when untagged so existing (Task/Sales/CRM) milestone rows
      // serialize byte-identically to before tagging existed.
      if (kind != null) 'kind': kind,
    };
  }

  // Copy with updates
  MilestoneModel copyWith({
    String? id,
    String? title,
    int? order,
    bool? isCompleted,
    DateTime? completedAt,
    DateTime? createdAt,
    DateTime? deadline,
    String? kind,
  }) {
    return MilestoneModel(
      id: id ?? this.id,
      title: title ?? this.title,
      order: order ?? this.order,
      isCompleted: isCompleted ?? this.isCompleted,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
      deadline: deadline ?? this.deadline,
      kind: kind ?? this.kind,
    );
  }

  /// Collapse duplicate milestones that resolve to the same [id], keeping the
  /// first occurrence's position. Historical data (a legacy double-apply of the
  /// milestone template) left some enquiries carrying the same step many times,
  /// so the pipeline rendered "Initial Contact 1" repeated. Ids are the identity
  /// used everywhere else — toggle/edit match by id and both decoders fall back
  /// to `milestone_<order|index>` — so entries sharing an id ARE the same step.
  /// Entries with an empty id are never collapsed (nothing keys them), and
  /// completion is preserved: if any duplicate was done, the kept one is done.
  /// Read-side and idempotent, so clean data is returned untouched and the next
  /// milestone edit writes the de-duplicated list back, healing Firestore too.
  static List<MilestoneModel> dedupeById(List<MilestoneModel> input) {
    if (input.length < 2) return input;
    final indexOfId = <String, int>{};
    final result = <MilestoneModel>[];
    for (final m in input) {
      if (m.id.isEmpty) {
        result.add(m); // Unkeyed — never collapse.
        continue;
      }
      final at = indexOfId[m.id];
      if (at == null) {
        indexOfId[m.id] = result.length;
        result.add(m);
      } else if (m.isCompleted && !result[at].isCompleted) {
        result[at] = result[at].copyWith(
          isCompleted: true,
          completedAt: m.completedAt,
        );
      }
    }
    return result;
  }
}
