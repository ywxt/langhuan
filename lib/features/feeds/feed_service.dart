import 'package:flutter/foundation.dart';

import '../../src/rust/api/auth.dart' as rust_auth;
import '../../src/rust/api/bookmark.dart' as rust_bookmark;
import '../../src/rust/api/bookshelf.dart' as rust_bookshelf;
import '../../src/rust/api/feed_stream.dart' as rust_stream;
import '../../src/rust/api/reading_progress.dart' as rust_progress;
import '../../src/rust/api/registry.dart' as rust_registry;
import '../../src/rust/api/transfer.dart' as rust_transfer;
import '../../src/rust/api/webview.dart' as rust_webview;
import '../../src/rust/api/types.dart';
import '../bookshelf/bookshelf_operation.dart';

// ---------------------------------------------------------------------------
// ParagraphId ↔ String helpers (synchronous, no FFI round-trip)
// ---------------------------------------------------------------------------

extension ParagraphIdStringExt on ParagraphId {
  String toStringValue() => switch (this) {
    ParagraphId_Index(field0: final i) => i.toString(),
    ParagraphId_Id(field0: final s) => s,
  };
}

ParagraphId paragraphIdFromString(String s) {
  final i = int.tryParse(s);
  return i != null ? ParagraphId.index(i) : ParagraphId.id(s);
}

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

/// One event of an aggregated (all-feeds) search, flattened for the UI:
/// either [item] from [feedId], or that source's terminal [error].
@immutable
class AggregatedSearchEventModel {
  const AggregatedSearchEventModel({
    required this.feedId,
    required this.feedName,
    this.item,
    this.error,
  });

  final String feedId;
  final String feedName;
  final SearchResultModel? item;
  final String? error;

  factory AggregatedSearchEventModel.fromRust(AggregatedSearchEvent event) =>
      switch (event) {
        AggregatedSearchEvent_Item(
          :final feedId,
          :final feedName,
          :final item,
        ) =>
          AggregatedSearchEventModel(
            feedId: feedId,
            feedName: feedName,
            item: SearchResultModel.fromRust(item),
          ),
        AggregatedSearchEvent_FeedError(
          :final feedId,
          :final feedName,
          :final error,
        ) =>
          AggregatedSearchEventModel(
            feedId: feedId,
            feedName: feedName,
            error: error,
          ),
      };
}

@immutable
class ChapterInfoModel {
  const ChapterInfoModel({required this.id, required this.title});

  final String id;
  final String title;

  factory ChapterInfoModel.fromRust(ChapterItem item) =>
      ChapterInfoModel(id: item.id, title: item.title);
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
    required this.versionChange,
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

  /// How [version] relates to the installed [currentVersion].
  final VersionChange versionChange;
}

@immutable
class BookshelfItemModel {
  const BookshelfItemModel({
    required this.feedId,
    required this.sourceBookId,
    required this.title,
    required this.author,
    required this.addedAtUnixMs,
    this.feedEnabled = true,
    this.coverUrl,
    this.description,
    this.progressCurrentChapter,
    this.progressTotalChapters,
    this.progressChapterTitle,
    this.progressCurrentParagraph,
    this.progressTotalParagraphs,
  });

  final String feedId;
  final String sourceBookId;
  final String title;
  final String author;
  final int addedAtUnixMs;
  final bool feedEnabled;
  final String? coverUrl;
  final String? description;
  final int? progressCurrentChapter;
  final int? progressTotalChapters;
  final String? progressChapterTitle;
  final int? progressCurrentParagraph;
  final int? progressTotalParagraphs;

  /// A copy with the feed's enabled flag replaced.
  ///
  /// Used to keep shelved books in sync when their feed is paused or
  /// resumed without re-fetching the whole shelf.
  BookshelfItemModel withFeedEnabled(bool value) => BookshelfItemModel(
    feedId: feedId,
    sourceBookId: sourceBookId,
    title: title,
    author: author,
    addedAtUnixMs: addedAtUnixMs,
    feedEnabled: value,
    coverUrl: coverUrl,
    description: description,
    progressCurrentChapter: progressCurrentChapter,
    progressTotalChapters: progressTotalChapters,
    progressChapterTitle: progressChapterTitle,
    progressCurrentParagraph: progressCurrentParagraph,
    progressTotalParagraphs: progressTotalParagraphs,
  );

  double? get progressFraction {
    final current = progressCurrentChapter;
    final total = progressTotalChapters;
    if (current == null || total == null || total <= 0) return null;
    final currentParagraph = progressCurrentParagraph;
    final totalParagraphs = progressTotalParagraphs;
    if (currentParagraph != null &&
        totalParagraphs != null &&
        totalParagraphs > 0) {
      final chapterPart = (currentParagraph / totalParagraphs).clamp(0.0, 1.0);
      return ((current - 1 + chapterPart) / total).clamp(0.0, 1.0);
    }
    return (current / total).clamp(0.0, 1.0);
  }

