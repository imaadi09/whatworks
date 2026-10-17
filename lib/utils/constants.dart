import 'package:flutter/material.dart';

class AppTheme {
  // WhatsApp Primary Colors (exact match)
  static const primaryGreen = Color(0xFF25D366);
  static const darkGreen = Color(0xFF128C7E);
  static const tealGreen = Color(0xFF075E54);
  static const lightGreen = Color(0xFFDCF8C6);

  // WhatsApp Header Colors
  static const headerGreen = Color(0xFF075E54);
  static const headerGreenDark = Color(0xFF1F2C34);

  // Chat Bubble Colors (iOS-style: soft teal outgoing on a neutral canvas)
  static const chatBubbleGreen = Color(0xFFD8EDE7);
  static const chatBubbleWhite = Colors.white;
  static const chatBackground = Color(0xFFF2F2F7);

  /// Theme-aware chat canvas: neutral gray in light mode, near-black in dark.
  static Color chatCanvas(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0E0E10)
          : chatBackground;

  /// Theme-aware primary text colour. [primaryText] is a light-mode ink
  /// (near-black) that renders invisible on a dark card surface, so card
  /// titles/names resolve through here: white in dark mode, [primaryText] in
  /// light. Use this anywhere text sits on a theme-driven (dark-capable)
  /// surface instead of hardcoding the light constant.
  static Color primaryTextOn(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkLabel : primaryText;

  // Background Colors (WhatsApp exact)
  static const lightGrey = Color(0xFFF0F2F5);
  static const backgroundGrey = Color(0xFFEFEAE2);
  static const darkGrey = Color(0xFF667781);
  static const dividerColor = Color(0xFFE9EDEF);

  // Priority Colors
  static const highPriority = Color(0xFFFF6B6B);
  static const midPriority = Color(0xFFFFA94D);
  static const lowPriority = Color(0xFF69DB7C);

  // Urgency Colors
  static const urgent = Color(0xFFE03131);
  static const deadlineNearing = Color(0xFFF59F00);
  static const onTime = Color(0xFF2F9E44);

  // Text Colors (WhatsApp exact)
  static const primaryText = Color(0xFF111B21);
  static const secondaryText = Color(0xFF667781);
  static const lightText = Color(0xFF8696A0);
  static const unreadText = Color(0xFF25D366);

  // System Message
  static const systemMessageBg = Color(0xFFFEF3C7);

  // ── iOS-style design tokens (neutral surfaces + semantic color) ────
  static const accent = Color(0xFF0E7C66); // calm premium teal-green
  static const label = Color(0xFF1C1C1E);
  static const secondaryLabel = Color(0xFF6E6E73);
  static const tertiaryLabel = Color(0xFF8E8E93);
  static const separator = Color(0xFFE5E5EA);
  static const groupedBackground = Color(0xFFF2F2F7);
  static const cardBackground = Colors.white;
  static const success = Color(0xFF34C759);
  static const warning = Color(0xFFFF9500);
  static const destructive = Color(0xFFFF3B30);
  static const blocked = Color(0xFFAF52DE);
  // Calm alert red for attention chips (Warn/Blk/Lost) and the overdue
  // deadline pill — softer than [destructive] so cards stay quiet.
  static const mutedRed = Color(0xFFC0392B);
  static const info = Color(0xFF007AFF);
  // Dark-mode counterparts
  static const darkLabel = Color(0xFFFFFFFF);
  static const darkSecondaryLabel = Color(0x99EBEBF5);
  static const darkTertiaryLabel = Color(0x4DEBEBF5);
  static const darkSeparator = Color(0xFF38383A);
  static const darkGroupedBackground = Color(0xFF000000);
  static const darkCardBackground = Color(0xFF1C1C1E);

  /// Centralized iOS-style type scale (wired into ThemeData.textTheme).
  /// A uniform slight negative [letterSpacing] gives the whole app a more
  /// condensed read without swapping the typeface.
  static TextTheme buildTextTheme(
    Color primary,
    Color secondary,
    Color tertiary,
  ) {
    return TextTheme(
      titleLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.6,
      ),
      titleSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: primary,
        letterSpacing: -0.4,
      ),
      headlineMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: primary,
        letterSpacing: -0.2,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: primary,
        letterSpacing: -0.2,
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: primary,
        letterSpacing: -0.2,
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: primary,
        letterSpacing: -0.2,
      ),
      labelMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: secondary,
        letterSpacing: -0.2,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: secondary,
        letterSpacing: -0.2,
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: tertiary,
        letterSpacing: -0.2,
      ),
    );
  }

  // Standard spacing
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;

  // Border radius
  static const double radiusSm = 8.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 16.0;
  static const double radiusXl = 24.0;

  // App theme data
  static ThemeData get lightTheme {
    return ThemeData(
      primaryColor: accent,
      scaffoldBackgroundColor: groupedBackground,
      cardColor: cardBackground,
      dividerColor: separator,
      textTheme: buildTextTheme(label, secondaryLabel, tertiaryLabel),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        primary: accent,
        secondary: accent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 56,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: spacingLg,
            vertical: spacingMd,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
    );
  }

  // Dark theme — mirrors the WhatsApp-style dark palette (headerGreenDark
  // surfaces, primaryGreen accents) so the app is legible in dark mode.
  static const darkScaffold = Color(0xFF0B141A);
  static const darkSurface = Color(0xFF1F2C34);
  static const darkCard = Color(0xFF202C33);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: accent,
      scaffoldBackgroundColor: darkGroupedBackground,
      canvasColor: darkSurface,
      cardColor: darkCardBackground,
      dividerColor: darkSeparator,
      textTheme: buildTextTheme(darkLabel, darkSecondaryLabel, darkTertiaryLabel),
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accent,
        surface: darkSurface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 56,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: Color(0xFFE9EDEF),
        iconColor: Color(0xFFAEBAC1),
      ),
      dialogTheme: const DialogThemeData(backgroundColor: darkSurface),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: spacingLg,
            vertical: spacingMd,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
    );
  }
}

