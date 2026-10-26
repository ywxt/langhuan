// Reader theme integration test.
//
// Runs the real app, Rust hub, router, reader and a hermetic JavaScript feed on an
// Android device. It exercises the real Dark-to-Custom workflow that once
// failed while the reader theme was changing.
//
// Preserve emulator app data when running manually:
//
//   flutter test integration_test/reader_theme_test.dart \
//     -d emulator-5554 --no-uninstall

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/app.dart';
import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_bottom_bar.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/router/app_router.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixture_feed.dart';

const _feedId = 'reader-theme-fixture';
const _bookId = '1001';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader switches from dark to a persisted custom theme', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await RustLib.init();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path.startsWith('/search')) {
        request.response.write('1');
      } else if (request.uri.path.startsWith('/chapters')) {
        request.response.write('3');
      } else {
        request.response.write('fixture');
      }
      await request.response.close();
    });

    final tmp = await getTemporaryDirectory();
    final dataDir = Directory(
      '${tmp.path}/reader-theme-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    await dataDir.create(recursive: true);
    final loadedFeeds = await AppService.instance.setAppDataDirectory(
      dataDir.path,
    );
    expect(loadedFeeds, 0);

    await installFixtureFeed(
      id: _feedId,
      name: 'Reader Theme Fixture',
      port: server.port,
      dataDir: dataDir,
    );
    final searchResults = await FeedService.instance
        .search(feedId: _feedId, keyword: 'fixture')
        .toList();
    expect(searchResults, hasLength(1));

    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith(
          (ref) async => const AppDataDirectoryResult(feedCount: 1),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(appRouterProvider)
        .goNamed(
          'bookshelf-reader',
          queryParameters: {
            'feedId': _feedId,
            'bookId': _bookId,
            'chapterId': '1',
            'paragraphId': '',
          },
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LanghuanApp(),
      ),
    );
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.byType(ReaderBottomBar));
    expect(tester.takeException(), isNull);

    // Reveal the reader controls and open its real settings bottom sheet.
    await tester.tapAt(tester.getCenter(find.byType(Scaffold).last));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'System'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Dark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Custom'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('reader-theme-color-background')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hue'), findsOneWidget);
    expect(find.text('Saturation'), findsOneWidget);
    expect(find.text('Brightness'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    for (final key in const [
      'reader-theme-color-background-161A20',
      'reader-theme-color-text-F4F4F0',
      'reader-theme-color-accent-315C8A',
    ]) {
      final swatch = find.byKey(ValueKey(key));
      await tester.ensureVisible(swatch);
      await tester.tap(swatch);
      await tester.pump();
    }

    final apply = find.widgetWithText(FilledButton, 'Apply');
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    final settings = container.read(readerSettingsProvider);
    expect(settings.themeMode, ReaderThemeMode.custom);
    expect(settings.customTheme.background, const Color(0xFF161A20));
    expect(settings.customTheme.foreground, const Color(0xFFF4F4F0));
    expect(settings.customTheme.accent, const Color(0xFF315C8A));

    // Let the async SharedPreferences write finish, then verify a fresh
    // provider restores the exact custom theme.
    await tester.pump(const Duration(milliseconds: 100));
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(readerSettingsProvider);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      restored.read(readerSettingsProvider).themeMode,
      ReaderThemeMode.custom,
    );
    expect(
      restored.read(readerSettingsProvider).customTheme.background,
      const Color(0xFF161A20),
    );
  });
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int attempts = 100,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}
