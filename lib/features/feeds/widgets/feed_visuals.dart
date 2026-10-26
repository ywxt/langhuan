import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../src/rust/api/types.dart';
import '../feed_service.dart';

/// Circular avatar with the feed's initial, tinted by its health.
///
/// 40px circle per the Wise design spec §4.3; pass [size] to scale it up
/// in larger contexts such as the detail sheet header.
class FeedAvatar extends StatelessWidget {
  const FeedAvatar({super.key, required this.feed, this.size = 40});

  final FeedMetaItem feed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = feed.error != null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: hasError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        feed.name.isNotEmpty ? feed.name[0].toUpperCase() : '?',
        style:
            (size >= 48
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.titleMedium)
                ?.copyWith(
                  color: hasError
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
      ),
    );
  }
}

/// Small rounded status chip used for feed badges.
class FeedStatusChip extends StatelessWidget {
  const FeedStatusChip({
    super.key,
    required this.label,
    this.foreground,
    this.background,
  });

  final String label;
  final Color? foreground;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground ?? scheme.onSurfaceVariant,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// Chip showing a feed's auth status, tinted by severity.
class FeedAuthBadge extends StatelessWidget {
  const FeedAuthBadge({super.key, required this.status});

  final FeedAuthStatusModel status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final (label, foreground, background) = switch (status) {
      FeedAuthStatusModel.loggedIn => (
        l10n.feedAuthStatusLoggedIn,
        theme.colorScheme.onTertiaryContainer,
        theme.colorScheme.tertiaryContainer,
      ),
      FeedAuthStatusModel.expired => (
        l10n.feedAuthStatusExpired,
        theme.colorScheme.onErrorContainer,
        theme.colorScheme.errorContainer,
      ),
      FeedAuthStatusModel.loggedOut => (
        l10n.feedAuthStatusLoggedOut,
        null,
        null,
      ),
      FeedAuthStatusModel.unsupported => (
        l10n.feedAuthStatusUnsupported,
        null,
        null,
      ),
    };

    return FeedStatusChip(
      label: label,
      foreground: foreground,
      background: background,
    );
  }
}
