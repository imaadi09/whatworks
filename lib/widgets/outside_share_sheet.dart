import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/contact_picker_service.dart';
import '../services/outside_share_service.dart';

/// Opens the "share outside WhatWorks" chooser.
///
/// Returns `null` when the user backed out without sending; otherwise a result
/// describing the channel used. SnackBar + chat logging are the caller's job so
/// each module can log through its own system-message path.
Future<OutsideShareResult?> showOutsideShareSheet(
  BuildContext context, {
  required OutsideSharePayload payload,
}) {
  return showModalBottomSheet<OutsideShareResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _OutsideShareSheet(payload: payload),
  );
}

class _OutsideShareSheet extends StatefulWidget {
  final OutsideSharePayload payload;

  const _OutsideShareSheet({required this.payload});

  @override
  State<_OutsideShareSheet> createState() => _OutsideShareSheetState();
}

class _OutsideShareSheetState extends State<_OutsideShareSheet> {
  static const Color _whatsapp = Color(0xFF25D366);

  late String _recipientName;
  late String? _recipientPhone;

  /// false = text message, true = image card.
  bool _formatIsImage = false;
  bool _sending = false;

  String? _appVersion;
  bool _previewOpen = false;
  bool _capturing = false;
  File? _previewFile;

  @override
  void initState() {
    super.initState();
    _recipientName = widget.payload.recipientName.trim().isEmpty
        ? 'Recipient'
        : widget.payload.recipientName.trim();
    _recipientPhone = (widget.payload.recipientPhone ?? '').trim().isEmpty
        ? null
        : widget.payload.recipientPhone!.trim();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {
      // Footer simply drops the version number.
    }
  }

  /// Device contacts + team members; the picker already offers a manual-number
  /// dialog as its own fallback.
  Future<bool> _pickRecipient() async {
    final contact = await ContactPickerService().showContactPicker(context);
    if (contact == null || !mounted) return false;
    final phone = contact.phone?.trim() ?? '';
    setState(() {
      if (contact.name.trim().isNotEmpty) _recipientName = contact.name.trim();
      _recipientPhone = phone.isEmpty ? null : phone;
    });
    return phone.isNotEmpty;
  }

  /// Renders the card once so the preview and the send share one PNG.
  Future<void> _ensureImagePreview() async {
    if (_previewFile != null || _capturing || !mounted) return;
    setState(() => _capturing = true);
    final file = await OutsideShareService().captureCardImage(
      context,
      widget.payload,
      appVersion: _appVersion,
    );
    if (!mounted) return;
    setState(() {
      _previewFile = file;
      _capturing = false;
    });
  }

  Future<void> _send(String channel) async {
    if (_sending) return;
    final svc = OutsideShareService();
    final usedChannel = _formatIsImage ? 'apps' : channel;

    if (usedChannel != 'apps' && (_recipientPhone ?? '').isEmpty) {
      // No number on the item — ask for one before opening a dead deep link.
      final picked = await _pickRecipient();
      if (!picked) {
        if (!mounted) return;
        _snack('Add a phone number to send this');
        return;
      }
      if (!mounted) return;
    }

    // Read AFTER the picker: _pickRecipient replaces the number in place.
    final phone = _recipientPhone ?? '';

    setState(() => _sending = true);
    var ok = false;
    String? error;
    try {
      if (_formatIsImage) {
        final file =
            _previewFile ??
            await svc.captureCardImage(
              context,
              widget.payload,
              appVersion: _appVersion,
            );
        if (file == null) {
          error = 'Could not create the image card';
        } else {
          ok = await svc.shareImage(file, svc.composeCaption(widget.payload));
          if (!ok) error = 'Share sheet closed without sending';
        }
      } else {
        final text = svc.composeText(widget.payload);
        switch (channel) {
          case 'whatsapp':
            ok = await svc.sendWhatsApp(phone, text);
            if (!ok) error = 'Could not open WhatsApp — is it installed?';
            break;
          case 'sms':
            ok = await svc.sendSMS(phone, text);
            if (!ok) error = 'Could not open the messaging app';
            break;
          default:
            ok = await svc.shareText(text);
            if (!ok) error = 'Share sheet closed without sending';
            break;
        }
      }
    } catch (e) {
      error = 'Could not share: $e';
    }

    if (!mounted) return;
    if (ok) {
      Navigator.pop(
        context,
        OutsideShareResult(
          channel: usedChannel,
          recipientName: _recipientName,
          recipientPhone: _recipientPhone,
          postCount: widget.payload.entries.length,
          success: true,
        ),
      );
      return;
    }
    setState(() => _sending = false);
    _snack(error ?? 'Could not share this post', isError: true);
  }

