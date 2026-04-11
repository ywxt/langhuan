import 'package:flutter/foundation.dart';

import '../../src/rust/api/auth.dart' as rust_auth;
import '../../src/rust/api/bookshelf.dart' as rust_bookshelf;
import '../../src/rust/api/feed_stream.dart' as rust_stream;
import '../../src/rust/api/reading_progress.dart' as rust_progress;
import '../../src/rust/api/registry.dart' as rust_registry;
import '../../src/rust/api/types.dart';

// ---------------------------------------------------------------------------
// Domain models (mirrors Rust structs, kept for backward compat with UI)
// ---------------------------------------------------------------------------

@immutable
class SearchResultModel {
  const SearchResultModel({
    required this.id,
    required this.title,
    required this.author,
    this.coverUrl,
    this.description,
  });

  final String id;
  final String title;
  final String author;
  final String? coverUrl;
  final String? description;

  factory SearchResultModel.fromRust(SearchResultItem item) =>
      SearchResultModel(
        id: item.id,
        title: item.title,
        author: item.author,
        coverUrl: item.coverUrl,
        description: item.description,
      );
}

@immutable
class ChapterInfoModel {
  const ChapterInfoModel({
    required this.id,
    required this.title,
    required this.index,
  });

  final String id;
  final String title;
  final int index;

  factory ChapterInfoModel.fromRust(ChapterItem item) =>
      ChapterInfoModel(id: item.id, title: item.title, index: item.index);
}

@immutable
class BookInfoModel {
  const BookInfoModel({
    required this.id,
    required this.title,
    required this.author,
    this.coverUrl,
    this.description,
  });

  final String id;
  final String title;
  final String author;
  final String? coverUrl;
  final String? description;

  factory BookInfoModel.fromRust(BookInfo info) => BookInfoModel(
    id: info.id,
    title: info.title,
    author: info.author,
    coverUrl: info.coverUrl,
    description: info.description,
  );
}

@immutable
class FeedPreviewModel {
  const FeedPreviewModel({
    required this.requestId,
    required this.id,
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.accessDomains,
    this.author,
    this.description,
    this.currentVersion,
  });

  final String requestId;
  final String id;
  final String name;
  final String version;
  final String? author;
  final String? description;
  final String baseUrl;
  final List<String> accessDomains;
  final String? currentVersion;
}

@immutable
class BookshelfItemModel {
  const BookshelfItemModel({
    required this.feedId,
    required this.sourceBookId,
    required this.title,
    required this.author,
    required this.addedAtUnixMs,
    this.coverUrl,
    this.description,
  });

  final String feedId;
  final String sourceBookId;
  final String title;
  final String author;
  final int addedAtUnixMs;
  final String? coverUrl;
  final String? description;

  String get stableId => '$feedId:$sourceBookId';

  factory BookshelfItemModel.fromRust(BookshelfListItem item) =>
      BookshelfItemModel(
        feedId: item.feedId,
        sourceBookId: item.sourceBookId,
        title: item.title,
        author: item.author,
        addedAtUnixMs: item.addedAtUnixMs,
        coverUrl: item.coverUrl,
        description: item.descriptionSnapshot,
      );
}

@immutable
class ReadingProgressModel {
  const ReadingProgressModel({
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    required this.paragraphIndex,
    required this.updatedAtMs,
  });

  final String feedId;
  final String bookId;
  final String chapterId;
  final int paragraphIndex;
  final int updatedAtMs;

  factory ReadingProgressModel.fromRust(ReadingProgressItem item) =>
      ReadingProgressModel(
        feedId: item.feedId,
        bookId: item.bookId,
        chapterId: item.chapterId,
        paragraphIndex: item.paragraphIndex,
        updatedAtMs: item.updatedAtMs,
      );
}

enum FeedAuthStatusModel { loggedIn, loggedOut, expired, unsupported }

@immutable
class FeedAuthEntryModel {
  const FeedAuthEntryModel({required this.url, this.title});

  final String url;
  final String? title;
}

// ---------------------------------------------------------------------------
// Bookshelf operation outcome (kept for provider compat)
// ---------------------------------------------------------------------------

