// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get feedUpdateUnchanged => '書源已是最新內容。';

  @override
  String get feedUpdateTitle => '檢查書源更新';

  @override
  String get feedUpdateInstall => '更新書源';

  @override
  String get feedUpdateSuccess => '書源已更新';

  @override
  String get feedUpdateIdMismatch => '下載的書源 ID 不同，無法更新此書源。';

  @override
  String get appName => '琅嬛';

  @override
  String get navBookshelf => '書架';

  @override
  String get navFeeds => '書源';

  @override
  String get bookshelfTitle => '書架';

  @override
  String get bookshelfRefresh => '刷新書架並檢查更新';

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
  String bookshelfReadingProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get bookshelfFeedPaused => '書源已暫停';

  @override
  String get bookshelfFeedPausedHint => '書源已暫停；已收藏書籍仍可閱讀，但不會檢查更新。';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHistory => '搜索歷史';

  @override
  String get searchHistoryClear => '清空歷史';

  @override
  String get searchHistoryDelete => '刪除此記錄';

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
  String get searchLoadMore => '加載更多';

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
  String get chapterCached => '已緩存';

  @override
  String get chapterNotCached => '未緩存';

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
  String get readerFontScale => '字體';

  @override
  String get readerLetterSpacing => '字距';

  @override
  String get readerParagraphSpacing => '段落間距';

  @override
  String get readerLineHeight => '行高';

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
  String readerPageProgress(int current, int total) {
    return '第 $current/$total 頁';
  }

  @override
  String readerBookProgress(int percent) {
    return '本書 $percent%';
  }

  @override
  String get readerModeVertical => '上下滑動';

  @override
  String get readerModeHorizontal => '左右翻頁';

  @override
  String get readerModeLabel => '閱讀方式';

  @override
  String get readerEndOfBook => '已讀至最新章節';

  @override
  String get readerEndHint => '暫時沒有更多章節。\n刷新目錄，查看是否有更新。';

  @override
  String get readerEndChecking => '正在檢查更新…';

  @override
  String get readerEndChecked => '目錄已刷新，暫時沒有新章節。';

  @override
  String get readerBackToText => '返回正文';

  @override
  String get readerRefreshChapters => '刷新目錄';

  @override
  String get readerLoading => '加載中…';

  @override
  String get readerChapterLoadError => '章節加載失敗';

  @override
  String get readerRetry => '重試';

  @override
  String get errorCategoryAuthRequired => '需要登錄';

  @override
  String get errorCategoryCfChallenge => '觸發了 Cloudflare 驗證';

  @override
  String get errorCategoryRateLimited => '請求過於頻繁';

  @override
  String get errorCategoryContentNotFound => '找不到內容';

  @override
  String get errorCategorySourceUnavailable => '書源暫時不可用';

  @override
  String get errorCategoryScriptError => '腳本錯誤';

  @override
  String get errorCategoryNetwork => '網絡錯誤';

  @override
  String get errorCategoryScriptRuntime => '腳本運行錯誤';

  @override
  String get errorCategoryScriptConfig => '腳本配置錯誤';

  @override
  String get errorCategoryStorage => '存儲錯誤';

  @override
  String get errorCategoryRegistry => '找不到書源';

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
  String get feedDetailNoDomainRestriction => '網絡訪問已禁用';

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
  String get webviewVerifyPageTitle => '驗證';

  @override
  String get webviewVerifyDone => '完成';

  @override
  String get webviewVerifyInstructions => '請在此網頁完成人機驗證，然後點擊「完成」。';

  @override
  String get webviewVerifyDesktopInstructions =>
      '已在單獨的窗口中打開驗證頁。請在該窗口完成驗證，保持窗口開啟，然後回到本頁點擊「完成」。';

  @override
  String get webviewVerifyDesktopWindowHint => '驗證窗口保持開啟中。完成驗證後，點擊右上角的「完成」。';

  @override
  String get webviewVerifyWindowClosed =>
      '驗證窗口已關閉。驗證需要讀取窗口中的頁面與 cookies，請重新打開。';

  @override
  String get webviewVerifyReopenWindow => '重新打開驗證窗口';

  @override
  String get webviewVerifySubmitting => '正在提交驗證…';

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
  String feedsImportTooLarge(String size) {
    return '匯入文件超過 $size 上限';
  }

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
  String get feedSecurityWarningTitle => '只安裝你信任的書源';

  @override
  String get feedSecurityWarningBody =>
      '書源腳本可以向列出的域名請求資料，並處理登入會話資料。惡意書源可能洩露私隱或過度消耗資源；繼續前請核對作者和允許訪問的域名。';

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
  String get addFeedNoDomainRestriction => '網絡訪問已禁用';

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
  String get addFeedError => '添加書源失敗';

  @override
  String get addFeedSuccess => '書源安裝成功';

  @override
  String addFeedAuditAction(String size) {
    return '查看腳本（$size）';
  }

  @override
  String get addFeedAuditTitle => '腳本審計';

  @override
  String addFeedAuditStats(String size, int lines) {
    return '$size · $lines 行';
  }

  @override
  String get addFeedAuditCopy => '複製';

  @override
  String get addFeedAuditCopied => '已複製腳本';

  @override
  String get addFeedAuditWrap => '切換自動換行';

  @override
  String get addFeedAuditFormat => '切換格式化檢視';

  @override
  String get addFeedAuditFormattedNote => '已格式化以便閱讀，安裝的腳本保持原文';

  @override
  String get addFeedAuditSearchHint => '搜尋腳本內容…';

  @override
  String addFeedAuditMatchCount(int count) {
    return '$count 處匹配';
  }

  @override
  String get addFeedAuditNoMatch => '無匹配';

  @override
  String get addFeedAuditEmpty => '腳本內容為空';

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
  String get devAgentApi => 'Agent API';

  @override
  String get devAgentApiTitle => '本地 Agent API';

  @override
  String get devAgentApiHint => '僅監聽本機回環地址；關閉此開發者工具頁後，API 會自動停止。';

  @override
  String get devAgentEndpoint => '接口地址';

  @override
  String get devAgentToken => 'Bearer 令牌';

  @override
  String get devAgentCopyCurl => '複製 curl';

  @override
  String get devAgentStop => '停止 API';

  @override
  String get devClose => '關閉';

  @override
  String get debugOperations => '操作';

  @override
  String debugStepTitle(int count) {
    return 'Reducer 步驟（$count）';
  }

  @override
  String get debugStepEmpty => '沒有記錄到 Reducer 步驟。';

  @override
  String debugStepDropped(int count) {
    return '另有 $count 個步驟未被記錄。';
  }

  @override
  String debugStepRound(String operation, int round) {
    return '$operation · 第 $round 輪';
  }

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
  String get devScriptHint =>
      '貼上 JavaScript 書源或從已安裝的書源導入。載入後運行才會使用新腳本，每次載入都會重置狀態；腳本在隔離的原生 QuickJS 沙盒中運行，不影響已安裝的書源。';

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
  String get devScriptLoad => '載入';

  @override
  String get devScriptLoaded => '腳本已載入，運行將使用此版本';

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
  String get debugStageComments => '評論';

  @override
  String get debugStageAuthStatus => '登錄狀態';

  @override
  String get debugStageManual => '高級單頁調用';

  @override
  String get debugManualOperation => 'Operation';

  @override
  String get debugManualInput => 'Input JSON';

  @override
  String get debugManualInputHint => '作爲 event.input 傳入';

  @override
  String get debugManualCursor => 'Cursor JSON';

  @override
  String get debugManualCursorHint => '作爲 event.cursor 傳入；第一頁使用 null';

  @override
  String get debugManualUseNextCursor => '使用下一頁 Cursor';

  @override
  String get debugManualNoNextCursor => '沒有 next_cursor，操作已完成。';

  @override
  String get debugInputKeyword => '關鍵詞';

  @override
  String get debugInputBookId => '書籍 ID';

  @override
  String get debugInputChapterId => '章節 ID';

  @override
  String get debugInputParagraphId => '段落 ID（可選）';

  @override
  String get debugInputParentId => '父評論 ID（可選）';

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

  @override
  String get readerChapterComments => '章節評論';

  @override
  String get readerParagraphComments => '段落評論';

  @override
  String get commentsReplies => '回覆';

  @override
  String get commentsExpand => '展開';

  @override
  String get commentsCollapse => '收起';

  @override
  String get commentsAllReplies => '全部回覆';

  @override
  String get commentsEmpty => '暫無評論';

  @override
  String get commentsMore => '加載更多';

  @override
  String get commentsEnd => '沒有更多評論';

  @override
  String get commentsRefresh => '刷新評論';

  @override
  String get commentsSortHot => '最熱';

  @override
  String get commentsSortLatest => '最新';

  @override
  String get commentsViewAll => '查看全部';

  @override
  String get listeningReturnToPosition => '回到朗讀位置';

  @override
  String get listeningFromHere => '從這裏聽';

  @override
  String get listeningTitle => '系統語音聽書';

  @override
  String get listeningStart => '開始聽書';

  @override
  String get listeningPause => '暫停';

  @override
  String get listeningResume => '繼續播放';

  @override
  String get listeningStop => '停止聽書';

  @override
  String get listeningVoice => '引擎聲音';

  @override
  String get listeningRate => '語速';

  @override
  String get listeningSleep => '定時停止';

  @override
  String get listeningNoTimer => '關閉';

  @override
  String get listeningLocalHint =>
      '使用本機 TTS 引擎，支持引擎提供的聯網聲音；Linux 需要安裝 eSpeak NG。';

  @override
  String get listeningError => '系統語音不可用或播放失敗，請檢查 TTS 引擎和聲音後重試。';

  @override
  String get listeningCompleted => '已播放完畢';

  @override
  String get listeningPrevious => '上一段';

  @override
  String get listeningNext => '下一段';

  @override
  String get listeningSearchVoices => '搜索聲音或語言';

  @override
  String get listeningNoVoicesMatch => '沒有匹配的聲音';

  @override
  String get listeningLoadingVoices => '正在加載系統聲音…';

  @override
  String get listeningReloadVoices => '重新加載聲音';

  @override
  String get listeningChapterEnd => '本章結束';

  @override
  String get listeningStopsAfterChapter => '本章結束後停止';

  @override
  String get listeningCustomTimer => '自訂';

  @override
  String get listeningCustomTimerTitle => '自訂定時';

  @override
  String listeningMinutesLabel(int count) {
    return '$count 分鐘';
  }

  @override
  String listeningRemainingTime(String time) {
    return '剩餘 $time';
  }

  @override
  String listeningParagraphProgress(int current, int total) {
    return '本段 $current/$total';
  }

  @override
  String get readerShowComments => '顯示評論';

  @override
  String get readerHideComments => '隱藏評論';

  @override
  String readerCommentCountCompact(String count) {
    return '$count萬';
  }

  @override
  String get transformTitle => '正文轉換';

  @override
  String get transformBookSettings => '本書正文轉換';

  @override
  String get transformDescription => '規則從上到下依次執行。點擊規則可編輯名稱、啓停狀態和配置。';

  @override
  String get transformRegexReplace => '正則替換';

  @override
  String get transformRegexDelete => '正則刪除段落';

  @override
  String get transformSave => '保存';

  @override
  String get transformAdd => '添加轉換規則';

  @override
  String get transformName => '名稱（可選）';

  @override
  String get transformPattern => '正則表達式';

  @override
  String get transformReplacement => '替換內容';

  @override
  String get transformIncludeTitles => '同時處理章節標題';

  @override
  String get transformRegexHelp =>
      '替換內容可用 \$1、\$2 引用捕獲組，\$\$ 表示美元符號。支持 (?i) 等內聯標誌，不支持環視及正則表達式內的反向引用。';

  @override
  String get transformInherit => '先應用全局轉換規則';

  @override
  String get transformInheritDescription => '關閉後僅使用本書的規則。';

  @override
  String get transformEmpty => '此組合尚無規則。';

  @override
  String get transformMoveUp => '上移';

  @override
  String get transformMoveDown => '下移';

  @override
  String get transformPatternRequired => '請輸入正則表達式。';

  @override
  String get transformIndent => '段落縮進';

  @override
  String get transformDeduplicate => '章節標題去重';

  @override
  String get transformConversionDescription => '轉換正文和章節標題的繁簡字形。';

  @override
  String get transformReplaceDescription => '替換段落中所有匹配正則表達式的文字。';

  @override
  String get transformDeleteDescription => '文字匹配時，刪除整個段落。';

  @override
  String get transformIndentDescription => '移除文字段落開頭的空白，並設置首行縮進。';

  @override
  String get transformDeduplicateDescription => '保留首個章節標題，移除後續重複的標題段落。';

  @override
  String get transformKeepFirstTitle => '每章僅保留首個標題';

  @override
  String transformIndentCharacters(int count) {
    return '首行縮進：$count 個字符';
  }

  @override
  String get transformApplicationRules => '應用級規則';

  @override
  String get transformBookRules => '本書規則';

  @override
  String get transformAddHint => '點擊 + 選擇轉換器並進入配置頁。';

  @override
  String get transformEnabled => '已啓用';

  @override
  String get transformDisabled => '已停用';

  @override
  String get transformEmptyReplacement => '（空文字）';

  @override
  String transformDeleteQueued(String name) {
    return '「$name」將被刪除';
  }

  @override
  String get transformUndo => '撤銷';

  @override
  String get transformRemoveTitle => '刪除轉換器？';

  @override
  String get transformRemoveMessage => '要從組合中移除此轉換器嗎？';

  @override
  String get transformApplicationEditHint => '這是應用級規則。修改會影響所有繼承它的書籍。';

  @override
  String get transformReorder => '拖動調整順序';
}

