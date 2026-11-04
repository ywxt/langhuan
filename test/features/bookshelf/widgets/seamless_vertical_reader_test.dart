import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/reader_chapter_window.dart';
import 'package:langhuan/features/bookshelf/widgets/seamless_vertical_reader.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

List<ChapterInfoModel> _chapters(int count) => [
  for (var i = 0; i < count; i++) ChapterInfoModel(id: 'c$i', title: 'C$i'),
];

/// 40 one-line paragraphs — tall enough to scroll several viewports.
List<ParagraphContent> _tallParagraphs(String chapterId) => [
  for (var i = 0; i < 40; i++)
    ParagraphContent_Text(
      id: ParagraphId(
        original: OriginalParagraphId.source('${chapterId}_p$i'),
        path: [],
      ),
      content: '$chapterId paragraph $i',
    ),
];

Future<List<ParagraphContent>> _loader(
  String chapterId, {
  bool forceRefresh = false,
}) async {
  return _tallParagraphs(chapterId);
}

Widget _host({
  required ReaderChapterWindow window,
  void Function(String chapterId, String paragraphId, double offset)?
  onPosition,
  VoidCallback? onToggle,
  ReaderScrollTarget? target,
  double? Function(String chapterId, String paragraphId)? estimate,
  VoidCallback? onTargetSettled,
  double viewportBottomInset = 0,
  double contentBottom = 32,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox.expand(
        child: SeamlessVerticalReader(
          window: window,
          chapters: window.chapters,
          contentPadding: EdgeInsets.fromLTRB(16, 32, 16, contentBottom),
          viewportBottomInset: viewportBottomInset,
          fontScale: 1,
          lineHeight: 1.8,
          onPositionChanged: (c, p, o) => onPosition?.call(c, p, o),
          onToggleControls: () => onToggle?.call(),
          scrollTarget: target,
          estimateParagraphOffset: estimate,
          onTargetSettled: onTargetSettled,
        ),
      ),
    ),
  );
}

ScrollableState _scrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable));

