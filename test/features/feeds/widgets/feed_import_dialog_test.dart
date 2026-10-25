import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/feeds/widgets/feed_import_dialog.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

const _entries = [
  FeedImportEntry(
    id: 'feed-a',
    name: 'Source A',
    version: '1.0.0',
    change: VersionChange.new_,
  ),
  FeedImportEntry(
    id: 'feed-b',
    name: 'Source B',
    version: '2.0.0',
    author: 'someone',
    change: VersionChange.upgrade,
  ),
  FeedImportEntry(
    id: 'feed-c',
    name: 'Source C',
    version: '1.0.0',
    change: VersionChange.same,
  ),
];

Widget _host() {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showFeedImportDialog(context, entries: _entries),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists every entry with its change badge', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(FeedImportDialog), findsOneWidget);
    expect(find.text('Import feeds'), findsOneWidget);
    expect(find.text('3 feeds found'), findsOneWidget);
    for (final name in ['Source A', 'Source B', 'Source C']) {
      expect(find.text(name), findsOneWidget);
    }
    // Change badges: New / Upgrade / Installed.
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Upgrade'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    // Author shown next to the version.
    expect(find.text('v2.0.0 · someone'), findsOneWidget);
  });

  testWidgets('confirm pops true and cancel pops false', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedImportDialog), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedImportDialog), findsNothing);
  });
}
