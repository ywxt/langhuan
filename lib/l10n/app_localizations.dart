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

  /// Bottom nav: settings tab
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navProfile;

  /// Bookshelf page title
  ///
  /// In en, this message translates to:
  /// **'Bookshelf'**
  String get bookshelfTitle;

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

  /// Streaming badge at bottom of results
  ///
  /// In en, this message translates to:
  /// **'Loading more…'**
  String get searchLoadingMore;

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

  /// Hint text when current feed supports bookshelf
  ///
  /// In en, this message translates to:
  /// **'This feed supports bookshelf'**
  String get bookDetailSourceSupportsBookshelf;

  /// Hint text when current feed does not support bookshelf
  ///
  /// In en, this message translates to:
  /// **'This feed does not support bookshelf'**
  String get bookDetailSourceNoBookshelf;

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

  /// Snackbar shown when swiping before first chapter
  ///
  /// In en, this message translates to:
  /// **'Already at the first chapter'**
  String get readerAtFirstChapter;

  /// Snackbar shown when swiping after last chapter
  ///
  /// In en, this message translates to:
  /// **'Already at the last chapter'**
  String get readerAtLastChapter;

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
  /// **'No feeds loaded.\nPlease add scripts to the scripts folder.'**
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

  /// Feed list tile trailing icon tooltip
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get feedDetailTooltip;

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

  /// Settings page title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get profileTitle;

  /// Settings page subtitle
  ///
  /// In en, this message translates to:
  /// **'Manage your preferences'**
  String get profileSubtitle;

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

  /// Generic error title
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get errorSomethingWrong;

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

  /// Button label: open file picker for .lua script
  ///
  /// In en, this message translates to:
  /// **'Pick Script File'**
  String get addFeedPickFile;

  /// Section heading for the feed preview card
  ///
  /// In en, this message translates to:
  /// **'Feed Summary'**
  String get addFeedPreviewTitle;

  /// Label for the allowed domains list in the feed preview
  ///
  /// In en, this message translates to:
  /// **'Accesses domains'**
  String get addFeedAllowedDomains;

  /// Shown when allowed_domains is empty
  ///
  /// In en, this message translates to:
  /// **'No domain restrictions'**
  String get addFeedNoDomainRestriction;

  /// Shown when installing a feed that replaces an existing version
  ///
  /// In en, this message translates to:
  /// **'Upgrading {from} → {to}'**
  String addFeedIsUpgrade(String from, String to);

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

  /// Error message when preview fails
  ///
  /// In en, this message translates to:
  /// **'Failed to preview feed'**
  String get addFeedErrorPreview;

  /// Error message when install fails
  ///
  /// In en, this message translates to:
  /// **'Failed to install feed'**
  String get addFeedErrorInstall;
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
