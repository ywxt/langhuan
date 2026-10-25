import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

/// Hand-rolled [FeedService] fake for notifier unit tests.
///
/// Handlers are assigned per test; anything called without a handler fails
/// the test through [noSuchMethod].
class FakeFeedService implements FeedService {
  FakeFeedService({
    this.searchHandler,
    this.searchAllHandler,
    this.bookshelfUpdatesHandler,
    this.listFeedsHandler,
    this.removeFeedHandler,
    this.listBookmarksHandler,
    this.chaptersHandler,
    this.paragraphsHandler,
    this.markBookshelfSeenHandler,
  });

  final Stream<SearchResultModel> Function(String feedId, String keyword)?
  searchHandler;
  final Stream<AggregatedSearchEventModel> Function(String keyword)?
  searchAllHandler;
  final Stream<BookshelfUpdateModel> Function()? bookshelfUpdatesHandler;
  final Future<List<FeedMetaItem>> Function()? listFeedsHandler;
  final Future<void> Function(String feedId)? removeFeedHandler;

  @override
  Stream<SearchResultModel> search({
    required String feedId,
    required String keyword,
  }) {
    final handler = searchHandler;
    if (handler == null) {
      throw UnimplementedError('search not configured for this test');
    }
    return handler(feedId, keyword);
  }

  @override
  Stream<AggregatedSearchEventModel> searchAll({required String keyword}) {
    final handler = searchAllHandler;
    if (handler == null) {
      throw UnimplementedError('searchAll not configured for this test');
    }
    return handler(keyword);
  }

  @override
  Stream<BookshelfUpdateModel> bookshelfUpdates() {
    final handler = bookshelfUpdatesHandler;
    if (handler == null) {
      throw UnimplementedError('bookshelfUpdates not configured for this test');
    }
    return handler();
  }

  @override
  Future<List<FeedMetaItem>> listFeeds() {
    final handler = listFeedsHandler;
    if (handler == null) {
      throw UnimplementedError('listFeeds not configured for this test');
    }
    return handler();
  }

  @override
  Future<void> removeFeed(String feedId) {
    final handler = removeFeedHandler;
    if (handler == null) {
      throw UnimplementedError('removeFeed not configured for this test');
    }
    return handler(feedId);
  }

  final Future<List<BookmarkModel>> Function(String feedId, String bookId)?
  listBookmarksHandler;

  @override
  Future<List<BookmarkModel>> listBookmarks({
    required String feedId,
    required String bookId,
  }) {
    final handler = listBookmarksHandler;
    if (handler == null) {
      throw UnimplementedError('listBookmarks not configured for this test');
    }
    return handler(feedId, bookId);
  }

  final Stream<ChapterInfoModel> Function(String feedId, String bookId)?
  chaptersHandler;

  @override
  Stream<ChapterInfoModel> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) {
    final handler = chaptersHandler;
    if (handler == null) {
      throw UnimplementedError('chapters not configured for this test');
    }
    return handler(feedId, bookId);
  }

  final Stream<ParagraphContent> Function(
    String feedId,
    String bookId,
    String chapterId, {
    bool forceRefresh,
  })?
  paragraphsHandler;

  @override
  Stream<ParagraphContent> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) {
    final handler = paragraphsHandler;
    if (handler == null) {
      throw UnimplementedError('paragraphs not configured for this test');
    }
    return handler(feedId, bookId, chapterId, forceRefresh: forceRefresh);
  }

  final Future<void> Function(String feedId, String sourceBookId, int count)?
  markBookshelfSeenHandler;

  @override
  Future<void> markBookshelfSeen({
    required String feedId,
    required String sourceBookId,
    required int chapterCount,
  }) {
    final handler = markBookshelfSeenHandler;
    if (handler == null) {
      throw UnimplementedError('markBookshelfSeen not configured for this test');
    }
    return handler(feedId, sourceBookId, chapterCount);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'FakeFeedService: ${invocation.memberName} not configured for this test',
    );
  }
}
