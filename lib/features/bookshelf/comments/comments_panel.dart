import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/comments.dart';
import '../widgets/reader_types.dart';
import 'comments_controller.dart';

Future<void> showCommentsPanel(
  BuildContext context,
  CommentsController controller,
) async {
  final panel = CommentsPanel(controller: controller);
  try {
    if (MediaQuery.sizeOf(context).width >= 840) {
      await showDialog<void>(
        context: context,
        builder: (_) => Align(
          alignment: Alignment.centerRight,
          child: Dialog(
            child: SizedBox(
              width: 640,
              height: MediaQuery.sizeOf(context).height * .8,
              child: panel,
            ),
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => FractionallySizedBox(heightFactor: .85, child: panel),
      );
    }
  } finally {
    controller.dispose();
  }
}

/// One page of the panel's navigation stack: the root comment thread, or a
/// reply thread opened from [parent].
class _PanelFrame {
  _PanelFrame(this.controller, {this.parent});

  final CommentsController controller;

  /// The comment whose replies this frame lists; null for the root frame.
  final CommentItem? parent;
}

class CommentsPanel extends StatefulWidget {
  const CommentsPanel({super.key, required this.controller});
  final CommentsController controller;
  @override
  State<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends State<CommentsPanel> {
  final List<_PanelFrame> _frames = [];

  @override
  void initState() {
    super.initState();
    _frames.add(_PanelFrame(widget.controller));
    unawaited(_frames.first.controller.loadMore());
  }

  @override
  void dispose() {
    for (final frame in _frames) {
      if (!identical(frame.controller, widget.controller)) {
        frame.controller.dispose();
      }
    }
    super.dispose();
  }

  void _openReplies(CommentItem comment) {
    final parent = _frames.last;
    final next = CommentsController(
      parent.controller.service,
      feedId: parent.controller.feedId,
      bookId: parent.controller.bookId,
      chapterId: parent.controller.chapterId,
      paragraphId: parent.controller.paragraphId,
      parentId: comment.id,
    );
    setState(() => _frames.add(_PanelFrame(next, parent: comment)));
    unawaited(next.loadMore());
  }

  void _popFrame() {
    if (_frames.length <= 1) return;
    final popped = _frames.removeLast();
    if (!identical(popped.controller, widget.controller)) {
      popped.controller.dispose();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // System back (Android back button, Escape) must pop the in-panel reply
    // frame first instead of dismissing the whole sheet/dialog route.
    return PopScope(
      canPop: _frames.length <= 1,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _popFrame();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const Divider(height: 1),
          Expanded(child: _buildBodyStack(context)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final frame = _frames.last;
    final controller = frame.controller;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          if (frame.parent != null)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _popFrame,
            ),
          Expanded(
            child: Text(
              frame.parent == null
                  ? controller.paragraphId == null
                        ? l10n.readerChapterComments
                        : l10n.readerParagraphComments
                  : l10n.commentsAllReplies,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: l10n.commentsRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: controller.refresh,
          ),
          const CloseButton(),
        ],
      ),
    );
  }

  /// Each frame renders in the same box via [IndexedStack], so leaving a
  /// reply thread restores the parent list with its scroll position and
  /// loaded pages intact.
  Widget _buildBodyStack(BuildContext context) {
    return IndexedStack(
      index: _frames.length - 1,
      children: [
        for (final frame in _frames)
          ListenableBuilder(
            listenable: frame.controller,
            builder: (context, _) => _buildFrameBody(context, frame),
          ),
      ],
    );
  }

  Widget _buildFrameBody(BuildContext context, _PanelFrame frame) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Reply threads quote the comment they answer at the top of the
        // same page, so the context is always visible.
        if (frame.parent != null) _ParentCommentCard(comment: frame.parent!),
        // Only the root thread offers ordering: replies read as a
        // conversation and keep the source's order.
        if (frame.parent == null) _SortBar(controller: frame.controller),
        Expanded(child: _buildBody(context, frame.controller)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, CommentsController controller) {
    final items = controller.items;

    if (items.isEmpty) {
      if (controller.error != null) {
        return Center(child: _buildError(context, controller));
      }
      if (controller.loading) return const _CommentsSkeleton();
      return const _EmptyComments();
    }

    return NotificationListener<ScrollEndNotification>(
      onNotification: (event) {
        if (event.metrics.extentAfter < 200 && controller.error == null) {
          unawaited(controller.loadMore());
        }
        return false;
      },
      child: Scrollbar(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: LanghuanTheme.spaceSm),
          itemCount: items.length + 1,
          separatorBuilder:
              (_, i) => i < items.length
                  ? const Divider(height: 1, indent: LanghuanTheme.spaceMd)
                  : const SizedBox.shrink(),
          itemBuilder: (context, index) {
            if (index == items.length) {
              return _buildFooter(context, controller);
            }
            return _CommentCard(
              comment: items[index],
              onOpenReplies: _openReplies,
            );
          },
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, CommentsController controller) {
    final l10n = AppLocalizations.of(context);
    if (controller.error != null) return _buildError(context, controller);
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

  Widget _buildError(BuildContext context, CommentsController controller) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            normalizeErrorMessage(controller.error),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: controller.loadMore,
            child: Text(l10n.readerRetry),
          ),
          if (isAuthRequiredError(controller.error))
            TextButton(
              onPressed: () async {
                final success = await context.pushNamed<bool>(
                  'feed-auth',
                  queryParameters: {'feedId': controller.feedId},
                );
                if (success == true && mounted) {
                  unawaited(controller.refresh());
                }
              },
              child: Text(l10n.feedAuthLogin),
            ),
        ],
      ),
    );
  }
}

