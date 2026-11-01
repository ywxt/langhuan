import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../src/rust/api/comments.dart';
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
      if (generation != _generation) {
        await request.cancel();
        return;
      }
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
      if (request != null) await request.cancel();
      if (generation == _generation) {
        _request = null;
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    ++_generation;
    unawaited(_request?.cancel());
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
    unawaited(_request?.cancel());
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
