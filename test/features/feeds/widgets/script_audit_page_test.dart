import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/widgets/feed_preview_content.dart';
import 'package:langhuan/features/feeds/widgets/feed_security_warning.dart';
import 'package:langhuan/features/feeds/widgets/script_audit_page.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/theme/app_theme.dart';
import 'package:langhuan/src/rust/api/types.dart' show VersionChange;

void main() {
  Widget app(Widget child, {ThemeData? theme}) => MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Theme(
      data: theme ?? LanghuanTheme.light(),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  const preview = FeedPreviewModel(
    requestId: 'org.example.feed',
    id: 'org.example.feed',
    name: 'Example',
    version: '1.0.0',
    baseUrl: 'https://example.com',
    accessDomains: ['example.com'],
    versionChange: VersionChange.new_,
    script: '// ==Feed==\n// @id org.example.feed\n',
  );

  testWidgets('the security warning renders caution yellow', (tester) async {
    for (final entry in [
      (LanghuanTheme.light(), LanghuanTheme.warningContainerLight),
      (LanghuanTheme.dark(), LanghuanTheme.warningContainerDark),
    ]) {
      await tester.pumpWidget(
        app(const FeedSecurityWarning(), theme: entry.$1),
      );
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(FeedSecurityWarning),
          matching: find.byType(Container),
        ),
      );
      expect((container.decoration as BoxDecoration).color, entry.$2);
    }
  });

  testWidgets('the preview offers an audit entry that opens the viewer', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => FeedPreviewContent(
            preview: preview,
            colorScheme: Theme.of(context).colorScheme,
            l10n: AppLocalizations.of(context),
          ),
        ),
      ),
    );

    // The button labels its payload: 36 UTF-8 bytes of script.
    await tester.tap(find.text('View script (36 B)'));
    await tester.pumpAndSettle();

    expect(find.byType(ScriptAuditPage), findsOneWidget);
    expect(find.text('Script audit'), findsOneWidget);
    expect(find.text('Example v1.0.0'), findsOneWidget);
    expect(find.text('36 B · 3 lines'), findsOneWidget);
  });

  testWidgets('search counts and highlights matches live', (tester) async {
    const script = 'foo bar foo baz';
    await tester.pumpWidget(
      app(const ScriptAuditPage(script: script, name: 'F', version: '2.0')),
    );
    await tester.enterText(find.byType(TextField), 'foo');
    await tester.pump();

    expect(find.text('2 matches'), findsOneWidget);
    // Matches carry the highlight background inside the script's span tree.
    // `Text.rich` nests the passed span under its own style wrapper, so the
    // tree has to be walked to collect the highlighted leaves.
    final scriptRichText = find
        .byType(RichText)
        .evaluate()
        .map((e) => e.widget as RichText)
        .firstWhere((t) => t.text.toPlainText() == script);
    final root = scriptRichText.text as TextSpan;
    int highlightedSpans(InlineSpan span) {
      var count = span.style?.backgroundColor != null ? 1 : 0;
      if (span is TextSpan) {
        for (final child in span.children ?? const <InlineSpan>[]) {
          count += highlightedSpans(child);
        }
      }
      return count;
    }

    expect(highlightedSpans(root), 2);
    expect(root.toPlainText(), script);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('the format toggle reindents the script and labels it', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const ScriptAuditPage(
          script: 'function f(){return 1;}',
          name: 'F',
          version: '2',
        ),
      ),
    );

    await tester.tap(find.byTooltip('Toggle formatted view'));
    await tester.pump();

    // The derived view is labeled as such…
    expect(
      find.text('Formatted for reading — the installed script stays untouched'),
      findsOneWidget,
    );
    // …and the body is the reindented reading form.
    final displayed = find
        .byType(RichText)
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .firstWhere((t) => t.contains('return 1;'));
    expect(displayed, 'function f() {\n  return 1;\n}');
    // Stats still describe the install payload, not the derived view.
    expect(find.text('23 B · 1 lines'), findsOneWidget);

    // Toggling back restores the untouched original.
    await tester.tap(find.byTooltip('Toggle formatted view'));
    await tester.pump();
    expect(
      find.text('Formatted for reading — the installed script stays untouched'),
      findsNothing,
    );
    final raw = find
        .byType(RichText)
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .firstWhere((t) => t.contains('return 1;'));
    expect(raw, 'function f(){return 1;}');
  });

  testWidgets('copy reports success and wrap toggles', (tester) async {
    await tester.pumpWidget(
      app(const ScriptAuditPage(script: 'let a = 1;', name: 'F', version: '2')),
    );

    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(find.text('Script copied'), findsOneWidget);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Toggle line wrapping'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
