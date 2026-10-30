import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/reader_screen_controller.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_controller.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

import '../feeds/fake_feed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const chapters = [
    ChapterInfoModel(id: 'c1', title: 'One'),
    ChapterInfoModel(id: 'c2', title: 'Two'),
    ChapterInfoModel(id: 'c3', title: 'Three'),
  ];

  /// Pumps a host tree that owns the controller's WidgetRef and returns the
  /// controller, its container, and the underlying reader controller.
  Future<(ReaderScreenController, ProviderContainer, ReaderController)>
  pumpHost(
    WidgetTester tester, {
    required FakeFeedService service,
    String initialChapterId = '',
    String initialParagraphId = '',
  }) async {
    final container = ProviderContainer(
      overrides: [feedServiceProvider.overrideWithValue(service)],
    );
    final readerController = ReaderController();

    late ReaderScreenController controller;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              controller = ReaderScreenController(
                ref: ref,
                readerController: readerController,
                feedId: 'f1',
                bookId: 'b1',
                initialChapterId: initialChapterId,
                initialParagraphId: initialParagraphId,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    addTearDown(controller.dispose);
    addTearDown(readerController.dispose);
    addTearDown(container.dispose);
    return (controller, container, readerController);
  }

  FakeFeedService baseService({
    Future<List<ChapterInfoModel>> Function(String, String)? chapterStream,
    Future<ReadingProgressModel?> Function(String, String)? progress,
    List<(String, String, int)>? seen,
    void Function(String, String, String, String, int)? onProgressSaved,
    Future<List<ParagraphContent>> Function(
      String,
      String,
      String, {
      bool forceRefresh,
    })?
    paragraphs,
  }) {
    return FakeFeedService(
      chaptersHandler: chapterStream ?? (f, b) async => chapters,
      getReadingProgressHandler: progress ?? (f, b) async => null,
      markBookshelfSeenHandler: (f, b, count) async {
        seen?.add((f, b, count));
      },
      bookInfoHandler: (f, b) async =>
          const BookInfoModel(id: 'b1', title: 'Book', author: 'Author'),
      listBookmarksHandler: (f, b) async => [],
      setReadingProgressHandler: onProgressSaved == null
          ? null
          : (f, b, c, p, offset) async => onProgressSaved(f, b, c, p, offset),
      paragraphsHandler: paragraphs,
    );
  }

  group('initialize', () {
    testWidgets('loads chapters, marks them seen, restores saved progress', (
      tester,
    ) async {
      final seen = <(String, String, int)>[];
      final service = baseService(
        seen: seen,
        progress: (f, b) async => const ReadingProgressModel(
          feedId: 'f1',
          bookId: 'b1',
          chapterId: 'c2',
          paragraphId: 'p5',
          paragraphCharOffset: 12,
          updatedAtMs: 1,
        ),
      );
      final (controller, _, reader) = await pumpHost(tester, service: service);

      await controller.initialize();
      await tester.pump(const Duration(milliseconds: 600));

      expect(controller.isInitializing, false);
      expect(controller.initError, isNull);
      expect(controller.chapters.length, 3);
      expect(seen, [('f1', 'b1', 3)]);
      // The saved progress drives the initial jump, page-precisely.
      expect(reader.pendingChapterId, 'c2');
      expect(reader.pendingParagraphId, 'p5');
      expect(reader.pendingCharOffset, 12);
    });

    testWidgets('an explicit initial chapter overrides saved progress', (
      tester,
    ) async {
      final service = baseService(
        progress: (f, b) async => const ReadingProgressModel(
          feedId: 'f1',
          bookId: 'b1',
          chapterId: 'c2',
          paragraphId: 'p5',
          updatedAtMs: 1,
        ),
      );
      final (controller, _, reader) = await pumpHost(
        tester,
        service: service,
        initialChapterId: 'c3',
        initialParagraphId: 'p9',
      );

      await controller.initialize();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.pendingChapterId, 'c3');
      expect(reader.pendingParagraphId, 'p9');
      expect(reader.pendingCharOffset, 0);
    });

    testWidgets('persists an opened chapter before its paragraphs load', (
      tester,
    ) async {
      final saves = <(String, String, String, String, int)>[];
      final service = baseService(
        onProgressSaved: (f, b, c, p, off) => saves.add((f, b, c, p, off)),
      );
      final (controller, _, _) = await pumpHost(
        tester,
        service: service,
        initialChapterId: 'c3',
      );

      await controller.initialize();
      await tester.pump(const Duration(milliseconds: 600));

      expect(saves, [('f1', 'b1', 'c3', '', 0)]);
    });

    testWidgets('saved progress outside the chapter list falls back to first', (
      tester,
    ) async {
      final service = baseService(
        progress: (f, b) async => const ReadingProgressModel(
          feedId: 'f1',
          bookId: 'b1',
          chapterId: 'gone',
          paragraphId: 'p1',
          updatedAtMs: 1,
        ),
      );
      final (controller, _, reader) = await pumpHost(tester, service: service);

      await controller.initialize();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.pendingChapterId, 'c1');
    });

    testWidgets('a failing chapter load records the error', (tester) async {
      final service = baseService(
        chapterStream: (f, b) => Future.error(StateError('boom')),
      );
      final (controller, _, _) = await pumpHost(tester, service: service);

      await controller.initialize();
      await tester.pump();

      expect(controller.initError, isA<StateError>());
      expect(controller.chapters, isEmpty);
      expect(controller.isInitializing, false);
    });
  });

  group('controls and selection', () {
    testWidgets('toggle cycles controls; a selection takes precedence', (
      tester,
    ) async {
      final (controller, _, _) = await pumpHost(tester, service: baseService());

      expect(controller.showControls, false);
      controller.toggleControls();
      expect(controller.showControls, true);

      // Selecting a paragraph hides the controls and shows the selection.
      controller.setSelection(
        chapterId: 'c1',
        paragraphId: 'p1',
        paragraph: const ParagraphContent_Title(
          id: ParagraphId.id('t'),
          text: 'Title',
        ),
        globalRect: Rect.zero,
      );
      expect(controller.showControls, false);
      expect(controller.selection, isNotNull);

      // The next toggle clears the selection without flipping controls.
      controller.toggleControls();
      expect(controller.selection, isNull);
      expect(controller.showControls, false);

      // And the one after that shows the controls again.
      controller.toggleControls();
      expect(controller.showControls, true);

      controller.clearSelection();
      expect(controller.selection, isNull);
    });
  });

  group('progress saving', () {
    testWidgets('debounces near positions, saves distinct ones once each', (
      tester,
    ) async {
      final saves = <(String, String, String, String, int)>[];
      final service = baseService(
        onProgressSaved: (f, b, c, p, off) => saves.add((f, b, c, p, off)),
      );
      final (controller, _, _) = await pumpHost(tester, service: service);

      controller.onPositionChanged(
        const ReaderPosition(chapterId: 'c1', paragraphId: 'p1'),
      );
      // Near-identical position: within epsilon, must not reschedule.
      controller.onPositionChanged(
        const ReaderPosition(
          chapterId: 'c1',
          paragraphId: 'p1',
          paragraphOffset: 0.3,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(saves.length, 1);
      expect(saves.single, ('f1', 'b1', 'c1', 'p1', 0));

      // A distant position saves again after the debounce.
      controller.onPositionChanged(
        const ReaderPosition(
          chapterId: 'c1',
          paragraphId: 'p1',
          paragraphOffset: 5,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(saves.length, 2);

      // A chapter-only position must still save: failed and empty chapters
      // never produce a paragraph position later.
      controller.onPositionChanged(
        const ReaderPosition(chapterId: 'c2', paragraphId: ''),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(saves.length, 3);
      expect(saves.last, ('f1', 'b1', 'c2', '', 0));
    });
  });

  group('refreshCurrentChapter', () {
    testWidgets('forces a refresh and requests the reload, once at a time', (
      tester,
    ) async {
      final refreshCalls = <(String, bool)>[];
      final gate = Completer<void>();
      final service = baseService(
        paragraphs: (f, b, chapterId, {forceRefresh = false}) async {
          refreshCalls.add((chapterId, forceRefresh));
          await gate.future;
          return [
            ParagraphContent_Text(
              id: const ParagraphId.id('p0'),
              content: 'refreshed',
            ),
          ];
        },
      );
      final (controller, _, reader) = await pumpHost(tester, service: service);

      final first = controller.refreshCurrentChapter('c2');
      await tester.pump();
      expect(controller.isRefreshingChapter, true);

      // A second call while one is in flight is ignored.
      await controller.refreshCurrentChapter('c2');
      expect(refreshCalls, [('c2', true)]);

      gate.complete();
      await first;
      expect(controller.isRefreshingChapter, false);
      expect(refreshCalls, [('c2', true)]);

      // The reader is asked to re-read the warmed chapter.
      expect(reader.consumeChapterReload(), 'c2');
    });
  });
}
