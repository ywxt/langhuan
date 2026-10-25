import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Application name
  ///
  /// In en, this message translates to:
  /// **'Langhuan'**
  String get appName;

  /// Bottom nav: bookshelf tab
  ///
  /// In en, this message translates to:
  /// **'Bookshelf'**
  String get navBookshelf;

  /// Bottom nav: feeds tab
  ///
  /// In en, this message translates to:
  /// **'Feeds'**
  String get navFeeds;

  /// Bookshelf page title
  ///
  /// In en, this message translates to:
  /// **'Bookshelf'**
  String get bookshelfTitle;

  /// Semantics label for a book's update badge
  ///
  /// In en, this message translates to:
  /// **'{count} new chapters'**
  String bookshelfNewChapters(int count);

  /// Snackbar when the update check could not run
  ///
  /// In en, this message translates to:
  /// **'Failed to check for updates'**
  String get bookshelfCheckFailed;

  /// Snackbar when some books failed their individual update check
  ///
  /// In en, this message translates to:
  /// **'Failed to check {count} books'**
  String bookshelfCheckPartialFailure(int count);

  /// Bookshelf empty state message
  ///
  /// In en, this message translates to:
  /// **'Your bookshelf is empty'**
  String get bookshelfEmpty;

  /// Bookshelf empty state secondary message
  ///
  /// In en, this message translates to:
  /// **'Search and save books to see them here'**
  String get bookshelfEmptyHint;

  /// Search bar hint on bookshelf page
  ///
  /// In en, this message translates to:
  /// **'Search books…'**
  String get bookshelfSearchHint;

  /// Bookshelf page load error title
  ///
  /// In en, this message translates to:
  /// **'Failed to load bookshelf'**
  String get bookshelfLoadError;

  /// Snackbar shown after adding a book to local bookshelf
  ///
  /// In en, this message translates to:
  /// **'Added to local bookshelf'**
  String get bookshelfAdded;

  /// Snackbar shown after removing a book from local bookshelf
  ///
  /// In en, this message translates to:
  /// **'Removed from local bookshelf'**
  String get bookshelfRemoved;

  /// Snackbar shown when add/remove bookshelf action fails
  ///
  /// In en, this message translates to:
  /// **'Bookshelf action failed'**
  String get bookshelfActionFailed;

  /// Bookshelf error: app data directory not ready
  ///
  /// In en, this message translates to:
  /// **'App data directory not ready'**
  String get bookshelfErrorAppDataNotReady;

  /// Bookshelf error: add book failed
  ///
  /// In en, this message translates to:
  /// **'Failed to add book'**
  String get bookshelfErrorAddFailed;

  /// Bookshelf error: remove book failed
  ///
  /// In en, this message translates to:
  /// **'Failed to remove book'**
  String get bookshelfErrorRemoveFailed;

  /// Bookshelf error: load bookshelf failed
  ///
  /// In en, this message translates to:
  /// **'Failed to load bookshelf'**
  String get bookshelfErrorLoadFailed;

  /// Bookshelf action that opens book details
  ///
  /// In en, this message translates to:
  /// **'Book Details'**
  String get bookshelfBookDetails;

  /// Title of the bookshelf book deletion confirmation
  ///
  /// In en, this message translates to:
  /// **'Delete book?'**
  String get bookshelfDeleteConfirmTitle;

  /// Bookshelf book deletion confirmation message
  ///
  /// In en, this message translates to:
  /// **'Remove \"{bookTitle}\" from your bookshelf?'**
  String bookshelfDeleteConfirmMessage(String bookTitle);

  /// Warning below the book delete dialog body about cascading data removal
  ///
  /// In en, this message translates to:
  /// **'This also removes the book\'s cached chapters, cover, reading progress, and bookmarks.'**
  String get bookshelfDeleteCascadeWarning;

  /// Cancel bookshelf book deletion
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get bookshelfDeleteCancel;

  /// Confirm bookshelf book deletion
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get bookshelfDeleteConfirm;

  /// Snackbar before a bookshelf deletion is committed
  ///
  /// In en, this message translates to:
  /// **'\"{bookTitle}\" will be removed from your bookshelf'**
  String bookshelfDeleteQueued(String bookTitle);

  /// Undo a pending bookshelf deletion
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get bookshelfDeleteUndo;

  /// Chapter-level reading progress shown on a bookshelf card
  ///
  /// In en, this message translates to:
  /// **'Chapter {current} of {total} · {percent}%'**
  String bookshelfReadingProgress(int current, int total, int percent);

  /// Search page title
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchTitle;

  /// Search bar hint when no feed is selected
  ///
  /// In en, this message translates to:
  /// **'Select a feed first…'**
  String get searchHintNoFeed;

  /// Search bar hint when the aggregated all-feeds search is selected
  ///
  /// In en, this message translates to:
  /// **'Search across all feeds…'**
  String get searchHintAllFeeds;

  /// Feed selector chip that searches every feed
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get searchAllFeeds;

  /// Header of a failed source's section in aggregated results
  ///
  /// In en, this message translates to:
  /// **'Failed to search {feedName}'**
  String searchSourceFailed(Object feedName);

  /// Search bar hint when a feed is selected
  ///
  /// In en, this message translates to:
  /// **'Search in {feedName}…'**
  String searchHintWithFeed(String feedName);

  /// Cancel search button tooltip
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get searchCancel;

  /// Clear search button tooltip
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchClear;

  /// Search empty state: no keyword yet
  ///
  /// In en, this message translates to:
  /// **'Enter a keyword to start searching'**
  String get searchEmptyPrompt;

  /// Search empty state: keyword entered but no results
  ///
  /// In en, this message translates to:
  /// **'No results for \"{keyword}\"'**
  String searchNoResults(String keyword);

  /// Search error title
  ///
  /// In en, this message translates to:
  /// **'Search failed'**
  String get searchError;

  /// Retry button label
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get searchRetry;

  /// Book detail page title
  ///
  /// In en, this message translates to:
  /// **'Book Details'**
  String get bookDetailTitle;

  /// Book detail page error title
  ///
  /// In en, this message translates to:
  /// **'Failed to load book details'**
  String get bookDetailError;

  /// Retry button label on book detail page
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get bookDetailRetry;

  /// Primary action button on book detail page
  ///
  /// In en, this message translates to:
  /// **'Start Reading'**
  String get bookDetailStartReading;

  /// Primary action button when reading progress exists
  ///
  /// In en, this message translates to:
  /// **'Continue Reading'**
  String get bookDetailContinueReading;

  /// Subtitle under the continue button showing last-read chapter
  ///
  /// In en, this message translates to:
  /// **'Last read: {chapterTitle}'**
  String bookDetailLastReadChapter(String chapterTitle);

  /// Fallback text when description is empty
  ///
  /// In en, this message translates to:
  /// **'No description available'**
  String get bookDetailNoDescription;

  /// Chapter section title with chapter count
  ///
  /// In en, this message translates to:
  /// **'Chapters ({count})'**
  String bookDetailChapters(int count);

  /// Chapter list load error title
  ///
  /// In en, this message translates to:
  /// **'Failed to load chapters'**
  String get bookDetailChaptersError;

  /// Shown when route params are missing
  ///
  /// In en, this message translates to:
  /// **'Missing book parameters'**
  String get bookDetailMissingParams;

  /// Fallback when no book data is returned
  ///
  /// In en, this message translates to:
  /// **'No book information available'**
  String get bookDetailEmpty;

  /// Button label to add current book to local bookshelf
  ///
  /// In en, this message translates to:
  /// **'Add to Local Bookshelf'**
  String get bookDetailAddBookshelf;

  /// Button label to remove current book from local bookshelf
  ///
  /// In en, this message translates to:
  /// **'Remove from Local Bookshelf'**
  String get bookDetailRemoveBookshelf;

  /// Reader page title fallback
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get readerTitle;

  /// Shown when reader route params are missing
  ///
  /// In en, this message translates to:
  /// **'Missing reading parameters'**
  String get readerMissingParams;

  /// Snackbar when a custom font file could not be loaded in the reader settings sheet
  ///
  /// In en, this message translates to:
  /// **'Failed to load font file'**
  String get readerFontLoadFailed;

  /// Label above the custom font picker in the reader font sheet
  ///
  /// In en, this message translates to:
  /// **'Font File'**
  String get readerFontFileLabel;

  /// Shown when no custom font is selected
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get readerFontSystemDefault;

  /// Button that opens the font file picker
  ///
  /// In en, this message translates to:
  /// **'Choose Font File'**
  String get readerFontChoose;

  /// Button to clear the custom font selection
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get readerFontReset;

  /// Font scale slider label
  ///
  /// In en, this message translates to:
  /// **'Font {scale}x'**
  String readerFontScale(String scale);

  /// Letter spacing slider label
  ///
  /// In en, this message translates to:
  /// **'Letter Spacing {value}'**
  String readerLetterSpacing(String value);

  /// Paragraph spacing slider label
  ///
  /// In en, this message translates to:
  /// **'Paragraph Spacing {value}'**
  String readerParagraphSpacing(String value);

  /// Line height slider label
  ///
  /// In en, this message translates to:
  /// **'Line Height {value}'**
  String readerLineHeight(String value);

  /// Reader page content load error title
  ///
  /// In en, this message translates to:
  /// **'Failed to load chapter'**
  String get readerLoadError;

  /// Reader page empty content state
  ///
  /// In en, this message translates to:
  /// **'No chapter content available'**
  String get readerEmpty;

  /// Reader page previous chapter button label
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get readerPrevChapter;

  /// Reader page next chapter button label
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get readerNextChapter;

  /// Reader page chapter progress indicator
  ///
  /// In en, this message translates to:
  /// **'Chapter {current} / {total}'**
  String readerChapterProgress(int current, int total);

  /// Reader mode toggle label: vertical scroll
  ///
  /// In en, this message translates to:
  /// **'Vertical Scroll'**
  String get readerModeVertical;

  /// Reader mode toggle label: horizontal paging
  ///
  /// In en, this message translates to:
  /// **'Horizontal Paging'**
  String get readerModeHorizontal;

  /// Section label above the reader mode toggle
  ///
  /// In en, this message translates to:
  /// **'Reading Mode'**
  String get readerModeLabel;

  /// Message shown after the last chapter of the book
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached the end of the book'**
  String get readerEndOfBook;

  /// Loading indicator text shown while a chapter is being fetched
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get readerLoading;

  /// Error shown when chapter content failed to load
  ///
  /// In en, this message translates to:
  /// **'Failed to load chapter'**
  String get readerChapterLoadError;

  /// Retry action label for chapter loading failures
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get readerRetry;

  /// Reader bottom bar button: table of contents
  ///
  /// In en, this message translates to:
  /// **'TOC'**
  String get readerToc;

  /// Reader bottom bar button: interface settings
  ///
  /// In en, this message translates to:
  /// **'Interface'**
  String get readerInterface;

  /// Reader bottom bar button: settings placeholder
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get readerSettings;

  /// Reader action to refresh current chapter
  ///
  /// In en, this message translates to:
  /// **'Refresh Chapter'**
  String get readerRefreshChapter;

  /// Reader bookmark list title
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get readerBookmarks;

  /// Snackbar after adding a bookmark
  ///
  /// In en, this message translates to:
  /// **'Bookmark added'**
  String get readerBookmarkAdded;

  /// Snackbar after removing a bookmark
  ///
  /// In en, this message translates to:
  /// **'Bookmark removed'**
  String get readerBookmarkRemoved;

  /// Bookmark list empty state
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet'**
  String get readerNoBookmarks;

  /// Popup menu item for adding a bookmark on long press
  ///
  /// In en, this message translates to:
  /// **'Add Bookmark'**
  String get readerAddBookmark;

  /// Search input hint in TOC bottom sheet
  ///
  /// In en, this message translates to:
  /// **'Search chapters'**
  String get readerSearchTocHint;

  /// Search input hint in bookmarks bottom sheet
  ///
  /// In en, this message translates to:
  /// **'Search bookmarks'**
  String get readerSearchBookmarksHint;

  /// Reader theme option: follow system
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get readerThemeSystem;

  /// Reader theme option: light
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get readerThemeLight;

  /// Reader theme option: dark
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get readerThemeDark;

  /// Reader theme option: sepia
  ///
  /// In en, this message translates to:
  /// **'Sepia'**
  String get readerThemeSepia;

  /// Reader settings section label: theme
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get readerThemeLabel;

  /// Reader TOC/bookmark sheet filter no match message
  ///
  /// In en, this message translates to:
  /// **'Nothing matching \"{keyword}\"'**
  String readerSearchNoMatch(String keyword);

  /// Placeholder text in reader settings sheet
  ///
  /// In en, this message translates to:
  /// **'This entry is reserved for future settings.'**
  String get readerSettingPlaceholder;

  /// Reader settings: Chinese conversion label
  ///
  /// In en, this message translates to:
  /// **'Chinese Conversion'**
  String get readerChineseConversion;

  /// Chinese conversion mode: no conversion
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get chineseConversionNone;

  /// Chinese conversion mode: simplified to traditional
  ///
  /// In en, this message translates to:
  /// **'Simplified → Traditional'**
  String get chineseConversionS2t;

  /// Chinese conversion mode: traditional to simplified
  ///
  /// In en, this message translates to:
  /// **'Traditional → Simplified'**
  String get chineseConversionT2s;

  /// Chinese conversion mode: simplified to Taiwan traditional
  ///
  /// In en, this message translates to:
  /// **'Simplified → Taiwan Traditional'**
  String get chineseConversionS2tw;

  /// Chinese conversion mode: simplified to Hong Kong traditional
  ///
  /// In en, this message translates to:
  /// **'Simplified → Hong Kong Traditional'**
  String get chineseConversionS2hk;

  /// Feeds page title
  ///
  /// In en, this message translates to:
  /// **'Feeds'**
  String get feedsTitle;

  /// Local filter search bar hint on feeds page
  ///
  /// In en, this message translates to:
  /// **'Search feeds…'**
  String get feedsSearchHint;

  /// Feeds empty state message
  ///
  /// In en, this message translates to:
  /// **'No feeds yet.\nAdd a feed to get started.'**
  String get feedsEmpty;

  /// Feeds local filter no match message
  ///
  /// In en, this message translates to:
  /// **'No feeds matching \"{keyword}\"'**
  String feedsNoMatch(String keyword);

  /// Feeds load error message
  ///
  /// In en, this message translates to:
  /// **'Failed to load feeds'**
  String get feedsLoadError;

  /// Retry button on feeds error state
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get feedsRetry;

  /// Feed detail sheet: ID label
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get feedDetailId;

  /// Feed detail sheet: version label
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get feedDetailVersion;

  /// Feed detail sheet: author label
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get feedDetailAuthor;

  /// Feed detail auth section label
  ///
  /// In en, this message translates to:
  /// **'Auth'**
  String get feedAuthLabel;

  /// Feed auth status when logged in
  ///
  /// In en, this message translates to:
  /// **'Logged in'**
  String get feedAuthStatusLoggedIn;

  /// Feed auth status when logged out
  ///
  /// In en, this message translates to:
  /// **'Logged out'**
  String get feedAuthStatusLoggedOut;

  /// Feed auth status when login has expired
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get feedAuthStatusExpired;

  /// Feed auth status when auth is not supported
  ///
  /// In en, this message translates to:
  /// **'Unsupported'**
  String get feedAuthStatusUnsupported;

  /// Feed auth login button label
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get feedAuthLogin;

  /// Feed auth logout button label
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get feedAuthLogout;

  /// Feed auth webview page title
  ///
  /// In en, this message translates to:
  /// **'Feed Login'**
  String get feedAuthPageTitle;

  /// Feed auth submit button label
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get feedAuthDone;

  /// Instructions shown above the feed login WebView
  ///
  /// In en, this message translates to:
  /// **'Sign in on this page. Login will be detected automatically, or tap Verify when finished.'**
  String get feedAuthInstructions;

  /// Status shown while feed auth is extracted and verified
  ///
  /// In en, this message translates to:
  /// **'Verifying login…'**
  String get feedAuthVerifying;

  /// Feed auth page message when auth is unsupported
  ///
  /// In en, this message translates to:
  /// **'This feed does not support login.'**
  String get feedAuthNotSupported;

  /// Snackbar after successful auth page submit
  ///
  /// In en, this message translates to:
  /// **'Login verified'**
  String get feedAuthUpdated;

  /// Snackbar after feed auth clear
  ///
  /// In en, this message translates to:
  /// **'Logged out'**
  String get feedAuthLoggedOut;

  /// Hint shown on search error when feed supports auth
  ///
  /// In en, this message translates to:
  /// **'This source may require login'**
  String get searchAuthHint;

  /// Action button for opening feed auth flow from search
  ///
  /// In en, this message translates to:
  /// **'Login Source'**
  String get searchAuthAction;

  /// Label for per-feed compile error in detail sheet
  ///
  /// In en, this message translates to:
  /// **'Load error'**
  String get feedItemLoadError;

  /// Dialog title when confirming feed deletion
  ///
  /// In en, this message translates to:
  /// **'Delete feed?'**
  String get feedDeleteConfirmTitle;

  /// Dialog body for feed deletion confirmation
  ///
  /// In en, this message translates to:
  /// **'Delete \"{feedName}\" from your feeds?'**
  String feedDeleteConfirmMessage(String feedName);

  /// Cancel button in feed delete confirmation dialog
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get feedDeleteCancel;

  /// Confirm button in feed delete confirmation dialog
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get feedDeleteConfirm;

  /// Warning below the feed delete dialog body about cascading data removal
  ///
  /// In en, this message translates to:
  /// **'This also removes the feed\'s cached books, covers, reading progress, and bookmarks.'**
  String get feedDeleteCascadeWarning;

  /// Snackbar shown when feed deletion succeeds
  ///
  /// In en, this message translates to:
  /// **'{feedName} removed'**
  String feedDeleteSuccess(String feedName);

  /// Snackbar prefix for feed deletion failure
  ///
  /// In en, this message translates to:
  /// **'Failed to delete feed'**
  String get feedDeleteError;

  /// Pausing/resuming a feed failed
  ///
  /// In en, this message translates to:
  /// **'Failed to switch feed'**
  String get feedToggleError;

  /// Menu item: import feeds from a file
  ///
  /// In en, this message translates to:
  /// **'Import feeds'**
  String get feedsMenuImport;

  /// Menu item: export all feeds to a file
  ///
  /// In en, this message translates to:
  /// **'Export feeds'**
  String get feedsMenuExport;

  /// Snack: the feeds file was written
  ///
  /// In en, this message translates to:
  /// **'Feed export saved'**
  String get feedsExported;

  /// Snack: export attempted with an empty registry
  ///
  /// In en, this message translates to:
  /// **'No feeds to export'**
  String get feedsExportNone;

  /// Snack: feed export failed
  ///
  /// In en, this message translates to:
  /// **'Failed to export feeds'**
  String get feedsExportError;

  /// Snack: feed import failed (unreadable file, bad format)
  ///
  /// In en, this message translates to:
  /// **'Failed to import feeds'**
  String get feedsImportError;

  /// Dialog title: confirm a feed import
  ///
  /// In en, this message translates to:
  /// **'Import feeds'**
  String get feedsImportTitle;

  /// Dialog button: run the import
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get feedsImportConfirm;

  /// Dialog subtitle: number of entries in the file
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 feed found} other{{count} feeds found}}'**
  String feedsImportCount(num count);

  /// Snack: import summary
  ///
  /// In en, this message translates to:
  /// **'Installed {installed}, skipped {skipped}, failed {failed}'**
  String feedsImportResult(Object failed, Object installed, Object skipped);

  /// Badge: entry not installed yet
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get feedsImportChangeNew;

  /// Badge: entry newer than installed
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get feedsImportChangeUpgrade;

  /// Badge: entry older than installed
  ///
  /// In en, this message translates to:
  /// **'Downgrade'**
  String get feedsImportChangeDowngrade;

  /// Badge: entry identical to installed (will skip)
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get feedsImportChangeSame;

  /// Badge: version not comparable
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get feedsImportChangeUnknown;

  /// Settings row: write a full data snapshot
  ///
  /// In en, this message translates to:
  /// **'Export backup'**
  String get settingsBackup;

  /// Settings row subtitle for the backup row
  ///
  /// In en, this message translates to:
  /// **'Save sources, shelf, reading progress and bookmarks to a file'**
  String get settingsBackupDescription;

  /// Snack: the backup file was written
  ///
  /// In en, this message translates to:
  /// **'Backup saved'**
  String get settingsBackupSuccess;

  /// Snack: backup export failed
  ///
  /// In en, this message translates to:
  /// **'Failed to export backup'**
  String get settingsBackupError;

  /// Snackbar when user tries delete while another delete is running
  ///
  /// In en, this message translates to:
  /// **'Another feed operation is in progress'**
  String get feedDeleteBusy;

  /// Snackbar shown right after swipe delete, before commit
  ///
  /// In en, this message translates to:
  /// **'\"{feedName}\" will be deleted'**
  String feedDeleteQueued(String feedName);

  /// Snackbar action label to cancel pending feed deletion
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get feedDeleteUndo;

  /// Search page: no feeds available message
  ///
  /// In en, this message translates to:
  /// **'No feeds available. Add scripts in the Feeds tab first.'**
  String get feedSelectorNoFeeds;

  /// Bottom nav: settings tab
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Settings page title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Settings section: about
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// Settings row: app version
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// Settings row: open source licenses
  ///
  /// In en, this message translates to:
  /// **'Licenses'**
  String get settingsLicenses;

  /// Add feed source page/sheet title
  ///
  /// In en, this message translates to:
  /// **'Add Feed Source'**
  String get addFeedTitle;

  /// Tab label: add feed from a network URL
  ///
  /// In en, this message translates to:
  /// **'From URL'**
  String get addFeedTabUrl;

  /// Description for the URL source option
  ///
  /// In en, this message translates to:
  /// **'Import a feed source script from a web address'**
  String get addFeedTabUrlDesc;

  /// Tab label: add feed from a local file
  ///
  /// In en, this message translates to:
  /// **'From File'**
  String get addFeedTabFile;

  /// Description for the file source option
  ///
  /// In en, this message translates to:
  /// **'Import a feed source script from local storage'**
  String get addFeedTabFileDesc;

  /// TextField hint for URL input
  ///
  /// In en, this message translates to:
  /// **'Enter script URL…'**
  String get addFeedUrlHint;

  /// Button label: preview feed from URL
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get addFeedUrlPreview;

  /// Section heading for the feed preview card
  ///
  /// In en, this message translates to:
  /// **'Feed Summary'**
  String get addFeedPreviewTitle;

  /// Label for the access domains list in the feed preview
  ///
  /// In en, this message translates to:
  /// **'Accesses domains'**
  String get addFeedAllowedDomains;

  /// Shown when access_domains is empty
  ///
  /// In en, this message translates to:
  /// **'No domain restrictions'**
  String get addFeedNoDomainRestriction;

  /// Shown when installing a feed that replaces an existing version
  ///
  /// In en, this message translates to:
  /// **'Upgrading {from} → {to}'**
  String addFeedIsUpgrade(String from, String to);

  /// Shown when the previewed feed is not installed yet
  ///
  /// In en, this message translates to:
  /// **'New feed'**
  String get addFeedBadgeNew;

  /// Shown when installing a feed older than the installed version
  ///
  /// In en, this message translates to:
  /// **'Downgrading {from} → {to}'**
  String addFeedIsDowngrade(String from, String to);

  /// Shown when the previewed version matches the installed one
  ///
  /// In en, this message translates to:
  /// **'Same version as installed'**
  String get addFeedIsSame;

  /// Shown when either version is not valid SemVer, so no relation can be derived
  ///
  /// In en, this message translates to:
  /// **'Installed {from}; installing {to}'**
  String addFeedVersionUnknown(String from, String to);

  /// Button label: confirm feed installation
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get addFeedInstall;

  /// Snackbar message on successful install
  ///
  /// In en, this message translates to:
  /// **'Feed installed successfully'**
  String get addFeedSuccess;

  /// Settings section: reading preferences
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get settingsReading;

  /// Settings row: Chinese text conversion mode
  ///
  /// In en, this message translates to:
  /// **'Chinese Conversion'**
  String get settingsChineseConversion;

  /// Subtitle for Chinese conversion setting
  ///
  /// In en, this message translates to:
  /// **'Auto-convert Chinese text while reading'**
  String get settingsChineseConversionDescription;

  /// Settings section: storage management
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// Settings row: clean up old cache data
  ///
  /// In en, this message translates to:
  /// **'Clear stale cache'**
  String get settingsCleanupCache;

  /// Subtitle for the cache cleanup row
  ///
  /// In en, this message translates to:
  /// **'Remove cached data and reading progress older than 15 days (bookshelf items are preserved)'**
  String get settingsCleanupCacheDescription;

  /// Snackbar after successful cleanup
  ///
  /// In en, this message translates to:
  /// **'{count} items cleaned up'**
  String settingsCleanupSuccess(int count);

  /// Snackbar when cleanup removes nothing
  ///
  /// In en, this message translates to:
  /// **'Nothing to clean up'**
  String get settingsCleanupNothingToClean;

  /// Snackbar when cleanup encounters an error
  ///
  /// In en, this message translates to:
  /// **'Cleanup failed'**
  String get settingsCleanupError;

  /// Storage stats row: total size of the database file
  ///
  /// In en, this message translates to:
  /// **'Database size'**
  String get settingsStorageDatabaseSize;

  /// Storage stats row: payload bytes in the cache tables
  ///
  /// In en, this message translates to:
  /// **'Cache size'**
  String get settingsStorageCacheSize;

  /// Storage stats chip: cached book rows
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get settingsStorageBooks;

  /// Storage stats chip: cached chapter contents
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get settingsStorageChapters;

  /// Storage stats chip: downloaded covers
  ///
  /// In en, this message translates to:
  /// **'Covers'**
  String get settingsStorageCovers;

  /// Storage stats chip: books on the bookshelf
  ///
  /// In en, this message translates to:
  /// **'On shelf'**
  String get settingsStorageBookshelfCount;

  /// Settings row: remove all cached chapters and covers
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get settingsClearCache;

  /// Subtitle for the clear cache row
  ///
  /// In en, this message translates to:
  /// **'Remove all cached chapters and covers; bookshelf, progress, and bookmarks are kept'**
  String get settingsClearCacheDescription;

  /// Dialog title for the clear cache confirmation
  ///
  /// In en, this message translates to:
  /// **'Clear cache?'**
  String get settingsClearCacheConfirmTitle;

  /// Dialog body for the clear cache confirmation
  ///
  /// In en, this message translates to:
  /// **'Clear all cached data?'**
  String get settingsClearCacheConfirmMessage;

  /// Neutral note block in the clear cache dialog about what is removed and kept
  ///
  /// In en, this message translates to:
  /// **'Cached chapters and covers will be removed and re-downloaded when needed. Reading progress and bookmarks are kept.'**
  String get settingsClearCacheNote;

  /// Snackbar after the cache was cleared
  ///
  /// In en, this message translates to:
  /// **'Cache cleared — {bytes} freed'**
  String settingsClearCacheSuccess(String bytes);

  /// Snackbar when there was nothing in the cache
  ///
  /// In en, this message translates to:
  /// **'Cache is already empty'**
  String get settingsClearCacheNothing;

  /// Snackbar when clearing the cache fails
  ///
  /// In en, this message translates to:
  /// **'Failed to clear cache'**
  String get settingsClearCacheError;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
