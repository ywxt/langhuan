import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/comments/comments_controller.dart';
import 'package:langhuan/features/bookshelf/comments/comments_panel.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'fixture_feed.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'comments, typed paragraph identity and shared reading progress',
    (tester) async {
      await RustLib.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var commentRequests = 0;
      final holding = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/comments') {
          commentRequests++;
          final parent = request.uri.queryParameters['parent'];
          if (parent == 'hold') {
            holding.complete();
            await release.future;
            try {
              await request.response.close();
            } catch (_) {
              /* Cancelled client. */
            }
            return;
          }
          final page = request.uri.queryParameters['page'];
          final ids = parent == null
              ? page == '2'
                    ? ['c2', 'c3']
                    : ['c1', 'c2']
              : ['reply'];
          request.response.write(
            jsonEncode({
              'items': [
                for (final id in ids)
                  {
                    'id': id,
                    'author': {'name': 'Reader'},
                    'text': 'Comment $id',
                    'replies': parent == null ? {'total_count': 1} : null,
                  },
              ],
              'next_cursor': parent == null && page != '2' ? {'page': 2} : null,
              'total_count': parent == null ? 3 : 1,
            }),
          );
        } else if (request.uri.path.startsWith('/paragraphs/')) {
          request.response.write('text');
        } else {
          request.response.write('1');
        }
        await request.response.close();
      });
      final directory = await Directory.systemTemp.createTemp(
        'langhuan-comments-',
      );
      await AppService.instance.setAppDataDirectory(directory.path);
      final script =
          fixtureFeedScript(
                id: 'comments-test',
                name: 'Comments',
                port: server.port,
              )
              .replaceFirst(
                'type: "text", content:',
                'type: "text", id: "839", content:',
              )
              .replaceFirst(
                'export default { search, bookInfo, chapters, paragraphs };',
                '''
function comments(event) {
  if (event.state == null) {
    const params = { page: String(event.cursor?.page ?? 1) };
    if (event.input.parentId != null) params.parent = event.input.parentId;
    return { type: "request", request: { url: meta.base_url + "/comments", method: "GET", params },
      next_state: { requested: true } };
  }
  const page = JSON.parse(DECODER.decode(event.response.body));
  return { type: "complete", result: { items: page.items, total_count: page.total_count }, next_cursor: page.next_cursor };
}
export default { search, bookInfo, chapters, paragraphs, comments: { chapter: comments, paragraph: comments } };
''',
              );
      final file = File('${directory.path}/comments.js')
        ..writeAsStringSync(script);
      final service = FeedService.instance;
      final preview = await service.previewFromFile(file.path);
      await service.installFeed(preview.requestId);
      final support = await service.commentSupport('comments-test');
      expect(support.chapter, isTrue);
      expect(support.paragraph, isTrue);
      final paragraphs = await service.paragraphs(
        feedId: 'comments-test',
        bookId: '1001',
        chapterId: '1',
      );
      final paragraph = paragraphs.single;
      final encoded = (paragraph as ParagraphContent_Text).id.toStringValue();
      expect(paragraphIdFromString(encoded)?.sourceId, '839');

      final controller = CommentsController(
        service,
        feedId: 'comments-test',
        bookId: '1001',
        chapterId: '1',
        paragraphId: '839',
      );
      await controller.loadMore();
      expect(controller.error, isNull, reason: '${controller.error}');
      await controller.loadMore();
      expect(controller.error, isNull, reason: '${controller.error}');
      expect(controller.items.map((c) => c.id), ['c1', 'c2', 'c3']);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: CommentsPanel(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Comment c1'), findsOneWidget);
      await tester.tap(find.text('Replies (1)').first);
      await tester.pumpAndSettle();
      expect(find.text('Comment reply'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();

      await service.setReadingProgress(
        feedId: 'comments-test',
        bookId: '1001',
        chapterId: '1',
        paragraphId: encoded,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      final reading = await service.getReadingProgress(
        feedId: 'comments-test',
        bookId: '1001',
      );
      expect(reading!.paragraphId, encoded);
      expect(reading.paragraphCharOffset, 0);
      final request = await service.openCommentsPage(
        feedId: 'comments-test',
        bookId: '1001',
        chapterId: '1',
        parentId: 'hold',
      );
      final cancelled = expectLater(request.result(), throwsA(anything));
      await holding.future.timeout(const Duration(seconds: 5));
      await request.cancel();
      await cancelled.timeout(const Duration(seconds: 5));
      release.complete();
      final beforeDisabled = commentRequests;
      await service.setFeedEnabled(feedId: 'comments-test', enabled: false);
      expect((await service.commentSupport('comments-test')).chapter, isFalse);
      await expectLater(
        service.commentsPage(
          feedId: 'comments-test',
          bookId: '1001',
          chapterId: '1',
        ),
        throwsA(anything),
      );
      expect(commentRequests, beforeDisabled);
    },
  );
}
