import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:random_avatar/random_avatar.dart';
import '../utils/avatar_presets.dart';

/// Shared avatar circle used by cards, pickers and headers.
///
/// Resolves [avatarUrl] in priority order:
/// - `avatar:mav:<seed>` → locally-generated multiavatar character (SVG)
/// - `avatar:<id>` preset → emoji on its tinted circle (fully local)
/// - http(s) URL → network photo, falling back to initials on load error
/// - null/empty/unknown → tinted initials circle (existing style)
class AppAvatar extends StatefulWidget {
  final String? avatarUrl;
  final String initials;
  final double radius;

  /// Fallback tint: circle background at 15% opacity + initials color.
  final Color color;
  final double? fontSize;

  const AppAvatar({
    super.key,
    required this.avatarUrl,
    required this.initials,
    required this.radius,
    required this.color,
    this.fontSize,
  });

  @override
  State<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends State<AppAvatar> {
  bool _imageFailed = false;

  /// Multiavatar widgets are generated from the seed and SVG-parsed on every
  /// build — the heaviest per-card cost in the task lists. Returning the
  /// SAME widget instance for a repeated seed+size lets Flutter skip the
  /// subtree rebuild entirely. Bounded so memory stays flat on long lists.
  static final Map<String, Widget> _mavCache = {};
  static const int _mavCacheMax = 256;

  @override
  void didUpdateWidget(AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarUrl != widget.avatarUrl) _imageFailed = false;
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.avatarUrl;

    // Multiavatar character — generated on-device from the seed (no network).
    final seed = AvatarPresets.mavSeed(url);
    if (seed != null) {
      final d = widget.radius * 2;
      final key = '$seed:$d';
      final hit = _mavCache[key];
      if (hit != null) return hit;
      final avatar = ClipOval(
        child: SizedBox(
          width: d,
          height: d,
          child: RandomAvatar(seed, height: d, width: d),
        ),
      );
      if (_mavCache.length >= _mavCacheMax) {
        _mavCache.remove(_mavCache.keys.first);
      }
      _mavCache[key] = avatar;
      return avatar;
    }

    final preset = AvatarPresets.byUrl(url);
    if (preset != null) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: preset.color.withOpacity(0.15),
        child: Text(
          preset.emoji,
          style: TextStyle(fontSize: widget.radius * 1.05, height: 1.0),
        ),
      );
    }

    final isNetwork =
        !_imageFailed && url != null && url.startsWith('http');
    if (isNetwork) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: widget.color.withOpacity(0.15),
        // Disk-cached: persists across restarts, no re-download on scroll,
        // unlike a bare NetworkImage (in-memory only). Tint shows while loading.
        backgroundImage: CachedNetworkImageProvider(url),
        onBackgroundImageError: (_, __) {
          if (mounted) setState(() => _imageFailed = true);
        },
      );
    }

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: widget.color.withOpacity(0.15),
      child: Text(
        widget.initials,
        style: TextStyle(
          color: widget.color,
          fontWeight: FontWeight.w600,
          fontSize: widget.fontSize ?? widget.radius * 0.7,
        ),
      ),
    );
  }
}
