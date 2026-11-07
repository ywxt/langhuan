import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_providers.dart';
import 'feed_service.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

sealed class AddFeedState {
  const AddFeedState();
}

class AddFeedIdle extends AddFeedState {
  const AddFeedIdle();
}

class AddFeedLoading extends AddFeedState {
  const AddFeedLoading();
}

class AddFeedPreview extends AddFeedState {
  const AddFeedPreview({required this.preview});
  final FeedPreviewModel preview;
}

class AddFeedInstalling extends AddFeedState {
  const AddFeedInstalling();
}

class AddFeedSuccess extends AddFeedState {
  const AddFeedSuccess();
}

class AddFeedError extends AddFeedState {
  const AddFeedError({required this.error});

  /// The raw failure; the surface classifies it via [describeError] so
  /// every add-feed error renders with the shared title-plus-detail form.
  final Object? error;
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class AddFeedNotifier extends Notifier<AddFeedState> {
  @override
  AddFeedState build() => const AddFeedIdle();

  /// Preview a feed script from a remote [url].
  ///
  /// Any failure — an unreachable URL, an oversized or non-script
  /// response, a script that fails to parse — lands in [AddFeedError]
  /// raw; nothing may escape, or the dialog sticks on its loading state,
  /// which also blocks dismissing it.
  Future<void> previewFromUrl(String url) async {
    state = const AddFeedLoading();
    try {
      final preview = await ref.read(feedServiceProvider).previewFromUrl(url);
      state = AddFeedPreview(preview: preview);
    } catch (e) {
      state = AddFeedError(error: e);
    }
  }

  /// Preview a feed script from a local file [path] (Rust reads the file).
  ///
  /// Failures land in [AddFeedError] raw for the same reason as
  /// [previewFromUrl]: an escaped error would strand the dialog in its
  /// loading state.
  Future<void> previewFromFile(String path) async {
    state = const AddFeedLoading();
    try {
      final preview = await ref.read(feedServiceProvider).previewFromFile(path);
      state = AddFeedPreview(preview: preview);
    } catch (e) {
      state = AddFeedError(error: e);
    }
  }

  /// Confirm installation of the currently previewed feed.
  ///
  /// After a successful install the [feedListProvider] is refreshed so Dart
  /// reflects the updated registry immediately.
  Future<void> confirmInstall() async {
    final current = state;
    if (current is! AddFeedPreview) return;

    state = const AddFeedInstalling();

    try {
      await ref
          .read(feedServiceProvider)
          .installFeed(current.preview.requestId);
      // Refresh the feed list so the newly installed feed appears.
      ref.read(feedListProvider.notifier).load();
      state = const AddFeedSuccess();
    } catch (e) {
      state = AddFeedError(error: e);
    }
  }

  /// Reset back to the idle state (e.g. when the sheet is closed).
  void reset() => state = const AddFeedIdle();
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final addFeedProvider = NotifierProvider<AddFeedNotifier, AddFeedState>(
  AddFeedNotifier.new,
);
