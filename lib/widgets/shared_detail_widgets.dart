import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../modules/shared/customer_info.dart';
import '../utils/constants.dart';

/// "Previous <action>: N" note shown inside an action composer dialog so the
/// sender sees how many cards of this type already exist before posting the
/// next one (the chat numbers that card N+1). Renders nothing when N is 0 — a
/// first-time action needs no hint. Same visual language as the long-standing
/// reminder / warning / query notes, tinted with the dialog's own accent.
class PreviousActionHint extends StatelessWidget {
  /// Action display name as the app labels it — the Message Actions tile /
  /// catalog label, e.g. 'Follow Up', 'Meeting', 'Blocker'.
  final String label;
  final int count;
  final Color color;

  /// Optional leading glyph (usually the action card's own emoji).
  final String emoji;

  const PreviousActionHint({
    super.key,
    required this.label,
    required this.count,
    required this.color,
    this.emoji = '',
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0 || label.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        emoji.isEmpty
            ? 'Previous $label: $count'
            : '$emoji Previous $label: $count',
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Reusable person info card (Created By, Assigned To, etc.)
/// Used in both Task Detail and Sales Detail screens.
class PersonCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String name;
  final Color color;

  const PersonCard({
    super.key,
    required this.icon,
    required this.label,
    required this.name,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Borderless iOS grouped style: caption label over a semibold value.
    final theme = Theme.of(context);
    final captionColor =
        theme.textTheme.bodySmall?.color ?? AppTheme.tertiaryLabel;
    final valueColor = theme.textTheme.bodyMedium?.color ?? AppTheme.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: captionColor,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Reusable date info card (Start Date, Deadline, Created, etc.)
/// Used in both Task Detail and Sales Detail screens.
class DateCard extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String date;
  final Color color;

  const DateCard({
    super.key,
    this.icon,
    required this.label,
    required this.date,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Borderless iOS grouped style: caption label over a semibold value.
    final theme = Theme.of(context);
    final captionColor =
        theme.textTheme.bodySmall?.color ?? AppTheme.tertiaryLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: captionColor,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                date,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Reusable date separator for chat messages.
/// Shows "Today", "Yesterday", day name (within 7 days), or full date.
/// Used in both Task Detail and Sales Detail screens.
class DateSeparator extends StatelessWidget {
  final DateTime date;

  const DateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    String label;
    if (msgDate == today) {
      label = 'Today';
    } else if (msgDate == yesterday) {
      label = 'Yesterday';
    } else {
      final diff = today.difference(msgDate).inDays;
      if (diff <= 7) {
        label = DateFormat('EEEE').format(date);
      } else {
        label = DateFormat('MMMM d, yyyy').format(date);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: AppTheme.lightText.withOpacity(0.2),
              thickness: 1,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.secondaryText,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: AppTheme.lightText.withOpacity(0.2),
              thickness: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact, expandable customer/contact section shared by Task, Sales and CRM
/// cards AND detail screens. Takes a module-agnostic [CustomerInfo] (never a
/// concrete model), so it drops into any screen without touching the
/// `WorkItem` or `TaskModel` interfaces.
///
/// Renders NOTHING when [CustomerInfo.hasAny] is false, so items with no
/// customer stay pixel-identical to before. Collapsed shows one row
/// (name • phone) + a chevron; expanding reveals the remaining fields and the
/// Call / WhatsApp / Copy / Save-contact action buttons. Every action is
/// supplied by the caller (usually wired to `CustomerCommsService`), keeping
/// this widget pure presentation. [onEdit] is optional — cards omit it so the
/// section stays read-only (editing lives on the detail screens).
class CustomerCardSection extends StatelessWidget {
  final CustomerInfo info;
  final bool expanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onCall;
  final VoidCallback? onWhatsApp;
  final VoidCallback? onCopy;
  final VoidCallback? onSave;
  final VoidCallback? onEdit;
  final Color accentColor;

  const CustomerCardSection({
    super.key,
    required this.info,
    this.expanded = false,
    this.onToggleExpand,
    this.onCall,
    this.onWhatsApp,
    this.onCopy,
    this.onSave,
    this.onEdit,
    this.accentColor = AppTheme.accent,
  });

  @override
  Widget build(BuildContext context) {
    if (!info.hasAny) return const SizedBox.shrink();
    // Standalone themed sub-card so the customer block reads as its own
    // section on the grouped canvas (iOS-style tinted surface + accent border).
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: AnimatedCrossFade(
        duration: const Duration(milliseconds: 180),
        crossFadeState: expanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        firstChild: _collapsedRow(),
        secondChild: _expandedBlock(),
      ),
    );
  }

  Widget _collapsedRow() {
    final canToggle = onToggleExpand != null;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.person_outline, size: 18, color: accentColor),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              info.hasName ? info.name : 'Customer',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.label,
              ),
            ),
          ),
          if (info.hasPhone)
            Flexible(
              child: Text(
                '  • ${info.phone}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.secondaryLabel,
                ),
              ),
            ),
          const Spacer(),
          if (canToggle)
            const Icon(Icons.expand_more, size: 18, color: AppTheme.lightText),
        ],
      ),
    );
    if (!canToggle) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggleExpand,
      child: row,
    );
  }

