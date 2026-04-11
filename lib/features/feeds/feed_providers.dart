import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_init.dart';
import '../../src/rust/api/types.dart';
import 'feed_service.dart';

// ---------------------------------------------------------------------------
// Feed list state
// ---------------------------------------------------------------------------

class FeedListState {
  const FeedListState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.removingFeedId,
  });

  final List<FeedMetaItem> items;
  final bool isLoading;
  final Object? error;
  final String? removingFeedId;

  bool get hasError => error != null;
  bool get hasItems => items.isNotEmpty;
  bool get isRemoving => removingFeedId != null;

  FeedListState copyWith({
    List<FeedMetaItem>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? removingFeedId,
  }) {
    return FeedListState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      removingFeedId: removingFeedId != null
          ? removingFeedId()
          : this.removingFeedId,
    );
  }
}

class FeedListNotifier extends Notifier<FeedListState> {
  bool _requestedInitialLoad = false;

  @override
  FeedListState build() {
    final bootstrap = ref.watch(appDataDirectorySetProvider);

    if (bootstrap.isLoading) {
      return const FeedListState(isLoading: true);
    }

    if (bootstrap.hasError) {
      return FeedListState(error: bootstrap.error);
    }

    final result = bootstrap.asData?.value;
    if (result == null) {
      return const FeedListState();
    }

    if (!_requestedInitialLoad) {
      _requestedInitialLoad = true;
      Future.microtask(load);
    }

    return const FeedListState();
  }

  Future<void> load() async {
    final bootstrap = ref.read(appDataDirectorySetProvider);

    if (bootstrap.isLoading) {
      state = const FeedListState(isLoading: true);
      return;
    }

    if (bootstrap.hasError || bootstrap.asData?.value == null) {
      state = FeedListState(
        error: bootstrap.error ?? 'app data directory not ready',
      );
      return;
    }

    state = const FeedListState(isLoading: true);
    try {
      final items = await FeedService.instance.listFeeds();
      state = FeedListState(items: List.unmodifiable(items));
    } catch (e) {
      state = FeedListState(error: e);
    }
  }

  /// Remove one feed, refresh list, and clear selected feed if needed.
  ///
  /// Returns `null` on success, or a user-facing error message on failure.
  Future<String?> removeFeed({required String feedId}) async {
    if (state.isRemoving) return 'busy';

    state = state.copyWith(removingFeedId: () => feedId, error: () => null);

    try {
      await FeedService.instance.removeFeed(feedId);

      final selected = ref.read(selectedFeedProvider);
      if (selected?.id == feedId) {
        ref.read(selectedFeedProvider.notifier).clear();
      }

      // Remove immediately for Dismissible, then sync from Rust.
      final nextItems = state.items
          .where((item) => item.id != feedId)
          .toList(growable: false);
      state = state.copyWith(items: nextItems, removingFeedId: () => null);

      await load();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      if (state.removingFeedId == feedId) {
        state = state.copyWith(removingFeedId: () => null);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final feedListProvider = NotifierProvider<FeedListNotifier, FeedListState>(
  FeedListNotifier.new,
);

/// The feed currently selected by the user (used as the source for searches).
class SelectedFeedNotifier extends Notifier<FeedMetaItem?> {
  @override
  FeedMetaItem? build() => null;

  void select(FeedMetaItem feed) => state = feed;
  void clear() => state = null;
}

final selectedFeedProvider =
    NotifierProvider<SelectedFeedNotifier, FeedMetaItem?>(
      SelectedFeedNotifier.new,
    );

// ---------------------------------------------------------------------------
// Per-feed auth status
// ---------------------------------------------------------------------------

/// Checks whether a feed supports auth, then fetches the auth status.
///
/// Returns `null` if auth is not supported by the feed.
final feedAuthStatusProvider =
    FutureProvider.family<FeedAuthStatusModel?, String>((ref, feedId) async {
      final supported = await FeedService.instance.isFeedAuthSupported(feedId);
      if (!supported) return null;
      return FeedService.instance.getFeedAuthStatus(feedId);
    });
