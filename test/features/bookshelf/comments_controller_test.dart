import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/comments/comments_controller.dart';
import 'package:langhuan/src/rust/api/comments.dart';
import '../feeds/fake_feed_service.dart';

class _Request implements CommentRequest {
  _Request(this.page);
  final Future<CommentPage> page;
  bool cancelled = false;
  @override
  Future<CommentPage> result() => page;
  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends FakeFeedService {
  final requests = <_Request>[];
  final cursors = <String?>[];
  final parents = <String?>[];
  final pages = <Future<CommentPage>>[];
  @override
  Future<CommentRequest> openCommentsPage({
    required String feedId,
    required String bookId,
    required String chapterId,
    String? paragraphId,
    String? parentId,
    String? cursorJson,
  }) async {
    cursors.add(cursorJson);
    parents.add(parentId);
    final request = _Request(pages.removeAt(0));
    requests.add(request);
    return request;
  }
}

CommentItem _item(String id) => CommentItem(
  id: id,
  author: const CommentAuthor(name: 'Author'),
  text: id,
  replies: const CommentReplies(totalCount: 2),
);
CommentsController _controller(_Service service, {String? parent}) =>
    CommentsController(
      service,
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c',
      paragraphId: '839',
      parentId: parent,
    );

void main() {
  test('overlap is deduplicated and each next cursor is forwarded', () async {
    final service = _Service()
      ..pages.addAll([
        Future.value(
          CommentPage(items: [_item('1')], nextCursorJson: '{"page":2}'),
        ),
        Future.value(CommentPage(items: [_item('1'), _item('2')])),
      ]);
    final controller = _controller(service, parent: 'root');
    addTearDown(controller.dispose);
    await controller.loadMore();
    await controller.loadMore();
    expect(controller.items.map((c) => c.id), ['1', '2']);
    expect(service.cursors, [null, '{"page":2}']);
    expect(service.parents, ['root', 'root']);
    expect(controller.hasMore, isFalse);
  });
  test('failure retries same page without losing previous results', () async {
    final service = _Service()
      ..pages.add(
        Future.value(
          CommentPage(items: [_item('1')], nextCursorJson: '{"page":2}'),
        ),
      );
    final controller = _controller(service);
    addTearDown(controller.dispose);
    await controller.loadMore();
    service.pages.add(
      Future.delayed(Duration.zero, () => throw StateError('network')),
    );
    await controller.loadMore();
    expect(controller.error, isNotNull);
    service.pages.add(Future.value(CommentPage(items: [_item('2')])));
    await controller.loadMore();
    expect(controller.items, hasLength(2));
    expect(service.cursors, [null, '{"page":2}', '{"page":2}']);
  });
  test(
    'refresh cancels an in-flight request and ignores its old response',
    () async {
      final old = Completer<CommentPage>();
      final service = _Service()
        ..pages.addAll([
          old.future,
          Future.value(CommentPage(items: [_item('new')])),
        ]);
      final controller = _controller(service);
      addTearDown(controller.dispose);
      final pending = controller.loadMore();
      await Future<void>.delayed(Duration.zero);
      await controller.refresh();
      expect(service.requests.first.cancelled, isTrue);
      old.complete(CommentPage(items: [_item('old')]));
      await pending;
      expect(controller.items.single.id, 'new');
    },
  );
  test('empty pages continue but a cyclic cursor is an error', () async {
    final service = _Service()
      ..pages.addAll([
        Future.value(
          const CommentPage(
            items: [],
            nextCursorJson: '{"page":2,"token":"a"}',
          ),
        ),
        Future.value(
          const CommentPage(
            items: [],
            nextCursorJson: '{"token":"a","page":2}',
          ),
        ),
      ]);
    final controller = _controller(service);
    addTearDown(controller.dispose);
    await controller.loadMore();
    expect(controller.hasMore, isTrue);
    await controller.loadMore();
    expect(controller.error, isA<FormatException>());
  });
}
