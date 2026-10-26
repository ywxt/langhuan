/// Integration tests for the qidian feed script.
///
/// Mocked tests use mockito to serve a local HTTP server and replace the
/// `@base_url` / `@access_domain` header in the script so that all network
/// requests hit the mock instead of the real site. Fixtures mirror the
/// server-rendered JSON that m.qidian.com embeds in every page inside
/// `<script id="vite-plugin-ssr_pageContext">`.
use langhuan::error::{Error, ExpectedErrorCode, ScriptError};
use langhuan::feed::{AuthPageContext, CookieEntry, Feed, FeedAuthFlow};
use langhuan::http::HttpBody;
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use std::time::Duration;
use tokio_stream::StreamExt;

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Load the qidian source script and replace its base_url / access_domain
/// so that all URLs point to the given mockito server.
fn load_script_for_server(server: &ServerGuard) -> String {
    let base = server.url(); // e.g. "http://127.0.0.1:PORT"

    let script = include_str!("../../../docs/book-sources/qidian.lua");

    // Replace the base_url header line and remove all @access_domain entries
    // so the domain allowlist is empty (empty list = no restriction).
    script
        .replace(
            "-- @base_url     https://m.qidian.com",
            &format!("-- @base_url     {base}"),
        )
        .replace("-- @access_domain m.qidian.com", "")
        .replace("-- @access_domain www.qidian.com", "")
}

/// Wrap a `pageContext` JSON value in the same script tag the live site uses.
fn ssr_page(page_context_json: &str) -> String {
    format!(
        r#"<!DOCTYPE html><html><head><meta charset="UTF-8">
<script id="vite-plugin-ssr_pageContext" type="application/json">{{"pageContext":{page_context_json}}}</script>
</head><body><div class="app"><div id="app"></div></div></body></html>"#
    )
}

async fn load_feed(server: &ServerGuard) -> langhuan::script::lua::LuaFeed {
    let script = load_script_for_server(server);
    let engine = ScriptEngine::new();
    engine.load_feed(&script).await.expect("load_feed failed")
}

fn cookie(name: &str, value: &str, domain: &str) -> CookieEntry {
    CookieEntry {
        name: name.to_owned(),
        value: value.to_owned(),
        domain: Some(domain.to_owned()),
        path: Some("/".to_owned()),
        expires: None,
        secure: None,
        http_only: None,
        same_site: None,
    }
}

// ── Fixtures (trimmed from live m.qidian.com pages) ─────────────────────────

fn search_page_json() -> String {
    r#"{"pageProps":{"pageData":{"bookInfo":{"records":[
        {"bid":1010868264,"bName":"诡秘之主","bAuth":"爱潜水的乌贼",
         "desc":"蒸汽与机械的浪潮中，谁能触及非凡？",
         "imgUrl":"//bookcover.yuewen.com/qdbimg/349573/1010868264/180",
         "cat":"玄幻","state":"完结","cnt":"446.77万字"},
        {"bid":1047654482,"bName":"星河之主","bAuth":"烽仙",
         "desc":"高武世界的故事。",
         "imgUrl":"//bookcover.yuewen.com/qdbimg/349573/1047654482/180",
         "cat":"玄幻","state":"连载","cnt":"180.69万字"}
    ]},"user":{"guid":0,"isLogin":false}}}}"#
        .to_owned()
}

fn book_page_json() -> String {
    r#"{"pageProps":{"pageData":{"bookInfo":{
        "bookId":1010868264,"bookName":"诡秘之主","authorName":"爱潜水的乌贼",
        "desc":"诡秘之主动画特别篇已在腾讯视频上播出。<br>蒸汽与机械的浪潮中，谁能触及非凡？",
        "bookStatus":"完本","chanName":"玄幻","showWordsCnt":"446.77万"
    },"user":{"guid":0,"isLogin":false}}}}"#
        .to_owned()
}

