/// Integration tests for the fanqie feed script.
///
/// Mocked tests use mockito to serve a local HTTP server and replace the
/// `@base_url` / `@access_domain` header in the script so that all network
/// requests hit the mock instead of the real site. Fixtures mirror the
/// server-rendered HTML of fanqienovel.com, including the private-use-area
/// codepoints that the site's custom font obfuscation substitutes for the
/// most frequent characters (see the FONT_MAP comment in the script).
use langhuan::error::{Error, ExpectedErrorCode, ScriptError};
use langhuan::feed::Feed;
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use std::time::Duration;
use tokio_stream::StreamExt;

const BOOK_ID: &str = "7146230612570047006";
const CHAPTER_1_ID: &str = "1111111111111111111";
const CHAPTER_2_ID: &str = "2222222222222222222";
const FONT_HASH: &str = "dc027189e0ba4cd";

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Load the fanqie source script and replace its base_url / access_domain
/// so that all URLs point to the given mockito server.
fn load_script_for_server(server: &ServerGuard) -> String {
    let base = server.url(); // e.g. "http://127.0.0.1:PORT"

    let script = include_str!("../../../docs/book-sources/fanqie.js");

    // Replace the base_url header line and remove all @access_domain entries
    // so the domain allowlist is empty (empty list = no restriction).
    script
        .replace(
            "// @base_url     https://fanqienovel.com",
            &format!("// @base_url     {base}"),
        )
        .replace("// @access_domain fanqienovel.com", "")
        .replace("// @access_domain *.byteimg.com", "")
}

/// A book page mirroring the live site's layout: one `h1` title, a cover
/// image with a protocol-relative URL, `.author-name-text`, an abstract, and
/// a fully server-rendered directory. The "latest chapter" banner link also
/// carries `chapter-item-title` but sits *outside* `.page-directory-content`,
/// which is how the live page marks it.
fn book_page_html() -> String {
    r#"<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>皇后重生要谋反_番茄小说官网</title></head>
<body>
<div class="page-header-layout">
  <div class="page-header">
    <h1>皇后重生要谋反</h1>
    <img class="book-cover-img " src="//p1-tt.byteimg.com/origin/novel-static/5cb03bd354145bc7815a5e09d4b15cfc" alt="皇后重生要谋反"/>
  </div>
  <div class="info-last"><a href="/reader/2222222222222222222" class="chapter-item-title" target="_blank">最近更新：<!-- -->第2章 重生</a></div>
  <div class="author">
    <div class="author-info">
      <div class="author-name"><span class="author-name-logo"></span><span class="author-name-text">流心蜜糖</span></div>
    </div>
  </div>
</div>
<div class="page-body">
  <div class="page-abstract-header"><h2>作品简介</h2></div>
  <div class="page-abstract-content"><p>本书原名《皇后重生要谋反》。前世，她用医术替他拉拢人心。</p></div>
  <div class="page-directory-header"><h3><span>目录</span><span class="directory-dot"></span>2<!-- -->章</h3></div>
  <div class="page-directory-content">
    <div><div class="volume volume_first">第一卷<span class="volume-dot"></span>共<!-- -->2<!-- -->章</div>
    <div class="chapter">
      <div class="chapter-item"><a href="/reader/1111111111111111111" class="chapter-item-title" target="_blank">第1章 殒命</a></div>
      <div class="chapter-item"><a href="/reader/2222222222222222222" class="chapter-item-title" target="_blank">第2章 重生</a></div>
    </div>
    </div>
  </div>
</div>
</body>
</html>"#
        .to_string()
}

