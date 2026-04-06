import 'package:flutter/material.dart';

import '../../feeds/feed_service.dart';
import 'chapter_loader.dart';
import 'horizontal_reader_view.dart';
import 'reader_types.dart';
import 'vertical_reader_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ChapterContentManager — owns ChapterLoader, switches reader views
// ─────────────────────────────────────────────────────────────────────────────

/// Owns a [ChapterLoader] and delegates to either [HorizontalReaderView] or
/// [VerticalReaderView] based on [readerMode].
///
/// When the mode changes, a fresh reader view is created (via [ValueKey]) but
/// the same [ChapterLoader] is reused — no re-fetching of chapters.
class ChapterContentManager extends StatefulWidget {
  const ChapterContentManager({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.initialChapterId,
    required this.initialParagraphIndex,
    required this.readerMode,
    required this.contentPadding,
    required this.onChapterChanged,
    required this.onParagraphChanged,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final String initialChapterId;
  final int initialParagraphIndex;
  final ReaderMode readerMode;
  final EdgeInsets contentPadding;
  final ValueChanged<String> onChapterChanged;
  final ValueChanged<int> onParagraphChanged;

  @override
  State<ChapterContentManager> createState() => _ChapterContentManagerState();
}

class _ChapterContentManagerState extends State<ChapterContentManager> {
  late ChapterLoader _loader;
  bool _isInitialLoading = true;
  Object? _loadError;

  // Track current position for mode switching.
  late String _currentChapterId;
  int _currentParagraphIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentChapterId = widget.initialChapterId;
    _currentParagraphIndex = widget.initialParagraphIndex;
    _loader = ChapterLoader(
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapters: widget.chapters,
    );
    _initialize();
  }

  @override
  void dispose() {
    _loader.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _loader.loadInitial(widget.initialChapterId);
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
          _loadError = e;
        });
      }
    }
  }

  Future<void> _retryInitialLoad() async {
    setState(() {
      _isInitialLoading = true;
      _loadError = null;
    });
    // Dispose old loader and create a fresh one.
    _loader.dispose();
    _loader = ChapterLoader(
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapters: widget.chapters,
    );
    await _initialize();
  }

  void _onChapterChanged(String chapterId) {
    _currentChapterId = chapterId;
    widget.onChapterChanged(chapterId);
  }

  void _onParagraphChanged(int paragraphIndex) {
    _currentParagraphIndex = paragraphIndex;
    widget.onParagraphChanged(paragraphIndex);
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null && _loader.slots.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              normalizeChapterErrorMessage(_loadError!),
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _retryInitialLoad,
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      );
    }

    if (widget.readerMode == ReaderMode.verticalScroll) {
      return VerticalReaderView(
        key: const ValueKey(ReaderMode.verticalScroll),
        loader: _loader,
        initialChapterId: _currentChapterId,
        initialParagraphIndex: _currentParagraphIndex,
        contentPadding: widget.contentPadding,
        onChapterChanged: _onChapterChanged,
        onParagraphChanged: _onParagraphChanged,
      );
    }

    return HorizontalReaderView(
      key: const ValueKey(ReaderMode.horizontalPaging),
      loader: _loader,
      initialChapterId: _currentChapterId,
      initialParagraphIndex: _currentParagraphIndex,
      contentPadding: widget.contentPadding,
      onChapterChanged: _onChapterChanged,
      onParagraphChanged: _onParagraphChanged,
    );
  }
}
