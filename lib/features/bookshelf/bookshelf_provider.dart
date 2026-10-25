import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_init.dart';
import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';
import 'bookshelf_operation.dart';

// ---------------------------------------------------------------------------
// Error types (for i18n)
// ---------------------------------------------------------------------------

enum BookshelfErrorType {
  appDataDirectoryNotReady,
  addFailed,
  removeFailed,
  loadFailed,
}

class BookshelfError implements Exception {
  const BookshelfError(this.type, {this.originalError});

  final BookshelfErrorType type;
  final Object? originalError;

  @override
  String toString() => 'BookshelfError($type)';
}

// ---------------------------------------------------------------------------
// Bookshelf state
// ---------------------------------------------------------------------------

class BookshelfState {
  const BookshelfState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.activeItemId,
  });

  final List<BookshelfItemModel> items;
  final bool isLoading;
  final Object? error;
  final String? activeItemId;

  bool get hasError => error != null;

  bool contains({required String feedId, required String sourceBookId}) {
    return items.any(
      (item) => item.feedId == feedId && item.sourceBookId == sourceBookId,
    );
  }

  BookshelfState copyWith({
    List<BookshelfItemModel>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? activeItemId,
  }) {
    return BookshelfState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      activeItemId: activeItemId != null ? activeItemId() : this.activeItemId,
    );
  }
}

class BookshelfNotifier extends Notifier<BookshelfState> {
  bool _initialized = false;

  bool _isBootstrapReady(AsyncValue<AppDataDirectoryResult> bootstrap) {
    if (bootstrap.isLoading || bootstrap.hasError) return false;
    return bootstrap.asData?.value != null;
  }

  @override
  BookshelfState build() {
    final bootstrap = ref.watch(appDataDirectorySetProvider);

    if (bootstrap.hasError) {
      return BookshelfState(
        error: BookshelfError(
          BookshelfErrorType.loadFailed,
          originalError: bootstrap.error,
        ),
      );
    }

    if (bootstrap.isLoading) return const BookshelfState(isLoading: true);

    if (bootstrap.asData?.value == null) return const BookshelfState();

    if (!_initialized) {
      _initialized = true;
      Future.microtask(load);
    }
    return const BookshelfState(isLoading: true);
  }

  Future<void> load() async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (!_isBootstrapReady(bootstrap)) return;

    state = state.copyWith(isLoading: true, error: () => null);
    try {
      final items = await ref.read(feedServiceProvider).listBookshelf();
      state = state.copyWith(items: items, isLoading: false, error: () => null);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: () =>
            BookshelfError(BookshelfErrorType.loadFailed, originalError: e),
      );
    }
  }

  /// Drop every locally cached shelf item owned by a deleted feed.
  ///
  /// The database removes these rows through `ON DELETE CASCADE`; this keeps
  /// the long-lived bookshelf tab in sync without waiting for another load.
  void removeFeed(String feedId) {
    final items = state.items
        .where((item) => item.feedId != feedId)
        .toList(growable: false);
    if (items.length == state.items.length) return;

    final activeItemBelongsToFeed = state.items.any(
      (item) => item.feedId == feedId && item.stableId == state.activeItemId,
    );
    state = state.copyWith(
      items: items,
      activeItemId: activeItemBelongsToFeed ? () => null : null,
    );
  }

  Future<BookshelfAddResult> add({
    required String feedId,
    required String sourceBookId,
    required String title,
    required String author,
    String? coverUrl,
    String? description,
  }) async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (!_isBootstrapReady(bootstrap)) {
      throw const BookshelfError(BookshelfErrorType.appDataDirectoryNotReady);
    }

    final itemId = '$feedId:$sourceBookId';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await ref
          .read(feedServiceProvider)
          .addToBookshelf(
            feedId: feedId,
            sourceBookId: sourceBookId,
            title: title,
            author: author,
            coverUrl: coverUrl,
            description: description,
          );
      await load();
      return outcome;
    } finally {
      if (state.activeItemId == itemId) {
        state = state.copyWith(activeItemId: () => null);
      }
    }
  }

  Future<BookshelfRemoveResult> remove({
    required String feedId,
    required String sourceBookId,
  }) async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (!_isBootstrapReady(bootstrap)) {
      throw const BookshelfError(BookshelfErrorType.appDataDirectoryNotReady);
    }

    final itemId = '$feedId:$sourceBookId';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await ref
          .read(feedServiceProvider)
          .removeFromBookshelf(feedId: feedId, sourceBookId: sourceBookId);
      await load();
      return outcome;
    } finally {
      if (state.activeItemId == itemId) {
        state = state.copyWith(activeItemId: () => null);
      }
    }
  }
}