  Widget _expandedBlock() {
    final canToggle = onToggleExpand != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canToggle ? onToggleExpand : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.person_outline, size: 18, color: accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    info.hasName ? info.name : 'Customer',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.label,
                    ),
                  ),
                ),
                if (onEdit != null)
                  InkWell(
                    onTap: onEdit,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.edit_outlined,
                        size: 15,
                        color: AppTheme.secondaryText,
                      ),
                    ),
                  ),
                if (canToggle)
                  const Icon(
                    Icons.expand_less,
                    size: 18,
                    color: AppTheme.lightText,
                  ),
              ],
            ),
          ),
        ),
        if (info.hasPhone) _detailLine(Icons.call, info.phone),
        if (info.hasEmail) _detailLine(Icons.email_outlined, info.email),
        if (info.hasCompany) _detailLine(Icons.business_outlined, info.company),
        if (info.hasAddress)
          _detailLine(Icons.location_on_outlined, info.address),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            if (info.hasPhone && onCall != null)
              _actionButton(Icons.call, 'Call', accentColor, onCall!),
            if (info.hasPhone && onWhatsApp != null)
              _actionButton(
                Icons.chat,
                'WhatsApp',
                AppTheme.primaryGreen,
                onWhatsApp!,
              ),
            if (info.hasPhone && onCopy != null)
              _actionButton(
                Icons.copy_rounded,
                'Copy',
                AppTheme.secondaryText,
                onCopy!,
              ),
            if (onSave != null)
              _actionButton(
                Icons.person_add_alt_1,
                'Save',
                AppTheme.secondaryText,
                onSave!,
              ),
          ],
        ),
      ],
    );
  }

  Widget _detailLine(IconData icon, String value) {
    return Padding(
      padding: const EdgeInsets.only(left: 22, top: 1, bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppTheme.tertiaryLabel),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single dialog for editing all five customer fields at once. Generalises the
/// old sales name-only inline edit so Task, Sales and CRM share ONE editor.
/// Resolves to the edited [CustomerInfo] (or null when cancelled) — the caller
/// maps it onto its own persist call and logs a "changed customer …" message.
class CustomerEditDialog extends StatefulWidget {
  final CustomerInfo initial;
  final Color accentColor;

  /// Customers already used on this module's cards. When non-empty the dialog
  /// shows a "Search saved customers" button that opens a searchable picker
  /// (match by name OR company); tapping a result autofills all five fields so
  /// an existing customer is reused verbatim instead of retyped. Supplied by
  /// each caller from its own loaded items (per-module, not a global directory).
  final List<CustomerInfo> existingCustomers;

  const CustomerEditDialog({
    super.key,
    required this.initial,
    this.accentColor = AppTheme.accent,
    this.existingCustomers = const [],
  });

  /// Convenience launcher — resolves to the edited info, or null if cancelled.
  static Future<CustomerInfo?> show(
    BuildContext context, {
    required CustomerInfo initial,
    Color accentColor = AppTheme.accent,
    List<CustomerInfo> existingCustomers = const [],
  }) {
    return showDialog<CustomerInfo>(
      context: context,
      builder: (_) => CustomerEditDialog(
        initial: initial,
        accentColor: accentColor,
        existingCustomers: existingCustomers,
      ),
    );
  }

  @override
  State<CustomerEditDialog> createState() => _CustomerEditDialogState();
}

class _CustomerEditDialogState extends State<CustomerEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.initial.phone,
  );
  late final TextEditingController _email = TextEditingController(
    text: widget.initial.email,
  );
  late final TextEditingController _company = TextEditingController(
    text: widget.initial.company,
  );
  late final TextEditingController _address = TextEditingController(
    text: widget.initial.address,
  );

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _company.dispose();
    _address.dispose();
    super.dispose();
  }

  void _applyCustomer(CustomerInfo c) {
    // Fill every field from the saved customer; the user can still tweak any
    // of them before saving.
    setState(() {
      _name.text = c.name;
      _phone.text = c.phone;
      _email.text = c.email;
      _company.text = c.company;
      _address.text = c.address;
    });
  }

  /// Open the searchable saved-customer picker and autofill from the choice.
  Future<void> _openSavedCustomerPicker() async {
    final picked = await showDialog<CustomerInfo>(
      context: context,
      builder: (_) => _SavedCustomerPicker(
        customers: widget.existingCustomers,
        accentColor: widget.accentColor,
      ),
    );
    if (picked != null) _applyCustomer(picked);
  }

  void _submit() {
    Navigator.pop(
      context,
      CustomerInfo(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        address: _address.text.trim(),
        company: _company.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Customer details',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Reuse an already-saved customer (per-module): a single search
            // button that opens the name/company picker; tapping a result
            // autofills all five fields.
            if (widget.existingCustomers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openSavedCustomerPicker,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Search saved customers'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: widget.accentColor,
                      side: BorderSide(color: widget.accentColor),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ),
            _field(
              controller: _name,
              label: 'Name',
              icon: Icons.person_outline,
              capitalization: TextCapitalization.words,
            ),
            _field(
              controller: _phone,
              label: 'Phone',
              icon: Icons.call,
              keyboardType: TextInputType.phone,
              maxLength: 24,
            ),
            _field(
              controller: _email,
              label: 'Email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
            ),
            _field(
              controller: _company,
              label: 'Company',
              icon: Icons.business_outlined,
              capitalization: TextCapitalization.words,
            ),
            _field(
              controller: _address,
              label: 'Address',
              icon: Icons.location_on_outlined,
              capitalization: TextCapitalization.sentences,
              maxLength: 240,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.accentColor,
            foregroundColor: Colors.white,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextCapitalization capitalization = TextCapitalization.none,
    TextInputType? keyboardType,
    int maxLength = 100,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        maxLength: maxLength,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20),
          counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: widget.accentColor, width: 2),
          ),
        ),
      ),
    );
  }
}