/// The translations for Chinese, as used in China (`zh_CN`).
class AppLocalizationsZhCn extends AppLocalizationsZh {
  AppLocalizationsZhCn() : super('zh_CN');

  @override
  String get feedUpdateUnchanged => '书源已是最新内容。';

  @override
  String get feedUpdateTitle => '检查书源更新';

  @override
  String get feedUpdateInstall => '更新书源';

  @override
  String get feedUpdateSuccess => '书源已更新';

  @override
  String get feedUpdateIdMismatch => '下载的书源 ID 不同，无法更新此书源。';

  @override
  String get appName => '琅嬛';

  @override
  String get navBookshelf => '书架';

  @override
  String get navFeeds => '书源';

  @override
  String get bookshelfTitle => '书架';

  @override
  String get bookshelfRefresh => '刷新书架并检查更新';

  @override
  String bookshelfNewChapters(int count) {
    return '$count 个新章节';
  }

  @override
  String get bookshelfCheckFailed => '检查更新失败';

  @override
  String bookshelfCheckPartialFailure(int count) {
    return '$count 本书检查失败';
  }

  @override
  String get bookshelfEmpty => '书架是空的';

  @override
  String get bookshelfEmptyHint => '搜索并收藏书籍后会显示在这里';

  @override
  String get bookshelfSearchHint => '搜索书籍…';

