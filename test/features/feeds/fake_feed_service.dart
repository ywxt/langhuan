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

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'FakeFeedService: ${invocation.memberName} not configured for this test',
    );
  }
}
