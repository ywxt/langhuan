import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/widgets/add_feed_dialog.dart';
import 'package:langhuan/features/feeds/widgets/feed_preview_content.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

import '../fake_feed_service.dart';

/// The exact error the bridge returns when the URL import downloads a
/// non-script (e.g. a plain web page): classified ScriptConfig, parsed
/// and localized on the Rust side.
const _parseError = BridgeError(
  kind: ErrorKind_ScriptConfig(),
  message: 'Script parse error at line 1: missing ==Feed== header',
);

Widget _host(FakeFeedService service, {String? initialPath}) => ProviderScope(
  overrides: [feedServiceProvider.overrideWithValue(service)],
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AddFeedDialog(initialPath: initialPath),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

/// Pumps past the dialog's [AnimatedSwitcher] transition. Bounded on
/// purpose: [LoadingContent] spins forever, so [WidgetTester.pumpAndSettle]
/// would time out while a stuck loading state is on screen.
Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 220));

void main() {
  testWidgets('a URL preview failure shows the error instead of hanging', (
    tester,
  ) async {
    final service = FakeFeedService(
      previewFromUrlHandler: (url) async {
        throw _parseError;
      },
    );

    await tester.pumpWidget(_host(service));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();
    await _settle(tester);

    // The failure is presented, never thrown past the notifier. Before the
    // fix the BridgeError escaped unhandled, the dialog stayed on its
    // loading spinner — and that state even blocks dismissing it.
    expect(tester.takeException(), isNull);
    expect(find.byType(LoadingContent), findsNothing);
    // The classified title-plus-detail form every error surface uses:
    // ScriptConfig leads with its category, the parse message follows.
    expect(find.text('Script configuration error'), findsOneWidget);
    expect(find.text(_parseError.message), findsOneWidget);

    // The dialog stays operable: backing out returns to the URL input.
    await tester.tap(find.text('Back'));
    await tester.pump();
    await _settle(tester);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a file preview failure shows the error instead of hanging', (
    tester,
  ) async {
    final service = FakeFeedService(
      previewFromFileHandler: (path) async {
        throw _parseError;
      },
    );

    await tester.pumpWidget(_host(service, initialPath: '/tmp/broken.js'));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(LoadingContent), findsNothing);
    expect(find.text('Script configuration error'), findsOneWidget);
    expect(find.text(_parseError.message), findsOneWidget);
  });
}
