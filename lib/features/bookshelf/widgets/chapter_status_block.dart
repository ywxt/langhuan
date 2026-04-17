import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

enum ChapterStatusBlockKind { loading, error }

class ChapterStatusBlock extends StatefulWidget {
  const ChapterStatusBlock({
    super.key,
    required this.kind,
    this.message,
    this.onRetry,
  });

  final ChapterStatusBlockKind kind;
  final String? message;
  final VoidCallback? onRetry;

  @override
  State<ChapterStatusBlock> createState() => _ChapterStatusBlockState();
}

class _ChapterStatusBlockState extends State<ChapterStatusBlock> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (widget.kind == ChapterStatusBlockKind.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.readerLoading, style: theme.textTheme.bodyLarge),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(
            l10n.readerChapterLoadError,
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          if (widget.message != null && widget.message!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              widget.message!,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          if (widget.onRetry != null)
            FilledButton.tonal(
              onPressed: widget.onRetry,
              child: Text(l10n.readerRetry),
            ),
        ],
      ),
    );
  }
}
