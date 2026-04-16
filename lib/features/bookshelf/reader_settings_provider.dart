import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ReaderMode { verticalScroll, horizontalPaging }

enum ReaderThemeMode { system, light, dark, sepia }

class ReaderSettingsState {
  const ReaderSettingsState({
    this.mode = ReaderMode.verticalScroll,
    this.fontScale = 1.0,
    this.lineHeight = 1.8,
    this.themeMode = ReaderThemeMode.system,
  });

  final ReaderMode mode;
  final double fontScale;
  final double lineHeight;
  final ReaderThemeMode themeMode;

  ReaderSettingsState copyWith({
    ReaderMode? mode,
    double? fontScale,
    double? lineHeight,
    ReaderThemeMode? themeMode,
  }) {
    return ReaderSettingsState(
      mode: mode ?? this.mode,
      fontScale: fontScale ?? this.fontScale,
      lineHeight: lineHeight ?? this.lineHeight,
      themeMode: themeMode ?? this.themeMode,
    );
  }
}

class ReaderSettingsNotifier extends Notifier<ReaderSettingsState> {
  @override
  ReaderSettingsState build() => const ReaderSettingsState();

  void setMode(ReaderMode mode) {
    state = state.copyWith(mode: mode);
  }

  void setFontScale(double fontScale) {
    state = state.copyWith(fontScale: fontScale.clamp(0.8, 1.8));
  }

  void setLineHeight(double lineHeight) {
    state = state.copyWith(lineHeight: lineHeight.clamp(1.2, 2.4));
  }

  void setThemeMode(ReaderThemeMode mode) {
    state = state.copyWith(themeMode: mode);
  }
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsNotifier, ReaderSettingsState>(
      ReaderSettingsNotifier.new,
    );

ThemeData resolveReaderTheme(ThemeData base, ReaderThemeMode mode) {
  return switch (mode) {
    ReaderThemeMode.system => base,
    ReaderThemeMode.light => ThemeData.light(useMaterial3: true),
    ReaderThemeMode.dark => ThemeData.dark(useMaterial3: true),
    ReaderThemeMode.sepia => _sepiaTheme(base),
  };
}

ThemeData _sepiaTheme(ThemeData base) {
  const background = Color(0xFFF3E9D2);
  const foreground = Color(0xFF4A3B2A);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF8A5A2B),
        brightness: Brightness.light,
      ).copyWith(
        surface: background,
        surfaceContainer: const Color(0xFFE8D9B5),
        onSurface: foreground,
        onSurfaceVariant: foreground,
      );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    textTheme: base.textTheme.apply(
      bodyColor: foreground,
      displayColor: foreground,
    ),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: const Color(0xFFE8D9B5),
      foregroundColor: foreground,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
