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
  String get navProfile => 'Settings';

  @override
  String get bookshelfTitle => 'Bookshelf';

  @override
  String get bookshelfEmpty => 'Your bookshelf is empty';

  @override
  String get bookshelfEmptyHint => 'Search and save books to see them here';

  @override
  String get bookshelfSearchHint => 'Search books…';

  @override
  String get bookshelfLoadError => 'Failed to load bookshelf';

  @override
  String get bookshelfAdded => 'Added to local bookshelf';

  @override
  String get bookshelfRemoved => 'Removed from local bookshelf';

  @override
  String get bookshelfActionFailed => 'Bookshelf action failed';

  @override
  String get bookshelfErrorAppDataNotReady => 'App data directory not ready';

  @override
  String get bookshelfErrorAddFailed => 'Failed to add book';

  @override
  String get bookshelfErrorRemoveFailed => 'Failed to remove book';

  @override
  String get bookshelfErrorLoadFailed => 'Failed to load bookshelf';

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
  String get bookDetailTitle => 'Book Details';

  @override
  String get bookDetailError => 'Failed to load book details';

  @override
  String get bookDetailRetry => 'Retry';

  @override
  String get bookDetailStartReading => 'Start Reading';

  @override
  String get bookDetailNoDescription => 'No description available';

  @override
  String bookDetailChapters(int count) {
    return 'Chapters ($count)';
  }

  @override
  String get bookDetailChaptersError => 'Failed to load chapters';

  @override
  String get bookDetailMissingParams => 'Missing book parameters';

  @override
  String get bookDetailEmpty => 'No book information available';

  @override
  String get bookDetailAddBookshelf => 'Add to Local Bookshelf';

  @override
  String get bookDetailRemoveBookshelf => 'Remove from Local Bookshelf';

  @override
  String get bookDetailSourceSupportsBookshelf =>
      'This feed supports bookshelf';

  @override
  String get bookDetailSourceNoBookshelf =>
      'This feed does not support bookshelf';

  @override
  String get readerTitle => 'Reader';

  @override
  String get readerMissingParams => 'Missing reading parameters';

  @override
  String get readerLoadError => 'Failed to load chapter';

  @override
  String get readerEmpty => 'No chapter content available';

  @override
  String get readerAtFirstChapter => 'Already at the first chapter';

  @override
  String get readerAtLastChapter => 'Already at the last chapter';

  @override
  String get readerPrevChapter => 'Previous';

  @override
  String get readerNextChapter => 'Next';

  @override
  String readerChapterProgress(int current, int total) {
    return 'Chapter $current / $total';
  }

  @override
  String get readerModeVertical => 'Vertical Scroll';

  @override
  String get readerModeHorizontal => 'Horizontal Paging';

  @override
  String readerChapterFallbackTitle(int index) {
    return 'Chapter $index';
  }

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
  String get profileTitle => 'Settings';

  @override
  String get profileSubtitle => 'Manage your preferences';

  @override
  String get navSettings => 'Settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsLicenses => 'Licenses';

  @override
  String get errorSomethingWrong => 'Something went wrong';

  @override
  String get addFeedTitle => 'Add Feed Source';

  @override
  String get addFeedTabUrl => 'From URL';

  @override
  String get addFeedTabUrlDesc =>
      'Import a feed source script from a web address';

  @override
  String get addFeedTabFile => 'From File';

  @override
  String get addFeedTabFileDesc =>
      'Import a feed source script from local storage';

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
