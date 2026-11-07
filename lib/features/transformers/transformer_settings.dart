import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/rust/api/transformers.dart' as native;
import '../../rust_init.dart';
import '../../src/rust/api/types.dart';

enum TransformerKind {
  chineseConversion,
  regexReplace,
  regexDelete,
  paragraphIndent,
  deduplicateTitles,
}

@immutable
class TransformerEntry {
  const TransformerEntry({
    required this.kind,
    this.name = '',
    this.enabled = true,
    this.mode = ChineseConversionMode.none,
    this.pattern = '',
    this.replacement = '',
    this.includeTitles = false,
    this.indentSpaces = 2,
  });
  final TransformerKind kind;
  final String name;
  final bool enabled;
  final ChineseConversionMode mode;
  final String pattern;
  final String replacement;
  final bool includeTitles;
  final int indentSpaces;

  TransformerEntry copyWith({
    String? name,
    bool? enabled,
    ChineseConversionMode? mode,
    String? pattern,
    String? replacement,
    bool? includeTitles,
    int? indentSpaces,
  }) => TransformerEntry(
    kind: kind,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    includeTitles: includeTitles ?? this.includeTitles,
    indentSpaces: indentSpaces ?? this.indentSpaces,
  );
  TransformerEntry withEnabled(bool value) => copyWith(enabled: value);

  TransformerRule toNative() => switch (kind) {
    TransformerKind.paragraphIndent => TransformerRule.paragraphIndent(
      spaces: indentSpaces,
    ),
    TransformerKind.deduplicateTitles =>
      const TransformerRule.deduplicateTitles(),
    TransformerKind.chineseConversion => TransformerRule.chineseConversion(
      mode: mode,
    ),
    TransformerKind.regexReplace => TransformerRule.regexReplace(
      pattern: pattern,
      replacement: replacement,
      includeTitles: includeTitles,
    ),
    TransformerKind.regexDelete => TransformerRule.regexDelete(
      pattern: pattern,
      includeTitles: includeTitles,
    ),
  };

  TransformerConfigurationEntry toStored() => TransformerConfigurationEntry(
    name: name,
    enabled: enabled,
    rule: toNative(),
  );

  factory TransformerEntry.fromStored(TransformerConfigurationEntry entry) {
    final rule = switch (entry.rule) {
      TransformerRule_ParagraphIndent(:final spaces) => TransformerEntry(
        kind: TransformerKind.paragraphIndent,
        indentSpaces: spaces,
      ),
      TransformerRule_DeduplicateTitles() => const TransformerEntry(
        kind: TransformerKind.deduplicateTitles,
      ),
      TransformerRule_ChineseConversion(:final mode) => TransformerEntry(
        kind: TransformerKind.chineseConversion,
        mode: mode,
      ),
      TransformerRule_RegexReplace(
        :final pattern,
        :final replacement,
        :final includeTitles,
      ) =>
        TransformerEntry(
          kind: TransformerKind.regexReplace,
          pattern: pattern,
          replacement: replacement,
          includeTitles: includeTitles,
        ),
      TransformerRule_RegexDelete(:final pattern, :final includeTitles) =>
        TransformerEntry(
          kind: TransformerKind.regexDelete,
          pattern: pattern,
          includeTitles: includeTitles,
        ),
    };
    return rule.copyWith(name: entry.name, enabled: entry.enabled);
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'enabled': enabled,
    'mode': mode.name,
    'pattern': pattern,
    'replacement': replacement,
    'includeTitles': includeTitles,
    'indentSpaces': indentSpaces,
  };
  factory TransformerEntry.fromJson(Map<String, dynamic> value) =>
      TransformerEntry(
        kind: TransformerKind.values.byName(value['kind'] as String),
        name: value['name'] as String? ?? '',
        enabled: value['enabled'] as bool? ?? true,
        mode: ChineseConversionMode.values.byName(
          value['mode'] as String? ?? 'none',
        ),
        pattern: value['pattern'] as String? ?? '',
        replacement: value['replacement'] as String? ?? '',
        includeTitles: value['includeTitles'] as bool? ?? false,
        indentSpaces: value['indentSpaces'] as int? ?? 2,
      );
}

