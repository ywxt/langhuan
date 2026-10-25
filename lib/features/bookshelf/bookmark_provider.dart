import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';

class BookmarkState {
  const BookmarkState({
    this.feedId = '',
    this.bookId = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final List<BookmarkModel> items;
  final bool isLoading;
  final Object? error;

  BookmarkState copyWith({
    String? feedId,
    String? bookId,
    List<BookmarkModel>? items,
    bool? isLoading,
    Object? Function()? error,
  }) {
    return BookmarkState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
    );
  }
}

class BookmarkNotifier extends Notifier<BookmarkState> {
  @override
  BookmarkState build() => const BookmarkState();

  Future<void> load({required String feedId, required String bookId}) async {
    state = state.copyWith(
      feedId: feedId,
      bookId: bookId,
      isLoading: true,
      error: () => null,
    );

    try {
      final items = await ref
          .read(feedServiceProvider)
          .listBookmarks(feedId: feedId, bookId: bookId);
      state = state.copyWith(items: items, isLoading: false, error: () => null);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: () => e);
    }
  }

  Future<BookmarkModel?> add({
    required String feedId,
    required String bookId,
    required String chapterId,
    required String paragraphId,
    required String paragraphName,
    required String paragraphPreview,
    String label = '',
  }) async {
    try {
      final created = await ref
          .read(feedServiceProvider)
          .addBookmark(
            feedId: feedId,
            bookId: bookId,
            chapterId: chapterId,
            paragraphId: paragraphId,
            paragraphName: paragraphName,
            paragraphPreview: paragraphPreview,
            label: label,
          );
      final next = List<BookmarkModel>.of(state.items)..insert(0, created);
      state = state.copyWith(items: next, error: () => null);
      return created;
    } catch (e) {
      state = state.copyWith(error: () => e);
      return null;
    }
  }

  Future<void> remove(String id) async {
    try {
      final removed = await ref
          .read(feedServiceProvider)
          .removeBookmark(id: id);
      if (!removed) return;
      final next = state.items.where((e) => e.id != id).toList(growable: false);
      state = state.copyWith(items: next, error: () => null);
    } catch (e) {
      state = state.copyWith(error: () => e);
    }
  }

  void clear() {
    state = const BookmarkState();
  }
}

final bookmarkProvider = NotifierProvider<BookmarkNotifier, BookmarkState>(
  BookmarkNotifier.new,
);
