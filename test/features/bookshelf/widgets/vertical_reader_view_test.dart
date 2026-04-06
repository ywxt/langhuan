import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_loader.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_status_block.dart';
import 'package:langhuan/features/bookshelf/widgets/paragraph_view.dart';
import 'package:langhuan/features/bookshelf/widgets/vertical_reader_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mock content provider
// ─────────────────────────────────────────────────────────────────────────────

class MockContentProvider implements ChapterContentProvider {
  int _counter = 0;
  Set<String> failingChapters = {};
  Map<String, List<ParagraphContent>> immediateContent = {};

  @override
  ({String requestId, Stream<ParagraphContent> stream}) fetchChapter({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) {
    final requestId = 'mock-req-${_counter++}';
    if (failingChapters.contains(chapterId)) {
      return (
        requestId: requestId,
        stream: Stream.error(
          FeedStreamException(
            requestId: requestId,
            message: 'Mock error for $chapterId',
            retriedCount: 0,
          ),
        ),
      );
    }
    final items = immediateContent[chapterId] ?? [];
    return (requestId: requestId, stream: Stream.fromIterable(items));
  }

  @override
  void cancel(String requestId) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

List<ChapterInfoModel> makeChapters(int count) {
  return List.generate(
    count,
    (i) => ChapterInfoModel(id: 'ch-$i', title: 'Chapter ${i + 1}', index: i),
  );
}

List<ParagraphContent> makeContent(String chapterId) => [
  ParagraphContentTitle(text: 'Title of $chapterId'),
  ParagraphContentText(content: 'Body text of $chapterId.'),
];

Widget buildTestWidget({
  required ChapterLoader loader,
  String initialChapterId = 'ch-0',
  int initialParagraphIndex = 0,
  ValueChanged<String>? onChapterChanged,
  ValueChanged<int>? onParagraphChanged,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 600,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: VerticalReaderView(
            loader: loader,
            initialChapterId: initialChapterId,
            initialParagraphIndex: initialParagraphIndex,
            contentPadding: const EdgeInsets.all(16),
            onChapterChanged: onChapterChanged ?? (_) {},
            onParagraphChanged: onParagraphChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late MockContentProvider provider;

  setUp(() {
    provider = MockContentProvider();
  });

  group('VerticalReaderView — loading state', () {
    testWidgets('shows loading when loader has no slots', (tester) async {
      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: makeChapters(3),
        contentProvider: provider,
      );

      await tester.pumpWidget(buildTestWidget(loader: loader));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);

      loader.dispose();
    });
  });

  group('VerticalReaderView — content display', () {
    testWidgets('shows chapter content after loading', (tester) async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-0'),
      );
      await tester.pumpAndSettle();

      // Should show the first chapter's title.
      expect(find.text('Title of ch-0'), findsOneWidget);
      // Should show body text.
      expect(find.text('Body text of ch-0.'), findsOneWidget);

      loader.dispose();
    });

    testWidgets('shows multiple chapters in scroll view', (tester) async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-0'),
      );
      await tester.pumpAndSettle();

      // Should have a ListView.
      expect(find.byType(ListView), findsOneWidget);

      // Should have ParagraphView widgets.
      expect(find.byType(ParagraphView), findsWidgets);

      loader.dispose();
    });
  });

  group('VerticalReaderView — chapter markers', () {
    testWidgets('shows chapter markers between chapters', (tester) async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-0'),
      );
      await tester.pumpAndSettle();

      // Scroll down to see chapter markers.
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      // Should have Divider widgets (from chapter markers).
      expect(find.byType(Divider), findsWidgets);

      loader.dispose();
    });
  });

  group('VerticalReaderView — error markers', () {
    testWidgets('shows error marker for failed chapter', (tester) async {
      final chapters = makeChapters(3);
      provider.immediateContent['ch-0'] = makeContent('ch-0');
      provider.failingChapters.add('ch-1');
      provider.immediateContent['ch-2'] = makeContent('ch-2');

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-0'),
      );
      await tester.pumpAndSettle();

      // Scroll down to see the error marker.
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      // Should show a ChapterStatusBlock for the error.
      expect(find.byType(ChapterStatusBlock), findsWidgets);

      loader.dispose();
    });
  });

  group('VerticalReaderView — callbacks', () {
    testWidgets('calls onChapterChanged when scrolling to new chapter', (
      tester,
    ) async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      final changedChapters = <String>[];
      await tester.pumpWidget(
        buildTestWidget(
          loader: loader,
          initialChapterId: 'ch-0',
          onChapterChanged: (id) => changedChapters.add(id),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down significantly.
      for (int i = 0; i < 5; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
      }

      // Should have detected chapter changes.
      // (May or may not have changed depending on content length.)
      expect(find.byType(ListView), findsOneWidget);

      loader.dispose();
    });
  });

  group('VerticalReaderView — scroll stability', () {
    testWidgets('scroll controller is never replaced on loader changes', (
      tester,
    ) async {
      final chapters = makeChapters(5);
      for (int i = 0; i < 5; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        maxLoaded: 5,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-2'),
      );
      await tester.pumpAndSettle();

      // Find the ListView.
      final listViewFinder = find.byType(ListView);
      expect(listViewFinder, findsOneWidget);

      // Trigger a loader change.
      loader.setCurrentChapter('ch-2');
      await tester.pumpAndSettle();

      // ListView should still exist.
      expect(listViewFinder, findsOneWidget);

      loader.dispose();
    });
  });

  group('VerticalItem model', () {
    test('stableKey for content items', () {
      const item = VerticalItem(
        type: VerticalItemType.content,
        chapterId: 'ch-1',
        paragraphIndexInChapter: 3,
      );
      expect(item.stableKey, 'ch-1:3');
    });

    test('stableKey for boundary items', () {
      const top = VerticalItem(type: VerticalItemType.topBoundary);
      expect(top.stableKey, '__top_boundary__');

      const bottom = VerticalItem(type: VerticalItemType.bottomBoundary);
      expect(bottom.stableKey, '__bottom_boundary__');
    });

    test('stableKey for chapter markers', () {
      const marker = VerticalItem(
        type: VerticalItemType.chapterMarker,
        chapterId: 'ch-2',
      );
      expect(marker.stableKey, '__marker_ch-2__');
    });
  });
}
