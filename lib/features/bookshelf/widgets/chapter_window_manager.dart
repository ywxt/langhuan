import 'dart:async';

import 'package:flutter/material.dart';

import '../../../src/bindings/signals/signals.dart';
import '../../feeds/feed_service.dart';
import 'page_breaker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

/// Holds content for one chapter: raw paragraphs, computed pages, and load state.
/// Public class shared between views.
class ChapterSlot {
  final String chapterId;
  final int chapterIndex;
  List<ParagraphContent>? content; // null = not loaded / failed
  List<PageContent> pages; // computed pages for horizontal mode
  bool isLoading;
  Object? error;
  String? requestId; // for FeedService.cancel()

  ChapterSlot({
    required this.chapterId,
    required this.chapterIndex,
    this.content,
    this.pages = const [],
    this.isLoading = false,
    this.error,
    this.requestId,
  });

  bool get isReady => content != null && !isLoading;
}

// ─────────────────────────────────────────────────────────────────────────────
// ChapterWindowManager Mixin
// ─────────────────────────────────────────────────────────────────────────────

/// Mixin for managing a sliding window of loaded chapters with proactive preloading
/// and intelligent eviction.
///
/// Contract:
/// - Maintain an ordered list of loaded chapters
/// - Load chapters on demand, streaming content via FeedService
/// - Preload adjacent chapters proactively (ripple preload)
/// - Evict farthest chapter when loaded count exceeds limit
/// - Cancel in-flight requests on dispose
///
/// The view using this mixin must:
/// 1. Implement `onChapterLoaded(ChapterSlot)` callback for when content arrives
/// 2. Implement `onChaptersEvicted(ChapterSlot, bool fromTop)` for when chapters are removed
/// 3. Call `initChapterWindow()` in initState
/// 4. Call `disposeChapterWindow()` in dispose
mixin ChapterWindowManager<T extends StatefulWidget> on State<T> {
  // ─ Configuration
  static const int defaultMaxLoadedChapters = 5;
  int get maxLoadedChapters => defaultMaxLoadedChapters;

  // ─ State
  late final List<ChapterInfoModel> _chapters;
  late final String _feedId;
  late final String _bookId;
  final List<ChapterSlot> _loadedSlots = []; // ordered by chapterIndex
  String? _currentChapterId;
  final Map<String, StreamSubscription> _activeSubscriptions = {};

  // ─ Initialization
  void initChapterWindow({
    required List<ChapterInfoModel> chapters,
    required String feedId,
    required String bookId,
  }) {
    _chapters = chapters;
    _feedId = feedId;
    _bookId = bookId;
  }

  void disposeChapterWindow() {
    _cancelAll();
  }

  // ─ Public API ────────────────────────────────────────────────────────────

  /// Get all currently loaded chapter slots, ordered by chapterIndex.
  List<ChapterSlot> get loadedSlots => List.unmodifiable(_loadedSlots);

  /// Get the slot for a specific chapter, or null if not loaded.
  ChapterSlot? getSlot(String chapterId) {
    try {
      return _loadedSlots.firstWhere((s) => s.chapterId == chapterId);
    } catch (e) {
      return null;
    }
  }

  /// Get chapter at a specific global index, or null if out of bounds.
  ChapterInfoModel? chapterAt(int index) {
    if (index < 0 || index >= _chapters.length) return null;
    return _chapters[index];
  }

  /// Get the global index of a chapter by ID.
  int chapterGlobalIndex(String chapterId) {
    return _chapters.indexWhere((c) => c.id == chapterId);
  }

  /// Check if there's an unloaded chapter before the first loaded slot.
  bool get hasOlderUnloaded {
    if (_loadedSlots.isEmpty) return false;
    return _loadedSlots.first.chapterIndex > 0;
  }

  /// Check if there's an unloaded chapter after the last loaded slot.
  bool get hasNewerUnloaded {
    if (_loadedSlots.isEmpty) return false;
    return _loadedSlots.last.chapterIndex < _chapters.length - 1;
  }

  /// Get title of chapter before first loaded slot, if available.
  String? get olderChapterTitle {
    if (!hasOlderUnloaded) return null;
    final idx = _loadedSlots.first.chapterIndex - 1;
    return _chapters[idx].title;
  }

  /// Get title of chapter after last loaded slot, if available.
  String? get newerChapterTitle {
    if (!hasNewerUnloaded) return null;
    final idx = _loadedSlots.last.chapterIndex + 1;
    return _chapters[idx].title;
  }

  // ─ Chapter Loading ──────────────────────────────────────────────────────────

  /// Load a chapter and add it to slots in sorted order. Returns when content arrives.
  Future<void> loadChapter(String chapterId) async {
    // Already loaded?
    if (getSlot(chapterId) != null) {
      return;
    }

    final globalIndex = chapterGlobalIndex(chapterId);
    if (globalIndex < 0) {
      throw ArgumentError('Chapter $chapterId not found');
    }

    // Create slot and add to list in sorted position
    final slot = ChapterSlot(
      chapterId: chapterId,
      chapterIndex: globalIndex,
      isLoading: true,
    );

    _insertSlotInOrder(slot);

    // Trigger rebuild so view sees loading state
    if (mounted) setState(() {});

    try {
      // Stream content from FeedService
      final (:requestId, :stream) = FeedService.instance.chapterContent(
        feedId: _feedId,
        bookId: _bookId,
        chapterId: chapterId,
      );
      slot.requestId = requestId;

      final paragraphs = <ParagraphContent>[];
      final completer = Completer<void>();

      final subscription = stream.listen(
        (paragraph) {
          paragraphs.add(paragraph);
        },
        onDone: () {
          if (!completer.isCompleted) {
            if (mounted) {
              slot
                ..content = paragraphs
                ..isLoading = false
                ..error = null;
              setState(() {});
              _onChapterLoaded(slot);
            }
            completer.complete();
          }
        },
        onError: (err) {
          if (!completer.isCompleted) {
            if (mounted) {
              slot
                ..error = err
                ..isLoading = false;
              setState(() {});
            }
            completer.completeError(err);
          }
        },
      );

      _activeSubscriptions[chapterId] = subscription;
      await completer.future;
    } catch (err) {
      if (mounted) {
        slot
          ..error = err
          ..isLoading = false;
        setState(() {});
      }
      rethrow;
    } finally {
      _activeSubscriptions.remove(chapterId);
    }
  }

  /// Load current chapter and preload adjacent chapters proactively.
  Future<void> loadInitial(String initialChapterId) async {
    _currentChapterId = initialChapterId;

    try {
      // Load current
      await loadChapter(initialChapterId);

      // Preload adjacent in parallel
      final prevFuture = _preloadPrev();
      final nextFuture = _preloadNext();
      await Future.wait([prevFuture, nextFuture], eagerError: false);
    } catch (e) {
      // Errors logged in loadChapter
    }
  }

  /// Set current chapter and trigger preloading of new adjacent chapters.
  /// Also triggers eviction if needed.
  void setCurrentChapter(String chapterId) {
    _currentChapterId = chapterId;

    // Preload the new unloaded neighbor (the one farther from where we came)
    _preloadAdjacentIfNeeded();

    // Evict if over limit
    evictIfNeeded();
  }

  // ─ Preloading ──────────────────────────────────────────────────────────────

  /// Preload chapters adjacent to the current chapter only.
  /// This avoids cascading fetches when a source is blocked and requests fail.
  void _preloadAdjacentIfNeeded() {
    if (_loadedSlots.isEmpty || _currentChapterId == null) return;

    final currentIdx = chapterGlobalIndex(_currentChapterId!);
    if (currentIdx < 0) return;

    if (currentIdx > 0) {
      final prevId = _chapters[currentIdx - 1].id;
      if (getSlot(prevId) == null) {
        loadChapter(prevId).catchError((_) {});
      }
    }

    if (currentIdx < _chapters.length - 1) {
      final nextId = _chapters[currentIdx + 1].id;
      if (getSlot(nextId) == null) {
        loadChapter(nextId).catchError((_) {});
      }
    }
  }

  Future<void> _preloadPrev() async {
    if (_loadedSlots.isEmpty) return;
    final idx = _loadedSlots.first.chapterIndex - 1;
    if (idx < 0) return;
    try {
      await loadChapter(_chapters[idx].id);
    } catch (e) {
      // Preload failure is non-fatal
    }
  }

  Future<void> _preloadNext() async {
    if (_loadedSlots.isEmpty) return;
    final idx = _loadedSlots.last.chapterIndex + 1;
    if (idx >= _chapters.length) return;
    try {
      await loadChapter(_chapters[idx].id);
    } catch (e) {
      // Preload failure is non-fatal
    }
  }

  // ─ Eviction ──────────────────────────────────────────────────────────────

  /// Remove farthest chapter if loaded count exceeds limit.
  /// Calls view callbacks to adjust scroll/page offset if evicting from top.
  void evictIfNeeded() {
    if (_loadedSlots.length <= maxLoadedChapters) return;

    // Find farthest chapter from current
    if (_currentChapterId == null || _loadedSlots.isEmpty) return;

    final currentIdx = chapterGlobalIndex(_currentChapterId!);
    ChapterSlot? farthest;
    int maxDist = -1;

    for (final slot in _loadedSlots) {
      final dist = (slot.chapterIndex - currentIdx).abs();
      if (dist > maxDist) {
        maxDist = dist;
        farthest = slot;
      }
    }

    if (farthest != null) {
      _evictSlot(farthest);
    }
  }

  void _evictSlot(ChapterSlot slot) {
    _cancelSlot(slot);

    final wasFromTop = _loadedSlots.first == slot;
    _loadedSlots.remove(slot);

    if (mounted) {
      setState(() {});
      // Delegate offset adjustment to view
      onChaptersEvicted(slot, wasFromTop);
    }
  }

  // ─ Cancellation ──────────────────────────────────────────────────────────

  void _cancelSlot(ChapterSlot slot) {
    if (slot.requestId != null) {
      FeedService.instance.cancel(slot.requestId!);
    }
    final subscription = _activeSubscriptions.remove(slot.chapterId);
    subscription?.cancel();
  }

  void _cancelAll() {
    for (final slot in _loadedSlots) {
      _cancelSlot(slot);
    }
    _loadedSlots.clear();
    for (final subscription in _activeSubscriptions.values) {
      subscription.cancel();
    }
    _activeSubscriptions.clear();
  }

  // ─ Helpers ───────────────────────────────────────────────────────────────

  void _insertSlotInOrder(ChapterSlot slot) {
    // Find insertion point to keep list sorted by chapterIndex
    int insertPos = 0;
    for (int i = 0; i < _loadedSlots.length; i++) {
      if (_loadedSlots[i].chapterIndex > slot.chapterIndex) {
        insertPos = i;
        break;
      }
      insertPos = i + 1;
    }
    _loadedSlots.insert(insertPos, slot);
  }

  // ─ Callbacks (to be implemented by view) ─────────────────────────────────

  /// Called when a chapter finishes loading (content arrives).
  /// View should rebuild its item/page array to include this chapter.
  void _onChapterLoaded(ChapterSlot slot) {
    onChapterLoaded(slot);

    // Only expand preloading from nearby chapters, not arbitrary outer edges.
    if (_currentChapterId == null) return;
    final currentIdx = chapterGlobalIndex(_currentChapterId!);
    if (currentIdx < 0) return;

    final distance = (slot.chapterIndex - currentIdx).abs();
    if (distance <= 1) {
      _preloadAdjacentIfNeeded();
    }
  }

  /// Override in view: called when chapter finishes loading.
  void onChapterLoaded(ChapterSlot slot) {}

  /// Override in view: called when chapter is evicted.
  /// `fromTop` indicates whether it was evicted from the leading edge (needs scroll adjustment).
  void onChaptersEvicted(ChapterSlot slot, bool fromTop) {}
}
