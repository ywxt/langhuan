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
    ReaderThemeMode.custom => l10n.readerThemeCustom,
  };
}

/// Presents the reader themes vertically. The leading icons (and the sepia
/// color swatch) show what each option looks like, so the choice reads as a
/// look, not just a word — the same rationale as the conversion picker.
Future<ReaderThemeMode?> showReaderThemePicker(
  BuildContext context, {
  required ReaderThemeMode selected,
  required ReaderCustomTheme customTheme,
}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<ReaderThemeMode>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
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
                leading: _themeLeading(sheetContext, mode, customTheme),
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

Widget _themeLeading(
  BuildContext context,
  ReaderThemeMode mode,
  ReaderCustomTheme customTheme,
) {
  final color = Theme.of(context).colorScheme.onSurfaceVariant;
  if (mode == ReaderThemeMode.sepia || mode == ReaderThemeMode.custom) {
    // Sepia is a color, not an icon: show the actual paper tone.
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: mode == ReaderThemeMode.sepia
            ? const Color(0xFFF3E9D2)
            : customTheme.background,
        shape: BoxShape.circle,
        border: Border.all(
          color: mode == ReaderThemeMode.custom ? customTheme.accent : color,
          width: mode == ReaderThemeMode.custom ? 3 : 1,
        ),
      ),
    );
  }
  return Icon(switch (mode) {
    ReaderThemeMode.system => Icons.brightness_auto_outlined,
    ReaderThemeMode.light => Icons.light_mode_outlined,
    _ => Icons.dark_mode_outlined,
  }, color: color);
}

const _backgroundColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFFF7F2E8),
  Color(0xFFF3E9D2),
  Color(0xFFEAF3E2),
  Color(0xFFE8F0F7),
  Color(0xFF1E211B),
  Color(0xFF161A20),
  Color(0xFF111111),
];

const _textColors = <Color>[
  Color(0xFF111111),
  Color(0xFF302A22),
  Color(0xFF374151),
  Color(0xFF163300),
  Color(0xFFF4F4F0),
  Color(0xFFE8E1D5),
];

const _accentColors = <Color>[
  Color(0xFF163300),
  Color(0xFF7A5C3E),
  Color(0xFF8A5A2B),
  Color(0xFF315C8A),
  Color(0xFF6B4EA0),
  Color(0xFFA13D2D),
  Color(0xFF9FE870),
];

Future<ReaderCustomTheme?> showReaderCustomThemeEditor(
  BuildContext context, {
  required ReaderCustomTheme initial,
}) => showModalBottomSheet<ReaderCustomTheme>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ReaderCustomThemeEditor(initial: initial),
);

class _ReaderCustomThemeEditor extends StatefulWidget {
  const _ReaderCustomThemeEditor({required this.initial});

  final ReaderCustomTheme initial;

  @override
  State<_ReaderCustomThemeEditor> createState() =>
      _ReaderCustomThemeEditorState();
}

