import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../src/rust/api/comments.dart';
import '../../feeds/feed_service.dart';

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
        if (_seen.add(item.id)) items.add(item);
      }
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
    _cursor = null;
    loading = false;
    hasMore = true;
    error = null;
    await loadMore();
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
