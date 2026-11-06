import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/comments.dart';
import 'comment_cards.dart';
import 'comments_controller.dart';

Future<void> showCommentsPanel(
  BuildContext context,
  CommentsController controller, {
  bool disposeController = true,
}) async {
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
    // Callers that share the controller with a long-lived surface (the
    // inline chapter-end section) keep ownership themselves.
    if (disposeController) controller.dispose();
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

  /// Whether the root thread's first load has been kicked off. It waits for
  /// the sheet/dialog entrance animation to finish so the request (and its
  /// result) never competes with the animation for frames.
  bool _initialLoadStarted = false;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    _frames.add(_PanelFrame(widget.controller));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialLoadStarted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _startInitialLoad();
      return;
    }
    _routeAnimation = animation;
    animation.addStatusListener(_onRouteAnimationStatus);
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    // Dismissed means the route was popped mid-animation; the panel is going
    // away, so nothing is left to start.
    if (status != AnimationStatus.completed) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = null;
    _startInitialLoad();
  }

  void _startInitialLoad() {
    _initialLoadStarted = true;
    unawaited(_frames.first.controller.loadMore());
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = null;
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
        if (frame.parent != null) ParentCommentCard(comment: frame.parent!),
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
      // The awaiting-start case only occurs on the root frame while the
      // entrance animation is still running; reply frames open long after.
      if (controller.loading || !_initialLoadStarted) {
        return const CommentsSkeleton();
      }
      return const EmptyComments();
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
          separatorBuilder: (_, i) => i < items.length
              ? const Divider(height: 1, indent: LanghuanTheme.spaceMd)
              : const SizedBox.shrink(),
          itemBuilder: (context, index) {
            if (index == items.length) {
              return _buildFooter(context, controller);
            }
            return CommentCard(
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
    return CommentsErrorBlock(
      error: controller.error,
      onRetry: controller.loadMore,
      feedId: controller.feedId,
      onAuthenticated: controller.refresh,
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