  @override
  String get bookshelfLoadError => '加载书架失败';

  @override
  String get bookshelfAdded => '已加入本地书架';

  @override
  String get bookshelfRemoved => '已从本地书架移除';

  @override
  String get bookshelfActionFailed => '书架操作失败';

  @override
  String get bookshelfErrorAppDataNotReady => '应用数据目录未准备就绪';

  @override
  String get bookshelfErrorAddFailed => '添加书籍失败';

  @override
  String get bookshelfErrorRemoveFailed => '移除书籍失败';

  @override
  String get bookshelfErrorLoadFailed => '加载书架失败';

  @override
  String get bookshelfBookDetails => '书籍详情';

  @override
  String get bookshelfDeleteConfirmTitle => '删除书籍？';

  @override
  String bookshelfDeleteConfirmMessage(String bookTitle) {
    return '确定要从书架删除「$bookTitle」吗？';
  }

  @override
  String get bookshelfDeleteCascadeWarning => '这也会删除该书的快取章节、封面、阅读进度与书签。';

  @override
  String get bookshelfDeleteCancel => '取消';

  @override
  String get bookshelfDeleteConfirm => '删除';

  @override
  String bookshelfDeleteQueued(String bookTitle) {
    return '「$bookTitle」将从书架移除';
  }

  @override
  String get bookshelfDeleteUndo => '撤销';

  @override
  String bookshelfReadingProgress(int current, int total, int percent) {
    return '第 $current/$total 章 · $percent%';
  }

  @override
  String bookshelfReadingProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get bookshelfFeedPaused => '书源已暂停';

  @override
  String get bookshelfFeedPausedHint => '书源已暂停；已收藏书籍仍可阅读，但不会检查更新。';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHistory => '搜索历史';

  @override
  String get searchHistoryClear => '清空历史';

  @override
  String get searchHistoryDelete => '删除此记录';

  @override
  String get searchHintNoFeed => '请先选择书源…';

  @override
  String get searchHintAllFeeds => '在全部书源中搜索…';

  @override
  String get searchAllFeeds => '全部';

