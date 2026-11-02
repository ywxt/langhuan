import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/reader_status_bar.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/theme/app_theme.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required ValueNotifier<ReaderPageProgress?> progress,
    String chapterTitle = 'Chapter title',
    String chapterId = 'c1',
    int chapterIndex = 1,
    int chapterCount = 4,
    bool visible = true,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Stack(
              children: [
                ReaderStatusBar(
                  visible: visible,
                  theme: Theme.of(context),
                  chapterId: chapterId,
                  chapterTitle: chapterTitle,
                  chapterIndex: chapterIndex,
                  chapterCount: chapterCount,
                  pageProgress: progress,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the chapter title with page and book progress', (
    tester,
  ) async {
    final progress = ValueNotifier<ReaderPageProgress?>(
      const ReaderPageProgress(chapterId: 'c1', pageIndex: 2, pageCount: 24),
    );
    addTearDown(progress.dispose);

    await pumpBar(tester, progress: progress);

    expect(find.text('Chapter title'), findsOneWidget);
    // Page 3 of 24; book = (1 + 3/24) / 4 ≈ 28%.
    expect(find.text('Page 3 / 24 · 28% of book'), findsOneWidget);
  });

  testWidgets('without page progress (vertical mode) only book percent shows', (
    tester,
  ) async {
    final progress = ValueNotifier<ReaderPageProgress?>(null);
    addTearDown(progress.dispose);

    await pumpBar(
      tester,
      progress: progress,
      chapterIndex: 2,
      chapterCount: 10,
    );

    expect(find.text('20% of book'), findsOneWidget);
    expect(find.textContaining('Page'), findsNothing);
  });

  testWidgets('a progress value from another chapter is ignored', (
    tester,
  ) async {
    final progress = ValueNotifier<ReaderPageProgress?>(
      const ReaderPageProgress(chapterId: 'c0', pageIndex: 5, pageCount: 24),
    );
    addTearDown(progress.dispose);

    await pumpBar(
      tester,
      progress: progress,
      chapterId: 'c1',
      chapterIndex: 1,
      chapterCount: 4,
    );

    // Stale progress from the previous chapter must not show a page label
    // nor feed the book percent.
    expect(find.text('25% of book'), findsOneWidget);
    expect(find.textContaining('Page'), findsNothing);

    // A later progress update addressing the visible chapter applies.
    progress.value = const ReaderPageProgress(
      chapterId: 'c1',
      pageIndex: 3,
      pageCount: 24,
    );
    await tester.pump();
    expect(find.text('Page 4 / 24 · 29% of book'), findsOneWidget);
  });

  testWidgets('an overly long title is truncated, not the progress', (
    tester,
  ) async {
    final progress = ValueNotifier<ReaderPageProgress?>(
      const ReaderPageProgress(chapterId: 'c1', pageIndex: 0, pageCount: 12),
    );
    addTearDown(progress.dispose);

    await pumpBar(
      tester,
      progress: progress,
      chapterTitle:
          'A chapter title so long that the status line cannot '
          'possibly fit it without ellipsis',
    );

    final title = tester.widget<Text>(
      find.textContaining('A chapter title so long'),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(find.text('Page 1 / 12 · 27% of book'), findsOneWidget);
  });

  testWidgets('hidden state fades the bar out of the hit-test tree', (
    tester,
  ) async {
    final progress = ValueNotifier<ReaderPageProgress?>(null);
    addTearDown(progress.dispose);

    await pumpBar(tester, progress: progress, visible: false);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });

  testWidgets('renders without errors across reader themes', (tester) async {
    final progress = ValueNotifier<ReaderPageProgress?>(
      const ReaderPageProgress(chapterId: 'c1', pageIndex: 1, pageCount: 8),
    );
    addTearDown(progress.dispose);

    await pumpBar(tester, progress: progress);
    for (final theme in [LanghuanTheme.light(), LanghuanTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  ReaderStatusBar(
                    visible: true,
                    theme: Theme.of(context),
                    chapterId: 'c1',
                    chapterTitle: 'T',
                    chapterIndex: 0,
                    chapterCount: 2,
                    pageProgress: progress,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}