class _ReaderCustomThemeEditorState extends State<_ReaderCustomThemeEditor> {
  late ReaderCustomTheme _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
  }

  void _updateBackground(Color color) {
    setState(() => _draft = _draft.copyWith(background: color));
  }

  void _updateForeground(Color color) {
    setState(() => _draft = _draft.copyWith(foreground: color));
  }

  void _updateAccent(Color color) {
    setState(() => _draft = _draft.copyWith(accent: color));
  }

  void _reset() {
    setState(() => _draft = const ReaderCustomTheme());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasReadableContrast =
        _contrastRatio(_draft.background, _draft.foreground) >= 4.5;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          0,
          LanghuanTheme.spaceLg,
          MediaQuery.viewInsetsOf(context).bottom + LanghuanTheme.spaceLg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.readerThemeCustomizeTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: LanghuanTheme.spaceLg),
            _ThemeColorField(
              label: l10n.readerThemeBackground,
              pickerKey: 'reader-theme-color-background',
              colors: _backgroundColors,
              selected: _draft.background,
              onSelected: _updateBackground,
            ),
            _ThemeColorField(
              label: l10n.readerThemeText,
              pickerKey: 'reader-theme-color-text',
              colors: _textColors,
              selected: _draft.foreground,
              onSelected: _updateForeground,
            ),
            _ThemeColorField(
              label: l10n.readerThemeAccent,
              pickerKey: 'reader-theme-color-accent',
              colors: _accentColors,
              selected: _draft.accent,
              onSelected: _updateAccent,
            ),
            const SizedBox(height: LanghuanTheme.spaceSm),
            Text(
              l10n.readerThemePreview,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: LanghuanTheme.spaceSm),
            _ThemePreview(theme: _draft, l10n: l10n),
            if (!hasReadableContrast) ...[
              const SizedBox(height: LanghuanTheme.spaceSm),
              Text(
                l10n.readerThemeContrastWarning,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: LanghuanTheme.spaceLg),
            Row(
              children: [
                TextButton(
                  onPressed: _reset,
                  child: Text(l10n.readerThemeReset),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: hasReadableContrast
                      ? () => Navigator.pop(context, _draft)
                      : null,
                  child: Text(l10n.readerThemeApply),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeColorField extends StatelessWidget {
  const _ThemeColorField({
    required this.label,
    required this.pickerKey,
    required this.colors,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final String pickerKey;
  final List<Color> colors;
  final Color selected;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              OutlinedButton(
                key: ValueKey(pickerKey),
                onPressed: () async {
                  final picked = await showDialog<Color>(
                    context: context,
                    builder: (_) => _ReaderColorPickerDialog(
                      title: label,
                      initial: selected,
                    ),
                  );
                  if (picked != null) onSelected(picked);
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LanghuanTheme.spaceMdSm,
                    vertical: LanghuanTheme.spaceSm,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: selected,
                        shape: BoxShape.circle,
                        border: Border.all(color: theme.colorScheme.outline),
                      ),
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    Text('#${_hexColor(selected)}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: LanghuanTheme.spaceSm),
          Wrap(
            spacing: LanghuanTheme.spaceSm,
            runSpacing: LanghuanTheme.spaceSm,
            children: [
              for (final color in colors)
                Semantics(
                  button: true,
                  selected: color == selected,
                  label:
                      '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                  child: InkWell(
                    key: ValueKey('$pickerKey-${_hexColor(color)}'),
                    customBorder: const CircleBorder(),
                    onTap: () => onSelected(color),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                          width: color == selected ? 3 : 1,
                        ),
                      ),
                      child: color == selected
                          ? Icon(
                              Icons.check,
                              size: 20,
                              color: color.computeLuminance() > 0.5
                                  ? Colors.black
                                  : Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReaderColorPickerDialog extends StatefulWidget {
  const _ReaderColorPickerDialog({required this.title, required this.initial});

  final String title;
  final Color initial;

  @override
  State<_ReaderColorPickerDialog> createState() =>
      _ReaderColorPickerDialogState();
}

class _ReaderColorPickerDialogState extends State<_ReaderColorPickerDialog> {
  late HSVColor _color;

  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _color.toColor();
    final hueColor = HSVColor.fromAHSV(1, _color.hue, 1, 1).toColor();
    final saturationColor = HSVColor.fromAHSV(
      1,
      _color.hue,
      _color.saturation,
      1,
    ).toColor();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              height: 64,
              decoration: BoxDecoration(
                color: color,
                borderRadius: LanghuanTheme.borderRadiusMd,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '#${_hexColor(color)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color.computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
                ),
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceLg),
            _ColorSlider(
              sliderKey: const ValueKey('reader-theme-hue-slider'),
              label: l10n.readerThemeColorHue,
              value: _color.hue,
              max: 360,
              gradient: const LinearGradient(
                colors: [
                  Colors.red,
                  Colors.yellow,
                  Colors.green,
                  Colors.cyan,
                  Colors.blue,
                  Colors.purple,
                  Colors.red,
                ],
              ),
              thumbColor: hueColor,
              onChanged: (value) =>
                  setState(() => _color = _color.withHue(value)),
            ),
            _ColorSlider(
              sliderKey: const ValueKey('reader-theme-saturation-slider'),
              label: l10n.readerThemeColorSaturation,
              value: _color.saturation,
              gradient: LinearGradient(colors: [Colors.white, hueColor]),
              thumbColor: color,
              onChanged: (value) =>
                  setState(() => _color = _color.withSaturation(value)),
            ),
            _ColorSlider(
              sliderKey: const ValueKey('reader-theme-brightness-slider'),
              label: l10n.readerThemeColorBrightness,
              value: _color.value,
              gradient: LinearGradient(colors: [Colors.black, saturationColor]),
              thumbColor: color,
              onChanged: (value) =>
                  setState(() => _color = _color.withValue(value)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.readerThemeColorCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: Text(l10n.readerThemeApply),
        ),
      ],
    );
  }
}

class _ColorSlider extends StatelessWidget {
  const _ColorSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.gradient,
    required this.thumbColor,
    required this.onChanged,
    this.max = 1,
  });

  final Key sliderKey;
  final String label;
  final double value;
  final double max;
  final Gradient gradient;
  final Color thumbColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: LanghuanTheme.spaceXs),
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 20,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  secondaryActiveTrackColor: Colors.transparent,
                  thumbColor: thumbColor,
                  overlayColor: thumbColor.withAlpha(30),
                ),
                child: Slider(
                  key: sliderKey,
                  value: value,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.theme, required this.l10n});

  final ReaderCustomTheme theme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: LanghuanTheme.borderRadiusMd,
        border: Border.all(color: theme.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.readerThemePreviewTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: theme.foreground),
          ),
          const SizedBox(height: LanghuanTheme.spaceSm),
          Text(
            l10n.readerThemePreviewBody,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: theme.foreground),
          ),
          const SizedBox(height: LanghuanTheme.spaceMd),
          LinearProgressIndicator(
            value: 0.62,
            color: theme.accent,
            backgroundColor: Color.lerp(
              theme.background,
              theme.foreground,
              0.12,
            ),
          ),
        ],
      ),
    );
  }
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

String _hexColor(Color color) => color
    .toARGB32()
    .toRadixString(16)
    .padLeft(8, '0')
    .substring(2)
    .toUpperCase();