final bookshelfProvider = NotifierProvider<BookshelfNotifier, BookshelfState>(
  BookshelfNotifier.new,
);

// ---------------------------------------------------------------------------
// Bookshelf update check
// ---------------------------------------------------------------------------

/// Per-book update badges, keyed by `BookshelfItemModel.stableId`.
///
/// A value > 0 is the number of chapters published since the user last saw
/// the book's chapter list. Books with a failed check carry no badge but are
/// listed in [failedBooks].
class BookshelfUpdatesState {
  const BookshelfUpdatesState({
    this.isChecking = false,
    this.newChaptersByBook = const {},
    this.failedBooks = const {},
    this.lastError,
  });

  final bool isChecking;

  final Map<String, int> newChaptersByBook;

  /// Books whose individual check failed (dead source, network, auth),
  /// mapped to the error message.
  final Map<String, String> failedBooks;

  /// Error of the last completed check, when it failed to run at all.
  final Object? lastError;

  BookshelfUpdatesState copyWith({
    bool? isChecking,
    Map<String, int>? newChaptersByBook,
    Map<String, String>? failedBooks,
    Object? lastError,
    bool clearError = false,
  }) {
    return BookshelfUpdatesState(
      isChecking: isChecking ?? this.isChecking,
      newChaptersByBook: newChaptersByBook ?? this.newChaptersByBook,
      failedBooks: failedBooks ?? this.failedBooks,
      lastError: clearError ? null : lastError ?? this.lastError,
    );
  }
}

class BookshelfUpdatesNotifier extends Notifier<BookshelfUpdatesState> {
  int _generation = 0;

  @override
  BookshelfUpdatesState build() => const BookshelfUpdatesState();

  /// Check every shelved book for new chapters. Emits badges incrementally
  /// as each book completes. Running checks are not re-entrant.
  Future<void> check() async {
    if (state.isChecking) return;
    final generation = ++_generation;
    state = const BookshelfUpdatesState(isChecking: true);

    final badges = <String, int>{};
    final failed = <String, String>{};
    Object? fatal;

    try {
      await for (final update
          in ref.read(feedServiceProvider).bookshelfUpdates()) {
        if (generation != _generation) return;
        final id = '${update.feedId}:${update.sourceBookId}';
        if (update.error != null) {
          failed[id] = update.error!;
        } else if (update.newChapters > 0) {
          badges[id] = update.newChapters;
        }
        state = state.copyWith(newChaptersByBook: {...badges});
      }
    } catch (e) {
      if (generation != _generation) return;
      fatal = e;
    }

    if (generation != _generation) return;

    state = BookshelfUpdatesState(
      isChecking: false,
      newChaptersByBook: badges,
      lastError: fatal,
      failedBooks: failed,
    );
  }

  /// Clear a book's badge after the user has seen its chapter list.
  void clear(String feedId, String sourceBookId) {
    final id = '$feedId:$sourceBookId';
    if (!state.newChaptersByBook.containsKey(id)) return;
    final updated = Map.of(state.newChaptersByBook)..remove(id);
    state = state.copyWith(newChaptersByBook: updated);
  }

  /// Drop a book's badge when it is removed from the shelf.
  void remove(String feedId, String sourceBookId) =>
      clear(feedId, sourceBookId);

  /// Drop badges and failures owned by a deleted feed.
  ///
  /// Incrementing [_generation] also prevents an update check that was
  /// already in flight from restoring stale entries after the deletion.
  void removeFeed(String feedId) {
    _generation++;
    final prefix = '$feedId:';
    state = BookshelfUpdatesState(
      newChaptersByBook: Map.unmodifiable(
        Map.of(state.newChaptersByBook)
          ..removeWhere((id, _) => id.startsWith(prefix)),
      ),
      failedBooks: Map.unmodifiable(
        Map.of(state.failedBooks)
          ..removeWhere((id, _) => id.startsWith(prefix)),
      ),
      lastError: state.lastError,
    );
  }
}

final bookshelfUpdatesProvider =
    NotifierProvider<BookshelfUpdatesNotifier, BookshelfUpdatesState>(
      BookshelfUpdatesNotifier.new,
    );
