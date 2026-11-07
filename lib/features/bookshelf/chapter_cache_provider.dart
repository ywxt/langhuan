import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/chapter_cache_changes.dart';
import '../../rust_init.dart';
import '../feeds/feed_providers.dart';

typedef ChapterCacheKey = ({String feedId, String bookId});

/// One lightweight query per visible book, shared by both chapter lists.
/// Auto-disposal refreshes the snapshot when the list is opened again.
final cachedChapterIdsProvider = FutureProvider.autoDispose
    .family<Set<String>, ChapterCacheKey>((ref, key) async {
      if (key.feedId.isEmpty || key.bookId.isEmpty) return const {};
      final service = ref.watch(feedServiceProvider);
      final bootstrap = ref.watch(appDataDirectorySetProvider.future);
      final subscription = chapterCacheChanges.listen((change) {
        if (change.affects(key.feedId, key.bookId)) ref.invalidateSelf();
      });
      ref.onDispose(subscription.cancel);
      await bootstrap;
      final ids = await service.cachedChapterIds(
        feedId: key.feedId,
        bookId: key.bookId,
      );
      return Set.unmodifiable(ids);
    });
