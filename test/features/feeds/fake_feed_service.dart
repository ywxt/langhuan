import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/bookshelf/bookshelf_operation.dart';
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
    this.listBookshelfHandler,
    this.addToBookshelfHandler,
    this.removeFromBookshelfHandler,
    this.listFeedsHandler,
    this.removeFeedHandler,
    this.setFeedEnabledHandler,
    this.exportFeedsHandler,
    this.previewImportFeedsHandler,
    this.importFeedsHandler,
    this.listBookmarksHandler,
    this.chaptersHandler,
    this.paragraphsHandler,
    this.markBookshelfSeenHandler,
    this.getReadingProgressHandler,
    this.setReadingProgressHandler,
    this.bookInfoHandler,
  });

  final Stream<SearchResultModel> Function(String feedId, String keyword)?
  searchHandler;
  final Stream<AggregatedSearchEventModel> Function(String keyword)?
  searchAllHandler;
  final Stream<BookshelfUpdateModel> Function()? bookshelfUpdatesHandler;
  final Future<List<BookshelfItemModel>> Function()? listBookshelfHandler;
  final Future<BookshelfAddResult> Function()? addToBookshelfHandler;
  final Future<BookshelfRemoveResult> Function()? removeFromBookshelfHandler;
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
  Future<List<BookshelfItemModel>> listBookshelf() {
    final handler = listBookshelfHandler;
    if (handler == null) {
      throw UnimplementedError('listBookshelf not configured for this test');
    }
    return handler();
  }

  @override
  Future<BookshelfAddResult> addToBookshelf({
    required String feedId,
    required String sourceBookId,
    required String title,
    required String author,
    String? coverUrl,
    String? description,
  }) {
    final handler = addToBookshelfHandler;
    if (handler == null) {
      throw UnimplementedError('addToBookshelf not configured for this test');
    }
    return handler();
  }

  @override
  Future<BookshelfRemoveResult> removeFromBookshelf({
    required String feedId,
    required String sourceBookId,
  }) {
    final handler = removeFromBookshelfHandler;
    if (handler == null) {
      throw UnimplementedError(
        'removeFromBookshelf not configured for this test',
      );
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

  final Future<void> Function(String feedId, bool enabled)?
  setFeedEnabledHandler;

  @override
  Future<void> setFeedEnabled({required String feedId, required bool enabled}) {
    final handler = setFeedEnabledHandler;
    if (handler == null) {
      throw UnimplementedError('setFeedEnabled not configured for this test');
    }
    return handler(feedId, enabled);
  }

  final Future<String> Function()? exportFeedsHandler;

  @override
  Future<String> exportFeeds() {
    final handler = exportFeedsHandler;
    if (handler == null) {
      throw UnimplementedError('exportFeeds not configured for this test');
    }
    return handler();
  }

  final Future<List<FeedImportEntry>> Function(String json)?
  previewImportFeedsHandler;

  @override
  Future<List<FeedImportEntry>> previewImportFeeds(String json) {
    final handler = previewImportFeedsHandler;
    if (handler == null) {
      throw UnimplementedError(
        'previewImportFeeds not configured for this test',
      );
    }
    return handler(json);
  }

  final Future<FeedImportOutcome> Function(String json)? importFeedsHandler;

  @override
  Future<FeedImportOutcome> importFeeds(String json) {
    final handler = importFeedsHandler;
    if (handler == null) {
      throw UnimplementedError('importFeeds not configured for this test');
    }
    return handler(json);
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

  final Future<List<ChapterInfoModel>> Function(String feedId, String bookId)?
  chaptersHandler;

  @override
  Future<List<ChapterInfoModel>> chapters({
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

  final Future<List<ParagraphContent>> Function(
    String feedId,
    String bookId,
    String chapterId, {
    bool forceRefresh,
  })?
  paragraphsHandler;

  @override
  Future<List<ParagraphContent>> paragraphs({
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
      throw UnimplementedError(
        'markBookshelfSeen not configured for this test',
      );
    }
    return handler(feedId, sourceBookId, chapterCount);
  }

  final Future<ReadingProgressModel?> Function(String feedId, String bookId)?
  getReadingProgressHandler;

  @override
  Future<ReadingProgressModel?> getReadingProgress({
    required String feedId,
    required String bookId,
  }) {
    final handler = getReadingProgressHandler;
    if (handler == null) {
      throw UnimplementedError(
        'getReadingProgress not configured for this test',
      );
    }
    return handler(feedId, bookId);
  }

  final Future<void> Function(
    String feedId,
    String bookId,
    String chapterId,
    String paragraphId,
    int paragraphCharOffset,
  )?
  setReadingProgressHandler;

  @override
  Future<void> setReadingProgress({
    required String feedId,
    required String bookId,
    required String chapterId,
    required String paragraphId,
    int paragraphCharOffset = 0,
    required int updatedAtMs,
  }) {
    final handler = setReadingProgressHandler;
    if (handler == null) {
      throw UnimplementedError(
        'setReadingProgress not configured for this test',
      );
    }
    return handler(feedId, bookId, chapterId, paragraphId, paragraphCharOffset);
  }

  final Future<BookInfoModel> Function(String feedId, String bookId)?
  bookInfoHandler;

  @override
  Future<BookInfoModel> bookInfo({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) {
    final handler = bookInfoHandler;
    if (handler == null) {
      throw UnimplementedError('bookInfo not configured for this test');
    }
    return handler(feedId, bookId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'FakeFeedService: ${invocation.memberName} not configured for this test',
    );
  }
}