  String get stableId => '$feedId:$sourceBookId';

  /// Chapter title of the last read position, when cached and non-blank.
  String? get progressChapterTitleOrNull {
    final title = progressChapterTitle?.trim();
    return (title == null || title.isEmpty) ? null : title;
  }

  factory BookshelfItemModel.fromRust(BookshelfListItem item) =>
      BookshelfItemModel(
        feedId: item.feedId,
        sourceBookId: item.sourceBookId,
        title: item.title,
        author: item.author,
        addedAtUnixMs: item.addedAtUnixMs,
        feedEnabled: item.feedEnabled,
        coverUrl: item.coverUrl,
        description: item.descriptionSnapshot,
        progressCurrentChapter: item.progressCurrentChapter,
        progressTotalChapters: item.progressTotalChapters,
        progressChapterTitle: item.progressChapterTitle,
        progressCurrentParagraph: item.progressCurrentParagraph,
        progressTotalParagraphs: item.progressTotalParagraphs,
      );
}

@immutable
class BookshelfUpdateModel {
  const BookshelfUpdateModel({
    required this.feedId,
    required this.sourceBookId,
    required this.newChapters,
    this.error,
  });

  final String feedId;
  final String sourceBookId;
  final int newChapters;

  /// Non-null when this book's check failed (dead source, network, auth).
  final String? error;

  factory BookshelfUpdateModel.fromRust(BookshelfUpdateItem item) =>
      BookshelfUpdateModel(
        feedId: item.feedId,
        sourceBookId: item.sourceBookId,
        newChapters: item.newChapters,
        error: item.error,
      );
}

@immutable
class ReadingProgressModel {
  const ReadingProgressModel({
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    required this.paragraphId,
    this.paragraphCharOffset = 0,
    required this.updatedAtMs,
  });

  final String feedId;
  final String bookId;
  final String chapterId;
  final String paragraphId;

  /// Character offset of the page-leading character within the paragraph
  /// (horizontal mode). Lets restore land on the exact page when a paragraph
  /// spans two pages; 0 means the paragraph's start.
  final int paragraphCharOffset;

  final int updatedAtMs;

  factory ReadingProgressModel.fromRust(ReadingProgressItem item) =>
      ReadingProgressModel(
        feedId: item.feedId,
        bookId: item.bookId,
        chapterId: item.chapterId,
        paragraphId: item.paragraphId.toStringValue(),
        paragraphCharOffset: item.paragraphCharOffset,
        updatedAtMs: item.updatedAtMs,
      );
}

@immutable
class BookmarkModel {
  const BookmarkModel({
    required this.id,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    required this.paragraphId,
    required this.paragraphName,
    required this.paragraphPreview,
    required this.label,
    required this.createdAtMs,
  });

  final String id;
  final String feedId;
  final String bookId;
  final String chapterId;
  final String paragraphId;
  final String paragraphName;
  final String paragraphPreview;
  final String label;
  final int createdAtMs;

  factory BookmarkModel.fromRust(BookmarkItem item) => BookmarkModel(
    id: item.id,
    feedId: item.feedId,
    bookId: item.bookId,
    chapterId: item.chapterId,
    paragraphId: item.paragraphId.toStringValue(),
    paragraphName: item.paragraphName,
    paragraphPreview: item.paragraphPreview,
    label: item.label,
    createdAtMs: item.createdAtMs,
  );
}

enum FeedAuthStatusModel { loggedIn, loggedOut, expired, unsupported }

/// A verification page a feed requested interactively (reducer `webview`
/// step). The Rust side parks the originating operation until the prompt
/// is answered.
@immutable
class WebviewPromptModel {
  const WebviewPromptModel({
    required this.requestId,
    required this.feedId,
    required this.feedName,
    required this.url,
    this.title,
  });

  final int requestId;
  final String feedId;
  final String feedName;
  final String url;
  final String? title;

  factory WebviewPromptModel.fromRust(WebviewPrompt prompt) =>
      WebviewPromptModel(
        requestId: prompt.requestId,
        feedId: prompt.feedId,
        feedName: prompt.feedName,
        url: prompt.url,
        title: prompt.title,
      );
}

@immutable
class FeedAuthEntryModel {
  const FeedAuthEntryModel({required this.url, this.title});

  final String url;
  final String? title;
}

// ---------------------------------------------------------------------------
// FeedService
// ---------------------------------------------------------------------------

/// Wraps FRB-generated Rust API calls into a convenient service layer.
class FeedService {
  FeedService._();

  static final FeedService instance = FeedService._();

