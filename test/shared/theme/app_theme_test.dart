import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/shared/theme/app_theme.dart';

void main() {
  test('dark green buttons use the color scheme container foreground', () {
    final theme = LanghuanTheme.dark();
    final buttonForeground = theme.filledButtonTheme.style?.foregroundColor
        ?.resolve(<WidgetState>{});

    expect(buttonForeground, theme.colorScheme.onPrimaryContainer);
    expect(
      theme.floatingActionButtonTheme.foregroundColor,
      theme.colorScheme.onPrimaryContainer,
    );
    expect(buttonForeground, isNot(const Color(0xFF121511)));
  });
}