/// The cover is not part of the JSON — it is rendered as a lazy-loaded img.
fn book_page_html() -> String {
    let mut page = ssr_page(&book_page_json());
    page = page.replace(
        "<div id=\"app\"></div>",
        "<div class=\"detail__header-cover\"><img src=\"https://placeholder.example/1.png\" \
         data-src=\"//bookcover.yuewen.com/qdbimg/349573/1010868264/180\" \
         class=\"detail__header-cover__img\" alt=\"诡秘之主在线阅读\"></div>",
    );
    page
}

fn catalog_page_json() -> String {
    // Volumes deliberately out of order to verify _index sorting; the second
    // chapter of volume 2 reuses volume 1's chapter id to verify dedup.
    r#"{"pageProps":{"pageData":{"vs":[
        {"_index":1,"vN":"第二卷","cs":[
            {"id":200,"cN":"第二章","cnt":3000,"sS":0},
            {"id":201,"cN":"第三章","cnt":3100,"sS":0},
            {"id":100,"cN":"第一章（重複）","cnt":2400,"sS":1}
        ]},
        {"_index":0,"vN":"第一卷","cs":[
            {"id":100,"cN":"第一章","cnt":2425,"sS":1}
        ]}
    ],"user":{"guid":0,"isLogin":false}}}}"#
        .to_owned()
}

fn chapter_page_json(vip_status: i64, is_buy: i64, logged_in: bool, content: &str) -> String {
    serde_json::json!({
        "pageProps": {
            "pageData": {
                "chapterInfo": {
                    "chapterName": "第一章 绯红",
                    "vipStatus": vip_status,
                    "isBuy": is_buy,
                    "salesMode": 1,
                    "wordsCount": 2425,
                    "next": 402760766,
                    "prev": -1,
                    // `content` is a JSON-encoded string, e.g. "\"<p>text\"".
                    "content": serde_json::from_str::<serde_json::Value>(content)
                        .expect("content fixture must be valid JSON"),
                },
                "user": {
                    "guid": if logged_in { 12345 } else { 0 },
                    "isLogin": logged_in,
                },
            },
        },
    })
    .to_string()
}

fn free_chapter_content() -> &'static str {
    "\"<p>　　痛！<p>　　好痛！<p>　　头好痛！<p>　　光怪陆离满是低语的梦境迅速支离破碎，熟睡中的周明瑞只觉脑袋抽痛异常，仿佛被人用棒子狠狠抡了一下。\""
}

fn status_page_json(logged_in: bool) -> String {
    serde_json::json!({
        "pageProps": {
            "pageData": {
                "bookInfo": {"records": []},
                "user": {
                    "guid": if logged_in { 12345 } else { 0 },
                    "isLogin": logged_in,
                },
            },
        },
    })
    .to_string()
}

// ── Search ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn search_parses_ssr_records() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/soushu/".to_owned()))
        .with_status(200)
        .with_header("content-type", "text/html; charset=utf-8")
        .with_body(ssr_page(&search_page_json()))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.search("诡秘").collect::<Vec<_>>().await;

    for r in &results {
        assert!(r.is_ok(), "stream yielded an error: {r:?}");
    }
    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();
    assert_eq!(items.len(), 2, "expected 2 results, got {}", items.len());

    let by_id = |id: &str| items.iter().find(|i| i.id == id).unwrap();
    assert_eq!(by_id("1010868264").title, "诡秘之主");
    assert_eq!(by_id("1010868264").author, "爱潜水的乌贼");
    assert_eq!(
        by_id("1010868264").cover_url.as_deref(),
        Some("https://bookcover.yuewen.com/qdbimg/349573/1010868264/180"),
        "protocol-relative cover URL should become absolute https"
    );
    assert_eq!(by_id("1047654482").title, "星河之主");
    assert!(
        by_id("1010868264")
            .description
            .as_deref()
            .is_some_and(|d| d.contains("蒸汽与机械")),
        "description should be extracted: {:?}",
        by_id("1010868264").description
    );
}

