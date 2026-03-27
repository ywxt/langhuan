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
class FeedPreviewModel {
  const FeedPreviewModel({
    required this.requestId,
    required this.id,
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.allowedDomains,
    required this.isUpgrade,
    this.author,
    this.description,
    this.currentVersion,
    this.error,
  });

  final String requestId;
  final String id;
  final String name;
  final String version;
  final String? author;
  final String? description;
  final String baseUrl;
  final List<String> allowedDomains;
  final bool isUpgrade;
  final String? currentVersion;

  /// Non-null when the preview failed.
  final String? error;

  bool get hasError => error != null;
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

    SearchRequest(
      requestId: requestId,
      feedId: feedId,
      keyword: keyword,
    ).sendSignalToRust();

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

    ChaptersRequest(
      requestId: requestId,
      feedId: feedId,
      bookId: bookId,
    ).sendSignalToRust();

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
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Chapter content
  // -------------------------------------------------------------------------

  /// Start a chapter-content stream.
  ({String requestId, Stream<ParagraphContent> stream}) chapterContent({
    required String feedId,
    required String chapterId,
  }) {
    final requestId = _nextId();

    ChapterContentRequest(
      requestId: requestId,
      feedId: feedId,
      chapterId: chapterId,
    ).sendSignalToRust();

    final stream = _buildStream<ParagraphContent>(
      requestId: requestId,
      itemStream: ChapterParagraphItem.rustSignalStream
          .where((pack) => pack.message.requestId == requestId)
          .map((pack) => pack.message.paragraph),
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Cancel
  // -------------------------------------------------------------------------

  /// Cancel an in-progress stream.  Rust will stop emitting items and send a
  /// [FeedStreamEnd] with `status == FeedStreamStatus.cancelled`.
  void cancel(String requestId) {
    FeedCancelRequest(requestId: requestId).sendSignalToRust();
  }

  // -------------------------------------------------------------------------
  // Script directory
  // -------------------------------------------------------------------------

  /// Tell Rust which directory contains `registry.toml` and the feed scripts.
  ///
  /// Rust will eagerly compile every feed listed in the registry, then
  /// respond with a [ScriptDirectorySet] signal.  If the registry file does
  /// not exist yet, `success` will be `false` and an error message will be
  /// provided — no crash.
  ///
  /// Returns a [Future] that completes once Rust has finished loading.
  Future<ScriptDirectorySet> setScriptDirectory(String path) {
    SetScriptDirectory(path: path).sendSignalToRust();
    return ScriptDirectorySet.rustSignalStream.first.then(
      (pack) => pack.message,
    );
  }

  /// Request a list of all feeds currently loaded in Rust.
  ///
  /// Returns a [Future] that completes with the [FeedListResult] once Rust
  /// responds.
  Future<FeedListResult> listFeeds() {
    final requestId = _nextId();
    ListFeedsRequest(requestId: requestId).sendSignalToRust();
    return FeedListResult.rustSignalStream
        .where((pack) => pack.message.requestId == requestId)
        .first
        .then((pack) => pack.message);
  }

  // -------------------------------------------------------------------------
  // Feed install
  // -------------------------------------------------------------------------

  /// Request a preview of a feed script from a remote [url].
  ///
  /// Returns a [Future] that resolves to a [FeedPreviewModel] once Rust has
  /// downloaded and parsed the script.  Check [FeedPreviewModel.hasError] for
  /// failures.
  Future<FeedPreviewModel> previewFromUrl(String url) async {
    final requestId = _nextId();
    PreviewFeedFromUrl(requestId: requestId, url: url).sendSignalToRust();
    return _awaitPreview(requestId);
  }

  /// Request a preview of a feed script from a local file [path].
  /// Rust reads the file, decodes it as UTF-8, and responds with a
  /// [FeedPreviewModel].  Check [FeedPreviewModel.hasError] for failures.
  Future<FeedPreviewModel> previewFromFile(String path) async {
    final requestId = _nextId();
    PreviewFeedFromFile(requestId: requestId, path: path).sendSignalToRust();
    return _awaitPreview(requestId);
  }

  /// Confirm installation of a previously previewed feed.
  ///
  /// [requestId] must match the one returned by the preceding preview call.
  /// Returns a [Future] that resolves to the [FeedInstallResult] once Rust
  /// finishes writing the script to disk and reloading the registry.
  Future<FeedInstallResult> installFeed(String requestId) {
    InstallFeedRequest(requestId: requestId).sendSignalToRust();
    return FeedInstallResult.rustSignalStream
        .where((pack) => pack.message.requestId == requestId)
        .first
        .then((pack) => pack.message);
  }

  Future<FeedPreviewModel> _awaitPreview(String requestId) {
    return FeedPreviewResult.rustSignalStream
        .where((pack) => pack.message.requestId == requestId)
        .first
        .then((pack) {
          final msg = pack.message;
          return FeedPreviewModel(
            requestId: msg.requestId,
            id: msg.id,
            name: msg.name,
            version: msg.version,
            author: msg.author,
            description: msg.description,
            baseUrl: msg.baseUrl,
            allowedDomains: List.unmodifiable(msg.allowedDomains),
            isUpgrade: msg.isUpgrade,
            currentVersion: msg.currentVersion,
            error: msg.error,
          );
        });
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /// Build a [Stream<T>] that:
  /// - Emits items from [itemStream] as they arrive.
  /// - Terminates (closes) when the matching [FeedStreamEnd] arrives.
  /// - Throws a [FeedStreamException] if the end status is `FeedStreamStatus.failed`.
  Stream<T> _buildStream<T>({
    required String requestId,
    required Stream<T> itemStream,
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
              final msg = pack.message;
              if (msg.status == FeedStreamStatus.failed) {
                controller.addError(
                  FeedStreamException(
                    requestId: requestId,
                    message: msg.error ?? 'unknown error',
                    retriedCount: msg.retriedCount,
                  ),
                );
              }
              // Close regardless of status (completed / cancelled / failed).
              controller.close();
            });
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
