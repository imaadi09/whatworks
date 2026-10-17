import 'package:flutter/widgets.dart';

/// Shared visibility-gating for tabs embedded in a home [IndexedStack].
///
/// The home [IndexedStack] keeps every visited tab mounted, so a hidden tab
/// must NOT re-run its expensive queries (a full tasks/enquiries scan) on every
/// sync notification — that is what froze the UI when several tabs were alive
/// at once. Instead a hidden tab calls [deferRefresh] from its table-change /
/// provider listener, and this mixin replays exactly one [onTabBecameActive]
/// when the tab turns visible again.
///
/// The host widget must expose an `isActive` flag (default true so a full-screen
/// push always stays live); the host State wires [isActiveTab] to it. Dart
/// cannot mix in a constructor parameter, so `isActive` stays declared on each
/// widget — only the gating logic lives here.
///
/// Usage:
/// ```dart
/// class _MyTabState extends State<MyTab> with VisibilityGatedTabState {
///   @override
///   bool get isActiveTab => widget.isActive;
///   @override
///   void onTabBecameActive() => setState(() => _future = null);
///   // in the table-change / provider listener:
///   //   if (isTabHidden) { deferRefresh(); return; }
/// }
/// ```
///
/// Apply the mixin AFTER any other State mixin in the `with` clause (e.g.
/// `with SingleTickerProviderStateMixin, VisibilityGatedTabState`) so its
/// [initState] / [didUpdateWidget] sit closest to [State] and always run.
mixin VisibilityGatedTabState<T extends StatefulWidget> on State<T> {
  /// Whether the hosting tab is the currently-visible one. Wire this to the
  /// host widget's `isActive` field.
  bool get isActiveTab;

  /// Called once when the tab becomes visible with a deferred refresh pending.
  /// Do the heavy catch-up reload here (re-fetch the list / invalidate a
  /// cached future). This runs inside [didUpdateWidget], so wrap a synchronous
  /// state change in `setState` and guard async work with `mounted`.
  void onTabBecameActive();

  // A deferred refresh is waiting to be replayed on the next activation.
  bool _pendingRefresh = false;
  // Last-seen visibility, so the hidden -> visible edge is detected without
  // relying on the concrete widget type exposing `isActive` to this mixin.
  bool _wasActive = true;

  /// True while the tab is hidden — listeners should [deferRefresh] instead of
  /// reloading.
  bool get isTabHidden => !isActiveTab;

  /// Remember to catch up when the tab is shown again.
  void deferRefresh() => _pendingRefresh = true;

  @override
  void initState() {
    super.initState();
    _wasActive = isActiveTab;
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = isActiveTab;
    // Became visible with a deferred refresh pending → catch up exactly once.
    if (active && !_wasActive && _pendingRefresh) {
      _pendingRefresh = false;
      onTabBecameActive();
    }
    _wasActive = active;
  }
}
