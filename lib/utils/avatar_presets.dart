import 'package:flutter/material.dart';

/// A built-in avatar choice: an emoji on a tinted circle. Rendered entirely
/// locally (no assets, no network) so avatars load instantly everywhere.
class AvatarPreset {
  final String id;
  final String emoji;
  final Color color;

  const AvatarPreset(this.id, this.emoji, this.color);
}

/// Local preset avatar library.
///
/// A chosen preset is stored in the users doc `avatarUrl` field as
/// `avatar:<id>` (instead of a Storage download URL). Every device renders
/// the preset from this table — nothing is uploaded or downloaded, so
/// preset avatars work offline and survive reinstalls for free.
class AvatarPresets {
  AvatarPresets._();

  static const String scheme = 'avatar:';

  static const List<AvatarPreset> all = [
    AvatarPreset('fox', '🦊', Color(0xFFE8590C)),
    AvatarPreset('panda', '🐼', Color(0xFF495057)),
    AvatarPreset('lion', '🦁', Color(0xFFF08C00)),
    AvatarPreset('koala', '🐨', Color(0xFF868E96)),
    AvatarPreset('tiger', '🐯', Color(0xFFE67700)),
    AvatarPreset('owl', '🦉', Color(0xFF795548)),
    AvatarPreset('penguin', '🐧', Color(0xFF1971C2)),
    AvatarPreset('frog', '🐸', Color(0xFF2F9E44)),
    AvatarPreset('monkey', '🐵', Color(0xFF8D6E63)),
    AvatarPreset('unicorn', '🦄', Color(0xFFAE3EC9)),
    AvatarPreset('bear', '🐻', Color(0xFF6D4C41)),
    AvatarPreset('cat', '🐱', Color(0xFFF59F00)),
    AvatarPreset('dog', '🐶', Color(0xFFA87C4F)),
    AvatarPreset('rabbit', '🐰', Color(0xFFE64980)),
    AvatarPreset('butterfly', '🦋', Color(0xFF3B5BDB)),
    AvatarPreset('turtle', '🐢', Color(0xFF099268)),
    AvatarPreset('bee', '🐝', Color(0xFFFAB005)),
    AvatarPreset('whale', '🐳', Color(0xFF1098AD)),
    AvatarPreset('rocket', '🚀', Color(0xFF5F3DC4)),
    AvatarPreset('star', '⭐', Color(0xFFF08C00)),
    AvatarPreset('rainbow', '🌈', Color(0xFF12B886)),
    AvatarPreset('sun', '🌞', Color(0xFFE8890C)),
    AvatarPreset('guitar', '🎸', Color(0xFFC2255C)),
    AvatarPreset('football', '⚽', Color(0xFF37B24D)),
  ];

  static final Map<String, AvatarPreset> _byId = {
    for (final p in all) p.id: p,
  };

  /// True when [url] is a preset reference (`avatar:<id>`).
  static bool isPreset(String? url) => url != null && url.startsWith(scheme);

  /// The preset referenced by an `avatar:<id>` string, or null.
  static AvatarPreset? byUrl(String? url) {
    if (!isPreset(url)) return null;
    return _byId[url!.substring(scheme.length)];
  }

  /// The `avatar:<id>` string to store for [preset].
  static String urlFor(AvatarPreset preset) => '$scheme${preset.id}';

  // ---------------------------------------------------------------------------
  // Multiavatar (illustrated character) library.
  //
  // A chosen character is stored in `avatarUrl` as `avatar:mav:<seed>`. The
  // `random_avatar` package regenerates the exact same SVG on every device
  // from the seed — nothing is uploaded or downloaded, so these work offline,
  // sync as a tiny string, and render identically on the counterpart's device.
  // ---------------------------------------------------------------------------

  static const String mavScheme = 'avatar:mav:';

  /// True when [url] is a multiavatar reference (`avatar:mav:<seed>`).
  static bool isMultiavatar(String? url) =>
      url != null && url.startsWith(mavScheme);

  /// The seed of an `avatar:mav:<seed>` string, or null.
  static String? mavSeed(String? url) =>
      isMultiavatar(url) ? url!.substring(mavScheme.length) : null;

  /// The `avatar:mav:<seed>` string to store for [seed].
  static String mavUrlFor(String seed) => '$mavScheme$seed';

  /// Curated seeds shown in the avatar picker. Each distinct seed yields a
  /// distinct multicultural character, so the picker offers real variety
  /// while the stored value stays a short deterministic string.
  static const List<String> mavSeeds = [
    'Aria', 'Kai', 'Zara', 'Milo', 'Nova', 'Rex',
    'Luna', 'Finn', 'Sage', 'Ravi', 'Ivy', 'Leo',
    'Mira', 'Otis', 'Yuki', 'Dante', 'Nia', 'Pablo',
    'Suki', 'Omar', 'Wren', 'Enzo', 'Tara', 'Cruz',
    'Elsa', 'Jax', 'Priya', 'Bodhi', 'Zoe', 'Hugo',
    'Amara', 'Niko', 'Freya', 'Kofi', 'Indira', 'Theo',
  ];
}
