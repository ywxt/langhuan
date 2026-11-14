import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
      const CommentPage(items: [], nextCursorJson: null),
    );
  }
}

class _PopulatedCommentsService extends FakeFeedService {
  @override
  Future<CommentRequest> openCommentsPage({
    required String feedId,
    required String bookId,
    required String chapterId,
    String? paragraphId,
    String? parentId,
    String? cursorJson,
  }) async => FakeCommentRequest(
    CommentPage(
      items: [
        for (var i = 0; i < 30; i++)
          CommentItem(
            id: '${parentId ?? 'root'}-$i',
            author: const CommentAuthor(name: 'Author'),
            text: 'Comment $i',
            replies: const CommentReplies(totalCount: 2),
          ),
      ],
    ),
  );
}

void main() {
  testWidgets(
    'desktop hover and reply navigation keep each scrollbar attached',
    (tester) async {
      final controller = CommentsController(
        _PopulatedCommentsService(),
        feedId: 'f',
        bookId: 'b',
        chapterId: 'c',
      );
      addTearDown(controller.dispose);
      await controller.loadMore();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: CommentsPanel(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getRect(find.byType(ListView)).topRight + const Offset(-4, 80),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.byType(Scrollbar), findsOneWidget);
      final root = tester
          .widget<Scrollbar>(find.byType(Scrollbar).first)
          .controller!;
      expect(root.positions, hasLength(1));
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(root),
      );
      root.jumpTo(200);
      await tester.pumpAndSettle();
      final card = tester.widget<CommentCard>(find.byType(CommentCard).first);
      card.onOpenReplies(card.comment);
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsOneWidget);
      final replies = tester
          .widget<Scrollbar>(find.byType(Scrollbar).first)
          .controller!;
      expect(replies, isNot(same(root)));
      expect(replies.positions, hasLength(1));
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(replies),
      );
      await mouse.moveTo(tester.getRect(find.byType(ListView)).center);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar).first).controller,
        same(root),
      );
      expect(root.offset, closeTo(200, .1));
      await mouse.moveTo(
        tester.getRect(find.byType(ListView)).topRight + const Offset(-4, 120),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

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
                onPressed: () => showCommentsPanel(
                  context,
                  controller,
                  disposeController: false,
                ),
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
