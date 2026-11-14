/// Shared error helpers used across features.
library;

import '../../l10n/app_localizations.dart';
import '../../src/rust/api/types.dart';

/// How an error should be presented on an error surface: a short
/// classification acting as the title, with the detail underneath.
class ErrorPresentation {
  const ErrorPresentation({required this.title, required this.detail});

  final String title;
  final String detail;

  /// Title and detail joined for one-line surfaces such as snackbars:
  /// the classification leads, the detail follows.
  String get singleLine => detail.isEmpty ? title : '$title: $detail';
}

/// Strips common exception prefixes (e.g. `BridgeError: …`) from an error so
/// only the human-readable message remains.
String normalizeErrorMessage(Object? error) {
  // Bridge errors take the `message` field directly: their `toString`
  // keeps the full `BridgeError($kind)` form for developer surfaces, and
  // the generic first-colon strip below would cut into localized category
  // prefixes inside the message (`网络错误: …`), or even into the wrapper
  // itself for kinds whose rendering contains a colon.
  if (error is BridgeError) {
    final message = error.message.trim();
    return message.isEmpty ? 'Unknown error' : message;
  }
  final text = error.toString().trim();
  if (text.isEmpty) return 'Unknown error';
  final colonIndex = text.indexOf(':');
  if (colonIndex > 0 && colonIndex < text.length - 1) {
    return text.substring(colonIndex + 1).trim();
  }
  return text;
}

/// Describes [error] for a surface whose generic title is [genericTitle].
///
/// Every classified bridge error leads with its classification: an
/// anticipated script error ([`ErrorKind_ScriptExpected`]) reports the
/// script's own message as the detail, while the other kinds carry the
/// full localized message. Only unclassified errors —
/// [`ErrorKind_Internal`], non-bridge exceptions, and null — keep the
/// surface's generic title.
ErrorPresentation describeError(
  Object? error,
  AppLocalizations l10n, {
  required String genericTitle,
}) {
  if (error == null) {
    return ErrorPresentation(title: genericTitle, detail: '');
  }
  if (error case BridgeError(kind: ErrorKind_ScriptExpected(:final reason))) {
    final detail = error.detail;
    return ErrorPresentation(
      title: _categoryLabel(reason, l10n),
      detail: detail != null && detail.isNotEmpty
          ? detail
          : normalizeErrorMessage(error),
    );
  }
  if (error is BridgeError) {
    final category = _kindLabel(error.kind, l10n);
    if (category != null) {
      return ErrorPresentation(
        title: category,
        detail: normalizeErrorMessage(error),
      );
    }
  }
  return ErrorPresentation(
    title: genericTitle,
    detail: normalizeErrorMessage(error),
  );
}

/// Localized label for a script-error classification. The wording matches
/// the prefix the Rust side composes into the full localized message.
String _categoryLabel(ScriptExpectedReason reason, AppLocalizations l10n) =>
    switch (reason) {
      ScriptExpectedReason_AuthRequired() => l10n.errorCategoryAuthRequired,
      ScriptExpectedReason_VerificationRequired() =>
        l10n.errorCategoryVerificationRequired,
      ScriptExpectedReason_RateLimited() => l10n.errorCategoryRateLimited,
      ScriptExpectedReason_ContentNotFound() =>
        l10n.errorCategoryContentNotFound,
      ScriptExpectedReason_SourceUnavailable() =>
        l10n.errorCategorySourceUnavailable,
      ScriptExpectedReason_Other() => l10n.errorCategoryScriptError,
    };

/// Localized label for a bridge error kind, or null when the kind carries
/// no user-facing classification — [`ErrorKind_Internal`] is the app's
/// own unclassified bucket and keeps the surface's generic title.
/// [`ErrorKind_ScriptExpected`] is resolved by [_categoryLabel] instead.
String? _kindLabel(ErrorKind kind, AppLocalizations l10n) => switch (kind) {
  ErrorKind_Internal() => null,
  ErrorKind_Network() => l10n.errorCategoryNetwork,
  ErrorKind_ScriptRuntime() => l10n.errorCategoryScriptRuntime,
  ErrorKind_ScriptConfig() => l10n.errorCategoryScriptConfig,
  ErrorKind_Storage() => l10n.errorCategoryStorage,
  ErrorKind_Registry() => l10n.errorCategoryRegistry,
  ErrorKind_ScriptExpected() => null,
};
