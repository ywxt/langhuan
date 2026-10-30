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

  /// Reading progress on a bookshelf card showing the current chapter title
  ///
  /// In en, this message translates to:
  /// **'{chapter} · {percent}%'**
  String bookshelfReadingProgressWithChapter(String chapter, int percent);

  /// No description provided for @bookshelfFeedPaused.
  ///
  /// In en, this message translates to:
  /// **'Feed paused'**
  String get bookshelfFeedPaused;

  /// No description provided for @bookshelfFeedPausedHint.
  ///
  /// In en, this message translates to:
  /// **'This feed is paused. The saved book remains readable, but update checks are skipped.'**
  String get bookshelfFeedPausedHint;

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

  /// No description provided for @errorCategoryAuthRequired.
  ///
  /// In en, this message translates to:
  /// **'Login required'**
  String get errorCategoryAuthRequired;

  /// No description provided for @errorCategoryCfChallenge.
  ///
  /// In en, this message translates to:
  /// **'Cloudflare challenge detected'**
  String get errorCategoryCfChallenge;

  /// No description provided for @errorCategoryRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Rate limited'**
  String get errorCategoryRateLimited;

  /// No description provided for @errorCategoryContentNotFound.
  ///
  /// In en, this message translates to:
  /// **'Content not found'**
  String get errorCategoryContentNotFound;

  /// No description provided for @errorCategorySourceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Source unavailable'**
  String get errorCategorySourceUnavailable;

  /// No description provided for @errorCategoryScriptError.
  ///
  /// In en, this message translates to:
  /// **'Script error'**
  String get errorCategoryScriptError;

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

  /// Reader theme option: user-defined colors
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get readerThemeCustom;

  /// Title of the custom reader theme editor
  ///
  /// In en, this message translates to:
  /// **'Custom reader theme'**
  String get readerThemeCustomizeTitle;

  /// Custom reader theme background color label
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get readerThemeBackground;

  /// Custom reader theme text color label
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get readerThemeText;

  /// Custom reader theme accent color label
  ///
  /// In en, this message translates to:
  /// **'Accent'**
  String get readerThemeAccent;

  /// Custom reader theme preview label
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get readerThemePreview;

  /// Sample chapter title in the custom theme preview
  ///
  /// In en, this message translates to:
  /// **'Chapter title'**
  String get readerThemePreviewTitle;

  /// Sample body text in the custom theme preview
  ///
  /// In en, this message translates to:
  /// **'Reading should feel comfortable on every page.'**
  String get readerThemePreviewBody;

  /// Warning when custom reader colors do not have readable contrast
  ///
  /// In en, this message translates to:
  /// **'Choose background and text colors with more contrast.'**
  String get readerThemeContrastWarning;

  /// Reset custom reader theme colors
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get readerThemeReset;

  /// Apply custom reader theme colors
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get readerThemeApply;

  /// Hue control in the reader color picker
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get readerThemeColorHue;

  /// Saturation control in the reader color picker
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get readerThemeColorSaturation;

  /// Brightness control in the reader color picker
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get readerThemeColorBrightness;

  /// Cancel the reader color picker
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get readerThemeColorCancel;

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

  /// Feed detail sheet: base URL label
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get feedDetailBaseUrl;

  /// Feed detail sheet: access domains label
  ///
  /// In en, this message translates to:
  /// **'Access domains'**
  String get feedDetailAccessDomains;

  /// Feed detail sheet: shown when the feed declares no access domain and therefore cannot make requests
  ///
  /// In en, this message translates to:
  /// **'Network access disabled'**
  String get feedDetailNoDomainRestriction;

  /// Feed detail sheet: label for the URL the feed was installed from
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get feedDetailSource;

  /// Feed detail sheet: enabled switch label
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get feedDetailEnabled;

  /// Feed detail sheet: helper text under the enabled switch
  ///
  /// In en, this message translates to:
  /// **'Paused feeds are excluded from aggregated search and update checks.'**
  String get feedDetailEnabledHint;

  /// Feed detail sheet: label for the count of shelved books from this feed
  ///
  /// In en, this message translates to:
  /// **'Shelved books'**
  String get feedDetailBooksLabel;

  /// Feed detail sheet: shelved book count value
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String feedDetailBookCount(int count);

  /// Feed detail sheet: copy-ID button tooltip
  ///
  /// In en, this message translates to:
  /// **'Copy ID'**
  String get feedDetailCopyId;

  /// Snackbar shown after copying the feed ID
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get feedDetailCopied;

  /// Feed detail sheet: delete button label
  ///
  /// In en, this message translates to:
  /// **'Delete feed'**
  String get feedDetailDelete;

  /// Badge on a feed list card whose feed is paused
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get feedItemPaused;

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
  /// **'Sign in on this page, then tap Verify when finished.'**
  String get feedAuthInstructions;

  /// Instructions on the feed login page when the login page runs in a separate native window (Linux/Windows)
  ///
  /// In en, this message translates to:
  /// **'A login window has opened. Sign in there, keep it open, then come back and tap Verify.'**
  String get feedAuthDesktopInstructions;

  /// Hint shown while the native login window is open
  ///
  /// In en, this message translates to:
  /// **'The login window stays open. After signing in, tap Verify in the top bar.'**
  String get feedAuthDesktopWindowHint;

  /// Shown when the native login window has been closed
  ///
  /// In en, this message translates to:
  /// **'The login window was closed. Verification needs the page and cookies from that window — please reopen it.'**
  String get feedAuthWindowClosed;

  /// Button that reopens the native login window
  ///
  /// In en, this message translates to:
  /// **'Reopen login window'**
  String get feedAuthReopenWindow;

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

  /// Tooltip for the auth status refresh button in the feed detail sheet
  ///
  /// In en, this message translates to:
  /// **'Refresh login status'**
  String get feedAuthRefresh;

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

  /// Fallback title for the feed-requested verification page
  ///
  /// In en, this message translates to:
  /// **'Verification'**
  String get webviewVerifyPageTitle;

  /// Button that submits the verification page snapshot
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get webviewVerifyDone;

  /// Instructions shown above the embedded verification WebView
  ///
  /// In en, this message translates to:
  /// **'Complete the verification on this page, then tap \"Done\".'**
  String get webviewVerifyInstructions;

  /// Instructions shown while the verification WebView runs in a separate desktop window
  ///
  /// In en, this message translates to:
  /// **'The verification page opened in a separate window. Complete it there, keep the window open, then come back and tap \"Done\".'**
  String get webviewVerifyDesktopInstructions;

  /// Hint shown while the desktop verification window is open
  ///
  /// In en, this message translates to:
  /// **'The verification window is still open. Once you finish there, tap \"Done\" in the top-right corner.'**
  String get webviewVerifyDesktopWindowHint;

  /// Message shown when the desktop verification window is closed
  ///
  /// In en, this message translates to:
  /// **'The verification window was closed. Verification needs the page and cookies from that window — please reopen it.'**
  String get webviewVerifyWindowClosed;

  /// Button that reopens the desktop verification window
  ///
  /// In en, this message translates to:
  /// **'Reopen verification window'**
  String get webviewVerifyReopenWindow;

  /// Banner shown while the page snapshot is being submitted
  ///
  /// In en, this message translates to:
  /// **'Submitting verification…'**
  String get webviewVerifySubmitting;

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

  /// Tooltip for pausing an enabled feed
  ///
  /// In en, this message translates to:
  /// **'Pause feed'**
  String get feedPause;

  /// Tooltip for resuming a paused feed
  ///
  /// In en, this message translates to:
  /// **'Resume feed'**
  String get feedResume;

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

  /// Security warning title shown before installing feed scripts
  ///
  /// In en, this message translates to:
  /// **'Only install sources you trust'**
  String get feedSecurityWarningTitle;

  /// Security warning body shown before installing feed scripts
  ///
  /// In en, this message translates to:
  /// **'Feed scripts can request data from the listed domains and process login session data. A malicious source could expose private information or consume excessive resources. Review its author and domains before continuing.'**
  String get feedSecurityWarningBody;

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

  /// Shown when access_domains is empty, which blocks every network request
  ///
  /// In en, this message translates to:
  /// **'Network access disabled'**
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

  /// Settings section header for developer tools
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get settingsDeveloper;

  /// Developer tools page title and settings entry label
  ///
  /// In en, this message translates to:
  /// **'Developer tools'**
  String get devToolsTitle;

  /// Subtitle of the developer tools entry in settings
  ///
  /// In en, this message translates to:
  /// **'Feed script debugging environment'**
  String get devToolsEntryDescription;

  /// Snackbar while tapping the version row towards unlocking
  ///
  /// In en, this message translates to:
  /// **'{count} more taps to enable developer tools'**
  String devUnlockCountdown(int count);

  /// Snackbar when the version-row unlock completes
  ///
  /// In en, this message translates to:
  /// **'Developer tools enabled'**
  String get devUnlocked;

  /// Settings row hiding the developer tools again
  ///
  /// In en, this message translates to:
  /// **'Turn off developer tools'**
  String get devDisable;

  /// Confirm dialog title for disabling developer tools
  ///
  /// In en, this message translates to:
  /// **'Turn off developer tools?'**
  String get devDisableConfirmTitle;

  /// Confirm dialog message for disabling developer tools
  ///
  /// In en, this message translates to:
  /// **'This hides the developer tools entry.'**
  String get devDisableConfirmMessage;

  /// Developer page: script editor section label
  ///
  /// In en, this message translates to:
  /// **'Feed script'**
  String get devScriptLabel;

  /// Developer page: script editor explanation
  ///
  /// In en, this message translates to:
  /// **'Paste a JavaScript feed or import one from an installed feed. Scripts run in an isolated native QuickJS sandbox; installed feeds are untouched.'**
  String get devScriptHint;

  /// Developer page: import-from-installed-feed action
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get devScriptImport;

  /// Developer page: import picker sheet title
  ///
  /// In en, this message translates to:
  /// **'Pick an installed feed'**
  String get devScriptImportTitle;

  /// Snackbar when the import picker has nothing to offer
  ///
  /// In en, this message translates to:
  /// **'No installed feeds'**
  String get devScriptImportEmpty;

  /// Developer page: clear-script action
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get devScriptClear;

  /// Confirm dialog title for clearing the script editor
  ///
  /// In en, this message translates to:
  /// **'Clear the script?'**
  String get devScriptClearConfirmTitle;

  /// Confirm dialog message for clearing the script editor
  ///
  /// In en, this message translates to:
  /// **'This empties the editor.'**
  String get devScriptClearConfirmMessage;

  /// Snackbar when running without a script
  ///
  /// In en, this message translates to:
  /// **'Paste or import a script first'**
  String get devScriptMissing;

  /// Snackbar after a script was imported into the editor
  ///
  /// In en, this message translates to:
  /// **'Imported \"{name}\"'**
  String devScriptImported(String name);

  /// Snackbar when reading an installed feed's script fails
  ///
  /// In en, this message translates to:
  /// **'Failed to load the feed script'**
  String get devScriptLoadError;

  /// Run summary chip: stored auth was hydrated
  ///
  /// In en, this message translates to:
  /// **'Using stored login'**
  String get devAuthApplied;

  /// Run summary chip: no auth stored for the feed id
  ///
  /// In en, this message translates to:
  /// **'No stored login'**
  String get devAuthMissing;

  /// Run summary chip: script declares no login block
  ///
  /// In en, this message translates to:
  /// **'Script has no login block'**
  String get devAuthNotSupported;

  /// Stage runner: search stage
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get debugStageSearch;

  /// Stage runner: book_info stage
  ///
  /// In en, this message translates to:
  /// **'Book info'**
  String get debugStageBookInfo;

  /// Stage runner: chapters stage
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get debugStageChapters;

  /// Stage runner: paragraphs stage
  ///
  /// In en, this message translates to:
  /// **'Paragraphs'**
  String get debugStageParagraphs;

  /// Stage runner: auth status probe stage
  ///
  /// In en, this message translates to:
  /// **'Auth status'**
  String get debugStageAuthStatus;

  /// Stage runner input: search keyword
  ///
  /// In en, this message translates to:
  /// **'Keyword'**
  String get debugInputKeyword;

  /// Stage runner input: book id
  ///
  /// In en, this message translates to:
  /// **'Book ID'**
  String get debugInputBookId;

  /// Stage runner input: chapter id
  ///
  /// In en, this message translates to:
  /// **'Chapter ID'**
  String get debugInputChapterId;

  /// Snackbar when a stage input is empty
  ///
  /// In en, this message translates to:
  /// **'Please fill in: {field}'**
  String debugInputMissing(String field);

  /// Stage runner: run button
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get debugRun;

  /// Run summary chip: succeeded
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get debugSummaryOk;

  /// Run summary chip: errored
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get debugSummaryFailed;

  /// Run/entry duration
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String debugDurationMs(int ms);

  /// Error card title
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get debugErrorTitle;

  /// Typed output section title
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get debugOutputTitle;

  /// Empty list output of a clean run
  ///
  /// In en, this message translates to:
  /// **'0 items'**
  String get debugResultEmpty;

  /// Placeholder before the first run
  ///
  /// In en, this message translates to:
  /// **'Paste or import a feed script, pick a pipeline stage and run. The typed output, the error (if any) and the recorded HTTP traffic appear here; runs accumulate in the history below.'**
  String get debugEmptyHint;

  /// Chain action: use this result's id as the book_info input
  ///
  /// In en, this message translates to:
  /// **'Book info'**
  String get debugChainBookInfo;

  /// Chain action: use this chapter's id as the paragraphs input
  ///
  /// In en, this message translates to:
  /// **'Paragraphs'**
  String get debugChainParagraphs;

  /// Book info output field label: id
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get debugFieldId;

  /// Book info output field label: title
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get debugFieldTitle;

  /// Book info output field label: author
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get debugFieldAuthor;

  /// Book info output field label: cover URL
  ///
  /// In en, this message translates to:
  /// **'Cover'**
  String get debugFieldCover;

  /// Book info output field label: description
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get debugFieldDescription;

  /// Prefix marking an image paragraph in the paragraphs output
  ///
  /// In en, this message translates to:
  /// **'image'**
  String get debugImageParagraph;

  /// HTTP trace section title
  ///
  /// In en, this message translates to:
  /// **'HTTP trace ({count})'**
  String debugTraceTitle(int count);

  /// HTTP trace section when nothing was recorded
  ///
  /// In en, this message translates to:
  /// **'No HTTP requests were made.'**
  String get debugTraceEmpty;

  /// HTTP trace note when the entry limit was hit
  ///
  /// In en, this message translates to:
  /// **'{count} further requests were not recorded (trace limit reached).'**
  String debugTraceDropped(int count);

  /// Trace detail row label: response body size
  ///
  /// In en, this message translates to:
  /// **'Response size'**
  String get debugTraceSize;

  /// Trace detail row label: request headers
  ///
  /// In en, this message translates to:
  /// **'Request headers'**
  String get debugTraceHeaders;

  /// Trace detail label: response body preview
  ///
  /// In en, this message translates to:
  /// **'Body preview'**
  String get debugTraceBodyPreview;

  /// Run history section title
  ///
  /// In en, this message translates to:
  /// **'History ({count})'**
  String debugHistoryTitle(int count);
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
