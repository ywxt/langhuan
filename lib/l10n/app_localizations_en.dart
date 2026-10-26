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
  String get bookshelfTitle => 'Bookshelf';

  @override
  String bookshelfNewChapters(int count) {
    return '$count new chapters';
  }

  @override
  String get bookshelfCheckFailed => 'Failed to check for updates';

  @override
  String bookshelfCheckPartialFailure(int count) {
    return 'Failed to check $count books';
  }

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
  String get bookshelfBookDetails => 'Book Details';

  @override
  String get bookshelfDeleteConfirmTitle => 'Delete book?';

  @override
  String bookshelfDeleteConfirmMessage(String bookTitle) {
    return 'Remove \"$bookTitle\" from your bookshelf?';
  }

  @override
  String get bookshelfDeleteCascadeWarning =>
      'This also removes the book\'s cached chapters, cover, reading progress, and bookmarks.';

  @override
  String get bookshelfDeleteCancel => 'Cancel';

  @override
  String get bookshelfDeleteConfirm => 'Delete';

  @override
  String bookshelfDeleteQueued(String bookTitle) {
    return '\"$bookTitle\" will be removed from your bookshelf';
  }

  @override
  String get bookshelfDeleteUndo => 'Undo';

  @override
  String bookshelfReadingProgress(int current, int total, int percent) {
    return 'Chapter $current of $total · $percent%';
  }

  @override
  String bookshelfReadingProgressWithChapter(String chapter, int percent) {
    return '$chapter · $percent%';
  }

  @override
  String get bookshelfFeedPaused => 'Feed paused';

  @override
  String get bookshelfFeedPausedHint =>
      'This feed is paused. The saved book remains readable, but update checks are skipped.';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchHintNoFeed => 'Select a feed first…';

  @override
  String get searchHintAllFeeds => 'Search across all feeds…';

  @override
  String get searchAllFeeds => 'All';

  @override
  String searchSourceFailed(Object feedName) {
    return 'Failed to search $feedName';
  }

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
  String get bookDetailTitle => 'Book Details';

  @override
  String get bookDetailError => 'Failed to load book details';

  @override
  String get bookDetailRetry => 'Retry';

  @override
  String get bookDetailStartReading => 'Start Reading';

  @override
  String get bookDetailContinueReading => 'Continue Reading';

  @override
  String bookDetailLastReadChapter(String chapterTitle) {
    return 'Last read: $chapterTitle';
  }

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
  String get readerTitle => 'Reader';

  @override
  String get readerMissingParams => 'Missing reading parameters';

  @override
  String get readerFontLoadFailed => 'Failed to load font file';

  @override
  String get readerFontFileLabel => 'Font File';

  @override
  String get readerFontSystemDefault => 'System Default';

  @override
  String get readerFontChoose => 'Choose Font File';

  @override
  String get readerFontReset => 'Reset';

  @override
  String readerFontScale(String scale) {
    return 'Font ${scale}x';
  }

  @override
  String readerLetterSpacing(String value) {
    return 'Letter Spacing $value';
  }

  @override
  String readerParagraphSpacing(String value) {
    return 'Paragraph Spacing $value';
  }

  @override
  String readerLineHeight(String value) {
    return 'Line Height $value';
  }

  @override
  String get readerLoadError => 'Failed to load chapter';

  @override
  String get readerEmpty => 'No chapter content available';

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
  String get readerModeLabel => 'Reading Mode';

  @override
  String get readerEndOfBook => 'You\'ve reached the end of the book';

  @override
  String get readerLoading => 'Loading…';

  @override
  String get readerChapterLoadError => 'Failed to load chapter';

  @override
  String get readerRetry => 'Retry';

  @override
  String get readerToc => 'TOC';

  @override
  String get readerInterface => 'Interface';

  @override
  String get readerSettings => 'Settings';

  @override
  String get readerRefreshChapter => 'Refresh Chapter';

  @override
  String get readerBookmarks => 'Bookmarks';

  @override
  String get readerBookmarkAdded => 'Bookmark added';

  @override
  String get readerBookmarkRemoved => 'Bookmark removed';

  @override
  String get readerNoBookmarks => 'No bookmarks yet';

  @override
  String get readerAddBookmark => 'Add Bookmark';

  @override
  String get readerSearchTocHint => 'Search chapters';

  @override
  String get readerSearchBookmarksHint => 'Search bookmarks';

  @override
  String get readerThemeSystem => 'System';

  @override
  String get readerThemeLight => 'Light';

  @override
  String get readerThemeDark => 'Dark';

  @override
  String get readerThemeSepia => 'Sepia';

  @override
  String get readerThemeCustom => 'Custom';

  @override
  String get readerThemeCustomizeTitle => 'Custom reader theme';

  @override
  String get readerThemeBackground => 'Background';

  @override
  String get readerThemeText => 'Text';

  @override
  String get readerThemeAccent => 'Accent';

  @override
  String get readerThemePreview => 'Preview';

  @override
  String get readerThemePreviewTitle => 'Chapter title';

  @override
  String get readerThemePreviewBody =>
      'Reading should feel comfortable on every page.';

  @override
  String get readerThemeContrastWarning =>
      'Choose background and text colors with more contrast.';

  @override
  String get readerThemeReset => 'Reset';

  @override
  String get readerThemeApply => 'Apply';

  @override
  String get readerThemeColorHue => 'Hue';

  @override
  String get readerThemeColorSaturation => 'Saturation';

  @override
  String get readerThemeColorBrightness => 'Brightness';

  @override
  String get readerThemeColorCancel => 'Cancel';

  @override
  String get readerThemeLabel => 'Theme';

  @override
  String readerSearchNoMatch(String keyword) {
    return 'Nothing matching \"$keyword\"';
  }

  @override
  String get readerSettingPlaceholder =>
      'This entry is reserved for future settings.';

  @override
  String get readerChineseConversion => 'Chinese Conversion';

  @override
  String get chineseConversionNone => 'Off';

  @override
  String get chineseConversionS2t => 'Simplified → Traditional';

  @override
  String get chineseConversionT2s => 'Traditional → Simplified';

  @override
  String get chineseConversionS2tw => 'Simplified → Taiwan Traditional';

  @override
  String get chineseConversionS2hk => 'Simplified → Hong Kong Traditional';

  @override
  String get feedsTitle => 'Feeds';

  @override
  String get feedsSearchHint => 'Search feeds…';

  @override
  String get feedsEmpty => 'No feeds yet.\nAdd a feed to get started.';

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
  String get feedDetailBaseUrl => 'Base URL';

  @override
  String get feedDetailAccessDomains => 'Access domains';

  @override
  String get feedDetailNoDomainRestriction => 'No domain restrictions';

  @override
  String get feedDetailSource => 'Source';

  @override
  String get feedDetailEnabled => 'Enabled';

  @override
  String get feedDetailEnabledHint =>
      'Paused feeds are excluded from aggregated search and update checks.';

  @override
  String get feedDetailBooksLabel => 'Shelved books';

  @override
  String feedDetailBookCount(int count) {
    return '$count';
  }

  @override
  String get feedDetailCopyId => 'Copy ID';

  @override
  String get feedDetailCopied => 'Copied';

  @override
  String get feedDetailDelete => 'Delete feed';

  @override
  String get feedItemPaused => 'Paused';

  @override
  String get feedAuthLabel => 'Auth';

  @override
  String get feedAuthStatusLoggedIn => 'Logged in';

  @override
  String get feedAuthStatusLoggedOut => 'Logged out';

  @override
  String get feedAuthStatusExpired => 'Expired';

  @override
  String get feedAuthStatusUnsupported => 'Unsupported';

  @override
  String get feedAuthLogin => 'Login';

  @override
  String get feedAuthLogout => 'Logout';

  @override
  String get feedAuthPageTitle => 'Feed Login';

  @override
  String get feedAuthDone => 'Verify';

  @override
  String get feedAuthInstructions =>
      'Sign in on this page, then tap Verify when finished.';

  @override
  String get feedAuthDesktopInstructions =>
      'A login window has opened. Sign in there, keep it open, then come back and tap Verify.';

  @override
  String get feedAuthDesktopWindowHint =>
      'The login window stays open. After signing in, tap Verify in the top bar.';

  @override
  String get feedAuthWindowClosed =>
      'The login window was closed. Verification needs the page and cookies from that window — please reopen it.';

  @override
  String get feedAuthReopenWindow => 'Reopen login window';

  @override
  String get feedAuthVerifying => 'Verifying login…';

  @override
  String get feedAuthNotSupported => 'This feed does not support login.';

  @override
  String get feedAuthUpdated => 'Login verified';

  @override
  String get feedAuthLoggedOut => 'Logged out';

  @override
  String get feedAuthRefresh => 'Refresh login status';

  @override
  String get searchAuthHint => 'This source may require login';

  @override
  String get searchAuthAction => 'Login Source';

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
  String get feedDeleteCascadeWarning =>
      'This also removes the feed\'s cached books, covers, reading progress, and bookmarks.';

  @override
  String feedDeleteSuccess(String feedName) {
    return '$feedName removed';
  }

  @override
  String get feedDeleteError => 'Failed to delete feed';

  @override
  String get feedToggleError => 'Failed to switch feed';

  @override
  String get feedPause => 'Pause feed';

  @override
  String get feedResume => 'Resume feed';

  @override
  String get feedsMenuImport => 'Import feeds';

  @override
  String get feedsMenuExport => 'Export feeds';

  @override
  String get feedsExported => 'Feed export saved';

  @override
  String get feedsExportNone => 'No feeds to export';

  @override
  String get feedsExportError => 'Failed to export feeds';

  @override
  String get feedsImportError => 'Failed to import feeds';

  @override
  String get feedsImportTitle => 'Import feeds';

  @override
  String get feedsImportConfirm => 'Import';

  @override
  String feedsImportCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count feeds found',
      one: '1 feed found',
    );
    return '$_temp0';
  }

  @override
  String feedsImportResult(Object failed, Object installed, Object skipped) {
    return 'Installed $installed, skipped $skipped, failed $failed';
  }

  @override
  String get feedsImportChangeNew => 'New';

  @override
  String get feedsImportChangeUpgrade => 'Upgrade';

  @override
  String get feedsImportChangeDowngrade => 'Downgrade';

  @override
  String get feedsImportChangeSame => 'Installed';

  @override
  String get feedsImportChangeUnknown => 'Unknown';

  @override
  String get settingsBackup => 'Export backup';

  @override
  String get settingsBackupDescription =>
      'Save sources, shelf, reading progress and bookmarks to a file';

  @override
  String get settingsBackupSuccess => 'Backup saved';

  @override
  String get settingsBackupError => 'Failed to export backup';

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
  String get addFeedBadgeNew => 'New feed';

  @override
  String addFeedIsDowngrade(String from, String to) {
    return 'Downgrading $from → $to';
  }

  @override
  String get addFeedIsSame => 'Same version as installed';

  @override
  String addFeedVersionUnknown(String from, String to) {
    return 'Installed $from; installing $to';
  }

  @override
  String get addFeedInstall => 'Install';

  @override
  String get addFeedSuccess => 'Feed installed successfully';

  @override
  String get settingsReading => 'Reading';

  @override
  String get settingsChineseConversion => 'Chinese Conversion';

  @override
  String get settingsChineseConversionDescription =>
      'Auto-convert Chinese text while reading';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsCleanupCache => 'Clear stale cache';

  @override
  String get settingsCleanupCacheDescription =>
      'Remove cached data and reading progress older than 15 days (bookshelf items are preserved)';

  @override
  String settingsCleanupSuccess(int count) {
    return '$count items cleaned up';
  }

  @override
  String get settingsCleanupNothingToClean => 'Nothing to clean up';

  @override
  String get settingsCleanupError => 'Cleanup failed';

  @override
  String get settingsStorageDatabaseSize => 'Database size';

  @override
  String get settingsStorageCacheSize => 'Cache size';

  @override
  String get settingsStorageBooks => 'Books';

  @override
  String get settingsStorageChapters => 'Chapters';

  @override
  String get settingsStorageCovers => 'Covers';

  @override
  String get settingsStorageBookshelfCount => 'On shelf';

  @override
  String get settingsClearCache => 'Clear cache';

  @override
  String get settingsClearCacheDescription =>
      'Remove all cached chapters and covers; bookshelf, progress, and bookmarks are kept';

  @override
  String get settingsClearCacheConfirmTitle => 'Clear cache?';

  @override
  String get settingsClearCacheConfirmMessage => 'Clear all cached data?';

  @override
  String get settingsClearCacheNote =>
      'Cached chapters and covers will be removed and re-downloaded when needed. Reading progress and bookmarks are kept.';

  @override
  String settingsClearCacheSuccess(String bytes) {
    return 'Cache cleared — $bytes freed';
  }

  @override
  String get settingsClearCacheNothing => 'Cache is already empty';

  @override
  String get settingsClearCacheError => 'Failed to clear cache';

  @override
  String get settingsDeveloper => 'Developer';

  @override
  String get devToolsTitle => 'Developer tools';

  @override
  String get devToolsEntryDescription => 'Feed script debugging environment';

  @override
  String devUnlockCountdown(int count) {
    return '$count more taps to enable developer tools';
  }

  @override
  String get devUnlocked => 'Developer tools enabled';

  @override
  String get devDisable => 'Turn off developer tools';

  @override
  String get devDisableConfirmTitle => 'Turn off developer tools?';

  @override
  String get devDisableConfirmMessage =>
      'This hides the developer tools entry.';

  @override
  String get devScriptLabel => 'Feed script';

  @override
  String get devScriptHint =>
      'Paste a JavaScript feed or import one from an installed feed. Scripts run in an isolated native QuickJS sandbox; installed feeds are untouched.';

  @override
  String get devScriptImport => 'Import';

  @override
  String get devScriptImportTitle => 'Pick an installed feed';

  @override
  String get devScriptImportEmpty => 'No installed feeds';

  @override
  String get devScriptClear => 'Clear';

  @override
  String get devScriptClearConfirmTitle => 'Clear the script?';

  @override
  String get devScriptClearConfirmMessage => 'This empties the editor.';

  @override
  String get devScriptMissing => 'Paste or import a script first';

  @override
  String devScriptImported(String name) {
    return 'Imported \"$name\"';
  }

  @override
  String get devScriptLoadError => 'Failed to load the feed script';

  @override
  String get devAuthApplied => 'Using stored login';

  @override
  String get devAuthMissing => 'No stored login';

  @override
  String get devAuthNotSupported => 'Script has no login block';

  @override
  String get debugStageSearch => 'Search';

  @override
  String get debugStageBookInfo => 'Book info';

  @override
  String get debugStageChapters => 'Chapters';

  @override
  String get debugStageParagraphs => 'Paragraphs';

  @override
  String get debugStageAuthStatus => 'Auth status';

  @override
  String get debugInputKeyword => 'Keyword';

  @override
  String get debugInputBookId => 'Book ID';

  @override
  String get debugInputChapterId => 'Chapter ID';

  @override
  String debugInputMissing(String field) {
    return 'Please fill in: $field';
  }

  @override
  String get debugRun => 'Run';

  @override
  String get debugSummaryOk => 'OK';

  @override
  String get debugSummaryFailed => 'Failed';

  @override
  String debugDurationMs(int ms) {
    return '$ms ms';
  }

  @override
  String get debugErrorTitle => 'Error';

  @override
  String get debugOutputTitle => 'Output';

  @override
  String get debugResultEmpty => '0 items';

  @override
  String get debugEmptyHint =>
      'Paste or import a feed script, pick a pipeline stage and run. The typed output, the error (if any) and the recorded HTTP traffic appear here; runs accumulate in the history below.';

  @override
  String get debugChainBookInfo => 'Book info';

  @override
  String get debugChainParagraphs => 'Paragraphs';

  @override
  String get debugFieldId => 'ID';

  @override
  String get debugFieldTitle => 'Title';

  @override
  String get debugFieldAuthor => 'Author';

  @override
  String get debugFieldCover => 'Cover';

  @override
  String get debugFieldDescription => 'Description';

  @override
  String get debugImageParagraph => 'image';

  @override
  String debugTraceTitle(int count) {
    return 'HTTP trace ($count)';
  }

  @override
  String get debugTraceEmpty => 'No HTTP requests were made.';

  @override
  String debugTraceDropped(int count) {
    return '$count further requests were not recorded (trace limit reached).';
  }

  @override
  String get debugTraceSize => 'Response size';

  @override
  String get debugTraceHeaders => 'Request headers';

  @override
  String get debugTraceBodyPreview => 'Body preview';

  @override
  String debugHistoryTitle(int count) {
    return 'History ($count)';
  }
}
