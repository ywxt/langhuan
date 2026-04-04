import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/rust_init.dart';

import 'l10n/app_localizations.dart';
import 'router/app_router.dart';
import 'shared/theme/app_theme.dart';
import 'src/bindings/signals/signals.dart';

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
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
          ),
        )
        .closed
        .then((_) {
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

    ref.listen(appDataDirectorySetProvider, (previous, next) {
      next.whenData((result) {
        final outcome = result.outcome;
        if (outcome is! AppDataDirectoryOutcomeError) return;
        debugPrint('Feed load error: ${outcome.message}');
        final snackContext = scaffoldMessengerKey.currentContext;
        final fallback = snackContext == null
            ? 'Failed to load feeds'
            : AppLocalizations.of(snackContext).feedsLoadError;
        _showGlobalErrorSnack(
          outcome.message.isNotEmpty ? outcome.message : fallback,
        );
      });
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
    );
  }
}