#[tokio::test]
async fn search_returns_empty_for_no_match() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/soushu/".to_owned()))
        .with_status(200)
        .with_body(ssr_page(&status_page_json(false)))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.search("不存在的書名xyz").collect::<Vec<_>>().await;

    for r in &results {
        assert!(r.is_ok(), "unexpected error: {r:?}");
    }
    assert!(results.is_empty(), "expected no results for empty page");
}

#[tokio::test]
async fn search_detects_waf_challenge() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", mockito::Matcher::Regex(r"^/soushu/".to_owned()))
        .with_status(202)
        .with_body(
            r#"<!doctype html><html><head><script src="/C2WF946J0/probev3.js" r='m'></script></head><body></body></html>"#,
        )
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.search("诡秘").collect::<Vec<_>>().await;

    let err = results
        .iter()
        .find_map(|r| r.as_ref().err())
        .expect("expected a WAF challenge error");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::CfChallenge,
                ..
            })
        ),
        "expected cf_challenge, got: {err:?}"
    );
}

// ── Book info ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn book_info_parses_json_and_cover() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/book/1010868264/")
        .with_status(200)
        .with_body(book_page_html())
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let info = feed
        .book_info("1010868264")
        .await
        .expect("book_info failed");

    assert_eq!(info.id, "1010868264");
    assert_eq!(info.title, "诡秘之主");
    assert_eq!(info.author, "爱潜水的乌贼");
    assert_eq!(
        info.cover_url.as_deref(),
        Some("https://bookcover.yuewen.com/qdbimg/349573/1010868264/180"),
        "cover should come from img.detail__header-cover__img data-src"
    );
    assert!(
        info.description
            .as_deref()
            .is_some_and(|d| d.contains("蒸汽与机械")),
        "description should be extracted: {:?}",
        info.description
    );
}

#[tokio::test]
async fn book_info_missing_context_raises_content_not_found() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/book/999999999/")
        .with_status(200)
        .with_body("<html><body>错误页</body></html>")
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let err = feed
        .book_info("999999999")
        .await
        .expect_err("expected content_not_found");

    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::ContentNotFound,
                ..
            })
        ),
        "expected content_not_found, got: {err:?}"
    );
}

// ── Chapters ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn chapters_flattens_volumes_in_order() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/book/1010868264/catalog/")
        .with_status(200)
        .with_body(ssr_page(&catalog_page_json()))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.chapters("1010868264").collect::<Vec<_>>().await;

    for r in &results {
        assert!(r.is_ok(), "chapters stream error: {r:?}");
    }
    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();

    let ids: Vec<&str> = items.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["100", "200", "201"],
        "volumes should be sorted by _index and duplicate chapter ids dropped"
    );
    assert_eq!(items[0].title, "第一章");
    assert_eq!(items[2].title, "第三章");
}

// ── Paragraphs ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn paragraphs_free_chapter_title_and_text() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/chapter/1010868264/402733549/")
        .with_status(200)
        .with_body(ssr_page(&chapter_page_json(
            0,
            0,
            false,
            free_chapter_content(),
        )))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed
        .paragraphs("1010868264", "402733549")
        .collect::<Vec<_>>()
        .await;

    for r in &results {
        assert!(r.is_ok(), "paragraphs stream error: {r:?}");
    }
    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();

    let title = items.iter().find_map(|p| match p {
        langhuan::model::Paragraph::Title { text, .. } => Some(text.clone()),
        _ => None,
    });
    assert_eq!(title.as_deref(), Some("第一章 绯红"));

    let texts: Vec<_> = items
        .iter()
        .filter_map(|p| match p {
            langhuan::model::Paragraph::Text { content, .. } => Some(content.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(texts.len(), 4, "expected 4 text paragraphs, got {texts:?}");
    assert!(texts.iter().any(|t| t.contains("痛！")), "texts: {texts:?}");
    // The fullwidth indent (U+3000) that Qidian prefixes is preserved.
    assert!(
        texts.iter().all(|t| t.starts_with('\u{3000}')),
        "fullwidth indent should be preserved: {texts:?}"
    );
}

#[tokio::test]
async fn paragraphs_vip_without_login_raises_auth_required() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/chapter/1010868264/414074529/")
        .with_status(200)
        .with_body(ssr_page(&chapter_page_json(
            1,
            0,
            false,
            "\"<p>　　预览内容。\"",
        )))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed
        .paragraphs("1010868264", "414074529")
        .collect::<Vec<_>>()
        .await;

    let err = results
        .iter()
        .find_map(|r| r.as_ref().err())
        .expect("expected an auth_required error");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::AuthRequired,
                ..
            })
        ),
        "expected auth_required, got: {err:?}"
    );
}

