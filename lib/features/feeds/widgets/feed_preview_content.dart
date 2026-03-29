import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../feed_service.dart';

// ---------------------------------------------------------------------------
// URL text field
// ---------------------------------------------------------------------------

/// Text field for entering a feed script URL.
class UrlInputContent extends StatelessWidget {
  const UrlInputContent({
    super.key,
    required this.controller,
    required this.l10n,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final AppLocalizations l10n;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: l10n.addFeedUrlHint,
          prefixIcon: const Icon(Icons.link_rounded),
        ),
        keyboardType: TextInputType.url,
        autofillHints: const [AutofillHints.url],
        autofocus: true,
        onSubmitted: (_) => onSubmit(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading / installing spinner
// ---------------------------------------------------------------------------

/// Centered spinner shown while loading or installing a feed.
class LoadingContent extends StatelessWidget {
  const LoadingContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 300,
      height: 100,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

// ---------------------------------------------------------------------------
// Feed preview card
// ---------------------------------------------------------------------------

/// Displays feed metadata (name, version, author, domains) before install.
class FeedPreviewContent extends StatelessWidget {
  const FeedPreviewContent({
    super.key,
    required this.preview,
    required this.colorScheme,
    required this.l10n,
  });

  final FeedPreviewModel preview;
  final ColorScheme colorScheme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Name + version ──
          Row(
            children: [
              Expanded(
                child: Text(preview.name, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(width: LanghuanTheme.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceSm,
                  vertical: LanghuanTheme.spaceXs,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: LanghuanTheme.borderRadiusSm,
                ),
                child: Text(
                  'v${preview.version}',
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ],
          ),
          // ── Upgrade banner ──
          if (preview.isUpgrade && preview.currentVersion != null) ...[
            const SizedBox(height: LanghuanTheme.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceSm,
                vertical: LanghuanTheme.spaceXs,
              ),
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer,
                borderRadius: LanghuanTheme.borderRadiusSm,
              ),
              child: Text(
                l10n.addFeedIsUpgrade(preview.currentVersion!, preview.version),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
          if (preview.author != null) ...[
            const SizedBox(height: LanghuanTheme.spaceXs),
            Text(
              preview.author!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: LanghuanTheme.spaceMd),
          Divider(color: colorScheme.outline),
          const SizedBox(height: LanghuanTheme.spaceMd),
          // ── Base URL ──
          Row(
            children: [
              Icon(Icons.link, size: 14, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: LanghuanTheme.spaceXs),
              Expanded(
                child: Text(
                  preview.baseUrl,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: LanghuanTheme.spaceMd),
          // ── Domain access ──
          Text(
            l10n.addFeedAllowedDomains,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LanghuanTheme.spaceSm),
          if (preview.allowedDomains.isEmpty)
            Text(
              l10n.addFeedNoDomainRestriction,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            Wrap(
              spacing: LanghuanTheme.spaceSm,
              runSpacing: LanghuanTheme.spaceXs,
              children: preview.allowedDomains
                  .map(
                    (d) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LanghuanTheme.spaceSm,
                        vertical: LanghuanTheme.spaceXs,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: LanghuanTheme.borderRadiusSm,
                      ),
                      child: Text(d, style: theme.textTheme.labelMedium),
                    ),
                  )
                  .toList(),
            ),
          // ── Description ──
          if (preview.description != null) ...[
            const SizedBox(height: LanghuanTheme.spaceMd),
            Text(
              preview.description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error display
// ---------------------------------------------------------------------------

/// Error message shown when feed preview or install fails.
class FeedErrorContent extends StatelessWidget {
  const FeedErrorContent({
    super.key,
    required this.message,
    required this.colorScheme,
  });

  final String message;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 300,
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
          const SizedBox(width: LanghuanTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
