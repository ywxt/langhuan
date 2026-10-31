import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../l10n/app_localizations.dart';
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
        builder: (_) => FractionallySizedBox(heightFactor: .85, child: panel),
      );
    }
  } finally {
    controller.dispose();
  }
}

class CommentsPanel extends StatefulWidget {
  const CommentsPanel({super.key, required this.controller});
  final CommentsController controller;
  @override
  State<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends State<CommentsPanel> {
  final _parents = <CommentsController>[];
  late CommentsController _current;
  @override
  void initState() {
    super.initState();
    _current = widget.controller;
    unawaited(_current.loadMore());
  }

  @override
  void dispose() {
    for (final controller in {..._parents, _current}) {
      if (!identical(controller, widget.controller)) controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _current,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (_parents.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      _current.dispose();
                      setState(() => _current = _parents.removeLast());
                    },
                  ),
                Expanded(
                  child: Text(
                    _parents.isNotEmpty
                        ? l10n.commentsReplies
                        : _current.paragraphId == null
                        ? l10n.readerChapterComments
                        : l10n.readerParagraphComments,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: l10n.commentsRefresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: _current.refresh,
                ),
                CloseButton(),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (event) {
                if (event.metrics.extentAfter < 200 && _current.error == null) {
                  unawaited(_current.loadMore());
                }
                return false;
              },
              child: Scrollbar(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _current.items.length + 1,
                  itemBuilder: (context, index) {
                    if (index == _current.items.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            if (_current.loading)
                              const CircularProgressIndicator()
                            else if (_current.error != null) ...[
                              Text(normalizeErrorMessage(_current.error)),
                              TextButton(
                                onPressed: _current.loadMore,
                                child: Text(l10n.readerRetry),
                              ),
                              if (isAuthRequiredError(_current.error))
                                TextButton(
                                  onPressed: () async {
                                    final success = await context
                                        .pushNamed<bool>(
                                          'feed-auth',
                                          queryParameters: {
                                            'feedId': _current.feedId,
                                          },
                                        );
                                    if (success == true && mounted) {
                                      unawaited(_current.refresh());
                                    }
                                  },
                                  child: Text(l10n.feedAuthLogin),
                                ),
                            ] else if (_current.hasMore)
                              TextButton(
                                onPressed: _current.loadMore,
                                child: Text(l10n.commentsMore),
                              )
                            else
                              Text(
                                _current.items.isEmpty
                                    ? l10n.commentsEmpty
                                    : l10n.commentsEnd,
                              ),
                          ],
                        ),
                      );
                    }
                    final comment = _current.items[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            comment.authorName,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(comment.text),
                          if (comment.createdAtMs case final timestamp?)
                            Text(
                              DateTime.fromMillisecondsSinceEpoch(
                                timestamp,
                              ).toLocal().toString().split('.').first,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          Row(
                            children: [
                              if (comment.likeCount case final count?) ...[
                                const Icon(Icons.favorite_border, size: 14),
                                const SizedBox(width: 4),
                                Text('$count'),
                              ],
                              if (comment.hasReplies)
                                TextButton(
                                  onPressed: () {
                                    final parent = _current;
                                    final next = CommentsController(
                                      parent.service,
                                      feedId: parent.feedId,
                                      bookId: parent.bookId,
                                      chapterId: parent.chapterId,
                                      paragraphId: parent.paragraphId,
                                      parentId: comment.id,
                                    );
                                    setState(() {
                                      _parents.add(parent);
                                      _current = next;
                                    });
                                    unawaited(next.loadMore());
                                  },
                                  child: Text(
                                    '${l10n.commentsReplies}${comment.replyCount == null ? '' : ' (${comment.replyCount})'}',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