sealed class BookshelfOperationOutcome {
  const BookshelfOperationOutcome();
}

class BookshelfOperationOutcomeAdded extends BookshelfOperationOutcome {
  const BookshelfOperationOutcomeAdded();
}

class BookshelfOperationOutcomeAlreadyExists extends BookshelfOperationOutcome {
  const BookshelfOperationOutcomeAlreadyExists();
}

class BookshelfOperationOutcomeRemoved extends BookshelfOperationOutcome {
  const BookshelfOperationOutcomeRemoved();
}

class BookshelfOperationOutcomeNotFound extends BookshelfOperationOutcome {
  const BookshelfOperationOutcomeNotFound();
}

class BookshelfOperationOutcomeError extends BookshelfOperationOutcome {
  const BookshelfOperationOutcomeError({required this.message});
  final String message;
}

// ---------------------------------------------------------------------------
// FeedService
// ---------------------------------------------------------------------------

/// Wraps FRB-generated Rust API calls into a convenient service layer.
class FeedService {
  FeedService._();

  static final FeedService instance = FeedService._();

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  Stream<SearchResultModel> search({
    required String feedId,
    required String keyword,
  }) async* {
    final stream = await rust_stream.openSearchStream(
      feedId: feedId,
      keyword: keyword,
    );
    try {
      while (true) {
        final item = await stream.next();
        if (item == null) break;
        yield SearchResultModel.fromRust(item);
      }
    } finally {
      stream.cancel();
    }
  }

  // -------------------------------------------------------------------------
  // Chapters
  // -------------------------------------------------------------------------

  Stream<ChapterInfoModel> chapters({
    required String feedId,
    required String bookId,
  }) async* {
    final stream = await rust_stream.openChaptersStream(
      feedId: feedId,
      bookId: bookId,
    );
    try {
      while (true) {
        final item = await stream.next();
        if (item == null) break;
        yield ChapterInfoModel.fromRust(item);
      }
    } finally {
      stream.cancel();
    }
  }

  // -------------------------------------------------------------------------
  // Book info
  // -------------------------------------------------------------------------

  Future<BookInfoModel> bookInfo({
    required String feedId,
    required String bookId,
  }) async {
    final info = await rust_stream.bookInfo(feedId: feedId, bookId: bookId);
    return BookInfoModel.fromRust(info);
  }

  // -------------------------------------------------------------------------
  // Paragraphs
  // -------------------------------------------------------------------------

