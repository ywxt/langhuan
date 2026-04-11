import '../../src/rust/api/app_data.dart' as rust_app_data;
import '../../src/rust/api/cleanup.dart' as rust_cleanup;
import '../../src/rust/api/locale.dart' as rust_locale;

/// Service for non-feed Rust API calls (locale, app data directory, etc.).
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

  /// Clean up stale cache and reading progress data (older than 15 days).
  ///
  /// Books on the bookshelf are preserved. Returns the number of items removed.
  Future<int> cleanupStaleData() {
    return rust_cleanup.cleanupStaleData();
  }
}
