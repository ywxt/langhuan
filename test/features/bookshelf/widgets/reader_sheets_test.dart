import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_sheets.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';

import '../../feeds/fake_feed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final chapters = [
    const ChapterInfoModel(id: 'c1', title: 'The Beginning'),
    const ChapterInfoModel(id: 'c2', title: 'A Dark Road'),
    const ChapterInfoModel(id: 'c3', title: 'The End'),
  ];

  Widget localized(Widget child) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );
  }

  /// A button that opens a sheet with the builder-provided ref/context, so
  /// the test can drive the public sheet functions exactly like a page.
  Widget sheetLauncher(
    Future<void> Function(WidgetRef ref, BuildContext context) onOpen,
  ) {
    return Consumer(
      builder: (context, ref, _) => ElevatedButton(
        onPressed: () => onOpen(ref, context),
        child: const Text('open'),
      ),
    );
  }

  group('showReaderInterfaceSheet layout', () {
    testWidgets('left-aligns the reading mode title with other labels', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        ProviderScope(
          child: localized(
            Scaffold(
              body: sheetLauncher(
                (ref, context) => showReaderInterfaceSheet(context),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final titleLeft = tester.getTopLeft(
        find.byKey(const ValueKey('reader-mode-title')),
      );
      final fontLabelLeft = tester.getTopLeft(find.text('Font File'));
      expect(titleLeft.dx, closeTo(fontLabelLeft.dx, 0.5));
    });
  });

  group('showReaderSettingsSheet theme picker', () {
    testWidgets('shows the current theme and applies a picked one', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerSettingsProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localized(
            Scaffold(
              body: sheetLauncher(
                (ref, context) => showReaderSettingsSheet(context),
              ),
            ),
          ),
        ),
      );
      // Let the notifier's async restore settle before interacting, so it
      // cannot race the tap below.
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The theme row reflects the current (default) mode.
      expect(find.text('Theme'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'System'), findsOneWidget);

      // Open the picker: every option appears (the settings sheet with
      // its own "System" button stays in the tree behind the picker).
      await tester.tap(find.widgetWithText(OutlinedButton, 'System'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'System'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Light'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Dark'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Sepia'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Custom'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'Dark'));
      await tester.pumpAndSettle();

      // Back on the settings sheet, the row shows the new mode, and the
      // provider state agrees.
      expect(find.widgetWithText(OutlinedButton, 'Dark'), findsOneWidget);
      expect(
        container.read(readerSettingsProvider).themeMode,
        ReaderThemeMode.dark,
      );
    });

    testWidgets('custom theme editor previews and applies saved colors', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerSettingsProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localized(
            Scaffold(
              body: sheetLauncher(
                (ref, context) => showReaderSettingsSheet(context),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'System'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Custom'));
      await tester.pumpAndSettle();

      expect(find.text('Custom reader theme'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Text'), findsOneWidget);
      expect(find.text('Accent'), findsOneWidget);
      expect(find.text('Chapter title'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader-theme-color-background')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hue'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('reader-theme-hue-slider')),
        const Offset(40, 0),
      );
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
      await tester.pumpAndSettle();

      final settings = container.read(readerSettingsProvider);
      expect(settings.themeMode, ReaderThemeMode.custom);
      expect(settings.customTheme.background, const Color(0xFF161A20));
      expect(settings.customTheme.foreground, const Color(0xFFF4F4F0));
      expect(settings.customTheme.accent, const Color(0xFF315C8A));
      expect(find.widgetWithText(OutlinedButton, 'Custom'), findsOneWidget);
      expect(find.byTooltip('Custom reader theme'), findsOneWidget);
    });
  });

  group('showReaderTocSheet filter', () {
    testWidgets('filters by title and keeps original numbering', (
      tester,
    ) async {
      final jumps = <String>[];

      await tester.pumpWidget(
        ProviderScope(
          child: localized(
            Scaffold(
              body: sheetLauncher((ref, context) {
                return showReaderTocSheet(
                  context: context,
                  ref: ref,
                  chapters: chapters,
                  onJumpToChapter: jumps.add,
                );
              }),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('The Beginning'), findsOneWidget);
      expect(find.text('A Dark Road'), findsOneWidget);
      expect(find.text('The End'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'dark');
      await tester.pumpAndSettle();

      expect(find.text('A Dark Road'), findsOneWidget);
      expect(find.text('The Beginning'), findsNothing);
      expect(find.text('The End'), findsNothing);
      // Original chapter number, not the filtered position.
      expect(find.text('2'), findsOneWidget);

      // No match renders the query back.
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matching "zzz"'), findsOneWidget);

      // Clearing restores the full list.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('The End'), findsOneWidget);

      // Tapping a filtered result jumps and closes the sheet.
      await tester.enterText(find.byType(TextField), 'dark');
      await tester.pumpAndSettle();
      await tester.tap(find.text('A Dark Road'));
      await tester.pumpAndSettle();

      expect(jumps, ['c2']);
      expect(find.text('A Dark Road'), findsNothing);
    });
  });

  group('showReaderBookmarkSheet filter', () {
    testWidgets('filters across chapter title, name and preview', (
      tester,
    ) async {
      final service = FakeFeedService(
        listBookmarksHandler: (feedId, bookId) async => [
          const BookmarkModel(
            id: 'k1',
            feedId: 'f1',
            bookId: 'b1',
            chapterId: 'c1',
            paragraphId: 'p1',
            paragraphName: 'opening line',
            paragraphPreview: 'It was the best of times',
            label: '',
            createdAtMs: 2,
          ),
          const BookmarkModel(
            id: 'k2',
            feedId: 'f1',
            bookId: 'b1',
            chapterId: 'c2',
            paragraphId: 'p9',
            paragraphName: 'the fallen star',
            paragraphPreview: 'A star fell',
            label: '',
            createdAtMs: 1,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedServiceProvider.overrideWithValue(service)],
          child: localized(
            Scaffold(
              body: sheetLauncher((ref, context) {
                return showReaderBookmarkSheet(
                  context: context,
                  ref: ref,
                  feedId: 'f1',
                  bookId: 'b1',
                  chapters: chapters,
                  onJumpToParagraph: (_, _) {},
                  onBookmarkRemoved: () {},
                );
              }),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('opening line'), findsOneWidget);
      expect(find.text('the fallen star'), findsOneWidget);

      // Match through the paragraph preview…
      await tester.enterText(find.byType(TextField), 'best of times');
      await tester.pumpAndSettle();
      expect(find.text('opening line'), findsOneWidget);
      expect(find.text('the fallen star'), findsNothing);

      // …through the chapter title…
      await tester.enterText(find.byType(TextField), 'dark road');
      await tester.pumpAndSettle();
      expect(find.text('the fallen star'), findsOneWidget);
      expect(find.text('opening line'), findsNothing);

      // …and the no-match case.
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matching "zzz"'), findsOneWidget);
    });

    testWidgets('empty bookmarks still shows the dedicated empty state', (
      tester,
    ) async {
      final service = FakeFeedService(
        listBookmarksHandler: (feedId, bookId) async => [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedServiceProvider.overrideWithValue(service)],
          child: localized(
            Scaffold(
              body: sheetLauncher((ref, context) {
                return showReaderBookmarkSheet(
                  context: context,
                  ref: ref,
                  feedId: 'f1',
                  bookId: 'b1',
                  chapters: chapters,
                  onJumpToParagraph: (_, _) {},
                  onBookmarkRemoved: () {},
                );
              }),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('No bookmarks yet'), findsOneWidget);
    });
  });
}