#[tokio::test]
async fn paragraphs_vip_not_purchased_raises_content_not_found() {
    let mut server = mockito::Server::new_async().await;
    // Logged in but isBuy == 0 with only a short preview.
    let _mock = server
        .mock("GET", "/chapter/1010868264/414074529/")
        .with_status(200)
        .with_body(ssr_page(&chapter_page_json(
            1,
            0,
            true,
            "\"<p>　　预览内容。\"",
        )))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed
        .paragraphs("1010868264", "414074529")
        .collect::<Vec<_>>()
        .await;

    let err = results
        .iter()
        .find_map(|r| r.as_ref().err())
        .expect("expected a content_not_found error");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::ContentNotFound,
                ..
            })
        ),
        "expected content_not_found for unpurchased VIP chapter, got: {err:?}"
    );
}

#[tokio::test]
async fn paragraphs_vip_purchased_returns_content() {
    let mut server = mockito::Server::new_async().await;
    // Logged in and purchased — the full text is returned even though it is
    // a VIP chapter.
    let _mock = server
        .mock("GET", "/chapter/1010868264/414074529/")
        .with_status(200)
        .with_body(ssr_page(&chapter_page_json(
            1,
            1,
            true,
            free_chapter_content(),
        )))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed
        .paragraphs("1010868264", "414074529")
        .collect::<Vec<_>>()
        .await;

    for r in &results {
        assert!(r.is_ok(), "purchased VIP chapter should parse: {r:?}");
    }
    assert!(!results.is_empty());
}

// ── Login flow ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn login_entry_points_to_passport() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;

    let support = feed.supports_auth().expect("qidian feed supports auth");
    let entry = feed.auth_entry(&support).expect("auth_entry failed");

    assert!(
        entry
            .url
            .starts_with("https://passport.qidian.com/?returnurl="),
        "entry should point at the Yuewen passport: {}",
        entry.url
    );
    assert!(
        entry.url.contains("m.qidian.com"),
        "entry url: {}",
        entry.url
    );
    assert_eq!(entry.title.as_deref(), Some("起點中文網登錄"));
}

#[tokio::test]
async fn login_parse_rejects_incomplete_login() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("qidian feed supports auth");

    let page = AuthPageContext {
        current_url: "https://passport.yuewen.com/yuewen.html".to_owned(),
        response: HttpBody::from("<html>login form</html>"),
        response_headers: vec![],
        cookies: vec![cookie("fu", "1", ".qidian.com")],
    };

    let err = feed
        .parse_auth(&support, &page)
        .expect_err("parse should reject a page without login cookies");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::AuthRequired,
                ..
            })
        ),
        "expected auth_required, got: {err:?}"
    );
}

