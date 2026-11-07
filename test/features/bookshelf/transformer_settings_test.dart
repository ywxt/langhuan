import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/rust_init.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/transformers/transformer_settings.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements TransformerSettingsStore {
  TransformerSettings? data;
  bool failWrites = false;
  int initializations = 0;
  @override
  Future<TransformerSettings?> read() async => data;
  Future<void>? applicationGate;
  final bookGates = <String, Future<void>>{};
  final writes = <String>[];

  void _checkWrite() {
    if (failWrites) throw StateError('Database write failed');
  }

  @override
  Future<void> saveApplication(List<TransformerEntry> rules) async {
    writes.add('application');
    await applicationGate;
    _checkWrite();
    data = TransformerSettings(application: rules, books: data!.books);
  }

  @override
  Future<void> saveBook({
    required String feedId,
    required String bookId,
    required BookTransformers configuration,
  }) async {
    final key = TransformerSettings.bookKey(feedId, bookId);
    writes.add(key);
    await bookGates[key];
    _checkWrite();
    data = TransformerSettings(
      application: data!.application,
      books: {...data!.books, key: configuration},
    );
  }

  @override
  Future<void> deleteBook({
    required String feedId,
    required String bookId,
  }) async {
    _checkWrite();
    final books = Map.of(data!.books)
      ..remove(TransformerSettings.bookKey(feedId, bookId));
    data = TransformerSettings(application: data!.application, books: books);
  }

  @override
  Future<TransformerSettings> initialize(TransformerSettings? imported) async {
    if (data != null) return data!;
    _checkWrite();
    initializations++;
    data = TransformerSettings.fromStored(
      (imported ??
              TransformerSettings(
                application: const [
                  TransformerEntry(kind: TransformerKind.deduplicateTitles),
                  TransformerEntry(kind: TransformerKind.paragraphIndent),
                ],
              ))
          .toStored(),
    );
    return data!;
  }
}

