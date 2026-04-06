import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../src/bindings/signals/signals.dart';
import '../../feeds/feed_service.dart';
import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstraction for chapter content fetching (enables testing)
// ─────────────────────────────────────────────────────────────────────────────

/// Abstraction over [FeedService.chapterContent] and [FeedService.cancel].
/// Inject a custom implementation for testing.
abstract class ChapterContentProvider {
  ({String requestId, Stream<ParagraphContent> stream}) fetchChapter({
    required String feedId,
    required String bookId,
    required String chapterId,
  });

  void cancel(String requestId);
}

/// Default implementation that delegates to [FeedService.instance].
class _DefaultContentProvider implements ChapterContentProvider {
  const _DefaultContentProvider();

  @override
  ({String requestId, Stream<ParagraphContent> stream}) fetchChapter({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) {
    return FeedService.instance.chapterContent(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
    );
  }

  @override
  void cancel(String requestId) {
    FeedService.instance.cancel(requestId);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ChapterLoader — standalone ChangeNotifier for chapter window management
// ─────────────────────────────────────────────────────────────────────────────

/// Manages a sliding window of loaded chapters with preloading and eviction.
///
/// This is a standalone [ChangeNotifier] — it does **not** call `setState` on
/// any widget.  Views listen to it and rebuild when notified.
///
/// The key invariant: [slots] is only mutated inside [_commit], which calls
/// [notifyListeners] exactly once.  This guarantees that listeners always see
/// a consistent snapshot.
class ChapterLoader extends ChangeNotifier {
  ChapterLoader({
    required this.feedId,
    required this.bookId,
    required List<ChapterInfoModel> chapters,
    this.maxLoaded = 5,
    ChapterContentProvider? contentProvider,
  }) : _contentProvider = contentProvider ?? const _DefaultContentProvider(),
       _chapters = List.unmodifiable(chapters),
       _minTocIndex = chapters.isEmpty
           ? 0
           : chapters.map((c) => c.index).reduce((a, b) => a < b ? a : b),
       _maxTocIndex = chapters.isEmpty
           ? -1
           : chapters.map((c) => c.index).reduce((a, b) => a > b ? a : b);

  final String feedId;
  final String bookId;
  final ChapterContentProvider _contentProvider;
  final List<ChapterInfoModel> _chapters;
  final int _minTocIndex;
  final int _maxTocIndex;
  final int maxLoaded;

  // ─ State ─────────────────────────────────────────────────────────────────

  /// Ordered by chapterIndex.  Treat as read-only from outside.
  List<ChapterSlot> _slots = [];
  List<ChapterSlot> get slots => List.unmodifiable(_slots);

  String? _currentChapterId;
  String? get currentChapterId => _currentChapterId;

  final Map<String, StreamSubscription<ParagraphContent>> _subscriptions = {};

  bool _disposed = false;

  // ─ Public getters ────────────────────────────────────────────────────────

  int get minTocIndex => _minTocIndex;
  int get maxTocIndex => _maxTocIndex;
  List<ChapterInfoModel> get chapters => _chapters;

  ChapterSlot? getSlot(String chapterId) {
    for (final s in _slots) {
      if (s.chapterId == chapterId) return s;
    }
    return null;
  }

  ChapterInfoModel? chapterByTocIndex(int tocIndex) {
    for (final c in _chapters) {
      if (c.index == tocIndex) return c;
    }
    return null;
  }

  int chapterGlobalIndex(String chapterId) {
    for (final c in _chapters) {
      if (c.id == chapterId) return c.index;
    }
    return -1;
  }

  bool get hasOlderUnloaded =>
      _slots.isNotEmpty && _slots.first.chapterIndex > _minTocIndex;

  bool get hasNewerUnloaded =>
      _slots.isNotEmpty && _slots.last.chapterIndex < _maxTocIndex;

  /// True when the first ready slot is the first chapter.
  bool get isAtBookStart {
    for (final s in _slots) {
      if (s.isReady) return s.chapterIndex == _minTocIndex;
    }
    return false;
  }

  /// True when the last ready slot is the last chapter.
  bool get isAtBookEnd {
    for (int i = _slots.length - 1; i >= 0; i--) {
      if (_slots[i].isReady) return _slots[i].chapterIndex == _maxTocIndex;
    }
    return false;
  }

  // ─ Loading API ───────────────────────────────────────────────────────────

  /// Load the initial chapter and preload adjacent ones.
  /// Throws on failure so the caller can show a retry UI.
  Future<void> loadInitial(String chapterId) async {
    _currentChapterId = chapterId;
    await _loadChapter(chapterId, rethrow_: true);

    // Preload adjacent — failures are silent.
    await Future.wait([_preloadPrev(), _preloadNext()], eagerError: false);
  }

  /// Preload a chapter.  Failures are stored in the slot (inline error).
  Future<void> preloadChapter(String chapterId) async {
    await _loadChapter(chapterId, rethrow_: false);
  }

  /// Retry a failed chapter.
  Future<void> retryChapter(String chapterId) async {
    _cancelSlot(chapterId);
    _removeSlot(chapterId);
    await _loadChapter(chapterId, rethrow_: false);
  }

  /// Update the current chapter and trigger preloading + eviction.
  void setCurrentChapter(String chapterId) {
    _currentChapterId = chapterId;
    _preloadAdjacentIfNeeded();
    _evictIfNeeded();
  }

  /// Trigger preload of adjacent chapters when approaching a boundary.
  void preloadIfNeeded({
    required bool approachingEnd,
    required bool approachingStart,
  }) {
    if (approachingEnd && hasNewerUnloaded) {
      final nextIdx = _slots.last.chapterIndex + 1;
      final ch = chapterByTocIndex(nextIdx);
      if (ch != null) preloadChapter(ch.id);
    }
    if (approachingStart && hasOlderUnloaded) {
      final prevIdx = _slots.first.chapterIndex - 1;
      final ch = chapterByTocIndex(prevIdx);
      if (ch != null) preloadChapter(ch.id);
    }
  }

  // ─ Slot mutation (always via _commit) ────────────────────────────────────

  /// Replace a slot in-place and notify listeners.
  void updateSlot(String chapterId, ChapterSlot Function(ChapterSlot) updater) {
    final idx = _slots.indexWhere((s) => s.chapterId == chapterId);
    if (idx < 0) return;
    final newSlots = List<ChapterSlot>.of(_slots);
    newSlots[idx] = updater(newSlots[idx]);
    _commit(newSlots);
  }

  // ─ Internal loading ──────────────────────────────────────────────────────

  Future<void> _loadChapter(String chapterId, {required bool rethrow_}) async {
    if (_disposed) return;
    if (getSlot(chapterId) != null) return;

    final globalIndex = chapterGlobalIndex(chapterId);
    if (globalIndex < 0) {
      if (rethrow_) throw ArgumentError('Chapter $chapterId not found');
      return;
    }

    // Insert loading slot.
    final slot = ChapterSlot(
      chapterId: chapterId,
      chapterIndex: globalIndex,
      state: const ChapterLoading(),
    );
    _insertSlotInOrder(slot);

    try {
      final (:requestId, :stream) = _contentProvider.fetchChapter(
        feedId: feedId,
        bookId: bookId,
        chapterId: chapterId,
      );

      // Update slot with requestId.
      _replaceSlot(chapterId, (s) => s.copyWith(requestId: requestId));

      final paragraphs = <ParagraphContent>[];
      final completer = Completer<void>();

      final subscription = stream.listen(
        (paragraph) {
          paragraphs.add(paragraph);
        },
        onDone: () {
          if (!completer.isCompleted && !_disposed) {
            _replaceSlot(
              chapterId,
              (s) => s.copyWith(state: ChapterReady(paragraphs)),
            );
            _onChapterLoaded(chapterId);
            completer.complete();
          }
        },
        onError: (err) {
          if (!completer.isCompleted && !_disposed) {
            _replaceSlot(
              chapterId,
              (s) => s.copyWith(
                state: ChapterError(
                  error: err,
                  message: normalizeChapterErrorMessage(err),
                ),
              ),
            );
            completer.completeError(err);
          }
        },
      );

      _subscriptions[chapterId] = subscription;
      await completer.future;
    } catch (err) {
      if (!_disposed) {
        _replaceSlot(
          chapterId,
          (s) => s.copyWith(
            state: ChapterError(
              error: err,
              message: normalizeChapterErrorMessage(err),
            ),
          ),
        );
      }
      if (rethrow_) rethrow;
    } finally {
      _subscriptions.remove(chapterId);
    }
  }

  void _onChapterLoaded(String chapterId) {
    if (_currentChapterId == null) return;
    final currentIdx = chapterGlobalIndex(_currentChapterId!);
    if (currentIdx < 0) return;
    final loadedIdx = chapterGlobalIndex(chapterId);
    if ((loadedIdx - currentIdx).abs() <= 1) {
      _preloadAdjacentIfNeeded();
    }
  }

  // ─ Preloading ────────────────────────────────────────────────────────────

  void _preloadAdjacentIfNeeded() {
    if (_slots.isEmpty || _currentChapterId == null) return;
    final currentIdx = chapterGlobalIndex(_currentChapterId!);
    if (currentIdx < 0) return;

    final prev = _nearestUnloadedBefore(currentIdx);
    if (prev != null) preloadChapter(prev.id);

    final next = _nearestUnloadedAfter(currentIdx);
    if (next != null) preloadChapter(next.id);
  }

  Future<void> _preloadPrev() async {
    if (_slots.isEmpty) return;
    final ch = _nearestUnloadedBefore(_slots.first.chapterIndex);
    if (ch != null) await preloadChapter(ch.id);
  }

  Future<void> _preloadNext() async {
    if (_slots.isEmpty) return;
    final ch = _nearestUnloadedAfter(_slots.last.chapterIndex);
    if (ch != null) await preloadChapter(ch.id);
  }

  ChapterInfoModel? _nearestUnloadedBefore(int tocIndex) {
    for (int i = tocIndex - 1; i >= _minTocIndex; i--) {
      final ch = chapterByTocIndex(i);
      if (ch != null && getSlot(ch.id) == null) return ch;
    }
    return null;
  }

  ChapterInfoModel? _nearestUnloadedAfter(int tocIndex) {
    for (int i = tocIndex + 1; i <= _maxTocIndex; i++) {
      final ch = chapterByTocIndex(i);
      if (ch != null && getSlot(ch.id) == null) return ch;
    }
    return null;
  }

  // ─ Eviction ──────────────────────────────────────────────────────────────

  void _evictIfNeeded() {
    while (_slots.length > maxLoaded && _currentChapterId != null) {
      final currentIdx = chapterGlobalIndex(_currentChapterId!);
      ChapterSlot? farthest;
      int maxDist = -1;

      for (final slot in _slots) {
        final dist = (slot.chapterIndex - currentIdx).abs();
        if (dist > maxDist) {
          maxDist = dist;
          farthest = slot;
        }
      }

      if (farthest == null) break;
      _cancelSlot(farthest.chapterId);
      _removeSlot(farthest.chapterId);
    }
  }

  // ─ Slot list helpers ─────────────────────────────────────────────────────

  void _commit(List<ChapterSlot> newSlots) {
    _slots = newSlots;
    if (!_disposed) notifyListeners();
  }

  void _insertSlotInOrder(ChapterSlot slot) {
    final newSlots = List<ChapterSlot>.of(_slots);
    int insertPos = newSlots.length;
    for (int i = 0; i < newSlots.length; i++) {
      if (newSlots[i].chapterIndex > slot.chapterIndex) {
        insertPos = i;
        break;
      }
    }
    newSlots.insert(insertPos, slot);
    _commit(newSlots);
  }

  void _replaceSlot(
    String chapterId,
    ChapterSlot Function(ChapterSlot) updater,
  ) {
    final idx = _slots.indexWhere((s) => s.chapterId == chapterId);
    if (idx < 0) return;
    final newSlots = List<ChapterSlot>.of(_slots);
    newSlots[idx] = updater(newSlots[idx]);
    _commit(newSlots);
  }

  void _removeSlot(String chapterId) {
    // Ensure any in-flight request/subscription is cancelled when a slot
    // disappears, even if caller forgot to cancel first.
    _cancelSlot(chapterId);
    final newSlots = _slots.where((s) => s.chapterId != chapterId).toList();
    _commit(newSlots);
  }

  // ─ Cancellation ──────────────────────────────────────────────────────────

  void _cancelSlot(String chapterId) {
    final slot = getSlot(chapterId);
    if (slot?.requestId != null) {
      _contentProvider.cancel(slot!.requestId!);
    }
    _subscriptions[chapterId]?.cancel();
    _subscriptions.remove(chapterId);
  }

  void _cancelAll() {
    for (final slot in _slots) {
      if (slot.requestId != null) {
        _contentProvider.cancel(slot.requestId!);
      }
    }
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  // ─ Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _cancelAll();
    super.dispose();
  }
}
