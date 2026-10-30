import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/webview_verify_coordinator.dart';
import 'package:langhuan/rust_init.dart';

import 'l10n/app_localizations.dart';
import 'router/app_router.dart';
import 'shared/theme/app_theme.dart';
import 'shared/utils/snackbars.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class LanghuanApp extends ConsumerStatefulWidget {
  const LanghuanApp({super.key});

  @override
  ConsumerState<LanghuanApp> createState() => _LanghuanAppState();
}

class _LanghuanAppState extends ConsumerState<LanghuanApp> {
  String? _activeGlobalSnackMessage;

  void _showGlobalErrorSnack(String message) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    if (_activeGlobalSnackMessage == message) return;

    _activeGlobalSnackMessage = message;
    showErrorSnack(
      messenger,
      message,
      duration: const Duration(seconds: 8),
    ).closed.then((_) {
      if (!mounted) return;
      if (_activeGlobalSnackMessage == message) {
        _activeGlobalSnackMessage = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appDataDirectorySetProvider);
    ref.watch(feedListProvider);
    // Presents feed verification prompts as they arrive; the underlying
    // stream stays open for the lifetime of the app.
    ref.watch(webviewVerifyCoordinatorProvider);

    ref.listen(appDataDirectorySetProvider, (previous, next) {
      next.when(
        data: (_) {},
        loading: () {},
        error: (error, stack) {
          debugPrint('Feed bootstrap exception: $error');
          final snackContext = scaffoldMessengerKey.currentContext;
          final fallback = snackContext == null
              ? 'Failed to load feeds'
              : AppLocalizations.of(snackContext).feedsLoadError;
          _showGlobalErrorSnack(fallback);
        },
      );
    });

    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      // i18n
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: LanghuanTheme.light(),
      darkTheme: LanghuanTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: router,
      // The app runs edge-to-edge (see main()), so the system bars are
      // transparent and the scaffold shows through them — only the icon
      // contrast is left to set, and it must follow the effective theme.
      // The reader annotates on top of this while it is shown; this value
      // re-applies when its route pops.
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: child!,
        );
      },
    );
  }
}
