/// Integration tests for the fanqie feed script.
///
/// Mocked tests use mockito to serve a local HTTP server and replace the
/// `@base_url` / `@access_domain` header in the script so that all network
/// requests hit the mock instead of the real site. Fixtures mirror the
/// server-rendered HTML of fanqienovel.com, including the private-use-area
/// codepoints that the site's custom font obfuscation substitutes for the
/// most frequent characters (see the FONT_MAP comment in the script).
use langhuan::error::{Error, ExpectedErrorCode, ScriptError};
use langhuan::feed::{AuthPageContext, Feed, FeedAuthFlow};
use langhuan::http::HttpBody;
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use std::sync::{Arc, Mutex};
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

    // Replace the base URL and declare only the local mock server. An empty
    // allowlist intentionally denies every network request.
    script
        .replace(
            "// @base_url     https://fanqienovel.com",
            &format!("// @base_url     {base}"),
        )
        .replace(
            "// @access_domain fanqienovel.com",
            "// @access_domain 127.0.0.1",
        )
        .replace("// @access_domain *.byteimg.com", "")
        .replace("// @access_domain *.fqnovelpic.com", "")
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

/// The live site returns only a short preview to logged-out users and appends
/// this membership gate after the reader content. It must never be mistaken
/// for a complete chapter.
fn preview_reader_page_html() -> String {
    reader_page_html(FONT_HASH).replace(
        "<div class=\"muye-reader-btns\">",
        r#"<div class="muye-to-vip-login">
          <div>下载「番茄小说APP」可免费阅读全文</div>
          <div class="muye-to-vip-login-btn">会员登录后，可在网页畅读全文</div>
        </div>
        <div class="muye-reader-btns">"#,
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

/// A search API response mirroring the live JSON: `search_book_data_list`
/// entries with plain-text fields, plus `total_count` for pagination.
fn search_page_json(total: u32, books: &[(&str, &str, &str)]) -> String {
    let items: Vec<String> = books
        .iter()
        .map(|(id, name, author)| {
            format!(
                r#"{{"book_id":"{id}","book_name":"{name}","author":"{author}","book_abstract":"这是{name}的简介。","category":"科幻末世","word_count":123456,"thumb_url":"https://p3-reading-sign.fqnovelpic.com/novel-pic/{id}.image"}}"#
            )
        })
        .collect();
    format!(
        r#"{{"code":0,"message":"success","data":{{"search_author_data_list":[],"search_book_data_list":[{}],"total_count":{total}}}}}"#,
        items.join(",")
    )
}

#[tokio::test]
async fn search_queries_by_keyword() {
    let mut server = mockito::Server::new_async().await;

    // The search API only escapes the risk gate when the parameters travel
    // as a POST query string (see the script header).
    let _mock = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(mockito::Matcher::AllOf(vec![
            mockito::Matcher::UrlEncoded("filter".into(), "127,127,127,127".into()),
            mockito::Matcher::UrlEncoded("page_count".into(), "10".into()),
            mockito::Matcher::UrlEncoded("page_index".into(), "0".into()),
            mockito::Matcher::UrlEncoded("query_type".into(), "0".into()),
            mockito::Matcher::UrlEncoded("query_word".into(), "深空".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(search_page_json(
            10,
            &[
                ("7649785550819314712", "深空底噪", "张大样"),
                ("7668191234912963608", "深空诡域", "沉静的大喵"),
            ],
        ))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;

    // total_count == page size → a single page, exactly the mocked items.
    let items: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("search stream yielded an error");
    assert_eq!(items.len(), 2, "expected the 2 mocked books");

    assert_eq!(items[0].id, "7649785550819314712");
    assert_eq!(items[0].title, "深空底噪");
    assert_eq!(items[0].author, "张大样");
    assert_eq!(
        items[0].cover_url.as_deref(),
        Some("https://p3-reading-sign.fqnovelpic.com/novel-pic/7649785550819314712.image")
    );
    assert!(
        items[1]
            .description
            .as_deref()
            .is_some_and(|d| d.contains("深空诡域")),
        "description should come from book_abstract: {:?}",
        items[1].description
    );
}

#[tokio::test]
async fn search_follows_pagination_cursor() {
    let mut server = mockito::Server::new_async().await;

    let query = |page_index: &'static str| {
        mockito::Matcher::AllOf(vec![
            mockito::Matcher::UrlEncoded("page_count".into(), "10".into()),
            mockito::Matcher::UrlEncoded("page_index".into(), page_index.into()),
            mockito::Matcher::UrlEncoded("query_word".into(), "深空".into()),
        ])
    };

    // Page 0: 2 books, total 15 → cursor 1. Page 1 repeats the page-0 tail
    // before one new book, matching the overlap observed after returning to
    // a suspended search route. The host must keep the stream usable.
    let _page0 = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(query("0"))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(search_page_json(
            15,
            &[
                ("1000000000000000001", "深空一号", "作者一"),
                ("1000000000000000002", "深空二号", "作者二"),
            ],
        ))
        .create_async()
        .await;
    let _page1 = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(query("1"))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(search_page_json(
            15,
            &[
                ("1000000000000000002", "深空二号", "作者二"),
                ("1000000000000000003", "深空三号", "作者三"),
            ],
        ))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;

    let items: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("search stream yielded an error");
    let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(
        ids,
        vec![
            "1000000000000000001",
            "1000000000000000002",
            "1000000000000000003"
        ],
        "expected both pages in order"
    );
}

// ── Search risk gate → WebView verification ─────────────────────────────────

/// A canned webview handler: records every request and answers with the
/// configured cookies, or with an auth-required error when `cookies` is
/// `None` (simulating the user canceling the page).
struct TestWebview {
    requests: Mutex<Vec<langhuan::feed::WebviewRequest>>,
    cookies: Option<Vec<langhuan::feed::CookieEntry>>,
}

impl TestWebview {
    fn new(cookies: Option<Vec<langhuan::feed::CookieEntry>>) -> Arc<Self> {
        Arc::new(Self {
            requests: Mutex::new(Vec::new()),
            cookies,
        })
    }
}

impl langhuan::feed::WebviewHandler for TestWebview {
    fn open(&self, request: langhuan::feed::WebviewRequest) -> langhuan::feed::WebviewFuture {
        self.requests.lock().unwrap().push(request);
        let cookies = self.cookies.clone();
        Box::pin(async move {
            match cookies {
                Some(cookies) => Ok(langhuan::feed::WebviewSnapshot {
                    current_url: "https://fanqienovel.com/library".into(),
                    html: "<html>ok</html>".into(),
                    cookies,
                }),
                None => Err(Error::expected(
                    ExpectedErrorCode::AuthRequired,
                    "驗證已取消",
                )),
            }
        })
    }
}

fn cookie(name: &str, value: &str, domain: &str) -> langhuan::feed::CookieEntry {
    langhuan::feed::CookieEntry {
        name: name.into(),
        value: value.into(),
        domain: Some(domain.into()),
        path: Some("/".into()),
        expires: None,
        secure: Some(true),
        http_only: Some(false),
        same_site: None,
    }
}

fn verified_cookies() -> Vec<langhuan::feed::CookieEntry> {
    vec![
        cookie("msToken", "device-token", ".fanqienovel.com"),
        cookie("ttwid", "tt-value", ".fanqienovel.com"),
        // 百度統計與異域 cookie 必須被剔除。
        cookie("Hm_lvt_9706", "stat", ".fanqienovel.com"),
        cookie("foreign", "no", ".example.org"),
    ]
}

fn gate_query() -> mockito::Matcher {
    mockito::Matcher::AllOf(vec![
        mockito::Matcher::UrlEncoded("page_count".into(), "10".into()),
        mockito::Matcher::UrlEncoded("page_index".into(), "0".into()),
        mockito::Matcher::UrlEncoded("query_word".into(), "深空".into()),
    ])
}

const VERIFIED_COOKIE_HEADER: &str = "msToken=device-token; ttwid=tt-value";

#[tokio::test]
async fn search_verifies_in_webview_and_retries_with_cookies() {
    let mut server = mockito::Server::new_async().await;

    // The initial POST carries no Cookie header and is answered with an
    // empty body — the risk gate's signature response.
    let _gate = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", mockito::Matcher::Missing)
        .with_status(200)
        .with_body("")
        .create_async()
        .await;
    // The post-verification retry must arrive with exactly the harvested
    // fanqienovel.com cookies to reach the business payload.
    let _ok = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", VERIFIED_COOKIE_HEADER)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(search_page_json(
            10,
            &[("7649785550819314712", "深空底噪", "张大样")],
        ))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let webview = TestWebview::new(Some(verified_cookies()));
    feed.set_webview_handler(Some(webview.clone()))
        .expect("install webview handler");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    let items: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("search stream yielded an error");
    assert_eq!(items.len(), 1, "expected the verified retry to succeed");
    assert_eq!(items[0].id, "7649785550819314712");

    let requests = webview.requests.lock().unwrap();
    assert_eq!(requests.len(), 1, "exactly one verification round-trip");
    assert!(requests[0].url.ends_with("/library"), "unexpected url");
    assert_eq!(requests[0].title.as_deref(), Some("番茄小說驗證"));
    assert_eq!(
        requests[0].user_agent,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
         (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    );
    assert_eq!(requests[0].feed_id, "org.eu.ywxt.langhuan.fanqie");
    assert_eq!(requests[0].feed_name, "番茄小說");
}

#[tokio::test]
async fn search_reuses_verified_cookies_within_the_session() {
    let mut server = mockito::Server::new_async().await;

    // The initial unauthenticated POST is gated…
    let _gate = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", mockito::Matcher::Missing)
        .with_status(200)
        .with_body("")
        .create_async()
        .await;
    // …and every cookie-carrying POST reaches the payload. After a
    // successful verification the session cache means brand-new searches
    // arrive already authenticated — no second verification prompt.
    let _ok = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", VERIFIED_COOKIE_HEADER)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(search_page_json(
            10,
            &[("7649785550819314712", "深空底噪", "张大样")],
        ))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let webview = TestWebview::new(Some(verified_cookies()));
    feed.set_webview_handler(Some(webview.clone()))
        .expect("install webview handler");

    let first: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    assert_eq!(
        first
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .expect("first search should verify and succeed")
            .len(),
        1
    );

    let second: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    let items: Vec<_> = second
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("second search should reuse the verified cookies");
    assert_eq!(items.len(), 1);
    assert_eq!(
        webview.requests.lock().unwrap().len(),
        1,
        "no second verification prompt within the session"
    );
}

#[tokio::test]
async fn search_fails_auth_required_when_webview_canceled() {
    let mut server = mockito::Server::new_async().await;

    let _gate = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .with_status(200)
        .with_body("")
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    feed.set_webview_handler(Some(TestWebview::new(None)))
        .expect("install webview handler");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    assert_eq!(results.len(), 1);
    let error = results[0].as_ref().expect_err("must fail");
    assert_expected_code(error, ExpectedErrorCode::AuthRequired);
}

#[tokio::test]
async fn search_fails_auth_required_when_snapshot_has_no_usable_cookies() {
    let mut server = mockito::Server::new_async().await;

    let _gate = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .with_status(200)
        .with_body("")
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    // Only statistics and foreign-domain cookies were harvested.
    feed.set_webview_handler(Some(TestWebview::new(Some(vec![
        cookie("Hm_lvt_9706", "stat", ".fanqienovel.com"),
        cookie("foreign", "no", ".example.org"),
    ]))))
    .expect("install webview handler");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    assert_eq!(results.len(), 1);
    let error = results[0].as_ref().expect_err("must fail");
    assert_expected_code(error, ExpectedErrorCode::AuthRequired);
}

#[tokio::test]
async fn search_reports_failure_when_verification_does_not_help() {
    let mut server = mockito::Server::new_async().await;

    let _gate = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", mockito::Matcher::Missing)
        .with_status(200)
        .with_body("")
        .create_async()
        .await;
    // Even with the verified cookies the gate answers empty.
    let _still_gated = server
        .mock("POST", "/api/author/search/search_book/v1")
        .match_query(gate_query())
        .match_header("Cookie", VERIFIED_COOKIE_HEADER)
        .with_status(200)
        .with_body("")
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let webview = TestWebview::new(Some(verified_cookies()));
    feed.set_webview_handler(Some(webview.clone()))
        .expect("install webview handler");

    let results: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    assert_eq!(results.len(), 1);
    let error = results[0].as_ref().expect_err("must fail");
    assert_eq!(
        error.to_string(),
        "expected script error [Unknown(\"search_failed\")]: 完成驗證後仍被番茄風控攔截，請稍後再試"
    );

    // While the session stays risk-blocked, further searches fail fast
    // without popping another verification page.
    let more: Vec<_> = feed.search("深空").collect::<Vec<_>>().await;
    assert_eq!(more.len(), 1);
    let error = more[0].as_ref().expect_err("must fail");
    assert!(error.to_string().contains("search_failed"));
    assert_eq!(
        webview.requests.lock().unwrap().len(),
        1,
        "no additional verification prompt while blocked"
    );
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
    assert!(
        info.cover_url
            .as_deref()
            .is_some_and(|u| u.starts_with("https://"))
    );
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
            !content
                .chars()
                .any(|c| ('\u{e000}'..='\u{f8ff}').contains(&c)),
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

#[tokio::test]
async fn paragraphs_preview_requires_login_instead_of_returning_partial_text() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .with_status(200)
        .with_body(preview_reader_page_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");

    let results = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;
    assert_eq!(results.len(), 1);
    let error = results.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(&error, ExpectedErrorCode::AuthRequired);
}

// ── Login flow ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn login_entry_and_parser_capture_fanqie_cookies() {
    let server = mockito::Server::new_async().await;
    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let support = feed.supports_auth().expect("fanqie supports login");

    let entry = feed.auth_entry(&support).expect("auth entry");
    assert_eq!(entry.url, format!("{}/", server.url()));
    assert_eq!(entry.title.as_deref(), Some("番茄小說登錄"));

    let auth = feed
        .parse_auth(
            &support,
            &AuthPageContext {
                current_url: server.url(),
                response: HttpBody::default(),
                response_headers: vec![],
                cookies: vec![
                    cookie("sessionid", "account-session", ".fanqienovel.com"),
                    cookie("ttwid", "device-id", ".fanqienovel.com"),
                    cookie("Hm_lvt_9706", "tracking", ".fanqienovel.com"),
                    cookie("foreign", "ignored", ".example.org"),
                ],
            },
        )
        .expect("parse auth");
    let header = auth["cookie_header"].as_str().expect("cookie header");
    assert!(header.contains("sessionid=account-session"));
    assert!(header.contains("ttwid=device-id"));
    assert!(!header.contains("Hm_lvt"));
    assert!(!header.contains("foreign"));
}

#[tokio::test]
async fn authenticated_reader_request_uses_cookie_and_returns_full_chapter() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .match_header(
            "Cookie",
            mockito::Matcher::Regex(r"sessionid=account-session".to_owned()),
        )
        .with_status(200)
        .with_body(reader_page_html(FONT_HASH))
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let support = feed.supports_auth().expect("fanqie supports login");
    feed.set_auth_info(
        &support,
        Some(serde_json::json!({ "cookie_header": "sessionid=account-session" })),
    )
    .expect("set auth");

    let results = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;
    assert!(results.iter().all(Result::is_ok), "{results:?}");
    assert_eq!(results.len(), 3);
}

#[tokio::test]
async fn authenticated_preview_reports_missing_svip_access() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", format!("/reader/{CHAPTER_1_ID}").as_str())
        .with_status(200)
        .with_body(preview_reader_page_html())
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let support = feed.supports_auth().expect("fanqie supports login");
    feed.set_auth_info(
        &support,
        Some(serde_json::json!({ "cookie_header": "sessionid=account-session" })),
    )
    .expect("set auth");

    let results = feed
        .paragraphs(BOOK_ID, CHAPTER_1_ID)
        .collect::<Vec<_>>()
        .await;
    assert_eq!(results.len(), 1);
    let error = results.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(&error, ExpectedErrorCode::ContentNotFound);
}

