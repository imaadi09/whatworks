import 'package:flutter/material.dart';

import '../services/outside_share_service.dart';
import '../utils/app_links.dart';

/// The standalone graphic shared as an image card.
///
/// Deliberately NOT a screen screenshot: fixed 420px width, hard-coded light
/// colours and no Theme lookups, so the PNG looks identical in light and dark
/// mode and stays readable in a WhatsApp chat. It is rendered off-screen by
/// [OutsideShareService.captureCardImage], so it must never depend on inherited
/// layout constraints other than its own width.
class OutsideShareCard extends StatelessWidget {
  final OutsideSharePayload payload;

  /// e.g. `'1.4.2'`; null falls back to just the wordmark.
  final String? appVersion;

  const OutsideShareCard({
    super.key,
    required this.payload,
    this.appVersion,
  });

  static const double cardWidth = 420;

  static const Color _ink = Color(0xFF1F2933);
  static const Color _muted = Color(0xFF6B7280);
  static const Color _bubble = Color(0xFFF4F6F8);
  static const Color _line = Color(0xFFE3E7EB);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: cardWidth,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  payload.title.isEmpty ? 'Untitled' : payload.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 10),
                _details(),
                if (payload.entries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...payload.entries.map(_entry),
                ],
              ],
            ),
          ),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      color: payload.themeColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          const Text(
            'WhatWorks',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          Text(
            payload.displayId != null
                ? '${payload.itemLabel} #${payload.displayId}'
                : payload.itemLabel,
            style: TextStyle(
              color: Colors.white.withOpacity(0.92),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// Two-column From/To and Deadline/Status block; rows with no value collapse.
  Widget _details() {
    final rows = <List<String?>>[];
    final people = <String?>[
      payload.byName.trim().isEmpty ? null : 'From: ${payload.byName}',
      payload.toName.trim().isEmpty ? null : 'To: ${payload.toName}',
    ];
    if (people.any((p) => p != null)) rows.add(people);

    final deadline = payload.deadlineLabel?.trim() ?? '';
    final status = payload.statusLine?.trim() ?? '';
    final meta = <String?>[
      deadline.isEmpty ? null : 'Deadline: $deadline',
      status.isEmpty ? null : 'Status: $status',
    ];
    if (meta.any((m) => m != null)) rows.add(meta);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows.map(_detailRow).toList(),
    );
  }

  Widget _detailRow(List<String?> cells) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: cells
            .map(
              (cell) => Expanded(
                child: Text(
                  cell ?? '',
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: _muted,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  /// One left-aligned chat bubble: sender + time above the text.
  Widget _entry(ShareEntry entry) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: _bubble,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _line, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  entry.senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: payload.themeColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                entry.timeLabel,
                style: const TextStyle(fontSize: 10, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            entry.text,
            style: const TextStyle(fontSize: 12, height: 1.35, color: _ink),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final version = appVersion?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _line, width: 1)),
      ),
      child: Row(
        children: [
          Text(
            version.isEmpty ? 'WhatWorks' : 'WhatWorks v$version',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: _muted,
            ),
          ),
          const Spacer(),
          const Flexible(
            child: Text(
              AppLinks.invite,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: _muted),
            ),
          ),
        ],
      ),
    );
  }
}
