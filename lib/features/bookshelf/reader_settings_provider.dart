import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/rust/api/conversion.dart' as rust_conversion;
import '../../src/rust/api/types.dart' show ChineseConversionMode;

enum ReaderThemeMode { system, light, dark, sepia }

class ReaderFontOption {
  const ReaderFontOption({
    required this.id,
    required this.label,
    required this.family,
  });

  final String id;
  final String label;
  final String? family;
}

const readerFontOptions = <ReaderFontOption>[
  ReaderFontOption(id: 'system', label: 'System Default', family: null),
  ReaderFontOption(
    id: 'noto_sans_cjk_sc',
    label: 'Noto Sans CJK SC',
    family: 'Noto Sans CJK SC',
  ),
  ReaderFontOption(
    id: 'noto_serif_cjk_sc',
    label: 'Noto Serif CJK SC',
    family: 'Noto Serif CJK SC',
  ),
  ReaderFontOption(id: 'serif', label: 'Serif', family: 'serif'),
  ReaderFontOption(id: 'monospace', label: 'Monospace', family: 'monospace'),
];

class ReaderSettingsState {
  const ReaderSettingsState({
    this.fontScale = 1.0,
    this.fontFamily,
    this.customFontFilePath,
    this.customFontDisplayName,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = 16.0,
    this.lineHeight = 1.8,
    this.themeMode = ReaderThemeMode.system,
    this.chineseConversion = ChineseConversionMode.none,
  });

  final double fontScale;
  final String? fontFamily;
  final String? customFontFilePath;
  final String? customFontDisplayName;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final ReaderThemeMode themeMode;
  final ChineseConversionMode chineseConversion;

  ReaderSettingsState copyWith({
    double? fontScale,
    String? Function()? fontFamily,
    String? Function()? customFontFilePath,
    String? Function()? customFontDisplayName,
    double? letterSpacing,
    double? paragraphSpacing,
    double? lineHeight,
    ReaderThemeMode? themeMode,
    ChineseConversionMode? chineseConversion,
  }) {
    return ReaderSettingsState(
      fontScale: fontScale ?? this.fontScale,
      fontFamily: fontFamily != null ? fontFamily() : this.fontFamily,
      customFontFilePath: customFontFilePath != null
          ? customFontFilePath()
          : this.customFontFilePath,
      customFontDisplayName: customFontDisplayName != null
          ? customFontDisplayName()
          : this.customFontDisplayName,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      lineHeight: lineHeight ?? this.lineHeight,
      themeMode: themeMode ?? this.themeMode,
      chineseConversion: chineseConversion ?? this.chineseConversion,
    );
  }
}

class ReaderSettingsNotifier extends Notifier<ReaderSettingsState> {
  static const _kFontScale = 'reader.fontScale';
  static const _kFontFamily = 'reader.fontFamily';
  static const _kCustomFontFilePath = 'reader.customFontFilePath';
  static const _kCustomFontDisplayName = 'reader.customFontDisplayName';
  static const _kLetterSpacing = 'reader.letterSpacing';
  static const _kParagraphSpacing = 'reader.paragraphSpacing';
  static const _kLineHeight = 'reader.lineHeight';
  static const _kThemeMode = 'reader.themeMode';
  static const _kChineseConversion = 'reader.chineseConversion';

  @override
  ReaderSettingsState build() {
    _restoreFromStorage();
    return const ReaderSettingsState();
  }

  void setFontScale(double fontScale) {
    state = state.copyWith(fontScale: fontScale.clamp(0.8, 1.8));
    _persistState();
  }

  void setFontFamily(String? fontFamily) {
    final normalized = fontFamily?.trim();
    state = state.copyWith(
      fontFamily: () =>
          (normalized == null || normalized.isEmpty) ? null : normalized,
      customFontFilePath: () => null,
      customFontDisplayName: () => null,
    );
    _persistState();
  }

  Future<void> loadFontFromFile(String filePath) async {
    await _loadFontFromFile(filePath, persist: true);
  }

  Future<void> _loadFontFromFile(
    String filePath, {
    required bool persist,
  }) async {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) return;