// Industry templates
class AppConstants {
  static const String appName = 'WhatWorks';

  // Task templates
  static const List<Map<String, String>> taskTemplates = [
    {'title': 'Sales Report', 'icon': '📊', 'category': 'Sales'},
    {'title': 'Customer Delivery', 'icon': '🚚', 'category': 'Logistics'},
    {'title': 'Pick Up Cash', 'icon': '💰', 'category': 'Finance'},
    {'title': 'Make Presentation', 'icon': '📑', 'category': 'Marketing'},
    {'title': 'Steel Stock Check', 'icon': '🏭', 'category': 'Inventory'},
    {'title': 'New Enquiry', 'icon': '📞', 'category': 'Sales'},
    {'title': 'Case Filing', 'icon': '⚖️', 'category': 'Legal'},
    {'title': 'Site Visit', 'icon': '🏗️', 'category': 'Operations'},
    {'title': 'Invoice Generation', 'icon': '🧾', 'category': 'Finance'},
    {'title': 'Quality Check', 'icon': '✅', 'category': 'Operations'},
  ];

  // Quick action chips
  static const List<String> quickActions = [
    'Ask for Update',
    'Need by Today?',
    'Improve it Further',
    'Reminder',
    'Warning',
  ];

  // Filter options
  static const List<String> filterOptions = [
    'All',
    'Deadlines Nearing',
    'Overdue',
    'High Priority',
    'Urgent Only',
    'Longest Pending',
  ];

  // Sort options
  static const List<String> sortOptions = [
    'Deadline',
    'Priority',
    'Latest Activity',
    'Oldest',
  ];

  // Storage limit
  static const int freeStorageLimitMB = 500;

  // Max file size (10 MB)
  static const int maxFileSizeBytes = 10 * 1024 * 1024;
}
