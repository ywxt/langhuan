import 'package:flutter/material.dart';
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

  test('custom reader theme persists across containers', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(readerSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    const custom = ReaderCustomTheme(
      background: Color(0xFF161A20),
      foreground: Color(0xFFF4F4F0),
      accent: Color(0xFF315C8A),
    );
    container.read(readerSettingsProvider.notifier).setCustomTheme(custom);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(readerSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final settings = restored.read(readerSettingsProvider);
    expect(settings.themeMode, ReaderThemeMode.custom);
    expect(settings.customTheme.background, custom.background);
    expect(settings.customTheme.foreground, custom.foreground);
    expect(settings.customTheme.accent, custom.accent);

    final theme = resolveReaderTheme(
      ThemeData.light(),
      settings.themeMode,
      customTheme: settings.customTheme,
    );
    expect(theme.scaffoldBackgroundColor, custom.background);
    expect(theme.colorScheme.onSurface, custom.foreground);
    expect(theme.colorScheme.primary, custom.accent);
  });
}
