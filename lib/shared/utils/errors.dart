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
}

/// Strips common exception prefixes (e.g. `BridgeError: …`) from an error so
/// only the human-readable message remains.
String normalizeErrorMessage(Object? error) {
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
/// An anticipated script error ([`ErrorKind_ScriptExpected`]) leads with its
/// classification and reports only the message the script itself provided;
/// every other error keeps the surface's generic title and carries the full
/// localized message.
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
      ScriptExpectedReason_CfChallenge() => l10n.errorCategoryCfChallenge,
      ScriptExpectedReason_RateLimited() => l10n.errorCategoryRateLimited,
      ScriptExpectedReason_ContentNotFound() =>
        l10n.errorCategoryContentNotFound,
      ScriptExpectedReason_SourceUnavailable() =>
        l10n.errorCategorySourceUnavailable,
      ScriptExpectedReason_Other() => l10n.errorCategoryScriptError,
    };
