import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/configuration_list_card.dart';
import '../bookshelf/widgets/chinese_conversion_picker.dart';
import 'transformer_settings.dart';

String transformerLabel(AppLocalizations l, TransformerKind kind) =>
    switch (kind) {
      TransformerKind.chineseConversion => l.settingsChineseConversion,
      TransformerKind.regexReplace => l.transformRegexReplace,
      TransformerKind.regexDelete => l.transformRegexDelete,
      TransformerKind.paragraphIndent => l.transformIndent,
      TransformerKind.deduplicateTitles => l.transformDeduplicate,
    };

String transformerDescription(AppLocalizations l, TransformerKind kind) =>
    switch (kind) {
      TransformerKind.chineseConversion => l.transformConversionDescription,
      TransformerKind.regexReplace => l.transformReplaceDescription,
      TransformerKind.regexDelete => l.transformDeleteDescription,
      TransformerKind.paragraphIndent => l.transformIndentDescription,
      TransformerKind.deduplicateTitles => l.transformDeduplicateDescription,
    };

IconData transformerIcon(TransformerKind kind) => switch (kind) {
  TransformerKind.chineseConversion => Icons.translate,
  TransformerKind.regexReplace => Icons.find_replace,
  TransformerKind.regexDelete => Icons.playlist_remove,
  TransformerKind.paragraphIndent => Icons.format_indent_increase,
  TransformerKind.deduplicateTitles => Icons.filter_1_outlined,
};

String transformerSummary(
  AppLocalizations l,
  TransformerEntry rule,
) => switch (rule.kind) {
  TransformerKind.chineseConversion => chineseConversionLabel(l, rule.mode),
  TransformerKind.paragraphIndent => l.transformIndentCharacters(
    rule.indentSpaces,
  ),
  TransformerKind.deduplicateTitles => l.transformKeepFirstTitle,
  TransformerKind.regexReplace =>
    '${rule.pattern} → ${rule.replacement.isEmpty ? l.transformEmptyReplacement : rule.replacement}',
  TransformerKind.regexDelete => rule.pattern,
};

/// Read-only list row. All changes are made in the dedicated editor.
class TransformerRuleCard extends StatelessWidget {
  const TransformerRuleCard({
    super.key,
    required this.rule,
    this.onTap,
    this.dragHandle,
  });
  final TransformerEntry rule;
  final VoidCallback? onTap;
  final Widget? dragHandle;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final type = transformerLabel(l, rule.kind);
    final summary = transformerSummary(l, rule);
    return ConfigurationListCard(
      leading: dragHandle ?? Icon(transformerIcon(rule.kind)),
      title: rule.name.isEmpty ? type : rule.name,
      subtitle: rule.name.isEmpty ? summary : '$type · $summary',
      status: Text(
        rule.enabled ? l.transformEnabled : l.transformDisabled,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: rule.enabled
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// Configuration form used only by the dedicated editor.
class TransformerRuleForm extends StatelessWidget {
  const TransformerRuleForm({
    super.key,
    required this.rule,
    required this.onChanged,
  });
  final TransformerEntry rule;
  final ValueChanged<TransformerEntry>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final editable = onChanged != null;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(l.transformEnabled),
              subtitle: Text(transformerDescription(l, rule.kind)),
              value: rule.enabled,
              onChanged: editable
                  ? (v) => onChanged!(rule.withEnabled(v))
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: rule.name,
              readOnly: !editable,
              decoration: InputDecoration(labelText: l.transformName),
              onChanged: (value) => onChanged?.call(rule.copyWith(name: value)),
            ),
            const SizedBox(height: 12),
            switch (rule.kind) {
              TransformerKind.chineseConversion => OutlinedButton.icon(
                icon: const Icon(Icons.translate),
                label: Text(chineseConversionLabel(l, rule.mode)),
                onPressed: !editable
                    ? null
                    : () async {
                        final mode = await showChineseConversionPicker(
                          context,
                          selected: rule.mode,
                        );
                        if (mode != null && context.mounted) {
                          onChanged!(rule.copyWith(mode: mode));
                        }
                      },
              ),
              TransformerKind.paragraphIndent => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.transformIndentCharacters(rule.indentSpaces)),
                  Slider(
                    min: 0,
                    max: 8,
                    divisions: 8,
                    label: '${rule.indentSpaces}',
                    value: rule.indentSpaces.toDouble(),
                    onChanged: editable
                        ? (v) =>
                              onChanged!(rule.copyWith(indentSpaces: v.round()))
                        : null,
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${'\u3000' * rule.indentSpaces}${l.readerThemePreviewBody}',
                    ),
                  ),
                ],
              ),
              TransformerKind.deduplicateTitles => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.first_page),
                title: Text(l.transformKeepFirstTitle),
              ),
              TransformerKind.regexReplace ||
              TransformerKind.regexDelete => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    initialValue: rule.pattern,
                    readOnly: !editable,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      labelText: l.transformPattern,
                      suffixIcon: Tooltip(
                        message: l.transformRegexHelp,
                        child: const Icon(Icons.help_outline),
                      ),
                    ),
                    validator: editable && rule.enabled
                        ? (v) => v == null || v.isEmpty
                              ? l.transformPatternRequired
                              : null
                        : null,
                    onChanged: (value) =>
                        onChanged?.call(rule.copyWith(pattern: value)),
                  ),
                  if (rule.kind == TransformerKind.regexReplace) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: rule.replacement,
                      readOnly: !editable,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: l.transformReplacement,
                      ),
                      onChanged: (value) =>
                          onChanged?.call(rule.copyWith(replacement: value)),
                    ),
                  ],
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.transformIncludeTitles),
                    value: rule.includeTitles,
                    onChanged: editable
                        ? (v) => onChanged!(rule.copyWith(includeTitles: v!))
                        : null,
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}
