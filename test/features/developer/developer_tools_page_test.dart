import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:langhuan/features/developer/developer_tools_page.dart';
import 'package:langhuan/l10n/app_localizations.dart';

void main() {
  testWidgets('desktop uses source, operation, and inspector panes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeveloperToolsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('developer-desktop-workbench')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('developer-source-pane')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('developer-operation-pane')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('developer-inspector-pane')),
      findsOneWidget,
    );
    expect(find.text('Operations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('advanced mode exposes operation input and cursor JSON', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeveloperToolsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final advanced = find.text('Advanced single page');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();

    expect(find.text('Operation'), findsOneWidget);
    expect(find.text('Input JSON'), findsOneWidget);
    expect(find.text('Cursor JSON'), findsOneWidget);
    expect(
      find.text('Passed to event.cursor; use null for the first page'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
