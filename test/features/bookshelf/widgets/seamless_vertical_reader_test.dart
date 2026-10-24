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
      id: ParagraphId.id('${chapterId}_p$i'),
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
  double Function(String chapterId, String paragraphId)? estimate,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox.expand(
        child: SeamlessVerticalReader(
          window: window,
          chapters: window.chapters,
          contentPadding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
          fontScale: 1,
          lineHeight: 1.8,
          onPositionChanged: (c, p, o) => onPosition?.call(c, p, o),
          onToggleControls: () => onToggle?.call(),
          scrollTarget: target,
          estimateParagraphOffset: estimate,
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
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -2400),
    );
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
    await tester.pumpWidget(
      _host(window: window, onToggle: () => toggles++),
    );
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
      _host(
        window: window,
        onPosition: (c, p, o) => positions.add((c, p, o)),
      ),
    );
    await _pumpLoaded(tester);

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -2400),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(positions, isNotEmpty);
    expect(positions.last.$1, 'c2');
    expect(positions.last.$2, startsWith('c2_p'));
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

    expect(find.text("You've reached the end of the book"), findsOneWidget);
  });
}