  /// The open/pull/cancel dance shared by every streaming API: FRB exposes
  /// each stream as an opaque wrapper with `next()`/`cancel()`, which this
  /// helper turns into a Dart stream that always cancels the Rust side.
  static Stream<T> _pull<S, T>(
    Future<S> Function() open,
    Future<T?> Function(S stream) next,
    void Function(S stream) cancel,
  ) async* {
    final stream = await open();
    try {
      while (true) {
        final item = await next(stream);
        if (item == null) break;
        yield item;
      }
    } finally {
      cancel(stream);
    }
  }

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  Stream<SearchResultModel> search({
    required String feedId,
    required String keyword,
  }) {
    return _pull(
      () => rust_stream.openSearchStream(feedId: feedId, keyword: keyword),
      (stream) => stream.next(),
      (stream) => stream.cancel(),
    ).map(SearchResultModel.fromRust);
  }

  /// Search every installed feed concurrently. Each event carries its
  /// source; a failing source yields an event with [error] set instead of
  /// ending the stream.
  Stream<AggregatedSearchEventModel> searchAll({required String keyword}) {
    return _pull(
      () => rust_stream.openAggregatedSearchStream(keyword: keyword),
      (stream) => stream.next(),
      (stream) => stream.cancel(),
    ).map(AggregatedSearchEventModel.fromRust);
  }

  // -------------------------------------------------------------------------
  // Chapters
  // -------------------------------------------------------------------------