    final file = File(trimmed);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('Selected font file is empty');
    }

    final family = 'user_font_${DateTime.now().microsecondsSinceEpoch}';
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();

    state = state.copyWith(
      fontFamily: () => family,
      customFontFilePath: () => trimmed,
      customFontDisplayName: () => _fileNameFromPath(trimmed),
    );
    if (persist) {
      _persistState();
    }
  }

  void clearCustomFont() {
    state = state.copyWith(
      fontFamily: () => null,
      customFontFilePath: () => null,
      customFontDisplayName: () => null,
    );
    _persistState();
  }

  String _fileNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (parts.isEmpty) return path;
    final name = parts.last.trim();
    return name.isEmpty ? path : name;
  }

  void setLetterSpacing(double letterSpacing) {
    state = state.copyWith(letterSpacing: letterSpacing.clamp(0.0, 4.0));
    _persistState();
  }

  void setParagraphSpacing(double paragraphSpacing) {
    state = state.copyWith(paragraphSpacing: paragraphSpacing.clamp(4.0, 32.0));
    _persistState();
  }

  void setLineHeight(double lineHeight) {
    state = state.copyWith(lineHeight: lineHeight.clamp(1.2, 2.4));
    _persistState();
  }

  void setThemeMode(ReaderThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _persistState();
  }

  void setChineseConversion(ChineseConversionMode mode) {
    state = state.copyWith(chineseConversion: mode);
    _persistState();
    // Fire-and-forget: notify Rust backend so subsequent streams use this mode.
    rust_conversion.setChineseConversionMode(mode: mode);
  }

  Future<void> _restoreFromStorage() async {
    final prefs = await SharedPreferences.getInstance();

    final fontScale = (prefs.getDouble(_kFontScale) ?? state.fontScale).clamp(
      0.8,
      1.8,
    );
    final letterSpacing =
        (prefs.getDouble(_kLetterSpacing) ?? state.letterSpacing).clamp(
          0.0,
          4.0,
        );
    final paragraphSpacing =
        (prefs.getDouble(_kParagraphSpacing) ?? state.paragraphSpacing).clamp(
          4.0,
          32.0,
        );
    final lineHeight = (prefs.getDouble(_kLineHeight) ?? state.lineHeight)
        .clamp(1.2, 2.4);

    final themeIndex = prefs.getInt(_kThemeMode);
    final conversionIndex = prefs.getInt(_kChineseConversion);

    final restoredThemeMode =
        themeIndex != null &&
            themeIndex >= 0 &&
            themeIndex < ReaderThemeMode.values.length
        ? ReaderThemeMode.values[themeIndex]
        : state.themeMode;

    final restoredConversion =
        conversionIndex != null &&
            conversionIndex >= 0 &&
            conversionIndex < ChineseConversionMode.values.length
        ? ChineseConversionMode.values[conversionIndex]
        : state.chineseConversion;

    final storedFilePath = prefs.getString(_kCustomFontFilePath);
    final storedDisplayName = prefs.getString(_kCustomFontDisplayName);
    final storedFontFamily = prefs.getString(_kFontFamily);

    state = state.copyWith(
      fontScale: fontScale,
      letterSpacing: letterSpacing,
      paragraphSpacing: paragraphSpacing,
      lineHeight: lineHeight,
      themeMode: restoredThemeMode,
      chineseConversion: restoredConversion,
      fontFamily: () => storedFontFamily,
      customFontFilePath: () => storedFilePath,
      customFontDisplayName: () => storedDisplayName,
    );

    rust_conversion.setChineseConversionMode(mode: restoredConversion);

    if (storedFilePath != null && storedFilePath.isNotEmpty) {
      try {
        await _loadFontFromFile(storedFilePath, persist: false);
      } catch (_) {
        state = state.copyWith(
          fontFamily: () => null,
          customFontFilePath: () => null,
          customFontDisplayName: () => null,
        );
        _persistState();
      }
    }
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontScale, state.fontScale);

    final family = state.fontFamily;
    if (family == null || family.isEmpty) {
      await prefs.remove(_kFontFamily);
    } else {
      await prefs.setString(_kFontFamily, family);
    }

    final customPath = state.customFontFilePath;
    if (customPath == null || customPath.isEmpty) {
      await prefs.remove(_kCustomFontFilePath);
    } else {
      await prefs.setString(_kCustomFontFilePath, customPath);
    }

    final displayName = state.customFontDisplayName;
    if (displayName == null || displayName.isEmpty) {
      await prefs.remove(_kCustomFontDisplayName);
    } else {
      await prefs.setString(_kCustomFontDisplayName, displayName);
    }

    await prefs.setDouble(_kLetterSpacing, state.letterSpacing);
    await prefs.setDouble(_kParagraphSpacing, state.paragraphSpacing);
    await prefs.setDouble(_kLineHeight, state.lineHeight);
    await prefs.setInt(_kThemeMode, state.themeMode.index);
    await prefs.setInt(_kChineseConversion, state.chineseConversion.index);
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