#[tokio::test]
async fn login_parse_captures_cookie_header() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("qidian feed supports auth");

    let page = AuthPageContext {
        current_url: "https://m.qidian.com/".to_owned(),
        response: HttpBody::from("<html>home</html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("ywkey", "secret-key", ".qidian.com"),
            cookie("ywguid", "12345", ".qidian.com"),
            cookie("_csrfToken", "token", ".qidian.com"),
            // Tracking cookies must be excluded.
            cookie("Hm_lvt_123", "1", ".qidian.com"),
            cookie("HMACCOUNT", "abc", ".qidian.com"),
            cookie("newstatisticUUID", "x", ".qidian.com"),
            cookie("w_tsfp", "fingerprint", "www.qidian.com"),
            // Cookies from other domains must be excluded.
            cookie("sso_token", "other", ".yuewen.com"),
        ],
    };

    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");

    let header = auth
        .get("cookie_header")
        .and_then(|v| v.as_str())
        .expect("cookie_header should be a string");
    assert!(header.contains("ywkey=secret-key"), "header: {header}");
    assert!(header.contains("ywguid=12345"), "header: {header}");
    assert!(header.contains("_csrfToken=token"), "header: {header}");
    for excluded in [
        "Hm_lvt",
        "HMACCOUNT",
        "newstatisticUUID",
        "w_tsfp",
        "sso_token",
    ] {
        assert!(
            !header.contains(excluded),
            "tracking/foreign cookie leaked into header: {header}"
        );
    }
}

#[tokio::test]
async fn auth_status_reflects_user_login_state() {
    let mut server = mockito::Server::new_async().await;

    // Logged-in probe page.
    let _mock_in = server
        .mock("GET", "/soushu/langhuanprobe.html")
        .with_status(200)
        .with_body(ssr_page(&status_page_json(true)))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("qidian feed supports auth");

    // Without auth info the feed reports logged out without any request.
    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        langhuan::feed::AuthStatus::LoggedOut
    );

    // Install auth info parsed from a fake WebView session.
    let page = AuthPageContext {
        current_url: "https://m.qidian.com/".to_owned(),
        response: HttpBody::from("<html>home</html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("ywkey", "secret-key", ".qidian.com"),
            cookie("ywguid", "12345", ".qidian.com"),
        ],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    feed.set_auth_info(&support, Some(auth))
        .expect("set_auth_info failed");

    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        langhuan::feed::AuthStatus::LoggedIn
    );
}

#[tokio::test]
async fn auth_status_expired_when_site_reports_logged_out() {
    let mut server = mockito::Server::new_async().await;

    let _mock_out = server
        .mock("GET", "/soushu/langhuanprobe.html")
        .with_status(200)
        .with_body(ssr_page(&status_page_json(false)))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("qidian feed supports auth");

    let page = AuthPageContext {
        current_url: "https://m.qidian.com/".to_owned(),
        response: HttpBody::from("<html>home</html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("ywkey", "stale-key", ".qidian.com"),
            cookie("ywguid", "12345", ".qidian.com"),
        ],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    feed.set_auth_info(&support, Some(auth))
        .expect("set_auth_info failed");

    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        langhuan::feed::AuthStatus::Expired
    );
}

