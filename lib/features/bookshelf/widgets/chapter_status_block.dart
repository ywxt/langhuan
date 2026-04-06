import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

enum ChapterStatusBlockKind { loading, error }

class ChapterStatusBlock extends StatefulWidget {
  const ChapterStatusBlock({
    super.key,
    required this.kind,
    this.title,
    this.message,
    this.onRetry,
    this.compact = false,
    this.padding,
  });

  final ChapterStatusBlockKind kind;
  final String? title;
  final String? message;
  final Future<void> Function()? onRetry;
  final bool compact;
  final EdgeInsetsGeometry? padding;

  @override
  State<ChapterStatusBlock> createState() => _ChapterStatusBlockState();
}

class _ChapterStatusBlockState extends State<ChapterStatusBlock> {
  bool _isRetrying = false;

  Future<void> _handleRetry() async {
    final onRetry = widget.onRetry;
    if (onRetry == null || _isRetrying) {
      return;
    }

    setState(() {
      _isRetrying = true;
    });

    try {
      await onRetry();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final compact = widget.compact;
    final effectivePadding = widget.padding ?? EdgeInsets.all(compact ? 0 : 32);
    final iconSize = compact ? 16.0 : 64.0;
    final gap = compact ? 8.0 : 16.0;
    final titleStyle = compact
        ? theme.textTheme.labelMedium
        : theme.textTheme.titleMedium;
    final statusStyle = compact
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyLarge;
    final effectiveKind = _isRetrying
        ? ChapterStatusBlockKind.loading
        : widget.kind;

    return Container(
      padding: effectivePadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        mainAxisAlignment: compact
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty) ...[
            Text(widget.title!, style: titleStyle, textAlign: TextAlign.center),
            SizedBox(height: gap),
          ],
          if (effectiveKind == ChapterStatusBlockKind.loading) ...[
            if (compact)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: iconSize,
                    height: iconSize,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.readerLoading, style: statusStyle),
                ],
              )
            else ...[
              const CircularProgressIndicator(),
              SizedBox(height: gap),
              Text(l10n.readerLoading, style: statusStyle),
            ],
          ],
          if (effectiveKind == ChapterStatusBlockKind.error) ...[
            Icon(
              Icons.error_outline,
              size: compact ? 32 : iconSize,
              color: theme.colorScheme.error,
            ),
            SizedBox(height: gap),
            Text(
              l10n.readerChapterLoadError,
              style: statusStyle?.copyWith(
                color: compact ? theme.colorScheme.error : null,
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.message != null && widget.message!.isNotEmpty) ...[
              SizedBox(height: compact ? 6 : 10),
              Text(
                widget.message!,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            SizedBox(height: compact ? 10 : 16),
            FilledButton.tonal(
              onPressed: _handleRetry,
              child: Text(l10n.readerRetry),
            ),
          ],
        ],
      ),
    );
  }
}
