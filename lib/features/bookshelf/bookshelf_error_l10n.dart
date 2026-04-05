import '../../l10n/app_localizations.dart';
import 'bookshelf_provider.dart';

/// Extension to translate BookshelfError to localized messages
extension BookshelfErrorL10n on BookshelfError {
  String localize(AppLocalizations l10n) {
    switch (type) {
      case BookshelfErrorType.appDataDirectoryNotReady:
        return l10n.bookshelfErrorAppDataNotReady;
      case BookshelfErrorType.addFailed:
        return l10n.bookshelfErrorAddFailed;
      case BookshelfErrorType.removeFailed:
        return l10n.bookshelfErrorRemoveFailed;
      case BookshelfErrorType.loadFailed:
        return l10n.bookshelfErrorLoadFailed;
    }
  }
}