@immutable
class BookTransformers {
  BookTransformers({
    this.inheritApplication = true,
    List<TransformerEntry> rules = const [],
  }) : rules = List.unmodifiable(rules);
  final bool inheritApplication;
  final List<TransformerEntry> rules;
  BookTransformerConfiguration toStored(String feedId, String bookId) =>
      BookTransformerConfiguration(
        feedId: feedId,
        bookId: bookId,
        inheritApplication: inheritApplication,
        rules: rules.map((r) => r.toStored()).toList(),
      );
  Map<String, Object?> toJson() => {
    'inheritApplication': inheritApplication,
    'rules': rules.map((r) => r.toJson()).toList(),
  };
  factory BookTransformers.fromJson(Map<String, dynamic> value) =>
      BookTransformers(
        inheritApplication: value['inheritApplication'] as bool? ?? true,
        rules: (value['rules'] as List)
            .map((r) => TransformerEntry.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
      );
}

@immutable
class TransformerSettings {
  TransformerSettings({
    List<TransformerEntry> application = const [],
    Map<String, BookTransformers> books = const {},
  }) : application = List.unmodifiable(application),
       books = Map.unmodifiable(books);
  final List<TransformerEntry> application;
  final Map<String, BookTransformers> books;
  static String bookKey(String feedId, String bookId) =>
      jsonEncode([feedId, bookId]);
  BookTransformers book(String feedId, String bookId) =>
      books[bookKey(feedId, bookId)] ?? BookTransformers();
  List<TransformerEntry> effectiveEntries(String feedId, String bookId) {
    final settings = book(feedId, bookId);
    return [
      if (settings.inheritApplication) ...application,
      ...settings.rules,
    ].where((r) => r.enabled).toList();
  }

