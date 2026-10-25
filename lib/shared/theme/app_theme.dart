import 'package:flutter/material.dart';

import 'fade_slide_page_transitions_builder.dart';

/// Langhuan design tokens and theme configuration.
///
/// Inspired by the Wise Design System — clean, flat, borderless, with generous
/// white space and a nature-inspired green accent palette.
///
/// See `docs/ui-design-spec.md` for the full specification.
abstract final class LanghuanTheme {
  // ─── Core brand colours ──────────────────────────────────────────────

  static const Color forestGreen = Color(0xFF163300);
  static const Color brightGreen = Color(0xFF9FE870);

  // ─── Spacing scale (8px grid) ────────────────────────────────────────

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMdSm = 12;
  static const double spaceMd = 16;
  static const double spaceLg = 24;
  static const double spaceXl = 32;
  static const double space2xl = 48;

  // ─── Radius scale ────────────────────────────────────────────────────

  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 24;
  static const double radiusXl = 32;

  static const BorderRadius borderRadiusSm = BorderRadius.all(
    Radius.circular(radiusSm),
  );
  static const BorderRadius borderRadiusMd = BorderRadius.all(
    Radius.circular(radiusMd),
  );
  static const BorderRadius borderRadiusLg = BorderRadius.all(
    Radius.circular(radiusLg),
  );
  static const BorderRadius borderRadiusXl = BorderRadius.all(
    Radius.circular(radiusXl),
  );