/// Searchable picker over the module's already-saved customers. Opens from the
/// "Search saved customers" button in [CustomerEditDialog]; filters by name OR
/// company as the user types and resolves to the tapped customer (null when
/// dismissed) so the editor can autofill all five fields.
class _SavedCustomerPicker extends StatefulWidget {
  final List<CustomerInfo> customers;
  final Color accentColor;

  const _SavedCustomerPicker({
    required this.customers,
    required this.accentColor,
  });

  @override
  State<_SavedCustomerPicker> createState() => _SavedCustomerPickerState();
}

class _SavedCustomerPickerState extends State<_SavedCustomerPicker> {
  final TextEditingController _query = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<CustomerInfo> get _matches {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return widget.customers;
    return widget.customers
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.company.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Pick a saved customer',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Search by name or company',
                prefixIcon: const Icon(Icons.search, size: 20),
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.accentColor, width: 2),
                ),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? const Center(
                      child: Text(
                        'No matching customer',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.lightText,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: matches.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = matches[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.person_outline,
                            size: 20,
                            color: widget.accentColor,
                          ),
                          title: Text(
                            c.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: c.company.isEmpty
                              ? null
                              : Text(
                                  c.company,
                                  style: const TextStyle(fontSize: 12),
                                ),
                          onTap: () => Navigator.pop(context, c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
