# 琅嬛（Langhuan）

琅嬛是一款跨平台網絡小說閱讀器，把不同網站的內容整理成統一、安靜的閱讀體驗。添加你信任的書源後，可以跨源搜索、建立個人書架，並在不依賴單一平台和目錄的情況下繼續閱讀。

> [English version](README.md)

## 你可以做什麼

- **使用自己的書源** — 無需等待應用更新即可導入 JavaScript 書源。普通 HTML 網站、需要登錄的網站以及需要多次請求才能取得章節的網站，都使用同一套模型。
- **統一搜索** — 可以搜索單個書源，也可以聚合所有已啓用書源；某個書源失敗不會清空其他來源的結果。
- **真正可用的書架** — 點擊書籍直接閱讀，查看閱讀與章節進度，檢查更新、收藏段落，並通過統一的滑動操作管理書籍。
- **選擇閱讀方式** — 支持橫向翻頁和無縫縱向閱讀，可調整字體、間距並創建自定義閱讀主題。
- **按習慣轉換中文** — 閱讀時可轉換為繁體、臺灣地區字詞或香港字形。
- **把常用數據留在本地** — 緩存書籍與章節以便快速打開；清理緩存時保留書架內容；支持導入和導出書源。
- **在需要時登錄** — 在內嵌瀏覽器中完成登錄或人工驗證，之後由書源把會話用於原生網絡請求。

## 從設計上限制書源權限

書源拿不到 HTTP 客戶端，也不能訪問文件系統、環境變量或進程。腳本只能描述它需要的請求；Rust 主程序會檢查目標域名是否已在書源中聲明，再代表書源執行請求。腳本運行在有內存、時間和結果大小限制的原生 QuickJS 沙箱中，HTML 解析、編碼和密碼學等能力必須通過明確的模塊導入。

書源仍然屬於第三方代碼。導入前請確認發布者、書源 ID 和聲明的訪問域名；只有在信任書源時才通過它登錄賬號。

## 支持平台

項目目標平台包括 Android、Linux、macOS 和 Windows。添加標籤的版本會生成各平台安裝包；項目仍在積極開發中，實際發布包可能因版本而異。

## 書源開發

從[書源文檔入口](docs/book-sources/README.md)開始：

- [架構與執行原理](docs/book-sources/architecture.md)
- [從零編寫書源](docs/book-sources/writing-a-source.md)
- [沙箱能力與限制](docs/book-sources/sandbox.md)
- [宿主模塊 API Reference](docs/book-sources/api-reference.md)

倉庫的 [`docs/book-sources`](docs/book-sources) 目錄同時包含普通 HTML、登錄認證和加密內容等不同複雜度的實際示例。

## 開發與構建

推薦在 x86_64 Linux 上使用倉庫提供的 Nix flake。它包含 Flutter、Rust、Android SDK/NDK、模擬器和匹配版本的 `flutter_rust_bridge` 生成器。

```bash
nix develop
flutter_rust_bridge_codegen generate
flutter run
```

不使用 Nix 時，需要自行安裝 Flutter、Rust、對應平台工具鏈以及 `flutter_rust_bridge_codegen` 2.13.0。修改 `native/hub/src/api/` 下的接口後必須重新生成橋接代碼；不要手動編輯 `lib/src/rust/` 和 `native/hub/src/frb_generated.rs` 中的生成文件。

常用檢查：

```bash
flutter analyze
flutter test
cargo test --workspace
```

## 項目狀態

琅嬛仍處於積極開發階段。首個穩定版本之前，書源協議可能繼續演進；倉庫中的書源是實現示例，不代表第三方網站會長期保持兼容。

## 許可證

琅嬛使用 [MIT License](LICENSE)。個別示例書源可能包含獨立的許可證聲明。
