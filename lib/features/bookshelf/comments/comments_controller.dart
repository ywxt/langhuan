import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../src/rust/api/comments.dart';
import '../../../shared/utils/app_log.dart';
import '../../feeds/feed_service.dart';

/// UI-side ordering of the root comment thread. Sources keep sending pages
/// in their own order; the panel re-sorts what has already arrived. Reply
/// frames never re-sort: replies read as a conversation, so they always keep
/// the source's order.
enum CommentsSort {
  /// Likes first (unknown counts rank as zero), then newest.
  hot,

  /// Newest first (unknown times rank as oldest).
  latest,
}

class CommentsController extends ChangeNotifier {
  CommentsController(
    this.service, {
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    this.paragraphId,
    this.parentId,
  });
  final FeedService service;
  final String feedId, bookId, chapterId;
  final String? paragraphId, parentId;
  final List<CommentItem> items = [];
  final Set<String> _seen = {};
  final Set<String> _cursors = {};

  /// Arrival order per comment id — the stable final tiebreak, because
  /// [List.sort] is not stable.
  final Map<String, int> _arrival = {};

  /// Root-thread ordering only; reply frames ([parentId] set) ignore it.
  CommentsSort sort = CommentsSort.hot;
  String? _cursor;
  bool loading = false, hasMore = true;
  Object? error;

  /// Whether a page load has completed for the current generation: the
  /// thread's outcome (items, empty, or error) is known rather than
  /// merely not-yet-fetched. A surface that mounts on a settled
  /// controller — the panel reopened from the inline chapter-end
  /// section, or a recycled section — can show the real state on its
  /// first frame instead of flashing the skeleton.
  bool hasLoadedPage = false;
  int _generation = 0;
  CommentRequest? _request;

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    CommentRequest? request;
    try {
      request = await service.openCommentsPage(
        feedId: feedId,
        bookId: bookId,
        chapterId: chapterId,
        paragraphId: paragraphId,
        parentId: parentId,
        cursorJson: _cursor,
      );
      if (generation != _generation) return;
      _request = request;
      final page = await request.result();
      if (generation != _generation) return;
      final next = page.nextCursorJson;
      // Canonicalise keys before comparing opaque JSON cursors so reordering
      // object fields cannot hide a pagination cycle.
      if (next != null && _cursors.contains(_canonical(jsonDecode(next)))) {
        throw const FormatException('Comment cursor cycle');
      }
      for (final item in page.items) {
        if (_seen.add(item.id)) {
          _arrival[item.id] = _arrival.length;
          items.add(item);
        }
      }
      _applySort();
      if (next != null) _cursors.add(_canonical(jsonDecode(next)));
      _cursor = next;
      hasMore = next != null;
    } catch (e) {
      if (generation == _generation) error = e;
    } finally {
      await _cancelRequest(request);
      if (generation == _generation) {
        _request = null;
        loading = false;
        hasLoadedPage = true;
        notifyListeners();
      }
    }
  }

  Future<void> _cancelRequest(CommentRequest? request) async {
    if (request == null) return;
    try {
      await request.cancel();
    } catch (error, stackTrace) {
      // Cleanup must not replace the fetch result or leave the panel loading.
      AppLog.warning(
        'comments.controller',
        'request cancellation failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> refresh() async {
    ++_generation;
    unawaited(_cancelRequest(_request));
    _request = null;
    items.clear();
    _seen.clear();
    _cursors.clear();
    _arrival.clear();
    _cursor = null;
    loading = false;
    hasMore = true;
    error = null;
    await loadMore();
  }

  /// Re-orders [items] under [value]; already-loaded comments keep their new
  /// relative order and pages loaded afterwards merge into it. Reply frames
  /// ignore it: they always keep the source's order.
  void setSort(CommentsSort value) {
    if (parentId != null || value == sort) return;
    sort = value;
    _applySort();
    notifyListeners();
  }

  void _applySort() {
    // Reply frames keep the source's conversation order; only the root
    // thread re-sorts what has arrived.
    if (parentId != null) return;
    items.sort(_compare);
  }

  int _compare(CommentItem a, CommentItem b) {
    if (sort == CommentsSort.hot) {
      final byLikes = (b.likeCount ?? 0).compareTo(a.likeCount ?? 0);
      if (byLikes != 0) return byLikes;
    }
    final byTime = (b.createdAtMs ?? 0).compareTo(a.createdAtMs ?? 0);
    if (byTime != 0) return byTime;
    return _arrival[a.id]!.compareTo(_arrival[b.id]!);
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_cancelRequest(_request));
    super.dispose();
  }
}

String _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

/// Per-chapter [CommentsController] cache behind the reader's inline
/// chapter-end sections.
///
/// Sections appear and disappear as chapters enter and leave the reading
/// window (page turns in horizontal mode, sliver build/dispose in vertical
/// mode); keying the controllers here keeps already-loaded pages alive
/// across those rebuilds instead of refetching them. [retainAll] disposes
/// controllers for chapters the window has trimmed.
class ChapterCommentsCache {
  ChapterCommentsCache({
    required this.service,
    required this.feedId,
    required this.bookId,
  });

  final FeedService service;
  final String feedId;
  final String bookId;
  final Map<String, CommentsController> _byChapterId = {};

  /// The chapter's controller, created on first access.
  CommentsController operator [](String chapterId) => _byChapterId.putIfAbsent(
    chapterId,
    () => CommentsController(
      service,
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
    ),
  );

  /// Disposes controllers for every chapter outside [chapterIds].
  void retainAll(Iterable<String> chapterIds) {
    final alive = chapterIds.toSet();
    _byChapterId.removeWhere((chapterId, controller) {
      if (alive.contains(chapterId)) return false;
      controller.dispose();
      return true;
    });
  }

  /// Disposes every controller (reader teardown, book switch).
  void clear() {
    for (final controller in _byChapterId.values) {
      controller.dispose();
    }
    _byChapterId.clear();
  }
}
