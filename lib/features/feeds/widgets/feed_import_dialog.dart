import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';

/// Confirmation dialog for a feed import: lists every entry with how its
/// version relates to the installed one. Pops with `true` when the user
/// confirms the import.
class FeedImportDialog extends StatelessWidget {
  const FeedImportDialog({super.key, required this.entries});

  final List<FeedImportEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final mat = MaterialLocalizations.of(context);

    return AlertDialog(
      title: Text(l10n.feedsImportTitle),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.feedsImportCount(entries.length),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: LanghuanTheme.spaceXs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            style: theme.textTheme.bodyLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            entry.author != null
                                ? 'v${entry.version} · ${entry.author}'
                                : 'v${entry.version}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    _ChangeBadge(entry: entry),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(mat.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.feedsImportConfirm),
        ),
      ],
    );
  }
}

/// Small colored badge stating how an entry's version relates to the
/// installed one (same palette as the add-feed preview banner).
class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({required this.entry});

  final FeedImportEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    final (text, background, foreground) = switch (entry.change) {
      VersionChange.new_ => (
        l10n.feedsImportChangeNew,
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
      VersionChange.upgrade => (
        l10n.feedsImportChangeUpgrade,
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
      VersionChange.downgrade => (
        l10n.feedsImportChangeDowngrade,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      VersionChange.same => (
        l10n.feedsImportChangeSame,
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
      ),
      VersionChange.unknown => (
        l10n.feedsImportChangeUnknown,
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LanghuanTheme.spaceSm,
        vertical: LanghuanTheme.spaceXs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: LanghuanTheme.borderRadiusSm,
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
        ),
      ),
    );
  }
}

/// Show [FeedImportDialog] and return whether the user confirmed.
Future<bool> showFeedImportDialog(
  BuildContext context, {
  required List<FeedImportEntry> entries,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => FeedImportDialog(entries: entries),
  );
  return result ?? false;
}
