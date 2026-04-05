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
  String get navProfile => '設置';

  @override
  String get bookshelfTitle => '書架';

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
  String get searchTitle => '搜索';

  @override
  String get searchHintNoFeed => '請先選擇書源…';

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
  String get searchLoadingMore => '加載更多…';

  @override
  String get bookDetailTitle => '書籍詳情';

  @override
  String get bookDetailError => '加載書籍信息失敗';

  @override
  String get bookDetailRetry => '重試';

  @override
  String get bookDetailStartReading => '開始閱讀';

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
  String get bookDetailSourceSupportsBookshelf => '當前書源支持書架功能';

  @override
  String get bookDetailSourceNoBookshelf => '當前書源不支持書架功能';

  @override
  String get readerTitle => '閱讀';

  @override
  String get readerMissingParams => '缺少閱讀參數';

  @override
  String get readerLoadError => '加載章節失敗';

  @override
  String get readerEmpty => '暫無章節正文';

  @override
  String get readerAtFirstChapter => '已是第一章';

  @override
  String get readerAtLastChapter => '已是最後一章';

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
  String readerChapterFallbackTitle(int index) {
    return '第 $index 章';
  }

  @override
  String get feedsTitle => '書源';

  @override
  String get feedsSearchHint => '搜索書源…';

  @override
  String get feedsEmpty => '暫無書源\n請將腳本文件放入 scripts 文件夾';

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
  String get feedDetailVersion => '版本';

  @override
  String get feedDetailAuthor => '作者';

  @override
  String get feedDetailTooltip => '詳情';

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
  String feedDeleteSuccess(String feedName) {
    return '已刪除 $feedName';
  }

  @override
  String get feedDeleteError => '刪除書源失敗';

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
  String get profileTitle => '設置';

  @override
  String get profileSubtitle => '管理你的偏好設置';

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
  String get errorSomethingWrong => '出現錯誤';

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
  String get addFeedPickFile => '選擇腳本文件';

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
  String get addFeedInstall => '安裝';

  @override
  String get addFeedSuccess => '書源安裝成功';

  @override
  String get addFeedErrorPreview => '預覽書源失敗';

  @override
  String get addFeedErrorInstall => '安裝書源失敗';
}
