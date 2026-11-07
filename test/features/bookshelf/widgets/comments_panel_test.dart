import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/comments/comment_cards.dart';
import 'package:langhuan/features/bookshelf/comments/comments_controller.dart';
import 'package:langhuan/features/bookshelf/comments/comments_panel.dart';
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

void main() {
  testWidgets('a settled empty thread opens the panel without a skeleton', (
    tester,
  ) async {
    // The controller is shared with the inline chapter-end section, which
    // already loaded this thread and found it empty.
    final controller = CommentsController(
      _EmptyCommentsService(),
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c',
    );
    addTearDown(controller.dispose);
    await controller.loadMore();
    expect(controller.hasLoadedPage, isTrue);

    await tester.pumpWidget(
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
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showCommentsPanel(context, controller, disposeController: false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    // Mid entrance animation: the empty state is already showing. Before
    // the fix the skeleton ran under the whole animation and then flipped,
    // flashing on every open of a chapter without comments.
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(CommentsSkeleton), findsNothing);
    expect(find.byType(EmptyComments), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(EmptyComments), findsOneWidget);
  });
}
