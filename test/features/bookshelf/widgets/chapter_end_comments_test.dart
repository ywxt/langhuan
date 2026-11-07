import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/comments/chapter_end_comments.dart';
import 'package:langhuan/features/bookshelf/comments/comment_cards.dart';
import 'package:langhuan/features/bookshelf/comments/comments_controller.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/comments.dart';

import '../../feeds/fake_feed_service.dart';

/// Serves one empty comment page per request.
class _EmptyCommentsService extends FakeFeedService {
  @override
  Future<CommentRequest> openCommentsPage({
    required String feedId,
    required String bookId,
    required String chapterId,
    String? paragraphId,
    String? parentId,
    String? cursorJson,
  }) async {
    return FakeCommentRequest(
      const CommentPage(items: [], nextCursorJson: null, totalCount: 0),
    );
  }
}

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

ChapterEndComments _section(CommentsController controller) => ChapterEndComments(
  service: controller.service,
  feedId: controller.feedId,
  bookId: controller.bookId,
  chapterId: controller.chapterId,
  controller: controller,
);

CommentsController _controller() => CommentsController(
  _EmptyCommentsService(),
  feedId: 'f',
  bookId: 'b',
  chapterId: 'c',
);

void main() {
  testWidgets('an empty chapter settles to the no-comments state', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_wrap(_section(controller)));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyComments), findsOneWidget);
    expect(find.byType(CommentsSkeleton), findsNothing);
  });

  testWidgets('a remounted section leaves the skeleton without a tap', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);

    // First mount loads and settles to empty.
    await tester.pumpWidget(_wrap(_section(controller)));
    await tester.pumpAndSettle();
    expect(find.byType(EmptyComments), findsOneWidget);

    // Scroll away and back: the reading views recycle the section's State
    // while ChapterCommentsCache keeps the settled controller. The remounted
    // section must leave the skeleton on its own — before the fix it waited
    // for an unrelated rebuild (a tap, a route change) to show the state.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_wrap(_section(controller)));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyComments), findsOneWidget);
    expect(find.byType(CommentsSkeleton), findsNothing);
  });
}
