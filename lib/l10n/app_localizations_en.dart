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
  String get bookshelfRefresh => 'Refresh bookshelf and check for updates';

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
  String bookshelfReadingProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get bookshelfFeedPaused => 'Feed paused';

  @override
  String get bookshelfFeedPausedHint =>
      'This feed is paused. The saved book remains readable, but update checks are skipped.';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchHistory => 'Search history';

  @override
  String get searchHistoryClear => 'Clear history';

  @override
  String get searchHistoryDelete => 'Remove from history';

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
  String get searchLoadMore => 'Load more';

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
  String get readerFontScale => 'Font';

  @override
  String get readerLetterSpacing => 'Letter Spacing';

  @override
  String get readerParagraphSpacing => 'Paragraph Spacing';

  @override
  String get readerLineHeight => 'Line Height';

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
  String readerPageProgress(int current, int total) {
    return 'Page $current / $total';
  }

  @override
  String readerBookProgress(int percent) {
    return '$percent% of book';
  }

  @override
  String get readerModeVertical => 'Vertical Scroll';

  @override
  String get readerModeHorizontal => 'Horizontal Paging';

  @override
  String get readerModeLabel => 'Reading Mode';

  @override
  String get readerEndOfBook => 'You\'re all caught up';

  @override
  String get readerEndHint =>
      'No more chapters for now.\nRefresh the contents to check for updates.';

  @override
  String get readerEndChecking => 'Checking for updates…';

  @override
  String get readerEndChecked => 'Contents refreshed. No new chapters yet.';

  @override
  String get readerBackToText => 'Back to reading';

  @override
  String get readerRefreshChapters => 'Check for new chapters';

  @override
  String get readerLoading => 'Loading…';

  @override
  String get readerChapterLoadError => 'Failed to load chapter';

  @override
  String get readerRetry => 'Retry';

  @override
  String get errorCategoryAuthRequired => 'Login required';

  @override
  String get errorCategoryCfChallenge => 'Cloudflare challenge detected';

  @override
  String get errorCategoryRateLimited => 'Rate limited';

  @override
  String get errorCategoryContentNotFound => 'Content not found';

  @override
  String get errorCategorySourceUnavailable => 'Source unavailable';

  @override
  String get errorCategoryScriptError => 'Script error';

  @override
  String get errorCategoryNetwork => 'Network error';

  @override
  String get errorCategoryScriptRuntime => 'Script runtime error';

  @override
  String get errorCategoryScriptConfig => 'Script configuration error';

  @override
  String get errorCategoryStorage => 'Storage error';

  @override
  String get errorCategoryRegistry => 'Feed not found';

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
  String get feedDetailNoDomainRestriction => 'Network access disabled';

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
  String get webviewVerifyPageTitle => 'Verification';

  @override
  String get webviewVerifyDone => 'Done';

  @override
  String get webviewVerifyInstructions =>
      'Complete the verification on this page, then tap \"Done\".';

  @override
  String get webviewVerifyDesktopInstructions =>
      'The verification page opened in a separate window. Complete it there, keep the window open, then come back and tap \"Done\".';

  @override
  String get webviewVerifyDesktopWindowHint =>
      'The verification window is still open. Once you finish there, tap \"Done\" in the top-right corner.';

  @override
  String get webviewVerifyWindowClosed =>
      'The verification window was closed. Verification needs the page and cookies from that window — please reopen it.';

  @override
  String get webviewVerifyReopenWindow => 'Reopen verification window';

  @override
  String get webviewVerifySubmitting => 'Submitting verification…';

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
  String feedsImportTooLarge(String size) {
    return 'Import file exceeds $size';
  }

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
  String get feedSecurityWarningTitle => 'Only install sources you trust';

  @override
  String get feedSecurityWarningBody =>
      'Feed scripts can request data from the listed domains and process login session data. A malicious source could expose private information or consume excessive resources. Review its author and domains before continuing.';

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
  String get addFeedNoDomainRestriction => 'Network access disabled';

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
  String get addFeedError => 'Failed to add feed';

  @override
  String get addFeedSuccess => 'Feed installed successfully';

  @override
  String addFeedAuditAction(String size) {
    return 'View script ($size)';
  }

  @override
  String get addFeedAuditTitle => 'Script audit';

  @override
  String addFeedAuditStats(String size, int lines) {
    return '$size · $lines lines';
  }

  @override
  String get addFeedAuditCopy => 'Copy';

  @override
  String get addFeedAuditCopied => 'Script copied';

  @override
  String get addFeedAuditWrap => 'Toggle line wrapping';

  @override
  String get addFeedAuditFormat => 'Toggle formatted view';

  @override
  String get addFeedAuditFormattedNote =>
      'Formatted for reading — the installed script stays untouched';

  @override
  String get addFeedAuditSearchHint => 'Search the script…';

  @override
  String addFeedAuditMatchCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return '$_temp0';
  }

  @override
  String get addFeedAuditNoMatch => 'No matches';

  @override
  String get addFeedAuditEmpty => 'The script is empty';

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
  String get devAgentApi => 'Agent API';

  @override
  String get devAgentApiTitle => 'Local Agent API';

  @override
  String get devAgentApiHint =>
      'Loopback only. The API stops when this developer page closes.';

  @override
  String get devAgentEndpoint => 'Endpoint';

  @override
  String get devAgentToken => 'Bearer token';

  @override
  String get devAgentCopyCurl => 'Copy curl';

  @override
  String get devAgentStop => 'Stop API';

  @override
  String get devClose => 'Close';

  @override
  String get debugOperations => 'Operations';

  @override
  String debugStepTitle(int count) {
    return 'Reducer steps ($count)';
  }

  @override
  String get debugStepEmpty => 'No reducer steps were recorded.';

  @override
  String debugStepDropped(int count) {
    return '$count further steps were omitted.';
  }

  @override
  String debugStepRound(String operation, int round) {
    return '$operation · round $round';
  }

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
  String get debugStageManual => 'Advanced single page';

  @override
  String get debugManualOperation => 'Operation';

  @override
  String get debugManualInput => 'Input JSON';

  @override
  String get debugManualInputHint => 'Passed to event.input';

  @override
  String get debugManualCursor => 'Cursor JSON';

  @override
  String get debugManualCursorHint =>
      'Passed to event.cursor; use null for the first page';

  @override
  String get debugManualUseNextCursor => 'Use next cursor';

  @override
  String get debugManualNoNextCursor =>
      'No next cursor; this operation is complete.';

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

  @override
  String get readerChapterComments => 'Chapter comments';

  @override
  String get readerParagraphComments => 'Paragraph comments';

  @override
  String get commentsReplies => 'Replies';

  @override
  String get commentsExpand => 'Expand';

  @override
  String get commentsCollapse => 'Collapse';

  @override
  String get commentsAllReplies => 'All replies';

  @override
  String get commentsEmpty => 'No comments yet';

  @override
  String get commentsMore => 'Load more';

  @override
  String get commentsEnd => 'No more comments';

  @override
  String get commentsRefresh => 'Refresh comments';

  @override
  String get commentsSortHot => 'Hot';

  @override
  String get commentsSortLatest => 'Latest';

  @override
  String get commentsViewAll => 'View all';

  @override
  String get listeningTitle => 'System text-to-speech';

  @override
  String get listeningStart => 'Start listening';

  @override
  String get listeningPause => 'Pause';

  @override
  String get listeningResume => 'Resume';

  @override
  String get listeningStop => 'Stop listening';

  @override
  String get listeningVoice => 'Engine voice';

  @override
  String get listeningRate => 'Speech rate';

  @override
  String get listeningSleep => 'Sleep timer';

  @override
  String get listeningNoTimer => 'Off';

  @override
  String get listeningLocalHint =>
      'Uses the device’s TTS engine, including its online voices. On Linux, install eSpeak NG.';

  @override
  String get listeningError =>
      'System speech is unavailable or failed. Check the TTS engine and voice, then retry.';

  @override
  String get listeningCompleted => 'Finished listening';

  @override
  String get listeningPrevious => 'Previous paragraph';

  @override
  String get listeningNext => 'Next paragraph';

  @override
  String get listeningSearchVoices => 'Search voices or languages';

  @override
  String get listeningNoVoicesMatch => 'No matching voices';

  @override
  String get listeningLoadingVoices => 'Loading system voices…';

  @override
  String get listeningReloadVoices => 'Reload voices';

  @override
  String get listeningChapterEnd => 'End of chapter';

  @override
  String get listeningStopsAfterChapter => 'Stops after this chapter';

  @override
  String get listeningCustomTimer => 'Custom';

  @override
  String get listeningCustomTimerTitle => 'Custom sleep timer';

  @override
  String listeningMinutesLabel(int count) {
    return '$count min';
  }

  @override
  String listeningRemainingTime(String time) {
    return 'Stops in $time';
  }

  @override
  String listeningParagraphProgress(int current, int total) {
    return 'Paragraph $current / $total';
  }

  @override
  String get readerShowComments => 'Show comments';

  @override
  String get readerHideComments => 'Hide comments';

  @override
  String readerCommentCountCompact(String count) {
    return '${count}K';
  }

  @override
  String get transformTitle => 'Transformers';

  @override
  String get transformBookSettings => 'Book transformers';

  @override
  String get transformDescription =>
      'Rules run from top to bottom. Select a rule to edit its name, status, and configuration.';

  @override
  String get transformRegexReplace => 'Regex replacement';

  @override
  String get transformRegexDelete => 'Delete matching paragraphs';

  @override
  String get transformSave => 'Save';

  @override
  String get transformAdd => 'Add transformer';

  @override
  String get transformName => 'Name (optional)';

  @override
  String get transformPattern => 'Regular expression';

  @override
  String get transformReplacement => 'Replacement';

  @override
  String get transformIncludeTitles => 'Also apply to chapter titles';

  @override
  String get transformRegexHelp =>
      'Use \$1 or \$2 for capture groups; \$\$ inserts a literal dollar sign. Inline flags such as (?i) are supported. Lookaround and pattern backreferences are not supported.';

  @override
  String get transformInherit => 'Apply application transformers first';

  @override
  String get transformInheritDescription =>
      'Turn off to use only this book’s rules.';

  @override
  String get transformEmpty => 'No rules in this combination.';

  @override
  String get transformMoveUp => 'Move up';

  @override
  String get transformMoveDown => 'Move down';

  @override
  String get transformPatternRequired => 'Enter a regular expression.';

  @override
  String get transformIndent => 'Paragraph indentation';

  @override
  String get transformDeduplicate => 'Chapter title cleanup';

  @override
  String get transformConversionDescription =>
      'Convert paragraph text and chapter titles between Chinese variants.';

  @override
  String get transformReplaceDescription =>
      'Replace every regex match within a paragraph.';

  @override
  String get transformDeleteDescription =>
      'Remove the whole paragraph when its text matches.';

  @override
  String get transformIndentDescription =>
      'Set the first-line indent; replaces existing leading spaces.';

  @override
  String get transformDeduplicateDescription =>
      'Keep the first chapter title and remove later duplicate title paragraphs.';

  @override
  String get transformKeepFirstTitle =>
      'Keep only the first title in each chapter';

  @override
  String transformIndentCharacters(int count) {
    return 'First-line indent: $count characters';
  }

  @override
  String get transformApplicationRules => 'Application rules';

  @override
  String get transformBookRules => 'This book’s rules';

  @override
  String get transformAddHint => 'Use + to choose and configure a transformer.';

  @override
  String get transformEnabled => 'Enabled';

  @override
  String get transformDisabled => 'Disabled';

  @override
  String get transformEmptyReplacement => '(empty text)';

  @override
  String transformDeleteQueued(String name) {
    return '\"$name\" will be deleted';
  }

  @override
  String get transformUndo => 'Undo';

  @override
  String get transformRemoveTitle => 'Delete transformer?';

  @override
  String get transformRemoveMessage =>
      'Remove this transformer from the combination?';

  @override
  String get transformApplicationEditHint =>
      'This is an application rule. Changes affect every book that inherits it.';

  @override
  String get transformReorder => 'Drag to reorder';
}