/// Hot / latest ordering for the root comment list. Front-end only: the
/// source keeps sending pages in its own order and the controller re-sorts
/// what has already arrived.
class _SortBar extends StatelessWidget {
  const _SortBar({required this.controller});

  final CommentsController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LanghuanTheme.spaceMd,
        LanghuanTheme.spaceSm,
        LanghuanTheme.spaceMd,
        0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<CommentsSort>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(
              Theme.of(context).textTheme.labelMedium,
            ),
          ),
          segments: [
            ButtonSegment(
              value: CommentsSort.hot,
              label: Text(l10n.commentsSortHot),
            ),
            ButtonSegment(
              value: CommentsSort.latest,
              label: Text(l10n.commentsSortLatest),
            ),
          ],
          selected: {controller.sort},
          onSelectionChanged: (selection) =>
              controller.setSort(selection.first),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Comment cards
// ─────────────────────────────────────────────────────────────────────────────

/// Circular author avatar. Falls back to a default person icon when the
/// source provides no [url] or the image fails to load.
class _CommentAvatar extends StatelessWidget {
  const _CommentAvatar({required this.url});

  final String? url;

  static const double size = 36;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person_rounded,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final url = this.url;
    if (url == null || url.isEmpty) {
      return SizedBox(width: size, height: size, child: fallback);
    }
    // Decode at the physical resolution of a `size`-pixel avatar.
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The fallback circle stays behind the image so it shows while
          // the network image loads and again if it errors out.
          fallback,
          ClipOval(
            child: Image.network(
              url,
              cacheWidth: cacheSize,
              cacheHeight: cacheSize,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: child,
                );
              },
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment, required this.onOpenReplies});

  final CommentItem comment;
  final void Function(CommentItem comment) onOpenReplies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final replyCount = comment.replies?.totalCount;
    final repliesLabel =
        '${l10n.commentsReplies}${replyCount == null ? '' : ' ($replyCount)'}';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LanghuanTheme.spaceMd,
        vertical: LanghuanTheme.spaceMdSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentAvatar(url: comment.author.avatarUrl),
          const SizedBox(width: LanghuanTheme.spaceMdSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.author.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (comment.createdAtMs case final timestamp?)
                      Text(
                        _formatTimestamp(timestamp),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                _ExpandableText(text: comment.text),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (comment.likeCount
                        case final count? when count > 0) ...[
                      Icon(
                        Icons.favorite_border,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$count',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (comment.replies != null)
                      TextButton.icon(
                        onPressed: () => onOpenReplies(comment),
                        icon: const Icon(Icons.chat_bubble_outline, size: 14),
                        label: Text(repliesLabel),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          textStyle: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The comment a reply thread answers, pinned above the reply list.
class _ParentCommentCard extends StatelessWidget {
  const _ParentCommentCard({required this.comment});

  final CommentItem comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        LanghuanTheme.spaceMd,
        LanghuanTheme.spaceSm,
        LanghuanTheme.spaceMd,
        0,
      ),
      padding: const EdgeInsets.all(LanghuanTheme.spaceMdSm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(LanghuanTheme.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentAvatar(url: comment.author.avatarUrl),
          const SizedBox(width: LanghuanTheme.spaceMdSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.author.name,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                _ExpandableText(text: comment.text),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Comment body text: collapses behind an ellipsis after six lines, with an
/// expand/collapse toggle when the text actually overflows.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const int _maxLines = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(height: 1.5);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Measure the full text so the toggle only shows when the body
        // actually overflows at this width.
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.computeLineMetrics().length > _maxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _maxLines,
              overflow:
                  _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (overflows)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      _expanded ? l10n.commentsCollapse : l10n.commentsExpand,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Loading and empty states
// ─────────────────────────────────────────────────────────────────────────────

/// Placeholder cards shown while the first page loads, so the panel opens
/// instantly and fills in behind a stable layout.
class _CommentsSkeleton extends StatelessWidget {
  const _CommentsSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - LanghuanTheme.spaceMd * 2;
        Widget block({required double widthFactor, double height = 12}) =>
            Container(
              width: width * widthFactor,
              height: height,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
            );

        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          children: [
            for (var i = 0; i < 4; i++) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  block(widthFactor: .3, height: 10),
                  block(widthFactor: .18, height: 10),
                ],
              ),
              const SizedBox(height: 12),
              block(widthFactor: 1),
              const SizedBox(height: 6),
              block(widthFactor: i % 2 == 0 ? .85 : .95),
              const SizedBox(height: 6),
              block(widthFactor: i % 2 == 0 ? .55 : .4),
              const SizedBox(height: LanghuanTheme.spaceLg),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyComments extends StatelessWidget {
  const _EmptyComments();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: LanghuanTheme.spaceMdSm),
          Text(
            AppLocalizations.of(context).commentsEmpty,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting helpers
// ─────────────────────────────────────────────────────────────────────────────

String _formatTimestamp(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