#[tokio::test]
async fn auth_cookie_is_sent_with_content_requests() {
    let mut server = mockito::Server::new_async().await;

    // The chapter request must carry the captured cookies — mockito only
    // matches when the Cookie header contains ywkey.
    let _mock = server
        .mock("GET", "/chapter/1010868264/402733549/")
        .match_header(
            "Cookie",
            mockito::Matcher::Regex(r"ywkey=secret-key".to_owned()),
        )
        .with_status(200)
        .with_body(ssr_page(&chapter_page_json(
            0,
            0,
            true,
            free_chapter_content(),
        )))
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("qidian feed supports auth");

    let page = AuthPageContext {
        current_url: "https://m.qidian.com/".to_owned(),
        response: HttpBody::from("<html>home</html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("ywkey", "secret-key", ".qidian.com"),
            cookie("ywguid", "12345", ".qidian.com"),
        ],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    feed.set_auth_info(&support, Some(auth))
        .expect("set_auth_info failed");

    let results: Vec<_> = feed
        .paragraphs("1010868264", "402733549")
        .collect::<Vec<_>>()
        .await;
    assert!(
        results.iter().all(|r| r.is_ok()),
        "request with cookie header should succeed: {results:?}"
    );
    assert!(!results.is_empty());
}

// ── Live-site smoke test ────────────────────────────────────────────────────

/// Real-site smoke test against https://m.qidian.com.
///
/// This test is ignored by default because it depends on external network,
/// target-site availability, and anti-bot behavior.
#[tokio::test]
#[ignore = "hits real website"]
async fn search_live_site_smoke() {
    let script = include_str!("../../../docs/book-sources/qidian.lua");
    let engine = ScriptEngine::new();
    let feed = engine.load_feed(script).await.expect("load_feed failed");

    // Bound runtime to avoid hanging on network issues.
    let collect_future = feed.search("诡秘之主").take(10).collect::<Vec<_>>();
    let results = tokio::time::timeout(Duration::from_secs(30), collect_future)
        .await
        .expect("live search timed out after 30s");

    assert!(
        !results.is_empty(),
        "live search returned no items (possible site/layout change)"
    );
    for item in &results {
        assert!(item.is_ok(), "live search error: {item:?}");
    }
    let items: Vec<_> = results.into_iter().filter_map(|r| r.ok()).collect();
    for item in &items {
        assert!(!item.id.trim().is_empty());
        assert!(!item.title.trim().is_empty());
        assert!(!item.author.trim().is_empty());
    }
    assert!(
        items.iter().any(|i| i.id == "1010868264"),
        "expected 诡秘之主 (1010868264) in search results: {:?}",
        items.iter().map(|i| &i.id).collect::<Vec<_>>()
    );

    // Book info.
    let info = feed
        .book_info("1010868264")
        .await
        .expect("live book_info failed");
    assert_eq!(info.title, "诡秘之主");
    assert_eq!(info.author, "爱潜水的乌贼");
    assert!(
        info.cover_url
            .as_deref()
            .is_some_and(|u| u.starts_with("https://bookcover.yuewen.com/")),
        "live book_info cover: {:?}",
        info.cover_url
    );

    // Chapters — 诡秘之主 has 1400+ chapters.
    let chapters_future = feed.chapters("1010868264").take(50).collect::<Vec<_>>();
    let chapters = tokio::time::timeout(Duration::from_secs(60), chapters_future)
        .await
        .expect("live chapters timed out after 60s");
    assert!(!chapters.is_empty());
    for c in &chapters {
        assert!(c.is_ok(), "live chapters error: {c:?}");
    }
    let chapters: Vec<_> = chapters.into_iter().filter_map(|c| c.ok()).collect();
    assert_eq!(
        chapters[0].title, "第一章 绯红",
        "chapters[0]: {:?}",
        chapters[0]
    );

    // Free chapter content.
    let first = chapters.first().unwrap();
    let paragraphs_future = feed
        .paragraphs("1010868264", &first.id)
        .take(100)
        .collect::<Vec<_>>();
    let paragraphs = tokio::time::timeout(Duration::from_secs(30), paragraphs_future)
        .await
        .expect("live paragraphs timed out after 30s");
    assert!(!paragraphs.is_empty());
    for p in &paragraphs {
        assert!(p.is_ok(), "live paragraphs error: {p:?}");
    }
    let paragraphs: Vec<_> = paragraphs.into_iter().filter_map(|p| p.ok()).collect();
    assert!(
        paragraphs
            .iter()
            .any(|p| matches!(p, langhuan::model::Paragraph::Title { .. }))
    );
    assert!(
        paragraphs
            .iter()
            .any(|p| matches!(p, langhuan::model::Paragraph::Text { .. }))
    );

    // VIP chapter while logged out must raise auth_required. Chapter
    // 414074529 (第一百三十章) is past this book's free section.
    let vip_future = feed
        .paragraphs("1010868264", "414074529")
        .take(10)
        .collect::<Vec<_>>();
    let vip_results = tokio::time::timeout(Duration::from_secs(30), vip_future)
        .await
        .expect("live VIP paragraphs timed out");
    let err = vip_results
        .iter()
        .find_map(|r| r.as_ref().err())
        .expect("logged-out VIP chapter should raise an error");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::AuthRequired,
                ..
            })
        ),
        "expected auth_required for logged-out VIP chapter, got: {err:?}"
    );
}
