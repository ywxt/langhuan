import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/transformers/transformer_rule_card.dart';
import 'package:langhuan/features/transformers/transformer_rule_editor_sheet.dart';
import 'package:langhuan/features/transformers/transformer_settings.dart';
import 'package:langhuan/features/transformers/transformer_settings_page.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/constants.dart';
import 'package:langhuan/shared/widgets/swipe_action_card.dart';

class _Settings extends TransformerSettingsNotifier {
  _Settings(this.initial);
  final TransformerSettings initial;
  List<TransformerEntry>? saved;
  String? savedFeed;
  bool failNext = false;
  @override
  Future<TransformerSettings> build() async => initial;
  @override
  Future<void> save({
    required List<TransformerEntry> rules,
    String? feedId,
    String? bookId,
    bool inheritApplication = true,
  }) async {
    if (failNext) {
      failNext = false;
      throw StateError('Save failed');
    }
    saved = List.of(rules);
    savedFeed = feedId;
    final current = state.requireValue;
    state = AsyncData(
      feedId == null
          ? TransformerSettings(application: rules, books: current.books)
          : TransformerSettings(
              application: current.application,
              books: {
                ...current.books,
                TransformerSettings.bookKey(feedId, bookId!): BookTransformers(
                  rules: rules,
                  inheritApplication: inheritApplication,
                ),
              },
            ),
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Settings settings, {
  bool book = false,
  double textScale = 1,
  TargetPlatform? platform,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [transformerSettingsProvider.overrideWith(() => settings)],
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TransformerSettingsPage(
          feedId: book ? 'feed' : null,
          bookId: book ? 'book' : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _card(TransformerKind kind) => find.byWidgetPredicate(
  (widget) => widget is TransformerRuleCard && widget.rule.kind == kind,
);

Future<void> _reorderLastBeforeFirst(WidgetTester tester) async {
  final handles = find.byType(ReorderableDragStartListener);
  final start = tester.getCenter(handles.last);
  final target = tester.getCenter(handles.first);
  final gesture = await tester.startGesture(start);
  for (var step = 1; step <= 8; step++) {
    await gesture.moveTo(Offset.lerp(start, target, step / 8)!);
    await tester.pump(const Duration(milliseconds: 32));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _swipeRule(WidgetTester tester, TransformerKind kind) async {
  await tester.drag(
    find.ancestor(of: _card(kind), matching: find.byType(Dismissible)),
    const Offset(-600, 0),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('swipe delete confirms, supports undo, and preserves ordering', (
    tester,
  ) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(
            kind: TransformerKind.paragraphIndent,
            name: 'Indent',
          ),
          TransformerEntry(
            kind: TransformerKind.regexDelete,
            pattern: 'advertisement',
          ),
        ],
      ),
    );
    await _open(tester, settings);
    expect(find.byType(SwipeActionCard), findsNWidgets(2));
    await _swipeRule(tester, TransformerKind.paragraphIndent);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(settings.saved, isNull);
    expect(_card(TransformerKind.paragraphIndent), findsOneWidget);
    await _swipeRule(tester, TransformerKind.paragraphIndent);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(_card(TransformerKind.paragraphIndent), findsNothing);
    expect(settings.saved, isNull);
    expect(
      tester
          .widget<ReorderableDragStartListener>(
            find.byType(ReorderableDragStartListener),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(settings.saved, isNull);
    expect(_card(TransformerKind.paragraphIndent), findsOneWidget);
    await _reorderLastBeforeFirst(tester);
    expect(settings.saved!.map((r) => r.kind), [
      TransformerKind.regexDelete,
      TransformerKind.paragraphIndent,
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final inherited in [false, true]) {
    testWidgets(
      'swipe delete saves the correct book/application scope, inherited=$inherited',
      (tester) async {
        final settings = _Settings(
          TransformerSettings(
            application: const [
              TransformerEntry(kind: TransformerKind.paragraphIndent),
            ],
            books: {
              TransformerSettings.bookKey('feed', 'book'): BookTransformers(
                rules: const [
                  TransformerEntry(
                    kind: TransformerKind.regexDelete,
                    pattern: 'ad',
                  ),
                ],
              ),
            },
          ),
        );
        await _open(tester, settings, book: true);
        final kind = inherited
            ? TransformerKind.paragraphIndent
            : TransformerKind.regexDelete;
        await _swipeRule(tester, kind);
        if (inherited) {
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(
                'This is an application rule. Changes affect every book that inherits it.',
              ),
            ),
            findsOneWidget,
          );
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(settings.saved, isNull);
        await tester.pump(AppConstants.undoDuration);
        await tester.pumpAndSettle();
        expect(settings.saved, isEmpty);
        expect(settings.savedFeed, inherited ? isNull : 'feed');
        expect(_card(kind), findsNothing);
        expect(
          _card(
            inherited
                ? TransformerKind.regexDelete
                : TransformerKind.paragraphIndent,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a failed swipe deletion restores the rule and reports the error',
    (tester) async {
      final settings = _Settings(
        TransformerSettings(
          application: const [
            TransformerEntry(kind: TransformerKind.paragraphIndent),
          ],
        ),
      )..failNext = true;
      await _open(tester, settings);
      await _swipeRule(tester, TransformerKind.paragraphIndent);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.pump(AppConstants.undoDuration);
      await tester.pumpAndSettle();
      expect(settings.saved, isNull);
      expect(_card(TransformerKind.paragraphIndent), findsOneWidget);
      expect(find.textContaining('Save failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop delete button uses the same confirmation and undo', (
    tester,
  ) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(kind: TransformerKind.paragraphIndent),
        ],
      ),
    );
    await _open(tester, settings, platform: TargetPlatform.linux);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(settings.saved, isNull);
    expect(_card(TransformerKind.paragraphIndent), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'list is read-only and opens a keyboard-safe configuration sheet',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = _Settings(
        TransformerSettings(
          application: [
            for (final kind in TransformerKind.values)
              TransformerEntry(
                kind: kind,
                pattern: 'advertisement',
                replacement: 'text',
              ),
          ],
        ),
      );
      await _open(tester, settings, textScale: 1.3);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(Switch), findsNothing);
      await tester.ensureVisible(_card(TransformerKind.paragraphIndent));
      await tester.pumpAndSettle();
      await tester.tap(_card(TransformerKind.paragraphIndent));
      await tester.pumpAndSettle();
      expect(find.byType(TransformerRuleEditorSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TransformerRuleEditorSheet),
          matching: find.text('Paragraph indentation'),
        ),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.widgetWithText(FilledButton, 'Save')).dy,
        lessThanOrEqualTo(460),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'add opens an editor, custom naming and saving persist immediately',
    (tester) async {
      final settings = _Settings(TransformerSettings());
      await _open(tester, settings);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Chapter title cleanup'), findsOneWidget);
      expect(find.text('Regex replacement'), findsOneWidget);
      await tester.tap(find.text('Paragraph indentation'));
      await tester.pumpAndSettle();
      expect(find.byType(TransformerRuleEditorSheet), findsOneWidget);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(4);
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).first, '  My indent  ');
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('transformer-editor-title')),
            )
            .data,
        'My indent',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('transformer-editor-type')))
            .data,
        'Paragraph indentation',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings.saved!.single.indentSpaces, 4);
      expect(settings.saved!.single.name, 'My indent');
      expect(find.byType(TransformerRuleEditorSheet), findsNothing);
      expect(find.text('My indent'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(Slider), findsNothing);
      await tester.tap(find.text('My indent'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'My indent'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('transformer-editor-title')),
            )
            .data,
        'My indent',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('transformer-editor-type')))
            .data,
        'Paragraph indentation',
      );
      await tester.enterText(find.byType(TextFormField).first, '   ');
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('transformer-editor-title')),
            )
            .data,
        'Paragraph indentation',
      );
      expect(
        find.byKey(const ValueKey('transformer-editor-type')),
        findsNothing,
      );
      expect(find.text('First-line indent: 4 characters'), findsOneWidget);
    },
  );

  testWidgets('leaving an add or edit page discards unsaved changes', (
    tester,
  ) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(
            kind: TransformerKind.paragraphIndent,
            name: 'Original',
          ),
        ],
      ),
    );
    await _open(tester, settings);
    await tester.tap(find.text('Original'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Discard');
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsOneWidget);
    expect(settings.saved, isNull);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regex replacement'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(TransformerRuleCard), findsOneWidget);
    expect(settings.saved, isNull);
  });

  testWidgets(
    'editing inherited rules explicitly updates the application scope',
    (tester) async {
      final settings = _Settings(
        TransformerSettings(
          application: const [
            TransformerEntry(
              kind: TransformerKind.paragraphIndent,
              indentSpaces: 3,
            ),
          ],
        ),
      );
      await _open(tester, settings, book: true);
      expect(find.text('Application rules'), findsOneWidget);
      expect(find.text('First-line indent: 3 characters'), findsOneWidget);
      await tester.tap(_card(TransformerKind.paragraphIndent));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(TransformerRuleEditorSheet),
          matching: find.text(
            'This is an application rule. Changes affect every book that inherits it.',
          ),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextFormField).first, 'Global indent');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings.savedFeed, isNull);
      expect(find.text('Global indent'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.savedFeed, 'feed');
      expect(find.byType(TransformerRuleCard), findsNothing);
    },
  );

  testWidgets(
    'list drag reorders persist without opening the editor or changing configurations',
    (tester) async {
      final settings = _Settings(
        TransformerSettings(
          application: const [
            TransformerEntry(
              kind: TransformerKind.regexReplace,
              pattern: 'first',
              replacement: 'before',
            ),
            TransformerEntry(
              kind: TransformerKind.regexDelete,
              pattern: 'second',
            ),
          ],
        ),
      );
      await _open(tester, settings);
      expect(find.byType(PopupMenuButton<TransformerEditAction>), findsNothing);
      await tester.tap(_card(TransformerKind.regexReplace));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'before'),
        'after',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await _reorderLastBeforeFirst(tester);
      expect(find.byType(TransformerRuleEditorSheet), findsNothing);
      final cards = tester
          .widgetList<TransformerRuleCard>(find.byType(TransformerRuleCard))
          .map((c) => c.rule)
          .toList();
      expect(cards.map((c) => c.pattern), ['second', 'first']);
      expect(settings.saved!.last.replacement, 'after');
      await tester.tap(_card(TransformerKind.regexDelete));
      await tester.pumpAndSettle();
      expect(find.text('Move up'), findsNothing);
      expect(find.text('Move down'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    },
  );

  testWidgets('failed reorders retain the saved order and allow retry', (
    tester,
  ) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(kind: TransformerKind.paragraphIndent),
          TransformerEntry(kind: TransformerKind.deduplicateTitles),
        ],
      ),
    )..failNext = true;
    await _open(tester, settings);
    await _reorderLastBeforeFirst(tester);
    expect(find.textContaining('Save failed'), findsOneWidget);
    expect(settings.saved, isNull);
    expect(
      tester
          .widgetList<TransformerRuleCard>(find.byType(TransformerRuleCard))
          .first
          .rule
          .kind,
      TransformerKind.paragraphIndent,
    );
    await _reorderLastBeforeFirst(tester);
    expect(settings.saved!.first.kind, TransformerKind.deduplicateTitles);
    expect(find.textContaining('Save failed'), findsNothing);
  });

  testWidgets('failed saves keep the editor open and can be retried', (
    tester,
  ) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(kind: TransformerKind.paragraphIndent),
        ],
      ),
    )..failNext = true;
    await _open(tester, settings);
    await tester.tap(_card(TransformerKind.paragraphIndent));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Retried');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Save failed'), findsOneWidget);
    expect(find.byType(TransformerRuleEditorSheet), findsOneWidget);
    expect(settings.saved, isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(TransformerRuleEditorSheet), findsNothing);
    expect(settings.saved!.single.name, 'Retried');
  });

  testWidgets('editor deletion requires confirmation', (tester) async {
    final settings = _Settings(
      TransformerSettings(
        application: const [
          TransformerEntry(kind: TransformerKind.paragraphIndent),
        ],
      ),
    );
    await _open(tester, settings);
    await tester.tap(_card(TransformerKind.paragraphIndent));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(settings.saved, isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(settings.saved, isEmpty);
    expect(find.byType(TransformerRuleCard), findsNothing);
  });
}
