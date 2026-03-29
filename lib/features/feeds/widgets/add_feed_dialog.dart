import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../add_feed_provider.dart';
import 'feed_preview_content.dart';

/// Dialog for adding a feed — handles URL input, preview, install, and errors.
class AddFeedDialog extends ConsumerStatefulWidget {
  const AddFeedDialog({super.key, this.initialPath});

  /// When set, Rust will read and preview the script at this file path.
  final String? initialPath;

  @override
  ConsumerState<AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends ConsumerState<AddFeedDialog> {
  final _urlController = TextEditingController();

  bool get _isFileMode => widget.initialPath != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(addFeedProvider.notifier).reset();
      if (_isFileMode) {
        ref.read(addFeedProvider.notifier).previewFromFile(widget.initialPath!);
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _previewFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await ref.read(addFeedProvider.notifier).previewFromUrl(url);
  }

  Future<void> _install() async {
    await ref.read(addFeedProvider.notifier).confirmInstall();
  }

  void _goBack() {
    ref.read(addFeedProvider.notifier).reset();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final addState = ref.watch(addFeedProvider);

    ref.listen<AddFeedState>(addFeedProvider, (_, next) {
      if (next is AddFeedSuccess && mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.addFeedSuccess)));
      }
    });

    final bool isOperating =
        addState is AddFeedLoading || addState is AddFeedInstalling;

    return PopScope(
      canPop: !isOperating,
      child: AlertDialog(
        title: Text(_dialogTitle(addState, l10n)),
        scrollable: true,
        content: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(
            key: ValueKey(_contentKey(addState)),
            child: _buildContent(addState, l10n, colorScheme),
          ),
        ),
        actions: _buildActions(context, addState, l10n),
      ),
    );
  }

  String _dialogTitle(AddFeedState state, AppLocalizations l10n) =>
      state is AddFeedPreview ? l10n.addFeedPreviewTitle : l10n.addFeedTitle;

  String _contentKey(AddFeedState state) => switch (state) {
    AddFeedIdle() => 'idle',
    AddFeedLoading() => 'loading',
    AddFeedPreview() => 'preview',
    AddFeedInstalling() => 'installing',
    AddFeedSuccess() => 'success',
    AddFeedError() => 'error',
  };

  Widget _buildContent(
    AddFeedState state,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) => switch (state) {
    AddFeedIdle() when !_isFileMode => UrlInputContent(
      controller: _urlController,
      l10n: l10n,
      onSubmit: _previewFromUrl,
    ),
    AddFeedIdle() ||
    AddFeedLoading() ||
    AddFeedInstalling() ||
    AddFeedSuccess() => const LoadingContent(),
    AddFeedPreview(:final preview) => FeedPreviewContent(
      preview: preview,
      colorScheme: colorScheme,
      l10n: l10n,
    ),
    AddFeedError(:final message) => FeedErrorContent(
      message: message,
      colorScheme: colorScheme,
    ),
  };

  List<Widget> _buildActions(
    BuildContext context,
    AddFeedState state,
    AppLocalizations l10n,
  ) {
    final mat = MaterialLocalizations.of(context);

    return switch (state) {
      AddFeedIdle() when !_isFileMode => [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(mat.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _previewFromUrl,
          child: Text(l10n.addFeedUrlPreview),
        ),
      ],
      AddFeedIdle() ||
      AddFeedLoading() ||
      AddFeedInstalling() ||
      AddFeedSuccess() => const [],
      AddFeedPreview() => [
        if (!_isFileMode)
          TextButton(onPressed: _goBack, child: Text(mat.backButtonTooltip)),
        if (_isFileMode)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(mat.cancelButtonLabel),
          ),
        FilledButton(onPressed: _install, child: Text(l10n.addFeedInstall)),
      ],
      AddFeedError() => [
        TextButton(
          onPressed: _isFileMode ? () => Navigator.of(context).pop() : _goBack,
          child: Text(
            _isFileMode ? mat.cancelButtonLabel : mat.backButtonTooltip,
          ),
        ),
      ],
    };
  }
}
