// Feed/bookshelf lifecycle integration test.
//
// Uses the real Rust hub, SQLite repository and a hermetic Lua feed. Run on
// Android without uninstalling the user's app data:
//
//   flutter test integration_test/feed_bookshelf_lifecycle_test.dart \
//     -d emulator-5554 --no-uninstall

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_operation.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

import 'fixture_feed.dart';

const _feedId = 'lifecycle-fixture';
const _bookId = '1001';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('feed and bookshelf data follow their complete lifecycle', (
    tester,
  ) async {
    await RustLib.init();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path.startsWith('/search')) {
        request.response.write('1');
      } else if (request.uri.path.startsWith('/chapters')) {
        request.response.write('3');
      } else {
        request.response.write('fixture');
      }
      await request.response.close();
    });

    final tmp = await getTemporaryDirectory();
    final dataDir = Directory(
      '${tmp.path}/feed-lifecycle-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    await dataDir.create(recursive: true);
    expect(await AppService.instance.setAppDataDirectory(dataDir.path), 0);

    await installFixtureFeed(
      id: _feedId,
      name: 'Lifecycle Fixture',
      port: server.port,
      dataDir: dataDir,
    );
    final service = FeedService.instance;

    var feeds = await service.listFeeds();
    expect(feeds.single.id, _feedId);
    expect(feeds.single.enabled, isTrue);

    await service.setFeedEnabled(feedId: _feedId, enabled: false);
    feeds = await service.listFeeds();
    expect(feeds.single.enabled, isFalse);
    expect(await service.searchAll(keyword: 'fixture').toList(), isEmpty);

    // Explicit single-source actions remain available while paused.
    var results = await service
        .search(feedId: _feedId, keyword: 'fixture')
        .toList();
    expect(results, hasLength(1));

    await service.setFeedEnabled(feedId: _feedId, enabled: true);
    results = await service
        .search(feedId: _feedId, keyword: 'fixture')
        .toList();
    final book = results.single;

    expect(
      await service.addToBookshelf(
        feedId: _feedId,
        sourceBookId: book.id,
        title: book.title,
        author: book.author,
      ),
      BookshelfAddResult.added,
    );
    expect(
      await service.addToBookshelf(
        feedId: _feedId,
        sourceBookId: book.id,
        title: book.title,
        author: book.author,
      ),
      BookshelfAddResult.alreadyExists,
    );

    final chapters = await service
        .chapters(feedId: _feedId, bookId: _bookId)
        .toList();
    expect(chapters.map((chapter) => chapter.id), ['1', '2', '3']);

    await service.setReadingProgress(
      feedId: _feedId,
      bookId: _bookId,
      chapterId: '2',
      paragraphId: '0',
      paragraphCharOffset: 7,
      updatedAtMs: 1234,
    );
    final progress = await service.getReadingProgress(
      feedId: _feedId,
      bookId: _bookId,
    );
    expect(progress?.chapterId, '2');
    expect(progress?.paragraphCharOffset, 7);

    final shelf = await service.listBookshelf();
    expect(shelf, hasLength(1));
    expect(shelf.single.progressCurrentChapter, 2);
    expect(shelf.single.progressTotalChapters, 3);

    final bookmark = await service.addBookmark(
      feedId: _feedId,
      bookId: _bookId,
      chapterId: '2',
      paragraphId: '0',
      paragraphName: 'Paragraph 1',
      paragraphPreview: 'Fixture paragraph.',
      label: 'Keep',
    );
    expect(
      (await service.listBookmarks(feedId: _feedId, bookId: _bookId)).single.id,
      bookmark.id,
    );

    expect(
      await service.removeFromBookshelf(feedId: _feedId, sourceBookId: _bookId),
      BookshelfRemoveResult.removed,
    );
    expect(await service.listBookshelf(), isEmpty);
    expect(
      await service.getReadingProgress(feedId: _feedId, bookId: _bookId),
      isNull,
    );
    expect(
      await service.listBookmarks(feedId: _feedId, bookId: _bookId),
      isEmpty,
    );
    expect(
      await service.removeFromBookshelf(feedId: _feedId, sourceBookId: _bookId),
      BookshelfRemoveResult.notFound,
    );

    await service.addToBookshelf(
      feedId: _feedId,
      sourceBookId: _bookId,
      title: book.title,
      author: book.author,
    );
    await service.removeFeed(_feedId);
    expect(
      (await service.listFeeds()).where((feed) => feed.id == _feedId),
      isEmpty,
    );
    expect(await service.listBookshelf(), isEmpty);
  });
}
