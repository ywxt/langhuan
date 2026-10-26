import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/format_bytes.dart';
import '../../src/rust/api/debug.dart';

/// The HTTP trace of a debug run: one expandable row per recorded request
/// (including blocked and failed ones), with masked request headers and a
/// bounded body preview.
class DebugTraceSection extends StatelessWidget {
  const DebugTraceSection({
    super.key,
    required this.entries,
    required this.dropped,
  });

  final List<HttpTraceEntry> entries;
  final int dropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (entries.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(theme, l10n),
          const SizedBox(height: LanghuanTheme.spaceSm),
          Text(
            l10n.debugTraceEmpty,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, l10n),
        if (dropped > 0) ...[
          const SizedBox(height: LanghuanTheme.spaceXs),
          Text(
            l10n.debugTraceDropped(dropped),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
            ),
          ),
        ],
        const SizedBox(height: LanghuanTheme.spaceSm),
        for (final (index, entry) in entries.indexed)
          _TraceEntryTile(entry: entry, index: index),
      ],
    );
  }

  Widget _header(ThemeData theme, AppLocalizations l10n) {
    return Row(
      children: [
        Icon(
          Icons.swap_vert_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: LanghuanTheme.spaceSm),
        Text(
          l10n.debugTraceTitle(entries.length),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TraceEntryTile extends StatelessWidget {
  const _TraceEntryTile({required this.entry, required this.index});

  final HttpTraceEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final status = entry.status;
    final failed = status == null || status >= 400;

    return Padding(
      padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceXs),
      child: Material(
        color: failed
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainer,
        borderRadius: LanghuanTheme.borderRadiusSm,
        child: Theme(
          // ExpansionTile's default divider is unwanted inside the card.
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: index == 0,
            tilePadding: const EdgeInsets.symmetric(
              horizontal: LanghuanTheme.spaceMdSm,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              LanghuanTheme.spaceMdSm,
              0,
              LanghuanTheme.spaceMdSm,
              LanghuanTheme.spaceMdSm,
            ),
            dense: true,
            title: Row(
              children: [
                _StatusBadge(status: status),
                const SizedBox(width: LanghuanTheme.spaceSm),
                Text(
                  entry.method,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: LanghuanTheme.spaceSm),
                Expanded(
                  child: Text(
                    entry.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            trailing: Text(
              '${entry.elapsedMs} ms',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            children: [
              if (entry.error != null) _ErrorLine(error: entry.error!),
              if (entry.finalUrl != null && entry.finalUrl != entry.url)
                _DetailLine(label: 'URL', value: entry.finalUrl!),
              if (entry.responseSize != null)
                _DetailLine(
                  label: l10n.debugTraceSize,
                  value: formatBytes(entry.responseSize!),
                ),
              if (entry.requestHeaders.isNotEmpty)
                _DetailLine(
                  label: l10n.debugTraceHeaders,
                  value: entry.requestHeaders
                      .map((h) => '${h.$1}: ${h.$2}')
                      .join('\n'),
                ),
              if (entry.bodyPreview != null && entry.bodyPreview!.isNotEmpty)
                _PreviewBlock(
                  label: l10n.debugTraceBodyPreview,
                  text: entry.bodyPreview!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final int? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label) = switch (status) {
      null => (theme.colorScheme.error, 'ERR'),
      int s when s < 300 => (theme.colorScheme.primary, '$s'),
      int s when s < 400 => (theme.colorScheme.tertiary, '$s'),
      _ => (theme.colorScheme.error, '$status'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
          fontFeatures: [const FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        error,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LanghuanTheme.spaceXs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scrollable, selectable monospace preview bounded to a few lines so one
/// large body does not dominate the page.
class _PreviewBlock extends StatelessWidget {
  const _PreviewBlock({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LanghuanTheme.spaceXs),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: LanghuanTheme.borderRadiusSm,
            ),
            padding: const EdgeInsets.all(LanghuanTheme.spaceSm),
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
