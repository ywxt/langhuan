import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_init.dart';
import '../feeds/feed_service.dart';

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
      final items = await FeedService.instance.listBookshelf();
      state = state.copyWith(items: items, isLoading: false, error: () => null);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: () =>
            BookshelfError(BookshelfErrorType.loadFailed, originalError: e),
      );
    }
  }

  Future<BookshelfOperationOutcome> add({
    required String feedId,
    required String sourceBookId,
  }) async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (!_isBootstrapReady(bootstrap)) {
      return BookshelfOperationOutcomeError(
        message: BookshelfError(
          BookshelfErrorType.appDataDirectoryNotReady,
        ).toString(),
      );
    }

    final itemId = '$feedId:$sourceBookId';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await FeedService.instance.addToBookshelf(
        feedId: feedId,
        sourceBookId: sourceBookId,
      );
      await load();
      return outcome;
    } finally {
      if (state.activeItemId == itemId) {
        state = state.copyWith(activeItemId: () => null);
      }
    }
  }

  Future<BookshelfOperationOutcome> remove({
    required String feedId,
    required String sourceBookId,
  }) async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (!_isBootstrapReady(bootstrap)) {
      return BookshelfOperationOutcomeError(
        message: BookshelfError(
          BookshelfErrorType.appDataDirectoryNotReady,
        ).toString(),
      );
    }

    final itemId = '$feedId:$sourceBookId';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await FeedService.instance.removeFromBookshelf(
        feedId: feedId,
        sourceBookId: sourceBookId,
      );
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