void main() {
  late _Store store;
  setUp(() {
    store = _Store();
    SharedPreferences.setMockInitialValues({});
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  const conversion = TransformerEntry(
    kind: TransformerKind.chineseConversion,
    mode: ChineseConversionMode.s2T,
  );
  const replace = TransformerEntry(
    kind: TransformerKind.regexReplace,
    pattern: '(廣告)(.*)',
    replacement: r'$2',
    includeTitles: true,
  );
  const delete = TransformerEntry(
    kind: TransformerKind.regexDelete,
    pattern: '廣告',
  );

  ProviderContainer containerForStore() => ProviderContainer(
    overrides: [
      transformerSettingsRepositoryProvider.overrideWithValue(
        TransformerSettingsRepository(store: store),
      ),
      appDataDirectorySetProvider.overrideWith(
        (ref) async => const AppDataDirectoryResult(feedCount: 0),
      ),
    ],
  );

  test(
    'concurrent writes merge only their completed scope into the latest state',
    () async {
      final container = containerForStore();
      addTearDown(container.dispose);
      await container.read(transformerSettingsProvider.future);
      final notifier = container.read(transformerSettingsProvider.notifier);
      final application = Completer<void>();
      final bookA = Completer<void>();
      final bookB = Completer<void>();
      store.applicationGate = application.future;
      store.bookGates[TransformerSettings.bookKey('f', 'a')] = bookA.future;
      store.bookGates[TransformerSettings.bookKey('f', 'b')] = bookB.future;
      final appWrite = notifier.save(rules: [conversion]);
      final firstWrite = notifier.save(
        feedId: 'f',
        bookId: 'a',
        inheritApplication: false,
        rules: [replace],
      );
      final secondWrite = notifier.save(
        feedId: 'f',
        bookId: 'b',
        rules: [delete],
      );
      bookA.complete();
      await firstWrite;
      application.complete();
      await appWrite;
      expect(
        container
            .read(transformerSettingsProvider)
            .requireValue
            .book('f', 'a')
            .rules,
        [replace],
      );
      bookB.complete();
      await secondWrite;
      final saved = container.read(transformerSettingsProvider).requireValue;
      expect(saved.application, [conversion]);
      expect(saved.book('f', 'a').inheritApplication, isFalse);
      expect(saved.book('f', 'a').rules, [replace]);
      expect(saved.book('f', 'b').rules, [delete]);
      expect(saved.toJson(), store.data!.toJson());
      expect(store.writes, hasLength(3));
    },
  );

  test(
    'failed scoped writes preserve state and resetting one book preserves other scopes',
    () async {
      store.data = TransformerSettings(
        application: [conversion],
        books: {
          TransformerSettings.bookKey('f', 'a'): BookTransformers(
            rules: [replace],
          ),
          TransformerSettings.bookKey('f', 'b'): BookTransformers(
            rules: [delete],
          ),
        },
      );
      final container = containerForStore();
      addTearDown(container.dispose);
      final original = await container.read(transformerSettingsProvider.future);
      final notifier = container.read(transformerSettingsProvider.notifier);
      store.failWrites = true;
      await expectLater(
        notifier.save(feedId: 'f', bookId: 'a', rules: []),
        throwsStateError,
      );
      expect(
        container.read(transformerSettingsProvider).requireValue.toJson(),
        original.toJson(),
      );
      store.failWrites = false;
      await notifier.resetBook(feedId: 'f', bookId: 'a');
      final reset = container.read(transformerSettingsProvider).requireValue;
      expect(reset.application, [conversion]);
      expect(
        reset.books.containsKey(TransformerSettings.bookKey('f', 'a')),
        isFalse,
      );
      expect(reset.book('f', 'a').inheritApplication, isTrue);
      expect(reset.book('f', 'b').rules, [delete]);
      expect(reset.toJson(), store.data!.toJson());
      await expectLater(
        notifier.save(feedId: 'f', rules: []),
        throwsArgumentError,
      );
    },
  );

  test(
    'new settings expose the former built-ins as configurable rules',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await TransformerSettingsRepository(store: store).load();
      expect(settings.application.map((r) => r.kind), [
        TransformerKind.deduplicateTitles,
        TransformerKind.paragraphIndent,
      ]);
      expect(settings.application.last.indentSpaces, 2);
      final changed = settings.application.last.copyWith(
        indentSpaces: 0,
        enabled: false,
      );
      expect(changed.indentSpaces, 0);
      expect(changed.enabled, isFalse);
    },
  );

  test(
    'application rules precede book rules and disabled rules are skipped',
    () {
      final settings = TransformerSettings(
        application: [conversion, delete.withEnabled(false)],
        books: {
          TransformerSettings.bookKey('feed', 'book'): BookTransformers(
            rules: [replace, delete],
          ),
        },
      );
      expect(settings.effectiveEntries('feed', 'book'), [
        conversion,
        replace,
        delete,
      ]);
      expect(settings.effectiveEntries('feed', 'other'), [conversion]);
      expect(settings.effectiveRules('feed', 'book'), [
        conversion.toNative(),
        replace.toNative(),
        delete.toNative(),
      ]);
    },
  );

  test(
    'a book may replace the application chain, including with an empty chain',
    () {
      final settings = TransformerSettings(
        application: [conversion],
        books: {
          TransformerSettings.bookKey('feed', 'book'): BookTransformers(
            inheritApplication: false,
            rules: [delete],
          ),
          TransformerSettings.bookKey('feed', 'plain'): BookTransformers(
            inheritApplication: false,
          ),
        },
      );
      expect(settings.effectiveEntries('feed', 'book'), [delete]);
      expect(settings.effectiveEntries('feed', 'plain'), isEmpty);
      expect(settings.effectiveEntries('other-feed', 'book'), [conversion]);
    },
  );

  test(
    'settings use database storage across repository instances without losing scopes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final original = TransformerSettings(
        application: [replace, conversion],
        books: {
          TransformerSettings.bookKey('a:b', 'c'): BookTransformers(
            inheritApplication: false,
            rules: [delete.withEnabled(false)],
          ),
          TransformerSettings.bookKey('a', 'b:c'): BookTransformers(
            rules: [delete],
          ),
        },
      );
      final repository = TransformerSettingsRepository(store: store);
      await repository.load();
      await repository.saveApplication(original.application);
      for (final entry in original.books.entries) {
        final key = jsonDecode(entry.key) as List;
        await repository.saveBook(
          feedId: key[0] as String,
          bookId: key[1] as String,
          configuration: entry.value,
        );
      }
      final restored = await TransformerSettingsRepository(store: store).load();
      expect(restored.toJson(), original.toJson());
      expect(
        restored.effectiveRules('a', 'b:c'),
        original.effectiveRules('a', 'b:c'),
      );
      expect(restored.effectiveRules('a:b', 'c'), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TransformerSettingsRepository.storageKey), isNull);
      expect(store.data!.toJson(), original.toJson());
    },
  );

  test(
    'old conversion is imported only before the first chain is saved',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader.chineseConversion': ChineseConversionMode.s2Hk.index,
      });
      final repository = TransformerSettingsRepository(store: store);
      expect(
        (await repository.load()).application
            .where((r) => r.kind == TransformerKind.chineseConversion)
            .single
            .mode,
        ChineseConversionMode.s2Hk,
      );
      await repository.saveApplication([]);
      expect(
        (await TransformerSettingsRepository(store: store).load()).application,
        isEmpty,
      );
    },
  );

  test(
    'failed storage reads can be retried instead of remaining failed',
    () async {
      SharedPreferences.setMockInitialValues({
        TransformerSettingsRepository.storageKey: '{broken',
      });
      final repository = TransformerSettingsRepository(store: store);
      await expectLater(repository.load(), throwsFormatException);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        TransformerSettingsRepository.storageKey,
        jsonEncode(TransformerSettings().toJson()),
      );
      expect((await repository.load()).application, isEmpty);
    },
  );

  test(
    'legacy preferences migrate with ordering, scopes, and disabled rules intact',
    () async {
      final legacy = TransformerSettings(
        application: [replace, conversion],
        books: {
          TransformerSettings.bookKey('f', 'b'): BookTransformers(
            inheritApplication: false,
            rules: [delete.withEnabled(false)],
          ),
        },
      );
      SharedPreferences.setMockInitialValues({
        TransformerSettingsRepository.storageKey: jsonEncode(legacy.toJson()),
      });
      final loaded = await TransformerSettingsRepository(store: store).load();
      expect(loaded.toJson(), legacy.toJson());
      expect(store.data!.toJson(), legacy.toJson());
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(TransformerSettingsRepository.storageKey),
        isFalse,
      );
      expect(store.initializations, 1);
      await TransformerSettingsRepository(store: store).load();
      expect(store.initializations, 1);
    },
  );

  test('existing database settings win over stale preferences', () async {
    store.data = TransformerSettings(application: [delete]);
    SharedPreferences.setMockInitialValues({
      TransformerSettingsRepository.storageKey: '{broken',
    });
    final loaded = await TransformerSettingsRepository(store: store).load();
    expect(loaded.effectiveRules('f', 'b'), [delete.toNative()]);
    expect(store.initializations, 0);
  });

  test(
    'failed database migration keeps the original preferences for retry',
    () async {
      final legacy = TransformerSettings(application: [conversion]);
      final json = jsonEncode(legacy.toJson());
      SharedPreferences.setMockInitialValues({
        TransformerSettingsRepository.storageKey: json,
      });
      store.failWrites = true;
      final repository = TransformerSettingsRepository(store: store);
      await expectLater(repository.load(), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TransformerSettingsRepository.storageKey), json);
      expect(store.data, isNull);
      store.failWrites = false;
      expect((await repository.load()).toJson(), legacy.toJson());
      expect(
        prefs.containsKey(TransformerSettingsRepository.storageKey),
        isFalse,
      );
    },
  );

  test('all transformer payloads roundtrip through typed database DTOs', () {
    final original = TransformerSettings(
      application: const [
        TransformerEntry(
          kind: TransformerKind.chineseConversion,
          mode: ChineseConversionMode.s2Hk,
          name: 'Convert',
        ),
        TransformerEntry(
          kind: TransformerKind.regexReplace,
          pattern: '(x)',
          replacement: r'$1!',
          includeTitles: true,
        ),
        TransformerEntry(
          kind: TransformerKind.regexDelete,
          pattern: 'ad',
          enabled: false,
        ),
        TransformerEntry(
          kind: TransformerKind.paragraphIndent,
          indentSpaces: 7,
        ),
        TransformerEntry(kind: TransformerKind.deduplicateTitles),
      ],
    );
    expect(
      TransformerSettings.fromStored(original.toStored()).toJson(),
      original.toJson(),
    );
  });

  test('reload signature changes only for the effective book chain', () {
    final initial = TransformerSettings(application: [conversion]);
    final changed = TransformerSettings(
      application: [conversion],
      books: {
        TransformerSettings.bookKey('feed', 'book'): BookTransformers(
          rules: [replace],
        ),
      },
    );
    expect(
      changed.signature('feed', 'book'),
      isNot(initial.signature('feed', 'book')),
    );
    expect(
      changed.signature('feed', 'other'),
      initial.signature('feed', 'other'),
    );
  });
}