  @override
  String searchSourceFailed(Object feedName) {
    return '「$feedName」搜索失败';
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
  String get searchEmptyPrompt => '输入关键词开始搜索';

  @override
  String searchNoResults(String keyword) {
    return '「$keyword」无搜索结果';
  }

  @override
  String get searchError => '搜索出错';

  @override
  String get searchRetry => '重试';

  @override
  String get searchLoadMore => '加载更多';

  @override
  String get bookDetailTitle => '书籍详情';

  @override
  String get bookDetailError => '加载书籍信息失败';

  @override
  String get bookDetailRetry => '重试';

  @override
  String get bookDetailStartReading => '开始阅读';

  @override
  String get bookDetailContinueReading => '继续阅读';

  @override
  String bookDetailLastReadChapter(String chapterTitle) {
    return '上次读到：$chapterTitle';
  }

  @override
  String get bookDetailNoDescription => '暂无简介';

  @override
  String get chapterCached => '已缓存';

  @override
  String get chapterNotCached => '未缓存';

  @override
  String bookDetailChapters(int count) {
    return '章节（$count）';
  }

  @override
  String get bookDetailChaptersError => '加载章节失败';

  @override
  String get bookDetailMissingParams => '缺少书籍参数';

  @override
  String get bookDetailEmpty => '暂无书籍信息';

  @override
  String get bookDetailAddBookshelf => '加入本地书架';

  @override
  String get bookDetailRemoveBookshelf => '从本地书架移除';

  @override
  String get readerTitle => '阅读';

  @override
  String get readerMissingParams => '缺少阅读参数';

  @override
  String get readerFontLoadFailed => '字体档案载入失败';

  @override
  String get readerFontFileLabel => '字体档案';

  @override
  String get readerFontSystemDefault => '系统默认';

  @override
  String get readerFontChoose => '选择字体档案';

  @override
  String get readerFontReset => '重设';

  @override
  String get readerFontScale => '字体';

  @override
  String get readerLetterSpacing => '字距';

  @override
  String get readerParagraphSpacing => '段落间距';

  @override
  String get readerLineHeight => '行高';

  @override
  String get readerLoadError => '加载章节失败';

  @override
  String get readerEmpty => '暂无章节正文';

  @override
  String get readerPrevChapter => '上一章';

  @override
  String get readerNextChapter => '下一章';

  @override
  String readerChapterProgress(int current, int total) {
    return '第 $current / $total 章';
  }

  @override
  String readerPageProgress(int current, int total) {
    return '第 $current/$total 页';
  }

  @override
  String readerBookProgress(int percent) {
    return '本书 $percent%';
  }

  @override
  String get readerModeVertical => '上下滑动';

  @override
  String get readerModeHorizontal => '左右翻页';

  @override
  String get readerModeLabel => '阅读方式';

  @override
  String get readerEndOfBook => '已读至最新章节';

  @override
  String get readerEndHint => '暂时没有更多章节。\n刷新目录，查看是否有更新。';

  @override
  String get readerEndChecking => '正在检查更新…';

  @override
  String get readerEndChecked => '目录已刷新，暂时没有新章节。';

  @override
  String get readerBackToText => '返回正文';

  @override
  String get readerRefreshChapters => '刷新目录';

  @override
  String get readerLoading => '加载中…';

  @override
  String get readerChapterLoadError => '章节加载失败';

  @override
  String get readerRetry => '重试';

  @override
  String get errorCategoryAuthRequired => '需要登录';

  @override
  String get errorCategoryCfChallenge => '触发了 Cloudflare 验证';

  @override
  String get errorCategoryRateLimited => '请求过于频繁';

  @override
  String get errorCategoryContentNotFound => '找不到内容';

  @override
  String get errorCategorySourceUnavailable => '书源暂时不可用';

  @override
  String get errorCategoryScriptError => '脚本错误';

  @override
  String get errorCategoryNetwork => '网络错误';

  @override
  String get errorCategoryScriptRuntime => '脚本运行错误';

  @override
  String get errorCategoryScriptConfig => '脚本配置错误';

  @override
  String get errorCategoryStorage => '存储错误';

  @override
  String get errorCategoryRegistry => '找不到书源';

  @override
  String get readerToc => '目录';

  @override
  String get readerInterface => '界面';

  @override
  String get readerSettings => '设置';

  @override
  String get readerRefreshChapter => '刷新本章';

  @override
  String get readerBookmarks => '书签';

  @override
  String get readerBookmarkAdded => '已添加书签';

  @override
  String get readerBookmarkRemoved => '已删除书签';

  @override
  String get readerNoBookmarks => '暂无书签';

  @override
  String get readerAddBookmark => '添加书签';

  @override
  String get readerSearchTocHint => '搜索章节';

  @override
  String get readerSearchBookmarksHint => '搜索书签';

  @override
  String get readerThemeSystem => '跟随系统';

  @override
  String get readerThemeLight => '浅色';

  @override
  String get readerThemeDark => '深色';

  @override
  String get readerThemeSepia => '护眼';

  @override
  String get readerThemeCustom => '自定义';

  @override
  String get readerThemeCustomizeTitle => '自定义阅读主题';

  @override
  String get readerThemeBackground => '背景';

  @override
  String get readerThemeText => '文字';

  @override
  String get readerThemeAccent => '强调色';

  @override
  String get readerThemePreview => '预览';

  @override
  String get readerThemePreviewTitle => '章节标题';

  @override
  String get readerThemePreviewBody => '让每一页都有舒适的阅读体验。';

  @override
  String get readerThemeContrastWarning => '请选择对比更明显的背景色与文字色。';

  @override
  String get readerThemeReset => '重置';

  @override
  String get readerThemeApply => '应用';

  @override
  String get readerThemeColorHue => '色相';

  @override
  String get readerThemeColorSaturation => '饱和度';

  @override
  String get readerThemeColorBrightness => '亮度';

  @override
  String get readerThemeColorCancel => '取消';

  @override
  String get readerThemeLabel => '主题';

  @override
  String readerSearchNoMatch(String keyword) {
    return '没有符合「$keyword」的内容';
  }

  @override
  String get readerSettingPlaceholder => '此入口预留，后续扩展。';

  @override
  String get readerChineseConversion => '繁简转换';

  @override
  String get chineseConversionNone => '不转换';

  @override
  String get chineseConversionS2t => '简体转繁体';

  @override
  String get chineseConversionT2s => '繁体转简体';

  @override
  String get chineseConversionS2tw => '简体 → 台湾正体';

  @override
  String get chineseConversionS2hk => '简体 → 香港繁体';

  @override
  String get feedsTitle => '书源';

  @override
  String get feedsSearchHint => '搜索书源…';

  @override
  String get feedsEmpty => '暂无书源\n请添加书源以开始使用';

  @override
  String feedsNoMatch(String keyword) {
    return '未找到匹配的书源「$keyword」';
  }

  @override
  String get feedsLoadError => '加载书源失败';

  @override
  String get feedsRetry => '重试';

  @override
  String get feedDetailId => 'ID';

  @override
  String get feedDetailBaseUrl => '主站网址';

  @override
  String get feedDetailAccessDomains => '允许访问的域名';

  @override
  String get feedDetailNoDomainRestriction => '网络访问已禁用';

  @override
  String get feedDetailSource => '来源';

  @override
  String get feedDetailEnabled => '启用书源';

  @override
  String get feedDetailEnabledHint => '暂停的书源不参与聚合搜索与更新检查。';

  @override
  String get feedDetailBooksLabel => '书架书籍';

  @override
  String feedDetailBookCount(int count) {
    return '$count 本';
  }

  @override
  String get feedDetailCopyId => '复制 ID';

  @override
  String get feedDetailCopied => '已复制';

  @override
  String get feedDetailDelete => '删除书源';

  @override
  String get feedItemPaused => '已暂停';

  @override
  String get feedAuthLabel => '登录';

  @override
  String get feedAuthStatusLoggedIn => '已登录';

  @override
  String get feedAuthStatusLoggedOut => '未登录';

  @override
  String get feedAuthStatusExpired => '登录已过期';

  @override
  String get feedAuthStatusUnsupported => '不支持';

  @override
  String get feedAuthLogin => '登录';

  @override
  String get feedAuthLogout => '登出';

  @override
  String get feedAuthPageTitle => '书源登录';

  @override
  String get feedAuthDone => '验证登录';

  @override
  String get feedAuthInstructions => '请在此网页完成登录，然后点击「验证登录」。';

  @override
  String get feedAuthDesktopInstructions =>
      '已在单独的窗口中打开登录页。请在该窗口完成登录，保持窗口开启，然后回到本页点击「验证登录」。';

  @override
  String get feedAuthDesktopWindowHint => '登录窗口保持开启中。完成登录后，点击右上角的「验证登录」。';

  @override
  String get feedAuthWindowClosed => '登录窗口已关闭。验证登录需要读取窗口中的页面与 cookies，请重新打开。';

  @override
  String get feedAuthReopenWindow => '重新打开登录窗口';

  @override
  String get feedAuthVerifying => '正在验证登录…';

  @override
  String get feedAuthNotSupported => '此书源不支持登录。';

  @override
  String get feedAuthUpdated => '登录验证成功';

  @override
  String get feedAuthLoggedOut => '已登出';

  @override
  String get feedAuthRefresh => '刷新登录状态';

  @override
  String get searchAuthHint => '此书源可能需要先登录';

  @override
  String get searchAuthAction => '去登录';

  @override
  String get webviewVerifyPageTitle => '验证';

  @override
  String get webviewVerifyDone => '完成';

  @override
  String get webviewVerifyInstructions => '请在此网页完成人机验证，然后点击「完成」。';

  @override
  String get webviewVerifyDesktopInstructions =>
      '已在单独的窗口中打开验证页。请在该窗口完成验证，保持窗口开启，然后回到本页点击「完成」。';

  @override
  String get webviewVerifyDesktopWindowHint => '验证窗口保持开启中。完成验证后，点击右上角的「完成」。';

  @override
  String get webviewVerifyWindowClosed =>
      '验证窗口已关闭。验证需要读取窗口中的页面与 cookies，请重新打开。';

  @override
  String get webviewVerifyReopenWindow => '重新打开验证窗口';

  @override
  String get webviewVerifySubmitting => '正在提交验证…';

  @override
  String get feedItemLoadError => '加载失败';

  @override
  String get feedDeleteConfirmTitle => '删除书源？';

  @override
  String feedDeleteConfirmMessage(String feedName) {
    return '确定要删除「$feedName」吗？';
  }

  @override
  String get feedDeleteCancel => '取消';

  @override
  String get feedDeleteConfirm => '删除';

  @override
  String get feedDeleteCascadeWarning => '这也会删除该书源的快取书籍、封面、阅读进度与书签。';

  @override
  String feedDeleteSuccess(String feedName) {
    return '已删除 $feedName';
  }

  @override
  String get feedDeleteError => '删除书源失败';

  @override
  String get feedToggleError => '切换书源状态失败';

  @override
  String get feedPause => '暂停书源';

  @override
  String get feedResume => '恢复书源';

  @override
  String get feedsMenuImport => '导入书源';

  @override
  String get feedsMenuExport => '导出书源';

  @override
  String get feedsExported => '书源已导出';

  @override
  String get feedsExportNone => '没有可导出的书源';

  @override
  String get feedsExportError => '导出书源失败';

  @override
  String get feedsImportError => '导入书源失败';

  @override
  String feedsImportTooLarge(String size) {
    return '汇入文件超过 $size 上限';
  }

  @override
  String get feedsImportTitle => '导入书源';

  @override
  String get feedsImportConfirm => '导入';

  @override
  String feedsImportCount(num count) {
    return '共找到 $count 个书源';
  }

  @override
  String feedsImportResult(Object failed, Object installed, Object skipped) {
    return '已安装 $installed，跳过 $skipped，失败 $failed';
  }

  @override
  String get feedsImportChangeNew => '新增';

  @override
  String get feedsImportChangeUpgrade => '升级';

  @override
  String get feedsImportChangeDowngrade => '降级';

  @override
  String get feedsImportChangeSame => '已安装';

  @override
  String get feedsImportChangeUnknown => '未知';

  @override
  String get feedSecurityWarningTitle => '只安装你信任的书源';

  @override
  String get feedSecurityWarningBody =>
      '书源脚本可以向列出的域名请求资料，并处理登入会话资料。恶意书源可能泄露私隐或过度消耗资源；继续前请核对作者和允许访问的域名。';

  @override
  String get settingsBackup => '导出备份';

  @override
  String get settingsBackupDescription => '将书源、书架、阅读进度与书签保存为文件';

  @override
  String get settingsBackupSuccess => '备份已保存';

  @override
  String get settingsBackupError => '导出备份失败';

  @override
  String get feedDeleteBusy => '目前有其他书源操作进行中';

  @override
  String feedDeleteQueued(String feedName) {
    return '「$feedName」将被删除';
  }

  @override
  String get feedDeleteUndo => '撤销';

  @override
  String get feedSelectorNoFeeds => '暂无书源，请先在「书源」页面添加脚本';

  @override
  String get navSettings => '设置';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsAbout => '关于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsLicenses => '开源许可';

  @override
  String get addFeedTitle => '添加书源';

  @override
  String get addFeedTabUrl => '从网络';

  @override
  String get addFeedTabUrlDesc => '从网络地址导入书源脚本';

  @override
  String get addFeedTabFile => '从本地';

  @override
  String get addFeedTabFileDesc => '从本地存储导入书源脚本';

  @override
  String get addFeedUrlHint => '输入脚本地址…';

  @override
  String get addFeedUrlPreview => '预览';

  @override
  String get addFeedPreviewTitle => '书源摘要';

  @override
  String get addFeedAllowedDomains => '允许访问的域名';

  @override
  String get addFeedNoDomainRestriction => '网络访问已禁用';

  @override
  String addFeedIsUpgrade(String from, String to) {
    return '升级 $from → $to';
  }

  @override
  String get addFeedBadgeNew => '新书源';

  @override
  String addFeedIsDowngrade(String from, String to) {
    return '降级 $from → $to';
  }

  @override
  String get addFeedIsSame => '与已安装版本相同';

  @override
  String addFeedVersionUnknown(String from, String to) {
    return '已安装 $from，将安装 $to';
  }

  @override
  String get addFeedInstall => '安装';

  @override
  String get addFeedError => '添加书源失败';

  @override
  String get addFeedSuccess => '书源安装成功';

  @override
  String addFeedAuditAction(String size) {
    return '查看脚本（$size）';
  }

  @override
  String get addFeedAuditTitle => '脚本审计';

  @override
  String addFeedAuditStats(String size, int lines) {
    return '$size · $lines 行';
  }

  @override
  String get addFeedAuditCopy => '复制';

  @override
  String get addFeedAuditCopied => '已复制脚本';

  @override
  String get addFeedAuditWrap => '切换自动换行';

  @override
  String get addFeedAuditFormat => '切换格式化检视';

  @override
  String get addFeedAuditFormattedNote => '已格式化以便阅读，安装的脚本保持原文';

  @override
  String get addFeedAuditSearchHint => '搜寻脚本内容…';

  @override
  String addFeedAuditMatchCount(int count) {
    return '$count 处匹配';
  }

  @override
  String get addFeedAuditNoMatch => '无匹配';

  @override
  String get addFeedAuditEmpty => '脚本内容为空';

  @override
  String get settingsReading => '阅读';

  @override
  String get settingsChineseConversion => '繁简转换';

  @override
  String get settingsChineseConversionDescription => '阅读时自动转换中文字体';

  @override
  String get settingsStorage => '存储';

  @override
  String get settingsCleanupCache => '清理缓存';

  @override
  String get settingsCleanupCacheDescription => '清理15天前的缓存数据和阅读进度（书架中的书不受影响）';

  @override
  String settingsCleanupSuccess(int count) {
    return '已清理 $count 项';
  }

  @override
  String get settingsCleanupNothingToClean => '没有需要清理的数据';

  @override
  String get settingsCleanupError => '清理失败';

  @override
  String get settingsStorageDatabaseSize => '资料库大小';

  @override
  String get settingsStorageCacheSize => '快取大小';

  @override
  String get settingsStorageBooks => '书籍';

  @override
  String get settingsStorageChapters => '章节';

  @override
  String get settingsStorageCovers => '封面';

  @override
  String get settingsStorageBookshelfCount => '书架';

  @override
  String get settingsClearCache => '清除快取';

  @override
  String get settingsClearCacheDescription => '删除所有已快取的章节与封面；书架、阅读进度与书签会保留';

  @override
  String get settingsClearCacheConfirmTitle => '清除快取？';

  @override
  String get settingsClearCacheConfirmMessage => '确定要清除所有快取吗？';

  @override
  String get settingsClearCacheNote => '快取章节与封面会被删除，需要时会重新下载；阅读进度与书签会保留。';

  @override
  String settingsClearCacheSuccess(String bytes) {
    return '已清除快取 — 释放 $bytes';
  }

  @override
  String get settingsClearCacheNothing => '快取已是空的';

  @override
  String get settingsClearCacheError => '清除快取失败';

  @override
  String get settingsDeveloper => '开发者';

  @override
  String get devToolsTitle => '开发者工具';

  @override
  String get devToolsEntryDescription => '书源脚本调试环境';

  @override
  String get devAgentApi => 'Agent API';

  @override
  String get devAgentApiTitle => '本地 Agent API';

  @override
  String get devAgentApiHint => '仅监听本机回环地址；关闭此开发者工具页后，API 会自动停止。';

  @override
  String get devAgentEndpoint => '接口地址';

  @override
  String get devAgentToken => 'Bearer 令牌';

  @override
  String get devAgentCopyCurl => '复制 curl';

  @override
  String get devAgentStop => '停止 API';

  @override
  String get devClose => '关闭';

  @override
  String get debugOperations => '操作';

  @override
  String debugStepTitle(int count) {
    return 'Reducer 步骤（$count）';
  }

  @override
  String get debugStepEmpty => '没有记录到 Reducer 步骤。';

  @override
  String debugStepDropped(int count) {
    return '另有 $count 个步骤未被记录。';
  }

  @override
  String debugStepRound(String operation, int round) {
    return '$operation · 第 $round 轮';
  }

  @override
  String devUnlockCountdown(int count) {
    return '再点击 $count 次开启开发者模式';
  }

  @override
  String get devUnlocked => '已开启开发者模式';

  @override
  String get devDisable => '关闭开发者模式';

  @override
  String get devDisableConfirmTitle => '关闭开发者模式？';

  @override
  String get devDisableConfirmMessage => '将隐藏开发者工具入口。';

  @override
  String get devScriptLabel => '书源脚本';

  @override
  String get devScriptHint =>
      '贴上 JavaScript 书源或从已安装的书源导入。载入后运行才会使用新脚本，每次载入都会重置状态；脚本在隔离的原生 QuickJS 沙盒中运行，不影响已安装的书源。';

  @override
  String get devScriptImport => '导入';

  @override
  String get devScriptImportTitle => '选择已安装的书源';

  @override
  String get devScriptImportEmpty => '没有已安装的书源';

  @override
  String get devScriptClear => '清空';

  @override
  String get devScriptClearConfirmTitle => '清空脚本？';

  @override
  String get devScriptClearConfirmMessage => '将清空编辑器中的脚本内容。';

  @override
  String get devScriptMissing => '请先贴上或导入脚本';

  @override
  String devScriptImported(String name) {
    return '已导入「$name」';
  }

  @override
  String get devScriptLoad => '载入';

  @override
  String get devScriptLoaded => '脚本已载入，运行将使用此版本';

  @override
  String get devScriptLoadError => '读取书源脚本失败';

  @override
  String get devAuthApplied => '已套用存储登录态';

  @override
  String get devAuthMissing => '无存储登录态';

  @override
  String get devAuthNotSupported => '脚本未定义登录';

  @override
  String get debugStageSearch => '搜索';

  @override
  String get debugStageBookInfo => '书籍详情';

  @override
  String get debugStageChapters => '章节目录';

  @override
  String get debugStageParagraphs => '正文段落';

  @override
  String get debugStageComments => '评论';

  @override
  String get debugStageAuthStatus => '登录状态';

  @override
  String get debugStageManual => '高级单页调用';

  @override
  String get debugManualOperation => 'Operation';

  @override
  String get debugManualInput => 'Input JSON';

  @override
  String get debugManualInputHint => '作为 event.input 传入';

  @override
  String get debugManualCursor => 'Cursor JSON';

  @override
  String get debugManualCursorHint => '作为 event.cursor 传入；第一页使用 null';

  @override
  String get debugManualUseNextCursor => '使用下一页 Cursor';

  @override
  String get debugManualNoNextCursor => '没有 next_cursor，操作已完成。';

  @override
  String get debugInputKeyword => '关键词';

  @override
  String get debugInputBookId => '书籍 ID';

  @override
  String get debugInputChapterId => '章节 ID';

  @override
  String get debugInputParagraphId => '段落 ID（可选）';

  @override
  String get debugInputParentId => '父评论 ID（可选）';

  @override
  String debugInputMissing(String field) {
    return '请填写：$field';
  }

  @override
  String get debugRun => '运行';

  @override
  String get debugSummaryOk => '成功';

  @override
  String get debugSummaryFailed => '失败';

  @override
  String debugDurationMs(int ms) {
    return '$ms ms';
  }

  @override
  String get debugErrorTitle => '错误';

  @override
  String get debugOutputTitle => '输出';

  @override
  String get debugResultEmpty => '0 项结果';

  @override
  String get debugEmptyHint =>
      '贴上或导入书源脚本，选择流水线阶段并运行。解析输出、错误（如有）与 HTTP 请求记录会显示在这里；运行结果会保存在本次会话的历史中。';

  @override
  String get debugChainBookInfo => '书籍详情';

  @override
  String get debugChainParagraphs => '正文段落';

  @override
  String get debugFieldId => 'ID';

  @override
  String get debugFieldTitle => '标题';

  @override
  String get debugFieldAuthor => '作者';

  @override
  String get debugFieldCover => '封面';

  @override
  String get debugFieldDescription => '简介';

  @override
  String get debugImageParagraph => '图片';

  @override
  String debugTraceTitle(int count) {
    return 'HTTP 追踪（$count）';
  }

  @override
  String get debugTraceEmpty => '没有发生 HTTP 请求。';

  @override
  String debugTraceDropped(int count) {
    return '另有 $count 个请求未被记录（已达追踪上限）。';
  }

  @override
  String get debugTraceSize => '响应大小';

  @override
  String get debugTraceHeaders => '请求头';

  @override
  String get debugTraceBodyPreview => '响应体预览';

  @override
  String debugHistoryTitle(int count) {
    return '历史（$count）';
  }

  @override
  String get readerChapterComments => '章节评论';

  @override
  String get readerParagraphComments => '段落评论';

  @override
  String get commentsReplies => '回复';

  @override
  String get commentsExpand => '展开';

  @override
  String get commentsCollapse => '收起';

  @override
  String get commentsAllReplies => '全部回复';

  @override
  String get commentsEmpty => '暂无评论';

  @override
  String get commentsMore => '加载更多';

  @override
  String get commentsEnd => '没有更多评论';

  @override
  String get commentsRefresh => '刷新评论';

  @override
  String get commentsSortHot => '最热';

  @override
  String get commentsSortLatest => '最新';

  @override
  String get commentsViewAll => '查看全部';

  @override
  String get listeningReturnToPosition => '回到朗读位置';

  @override
  String get listeningFromHere => '从这里听';

  @override
  String get listeningTitle => '系统语音听书';

  @override
  String get listeningStart => '开始听书';

  @override
  String get listeningPause => '暂停';

  @override
  String get listeningResume => '继续播放';

  @override
  String get listeningStop => '停止听书';

  @override
  String get listeningVoice => '引擎声音';

  @override
  String get listeningRate => '语速';

  @override
  String get listeningSleep => '定时停止';

  @override
  String get listeningNoTimer => '关闭';

  @override
  String get listeningLocalHint =>
      '使用本机 TTS 引擎，支持引擎提供的联网声音；Linux 需要安装 eSpeak NG。';

  @override
  String get listeningError => '系统语音不可用或播放失败，请检查 TTS 引擎和声音后重试。';

  @override
  String get listeningCompleted => '已播放完毕';

  @override
  String get listeningPrevious => '上一段';

  @override
  String get listeningNext => '下一段';

  @override
  String get listeningSearchVoices => '搜索声音或语言';

  @override
  String get listeningNoVoicesMatch => '没有匹配的声音';

  @override
  String get listeningLoadingVoices => '正在加载系统声音…';

  @override
  String get listeningReloadVoices => '重新加载声音';

  @override
  String get listeningChapterEnd => '本章结束';

  @override
  String get listeningStopsAfterChapter => '本章结束后停止';

  @override
  String get listeningCustomTimer => '自订';

  @override
  String get listeningCustomTimerTitle => '自订定时';

  @override
  String listeningMinutesLabel(int count) {
    return '$count 分钟';
  }

  @override
  String listeningRemainingTime(String time) {
    return '剩余 $time';
  }

  @override
  String listeningParagraphProgress(int current, int total) {
    return '本段 $current/$total';
  }

  @override
  String get readerShowComments => '显示评论';

  @override
  String get readerHideComments => '隐藏评论';

  @override
  String readerCommentCountCompact(String count) {
    return '$count万';
  }

  @override
  String get transformTitle => '正文转换';

  @override
  String get transformBookSettings => '本书正文转换';

  @override
  String get transformDescription => '规则从上到下依次执行。点击规则可编辑名称、启停状态和配置。';

  @override
  String get transformRegexReplace => '正则替换';

  @override
  String get transformRegexDelete => '正则删除段落';

  @override
  String get transformSave => '保存';

  @override
  String get transformAdd => '添加转换规则';

  @override
  String get transformName => '名称（可选）';

  @override
  String get transformPattern => '正则表达式';

  @override
  String get transformReplacement => '替换内容';

  @override
  String get transformIncludeTitles => '同时处理章节标题';

  @override
  String get transformRegexHelp =>
      '替换内容可用 \$1、\$2 引用捕获组，\$\$ 表示美元符号。支持 (?i) 等内联标志，不支持环视及正则表达式内的反向引用。';

  @override
  String get transformInherit => '先应用全局转换规则';

  @override
  String get transformInheritDescription => '关闭后仅使用本书的规则。';

  @override
  String get transformEmpty => '此组合尚无规则。';

  @override
  String get transformMoveUp => '上移';

  @override
  String get transformMoveDown => '下移';

  @override
  String get transformPatternRequired => '请输入正则表达式。';

  @override
  String get transformIndent => '段落缩进';

  @override
  String get transformDeduplicate => '章节标题去重';

  @override
  String get transformConversionDescription => '转换正文和章节标题的繁简字形。';

  @override
  String get transformReplaceDescription => '替换段落中所有匹配正则表达式的文字。';

  @override
  String get transformDeleteDescription => '文字匹配时，删除整个段落。';

  @override
  String get transformIndentDescription => '移除文字段落开头的空白，并设置首行缩进。';

  @override
  String get transformDeduplicateDescription => '保留首个章节标题，移除后续重复的标题段落。';

  @override
  String get transformKeepFirstTitle => '每章仅保留首个标题';

  @override
  String transformIndentCharacters(int count) {
    return '首行缩进：$count 个字符';
  }

  @override
  String get transformApplicationRules => '应用级规则';

  @override
  String get transformBookRules => '本书规则';

  @override
  String get transformAddHint => '点击 + 选择转换器并进入配置页。';

  @override
  String get transformEnabled => '已启用';

  @override
  String get transformDisabled => '已停用';

  @override
  String get transformEmptyReplacement => '（空文字）';

  @override
  String transformDeleteQueued(String name) {
    return '「$name」将被删除';
  }

  @override
  String get transformUndo => '撤销';

  @override
  String get transformRemoveTitle => '删除转换器？';

  @override
  String get transformRemoveMessage => '要从组合中移除此转换器吗？';

  @override
  String get transformApplicationEditHint => '这是应用级规则。修改会影响所有继承它的书籍。';

  @override
  String get transformReorder => '拖动调整顺序';
}
