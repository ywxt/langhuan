import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/comments/comments_controller.dart';
import 'package:langhuan/src/rust/api/comments.dart';
import '../feeds/fake_feed_service.dart';

class _Request implements CommentRequest {
  _Request(this.page);
  final Future<CommentPage> page;
  bool cancelled = false;
  bool failCancel = false;
  @override
  Future<CommentPage> result() => page;
  @override
  Future<void> cancel() async {
    cancelled = true;
    if (failCancel) throw StateError('cancel failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends FakeFeedService {
  final requests = <_Request>[];
  bool failCancel = false;
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
    final request = _Request(pages.removeAt(0))..failCancel = failCancel;
    requests.add(request);
    return request;
  }
}

CommentItem _item(String id, {int? likes, int? createdAtMs}) => CommentItem(
  id: id,
  author: const CommentAuthor(name: 'Author'),
  text: id,
  likeCount: likes,
  createdAtMs: createdAtMs,
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
  test(
    'cleanup failures do not leave a successful page loading or prevent refresh',
    () async {
      final service = _Service()..failCancel = true;
      service.pages.add(Future.value(CommentPage(items: [_item('1')])));
      final controller = _controller(service);
      addTearDown(controller.dispose);
      await controller.loadMore();
      expect(controller.loading, isFalse);
      expect(controller.hasLoadedPage, isTrue);
      expect(controller.error, isNull);
      expect(controller.items.single.id, '1');
      service.pages.add(Future.value(CommentPage(items: [_item('2')])));
      await controller.refresh();
      expect(controller.items.single.id, '2');
      expect(controller.loading, isFalse);
    },
  );

  test('cleanup failures preserve the original page error', () async {
    final failure = StateError('page fetch failed');
    final service = _Service()..failCancel = true;
    final result = Completer<CommentPage>();
    service.pages.add(result.future);
    final controller = _controller(service);
    addTearDown(controller.dispose);
    final loading = controller.loadMore();
    await Future<void>.delayed(Duration.zero);
    result.completeError(failure);
    await loading;
    expect(controller.error, same(failure));
    expect(controller.loading, isFalse);
    expect(controller.hasLoadedPage, isTrue);
  });

  test('hasLoadedPage flips once the first page settles', () async {
    final service = _Service()
      ..pages.add(
        Future.value(const CommentPage(items: [], nextCursorJson: null)),
      );
    final controller = _controller(service);
    addTearDown(controller.dispose);
    // Nothing fetched yet: the content is unknown, not empty.
    expect(controller.hasLoadedPage, isFalse);
    await controller.loadMore();
    expect(controller.hasLoadedPage, isTrue);

    // A refresh keeps the known-content guarantee through its reload.
    service.pages.add(Future.value(CommentPage(items: [_item('1')])));
    await controller.refresh();
    expect(controller.hasLoadedPage, isTrue);
  });

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
  test('hot sort orders by likes, then time, then arrival', () async {
    final service = _Service()
      ..pages.add(
        Future.value(
          CommentPage(
            items: [
              _item('low', likes: 1),
              _item('top', likes: 9),
              _item('mid', likes: 5),
            ],
          ),
        ),
      );
    final controller = _controller(service);
    addTearDown(controller.dispose);
    await controller.loadMore();
    expect(controller.items.map((c) => c.id), ['top', 'mid', 'low']);
  });
  test(
    'unknown likes rank as zero and keep arrival order among ties',
    () async {
      final service = _Service()
        ..pages.add(
          Future.value(
            CommentPage(
              items: [_item('none-1'), _item('one', likes: 1), _item('none-2')],
            ),
          ),
        );
      final controller = _controller(service);
      addTearDown(controller.dispose);
      await controller.loadMore();
      expect(controller.items.map((c) => c.id), ['one', 'none-1', 'none-2']);
    },
  );
  test('pages loaded later merge into the current ranking', () async {
    final service = _Service()
      ..pages.addAll([
        Future.value(
          CommentPage(
            items: [_item('a', likes: 3)],
            nextCursorJson: '{"page":2}',
          ),
        ),
        Future.value(CommentPage(items: [_item('b', likes: 7)])),
      ]);
    final controller = _controller(service);
    addTearDown(controller.dispose);
    await controller.loadMore();
    await controller.loadMore();
    expect(controller.items.map((c) => c.id), ['b', 'a']);
  });
  test('setSort re-orders loaded comments and later pages', () async {
    final service = _Service()
      ..pages.addAll([
        Future.value(
          CommentPage(
            items: [
              _item('old-but-liked', likes: 2, createdAtMs: 100),
              _item('new', createdAtMs: 900),
              _item('older', createdAtMs: 50),
            ],
            nextCursorJson: '{"page":2}',
          ),
        ),
        Future.value(CommentPage(items: [_item('newest', createdAtMs: 9999)])),
      ]);
    final controller = _controller(service);
    addTearDown(controller.dispose);
    await controller.loadMore();
    // Default hot order: likes first, time breaks the zero-like ties.
    expect(controller.items.map((c) => c.id), [
      'old-but-liked',
      'new',
      'older',
    ]);
    controller.setSort(CommentsSort.latest);
    expect(controller.items.map((c) => c.id), [
      'new',
      'old-but-liked',
      'older',
    ]);
    await controller.loadMore();
    expect(controller.items.map((c) => c.id), [
      'newest',
      'new',
      'old-but-liked',
      'older',
    ]);
    controller.setSort(CommentsSort.hot);
    expect(controller.items.map((c) => c.id), [
      'old-but-liked',
      'newest',
      'new',
      'older',
    ]);
  });
  test('setSort with the current mode is a silent no-op', () {
    final controller = _controller(_Service());
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => ++notified);
    controller.setSort(CommentsSort.hot);
    expect(notified, 0);
  });
  test('reply frames keep the source order despite likes and times', () async {
    final service = _Service()
      ..pages.addAll([
        Future.value(
          CommentPage(
            items: [
              _item('plain', createdAtMs: 10),
              _item('liked', likes: 99),
              _item('newest', createdAtMs: 999),
            ],
            nextCursorJson: '{"page":2}',
          ),
        ),
        Future.value(
          CommentPage(items: [_item('tail', likes: 88, createdAtMs: 888)]),
        ),
      ]);
    final controller = _controller(service, parent: 'root');
    addTearDown(controller.dispose);
    await controller.loadMore();
    await controller.loadMore();
    expect(controller.items.map((c) => c.id), [
      'plain',
      'liked',
      'newest',
      'tail',
    ]);
  });
  test('setSort on a reply frame is a silent no-op', () async {
    final service = _Service()
      ..pages.add(
        Future.value(
          CommentPage(items: [_item('first'), _item('second', likes: 5)]),
        ),
      );
    final controller = _controller(service, parent: 'root');
    addTearDown(controller.dispose);
    await controller.loadMore();
    var notified = 0;
    controller.addListener(() => ++notified);
    controller.setSort(CommentsSort.latest);
    expect(controller.items.map((c) => c.id), ['first', 'second']);
    expect(notified, 0);
  });
}
