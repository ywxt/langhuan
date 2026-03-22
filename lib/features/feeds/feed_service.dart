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
class ChapterContentModel {
  const ChapterContentModel({required this.title, required this.paragraphs});

  final String title;
  final List<String> paragraphs;
}

// ---------------------------------------------------------------------------
// Stream status
// ---------------------------------------------------------------------------

enum FeedStreamStatus { streaming, completed, cancelled, failed }

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
  ({String requestId, Stream<ChapterContentModel> stream}) chapterContent({
    required String feedId,
    required String chapterId,
  }) {
    final requestId = _nextId();

    ChapterContentRequest(
      requestId: requestId,
      feedId: feedId,
      chapterId: chapterId,
    ).sendSignalToRust();

    final stream = _buildStream<ChapterContentModel>(
      requestId: requestId,
      itemStream: ChapterContentItem.rustSignalStream
          .where((pack) => pack.message.requestId == requestId)
          .map(
            (pack) => ChapterContentModel(
              title: pack.message.title,
              paragraphs: List.unmodifiable(pack.message.paragraphs),
            ),
          ),
    );

    return (requestId: requestId, stream: stream);
  }

  // -------------------------------------------------------------------------
  // Cancel
  // -------------------------------------------------------------------------

  /// Cancel an in-progress stream.  Rust will stop emitting items and send a
  /// [FeedStreamEnd] with `status == "cancelled"`.
  void cancel(String requestId) {
    FeedCancelRequest(requestId: requestId).sendSignalToRust();
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /// Build a [Stream<T>] that:
  /// - Emits items from [itemStream] as they arrive.
  /// - Terminates (closes) when the matching [FeedStreamEnd] arrives.
  /// - Throws a [FeedStreamException] if the end status is `"failed"`.
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
              if (msg.status == 'failed') {
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
