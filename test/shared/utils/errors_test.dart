import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/utils/errors.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  // The message strings mirror what the Rust side localizes; only the
  // mapping contract is under test, not the wording.
  const genericTitle = 'Failed to load chapter';

  late AppLocalizations en;

  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('null keeps the generic title with no detail', () {
    final display = describeError(null, en, genericTitle: genericTitle);
    expect(display.title, genericTitle);
    expect(display.detail, '');
  });

  test('unclassified internal errors keep the generic title', () {
    final display = describeError(
      const BridgeError(
        kind: ErrorKind_Internal(),
        message: 'internal error: mailbox closed',
      ),
      en,
      genericTitle: genericTitle,
    );
    expect(display.title, genericTitle);
    expect(display.detail, 'internal error: mailbox closed');
  });

  test('non-bridge exceptions keep the generic title', () {
    final display = describeError(
      StateError('paragraph job died: boom'),
      en,
      genericTitle: genericTitle,
    );
    // Only the "Bad state" wrapper prefix is stripped.
    expect(display.title, genericTitle);
    expect(display.detail, 'paragraph job died: boom');
  });

  for (final (kind, label) in [
    (const ErrorKind_Network(), 'Network error'),
    (const ErrorKind_ScriptRuntime(), 'Script runtime error'),
    (const ErrorKind_ScriptConfig(), 'Script configuration error'),
    (const ErrorKind_Storage(), 'Storage error'),
    (const ErrorKind_Registry(), 'Feed not found'),
  ]) {
    test('$kind leads with its classification', () {
      final display = describeError(
        BridgeError(kind: kind, message: 'HTTP request failed: timeout'),
        en,
        genericTitle: genericTitle,
      );
      expect(display.title, label);
      // The full localized message stays visible under the title.
      expect(display.detail, 'HTTP request failed: timeout');
    });
  }

  test('an anticipated script error reports only the script message', () {
    final display = describeError(
      const BridgeError(
        kind: ErrorKind_ScriptExpected(
          reason: ScriptExpectedReason_RateLimited(),
        ),
        message: 'Rate limited: slow down',
        detail: 'slow down',
      ),
      en,
      genericTitle: genericTitle,
    );
    expect(display.title, 'Rate limited');
    expect(display.detail, 'slow down');
  });

  test('zh labels carry the Traditional Chinese wording', () async {
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final (kind, label) in [
      (const ErrorKind_Network(), '網絡錯誤'),
      (const ErrorKind_ScriptRuntime(), '腳本運行錯誤'),
      (const ErrorKind_ScriptConfig(), '腳本配置錯誤'),
      (const ErrorKind_Storage(), '存儲錯誤'),
      (const ErrorKind_Registry(), '找不到書源'),
    ]) {
      final display = describeError(
        BridgeError(kind: kind, message: 'ignored'),
        zh,
        genericTitle: genericTitle,
      );
      expect(display.title, label);
    }
  });
}
