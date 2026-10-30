import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../src/rust/api/debug.dart';

class DebugStepTraceView extends StatelessWidget {
  const DebugStepTraceView({
    super.key,
    required this.entries,
    required this.dropped,
  });

  final List<DebugStepTraceEntry> entries;
  final int dropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (entries.isEmpty) {
      return Text(
        l10n.debugStepEmpty,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, entry) in entries.indexed)
          _StepTile(index: index, entry: entry),
        if (dropped > 0)
          Padding(
            padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
            child: Text(
              l10n.debugStepDropped(dropped),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.index, required this.entry});

  final int index;
  final DebugStepTraceEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final color = switch (entry.kind) {
      'request' => theme.colorScheme.primary,
      'compute' => theme.colorScheme.tertiary,
      'webview' => theme.colorScheme.secondary,
      'fail' => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: LanghuanTheme.borderRadiusSm,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: color.withValues(alpha: 0.14),
            foregroundColor: color,
            child: Text('${index + 1}', style: theme.textTheme.labelSmall),
          ),
          const SizedBox(width: LanghuanTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: LanghuanTheme.spaceSm,
                  children: [
                    Text(
                      entry.kind,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: color,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      l10n.debugStepRound(entry.operation, entry.round),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LanghuanTheme.spaceXs),
                SelectionArea(
                  child: Text(
                    entry.summary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