  Stream<ParagraphContent> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) async* {
    final stream = await rust_stream.openParagraphsStream(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
    );
    try {
      while (true) {
        final item = await stream.next();
        if (item == null) break;
        yield item;
      }
    } finally {
      stream.cancel();
    }
  }

  // -------------------------------------------------------------------------
  // Bookshelf
  // -------------------------------------------------------------------------

  Future<BookshelfOperationOutcome> addToBookshelf({
    required String feedId,
    required String sourceBookId,
  }) async {
    try {
      final outcome = await rust_bookshelf.bookshelfAdd(
        feedId: feedId,
        sourceBookId: sourceBookId,
      );
      return switch (outcome) {
        BookshelfAddOutcome.added => const BookshelfOperationOutcomeAdded(),
        BookshelfAddOutcome.alreadyExists =>
          const BookshelfOperationOutcomeAlreadyExists(),
      };
    } on BridgeError catch (e) {
      return BookshelfOperationOutcomeError(message: e.message);
    }
  }

  Future<BookshelfOperationOutcome> removeFromBookshelf({
    required String feedId,
    required String sourceBookId,
  }) async {
    try {
      final outcome = await rust_bookshelf.bookshelfRemove(
        feedId: feedId,
        sourceBookId: sourceBookId,
      );
      return switch (outcome) {
        BookshelfRemoveOutcome.removed =>
          const BookshelfOperationOutcomeRemoved(),
        BookshelfRemoveOutcome.notFound =>
          const BookshelfOperationOutcomeNotFound(),
      };
    } on BridgeError catch (e) {
      return BookshelfOperationOutcomeError(message: e.message);
    }
  }

  Future<List<BookshelfItemModel>> listBookshelf() async {
    final items = await rust_bookshelf.bookshelfList();
    final result = items
        .map(BookshelfItemModel.fromRust)
        .toList(growable: false);
    result.sort((a, b) => b.addedAtUnixMs.compareTo(a.addedAtUnixMs));
    return result;
  }

  // -------------------------------------------------------------------------
  // Reading progress
  // -------------------------------------------------------------------------

  Future<ReadingProgressModel?> getReadingProgress({
    required String feedId,
    required String bookId,
  }) async {
    final item = await rust_progress.getReadingProgress(
      feedId: feedId,
      bookId: bookId,
    );
    return item != null ? ReadingProgressModel.fromRust(item) : null;
  }

  Future<void> setReadingProgress({
    required String feedId,
    required String bookId,
    required String chapterId,
    required int paragraphIndex,
    required int updatedAtMs,
  }) {
    return rust_progress.setReadingProgress(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphIndex: paragraphIndex,
      updatedAtMs: updatedAtMs,
    );
  }

  // -------------------------------------------------------------------------
  // Feed list
  // -------------------------------------------------------------------------

  Future<List<FeedMetaItem>> listFeeds() {
    return rust_registry.listFeeds();
  }

  // -------------------------------------------------------------------------
  // Feed install
  // -------------------------------------------------------------------------

  Future<FeedPreviewModel> previewFromUrl(String url) async {
    final info = await rust_registry.previewFeedFromUrl(url: url);
    return _toPreviewModel(info);
  }

  Future<FeedPreviewModel> previewFromFile(String path) async {
    final info = await rust_registry.previewFeedFromFile(path: path);
    return _toPreviewModel(info);
  }

  /// Confirm installation of a previously previewed feed.
  ///
  /// [requestId] is the feed id returned by the preview call.
  Future<void> installFeed(String requestId) {
    return rust_registry.installFeed(requestId: requestId);
  }

  Future<void> removeFeed(String feedId) {
    return rust_registry.removeFeed(feedId: feedId);
  }

  FeedPreviewModel _toPreviewModel(FeedPreviewInfo info) {
    return FeedPreviewModel(
      requestId: info.id,
      id: info.id,
      name: info.name,
      version: info.version,
      author: info.author,
      description: info.description,
      baseUrl: info.baseUrl,
      accessDomains: info.accessDomains.toList(growable: false),
      currentVersion: info.currentVersion,
    );
  }

  // -------------------------------------------------------------------------
  // Feed auth
  // -------------------------------------------------------------------------

  Future<bool> isFeedAuthSupported(String feedId) async {
    final cap = await rust_auth.feedAuthCapability(feedId: feedId);
    return cap == AuthCapability.supported;
  }

  Future<FeedAuthEntryModel?> getFeedAuthEntry(String feedId) async {
    final entry = await rust_auth.feedAuthEntry(feedId: feedId);
    if (entry == null) return null;
    return FeedAuthEntryModel(url: entry.url, title: entry.title);
  }

  Future<void> submitFeedAuthPage({
    required String feedId,
    required String currentUrl,
    required String response,
    required List<(String, String)> responseHeaders,
    required List<CookieEntry> cookies,
  }) {
    return rust_auth.feedAuthSubmitPage(
      feedId: feedId,
      currentUrl: currentUrl,
      response: response,
      responseHeaders: responseHeaders,
      cookies: cookies,
    );
  }

  Future<FeedAuthStatusModel> getFeedAuthStatus(String feedId) async {
    final status = await rust_auth.feedAuthStatus(feedId: feedId);
    return switch (status) {
      AuthStatus.loggedIn => FeedAuthStatusModel.loggedIn,
      AuthStatus.expired => FeedAuthStatusModel.expired,
      AuthStatus.loggedOut => FeedAuthStatusModel.loggedOut,
    };
  }

  Future<void> clearFeedAuth(String feedId) {
    return rust_auth.feedAuthClear(feedId: feedId);
  }
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

class FeedPullException implements Exception {
  const FeedPullException({required this.message});

  final String message;

  @override
  String toString() => 'FeedPullException: $message';
}

class FeedPreviewException implements Exception {
  const FeedPreviewException({required this.message});

  final String message;

  @override
  String toString() => 'FeedPreviewException: $message';
}
