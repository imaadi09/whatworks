/// Shared, module-agnostic customer/contact details attached to a work item
/// (a Task, a Sales enquiry or a CRM record).
///
/// This is the SINGLE SOURCE OF TRUTH for the five customer fields AND their
/// Firestore / SQLite keys, so persistence and the shared UI can never drift:
/// - `TaskModel` and `EnquiryModel` each expose a `customerInfo` getter that
///   returns this object (and a `withCustomerInfo` to persist an edit).
/// - The shared widgets (`CustomerCardSection`, `CustomerEditDialog`) consume
///   a [CustomerInfo] directly, so they never depend on a concrete model type
///   and `WorkItem`/`TaskModel` interfaces stay untouched.
///
/// Field values are always non-null (empty string when unset) so callers never
/// need null-guards; [hasAny]/[hasPhone] drive whether UI is shown at all.
class CustomerInfo {
  final String name;
  final String phone;
  final String email;
  final String address;
  final String company;

  const CustomerInfo({
    this.name = '',
    this.phone = '',
    this.email = '',
    this.address = '',
    this.company = '',
  });

  /// No customer attached.
  static const CustomerInfo empty = CustomerInfo();

  // ── Presence helpers (drive conditional UI so empty items render nothing) ──
  bool get hasName => name.trim().isNotEmpty;
  bool get hasPhone => phone.trim().isNotEmpty;
  bool get hasEmail => email.trim().isNotEmpty;
  bool get hasAddress => address.trim().isNotEmpty;
  bool get hasCompany => company.trim().isNotEmpty;

  /// True when every field is blank.
  bool get isEmpty =>
      !hasName && !hasPhone && !hasEmail && !hasAddress && !hasCompany;

  /// True when at least one field is set (safe to render a customer section).
  bool get hasAny => !isEmpty;

  /// WhatsApp availability mirrors phone presence (wa.me needs a number).
  bool get hasWhatsApp => hasPhone;

  // ── Map / column keys — the ONE place these strings are defined ──────────
  static const String kName = 'clientName';
  static const String kPhone = 'clientPhone';
  static const String kEmail = 'clientEmail';
  static const String kAddress = 'clientAddress';
  static const String kCompany = 'clientCompany';

  /// Firestore / generic map fragment (also used as the SQLite row fragment —
  /// the column names match these keys exactly).
  Map<String, dynamic> toMap() => {
    kName: name,
    kPhone: phone,
    kEmail: email,
    kAddress: address,
    kCompany: company,
  };

  /// Null-safe read from any map (Firestore doc, in-memory update, SQLite row).
  /// Missing or non-string values fall back to an empty string.
  factory CustomerInfo.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CustomerInfo();
    return CustomerInfo(
      name: (map[kName] as String?) ?? '',
      phone: (map[kPhone] as String?) ?? '',
      email: (map[kEmail] as String?) ?? '',
      address: (map[kAddress] as String?) ?? '',
      company: (map[kCompany] as String?) ?? '',
    );
  }

  /// SQLite row fragment — identical keys to [toMap] (columns mirror them).
  Map<String, dynamic> toRow() => toMap();

  /// Read from a SQLite row (same keys as columns).
  factory CustomerInfo.fromRow(Map<String, dynamic> row) =>
      CustomerInfo.fromMap(row);

  CustomerInfo copyWith({
    String? name,
    String? phone,
    String? email,
    String? address,
    String? company,
  }) {
    return CustomerInfo(
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      address: address ?? this.address,
      company: company ?? this.company,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerInfo &&
          name == other.name &&
          phone == other.phone &&
          email == other.email &&
          address == other.address &&
          company == other.company;

  @override
  int get hashCode => Object.hash(name, phone, email, address, company);

  @override
  String toString() =>
      'CustomerInfo(name: $name, phone: $phone, email: $email, '
      'address: $address, company: $company)';
}
