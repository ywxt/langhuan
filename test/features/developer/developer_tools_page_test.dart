import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:langhuan/features/developer/developer_tools_page.dart';
import 'package:langhuan/l10n/app_localizations.dart';

/// Records the environment calls the page makes.
class _RecordingEnvironment {
  final List<String> loads = [];
  int closes = 0;

  Future<void> load({required String script}) async => loads.add(script);
  Future<void> close() async => closes++;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _RecordingEnvironment environment,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: DeveloperToolsPage(
          loadEnvironment: environment.load,
          closeEnvironment: environment.close,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('desktop uses source, operation, and inspector panes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final environment = _RecordingEnvironment();
    await _pumpPage(tester, environment: environment);
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

    final environment = _RecordingEnvironment();
    await _pumpPage(tester, environment: environment);
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

  testWidgets('comments stage exposes the thread target inputs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final environment = _RecordingEnvironment();
    await _pumpPage(tester, environment: environment);
    await tester.pumpAndSettle();

    final comments = find.text('Comments');
    await tester.ensureVisible(comments);
    await tester.tap(comments);
    await tester.pumpAndSettle();

    // The required thread target plus the two optional selectors: a
    // paragraph id routes to comments.paragraph, a parent id reads replies.
    expect(find.text('Book ID'), findsOneWidget);
    expect(find.text('Chapter ID'), findsOneWidget);
    expect(find.text('Paragraph ID (optional)'), findsOneWidget);
    expect(find.text('Parent comment ID (optional)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the environment opens with the restored script and closes with the page',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'developer.script': '// persisted work in progress',
      });
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final environment = _RecordingEnvironment();
      await _pumpPage(tester, environment: environment);
      await tester.pumpAndSettle();

      // Opening the page loads the restored editor contents directly.
      expect(environment.loads, ['// persisted work in progress']);
      expect(environment.closes, 0);

      // Leaving the page drops the environment.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(environment.closes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the load button compiles the editor into the environment', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final environment = _RecordingEnvironment();
    await _pumpPage(tester, environment: environment);
    await tester.pumpAndSettle();

    // Nothing restored: the environment stays empty until an explicit load.
    expect(environment.loads, isEmpty);

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands == true,
      ),
      '// fresh script',
    );
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();

    expect(environment.loads, ['// fresh script']);
    // The user gets feedback that runs will use this version.
    expect(find.text('Script loaded — runs use this version'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
