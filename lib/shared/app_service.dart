import '../../src/rust/api/app_data.dart' as rust_app_data;
import '../../src/rust/api/cache.dart' as rust_cache;
import '../../src/rust/api/locale.dart' as rust_locale;
import '../../src/rust/api/transfer.dart' as rust_transfer;
import '../../src/rust/api/types.dart'
    show CacheStats, CleanupResult, CoverData;

/// Service for non-feed Rust API calls (locale, app data directory, storage
/// maintenance, etc.).
class AppService {
  AppService._();

  static final AppService instance = AppService._();

  /// Tell Rust which directory should be used as the app data root.
  ///
  /// Returns the number of feeds loaded.
  Future<int> setAppDataDirectory(String path) {
    return rust_app_data.setAppDataDirectory(path: path);
  }

  /// Send the current locale to Rust for i18n.
  Future<void> setLocale(String locale) {
    return rust_locale.setLocale(locale: locale);
  }

  /// Run the full maintenance pass (stale cleanup, script-history pruning,
  /// LRU eviction beyond the size cap).
  ///
  /// Shelved books and their data are always preserved.
  Future<CleanupResult> cleanupStaleData() {
    return rust_cache.cleanupStaleData();
  }

  /// Snapshot of database and cache statistics.
  Future<CacheStats> cacheStats() {
    return rust_cache.cacheStats();
  }

  /// Clear all cache payloads (chapter content, chapter lists, covers).
  ///
  /// The bookshelf, reading progress, and bookmarks are untouched; covers
  /// re-download on demand.
  Future<CleanupResult> clearCache() {
    return rust_cache.clearCache();
  }

  /// Write a standalone snapshot of the whole database (feeds, shelf,
  /// progress, bookmarks) to [path] via `VACUUM INTO`. The caller owns the
  /// file afterwards.
  Future<void> exportBackup({required String path}) {
    return rust_transfer.exportBackup(path: path);
  }

  /// Read the downloaded cover for a book, if one is stored.
  Future<CoverData?> getCover({
    required String feedId,
    required String bookId,
  }) {
    return rust_cache.getCover(feedId: feedId, bookId: bookId);
  }
}