  // ─── Light colour scheme ─────────────────────────────────────────────

  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    // Primary
    primary: forestGreen,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: brightGreen,
    onPrimaryContainer: forestGreen,
    // Secondary (neutral green-tinted)
    secondary: Color(0xFF4E6440),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFD0E8BF),
    onSecondaryContainer: Color(0xFF0C1F03),
    // Tertiary (warm accent)
    tertiary: Color(0xFF3A6652),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFBCECD2),
    onTertiaryContainer: Color(0xFF002113),
    // Error / sentiment
    error: Color(0xFFA8200D),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD4),
    onErrorContainer: Color(0xFF410001),
    // Surfaces
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF0E0F0C),
    onSurfaceVariant: Color(0xFF454745),
    // Surface containers (Wise-style neutral backgrounds)
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F9F2),
    surfaceContainer: Color(0xFFF2F4EF),
    surfaceContainerHigh: Color(0xFFECEEE8),
    surfaceContainerHighest: Color(0xFFE6E8E2),
    // Outline
    outline: Color(0x1F0E0F0C), // 12% opacity — Wise border.neutral
    outlineVariant: Color(0x140E0F0C), // 8% opacity
    // Misc
    inverseSurface: Color(0xFF2E312B),
    onInverseSurface: Color(0xFFF0F1EB),
    inversePrimary: brightGreen,
    shadow: Colors.transparent,
    scrim: Color(0xFF000000),
    surfaceTint: Colors.transparent,
  );

  // ─── Dark colour scheme ──────────────────────────────────────────────

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    // Primary
    primary: brightGreen,
    onPrimary: forestGreen,
    primaryContainer: Color(0xFF1E4D00),
    onPrimaryContainer: brightGreen,
    // Secondary
    secondary: Color(0xFFB5CCA5),
    onSecondary: Color(0xFF213517),
    secondaryContainer: Color(0xFF374B2B),
    onSecondaryContainer: Color(0xFFD0E8BF),
    // Tertiary
    tertiary: Color(0xFFA1D0B7),
    onTertiary: Color(0xFF073726),
    tertiaryContainer: Color(0xFF224E3B),
    onTertiaryContainer: Color(0xFFBCECD2),
    // Error
    error: Color(0xFFFF6B5A),
    onError: Color(0xFF690003),
    errorContainer: Color(0xFF930006),
    onErrorContainer: Color(0xFFFFDAD4),
    // Surfaces
    surface: Color(0xFF121511),
    onSurface: Color(0xFFE8EAE5),
    onSurfaceVariant: Color(0xFFB0B2AD),
    // Surface containers
    surfaceContainerLowest: Color(0xFF0D100C),
    surfaceContainerLow: Color(0xFF1A1D18),
    surfaceContainer: Color(0xFF1E211B),
    surfaceContainerHigh: Color(0xFF282B25),
    surfaceContainerHighest: Color(0xFF33362F),
    // Outline
    outline: Color(0x1FE8EAE5),
    outlineVariant: Color(0x14E8EAE5),
    // Misc
    inverseSurface: Color(0xFFE8EAE5),
    onInverseSurface: Color(0xFF2E312B),
    inversePrimary: forestGreen,
    shadow: Colors.transparent,
    scrim: Color(0xFF000000),
    surfaceTint: Colors.transparent,
  );

  // ─── Text theme ──────────────────────────────────────────────────────

  static const TextTheme textTheme = TextTheme(
    // Title Screen → headlineLarge
    headlineLarge: TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w600,
      height: 34 / 30,
      letterSpacing: -0.75, // -2.5%
    ),
    // Title Section → headlineMedium
    headlineMedium: TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w600,
      height: 32 / 26,
      letterSpacing: -0.39, // -1.5%
    ),
    // Title Subsection → headlineSmall
    headlineSmall: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      height: 28 / 22,
      letterSpacing: -0.33, // -1.5%
    ),
    // Title Body → titleLarge
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      height: 24 / 18,
      letterSpacing: -0.18, // -1%
    ),
    // Body Large → bodyLarge
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 24 / 16,
      letterSpacing: -0.08, // -0.5%
    ),
    // Body Default → bodyMedium
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 22 / 14,
      letterSpacing: 0.14, // +1%
    ),
    // Body Bold → titleMedium
    titleMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 22 / 14,
      letterSpacing: 0.175, // +1.25%
    ),
    // Label → labelMedium
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 16 / 12,
      letterSpacing: 0.06, // 0.5%
    ),
    // Small label
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 16 / 11,
      letterSpacing: 0.5,
    ),
  );

  // ─── Component themes ────────────────────────────────────────────────

  static ThemeData light() => _buildTheme(lightScheme);
  static ThemeData dark() => _buildTheme(darkScheme);

  static ThemeData _buildTheme(ColorScheme scheme) {
    final isLight = scheme.brightness == Brightness.light;
    final neutralBg = isLight
        ? const Color(0xFFF2F4EF)
        : const Color(0xFF1E211B);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,

      // ── Page transitions ──────────────────────────────────────────
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeSlidePageTransitionsBuilder(),
          TargetPlatform.iOS: FadeSlidePageTransitionsBuilder(),
          TargetPlatform.linux: FadeSlidePageTransitionsBuilder(),
          TargetPlatform.macOS: FadeSlidePageTransitionsBuilder(),
          TargetPlatform.windows: FadeSlidePageTransitionsBuilder(),
        },
      ),

      // ── AppBar ─────────────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
      ),

      // ── Navigation Bar ─────────────────────────────────────────────
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: neutralBg,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: scheme.primary, size: 24);
          }
          return IconThemeData(color: scheme.onSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final base = textTheme.labelMedium?.copyWith(letterSpacing: 0);
          if (states.contains(WidgetState.selected)) {
            return base?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            );
          }
          return base?.copyWith(color: scheme.onSurfaceVariant);
        }),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
      ),

      // ── Search Bar ─────────────────────────────────────────────────
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(neutralBg),
        overlayColor: WidgetStatePropertyAll(scheme.primary.withAlpha(20)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: borderRadiusMd),
        ),
        hintStyle: WidgetStatePropertyAll(
          textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        textStyle: WidgetStatePropertyAll(
          textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
        ),
        constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: spaceMd),
        ),
      ),

      // ── Card ───────────────────────────────────────────────────────
      cardTheme: CardThemeData(
        elevation: 0,
        color: neutralBg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: borderRadiusMd),
        margin: EdgeInsets.zero,
      ),

      // ── Filled Button (Primary — pill-shaped) ─────────────────────
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.primaryContainer),
          foregroundColor: WidgetStatePropertyAll(
            isLight ? forestGreen : const Color(0xFF121511),
          ),
          elevation: const WidgetStatePropertyAll(0),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          textStyle: WidgetStatePropertyAll(
            textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),

      // ── Tonal Button (Secondary) ───────────────────────────────────
      // FilledButton.tonal uses this
      // We keep the default M3 tonal mapping which uses secondaryContainer.

      // ── Text Button (Tertiary — pill-shaped) ──────────────────────
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(scheme.primary),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          textStyle: WidgetStatePropertyAll(
            textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),

      // ── Outlined Button (pill-shaped) ──────────────────────────────
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
        ),
      ),

      // ── FAB (circular) ─────────────────────────────────────────────
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: isLight ? forestGreen : const Color(0xFF121511),
        shape: const CircleBorder(),
      ),

      // ── Chip ───────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        elevation: 0,
        pressElevation: 0,
        backgroundColor: neutralBg,
        selectedColor: scheme.primary,
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onPrimary,
        ),
        shape: RoundedRectangleBorder(borderRadius: borderRadiusSm),
        side: BorderSide.none,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),

      // ── Dialog ─────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: borderRadiusLg),
      ),

      // ── Bottom Sheet ───────────────────────────────────────────────
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
        dragHandleColor: scheme.onSurfaceVariant.withAlpha(80),
        dragHandleSize: const Size(32, 4),
        showDragHandle: true,
      ),

      // ── Snackbar ───────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        elevation: 0,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: brightGreen,
        shape: RoundedRectangleBorder(borderRadius: borderRadiusMd),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: spaceMd,
          vertical: spaceMd,
        ),
      ),

      // ── Divider ────────────────────────────────────────────────────
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 0,
      ),

      // ── ListTile ───────────────────────────────────────────────────
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spaceMd,
          vertical: spaceXs,
        ),
        shape: RoundedRectangleBorder(borderRadius: borderRadiusMd),
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      // ── Input Decoration ───────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: neutralBg,
        border: OutlineInputBorder(
          borderRadius: borderRadiusMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: borderRadiusMd,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: borderRadiusMd,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: borderRadiusMd,
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spaceMd,
          vertical: 14,
        ),
        hintStyle: textTheme.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      // ── Progress Indicator ─────────────────────────────────────────
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: neutralBg,
        linearMinHeight: 2,
      ),
    );
  }
}