  List<TransformerRule> effectiveRules(String feedId, String bookId) =>
      effectiveEntries(feedId, bookId).map((r) => r.toNative()).toList();
  String signature(String feedId, String bookId) => jsonEncode(
    effectiveEntries(
      feedId,
      bookId,
    ).map((r) => {...r.toJson()}..remove('name')).toList(),
  );
  TransformerConfiguration toStored() => TransformerConfiguration(
    application: application.map((r) => r.toStored()).toList(),
    books: books.entries.map((entry) {
      final key = jsonDecode(entry.key) as List;
      return entry.value.toStored(key[0] as String, key[1] as String);
    }).toList(),
  );
  factory TransformerSettings.fromStored(TransformerConfiguration value) =>
      TransformerSettings(
        application: value.application
            .map(TransformerEntry.fromStored)
            .toList(),
        books: {
          for (final book in value.books)
            bookKey(book.feedId, book.bookId): BookTransformers(
              inheritApplication: book.inheritApplication,
              rules: book.rules.map(TransformerEntry.fromStored).toList(),
            ),
        },
      );
  Map<String, Object?> toJson() => {
    'application': application.map((r) => r.toJson()).toList(),
    'books': books.map((k, v) => MapEntry(k, v.toJson())),
  };
  factory TransformerSettings.fromJson(Map<String, dynamic> value) =>
      TransformerSettings(
        application: (value['application'] as List)
            .map((r) => TransformerEntry.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
        books: (value['books'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(
            k,
            BookTransformers.fromJson(Map<String, dynamic>.from(v)),
          ),
        ),
      );
}

/// Database storage boundary, injectable for settings and migration tests.
abstract interface class TransformerSettingsStore {
  Future<TransformerSettings?> read();
  Future<TransformerSettings> initialize(TransformerSettings? imported);
  Future<void> saveApplication(List<TransformerEntry> rules);
  Future<void> saveBook({
    required String feedId,
    required String bookId,
    required BookTransformers configuration,
  });
  Future<void> deleteBook({required String feedId, required String bookId});
}

class _DatabaseTransformerSettingsStore implements TransformerSettingsStore {
  const _DatabaseTransformerSettingsStore();
  @override
  Future<TransformerSettings?> read() async {
    final value = await native.getTransformerConfiguration();
    return value == null ? null : TransformerSettings.fromStored(value);
  }

  @override
  Future<TransformerSettings> initialize(TransformerSettings? imported) async =>
      TransformerSettings.fromStored(
        await native.initializeTransformerConfiguration(
          configuration: imported?.toStored(),
        ),
      );
  @override
  Future<void> saveApplication(List<TransformerEntry> rules) =>
      native.saveApplicationTransformers(
        rules: rules.map((r) => r.toStored()).toList(),
      );
  @override
  Future<void> saveBook({
    required String feedId,
    required String bookId,
    required BookTransformers configuration,
  }) => native.saveBookTransformers(
    configuration: configuration.toStored(feedId, bookId),
  );
  @override
  Future<void> deleteBook({required String feedId, required String bookId}) =>
      native.deleteBookTransformers(feedId: feedId, bookId: bookId);
}

/// SQLite is authoritative. Preferences are consulted only before the first
/// database configuration exists, and removed only after the import commits.
class TransformerSettingsRepository {
  TransformerSettingsRepository({TransformerSettingsStore? store})
    : _store = store ?? const _DatabaseTransformerSettingsStore();
  static final instance = TransformerSettingsRepository();
  static const storageKey = 'reader.transformers';
  final TransformerSettingsStore _store;

  Future<TransformerSettings> load() async {
    final stored = await _store.read();
    if (stored != null) return stored;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(storageKey);
    TransformerSettings? imported;
    if (legacy != null) {
      imported = TransformerSettings.fromJson(
        jsonDecode(legacy) as Map<String, dynamic>,
      );
    } else {
      final index = prefs.getInt('reader.chineseConversion');
      if (index != null &&
          index >= 0 &&
          index < ChineseConversionMode.values.length) {
        final mode = ChineseConversionMode.values[index];
        imported = TransformerSettings(
          application: [
            const TransformerEntry(kind: TransformerKind.deduplicateTitles),
            if (mode != ChineseConversionMode.none)
              TransformerEntry(
                kind: TransformerKind.chineseConversion,
                mode: mode,
              ),
            const TransformerEntry(kind: TransformerKind.paragraphIndent),
          ],
        );
      }
    }
    final result = await _store.initialize(imported);
    await prefs.remove(storageKey);
    await prefs.remove('reader.chineseConversion');
    return result;
  }

  Future<void> saveApplication(List<TransformerEntry> rules) =>
      _store.saveApplication(rules);
  Future<void> saveBook({
    required String feedId,
    required String bookId,
    required BookTransformers configuration,
  }) => _store.saveBook(
    feedId: feedId,
    bookId: bookId,
    configuration: configuration,
  );
  Future<void> deleteBook({required String feedId, required String bookId}) =>
      _store.deleteBook(feedId: feedId, bookId: bookId);
}

final transformerSettingsRepositoryProvider =
    Provider<TransformerSettingsRepository>(
      (ref) => TransformerSettingsRepository.instance,
    );

final transformerSettingsProvider =
    AsyncNotifierProvider<TransformerSettingsNotifier, TransformerSettings>(
      TransformerSettingsNotifier.new,
    );

class TransformerSettingsNotifier extends AsyncNotifier<TransformerSettings> {
  @override
  Future<TransformerSettings> build() async {
    final repository = ref.watch(transformerSettingsRepositoryProvider);
    await ref.watch(appDataDirectorySetProvider.future);
    return repository.load();
  }

  Future<void> save({
    required List<TransformerEntry> rules,
    String? feedId,
    String? bookId,
    bool inheritApplication = true,
  }) async {
    if ((feedId == null) != (bookId == null)) {
      throw ArgumentError('feedId and bookId must be supplied together');
    }
    final entries = List<TransformerEntry>.unmodifiable(rules);
    await future;
    final repository = ref.read(transformerSettingsRepositoryProvider);
    final book = BookTransformers(
      inheritApplication: inheritApplication,
      rules: entries,
    );
    if (feedId == null) {
      await repository.saveApplication(entries);
    } else {
      await repository.saveBook(
        feedId: feedId,
        bookId: bookId!,
        configuration: book,
      );
    }
    if (!ref.mounted) return;
    // Merge the completed scope into the latest state, so another scope's
    // concurrently completed write is not replaced with an earlier snapshot.
    final current = state.requireValue;
    state = AsyncData(
      feedId == null
          ? TransformerSettings(application: entries, books: current.books)
          : TransformerSettings(
              application: current.application,
              books: {
                ...current.books,
                TransformerSettings.bookKey(feedId, bookId!): book,
              },
            ),
    );
  }

  Future<void> resetBook({
    required String feedId,
    required String bookId,
  }) async {
    await future;
    await ref
        .read(transformerSettingsRepositoryProvider)
        .deleteBook(feedId: feedId, bookId: bookId);
    if (!ref.mounted) return;
    final current = state.requireValue;
    final books = Map.of(current.books)
      ..remove(TransformerSettings.bookKey(feedId, bookId));
    state = AsyncData(
      TransformerSettings(application: current.application, books: books),
    );
  }
}
