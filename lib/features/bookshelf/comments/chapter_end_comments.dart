import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/comments.dart';
import '../../feeds/feed_service.dart';
import 'comment_cards.dart';
import 'comments_controller.dart';
import 'comments_panel.dart';

/// The chapter's comment thread, rendered at the end of the chapter.
///
/// The reading views mount one section per chapter: in vertical mode it
/// flows inline with the text (no scroll of its own), in horizontal mode it
/// fills the page after the chapter's last text page and scrolls within it.
/// [controller] is owned by the caller's [ChapterCommentsCache] — this
/// widget only starts the first load and must never dispose it.
class ChapterEndComments extends StatefulWidget {
  const ChapterEndComments({
    super.key,
    required this.service,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    required this.controller,
    this.scrollable = false,
  });

  final FeedService service;
  final String feedId;
  final String bookId;
  final String chapterId;
  final CommentsController controller;

  /// Whether the section manages its own scroll view (horizontal mode,
  /// where it fills one fixed page) instead of flowing with the surrounding
  /// scroll (vertical mode).
  final bool scrollable;

  @override
  State<ChapterEndComments> createState() => _ChapterEndCommentsState();
}

class _ChapterEndCommentsState extends State<ChapterEndComments> {
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    // Post-frame: the section builds inside the reading views' layout, and
    // the request bookkeeping must not compete with that frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadStarted) return;
      // A remount (sliver recycle, page rebuild) lands here on an
      // already-settled controller — loadMore then returns without
      // notifying, so the flag flip must carry its own rebuild or the
      // section keeps rendering the skeleton.
      setState(() => _loadStarted = true);
      unawaited(widget.controller.loadMore());
    });
  }

  /// Opens the full panel on the shared controller: sorting, refreshing and
  /// paging then act on exactly what the section shows. The cache keeps
  /// owning the controller, so the panel must not dispose it.
  Future<void> _openPanel() {
    return showCommentsPanel(
      context,
      widget.controller,
      disposeController: false,
    );
  }

  /// Opens one comment's reply thread. Reply controllers are panel-owned.
  Future<void> _openReplies(CommentItem comment) {
    return showCommentsPanel(
      context,
      CommentsController(
        widget.service,
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        parentId: comment.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final children = [_buildHeader(context), ..._buildBody(context)];
        if (widget.scrollable) {
          return ListView(
            // Pages of the horizontal reader stay put for horizontal pans;
            // this list only ever scrolls vertically.
            scrollDirection: Axis.vertical,
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceLg),
            children: children,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(
            top: LanghuanTheme.spaceSm,
            bottom: LanghuanTheme.spaceXl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final count = controller.totalCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LanghuanTheme.spaceMd,
        LanghuanTheme.spaceMd,
        LanghuanTheme.spaceSm,
        0,
      ),
      child: Row(
        children: [
          Icon(
            Icons.forum_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              count == null
                  ? l10n.readerChapterComments
                  : '${l10n.readerChapterComments} · $count',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: _openPanel,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              textStyle: theme.textTheme.labelMedium,
            ),
            child: Text(l10n.commentsViewAll),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final controller = widget.controller;
    final items = controller.items;

    if (items.isEmpty) {
      if (controller.error != null) {
        return [_buildError(context)];
      }
      if (!_loadStarted || controller.loading) {
        return [const CommentsSkeleton(cards: 2)];
      }
      return [const EmptyComments()];
    }

    return [
      for (final comment in items)
        CommentCard(comment: comment, onOpenReplies: _openReplies),
      _buildFooter(context),
    ];
  }

  Widget _buildFooter(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    if (controller.error != null) return _buildError(context);
    if (controller.loading) {
      return const Padding(
        padding: EdgeInsets.all(LanghuanTheme.spaceLg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (controller.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceSm),
        child: Center(
          child: TextButton(
            onPressed: controller.loadMore,
            child: Text(l10n.commentsMore),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      child: Center(
        child: Text(
          l10n.commentsEnd,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return CommentsErrorBlock(
      error: widget.controller.error,
      onRetry: widget.controller.loadMore,
      feedId: widget.feedId,
      onAuthenticated: widget.controller.refresh,
    );
  }
}
