import 'package:flutter/material.dart';

/// App theming.
///
/// The manual Light/Dark/System picker was removed from Settings (user
/// request), so the app now always follows the device's light/dark setting via
/// [ThemeMode.system]. Kept as a [ChangeNotifier] so the existing
/// `Consumer<ThemeProvider>` wiring in main.dart keeps working unchanged.
class ThemeProvider extends ChangeNotifier {
  ThemeMode get themeMode => ThemeMode.system;
}
