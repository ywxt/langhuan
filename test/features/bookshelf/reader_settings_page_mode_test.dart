import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('page mode defaults to horizontal', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Touch the provider so build() (and its async restore) starts now.
    container.read(readerSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(readerSettingsProvider).pageMode,
      ReaderPageMode.horizontal,
    );
  });

  test('page mode change persists across containers', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Let the initial restore settle before changing anything.
    container.read(readerSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    container
        .read(readerSettingsProvider.notifier)
        .setPageMode(ReaderPageMode.vertical);
    // Let the async persist land.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A fresh container restores from shared preferences.
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(readerSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      restored.read(readerSettingsProvider).pageMode,
      ReaderPageMode.vertical,
    );
  });
}