  void _snack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Share outside WhatWorks',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            "For people who don't have the app",
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionLabel('Send to'),
                      _recipientTile(),
                      const SizedBox(height: 14),
                      _sectionLabel('Format'),
                      _formatTile(
                        title: 'Text message',
                        subtitle: 'Item details + posts as text',
                        icon: Icons.notes_rounded,
                        selected: !_formatIsImage,
                        onTap: () => _setFormat(false),
                      ),
                      _formatTile(
                        title: 'Image card',
                        subtitle: 'A shareable picture of the same details',
                        icon: Icons.image_outlined,
                        selected: _formatIsImage,
                        onTap: () => _setFormat(true),
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel(_formatIsImage ? 'Share' : 'Send via'),
                      ..._channelTiles(),
                      const SizedBox(height: 6),
                      _preview(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _setFormat(bool isImage) {
    if (_sending) return;
    setState(() => _formatIsImage = isImage);
    if (isImage && _previewOpen) _ensureImagePreview();
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6B7280),
        ),
      ),
    );
  }

  Widget _recipientTile() {
    final hasPhone = (_recipientPhone ?? '').isNotEmpty;
    return InkWell(
      onTap: _sending ? null : _pickRecipient,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F6F8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE3E7EB), width: 1),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: widget.payload.themeColor.withOpacity(0.14),
              child: Text(
                _initials(_recipientName),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: widget.payload.themeColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recipientName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    hasPhone ? _recipientPhone! : 'No number — add one',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasPhone
                          ? const Color(0xFF6B7280)
                          : const Color(0xFFE8590C),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _sending ? null : _pickRecipient,
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _formatTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = widget.payload.themeColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: _sending ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: accent.withOpacity(selected ? 0.10 : 0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? accent : const Color(0xFFE3E7EB),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: selected ? accent : Colors.grey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, size: 18, color: accent)
              else
                const Icon(
                  Icons.radio_button_unchecked,
                  size: 18,
                  color: Color(0xFFBFC6CC),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _channelTiles() {
    if (_formatIsImage) {
      return [
        _channelTile(
          label: 'Share image',
          subtitle: 'Opens the system sheet — WhatsApp, SMS, any app',
          icon: Icons.ios_share,
          color: widget.payload.themeColor,
          onTap: () => _send('apps'),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text(
            'A WhatsApp link cannot attach a picture, so image cards always go '
            'through the system share sheet.',
            style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
          ),
        ),
      ];
    }
    final phone = _recipientPhone ?? '';
    return [
      _channelTile(
        label: 'WhatsApp',
        subtitle: phone.isEmpty ? 'Add a number first' : phone,
        icon: Icons.chat,
        color: _whatsapp,
        onTap: () => _send('whatsapp'),
      ),
      _channelTile(
        label: 'SMS',
        subtitle: phone.isEmpty ? 'Add a number first' : phone,
        icon: Icons.sms,
        color: Colors.blue,
        onTap: () => _send('sms'),
      ),
      _channelTile(
        label: 'More apps',
        subtitle: 'System share sheet with the same text',
        icon: Icons.ios_share,
        color: const Color(0xFF495057),
        onTap: () => _send('apps'),
      ),
    ];
  }

  Widget _channelTile({
    required String label,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: _sending ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE3E7EB), width: 1),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    return Theme(
      // Kill the ExpansionTile's default divider lines so it sits inside the
      // sheet like the rest of the rows.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: const Icon(Icons.visibility_outlined, size: 18),
        title: const Text(
          'Preview',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        onExpansionChanged: (open) {
          _previewOpen = open;
          if (open && _formatIsImage) _ensureImagePreview();
        },
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F6F8),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE3E7EB), width: 1),
            ),
            child: _formatIsImage ? _imagePreview() : _textPreview(),
          ),
        ],
      ),
    );
  }

  Widget _textPreview() {
    return SelectableText(
      OutsideShareService().composeText(widget.payload),
      style: const TextStyle(fontSize: 11.5, height: 1.4),
    );
  }

  Widget _imagePreview() {
    final file = _previewFile;
    if (file != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: Image.file(file, fit: BoxFit.contain),
        ),
      );
    }
    if (_capturing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    // Capture failed (or has not been requested yet) — offer a retry instead of
    // a blank box.
    return InkWell(
      onTap: _ensureImagePreview,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            'Tap to build the image preview',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
