import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';

enum ChapterStatusBlockKind { loading, error }

/// Inline block rendered in place of a chapter's content while it is being
/// fetched or after the fetch failed.
///
/// Both reader modes share it. [chapterTitle] anchors the block when the
/// title is known, so the reader can tell *which* chapter is loading or
/// failed even mid-scroll in the seamless view.
class ChapterStatusBlock extends StatelessWidget {
  const ChapterStatusBlock({
    super.key,
    required this.kind,
    this.chapterTitle,
    this.message,
    this.onRetry,
  });

  final ChapterStatusBlockKind kind;
  final String? chapterTitle;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      ChapterStatusBlockKind.loading => _LoadingBlock(
        chapterTitle: chapterTitle,
      ),
      ChapterStatusBlockKind.error => _ErrorBlock(
        chapterTitle: chapterTitle,
        message: message,
        onRetry: onRetry,
      ),
    };
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({this.chapterTitle});

  final String? chapterTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = chapterTitle;
    final hasTitle = title != null && title.isNotEmpty;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasTitle) ...[
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LanghuanSpinner(size: 20),
              const SizedBox(width: LanghuanTheme.spaceMdSm),
              Text(
                AppLocalizations.of(context).readerLoading,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({this.chapterTitle, this.message, this.onRetry});

  final String? chapterTitle;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = chapterTitle;
    final detail = message;
    final hasTitle = title != null && title.isNotEmpty;
    final hasDetail = detail != null && detail.isNotEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LanghuanTheme.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.error_outline_rounded,
                size: 32,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceLg),
            Text(
              l10n.readerChapterLoadError,
              style: theme.textTheme.titleMedium,
            ),
            if (hasTitle) ...[
              const SizedBox(height: LanghuanTheme.spaceXs),
              Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (hasDetail) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceMd,
                  vertical: LanghuanTheme.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(LanghuanTheme.radiusSm),
                ),
                child: Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: LanghuanTheme.spaceLg),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.readerRetry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