/// A reader page mirroring the live site: a nav `h1` with the book title, a
/// `.muye-reader-title` h1 with the chapter title, and `.muye-reader-content`
/// paragraphs whose frequent characters are private-use-area codepoints. The
/// style block references the obfuscation font by its hash, as the live page
/// does.
fn reader_page_html(font_hash: &str) -> String {
    // Raw paragraphs captured from the live site (chapter 1 of the same book).
    // The escapes are the PUA codepoints the real page stores.
    let para0 = "寒\u{e516}呼啸，漫\u{e4eb}飞雪。";
    let para1 = "\u{e4aa}\u{e4b5}\u{e500}\u{e4bc}，\u{e40f}\u{e475}素\u{e4fa}\u{e44e}静\u{e4f3}冷宫\u{e400}\u{e4fc}\u{e532}\u{e4b9}\u{e52a}\u{e44e}静，\u{e417}\u{e4de}\u{e488}\u{e488}痛苦\u{e431}\u{e4a5}隐忍\u{e4f3}呻吟\u{e4b4}\u{e4b7}\u{e4c2}\u{e4f9}颤。";

    format!(
        r#"<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8"><title>皇后重生要谋反第1章 殒命在线免费阅读_番茄小说官网</title>
<style>
.font-DNMrHsV173Pd4pgy {{ font-family: DNMrHsV173Pd4pgy, -apple-system, 'PingFang SC', sans-serif; }}
@font-face {{ font-family: DNMrHsV173Pd4pgy; src: url(https://lf3-awef.bytetos.com/obj/awesome-font/c/{font_hash}.woff2)format("woff2"), url(https://lf3-awef.bytetos.com/obj/awesome-font/c/{font_hash}.woff)format("woff"); }}
</style>
</head>
<body>
<h1 class="muye-reader-nav-title"><svg class="muyeicon-icon" viewBox="0 0 12 24"></svg>皇后重生要谋反</h1>
<div class="page-reader">
<h1 class="muye-reader-title">第1章 殒命</h1>
<div class="muye-reader-content noselect">
<p>{para0}</p>
<p>{para1}</p>
<p></p>
</div>
<div class="muye-reader-btns"><div class="chapter-btn next"><button type="button"><span>下一章</span></button></div></div>
</div>
</body>
</html>"#
    )
}

fn assert_expected_code(err: &Error, code: ExpectedErrorCode) {
    match err {
        Error::Script(ScriptError::Expected { code: actual, .. }) => {
            assert_eq!(actual, &code, "unexpected expected-error code: {err}");
        }
        other => panic!("expected a script expected-error, got: {other}"),
    }
}

// ── Search ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn search_resolves_pasted_book_url() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/page/{BOOK_ID}").as_str())
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(book_page_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    // Users paste the book-page URL because the official search API is
    // captcha-gated.
    let results: Vec<_> = feed
        .search(&format!("https://fanqienovel.com/page/{BOOK_ID}"))
        .collect::<Vec<_>>()
        .await;

    assert_eq!(results.len(), 1, "expected exactly one search result");
    let item = results
        .into_iter()
        .next()
        .unwrap()
        .expect("search yielded an error");

    assert_eq!(item.id, BOOK_ID);
    assert_eq!(item.title, "皇后重生要谋反");
    assert_eq!(item.author, "流心蜜糖");
    assert_eq!(
        item.cover_url.as_deref(),
        Some("https://p1-tt.byteimg.com/origin/novel-static/5cb03bd354145bc7815a5e09d4b15cfc"),
        "protocol-relative cover URL should be absolutized with https"
    );
    assert!(
        item.description
            .as_deref()
            .is_some_and(|d| d.contains("本书原名")),
        "description should be extracted from the abstract: {item:?}"
    );
}

#[tokio::test]
async fn search_rejects_plain_keywords() {
    let mut server = mockito::Server::new_async().await;

    // No mock is installed: a rejected keyword must fail before any request.
    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed.search("深空彼岸").collect::<Vec<_>>().await;

    assert_eq!(results.len(), 1, "expected a single error item");
    let err = results.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(&err, ExpectedErrorCode::Unknown("search_unsupported".into()));
}

// ── Book info & chapters ────────────────────────────────────────────────────

#[tokio::test]
async fn book_info_parses_metadata() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/page/{BOOK_ID}").as_str())
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(book_page_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let info = feed.book_info(BOOK_ID).await.expect("book_info failed");

    assert_eq!(info.id, BOOK_ID);
    assert_eq!(info.title, "皇后重生要谋反");
    assert_eq!(info.author, "流心蜜糖");
    assert!(info.cover_url.as_deref().is_some_and(|u| u.starts_with("https://")));
}

#[tokio::test]
async fn chapters_returns_directory_without_banner() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/page/{BOOK_ID}").as_str())
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(book_page_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed.chapters(BOOK_ID).collect::<Vec<_>>().await;

    let chapters: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("chapters stream yielded an error");

    // The "最近更新" banner link (outside .page-directory-content) must be
    // excluded even though it carries the chapter-item-title class.
    assert_eq!(
        chapters.len(),
        2,
        "expected exactly the 2 directory chapters, got {:?}",
        chapters.iter().map(|c| &c.title).collect::<Vec<_>>()
    );
    assert_eq!(chapters[0].id, CHAPTER_1_ID);
    assert_eq!(chapters[0].title, "第1章 殒命");
    assert_eq!(chapters[1].id, CHAPTER_2_ID);
    assert_eq!(chapters[1].title, "第2章 重生");
}

// ── Paragraphs ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn paragraphs_decode_font_obfuscation() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(reader_page_html(FONT_HASH))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;

    let items: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("paragraphs stream yielded an error");

    // Title first, then the two non-empty paragraphs (the trailing empty <p>
    // must be dropped).
    assert_eq!(items.len(), 3, "expected title + 2 text paragraphs");
    match &items[0] {
        langhuan::model::Paragraph::Title { text, .. } => {
            assert_eq!(text, "第1章 殒命");
        }
        other => panic!("expected a title paragraph, got {other:?}"),
    }
    let contents: Vec<&str> = items[1..]
        .iter()
        .map(|p| match p {
            langhuan::model::Paragraph::Text { content, .. } => content.as_str(),
            other => panic!("expected a text paragraph, got {other:?}"),
        })
        .collect();
    assert_eq!(contents[0], "寒风呼啸，漫天飞雪。");
    assert_eq!(
        contents[1],
        "三更已过，平日素来安静的冷宫此时却并不安静，那一声声痛苦而又隐忍的呻吟听得人心颤。"
    );
    for content in &contents {
        assert!(
            !content.chars().any(|c| ('\u{e000}'..='\u{f8ff}').contains(&c)),
            "decoded paragraph still contains private-use codepoints: {content:?}"
        );
    }
}

#[tokio::test]
async fn paragraphs_reject_rotated_font() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(reader_page_html("0123456789abcdef"))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;

    // A rotated obfuscation font must fail loudly instead of decoding into
    // mojibake.
    assert_eq!(results.len(), 1);
    let err = results.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(
        &err,
        ExpectedErrorCode::Unknown("font_mapping_outdated".into()),
    );
}

#[tokio::test]
async fn paragraphs_report_missing_chapter() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .with_status(404)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body("<html><body>not found</body></html>")
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;

    assert_eq!(results.len(), 1);
    let err = results.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(&err, ExpectedErrorCode::ContentNotFound);
}

