import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:langhuan/features/bookshelf/search_history_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'history trims, deduplicates, moves repeated searches to the front and persists',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final history = container.read(searchHistoryProvider.notifier);
      await history.record(' first ');
      await history.record('second');
      await history.record('first');
      await history.record('   ');
      expect(await container.read(searchHistoryProvider.future), [
        'first',
        'second',
      ]);
      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      expect(await restored.read(searchHistoryProvider.future), [
        'first',
        'second',
      ]);
    },
  );

  test(
    'rapid changes during initial loading retain their submission order',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final history = container.read(searchHistoryProvider.notifier);
      await Future.wait([
        history.record('first'),
        history.record('second'),
        history.remove('first'),
        history.clear(),
        history.record('last'),
      ]);
      expect(await container.read(searchHistoryProvider.future), ['last']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(SearchHistoryNotifier.storageKey), ['last']);
    },
  );

  test('history is bounded and removal and clearing persist', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final history = container.read(searchHistoryProvider.notifier);
    await Future.wait([for (var i = 0; i < 25; i++) history.record('term$i')]);
    final entries = await container.read(searchHistoryProvider.future);
    expect(entries.length, SearchHistoryNotifier.maxEntries);
    expect(entries.first, 'term24');
    expect(entries.last, 'term5');
    await history.remove('term24');
    expect(
      container.read(searchHistoryProvider).requireValue,
      isNot(contains('term24')),
    );
    await history.clear();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(await restored.read(searchHistoryProvider.future), isEmpty);
  });
}
