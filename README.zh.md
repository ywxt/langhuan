# 琅嬛 (Langhuan)

一款支持**自定義書源**的跨平台網路小說閱讀器。編寫一個沙盒化 JavaScript reducer，指向任意網站，即可開始閱讀——無需更新應用。

使用 Flutter（UI）、Rust（後端）和隔離的原生 QuickJS 執行環境（腳本）構建。

> [English version](README.md)

## 功能

- **沙盒化 JavaScript 書源** — 通過 schema 3 reducer 定義搜索與解析；HTTP 和認證由 Rust 掌控，腳本在無系統能力的原生 QuickJS 執行環境中運行。
- **緩存管理** — 本地章節緩存，自動清理過期數據；書架中的書籍不會被清理。
- **本地化** — 支持英文和中文。

## 技術棧

| 層級 | 技術                          |
| ---- | ----------------------------- |
| UI   | Flutter + Riverpod + GoRouter |
| 橋接 | flutter_rust_bridge v2        |
| 後端 | Rust + Tokio（Actor 模型）    |
| 腳本 | 原生 QuickJS 沙盒              |
| HTTP | reqwest + rustls              |

## 項目結構

```
lib/                        # Flutter 前端
├── features/               # 功能模塊（書架、書源、設置）
├── router/                 # GoRouter 路由配置
├── shared/                 # 共享服務、主題、組件
└── l10n/                   # 國際化資源（ARB）

native/langhuan/            # Rust 核心庫（純領域邏輯）
├── src/
│   ├── script/             # 原生 QuickJS 沙盒與書源運行時
│   ├── cache/              # 緩存存儲
│   ├── bookshelf/          # 書架持久化
│   ├── progress/           # 閱讀進度
│   ├── auth/               # 登錄認證
│   └── feed/               # 書源加載與註冊

native/hub/                 # FRB 橋接層 + Actor 系統
├── src/
│   ├── api/                # FRB API（Dart 可調用的公開函數）
│   └── actors/             # 消息傳遞 Actor
```

## 構建

### 使用 Nix（推薦）

開發環境完全聲明式：Nix flake 提供 Flutter（stable）、帶 Android 交叉編譯 target 的 Rust 穩定工具鏈、綁定生成器、許可證已預接受的 Android SDK/NDK、模擬器，以及一個 Pixel 7 AVD（Android 16），AVD 存放在項目內的 `.avd/` 目錄。SDK 攜帶應用及其插件編譯所需的全部平臺（API 35、36），以及 AVD 啓動所需的唯一系統鏡像（API 36），構建期間不會再下載任何內容。

環境要求：x86_64-linux 主機上的 Nix（含 flakes）與 [direnv](https://direnv.net/)。

```bash
direnv allow                            # 或：nix develop
flutter doctor                          # 所有項目應爲綠色
flutter_rust_bridge_codegen generate    # 首次構建前必須執行
emulator -avd Pixel_7_API_36            # 可選：啓動模擬器
flutter run                             # 在真機或模擬器上運行
flutter build apk --release             # 或 --debug；APK 在 build/app/outputs/flutter-apk/
```

`flutter run -d linux` 同樣可用。

### 不使用 Nix

手動安裝工具鏈：

- [Flutter SDK](https://docs.flutter.dev/get-started/install)（stable，Dart ≥ 3.11.3）
- [Rust 工具鏈](https://www.rust-lang.org/tools/install)，並添加 Android 交叉編譯 target：

  ```bash
  rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
  ```

- Android SDK（許可證已接受、帶 Flutter 所釘定的 NDK 版本；缺什麼 `flutter doctor` 會指出）

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0   # 僅首次
flutter doctor
flutter_rust_bridge_codegen generate    # 首次構建前必須執行
flutter run
```

### 綁定

後續修改 Rust API（`native/hub/src/api/` 中的函數）後，需重新執行 `flutter_rust_bridge_codegen generate` 更新綁定。生成的 Dart 代碼位於 `lib/src/rust/`，生成的 Rust 代碼位於 `native/hub/src/frb_generated.rs`——請勿手動編輯這些文件。

> `flutter_rust_bridge` 的版本需要在 Dart 運行時（`pubspec.lock`）、Rust crate（`native/hub/Cargo.toml`）與代碼生成器之間保持一致。Nix 環境下執行 `nix flake update` 後運行 `flutter pub upgrade flutter_rust_bridge`，下次 `generate` 時生成器會自動升級 Rust crate；手動環境請保持 `cargo install` 的生成器版本一致。

## 書源腳本

書源是 schema 3 JavaScript reducer；它返回請求描述，所有 HTTP 均由原生 Rust 執行。完整指南、沙盒契約和示例請見[書源文檔](docs/book-sources/README.md)。

## 許可證

本項目使用 [MIT 許可證](LICENSE) 授權。