// ── Live site ───────────────────────────────────────────────────────────────

/// Real-site smoke test against https://fanqienovel.com.
///
/// Ignored by default because it depends on external network, target-site
/// availability, and the current obfuscation font staying in rotation.
#[tokio::test]
#[ignore = "hits real website"]
async fn live_site_smoke() {
    let script = include_str!("../../../docs/book-sources/fanqie.js");
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(script)
        .await
        .expect("load_script failed");

    // 皇后重生要谋反 — a completed book with a large SSR directory.
    let search_future = feed
        .search("https://fanqienovel.com/page/6823667291557727235")
        .take(5)
        .collect::<Vec<_>>();
    let results = tokio::time::timeout(Duration::from_secs(30), search_future)
        .await
        .expect("live search timed out after 30s");

    assert_eq!(results.len(), 1, "expected exactly one search result");
    let book = results
        .into_iter()
        .next()
        .unwrap()
        .expect("live search yielded an error");
    assert_eq!(book.title, "皇后重生要谋反");
    assert!(!book.author.trim().is_empty());

    let chapters_future = feed.chapters(&book.id).take(2000).collect::<Vec<_>>();
    let chapters = tokio::time::timeout(Duration::from_secs(60), chapters_future)
        .await
        .expect("live chapters timed out after 60s");

    assert!(
        chapters.len() > 900,
        "expected the full directory to be server-rendered, got {} items",
        chapters.len()
    );
    for c in &chapters {
        assert!(c.is_ok(), "live chapters yielded error: {c:?}");
    }
    let chapters: Vec<_> = chapters.into_iter().filter_map(|c| c.ok()).collect();
    let first_chapter = chapters.first().expect("expected a first chapter");

    let paragraphs_future = feed
        .paragraphs(&book.id, &first_chapter.id)
        .take(200)
        .collect::<Vec<_>>();
    let paragraphs = tokio::time::timeout(Duration::from_secs(30), paragraphs_future)
        .await
        .expect("live paragraphs timed out after 30s");

    assert!(!paragraphs.is_empty(), "live paragraphs returned no items");
    for p in &paragraphs {
        assert!(p.is_ok(), "live paragraphs yielded error: {p:?}");
    }
    let paragraphs: Vec<_> = paragraphs.into_iter().filter_map(|p| p.ok()).collect();

    let mut text_count = 0usize;
    for paragraph in &paragraphs {
        let content = match paragraph {
            langhuan::model::Paragraph::Text { content, .. } => content,
            langhuan::model::Paragraph::Title { text, .. } => text,
            langhuan::model::Paragraph::Image { .. } => continue,
        };
        assert!(
            !content.chars().any(|c| ('\u{e000}'..='\u{f8ff}').contains(&c)),
            "live paragraph still contains undecoded private-use codepoints: {content:?}"
        );
        if matches!(paragraph, langhuan::model::Paragraph::Text { .. }) {
            text_count += 1;
        }
    }
    assert!(text_count > 0, "expected decoded text paragraphs");
}
