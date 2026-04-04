import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../l10n/app_localizations.dart';
import '../../rust_init.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/delete_with_undo.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../src/bindings/signals/signals.dart';
import 'add_feed_sheet.dart';
import 'feed_providers.dart';
import 'widgets/feed_card.dart';

// ---------------------------------------------------------------------------
// FeedsPage — Wise-inspired feed (book source) management
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
    final bootstrap = ref.watch(appDataDirectorySetProvider);
    final bootstrapReady =
        bootstrap.asData?.value.outcome is AppDataDirectoryOutcomeSuccess;
    final feedState = ref.watch(feedListProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final filtered = _filtered(feedState.items);

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: bootstrapReady ? () => showAddFeedSheet(context) : null,
        tooltip: l10n.addFeedTitle,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ── Title ──────────────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceMd,
              ),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n.feedsTitle,
                  style: theme.textTheme.headlineLarge,
                ),
              ),
            ),

            // ── Search bar ─────────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceLg,
              ),
              sliver: SliverToBoxAdapter(
                child: SearchBar(
                  enabled: bootstrapReady,
                  controller: _filterController,
                  hintText: l10n.feedsSearchHint,
                  leading: Icon(
                    Icons.search,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  trailing: [
                    if (_filterText.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: bootstrapReady
                            ? _filterController.clear
                            : null,
                      ),
                  ],
                ),
              ),
            ),

            const SliverToBoxAdapter(
              child: SizedBox(height: LanghuanTheme.spaceMd),
            ),

            // ── Content ────────────────────────────────────────────────
            _buildBody(
              context,
              feedState,
              filtered,
              theme,
              l10n,
              bootstrapReady,
            ),

            // Bottom padding for FAB
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    FeedListState feedState,
    List<FeedMetaItem> filtered,
    ThemeData theme,
    AppLocalizations l10n,
    bool bootstrapReady,
  ) {
    // ── Loading ──────────────────────────────────────────────────────────────
    if (feedState.isLoading) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // ── Error ────────────────────────────────────────────────────────────────
    if (feedState.hasError) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorState(
          title: l10n.feedsLoadError,
          message: feedState.error.toString(),
          onRetry: () => ref.read(feedListProvider.notifier).load(),
          retryLabel: l10n.feedsRetry,
        ),
      );
    }

    // ── Empty state ──────────────────────────────────────────────────────────
    if (!feedState.hasItems) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.extension_outlined,
          title: l10n.feedsEmpty,
        ),
      );
    }

    // ── No filter matches ─────────────────────────────────────────────────────
    if (filtered.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.search_off,
          title: l10n.feedsNoMatch(_filterText),
        ),
      );
    }

    // ── Feed list (card-style items) ──────────────────────────────────────
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: LanghuanTheme.spaceLg),
      sliver: SliverList.builder(
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final feed = filtered[index];
          final deletingId = feedState.removingFeedId;
          final isDeleting =
              deletingId == feed.id || _pendingDeleteIds.contains(feed.id);
          final isBusy =
              !bootstrapReady ||
              deletingId != null ||
              _pendingDeleteIds.isNotEmpty;

          return Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
            child: Dismissible(
              key: ValueKey('feed-${feed.id}'),
              direction: isBusy
                  ? DismissDirection.none
                  : DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                ),
                child: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              confirmDismiss: (_) async {
                final confirmed =
                    await _confirmDelete(context, feed, l10n) == true;
                if (confirmed && context.mounted) {
                  final messenger = ScaffoldMessenger.of(context);
                  _handleDeleteWithUndo(feed, l10n, messenger);
                }
                return false;
              },
              child: FeedCard(feed: feed, isDeleting: isDeleting),
            ),
          );
        },
      ),
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

    final undone = await deleteWithUndo(
      messenger: messenger,
      message: l10n.feedDeleteQueued(feed.name),
      undoLabel: l10n.feedDeleteUndo,
      duration: AppConstants.undoDuration,
    );

    if (!mounted) return;

    if (undone) {
      setState(() {
        _pendingDeleteIds.remove(feed.id);
      });
      messenger.clearSnackBars();
      return;
    }

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
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            child: Text(l10n.feedDeleteConfirm),
          ),
        ],
      ),
    );
  }
}
