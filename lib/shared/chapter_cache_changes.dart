import 'dart:async';

/// A completed cache operation can affect one book, one source, or all books.
class ChapterCacheChange {
  const ChapterCacheChange({this.feedId, this.bookId});
  final String? feedId, bookId;

  bool affects(String feed, String book) =>
      (feedId == null || feedId == feed) && (bookId == null || bookId == book);
}

final _changes = StreamController<ChapterCacheChange>.broadcast(sync: true);
Stream<ChapterCacheChange> get chapterCacheChanges => _changes.stream;

void notifyChapterCacheChanged({String? feedId, String? bookId}) {
  assert(bookId == null || feedId != null);
  _changes.add(ChapterCacheChange(feedId: feedId, bookId: bookId));
}

/// Failed refreshes may also remove a previous cache entry, so consumers
/// re-query after either outcome instead of guessing from returned paragraphs.
Future<T> trackChapterCacheChange<T>(
  Future<T> Function() operation, {
  String? feedId,
  String? bookId,
}) async {
  try {
    return await operation();
  } finally {
    notifyChapterCacheChanged(feedId: feedId, bookId: bookId);
  }
}
