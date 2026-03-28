// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Langhuan';

  @override
  String get navBookshelf => 'Bookshelf';

  @override
  String get navFeeds => 'Feeds';

  @override
  String get navProfile => 'Profile';

  @override
  String get bookshelfTitle => 'Bookshelf';

  @override
  String get bookshelfEmpty => 'Your books will appear here';

  @override
  String get bookshelfSearchHint => 'Search books…';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchHintNoFeed => 'Select a feed first…';

  @override
  String searchHintWithFeed(String feedName) {
    return 'Search in $feedName…';
  }

  @override
  String get searchCancel => 'Cancel';

  @override
  String get searchClear => 'Clear';

  @override
  String get searchEmptyPrompt => 'Enter a keyword to start searching';

  @override
  String searchNoResults(String keyword) {
    return 'No results for \"$keyword\"';
  }

  @override
  String get searchError => 'Search failed';

  @override
  String get searchRetry => 'Retry';

  @override
  String get searchLoadingMore => 'Loading more…';

  @override
  String get feedsTitle => 'Feeds';

  @override
  String get feedsSearchHint => 'Search feeds…';

  @override
  String get feedsEmpty =>
      'No feeds loaded.\nPlease add scripts to the scripts folder.';

  @override
  String feedsNoMatch(String keyword) {
    return 'No feeds matching \"$keyword\"';
  }

  @override
  String get feedsLoadError => 'Failed to load feeds';

  @override
  String get feedsRetry => 'Retry';

  @override
  String get feedDetailId => 'ID';

  @override
  String get feedDetailVersion => 'Version';

  @override
  String get feedDetailAuthor => 'Author';

  @override
  String get feedDetailTooltip => 'Details';

  @override
  String get feedItemLoadError => 'Load error';

  @override
  String get feedDeleteConfirmTitle => 'Delete feed?';

  @override
  String feedDeleteConfirmMessage(String feedName) {
    return 'Delete \"$feedName\" from your feeds?';
  }

  @override
  String get feedDeleteCancel => 'Cancel';

  @override
  String get feedDeleteConfirm => 'Delete';

  @override
  String feedDeleteSuccess(String feedName) {
    return '$feedName removed';
  }

  @override
  String get feedDeleteError => 'Failed to delete feed';

  @override
  String get feedDeleteBusy => 'Another feed operation is in progress';

  @override
  String feedDeleteQueued(String feedName) {
    return '\"$feedName\" will be deleted';
  }

  @override
  String get feedDeleteUndo => 'Undo';

  @override
  String get feedSelectorNoFeeds =>
      'No feeds available. Add scripts in the Feeds tab first.';

  @override
  String get profileTitle => 'Profile';

  @override
  String get profileSubtitle => 'Manage your account settings';

  @override
  String get errorSomethingWrong => 'Something went wrong';

  @override
  String get addFeedTitle => 'Add Feed Source';

  @override
  String get addFeedTabUrl => 'From URL';

  @override
  String get addFeedTabFile => 'From File';

  @override
  String get addFeedUrlHint => 'Enter script URL…';

  @override
  String get addFeedUrlPreview => 'Preview';

  @override
  String get addFeedPickFile => 'Pick Script File';

  @override
  String get addFeedPreviewTitle => 'Feed Summary';

  @override
  String get addFeedAllowedDomains => 'Accesses domains';

  @override
  String get addFeedNoDomainRestriction => 'No domain restrictions';

  @override
  String addFeedIsUpgrade(String from, String to) {
    return 'Upgrading $from → $to';
  }

  @override
  String get addFeedInstall => 'Install';

  @override
  String get addFeedSuccess => 'Feed installed successfully';

  @override
  String get addFeedErrorPreview => 'Failed to preview feed';

  @override
  String get addFeedErrorInstall => 'Failed to install feed';
}
