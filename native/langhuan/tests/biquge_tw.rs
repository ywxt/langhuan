/// Integration tests for the biquge-tw feed script.
///
/// These tests use mockito to serve a local HTTP server and replace the
/// `@base_url` / `@allowed_domain` header in the script so that all network
/// requests hit the mock instead of the real site.
use langhuan::feed::Feed;
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use std::time::Duration;
use tokio_stream::StreamExt;

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Load the biquge-tw source script and replace its base_url / allowed_domain
/// so that all URLs point to the given mockito server.
fn load_script_for_server(server: &ServerGuard) -> String {
    let base = server.url(); // e.g. "http://127.0.0.1:PORT"

    let script = include_str!("../../../docs/book-sources/biquge-tw.lua");

    // Replace the base_url header line.
    let script = script.replace(
        "-- @base_url     https://www.biquge.tw",
        &format!("-- @base_url     {base}"),
    );

    // Remove all @allowed_domain entries so the domain allowlist is empty
    // (empty list = no restriction), allowing requests to the local mock server.
    let script = script
        .replace("-- @allowed_domain www.biquge.tw", "")
        .replace("-- @allowed_domain m.biquge.tw", "")
        .replace("-- @allowed_domain img.biquge.tw", "");

    script
}

/// Build a minimal HTML search-results page that the biquge-tw parser can
/// process.  The selector used by the script is:
///   `a[href*="/book/"][href$=".html"]`
/// and IDs are extracted with the pattern `/book/(%d+)%.html`.
fn search_results_html() -> String {
    r#"<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>搜尋結果</title></head>
<body>
<div class="result-list">
  <div class="result-item">
    <a href="/book/12345.html">剛好遇見你</a>
  </div>
  <div class="result-item">
    <a href="/book/67890.html">剛好是你</a>
  </div>
</div>
</body>
</html>"#
        .to_string()
}

    /// Build a minimal chapter-content page that the biquge-tw paragraph parser
    /// can process.
    fn chapter_content_html() -> String {
        r#"<!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8"><title>第一章 測試章節</title></head>
    <body>
    <h1>第一章 測試章節</h1>
    <div id="content">
      <p>這是一段測試正文。</p>
      <p>這是第二段測試正文。</p>
    </div>
    </body>
    </html>"#
        .to_string()
    }

    /// Build a chapter page where正文 is under #chaptercontent and split by <br>,
    /// which is a common layout on live sites.
    fn chapter_content_br_html() -> String {
        r#"<!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8"><title>第二章 測試章節</title></head>
    <body>
    <h1>第二章 測試章節</h1>
    <div id="chaptercontent" class="Readarea ReadAjax_content">
      第一段<br><br />第二段<br/>第三段
    </div>
    </body>
    </html>"#
        .to_string()
    }

// ── Tests ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn search_returns_results() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/search/".to_string()))
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(search_results_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(&script).await.expect("load_feed failed");

    let results: Vec<_> = feed
        .search("剛好")
        .collect::<Vec<_>>()
        .await;

    assert!(!results.is_empty(), "expected at least one search result");

    // All items should be Ok.
    for r in &results {
        assert!(r.is_ok(), "stream yielded an error: {:?}", r);
    }

    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();
    assert_eq!(items.len(), 2, "expected exactly 2 results, got {}", items.len());

    let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
    assert!(ids.contains(&"12345"), "expected book id 12345, got {:?}", ids);
    assert!(ids.contains(&"67890"), "expected book id 67890, got {:?}", ids);

    let titles: Vec<&str> = items.iter().map(|i| i.title.as_str()).collect();
    assert!(
        titles.iter().any(|t| t.contains("剛好")),
        "expected titles containing '剛好', got {:?}",
        titles
    );

    // Verify search-result fields are complete under current parser behavior.
    for item in &items {
        assert!(!item.id.trim().is_empty(), "id should not be empty: {item:?}");
        assert!(
            !item.title.trim().is_empty(),
            "title should not be empty: {item:?}"
        );
        assert!(
            !item.author.trim().is_empty(),
            "author should not be empty: {item:?}"
        );
        // Current parser may not provide these fields from search HTML.
        assert!(item.cover_url.is_none() || item.cover_url.as_deref().unwrap().starts_with("http") || item.cover_url.as_deref().unwrap().starts_with('/'));
        assert!(item.description.is_none() || !item.description.as_deref().unwrap().trim().is_empty());
    }
}

#[tokio::test]
async fn paragraphs_returns_title_and_text_items() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", "/book/12345/67890.html")
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(chapter_content_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(&script).await.expect("load_feed failed");

    let results: Vec<_> = feed.paragraphs("12345/67890").collect::<Vec<_>>().await;

    assert!(!results.is_empty(), "expected paragraph stream items");
    for r in &results {
        assert!(r.is_ok(), "paragraph stream yielded an error: {r:?}");
    }

    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();
    assert!(!items.is_empty(), "expected at least one paragraph item");

    let has_title = items
        .iter()
        .any(|p| matches!(p, langhuan::model::Paragraph::Title { .. }));
    let has_text = items
        .iter()
        .any(|p| matches!(p, langhuan::model::Paragraph::Text { .. }));

    assert!(has_title || has_text, "expected title/text paragraph content");
    assert!(has_text, "expected at least one text paragraph");
}

