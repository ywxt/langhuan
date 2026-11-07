import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../src/rust/api/types.dart';
import '../feed_service.dart';

/// Source initial shared by the list and detail sheet, with a subtle tonal
/// gradient. Paused sources use neutral colours; load failures use error tones.
class FeedAvatar extends StatelessWidget {
  const FeedAvatar({super.key, required this.feed, this.size = 40});

  final FeedMetaItem feed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasError = feed.error != null;
    final (background, highlight, foreground, outline) = hasError
        ? (
            colors.errorContainer,
            colors.errorContainer,
            colors.onErrorContainer,
            colors.error,
          )
        : feed.enabled
        ? (
            colors.primaryContainer,
            colors.secondaryContainer,
            colors.onPrimaryContainer,
            colors.primary,
          )
        : (
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
            colors.onSurfaceVariant,
            colors.outline,
          );
    final name = feed.name.trim();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [background, Color.lerp(background, highlight, .35)!],
          ),
          shape: BoxShape.circle,
          border: Border.all(color: outline.withAlpha(40)),
        ),
        alignment: Alignment.center,
        padding: EdgeInsets.all(size * .18),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: foreground,
              fontSize: size * .44,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
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
