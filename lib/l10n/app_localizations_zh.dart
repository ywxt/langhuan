// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '琅嬛';

  @override
  String get navBookshelf => '書架';

  @override
  String get navFeeds => '書源';

  @override
  String get bookshelfTitle => '書架';

  @override
  String bookshelfNewChapters(int count) {
    return '$count 個新章節';
  }

  @override
  String get bookshelfCheckFailed => '檢查更新失敗';

  @override
  String bookshelfCheckPartialFailure(int count) {
    return '$count 本書檢查失敗';
  }

  @override
  String get bookshelfEmpty => '書架是空的';

  @override
  String get bookshelfEmptyHint => '搜索並收藏書籍後會顯示在這裡';

  @override
  String get bookshelfSearchHint => '搜索書籍…';

  @override
  String get bookshelfLoadError => '加載書架失敗';

  @override
  String get bookshelfAdded => '已加入本地書架';

  @override
  String get bookshelfRemoved => '已從本地書架移除';

  @override
  String get bookshelfActionFailed => '書架操作失敗';

  @override
  String get bookshelfErrorAppDataNotReady => '應用數據目錄未準備就緒';

  @override
  String get bookshelfErrorAddFailed => '添加書籍失敗';

  @override
  String get bookshelfErrorRemoveFailed => '移除書籍失敗';

  @override
  String get bookshelfErrorLoadFailed => '加載書架失敗';

  @override
  String get bookshelfBookDetails => '書籍詳情';

  @override
  String get bookshelfDeleteConfirmTitle => '刪除書籍？';

  @override
  String bookshelfDeleteConfirmMessage(String bookTitle) {
    return '確定要從書架刪除「$bookTitle」嗎？';
  }

  @override
  String get bookshelfDeleteCascadeWarning => '這也會刪除該書的快取章節、封面、閱讀進度與書籤。';

  @override
  String get bookshelfDeleteCancel => '取消';

  @override
  String get bookshelfDeleteConfirm => '刪除';

  @override
  String bookshelfDeleteQueued(String bookTitle) {
    return '「$bookTitle」將從書架移除';
  }

  @override
  String get bookshelfDeleteUndo => '撤銷';

  @override
  String bookshelfReadingProgress(int current, int total, int percent) {
    return '第 $current/$total 章 · $percent%';
  }

  @override
  String bookshelfReadingProgressWithChapter(String chapter, int percent) {
    return '$chapter · $percent%';
  }

  @override
  String get bookshelfFeedPaused => '書源已暫停';

  @override
  String get bookshelfFeedPausedHint => '書源已暫停；已收藏書籍仍可閱讀，但不會檢查更新。';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHintNoFeed => '請先選擇書源…';

  @override
  String get searchHintAllFeeds => '在全部書源中搜索…';

  @override
  String get searchAllFeeds => '全部';

  @override
  String searchSourceFailed(Object feedName) {
    return '「$feedName」搜索失敗';
  }

  @override
  String searchHintWithFeed(String feedName) {
    return '在 $feedName 中搜索…';
  }

  @override
  String get searchCancel => '取消';

  @override
  String get searchClear => '清除';

  @override
  String get searchEmptyPrompt => '輸入關鍵詞開始搜索';

  @override
  String searchNoResults(String keyword) {
    return '「$keyword」無搜索結果';
  }

  @override
  String get searchError => '搜索出錯';

  @override
  String get searchRetry => '重試';

  @override
  String get bookDetailTitle => '書籍詳情';

  @override
  String get bookDetailError => '加載書籍信息失敗';

  @override
  String get bookDetailRetry => '重試';

  @override
  String get bookDetailStartReading => '開始閱讀';

  @override
  String get bookDetailContinueReading => '繼續閱讀';

  @override
  String bookDetailLastReadChapter(String chapterTitle) {
    return '上次讀到：$chapterTitle';
  }

  @override
  String get bookDetailNoDescription => '暫無簡介';

  @override
  String bookDetailChapters(int count) {
    return '章節（$count）';
  }

  @override
  String get bookDetailChaptersError => '加載章節失敗';

  @override
  String get bookDetailMissingParams => '缺少書籍參數';

  @override
  String get bookDetailEmpty => '暫無書籍信息';

  @override
  String get bookDetailAddBookshelf => '加入本地書架';

  @override
  String get bookDetailRemoveBookshelf => '從本地書架移除';

  @override
  String get readerTitle => '閱讀';

  @override
  String get readerMissingParams => '缺少閱讀參數';

  @override
  String get readerFontLoadFailed => '字體檔案載入失敗';

  @override
  String get readerFontFileLabel => '字體檔案';

  @override
  String get readerFontSystemDefault => '系統默認';

  @override
  String get readerFontChoose => '選擇字體檔案';

  @override
  String get readerFontReset => '重設';

  @override
  String readerFontScale(String scale) {
    return '字體 ${scale}x';
  }

  @override
  String readerLetterSpacing(String value) {
    return '字距 $value';
  }

  @override
  String readerParagraphSpacing(String value) {
    return '段落間距 $value';
  }

  @override
  String readerLineHeight(String value) {
    return '行高 $value';
  }

  @override
  String get readerLoadError => '加載章節失敗';

  @override
  String get readerEmpty => '暫無章節正文';

  @override
  String get readerPrevChapter => '上一章';

  @override
  String get readerNextChapter => '下一章';

  @override
  String readerChapterProgress(int current, int total) {
    return '第 $current / $total 章';
  }

  @override
  String get readerModeVertical => '上下滑動';

  @override
  String get readerModeHorizontal => '左右翻頁';

  @override
  String get readerModeLabel => '閱讀方式';

  @override
  String get readerEndOfBook => '已讀完全書';

  @override
  String get readerLoading => '加載中…';

  @override
  String get readerChapterLoadError => '章節加載失敗';

  @override
  String get readerRetry => '重試';

  @override
  String get readerToc => '目錄';

  @override
  String get readerInterface => '界面';

  @override
  String get readerSettings => '設置';

  @override
  String get readerRefreshChapter => '刷新本章';

  @override
  String get readerBookmarks => '書籤';

  @override
  String get readerBookmarkAdded => '已添加書籤';

  @override
  String get readerBookmarkRemoved => '已刪除書籤';

  @override
  String get readerNoBookmarks => '暫無書籤';

  @override
  String get readerAddBookmark => '添加書籤';

  @override
  String get readerSearchTocHint => '搜索章節';

  @override
  String get readerSearchBookmarksHint => '搜索書籤';

  @override
  String get readerThemeSystem => '跟隨系統';

  @override
  String get readerThemeLight => '淺色';

  @override
  String get readerThemeDark => '深色';

  @override
  String get readerThemeSepia => '護眼';

  @override
  String get readerThemeCustom => '自定義';

  @override
  String get readerThemeCustomizeTitle => '自定義閱讀主題';

  @override
  String get readerThemeBackground => '背景';

  @override
  String get readerThemeText => '文字';

  @override
  String get readerThemeAccent => '強調色';

  @override
  String get readerThemePreview => '預覽';

  @override
  String get readerThemePreviewTitle => '章節標題';

  @override
  String get readerThemePreviewBody => '讓每一頁都有舒適的閱讀體驗。';

  @override
  String get readerThemeContrastWarning => '請選擇對比更明顯的背景色與文字色。';

  @override
  String get readerThemeReset => '重置';

  @override
  String get readerThemeApply => '應用';

  @override
  String get readerThemeColorHue => '色相';

  @override
  String get readerThemeColorSaturation => '飽和度';

  @override
  String get readerThemeColorBrightness => '亮度';

  @override
  String get readerThemeColorCancel => '取消';

  @override
  String get readerThemeLabel => '主題';

  @override
  String readerSearchNoMatch(String keyword) {
    return '沒有符合「$keyword」的內容';
  }

  @override
  String get readerSettingPlaceholder => '此入口預留，後續擴展。';

  @override
  String get readerChineseConversion => '繁簡轉換';

  @override
  String get chineseConversionNone => '不轉換';

  @override
  String get chineseConversionS2t => '簡體轉繁體';

  @override
  String get chineseConversionT2s => '繁體轉簡體';

  @override
  String get chineseConversionS2tw => '簡體 → 臺灣正體';

  @override
  String get chineseConversionS2hk => '簡體 → 香港繁體';

  @override
  String get feedsTitle => '書源';

  @override
  String get feedsSearchHint => '搜索書源…';

  @override
  String get feedsEmpty => '暫無書源\n請添加書源以開始使用';

  @override
  String feedsNoMatch(String keyword) {
    return '未找到匹配的書源「$keyword」';
  }

  @override
  String get feedsLoadError => '加載書源失敗';

  @override
  String get feedsRetry => '重試';

  @override
  String get feedDetailId => 'ID';

  @override
  String get feedDetailBaseUrl => '主站網址';

  @override
  String get feedDetailAccessDomains => '允許訪問的域名';

  @override
  String get feedDetailNoDomainRestriction => '無域名限制';

  @override
  String get feedDetailSource => '來源';

  @override
  String get feedDetailEnabled => '啟用書源';

  @override
  String get feedDetailEnabledHint => '暫停的書源不參與聚合搜索與更新檢查。';

  @override
  String get feedDetailBooksLabel => '書架書籍';

  @override
  String feedDetailBookCount(int count) {
    return '$count 本';
  }

  @override
  String get feedDetailCopyId => '複製 ID';

  @override
  String get feedDetailCopied => '已複製';

  @override
  String get feedDetailDelete => '刪除書源';

  @override
  String get feedItemPaused => '已暫停';

  @override
  String get feedAuthLabel => '登錄';

  @override
  String get feedAuthStatusLoggedIn => '已登錄';

  @override
  String get feedAuthStatusLoggedOut => '未登錄';

  @override
  String get feedAuthStatusExpired => '登錄已過期';

  @override
  String get feedAuthStatusUnsupported => '不支持';

  @override
  String get feedAuthLogin => '登錄';

  @override
  String get feedAuthLogout => '登出';

  @override
  String get feedAuthPageTitle => '書源登錄';

  @override
  String get feedAuthDone => '驗證登錄';

  @override
  String get feedAuthInstructions => '請在此網頁完成登錄，然後點擊「驗證登錄」。';

  @override
  String get feedAuthDesktopInstructions =>
      '已在單獨的窗口中打開登錄頁。請在該窗口完成登錄，保持窗口開啟，然後回到本頁點擊「驗證登錄」。';

  @override
  String get feedAuthDesktopWindowHint => '登錄窗口保持開啟中。完成登錄後，點擊右上角的「驗證登錄」。';

  @override
  String get feedAuthWindowClosed => '登錄窗口已關閉。驗證登錄需要讀取窗口中的頁面與 cookies，請重新打開。';

  @override
  String get feedAuthReopenWindow => '重新打開登錄窗口';

  @override
  String get feedAuthVerifying => '正在驗證登錄…';

  @override
  String get feedAuthNotSupported => '此書源不支持登錄。';

  @override
  String get feedAuthUpdated => '登錄驗證成功';

  @override
  String get feedAuthLoggedOut => '已登出';

  @override
  String get feedAuthRefresh => '刷新登錄狀態';

  @override
  String get searchAuthHint => '此書源可能需要先登錄';

  @override
  String get searchAuthAction => '去登錄';

  @override
  String get feedItemLoadError => '加載失敗';

  @override
  String get feedDeleteConfirmTitle => '刪除書源？';

  @override
  String feedDeleteConfirmMessage(String feedName) {
    return '確定要刪除「$feedName」嗎？';
  }

  @override
  String get feedDeleteCancel => '取消';

  @override
  String get feedDeleteConfirm => '刪除';

  @override
  String get feedDeleteCascadeWarning => '這也會刪除該書源的快取書籍、封面、閱讀進度與書籤。';

  @override
  String feedDeleteSuccess(String feedName) {
    return '已刪除 $feedName';
  }

  @override
  String get feedDeleteError => '刪除書源失敗';

  @override
  String get feedToggleError => '切換書源狀態失敗';

  @override
  String get feedPause => '暫停書源';

  @override
  String get feedResume => '恢復書源';

  @override
  String get feedsMenuImport => '導入書源';

  @override
  String get feedsMenuExport => '導出書源';

  @override
  String get feedsExported => '書源已導出';

  @override
  String get feedsExportNone => '沒有可導出的書源';

  @override
  String get feedsExportError => '導出書源失敗';

  @override
  String get feedsImportError => '導入書源失敗';

  @override
  String get feedsImportTitle => '導入書源';

  @override
  String get feedsImportConfirm => '導入';

  @override
  String feedsImportCount(num count) {
    return '共找到 $count 個書源';
  }

  @override
  String feedsImportResult(Object failed, Object installed, Object skipped) {
    return '已安裝 $installed，跳過 $skipped，失敗 $failed';
  }

  @override
  String get feedsImportChangeNew => '新增';

  @override
  String get feedsImportChangeUpgrade => '升級';

  @override
  String get feedsImportChangeDowngrade => '降級';

  @override
  String get feedsImportChangeSame => '已安裝';

  @override
  String get feedsImportChangeUnknown => '未知';

  @override
  String get settingsBackup => '導出備份';

  @override
  String get settingsBackupDescription => '將書源、書架、閱讀進度與書籤保存爲文件';

  @override
  String get settingsBackupSuccess => '備份已保存';

  @override
  String get settingsBackupError => '導出備份失敗';

  @override
  String get feedDeleteBusy => '目前有其他書源操作進行中';

  @override
  String feedDeleteQueued(String feedName) {
    return '「$feedName」將被刪除';
  }

  @override
  String get feedDeleteUndo => '撤銷';

  @override
  String get feedSelectorNoFeeds => '暫無書源，請先在「書源」頁面添加腳本';

  @override
  String get navSettings => '設置';

  @override
  String get settingsTitle => '設置';

  @override
  String get settingsAbout => '關於';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsLicenses => '開源許可';

  @override
  String get addFeedTitle => '添加書源';

  @override
  String get addFeedTabUrl => '從網絡';

  @override
  String get addFeedTabUrlDesc => '從網絡地址導入書源腳本';

  @override
  String get addFeedTabFile => '從本地';

  @override
  String get addFeedTabFileDesc => '從本地存儲導入書源腳本';

  @override
  String get addFeedUrlHint => '輸入腳本地址…';

  @override
  String get addFeedUrlPreview => '預覽';

  @override
  String get addFeedPreviewTitle => '書源摘要';

  @override
  String get addFeedAllowedDomains => '允許訪問的域名';

  @override
  String get addFeedNoDomainRestriction => '無域名限制';

  @override
  String addFeedIsUpgrade(String from, String to) {
    return '升級 $from → $to';
  }

  @override
  String get addFeedBadgeNew => '新書源';

  @override
  String addFeedIsDowngrade(String from, String to) {
    return '降級 $from → $to';
  }

  @override
  String get addFeedIsSame => '與已安裝版本相同';

  @override
  String addFeedVersionUnknown(String from, String to) {
    return '已安裝 $from，將安裝 $to';
  }

  @override
  String get addFeedInstall => '安裝';

  @override
  String get addFeedSuccess => '書源安裝成功';

  @override
  String get settingsReading => '閱讀';

  @override
  String get settingsChineseConversion => '繁簡轉換';

  @override
  String get settingsChineseConversionDescription => '閱讀時自動轉換中文字體';

  @override
  String get settingsStorage => '存儲';

  @override
  String get settingsCleanupCache => '清理緩存';

  @override
  String get settingsCleanupCacheDescription => '清理15天前的緩存數據和閱讀進度（書架中的書不受影響）';

  @override
  String settingsCleanupSuccess(int count) {
    return '已清理 $count 項';
  }

  @override
  String get settingsCleanupNothingToClean => '沒有需要清理的數據';

  @override
  String get settingsCleanupError => '清理失敗';

  @override
  String get settingsStorageDatabaseSize => '資料庫大小';

  @override
  String get settingsStorageCacheSize => '快取大小';

  @override
  String get settingsStorageBooks => '書籍';

  @override
  String get settingsStorageChapters => '章節';

  @override
  String get settingsStorageCovers => '封面';

  @override
  String get settingsStorageBookshelfCount => '書架';

  @override
  String get settingsClearCache => '清除快取';

  @override
  String get settingsClearCacheDescription => '刪除所有已快取的章節與封面；書架、閱讀進度與書籤會保留';

  @override
  String get settingsClearCacheConfirmTitle => '清除快取？';

  @override
  String get settingsClearCacheConfirmMessage => '確定要清除所有快取嗎？';

  @override
  String get settingsClearCacheNote => '快取章節與封面會被刪除，需要時會重新下載；閱讀進度與書籤會保留。';

  @override
  String settingsClearCacheSuccess(String bytes) {
    return '已清除快取 — 釋放 $bytes';
  }

  @override
  String get settingsClearCacheNothing => '快取已是空的';

  @override
  String get settingsClearCacheError => '清除快取失敗';

  @override
  String get settingsDeveloper => '開發者';

  @override
  String get devToolsTitle => '開發者工具';

  @override
  String get devToolsEntryDescription => '書源腳本調試環境';

  @override
  String devUnlockCountdown(int count) {
    return '再點擊 $count 次開啟開發者模式';
  }

  @override
  String get devUnlocked => '已開啟開發者模式';

  @override
  String get devDisable => '關閉開發者模式';

  @override
  String get devDisableConfirmTitle => '關閉開發者模式？';

  @override
  String get devDisableConfirmMessage => '將隱藏開發者工具入口。';

  @override
  String get devScriptLabel => '書源腳本';

  @override
  String get devScriptHint => '貼上 Lua 腳本或從已安裝的書源導入；腳本在此獨立編譯運行，不影響已安裝的書源。';

  @override
  String get devScriptImport => '導入';

  @override
  String get devScriptImportTitle => '選擇已安裝的書源';

  @override
  String get devScriptImportEmpty => '沒有已安裝的書源';

  @override
  String get devScriptClear => '清空';

  @override
  String get devScriptClearConfirmTitle => '清空腳本？';

  @override
  String get devScriptClearConfirmMessage => '將清空編輯器中的腳本內容。';

  @override
  String get devScriptMissing => '請先貼上或導入腳本';

  @override
  String devScriptImported(String name) {
    return '已導入「$name」';
  }

  @override
  String get devScriptLoadError => '讀取書源腳本失敗';

  @override
  String get devAuthApplied => '已套用存儲登錄態';

  @override
  String get devAuthMissing => '無存儲登錄態';

  @override
  String get devAuthNotSupported => '腳本未定義登錄';

  @override
  String get debugStageSearch => '搜索';

  @override
  String get debugStageBookInfo => '書籍詳情';

  @override
  String get debugStageChapters => '章節目錄';

  @override
  String get debugStageParagraphs => '正文段落';

  @override
  String get debugStageAuthStatus => '登錄狀態';

  @override
  String get debugInputKeyword => '關鍵詞';

  @override
  String get debugInputBookId => '書籍 ID';

  @override
  String get debugInputChapterId => '章節 ID';

  @override
  String debugInputMissing(String field) {
    return '請填寫：$field';
  }

  @override
  String get debugRun => '運行';

  @override
  String get debugSummaryOk => '成功';

  @override
  String get debugSummaryFailed => '失敗';

  @override
  String debugDurationMs(int ms) {
    return '$ms ms';
  }

  @override
  String get debugErrorTitle => '錯誤';

  @override
  String get debugOutputTitle => '輸出';

  @override
  String get debugResultEmpty => '0 項結果';

  @override
  String get debugEmptyHint =>
      '貼上或導入書源腳本，選擇流水線階段並運行。解析輸出、錯誤（如有）與 HTTP 請求記錄會顯示在這裏；運行結果會保存在本次會話的歷史中。';

  @override
  String get debugChainBookInfo => '書籍詳情';

  @override
  String get debugChainParagraphs => '正文段落';

  @override
  String get debugFieldId => 'ID';

  @override
  String get debugFieldTitle => '標題';

  @override
  String get debugFieldAuthor => '作者';

  @override
  String get debugFieldCover => '封面';

  @override
  String get debugFieldDescription => '簡介';

  @override
  String get debugImageParagraph => '圖片';

  @override
  String debugTraceTitle(int count) {
    return 'HTTP 追蹤（$count）';
  }

  @override
  String get debugTraceEmpty => '沒有發生 HTTP 請求。';

  @override
  String debugTraceDropped(int count) {
    return '另有 $count 個請求未被記錄（已達追蹤上限）。';
  }

  @override
  String get debugTraceSize => '響應大小';

  @override
  String get debugTraceHeaders => '請求頭';

  @override
  String get debugTraceBodyPreview => '響應體預覽';

  @override
  String debugHistoryTitle(int count) {
    return '歷史（$count）';
  }
}
