import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';

String chineseConversionLabel(
  AppLocalizations l10n,
  ChineseConversionMode mode,
) {
  return switch (mode) {
    ChineseConversionMode.none => l10n.chineseConversionNone,
    ChineseConversionMode.s2T => l10n.chineseConversionS2t,
    ChineseConversionMode.t2S => l10n.chineseConversionT2s,
    ChineseConversionMode.s2Tw => l10n.chineseConversionS2tw,
    ChineseConversionMode.s2Hk => l10n.chineseConversionS2hk,
  };
}

/// Presents conversion modes vertically so regional names never have to fit
/// into cramped segmented controls or a settings-row dropdown.
Future<ChineseConversionMode?> showChineseConversionPicker(
  BuildContext context, {
  required ChineseConversionMode selected,
}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<ChineseConversionMode>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                0,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceSm,
              ),
              child: Text(
                l10n.readerChineseConversion,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final mode in ChineseConversionMode.values)
              ListTile(
                leading: Icon(
                  mode == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: mode == selected
                      ? Theme.of(sheetContext).colorScheme.primary
                      : Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
                title: Text(chineseConversionLabel(l10n, mode)),
                selected: mode == selected,
                onTap: () => Navigator.pop(sheetContext, mode),
              ),
          ],
        ),
      ),
    ),
  );
}
