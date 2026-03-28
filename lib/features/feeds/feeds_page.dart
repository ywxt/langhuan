import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../l10n/app_localizations.dart';
import '../../src/bindings/signals/signals.dart';
import 'add_feed_sheet.dart';
import 'feed_providers.dart';

// ---------------------------------------------------------------------------
// FeedsPage — feed (book source) list
// ---------------------------------------------------------------------------

class FeedsPage extends ConsumerStatefulWidget {
  const FeedsPage({super.key});

  @override
  ConsumerState<FeedsPage> createState() => _FeedsPageState();
}

class _FeedsPageState extends ConsumerState<FeedsPage> {
  final _filterController = TextEditingController();
  String _filterText = '';
  final Set<String> _pendingDeleteIds = <String>{};
  Completer<bool>? _undoCompleter;

  @override
  void initState() {
    super.initState();
    _filterController.addListener(() {
      setState(() => _filterText = _filterController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _filterController.dispose();
    if (_undoCompleter != null && !_undoCompleter!.isCompleted) {
      _undoCompleter!.complete(false);
    }
    super.dispose();
  }

  List<FeedMetaItem> _filtered(List<FeedMetaItem> items) {
    final visible = items
        .where((f) => !_pendingDeleteIds.contains(f.id))
        .toList(growable: false);
    if (_filterText.isEmpty) return visible;
    return visible
        .where(
          (f) =>
              f.name.toLowerCase().contains(_filterText) ||
              f.id.toLowerCase().contains(_filterText),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final feedState = ref.watch(feedListProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    final filtered = _filtered(feedState.items);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.feedsTitle),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              controller: _filterController,
              hintText: l10n.feedsSearchHint,
              leading: const Icon(Icons.search),
              trailing: [
                if (_filterText.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: _filterController.clear,
                  ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showAddFeedSheet(context),
        tooltip: l10n.addFeedTitle,
        child: const Icon(Icons.add),
      ),
      body: _buildBody(context, feedState, filtered, colorScheme, l10n),
    );
  }

  Widget _buildBody(
    BuildContext context,
    FeedListState feedState,
    List<FeedMetaItem> filtered,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    // ── Loading ──────────────────────────────────────────────────────────────
    if (feedState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // ── Error ────────────────────────────────────────────────────────────────────────
    if (feedState.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                l10n.feedsLoadError,
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                feedState.error.toString(),
                style: TextStyle(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => ref.read(feedListProvider.notifier).load(),
                child: Text(l10n.feedsRetry),
              ),
            ],
          ),
        ),
      );
    }

    // ── Empty state ──────────────────────────────────────────────────────────
    if (!feedState.hasItems) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.rss_feed,
              size: 64,
              color: colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.feedsEmpty,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // ── No filter matches ─────────────────────────────────────────────────────
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          l10n.feedsNoMatch(_filterText),
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    // ── Feed list ─────────────────────────────────────────────────────────────
    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final feed = filtered[index];
        final deletingId = feedState.removingFeedId;
        final isDeleting =
            deletingId == feed.id || _pendingDeleteIds.contains(feed.id);
        final isBusy = deletingId != null || _pendingDeleteIds.isNotEmpty;

        return Dismissible(
          key: ValueKey('feed-${feed.id}'),
          direction: isBusy
              ? DismissDirection.none
              : DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            color: colorScheme.errorContainer,
            child: Icon(
              Icons.delete_outline,
              color: colorScheme.onErrorContainer,
            ),
          ),
          confirmDismiss: (_) async {
            final confirmed =
                await _confirmDelete(context, feed, l10n) == true;
            if (confirmed) {
              // Capture the local Scaffold's messenger BEFORE any rebuild.
              final messenger = ScaffoldMessenger.of(context);
              _handleDeleteWithUndo(feed, l10n, messenger);
            }
            return false; // Always reset Dismissible position
          },
          child: _FeedTile(feed: feed, isDeleting: isDeleting),
        );
      },
    );
  }

  Future<void> _handleDeleteWithUndo(
    FeedMetaItem feed,
    AppLocalizations l10n,
    ScaffoldMessengerState messenger,
  ) async {
    if (!mounted) return;

    setState(() {
      _pendingDeleteIds.add(feed.id);
    });

    // Use a Completer + Timer instead of awaiting SnackBarController.closed,
    // because MaterialApp rebuilds can orphan the .closed future forever.
    final completer = Completer<bool>();
    _undoCompleter = completer;

    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.feedDeleteQueued(feed.name)),
        action: SnackBarAction(
          label: l10n.feedDeleteUndo,
          onPressed: () {
            if (!completer.isCompleted) completer.complete(true);
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );

    // Timer fires after 4 seconds — if user hasn't tapped Undo, proceed.
    final timer = Timer(const Duration(seconds: 4), () {
      if (!completer.isCompleted) completer.complete(false);
    });

    final undone = await completer.future;
    timer.cancel();
    _undoCompleter = null;

    if (!mounted) return;

    if (undone) {
      // User tapped Undo — restore the item in the list.
      setState(() {
        _pendingDeleteIds.remove(feed.id);
      });
      messenger.clearSnackBars();
      return;
    }

    // Proceed with actual deletion.
    messenger.clearSnackBars();
    final error = await ref
        .read(feedListProvider.notifier)
        .removeFeed(feedId: feed.id);

    if (!mounted) return;

    setState(() {
      _pendingDeleteIds.remove(feed.id);
    });

    final cur = scaffoldMessengerKey.currentState;

    if (error == null) {
      cur?.clearSnackBars();
      cur?.showSnackBar(
        SnackBar(content: Text(l10n.feedDeleteSuccess(feed.name))),
      );
      return;
    }

    final message = error == 'busy'
        ? l10n.feedDeleteBusy
        : '${l10n.feedDeleteError}: $error';
    cur?.clearSnackBars();
    cur?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool?> _confirmDelete(
    BuildContext context,
    FeedMetaItem feed,
    AppLocalizations l10n,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.feedDeleteConfirmTitle),
        content: Text(l10n.feedDeleteConfirmMessage(feed.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.feedDeleteCancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.feedDeleteConfirm),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Feed list tile
// ---------------------------------------------------------------------------

class _FeedTile extends StatelessWidget {
  const _FeedTile({required this.feed, this.isDeleting = false});

  final FeedMetaItem feed;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final hasError = feed.error != null;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: hasError
            ? colorScheme.errorContainer
            : colorScheme.primaryContainer,
        child: Text(
          feed.name.isNotEmpty ? feed.name[0].toUpperCase() : '?',
          style: TextStyle(
            color: hasError
                ? colorScheme.onErrorContainer
                : colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(feed.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        feed.author != null
            ? 'v${feed.version} · ${feed.author}'
            : 'v${feed.version}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: isDeleting
            ? SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              )
            : Icon(
                hasError ? Icons.error_outline : Icons.info_outline,
                color: hasError ? colorScheme.error : null,
              ),
        tooltip: l10n.feedDetailTooltip,
        onPressed: isDeleting
            ? null
            : () => _showFeedDetailSheet(context, feed),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Feed detail bottom sheet
// ---------------------------------------------------------------------------

void _showFeedDetailSheet(BuildContext context, FeedMetaItem feed) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => _FeedDetailSheet(feed: feed),
  );
}

class _FeedDetailSheet extends StatelessWidget {
  const _FeedDetailSheet({required this.feed});

  final FeedMetaItem feed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              feed.name,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            if (feed.error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.feedItemLoadError,
                            style: textTheme.labelSmall?.copyWith(
                              color: colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            feed.error!,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            _MetaRow(
              icon: Icons.label_outline,
              label: l10n.feedDetailId,
              value: feed.id,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
            const SizedBox(height: 12),
            _MetaRow(
              icon: Icons.tag,
              label: l10n.feedDetailVersion,
              value: feed.version,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
            if (feed.author != null) ...[
              const SizedBox(height: 12),
              _MetaRow(
                icon: Icons.person_outline,
                label: l10n.feedDetailAuthor,
                value: feed.author!,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colorScheme,
    required this.textTheme,
  });

  final IconData icon;
  final String label;
  final String value;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(value, style: textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
