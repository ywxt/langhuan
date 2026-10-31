import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/utils/app_log.dart';

final searchHistoryProvider =
    AsyncNotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

/// Search keywords are local UI preferences, independent from result streams.
class SearchHistoryNotifier extends AsyncNotifier<List<String>> {
  static const storageKey = 'book_search_history';
  static const maxEntries = 20;
  late SharedPreferences _preferences;
  Future<void> _pending = Future.value();

  @override
  Future<List<String>> build() async {
    _preferences = await SharedPreferences.getInstance();
    return _normalize(_preferences.getStringList(storageKey) ?? []);
  }

  Future<void> record(String keyword) {
    final term = keyword.trim();
    if (term.isEmpty) return Future.value();
    return _update((items) => [term, ...items.where((item) => item != term)]);
  }

  Future<void> remove(String keyword) =>
      _update((items) => items.where((item) => item != keyword).toList());

  Future<void> clear() => _update((_) => []);

  Future<void> _update(List<String> Function(List<String>) change) {
    // Serialize edits, including those made while preferences are loading.
    _pending = _pending.then((_) async {
      try {
        final current = await future;
        if (!ref.mounted) return;
        final next = _normalize(change(current));
        state = AsyncData(next);
        await _preferences.setStringList(storageKey, next);
      } catch (error, stackTrace) {
        // Saving history must not interrupt a search or expose its keyword.
        AppLog.warning(
          'search.history',
          'could not update search history',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
    return _pending;
  }

  static List<String> _normalize(Iterable<String> items) => List.unmodifiable(
    items
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .take(maxEntries),
  );
}