#[tokio::test]
async fn auth_status_uses_reader_user_endpoint() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/api/reader/user/info")
        .match_header(
            "Cookie",
            mockito::Matcher::Regex(r"sessionid=account-session".to_owned()),
        )
        .with_status(200)
        .with_body(r#"{"code":0,"message":"success","data":{"user_id":"123"}}"#)
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(&script)
        .await
        .expect("load_script failed");
    let support = feed.supports_auth().expect("fanqie supports login");
    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        langhuan::feed::AuthStatus::LoggedOut
    );
    feed.set_auth_info(
        &support,
        Some(serde_json::json!({ "cookie_header": "sessionid=account-session" })),
    )
    .expect("set auth");
    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        langhuan::feed::AuthStatus::LoggedIn
    );
}

// ── Live site ───────────────────────────────────────────────────────────────

/// Real-site smoke test against https://fanqienovel.com.
///
/// Ignored by default because it depends on external network, target-site
/// availability and current site behavior.
#[tokio::test]
#[ignore = "hits real website"]
async fn live_site_smoke() {
    let script = include_str!("../../../docs/book-sources/fanqie.js");
    let engine = ScriptEngine::new();
    let feed = engine
        .load_script(script)
        .await
        .expect("load_script failed");

    // 1. Real keyword search against the live API.
    let search_future = feed.search("深空").take(10).collect::<Vec<_>>();
    let results = tokio::time::timeout(Duration::from_secs(30), search_future)
        .await
        .expect("live search timed out after 30s");

    let keyword_items: Vec<_> = results
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("live keyword search yielded an error");
    assert!(
        !keyword_items.is_empty(),
        "keyword search returned no items"
    );
    for item in &keyword_items {
        assert!(!item.title.trim().is_empty(), "empty title: {item:?}");
        assert!(!item.author.trim().is_empty(), "empty author: {item:?}");
        assert!(
            !item
                .title
                .chars()
                .any(|c| ('\u{e000}'..='\u{f8ff}').contains(&c)),
            "search title contains private-use codepoints: {:?}",
            item.title
        );
    }
    assert!(
        keyword_items[0]
            .cover_url
            .as_deref()
            .is_some_and(|url| url.starts_with("http")),
        "expected a cover URL on the first result: {:?}",
        keyword_items[0].cover_url
    );

    // 2. Pasting a book URL still resolves directly to that book.
    // 皇后重生要谋反 — a completed book with a large SSR directory.
    let direct_future = feed
        .search("https://fanqienovel.com/page/6823667291557727235")
        .take(5)
        .collect::<Vec<_>>();
    let direct = tokio::time::timeout(Duration::from_secs(30), direct_future)
        .await
        .expect("live direct search timed out after 30s");

    assert_eq!(direct.len(), 1, "expected exactly one direct search result");
    let book = direct
        .into_iter()
        .next()
        .unwrap()
        .expect("live direct search yielded an error");
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
    // A late chapter currently returns only a short preview to logged-out
    // visitors. The source must surface an authentication requirement rather
    // than silently presenting that preview as the complete chapter.
    let late_chapter = chapters.get(499).expect("expected at least 500 chapters");

    let paragraphs_future = feed
        .paragraphs(&book.id, &late_chapter.id)
        .take(200)
        .collect::<Vec<_>>();
    let paragraphs = tokio::time::timeout(Duration::from_secs(30), paragraphs_future)
        .await
        .expect("live paragraphs timed out after 30s");

    assert_eq!(paragraphs.len(), 1, "expected one auth error");
    let error = paragraphs.into_iter().next().unwrap().unwrap_err();
    assert_expected_code(&error, ExpectedErrorCode::AuthRequired);
}
