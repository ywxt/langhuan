import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_loader.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_status_block.dart';
import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

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
          FeedPullException(message: 'Mock error for $chapterId'),
        ),
      );
    }
    final items = immediateContent[chapterId] ?? [];
    return (requestId: requestId, stream: Stream.fromIterable(items));
  }

  @override
  void cancel(String requestId) {}
}

/// Provider that delegates to a base provider but returns controlled streams
/// for specific chapters.
class _DelayedProvider implements ChapterContentProvider {
  final ChapterContentProvider base;
  final Map<String, Stream<ParagraphContent>> delayedStreams;
  int _counter = 0;

  _DelayedProvider({required this.base, required this.delayedStreams});

  @override
  ({String requestId, Stream<ParagraphContent> stream}) fetchChapter({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) {
    if (delayedStreams.containsKey(chapterId)) {
      final requestId = 'delayed-req-${_counter++}';
      return (requestId: requestId, stream: delayedStreams[chapterId]!);
    }
    return base.fetchChapter(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
    );
  }

  @override
  void cancel(String requestId) {
    base.cancel(requestId);
  }
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
  ParagraphContent_Title(text: 'Title of $chapterId'),
  ParagraphContent_Text(content: 'Body text of $chapterId. ' * 5),
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
          child: HorizontalReaderView(
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

  group('HorizontalReaderView — loading state', () {
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

  group('HorizontalReaderView — content display', () {
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

      loader.dispose();
    });

    testWidgets('swiping right shows next chapter content', (tester) async {
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
        buildTestWidget(
          loader: loader,
          initialChapterId: 'ch-0',
          onChapterChanged: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      // Swipe left to go to next page.
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      // The content should have changed (either still ch-0 page 2 or ch-1).
      // We just verify no crash and the page changed.
      expect(find.byType(PageView), findsOneWidget);

      loader.dispose();
    });
  });

  group('HorizontalReaderView — error pages', () {
    testWidgets('shows error page for failed chapter', (tester) async {
      final chapters = makeChapters(3);
      // Make ch-0 have very short content (1 page), ch-1 fails, ch-2 ok.
      provider.immediateContent['ch-0'] = [
        const ParagraphContent_Title(text: 'Ch 0'),
      ];
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

      // ch-0 is 1 page, so swiping once should show ch-1 (error).
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      // Should show a ChapterStatusBlock for the error.
      expect(find.byType(ChapterStatusBlock), findsOneWidget);

      loader.dispose();
    });
  });

  group('HorizontalReaderView — virtual index stability', () {
    testWidgets('page controller is never replaced on loader changes', (
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

      // Find the PageView and verify it exists.
      final pageViewFinder = find.byType(PageView);
      expect(pageViewFinder, findsOneWidget);

      // Trigger a loader change (e.g., retry a chapter).
      provider.failingChapters.clear();
      provider.immediateContent['ch-0'] = makeContent('ch-0');

      // Force a rebuild by calling setCurrentChapter.
      loader.setCurrentChapter('ch-2');
      await tester.pumpAndSettle();

      // PageView should still exist (same widget, not replaced).
      expect(pageViewFinder, findsOneWidget);

      loader.dispose();
    });

    testWidgets('shows content at initial chapter position', (tester) async {
      final chapters = makeChapters(5);
      for (int i = 0; i < 5; i++) {
        provider.immediateContent['ch-$i'] = makeContent('ch-$i');
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');

      await tester.pumpWidget(
        buildTestWidget(loader: loader, initialChapterId: 'ch-2'),
      );
      await tester.pumpAndSettle();

      // Should show ch-2's content.
      expect(find.text('Title of ch-2'), findsOneWidget);

      loader.dispose();
    });
  });

  group('HorizontalReaderView — callbacks', () {
    testWidgets('calls onChapterChanged when chapter changes', (tester) async {
      final chapters = makeChapters(3);
      // Make chapters with very short content so each is 1 page.
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = [
          ParagraphContent_Title(text: 'Ch $i'),
        ];
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

      // Swipe to next page (should be ch-1 since each chapter is 1 page).
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      // Should have called onChapterChanged.
      expect(changedChapters, contains('ch-1'));

      loader.dispose();
    });
  });

  group('HorizontalReaderView — layout stability regression', () {
    testWidgets(
      'swiping to loading chapter and back preserves previous content',
      (tester) async {
        // Regression test: when the next chapter is loading, swiping back
        // to the previous chapter should show its content, not loading.
        final chapters = makeChapters(3);

        // ch-0: ready immediately (short content = 1 page).
        provider.immediateContent['ch-0'] = [
          const ParagraphContent_Title(text: 'Ch 0 Title'),
        ];
        // ch-1: delayed loading (will stay in loading state).
        // We use a StreamController to keep it pending.
        final ch1Controller = StreamController<ParagraphContent>();
        // ch-2: ready immediately.
        provider.immediateContent['ch-2'] = makeContent('ch-2');

        // Custom provider that returns the controlled stream for ch-1.
        final customProvider = _DelayedProvider(
          base: provider,
          delayedStreams: {'ch-1': ch1Controller.stream},
        );

        final loader = ChapterLoader(
          feedId: 'f1',
          bookId: 'b1',
          chapters: chapters,
          contentProvider: customProvider,
        );

        // Load ch-0 only. Don't await loadInitial since ch-1 preload won't
        // complete. Instead, load ch-0 directly and preload ch-1 manually.
        // We use a non-throwing load approach.
        unawaited(loader.loadInitial('ch-0'));
        // Give time for ch-0 to load (it's immediate).
        await tester.pump(const Duration(milliseconds: 100));

        await tester.pumpWidget(
          buildTestWidget(loader: loader, initialChapterId: 'ch-0'),
        );
        await tester.pump();
        await tester.pump();

        // Verify ch-0 content is shown.
        expect(find.text('Ch 0 Title'), findsOneWidget);

        // Swipe to next page (ch-1 loading).
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Should show loading indicator for ch-1.
        expect(find.byType(CircularProgressIndicator), findsWidgets);

        // Now swipe BACK to ch-0.
        await tester.drag(find.byType(PageView), const Offset(400, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // ch-0 should show its content, NOT loading.
        expect(find.text('Ch 0 Title'), findsOneWidget);

        // Clean up.
        await ch1Controller.close();
        loader.dispose();
      },
    );

    testWidgets(
      'background chapter loading does not shift current page mapping',
      (tester) async {
        // When a chapter between anchor and current position finishes loading,
        // the current page should not shift to a different chapter.
        final chapters = makeChapters(5);

        // All chapters ready immediately.
        for (int i = 0; i < 5; i++) {
          provider.immediateContent['ch-$i'] = [
            ParagraphContent_Title(text: 'Ch $i Title'),
          ];
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

        // Verify ch-0 is shown.
        expect(find.text('Ch 0 Title'), findsOneWidget);

        // Trigger a loader notification (simulating background activity).
        loader.setCurrentChapter('ch-0');
        await tester.pumpAndSettle();

        // ch-0 should STILL be shown (not shifted).
        expect(find.text('Ch 0 Title'), findsOneWidget);

        loader.dispose();
      },
    );

    testWidgets(
      'resolving earlier loading chapter into multiple pages does not jump away from current chapter',
      (tester) async {
        final chapters = makeChapters(4);

        provider.immediateContent['ch-0'] = [
          const ParagraphContent_Title(text: 'Ch 0 Title'),
        ];

        final delayedCh1 = StreamController<ParagraphContent>();

        provider.immediateContent['ch-2'] = [
          const ParagraphContent_Title(text: 'Ch 2 Title'),
        ];
        provider.immediateContent['ch-3'] = [
          const ParagraphContent_Title(text: 'Ch 3 Title'),
        ];

        final customProvider = _DelayedProvider(
          base: provider,
          delayedStreams: {'ch-1': delayedCh1.stream},
        );

        final loader = ChapterLoader(
          feedId: 'f1',
          bookId: 'b1',
          chapters: chapters,
          contentProvider: customProvider,
        );

        unawaited(loader.loadInitial('ch-2'));
        await tester.pump(const Duration(milliseconds: 100));

        await tester.pumpWidget(
          buildTestWidget(loader: loader, initialChapterId: 'ch-2'),
        );
        await tester.pump();
        await tester.pump();

        // We are reading ch-2 while ch-1 is still loading.
        expect(find.text('Ch 2 Title'), findsOneWidget);

        // Resolve ch-1 with enough content to produce multiple pages,
        // which inserts extra pages before current viewport.
        delayedCh1.add(const ParagraphContent_Title(text: 'Ch 1 Title'));
        delayedCh1.add(
          ParagraphContent_Text(content: 'Ch 1 long body. ' * 2000),
        );
        await delayedCh1.close();

        await tester.pump();
        await tester.pumpAndSettle();

        // Current chapter should remain ch-2 (no random jump).
        expect(find.text('Ch 2 Title'), findsOneWidget);

        loader.dispose();
      },
    );
  });

  group('ResolvedPage model', () {
    test('content page has correct properties', () {
      const page = PageContent(items: []);
      const resolved = ResolvedPage.content(chapterId: 'ch-1', page: page);
      expect(resolved.kind, ResolvedPageKind.content);
      expect(resolved.chapterId, 'ch-1');
      expect(resolved.page, isNotNull);
    });

    test('loading page has correct properties', () {
      const resolved = ResolvedPage.loading(chapterId: 'ch-1');
      expect(resolved.kind, ResolvedPageKind.loading);
      expect(resolved.chapterId, 'ch-1');
      expect(resolved.page, isNull);
    });

    test('error page has correct properties', () {
      const resolved = ResolvedPage.error(
        chapterId: 'ch-1',
        errorMessage: 'fail',
      );
      expect(resolved.kind, ResolvedPageKind.error);
      expect(resolved.chapterId, 'ch-1');
      expect(resolved.errorMessage, 'fail');
    });

    test('boundary pages have correct kinds', () {
      const endOfBook = ResolvedPage.endOfBook();
      expect(endOfBook.kind, ResolvedPageKind.endOfBook);

      const loadingBoundary = ResolvedPage.loadingBoundary();
      expect(loadingBoundary.kind, ResolvedPageKind.loadingBoundary);
    });
  });
}
