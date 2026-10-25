import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../reader_settings_provider.dart';

String readerThemeModeLabel(AppLocalizations l10n, ReaderThemeMode mode) {
  return switch (mode) {
    ReaderThemeMode.system => l10n.readerThemeSystem,
    ReaderThemeMode.light => l10n.readerThemeLight,
    ReaderThemeMode.dark => l10n.readerThemeDark,
    ReaderThemeMode.sepia => l10n.readerThemeSepia,
  };
}

/// Presents the reader themes vertically. The leading icons (and the sepia
/// color swatch) show what each option looks like, so the choice reads as a
/// look, not just a word — the same rationale as the conversion picker.
Future<ReaderThemeMode?> showReaderThemePicker(
  BuildContext context, {
  required ReaderThemeMode selected,
}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<ReaderThemeMode>(
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
                l10n.readerThemeLabel,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final mode in ReaderThemeMode.values)
              ListTile(
                leading: _themeLeading(sheetContext, mode),
                title: Text(readerThemeModeLabel(l10n, mode)),
                trailing: mode == selected
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, mode),
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _themeLeading(BuildContext context, ReaderThemeMode mode) {
  final color = Theme.of(context).colorScheme.onSurfaceVariant;
  if (mode == ReaderThemeMode.sepia) {
    // Sepia is a color, not an icon: show the actual paper tone.
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: const Color(0xFFF3E9D2),
        shape: BoxShape.circle,
        border: Border.all(color: color),
      ),
    );
  }
  return Icon(
    switch (mode) {
      ReaderThemeMode.system => Icons.brightness_auto_outlined,
      ReaderThemeMode.light => Icons.light_mode_outlined,
      _ => Icons.dark_mode_outlined,
    },
    color: color,
  );
}
