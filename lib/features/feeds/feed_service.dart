import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rinf/rinf.dart';

import '../../src/bindings/signals/signals.dart';

// ---------------------------------------------------------------------------
// Domain models (mirrors Rust structs)
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
}

@immutable
class FeedPreviewModel {
  const FeedPreviewModel({
    required this.requestId,
    required this.id,
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.allowedDomains,
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
  final List<String> allowedDomains;
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
}

@immutable
class BookshelfCapabilitiesModel {
  const BookshelfCapabilitiesModel({
    required this.feedId,
    required this.supportsBookshelf,
  });

  final String feedId;
  final bool supportsBookshelf;
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
}

// ---------------------------------------------------------------------------
// FeedService
// ---------------------------------------------------------------------------

/// Wraps Rinf broadcast signals into clean per-request Dart [Stream]s.
///
/// Each method:
/// 1. Generates a unique `requestId`.
/// 2. Sends the appropriate `DartSignal` to Rust.
/// 3. Returns a [Stream] that filters the global broadcast by `requestId`
///    and terminates when the matching [FeedStreamEnd] arrives.
///
/// Call [cancel] with the `requestId` to abort an in-progress stream.
class FeedService {
  FeedService._();

  static final FeedService instance = FeedService._();

  // -------------------------------------------------------------------------
  // Request ID generation
  // -------------------------------------------------------------------------

  int _counter = 0;

  /// Generate a unique request ID.
  String _nextId() =>
      'req-${DateTime.now().millisecondsSinceEpoch}-${_counter++}';

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  /// Start a search stream.
  ///
  /// Returns a record of `(requestId, stream)`.  Use `requestId` to cancel.
  ({String requestId, Stream<SearchResultModel> stream}) search({
    required String feedId,
    required String keyword,
  }) {
    final requestId = _nextId();

    final stream = _buildStream<SearchResultModel>(
      requestId: requestId,
      itemStream: SearchResultItem.rustSignalStream
          .where((pack) => pack.message.requestId == requestId)
          .map(
            (pack) => SearchResultModel(
              id: pack.message.id,
              title: pack.message.title,
              author: pack.message.author,
              coverUrl: pack.message.coverUrl,
              description: pack.message.description,
            ),
          ),
      send: () {
        SearchRequest(
          requestId: requestId,
          feedId: feedId,
          keyword: keyword,
        ).sendSignalToRust();
      },
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Chapters
  // -------------------------------------------------------------------------

  /// Start a chapters stream for a book.
  ({String requestId, Stream<ChapterInfoModel> stream}) chapters({
    required String feedId,
    required String bookId,
  }) {
    final requestId = _nextId();

    final stream = _buildStream<ChapterInfoModel>(
      requestId: requestId,
      itemStream: ChapterInfoItem.rustSignalStream
          .where((pack) => pack.message.requestId == requestId)
          .map(
            (pack) => ChapterInfoModel(
              id: pack.message.id,
              title: pack.message.title,
              index: pack.message.index,
            ),
          ),
      send: () {
        ChaptersRequest(
          requestId: requestId,
          feedId: feedId,
          bookId: bookId,
        ).sendSignalToRust();
      },
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Book info
  // -------------------------------------------------------------------------

  /// Request detailed information for a single book.
  Future<BookInfoModel> bookInfo({
    required String feedId,
    required String bookId,
  }) {
    return _subscribeAndSendNext(
      responseStream: BookInfoResult.rustSignalStream,
      send: () {
        BookInfoRequest(feedId: feedId, bookId: bookId).sendSignalToRust();
      },
    ).then((message) {
      final outcome = message.outcome;
      if (outcome is BookInfoOutcomeError) {
        throw BookInfoException(message: outcome.message);
      }
      final success = outcome as BookInfoOutcomeSuccess;
      return BookInfoModel(
        id: success.id,
        title: success.title,
        author: success.author,
        coverUrl: success.coverUrl,
        description: success.description,
      );
    });
  }

  // -------------------------------------------------------------------------
  // Chapter content
  // -------------------------------------------------------------------------

  /// Start a chapter-content stream.
  ({String requestId, Stream<ParagraphContent> stream}) chapterContent({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) {
    final requestId = _nextId();

    final stream = _buildStream<ParagraphContent>(
      requestId: requestId,
      itemStream: ChapterParagraphItem.rustSignalStream
          .where((pack) => pack.message.requestId == requestId)
          .map((pack) => pack.message.paragraph),
      send: () {
        ChapterContentRequest(
          requestId: requestId,
          feedId: feedId,
          bookId: bookId,
          chapterId: chapterId,
        ).sendSignalToRust();
      },
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Bookshelf
  // -------------------------------------------------------------------------

  Future<BookshelfOperationOutcome> addToBookshelf({
    required String feedId,
    required String sourceBookId,
    required String title,
    required String author,
    String? coverUrl,
    String? descriptionSnapshot,
  }) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: BookshelfAddResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () {
        BookshelfAddRequest(
          requestId: requestId,
          feedId: feedId,
          sourceBookId: sourceBookId,
          title: title,
          author: author,
          coverUrl: coverUrl,
          descriptionSnapshot: descriptionSnapshot,
        ).sendSignalToRust();
      },
    ).then((message) => message.outcome);
  }

  Future<BookshelfOperationOutcome> removeFromBookshelf({
    required String feedId,
    required String sourceBookId,
  }) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: BookshelfRemoveResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () {
        BookshelfRemoveRequest(
          requestId: requestId,
          feedId: feedId,
          sourceBookId: sourceBookId,
        ).sendSignalToRust();
      },
    ).then((message) => message.outcome);
  }

  Future<List<BookshelfItemModel>> listBookshelf() {
    final requestId = _nextId();
    final completer = Completer<List<BookshelfItemModel>>();
    final items = <BookshelfItemModel>[];

    StreamSubscription<RustSignalPack<BookshelfListItem>>? itemSub;
    StreamSubscription<RustSignalPack<BookshelfListEnd>>? endSub;

    itemSub = BookshelfListItem.rustSignalStream
        .where((pack) => pack.message.requestId == requestId)
        .listen((pack) {
          final it = pack.message;
          items.add(
            BookshelfItemModel(
              feedId: it.feedId,
              sourceBookId: it.sourceBookId,
              title: it.title,
              author: it.author,
              coverUrl: it.coverUrl,
              description: it.descriptionSnapshot,
              addedAtUnixMs: it.addedAtUnixMs,
            ),
          );
        });

    endSub = BookshelfListEnd.rustSignalStream
        .where((pack) => pack.message.requestId == requestId)
        .listen((pack) async {
          final outcome = pack.message.outcome;
          await itemSub?.cancel();
          await endSub?.cancel();

          if (outcome is BookshelfListOutcomeFailed) {
            completer.completeError(
              BookshelfOperationException(message: outcome.message),
            );
            return;
          }

          items.sort((a, b) => b.addedAtUnixMs.compareTo(a.addedAtUnixMs));
          completer.complete(items);
        });

    BookshelfListRequest(requestId: requestId).sendSignalToRust();
    return completer.future;
  }

  Future<BookshelfCapabilitiesModel> bookshelfCapabilities({
    required String feedId,
  }) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: BookshelfCapabilitiesResult.rustSignalStream,
      matches: (message) =>
          message.requestId == requestId && message.feedId == feedId,
      send: () {
        BookshelfCapabilitiesRequest(
          requestId: requestId,
          feedId: feedId,
        ).sendSignalToRust();
      },
    ).then(
      (message) => BookshelfCapabilitiesModel(
        feedId: message.feedId,
        supportsBookshelf: message.supportsBookshelf,
      ),
    );
  }

  Future<ReadingProgressModel?> getReadingProgress({
    required String feedId,
    required String bookId,
  }) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: ReadingProgressGetResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () {
        ReadingProgressGetRequest(
          requestId: requestId,
          feedId: feedId,
          bookId: bookId,
        ).sendSignalToRust();
      },
    ).then((message) {
      final outcome = message.outcome;
      if (outcome is ReadingProgressGetOutcomeError) {
        throw ReadingProgressException(message: outcome.message);
      }

      final success = outcome as ReadingProgressGetOutcomeSuccess;
      final item = success.progress;
      if (item == null) {
        return null;
      }

      return ReadingProgressModel(
        feedId: item.feedId,
        bookId: item.bookId,
        chapterId: item.chapterId,
        paragraphIndex: item.paragraphIndex,
        updatedAtMs: item.updatedAtMs,
      );
    });
  }

  Future<void> setReadingProgress({
    required String feedId,
    required String bookId,
    required String chapterId,
    required int paragraphIndex,
    required int updatedAtMs,
  }) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: ReadingProgressSetResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () {
        ReadingProgressSetRequest(
          requestId: requestId,
          feedId: feedId,
          bookId: bookId,
          chapterId: chapterId,
          paragraphIndex: paragraphIndex,
          updatedAtMs: updatedAtMs,
        ).sendSignalToRust();
      },
    ).then((message) {
      final outcome = message.outcome;
      if (outcome is ReadingProgressSetOutcomeError) {
        throw ReadingProgressException(message: outcome.message);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Cancel
  // -------------------------------------------------------------------------

  /// Cancel an in-progress stream.  Rust will stop emitting items and send a
  /// [FeedStreamEnd] with `outcome == FeedStreamOutcomeCancelled`.
  void cancel(String requestId) {
    FeedCancelRequest(requestId: requestId).sendSignalToRust();
  }

  // -------------------------------------------------------------------------
  // App data directory
  // -------------------------------------------------------------------------

  /// Tell Rust which directory should be used as the app data root.
  ///
  /// Rust will keep feeds under `scripts/` and bookshelf data under
  /// `bookshelf/`, then respond with an [AppDataDirectorySet] signal. If the
  /// registry file does
  /// not exist yet, `success` will be `false` and an error message will be
  /// provided — no crash.
  ///
  /// Returns a [Future] that completes once Rust has finished loading.
  Future<AppDataDirectorySet> setAppDataDirectory(String path) {
    return _subscribeAndSendNext(
      responseStream: AppDataDirectorySet.rustSignalStream,
      send: () => SetAppDataDirectory(path: path).sendSignalToRust(),
    );
  }

  /// Request a list of all feeds currently loaded in Rust.
  ///
  /// Returns a [Future] that completes with the [FeedListResult] once Rust
  /// responds.
  Future<FeedListResult> listFeeds() {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: FeedListResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () => ListFeedsRequest(requestId: requestId).sendSignalToRust(),
    );
  }

  // -------------------------------------------------------------------------
  // Feed install
  // -------------------------------------------------------------------------

  /// Request a preview of a feed script from a remote [url].
  ///
  /// Returns a [Future] that resolves to a [FeedPreviewModel] once Rust has
  /// downloaded and parsed the script.  Throws a [FeedPreviewException] on
  /// failure.
  Future<FeedPreviewModel> previewFromUrl(String url) async {
    final requestId = _nextId();
    return _awaitPreview(
      requestId,
      () =>
          PreviewFeedFromUrl(requestId: requestId, url: url).sendSignalToRust(),
    );
  }

  /// Request a preview of a feed script from a local file [path].
  /// Rust reads the file, decodes it as UTF-8, and responds with a
  /// [FeedPreviewModel].  Throws a [FeedPreviewException] on failure.
  Future<FeedPreviewModel> previewFromFile(String path) async {
    final requestId = _nextId();
    return _awaitPreview(
      requestId,
      () => PreviewFeedFromFile(
        requestId: requestId,
        path: path,
      ).sendSignalToRust(),
    );
  }

  /// Confirm installation of a previously previewed feed.
  ///
  /// [requestId] must match the one returned by the preceding preview call.
  /// Returns a [Future] that resolves to the [FeedInstallResult] once Rust
  /// finishes writing the script to disk and updating the current registry.
  Future<FeedInstallResult> installFeed(String requestId) {
    return _subscribeAndSend(
      responseStream: FeedInstallResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () => InstallFeedRequest(requestId: requestId).sendSignalToRust(),
    );
  }

  /// Remove an installed feed by [feedId].
  ///
  /// Returns a [Future] that resolves to [FeedRemoveResult] when Rust finishes.
  Future<FeedRemoveResult> removeFeed(String feedId) {
    final requestId = _nextId();
    return _subscribeAndSend(
      responseStream: FeedRemoveResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: () => RemoveFeedRequest(
        requestId: requestId,
        feedId: feedId,
      ).sendSignalToRust(),
    );
  }

  Future<FeedPreviewModel> _awaitPreview(
    String requestId,
    void Function() send,
  ) {
    return _subscribeAndSend(
      responseStream: FeedPreviewResult.rustSignalStream,
      matches: (message) => message.requestId == requestId,
      send: send,
    ).then((message) {
      final outcome = message.outcome;
      if (outcome is FeedPreviewOutcomeError) {
        throw FeedPreviewException(message: outcome.message);
      }
      final success = outcome as FeedPreviewOutcomeSuccess;
      return FeedPreviewModel(
        requestId: message.requestId,
        id: success.id,
        name: success.name,
        version: success.version,
        author: success.author,
        description: success.description,
        baseUrl: success.baseUrl,
        allowedDomains: List.unmodifiable(success.allowedDomains),
        currentVersion: success.currentVersion,
      );
    });
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /// Build a [Stream<T>] that:
  /// - Emits items from [itemStream] as they arrive.
  /// - Terminates (closes) when the matching [FeedStreamEnd] arrives.
  /// - Throws a [FeedStreamException] if the outcome is `FeedStreamOutcomeFailed`.
  Stream<T> _buildStream<T>({
    required String requestId,
    required Stream<T> itemStream,
    required void Function() send,
  }) {
    late StreamController<T> controller;
    StreamSubscription<T>? itemSub;
    StreamSubscription<RustSignalPack<FeedStreamEnd>>? endSub;

    controller = StreamController<T>(
      onListen: () {
        // Listen for items.
        itemSub = itemStream.listen(
          controller.add,
          onError: controller.addError,
        );

        // Listen for the terminal signal.
        endSub = FeedStreamEnd.rustSignalStream
            .where((pack) => pack.message.requestId == requestId)
            .listen((pack) {
              final outcome = pack.message.outcome;
              if (outcome is FeedStreamOutcomeFailed) {
                controller.addError(
                  FeedStreamException(
                    requestId: requestId,
                    message: outcome.error,
                    retriedCount: outcome.retriedCount,
                  ),
                );
              }
              // Close regardless of outcome (completed / cancelled / failed).
              controller.close();
            });

        send();
      },
      onCancel: () {
        itemSub?.cancel();
        endSub?.cancel();
        // Also tell Rust to stop if the Dart side cancels.
        cancel(requestId);
      },
    );

    return controller.stream;
  }

  Future<T> _subscribeAndSend<T>({
    required Stream<RustSignalPack<T>> responseStream,
    required bool Function(T message) matches,
    required void Function() send,
  }) {
    final future = responseStream
        .where((pack) => matches(pack.message))
        .first
        .then((pack) => pack.message);
    send();
    return future;
  }

  Future<T> _subscribeAndSendNext<T>({
    required Stream<RustSignalPack<T>> responseStream,
    required void Function() send,
  }) {
    final future = responseStream.first.then((pack) => pack.message);
    send();
    return future;
  }
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

class FeedStreamException implements Exception {
  const FeedStreamException({
    required this.requestId,
    required this.message,
    required this.retriedCount,
  });

  final String requestId;
  final String message;
  final int retriedCount;

  @override
  String toString() =>
      'FeedStreamException[$requestId]: $message (retried $retriedCount times)';
}

class FeedPreviewException implements Exception {
  const FeedPreviewException({required this.message});

  final String message;

  @override
  String toString() => 'FeedPreviewException: $message';
}

class BookInfoException implements Exception {
  const BookInfoException({required this.message});

  final String message;

  @override
  String toString() => 'BookInfoException: $message';
}

class BookshelfOperationException implements Exception {
  const BookshelfOperationException({required this.message});

  final String message;

  @override
  String toString() => 'BookshelfOperationException: $message';
}

class ReadingProgressException implements Exception {
  const ReadingProgressException({required this.message});

  final String message;

  @override
  String toString() => 'ReadingProgressException: $message';
}