#[tokio::test]
async fn paragraphs_supports_chaptercontent_br_layout() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", "/book/12345/24680.html")
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(chapter_content_br_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(&script).await.expect("load_feed failed");

    let results: Vec<_> = feed.paragraphs("12345/24680").collect::<Vec<_>>().await;
    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();

    let text_items: Vec<_> = items
        .iter()
        .filter_map(|p| match p {
            langhuan::model::Paragraph::Text { content } => Some(content.as_str()),
            _ => None,
        })
        .collect();

    assert!(
        !text_items.is_empty(),
        "expected at least one text item from #chaptercontent br layout"
    );

    let combined = text_items.join("\n");
    assert!(
        combined.contains("第一段") || combined.contains("第二段") || combined.contains("第三段"),
        "expected extracted text from chaptercontent, got: {combined}"
    );
}

#[tokio::test]
async fn search_returns_empty_for_no_matches() {
    let mut server = mockito::Server::new_async().await;

    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/search/".to_string()))
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(
            r#"<!DOCTYPE html><html><body><p>沒有找到結果</p></body></html>"#,
        )
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(&script).await.expect("load_feed failed");

    let results: Vec<_> = feed.search("不存在的書名xyz").collect::<Vec<_>>().await;

    // Empty results are valid — no error, just no items.
    for r in &results {
        assert!(r.is_ok(), "unexpected error: {:?}", r);
    }
    assert!(results.is_empty(), "expected no results for empty page");
}

#[tokio::test]
async fn search_detects_cloudflare_challenge() {
    let mut server = mockito::Server::new_async().await;

    // Simulate a Cloudflare challenge page.
    let cf_body = r#"<!DOCTYPE html>
<html>
<head><title>Just a moment...</title></head>
<body>
<div id="cf_chl_opt">challenge data</div>
<p>Just a moment...</p>
</body>
</html>"#;

    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/search/".to_string()))
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(cf_body)
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(&script).await.expect("load_feed failed");

    let results: Vec<_> = feed.search("剛好").collect::<Vec<_>>().await;

    // The Cloudflare check in the Lua script calls `error(...)`, which should
    // surface as an Err in the stream.
    assert!(
        results.iter().any(|r| r.is_err()),
        "expected a Cloudflare error to be yielded by the stream"
    );
}

/// Real-site smoke test against https://www.biquge.tw.
///
/// This test is ignored by default because it depends on external network,
/// target-site availability, and anti-bot behavior.
#[tokio::test]
#[ignore = "hits real website"]
async fn search_live_site_smoke() {
    let script = include_str!("../../../docs/book-sources/biquge-tw.lua");
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(script).await.expect("load_feed failed");

    // Bound runtime and result count to avoid hanging/flaky pagination.
    let collect_future = feed.search("剛好").take(10).collect::<Vec<_>>();
    let results = tokio::time::timeout(Duration::from_secs(30), collect_future)
        .await
        .expect("live search timed out after 30s");

    assert!(
        !results.is_empty(),
        "live search returned no items (possible site/layout change)"
    );

    for item in &results {
        assert!(
            item.is_ok(),
            "live search yielded error (possibly Cloudflare/anti-bot): {:?}",
            item
        );
    }

    let search_items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();
    assert!(!search_items.is_empty(), "live search returned no Ok items");

    for item in &search_items {
        assert!(!item.id.trim().is_empty(), "live item id should not be empty");
        assert!(
            !item.title.trim().is_empty(),
            "live item title should not be empty"
        );
        assert!(
            !item.author.trim().is_empty(),
            "live item author should not be empty"
        );
    }

    // Paragraph-content live smoke: search -> first book -> first chapter -> paragraphs.
    let first_book = search_items.first().expect("expected first live search item");
    let chapters_future = feed.chapters(&first_book.id).take(30).collect::<Vec<_>>();
    let chapters = tokio::time::timeout(Duration::from_secs(30), chapters_future)
        .await
        .expect("live chapters timed out after 30s");

    assert!(!chapters.is_empty(), "live chapters returned no items");
    for c in &chapters {
        assert!(
            c.is_ok(),
            "live chapters yielded error (possibly layout change): {:?}",
            c
        );
    }

    let chapters: Vec<_> = chapters.into_iter().filter_map(|c| c.ok()).collect();
    let first_chapter = chapters.first().expect("expected first chapter item");

    let paragraphs_future = feed.paragraphs(&first_chapter.id).take(100).collect::<Vec<_>>();
    let paragraphs = tokio::time::timeout(Duration::from_secs(30), paragraphs_future)
        .await
        .expect("live paragraphs timed out after 30s");

    assert!(!paragraphs.is_empty(), "live paragraphs returned no items");
    for p in &paragraphs {
        assert!(
            p.is_ok(),
            "live paragraphs yielded error (possibly anti-bot/layout change): {:?}",
            p
        );
    }

    let paragraphs: Vec<_> = paragraphs.into_iter().filter_map(|p| p.ok()).collect();
    let has_title_or_text = paragraphs.iter().any(|p| {
        matches!(
            p,
            langhuan::model::Paragraph::Title { .. } | langhuan::model::Paragraph::Text { .. }
        )
    });
    assert!(
        has_title_or_text,
        "expected live paragraph content to contain title or text"
    );
}
