import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_bottom_bar.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/theme/app_theme.dart';

void main() {
  testWidgets('reader themes switch without text style errors', (tester) async {
    final themeMode = ValueNotifier(ReaderThemeMode.system);
    addTearDown(themeMode.dispose);
    final baseTheme = LanghuanTheme.light();

    await tester.pumpWidget(
      MaterialApp(
        theme: baseTheme,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          bottomNavigationBar: ValueListenableBuilder<ReaderThemeMode>(
            valueListenable: themeMode,
            builder: (context, mode, _) => Theme(
              data: resolveReaderTheme(baseTheme, mode),
              child: ReaderBottomBar(
                chapters: const [
                  ChapterInfoModel(id: 'c1', title: 'One'),
                  ChapterInfoModel(id: 'c2', title: 'Two'),
                  ChapterInfoModel(id: 'c3', title: 'Three'),
                ],
                currentIndex: 1,
                isSwitchingChapter: false,
                onPrevious: () {},
                onNext: () {},
                onOpenToc: () {},
                onOpenInterface: () {},
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      ),
    );

    for (final mode in [
      ReaderThemeMode.light,
      ReaderThemeMode.dark,
      ReaderThemeMode.sepia,
      ReaderThemeMode.custom,
      ReaderThemeMode.system,
    ]) {
      themeMode.value = mode;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: 'switching to $mode');
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });

  test('every reader theme uses interpolatable text styles', () {
    final base = LanghuanTheme.dark();

    for (final mode in ReaderThemeMode.values) {
      final theme = resolveReaderTheme(base, mode);
      final styles = <String, TextStyle?>{
        'displayLarge': theme.textTheme.displayLarge,
        'displayMedium': theme.textTheme.displayMedium,
        'displaySmall': theme.textTheme.displaySmall,
        'headlineLarge': theme.textTheme.headlineLarge,
        'headlineMedium': theme.textTheme.headlineMedium,
        'headlineSmall': theme.textTheme.headlineSmall,
        'titleLarge': theme.textTheme.titleLarge,
        'titleMedium': theme.textTheme.titleMedium,
        'titleSmall': theme.textTheme.titleSmall,
        'bodyLarge': theme.textTheme.bodyLarge,
        'bodyMedium': theme.textTheme.bodyMedium,
        'bodySmall': theme.textTheme.bodySmall,
        'labelLarge': theme.textTheme.labelLarge,
        'labelMedium': theme.textTheme.labelMedium,
        'labelSmall': theme.textTheme.labelSmall,
      };
      for (final MapEntry(:key, :value) in styles.entries) {
        expect(
          value?.inherit,
          isFalse,
          reason: '$mode.$key must interpolate with Material text styles',
        );
        expect(value?.fontSize, isNotNull, reason: '$mode.$key needs fontSize');
        expect(
          value?.textBaseline,
          isNotNull,
          reason: '$mode.$key needs textBaseline',
        );
      }
    }
  });
}
