import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_init.dart';
import '../../src/rust/api/types.dart';
import 'feed_service.dart';

/// FRB generates no `copyWith`; the notifier needs to flip `enabled`.
extension FeedMetaEnabled on FeedMetaItem {
  FeedMetaItem withEnabled(bool value) => FeedMetaItem(
    id: id,
    name: name,
    version: version,
    author: author,
    enabled: value,
    sourceUrl: sourceUrl,
    baseUrl: baseUrl,
    accessDomains: accessDomains,
    error: error,
  );
}

// ---------------------------------------------------------------------------
// Service injection
// ---------------------------------------------------------------------------

/// The [FeedService] used by every provider. Overriding this in a
/// ProviderScope is how unit tests substitute a fake service.
final feedServiceProvider = Provider<FeedService>(
  (ref) => FeedService.instance,
);

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
      final items = await ref.read(feedServiceProvider).listFeeds();
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
      await ref.read(feedServiceProvider).removeFeed(feedId);

      final selected = ref.read(selectedFeedProvider);
      if (selected is FeedSelectionOne && selected.feed.id == feedId) {
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

  /// Pause or resume a feed, flipping the item optimistically and reverting
  /// when the backend rejects it.
  Future<String?> setFeedEnabled({
    required String feedId,
    required bool enabled,
  }) async {
    final previous = state.items;
    state = state.copyWith(
      items: [
        for (final item in previous)
          if (item.id == feedId) item.withEnabled(enabled) else item,
      ],
    );

    try {
      await ref
          .read(feedServiceProvider)
          .setFeedEnabled(feedId: feedId, enabled: enabled);
      return null;
    } catch (e) {
      state = state.copyWith(items: previous);
      return e.toString();
    }
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final feedListProvider = NotifierProvider<FeedListNotifier, FeedListState>(
  FeedListNotifier.new,
);

/// What the search page searches: every installed feed, or one specific
/// source.
sealed class FeedSelection {
  const FeedSelection();
}

/// Search across every installed feed concurrently.
class FeedSelectionAll extends FeedSelection {
  const FeedSelectionAll();
}

/// Search a single feed.
class FeedSelectionOne extends FeedSelection {
  const FeedSelectionOne(this.feed);

  final FeedMetaItem feed;
}

/// The search source selection (all feeds or one specific feed).
class SelectedFeedNotifier extends Notifier<FeedSelection?> {
  @override
  FeedSelection? build() => null;

  void select(FeedSelection selection) => state = selection;
  void clear() => state = null;
}

final selectedFeedProvider =
    NotifierProvider<SelectedFeedNotifier, FeedSelection?>(
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
      final service = ref.watch(feedServiceProvider);
      final supported = await service.isFeedAuthSupported(feedId);
      if (!supported) return null;
      return service.getFeedAuthStatus(feedId);
    });
