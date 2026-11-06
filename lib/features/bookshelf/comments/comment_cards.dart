import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/comments.dart';
import '../widgets/reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared comment presentation
// ─────────────────────────────────────────────────────────────────────────────
// Used by both presentation surfaces: the modal comments panel (reply threads,
// paragraph comments) and the inline chapter-end section of the reader.

/// Circular author avatar. Falls back to a default person icon when the
/// source provides no [url] or the image fails to load.
class CommentAvatar extends StatelessWidget {
  const CommentAvatar({super.key, required this.url});

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

/// One comment row: avatar, author, timestamp, expandable body, likes and
/// the replies action when the source exposes a reply collection.
class CommentCard extends StatelessWidget {
  const CommentCard({
    super.key,
    required this.comment,
    required this.onOpenReplies,
  });

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
          CommentAvatar(url: comment.author.avatarUrl),
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
                        formatCommentTimestamp(timestamp),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                ExpandableCommentText(text: comment.text),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (comment.likeCount case final count? when count > 0) ...[
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
class ParentCommentCard extends StatelessWidget {
  const ParentCommentCard({super.key, required this.comment});

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
          CommentAvatar(url: comment.author.avatarUrl),
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
                ExpandableCommentText(text: comment.text),
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
class ExpandableCommentText extends StatefulWidget {
  const ExpandableCommentText({super.key, required this.text});

  final String text;

  @override
  State<ExpandableCommentText> createState() => _ExpandableCommentTextState();
}

class _ExpandableCommentTextState extends State<ExpandableCommentText> {
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
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
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
// Loading, empty and error states
// ─────────────────────────────────────────────────────────────────────────────

/// Placeholder cards shown while the first page loads, so the surrounding
/// surface opens instantly and fills in behind a stable layout.
class CommentsSkeleton extends StatelessWidget {
  const CommentsSkeleton({super.key, this.cards = 4});

  /// Skeleton card rows to render.
  final int cards;

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

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < cards; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceMd,
                  vertical: LanghuanTheme.spaceMdSm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                  ],
                ),
              ),
              const SizedBox(height: LanghuanTheme.spaceMdSm),
            ],
          ],
        );
      },
    );
  }
}

class EmptyComments extends StatelessWidget {
  const EmptyComments({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
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
      ),
    );
  }
}

/// Failure block: message plus retry, and a sign-in shortcut when the error
/// is an authentication failure.
class CommentsErrorBlock extends StatelessWidget {
  const CommentsErrorBlock({
    super.key,
    required this.error,
    required this.onRetry,
    required this.feedId,
    this.onAuthenticated,
  });

  final Object? error;
  final VoidCallback onRetry;
  final String feedId;

  /// Invoked after a successful sign-in (typically refreshing the list).
  final VoidCallback? onAuthenticated;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            normalizeErrorMessage(error),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(l10n.readerRetry)),
          if (isAuthRequiredError(error))
            TextButton(
              onPressed: () async {
                final success = await context.pushNamed<bool>(
                  'feed-auth',
                  queryParameters: {'feedId': feedId},
                );
                if (success == true && context.mounted) onAuthenticated?.call();
              },
              child: Text(l10n.feedAuthLogin),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting helpers
// ─────────────────────────────────────────────────────────────────────────────

String formatCommentTimestamp(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