  Stream<ChapterInfoModel> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) {
    return _pull(
      () => rust_stream.openChaptersStream(
        feedId: feedId,
        bookId: bookId,
        forceRefresh: forceRefresh,
      ),
      (stream) => stream.next(),
      (stream) => stream.cancel(),
    ).map(ChapterInfoModel.fromRust);
  }

  // -------------------------------------------------------------------------
  // Book info
  // -------------------------------------------------------------------------

  Future<BookInfoModel> bookInfo({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) async {
    final info = await rust_stream.bookInfo(
      feedId: feedId,
      bookId: bookId,
      forceRefresh: forceRefresh,
    );
    return BookInfoModel.fromRust(info);
  }

  // -------------------------------------------------------------------------
  // Paragraphs
  // -------------------------------------------------------------------------

  Stream<ParagraphContent> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) {
    return _pull(
      () => rust_stream.openParagraphsStream(
        feedId: feedId,
        bookId: bookId,
        chapterId: chapterId,
        forceRefresh: forceRefresh,
      ),
      (stream) => stream.next(),
      (stream) => stream.cancel(),
    );
  }

  // -------------------------------------------------------------------------
  // Bookshelf
  // -------------------------------------------------------------------------

  /// Add a book to the bookshelf.
  ///
  /// [title]/[author]/[coverUrl]/[description] form the display snapshot the
  /// shelf renders from — taken from the search result or detail page the
  /// user is looking at.
  Future<BookshelfAddResult> addToBookshelf({
    required String feedId,
    required String sourceBookId,
    required String title,
    required String author,
    String? coverUrl,
    String? description,
  }) async {
    final outcome = await rust_bookshelf.bookshelfAdd(
      feedId: feedId,
      sourceBookId: sourceBookId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      description: description,
    );
    return switch (outcome) {
      BookshelfAddOutcome.added => BookshelfAddResult.added,
      BookshelfAddOutcome.alreadyExists => BookshelfAddResult.alreadyExists,
    };
  }

  Future<BookshelfRemoveResult> removeFromBookshelf({
    required String feedId,
    required String sourceBookId,
  }) async {
    final outcome = await rust_bookshelf.bookshelfRemove(
      feedId: feedId,
      sourceBookId: sourceBookId,
    );
    return switch (outcome) {
      BookshelfRemoveOutcome.removed => BookshelfRemoveResult.removed,
      BookshelfRemoveOutcome.notFound => BookshelfRemoveResult.notFound,
    };
  }

  Future<List<BookshelfItemModel>> listBookshelf() async {
    final items = await rust_bookshelf.bookshelfList();
    final result = items
        .map(BookshelfItemModel.fromRust)
        .toList(growable: false);
    result.sort((a, b) => b.addedAtUnixMs.compareTo(a.addedAtUnixMs));
    return result;
  }

  /// Check every shelved book for new chapters; emits one item per book as
  /// each check completes.
  Stream<BookshelfUpdateModel> bookshelfUpdates() {
    return _pull(
      rust_bookshelf.openBookshelfUpdatesStream,
      (stream) => stream.next(),
      (stream) => stream.cancel(),
    ).map(BookshelfUpdateModel.fromRust);
  }

  /// Record the chapter count the user has just seen, clearing the book's
  /// update badge until new chapters appear.
  Future<void> markBookshelfSeen({
    required String feedId,
    required String sourceBookId,
    required int chapterCount,
  }) async {
    try {
      await rust_bookshelf.markBookshelfSeen(
        feedId: feedId,
        sourceBookId: sourceBookId,
        chapterCount: chapterCount,
      );
    } on BridgeError {
      // Marking seen is best-effort: a failure only means the badge may
      // re-appear on the next check.
    }
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
    required String paragraphId,
    int paragraphCharOffset = 0,
    required int updatedAtMs,
  }) {
    return rust_progress.setReadingProgress(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphId: paragraphIdFromString(paragraphId),
      paragraphCharOffset: paragraphCharOffset,
      updatedAtMs: updatedAtMs,
    );
  }

  // -------------------------------------------------------------------------
  // Bookmarks
  // -------------------------------------------------------------------------

  Future<List<BookmarkModel>> listBookmarks({
    required String feedId,
    required String bookId,
  }) async {
    final items = await rust_bookmark.listBookmarks(
      feedId: feedId,
      bookId: bookId,
    );
    final result = items.map(BookmarkModel.fromRust).toList(growable: false);
    result.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return result;
  }

  Future<BookmarkModel> addBookmark({
    required String feedId,
    required String bookId,
    required String chapterId,
    required String paragraphId,
    required String paragraphName,
    required String paragraphPreview,
    String label = '',
  }) async {
    final item = await rust_bookmark.addBookmark(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphId: paragraphIdFromString(paragraphId),
      paragraphName: paragraphName,
      paragraphPreview: paragraphPreview,
      label: label,
    );
    return BookmarkModel.fromRust(item);
  }

  Future<bool> removeBookmark({required String id}) {
    return rust_bookmark.removeBookmark(id: id);
  }

  // -------------------------------------------------------------------------
  // Feed list
  // -------------------------------------------------------------------------

  Future<List<FeedMetaItem>> listFeeds() {
    return rust_registry.listFeeds();
  }

  /// Pause (`enabled = false`) or resume a feed. Paused feeds are excluded
  /// from aggregated search and bookshelf update checks; explicit
  /// single-feed actions keep working.
  Future<void> setFeedEnabled({required String feedId, required bool enabled}) {
    return rust_registry.setFeedEnabled(feedId: feedId, enabled: enabled);
  }

  // -------------------------------------------------------------------------
  // Feed export / import
  // -------------------------------------------------------------------------

  /// Every installed feed — scripts included — as a portable JSON document
  /// [FeedService.importFeeds] accepts back.
  Future<String> exportFeeds() {
    return rust_transfer.exportFeeds();
  }

  /// Parse a feed export and classify each entry against the installed
  /// registry, without installing anything.
  Future<List<FeedImportEntry>> previewImportFeeds(String json) {
    return rust_transfer.previewImportFeeds(json: json);
  }

  /// Install every feed from an export. Entries already installed at the
  /// exact same version and content are skipped; each other entry installs
  /// independently, and failures are collected per entry.
  Future<FeedImportOutcome> importFeeds(String json) {
    return rust_transfer.importFeeds(json: json);
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
      versionChange: info.versionChange,
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
    String? userAgent,
  }) {
    return rust_auth.feedAuthSubmitPage(
      feedId: feedId,
      currentUrl: currentUrl,
      response: response,
      responseHeaders: responseHeaders,
      cookies: cookies,
      userAgent: userAgent,
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

  // -------------------------------------------------------------------------
  // WebView verification prompts
  // -------------------------------------------------------------------------

  /// Opens the single app-wide verification prompt stream. The coordinator
  /// presents each prompt and answers it via [completeWebview] or
  /// [cancelWebview].
  Future<rust_webview.WebviewPromptStream> openWebviewPromptStream() {
    return rust_webview.openWebviewPromptStream();
  }

  /// Delivers the page snapshot after the user finished verifying. Returns
  /// `false` when the request id is no longer pending.
  Future<bool> completeWebview({
    required int requestId,
    required String currentUrl,
    required String html,
    required List<CookieEntry> cookies,
    String? userAgent,
  }) {
    return rust_webview.completeWebview(
      requestId: requestId,
      currentUrl: currentUrl,
      html: html,
      cookies: cookies,
      userAgent: userAgent,
    );
  }

  /// Reports that the user abandoned the verification page. Returns `false`
  /// when the request id is no longer pending.
  Future<bool> cancelWebview(int requestId) {
    return rust_webview.cancelWebview(requestId: requestId);
  }
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

class FeedPullException implements Exception {
  const FeedPullException({required this.message, required this.kind});

  final String message;
  final ErrorKind kind;

  @override
  String toString() => 'FeedPullException: $message';
}

class FeedPreviewException implements Exception {
  const FeedPreviewException({required this.message, required this.kind});

  final String message;
  final ErrorKind kind;

  @override
  String toString() => 'FeedPreviewException: $message';
}
