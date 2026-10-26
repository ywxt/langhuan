import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../l10n/app_localizations.dart';
import '../../rust_init.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/delete_with_undo.dart';
import '../../shared/utils/errors.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/loading.dart';
import '../../shared/widgets/swipe_action_card.dart';
import '../../src/rust/api/types.dart';
import '../bookshelf/bookshelf_provider.dart';
import 'add_feed_sheet.dart';
import 'feed_providers.dart';
import 'widgets/feed_card.dart';
import 'widgets/feed_import_dialog.dart';

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
  bool _transferring = false;

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

  // ── Feed export / import ────────────────────────────────────────────────

  Future<void> _exportFeeds() async {
    if (_transferring) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _transferring = true);

    try {
      final json = await ref.read(feedServiceProvider).exportFeeds();
      final saved = await FilePicker.saveFile(
        fileName:
            'langhuan-feeds-${DateTime.now().millisecondsSinceEpoch}.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      if (!mounted) return;
      if (saved != null) {
        showSuccessSnack(ScaffoldMessenger.of(context), l10n.feedsExported);
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(
        ScaffoldMessenger.of(context),
        '${l10n.feedsExportError}: ${normalizeErrorMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _importFeeds() async {
    if (_transferring) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _transferring = true);

    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked.isEmpty) return;
      final path = picked.first.path;
      if (path == null) return;

      final json = await File(path).readAsString();
      final preview = await ref
          .read(feedServiceProvider)
          .previewImportFeeds(json);
      if (!mounted) return;

      final confirmed = await showFeedImportDialog(context, entries: preview);
      if (!confirmed || !mounted) return;

      final outcome = await ref.read(feedServiceProvider).importFeeds(json);
      await ref.read(feedListProvider.notifier).load();
      if (!mounted) return;
      showSuccessSnack(
        ScaffoldMessenger.of(context),
        l10n.feedsImportResult(
          outcome.installed,
          outcome.skipped,
          outcome.failed.length,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(
        ScaffoldMessenger.of(context),
        '${l10n.feedsImportError}: ${normalizeErrorMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
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
        !bootstrap.isLoading &&
        !bootstrap.hasError &&
        bootstrap.asData?.value != null;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceSm,
                LanghuanTheme.spaceMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.feedsTitle,
                      style: theme.textTheme.headlineLarge,
                    ),
                  ),
                  PopupMenuButton<String>(
                    enabled: bootstrapReady && !_transferring,
                    tooltip: l10n.feedsTitle,
                    onSelected: (value) => switch (value) {
                      'import' => _importFeeds(),
                      'export' => _exportFeeds(),
                      _ => (),
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'import',
                        child: Text(l10n.feedsMenuImport),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        enabled: feedState.items.isNotEmpty,
                        child: Text(l10n.feedsMenuExport),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Search bar ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceLg,
              ),
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

            const SizedBox(height: LanghuanTheme.spaceMd),

            // ── Content — the only scrollable area, so the title and
            // filter bar stay put while the feed list scrolls.
            Expanded(
              child: CustomScrollView(
                slivers: [
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
        child: LoadingState(),
      );
    }

    // ── Error ────────────────────────────────────────────────────────────────
    if (feedState.hasError) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorState(
          title: l10n.feedsLoadError,
          message: normalizeErrorMessage(feedState.error!),
          onRetry: () => ref.read(feedListProvider.notifier).retry(),
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
            child: SwipeActionCard(
              dismissKey: ValueKey('feed-${feed.id}'),
              enabled: !isBusy,
              confirmDismiss: (_) async {
                await _confirmAndDelete(feed, l10n);
                return false;
              },
              child: FeedCard(
                feed: feed,
                isDeleting: isDeleting,
                borderRadius: BorderRadius.zero,
                onDelete: () => _confirmAndDelete(feed, l10n),
              ),
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

    if (error == null) {
      // The database cascades the deletion. Mirror it in the long-lived
      // bookshelf branch even when this page is no longer mounted.
      ref.read(bookshelfProvider.notifier).removeFeed(feed.id);
      ref.read(bookshelfUpdatesProvider.notifier).removeFeed(feed.id);
    }

    if (!mounted) return;

    setState(() {
      _pendingDeleteIds.remove(feed.id);
    });

    final cur = scaffoldMessengerKey.currentState;
    if (cur == null) return;

    if (error == null) {
      showSuccessSnack(cur, l10n.feedDeleteSuccess(feed.name));
      return;
    }

    final message = error == 'busy'
        ? l10n.feedDeleteBusy
        : '${l10n.feedDeleteError}: ${normalizeErrorMessage(error)}';
    showErrorSnack(cur, message);
  }

  /// Shared delete entry point for the swipe action and the detail
  /// sheet's delete button: confirm, then run the undoable deletion.
  Future<void> _confirmAndDelete(
    FeedMetaItem feed,
    AppLocalizations l10n,
  ) async {
    final confirmed = await _confirmDelete(context, feed, l10n) == true;
    if (!confirmed || !mounted) return;
    _handleDeleteWithUndo(feed, l10n, ScaffoldMessenger.of(context));
  }

  Future<bool> _confirmDelete(
    BuildContext context,
    FeedMetaItem feed,
    AppLocalizations l10n,
  ) {
    return showConfirmDialog(
      context,
      title: l10n.feedDeleteConfirmTitle,
      message: l10n.feedDeleteConfirmMessage(feed.name),
      warning: l10n.feedDeleteCascadeWarning,
      confirmLabel: l10n.feedDeleteConfirm,
      cancelLabel: l10n.feedDeleteCancel,
    );
  }
}