Future<void> _pumpLoaded(WidgetTester tester) async {
  // Let the (immediate) loader futures complete and rebuild.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('scroll targets scope repeated paragraph IDs to their chapter', (
    tester,
  ) async {
    final id = const ParagraphId(
      original: OriginalParagraphId.source('same'),
      path: [],
    );
    final window = ReaderChapterWindow(
      chapters: _chapters(3),
      anchorChapterId: 'c1',
      loader: (chapterId, {bool forceRefresh = false}) async => [
        ParagraphContent.text(id: id, content: '$chapterId paragraph'),
      ],
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(
      _host(
        window: window,
        target: ReaderScrollTarget(
          token: 1,
          chapterId: 'c1',
          paragraphId: id.toStringValue(),
        ),
      ),
    );
    await _pumpLoaded(tester);
    await tester.pumpAndSettle();
    expect(find.text('c1 paragraph'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('refines an underestimated jump beyond a tall paragraph', (
    tester,
  ) async {
    final targetId = const ParagraphId(
      original: OriginalParagraphId.source('target'),
      path: [],
    ).toStringValue();
    final window = ReaderChapterWindow(
      chapters: _chapters(1),
      anchorChapterId: 'c0',
      loader: (_, {bool forceRefresh = false}) async => [
        ParagraphContent.text(
          id: const ParagraphId(
            original: OriginalParagraphId.source('long'),
            path: [],
          ),
          content: List.filled(300, 'A tall paragraph. ').join(),
        ),
        ParagraphContent.text(
          id: const ParagraphId(
            original: OriginalParagraphId.source('target'),
            path: [],
          ),
          content: 'Target paragraph',
        ),
      ],
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);
    expect(find.text('Target paragraph'), findsNothing);
    await tester.pumpWidget(
      _host(
        window: window,
        target: ReaderScrollTarget(
          token: 1,
          chapterId: 'c0',
          paragraphId: targetId,
        ),
        estimate: (_, _) => 100,
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.text('Target paragraph'));
    expect(rect.top, lessThan(600));
    expect(rect.bottom, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
  testWidgets('held drag preserves small movements in both directions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetDevicePixelRatio);

    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    final start = _scrollable(tester).position.pixels;

    // One slow finger movement is delivered as many subpixel deltas. Rounding
    // the scroll offset per event loses those deltas and makes text stick.
    for (var i = 0; i < 100; i++) {
      await gesture.moveBy(const Offset(0, -0.1));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(_scrollable(tester).position.pixels - start, closeTo(10, 0.01));
    final paintedOrigin = tester.getTopLeft(find.text('c1 paragraph 3')) * 3.5;
    expect(paintedOrigin.dy, closeTo(paintedOrigin.dy.roundToDouble(), 1e-6));
    for (var i = 0; i < 100; i++) {
      await gesture.moveBy(const Offset(0, 0.1));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(_scrollable(tester).position.pixels, closeTo(start, 0.01));
    await gesture.up();
  });

  testWidgets('renders anchor chapter content on open', (tester) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);

    expect(find.text('c1 paragraph 0'), findsOneWidget);
    expect(find.text('c1 paragraph 5'), findsOneWidget);
  });

  testWidgets('scrolling down flows into the next chapter seamlessly', (
    tester,
  ) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);

    // Drag past the end of the anchor chapter into the next one — the
    // content continues inside the same scroll view.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('c2 paragraph'), findsAny);
    expect(
      find.byType(CustomScrollView),
      findsOneWidget,
      reason: 'no separate page/view is introduced at the boundary',
    );
  });

  testWidgets('tap zones page the scroll view', (tester) async {
    var toggles = 0;
    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window, onToggle: () => toggles++));
    await _pumpLoaded(tester);

    expect(_scrollable(tester).position.pixels, 0);

    // Bottom third: forward one viewport.
    await tester.tapAt(const Offset(300, 550));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final afterDown = _scrollable(tester).position.pixels;
    expect(afterDown, greaterThan(300));

    // Middle third: toggles the controls, does not scroll.
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(toggles, 1);
    expect(_scrollable(tester).position.pixels, afterDown);

    // Top third: back one viewport.
    await tester.tapAt(const Offset(300, 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_scrollable(tester).position.pixels, lessThan(afterDown));
  });

  testWidgets('scrolling toward the bottom expands the window', (tester) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(8),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);
    expect(window.windowChapterIds, ['c0', 'c1', 'c2']);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -4000),
      2000,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      window.windowChapterIds,
      contains('c3'),
      reason: 'approaching the window edge must load the next chapter',
    );
  });

  testWidgets('reports the first visible paragraph while scrolling', (
    tester,
  ) async {
    final positions = <(String, String, double)>[];
    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(
      _host(window: window, onPosition: (c, p, o) => positions.add((c, p, o))),
    );
    await _pumpLoaded(tester);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(positions, isNotEmpty);
    expect(positions.last.$1, 'c2');
    expect(
      paragraphIdFromString(positions.last.$2)?.sourceId,
      startsWith('c2_p'),
    );
  });

  testWidgets('restores to a target paragraph', (tester) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(4),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(
      _host(
        window: window,
        target: const ReaderScrollTarget(
          token: 1,
          chapterId: 'c1',
          paragraphId: 'c1_p30',
        ),
        estimate: (chapterId, paragraphId) => 30 * 44.0,
      ),
    );
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 50));

    final pixels = _scrollable(tester).position.pixels;
    expect(pixels, greaterThan(1000));
    expect(find.text('c1 paragraph 30'), findsOneWidget);
  });

  testWidgets('a target whose estimate is unknown holds the offset', (
    tester,
  ) async {
    // Saved positions report ParagraphId.toStringValue, and the target
    // key matching below needs that exact form.
    final p30Id = ParagraphId(
      original: const OriginalParagraphId.source('c1_p30'),
      path: const [],
    ).toStringValue();
    final window = ReaderChapterWindow(
      chapters: _chapters(2),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(
      _host(
        window: window,
        target: ReaderScrollTarget(
          token: 1,
          chapterId: 'c1',
          paragraphId: p30Id,
        ),
        estimate: (chapterId, paragraphId) => 30 * 44.0,
      ),
    );
    await _pumpLoaded(tester);
    await tester.pumpAndSettle();
    final landed = _scrollable(tester).position.pixels;
    expect(landed, greaterThan(1000));

    // A new target (a reflow re-issue) whose pages are still being
    // paginated reports no estimate: the current offset must be held —
    // jumping to the chapter top mid-drag would be disorienting.
    await tester.pumpWidget(
      _host(
        window: window,
        target: ReaderScrollTarget(
          token: 2,
          chapterId: 'c1',
          paragraphId: p30Id,
        ),
        estimate: (chapterId, paragraphId) => null,
      ),
    );
    expect(_scrollable(tester).position.pixels, greaterThan(1000));

    // The fine-tune still lands on the paragraph without any estimate.
    await tester.pumpAndSettle();
    expect(find.text('c1 paragraph 30'), findsOneWidget);
    expect(_scrollable(tester).position.pixels, greaterThan(1000));
  });

  testWidgets('notifies once when the target lands exactly', (tester) async {
    var settled = 0;
    final p30Id = ParagraphId(
      original: const OriginalParagraphId.source('c1_p30'),
      path: const [],
    ).toStringValue();
    final window = ReaderChapterWindow(
      chapters: _chapters(2),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(
      _host(
        window: window,
        target: ReaderScrollTarget(
          token: 1,
          chapterId: 'c1',
          paragraphId: p30Id,
        ),
        estimate: (chapterId, paragraphId) => 30 * 44.0,
        onTargetSettled: () => settled++,
      ),
    );
    await _pumpLoaded(tester);
    await tester.pumpAndSettle();

    expect(settled, 1);
    expect(find.text('c1 paragraph 30'), findsOneWidget);
  });

  testWidgets('shows the end-of-book mark after the last chapter', (
    tester,
  ) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(2),
      anchorChapterId: 'c0',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);

    // Scroll to the very bottom.
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -8000),
      4000,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("You're all caught up"), findsOneWidget);
  });

  testWidgets('a viewport inset replaces, not stacks with, the bottom inset', (
    tester,
  ) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(2),
      anchorChapterId: 'c0',
      loader: _loader,
    );
    // The reader in production passes the status-bar chrome as the
    // viewport inset and a zero content bottom: no trailing spacer.
    await tester.pumpWidget(
      _host(window: window, viewportBottomInset: 32, contentBottom: 0),
    );
    await _pumpLoaded(tester);

    expect(
      find.byKey(const ValueKey('vertical-bottom-inset')),
      findsNothing,
      reason: 'the viewport inset already keeps content off the chrome',
    );

    // Scrolled to the very bottom, the end mark rests on the inset edge —
    // no second dead spacer above it.
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -8000),
      4000,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    final hostBottom = tester.getSize(find.byType(Scaffold)).height;
    final markBottom = tester
        .getBottomLeft(find.text("You're all caught up"))
        .dy;
    // The mark's own vertical padding is part of its design; what must not
    // happen is the viewport inset stacking a dead spacer above it.
    expect(markBottom, lessThan(hostBottom - 32));

    // Without a viewport inset the trailing spacer is the mechanism again,
    // and it must land the mark at the very same place — the inset replaces
    // the spacer one-for-one instead of stacking on top of it.
    await tester.pumpWidget(
      _host(window: window, viewportBottomInset: 0, contentBottom: 32),
    );
    await _pumpLoaded(tester);
    expect(find.byKey(const ValueKey('vertical-bottom-inset')), findsOneWidget);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -8000),
      4000,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getBottomLeft(find.text("You're all caught up")).dy,
      closeTo(markBottom, 2),
      reason: 'the viewport inset replaces the spacer, not stacks with it',
    );
  });

  testWidgets('mid-session jump lands on the anchor chapter start', (
    tester,
  ) async {
    final window = ReaderChapterWindow(
      chapters: _chapters(8),
      anchorChapterId: 'c1',
      loader: _loader,
    );
    await tester.pumpWidget(_host(window: window));
    await _pumpLoaded(tester);

    // Scroll deep into the anchor so the current offset is far from 0.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pump(const Duration(milliseconds: 100));

    // Jump exactly like ChapterContentManager._onJumpCommand does:
    // reset the window around the target, then rebuild with a fresh
    // scroll-target token.
    window.jumpTo('c5');
    await tester.pumpWidget(
      _host(
        window: window,
        target: const ReaderScrollTarget(
          token: 2,
          chapterId: 'c5',
          paragraphId: '',
        ),
      ),
    );
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text('c5 paragraph 0'),
      findsOneWidget,
      reason: 'the anchor chapter must be built',
    );
    final render =
        find.text('c5 paragraph 0').evaluate().single.findRenderObject()
            as RenderBox;
    final top = render.localToGlobal(Offset.zero).dy;
    expect(
      top,
      closeTo(32, 2.0),
      reason:
          'after a TOC jump the anchor chapter starts at the viewport top '
          '(contentPadding.top = 32), got $top',
    );
  });

  testWidgets('mid-session jump shows one loading indicator, on the anchor', (
    tester,
  ) async {
    // Gate every chapter load so the loading state is observable.
    final gates = <String, Completer<void>>{};
    Future<List<ParagraphContent>> gatedLoader(
      String chapterId, {
      bool forceRefresh = false,
    }) {
      final gate = gates.putIfAbsent(chapterId, Completer.new);
      return gate.future.then((_) => _tallParagraphs(chapterId));
    }

    final window = ReaderChapterWindow(
      chapters: _chapters(8),
      anchorChapterId: 'c1',
      loader: gatedLoader,
    );
    await tester.pumpWidget(_host(window: window));
    // Let the initial window (c0, c1, c2) reach its loading state.
    await tester.pump(const Duration(milliseconds: 50));
    gates['c0']!.complete();
    gates['c1']!.complete();
    gates['c2']!.complete();
    await _pumpLoaded(tester);

    // Jump to an uncached chapter — its window (c4, c5, c6) is all loading.
    window.jumpTo('c5');
    await tester.pumpWidget(
      _host(
        window: window,
        target: const ReaderScrollTarget(
          token: 2,
          chapterId: 'c5',
          paragraphId: '',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason:
          'only the anchor chapter may show a spinner while loading; '
          'neighbours load quietly and edge spinners must not stack',
    );

    // Releasing the anchor lets the reader show content at the viewport top.
    gates['c5']!.complete();
    await _pumpLoaded(tester);
    expect(find.text('c5 paragraph 0'), findsOneWidget);
    final render =
        find.text('c5 paragraph 0').evaluate().single.findRenderObject()
            as RenderBox;
    expect(render.localToGlobal(Offset.zero).dy, closeTo(32, 2.0));
  });

  testWidgets('chapter above the anchor keeps title before its body', (
    tester,
  ) async {
    Future<List<ParagraphContent>> titledLoader(
      String chapterId, {
      bool forceRefresh = false,
    }) async => [
      ParagraphContent_Title(
        id: ParagraphId(
          original: OriginalParagraphId.source('${chapterId}_title'),
          path: [],
        ),
        text: '$chapterId title',
      ),
      ParagraphContent_Text(
        id: ParagraphId(
          original: OriginalParagraphId.source('${chapterId}_body_0'),
          path: [],
        ),
        content: '$chapterId body 0',
      ),
      ParagraphContent_Text(
        id: ParagraphId(
          original: OriginalParagraphId.source('${chapterId}_body_1'),
          path: [],
        ),
        content: '$chapterId body 1',
      ),
    ];

    final positions = <(String, String, double)>[];
    final window = ReaderChapterWindow(
      chapters: _chapters(3),
      anchorChapterId: 'c1',
      loader: titledLoader,
    );
    await tester.pumpWidget(
      _host(window: window, onPosition: (c, p, o) => positions.add((c, p, o))),
    );
    await _pumpLoaded(tester);

    // Reveal the reverse-growth region above the center/anchor.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 100));

    final titleTop = tester.getTopLeft(find.text('c0 title')).dy;
    final firstBodyTop = tester.getTopLeft(find.text('c0 body 0')).dy;
    final lastBodyTop = tester.getTopLeft(find.text('c0 body 1')).dy;

    expect(titleTop, lessThan(firstBodyTop));
    expect(firstBodyTop, lessThan(lastBodyTop));
    expect(positions.last.$1, 'c0');
    expect(paragraphIdFromString(positions.last.$2)?.sourceId, 'c0_title');
  });
}
