import 'package:flutter/foundation.dart';

/// Shared lazy-loading pagination engine for the SQLite-first list providers.
///
/// Both [TaskProvider] and [BaseModuleProvider] (Sales/CRM) page their card
/// lists off SQLite with the identical state machine: a page cursor, a
/// "has more" flag, an in-flight guard, and a rollback-on-error rule. Only two
/// things differ per module — how a page is *read* and how it is *spliced* into
/// the in-memory lists — so those are the abstract hooks ([fetchPage] and
/// [appendPage]) each provider supplies.
///
/// The module-specific public names (`hasMoreTasks` / `loadMoreTasks`,
/// `hasMoreEnquiries` / `loadMoreEnquiries`) stay as thin delegating wrappers in
/// the providers, so every existing call site keeps working unchanged.
mixin PaginationMixin<T> on ChangeNotifier {
  /// Rows per page. Matches the pre-mixin `_pageSize = 20` both providers used.
  static const int defaultPageSize = 20;

  int _currentPage = 0;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  /// Page size used by both the initial SQLite read and [loadMoreItems].
  int get pageSize => defaultPageSize;

  /// Whether another page is available. Replaces the old per-module
  /// `_hasMoreTasks` / `_hasMoreEnquiries` fields; the change-set paths set it
  /// directly (`hasMoreItems = list.length > pageSize`).
  bool get hasMoreItems => _hasMore;
  set hasMoreItems(bool value) => _hasMore = value;

  /// True while a [loadMoreItems] call is in flight (infinite-scroll guard).
  bool get isLoadingMore => _isLoadingMore;

  /// Extra precondition for [loadMoreItems] — e.g. Task requires a signed-in
  /// user (`_currentUserId.isNotEmpty`). Defaults to true so modules without an
  /// additional guard need no override.
  bool get canLoadMore => true;

  /// Read exactly one page from the local source of truth (SQLite).
  Future<List<T>> fetchPage(int offset, int limit);

  /// Splice a freshly fetched, non-empty page into the provider's in-memory
  /// lists and preload any per-row resources (e.g. action icons). The mixin
  /// calls [notifyListeners] immediately after this returns.
  Future<void> appendPage(List<T> items);

  /// Load the next page (lazy loading / infinite scroll).
  Future<void> loadMoreItems() async {
    if (_isLoadingMore || !_hasMore || !canLoadMore) return;

    _isLoadingMore = true;
    _currentPage++;

    try {
      final items = await fetchPage(_currentPage * pageSize, pageSize);

      if (items.isEmpty || items.length < pageSize) {
        _hasMore = false;
      }

      if (items.isNotEmpty) {
        await appendPage(items);
        notifyListeners();
      }
    } catch (e) {
      _currentPage--; // Rollback page on error
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Record the result of a full (re)load: [loadedCount] is the number of rows
  /// the initial SQLite read returned, so there are further pages iff it
  /// exceeds one page. Replaces the old `_hasMore = n > _pageSize;
  /// _currentPage = 0;` pair and resets the cursor to the first page.
  void markFirstPage(int loadedCount) {
    _hasMore = loadedCount > pageSize;
    _currentPage = 0;
  }

  /// Reset pagination (call when refreshing or changing user/team).
  void resetPagination() {
    _currentPage = 0;
    _hasMore = true;
    _isLoadingMore = false;
  }
}
