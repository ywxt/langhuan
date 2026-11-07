import 'package:flutter/material.dart';

/// Label at the left end, current value at the right end — the app-wide
/// setting-row layout (ui-design-spec §4.5).
///
/// ```
/// Label                        Value
/// ```
class SettingValueRow extends StatelessWidget {
  const SettingValueRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;

  /// Key for the far-end value text, so tests can pin the row's value.
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(label),
        const Spacer(),
        Text(
          value,
          key: valueKey,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
