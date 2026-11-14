/// Integration tests for the jjwxc feed script.
///
/// Mocked tests use mockito to serve a local HTTP server and rewrite the
/// script's `@base_url` / `@access_domain` header plus the two hard-coded
/// hosts (the anti-crawler font CDN and the login-status probe) so every
/// network request hits the mock; a request that accidentally escapes to the
/// real site fails loudly with an access-domain error instead.
///
/// Fixtures under `fixtures/` are trimmed from real www.jjwxc.net pages and
/// kept in their native gb18030 encoding, like the live site. The synthetic
/// crypto fixtures exercise the legacy decrypt chains with fixed vectors
/// (URL-encoded plaintext, odd-chapter key variant, m-site DES, seam
/// splicing).
use langhuan::error::{Error, ExpectedErrorCode, ScriptError};
use langhuan::feed::comments::CommentsQuery;
use langhuan::feed::{AuthPageContext, AuthStatus, CookieEntry, Feed, FeedAuthFlow};
use langhuan::http::HttpBody;
use langhuan::model::Paragraph;
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use std::time::Duration;
use tokio_stream::StreamExt;

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Login WebView cookie jars store the base64 token URL-encoded
/// (`…%3D`); readerIdFromAuth must decode it before the base64 round-trip.
/// The value decodes to `49887490|hash+with/special=chars`, i.e. reader
/// 49887490 — the reader id the VIP fixture ciphertexts were made for.
const TOKEN_COOKIE: &str = "NDk4ODc0OTB8aGFzaCt3aXRoL3NwZWNpYWw9Y2hhcnM%3D";

/// `2026-05-18 23:46:34` Beijing time, in Unix milliseconds.
const COMMENT_DATE: &str = "2026-05-18 23:46:34";
const COMMENT_DATE_MS: i64 = 1_779_119_194_000;

const VIP_FIRST: &str = "众人见场中出了状况, 纷纷起身观望。季歌、灵甜、静慧三人也震惊不小。";
const VIP_SECOND: &str =
    "静慧小声道：“早就听闻吴长风品行卑劣，是个目中无人的小人。今日一见，原来如此心狠手辣。”";
const VIP_LAST: &str = "季歌道：“那是。雷声大，雨点小呗。”";

/// Shared plaintext of the odd-chapter and DES-chain fixtures.
const CHAIN_FIRST: &str = "沈玄宁讪讪一笑，道：“我是路过的。”";
const CHAIN_SECOND: &str = "他转身走了，留下一句话：好自为之。";

const EMOJI_URL: &str =
    "https://i9-static.jjwxc.net/tmp/emoji/20250513142108_6822e4d4908c7_855.png";

// ── Fixtures (gb18030 bytes, trimmed from live pages) ───────────────────────

const SEARCH_PAGE: &[u8] = include_bytes!("fixtures/jjwxc_search_page.html");
const BOOK_PAGE: &[u8] = include_bytes!("fixtures/jjwxc_book_page.html");
const FREE_CHAPTER: &[u8] = include_bytes!("fixtures/jjwxc_free_chapter.html");
const VIP_PURCHASED: &[u8] = include_bytes!("fixtures/jjwxc_vip_purchased.html");
const VIP_NO_READERID: &[u8] = include_bytes!("fixtures/jjwxc_vip_no_readerid.html");
const VIP_UNPAID: &[u8] = include_bytes!("fixtures/jjwxc_vip_unpaid.html");
const LOGIN_PAGE: &[u8] = include_bytes!("fixtures/jjwxc_login.html");
const VIP_OLD_CHAIN: &[u8] = include_bytes!("fixtures/jjwxc_vip_old_chain.html");
const VIP_ODD_CHAIN: &[u8] = include_bytes!("fixtures/jjwxc_vip_odd_chain.html");
const VIP_DES_CHAIN: &[u8] = include_bytes!("fixtures/jjwxc_vip_des_chain.html");
const VIP_SEAM: &[u8] = include_bytes!("fixtures/jjwxc_vip_seam.html");
const VIP_BAD_ACCESS: &[u8] = include_bytes!("fixtures/jjwxc_vip_bad_access.html");
const FONT_TTF: &[u8] = include_bytes!("fixtures/jjwxcfont_9erly.ttf");

// ── Script loading ──────────────────────────────────────────────────────────

fn load_script_for_server(server: &ServerGuard) -> String {
    let base = server.url(); // e.g. "http://127.0.0.1:PORT"

    include_str!("../../../docs/book-sources/jjwxc.js")
        .replace(
            "// @base_url     https://www.jjwxc.net",
            &format!("// @base_url     {base}"),
        )
        // Route the primary access domain at the mock host and drop the
        // other three: every rewritten request must stay inside the mock.
        .replace(
            "// @access_domain www.jjwxc.net",
            "// @access_domain 127.0.0.1",
        )
        .replace("// @access_domain my.jjwxc.net\n", "")
        .replace("// @access_domain i9-static.jjwxc.net\n", "")
        .replace("// @access_domain static.jjwxc.net\n", "")
        // Anti-crawler font CDN and the login-status probe host. The login
        // entry URL stays real: it is opened in a WebView, never requested.
        .replace(
            "https://static.jjwxc.net/tmp/fonts/",
            &format!("{base}/tmp/fonts/"),
        )
        .replace(
            "https://my.jjwxc.net/backend/user_setting.php",
            &format!("{base}/backend/user_setting.php"),
        )
        .replace(
            "https://my.jjwxc.net/onebook_vip.php",
            &format!("{base}/onebook_vip.php"),
        )
}

async fn load_feed(server: &ServerGuard) -> langhuan::script::js::JsFeed {
    let script = load_script_for_server(server);
    let engine = ScriptEngine::new();
    engine.load_js_feed(&script).expect("load_feed failed")
}

/// A feed with a logged-in session whose token cookie decodes to reader
/// 49887490 (see `TOKEN_COOKIE`).
async fn authed_feed(server: &ServerGuard) -> langhuan::script::js::JsFeed {
    let feed = load_feed(server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");
    let page = AuthPageContext {
        current_url: "https://my.jjwxc.net/".to_owned(),
        response: HttpBody::from("<html></html>"),
        response_headers: vec![],
        cookies: vec![cookie("token", TOKEN_COOKIE, ".jjwxc.net")],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    feed.set_auth_info(&support, Some(auth))
        .expect("set_auth_info failed");
    feed
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

fn regex(pattern: &str) -> mockito::Matcher {
    mockito::Matcher::Regex(pattern.to_owned())
}

// ── Paragraph helpers ───────────────────────────────────────────────────────

async fn ok_paragraphs(
    feed: &langhuan::script::js::JsFeed,
    book_id: &str,
    chapter_id: &str,
) -> Vec<Paragraph> {
    let results: Vec<_> = feed
        .paragraphs(book_id, chapter_id)
        .collect::<Vec<_>>()
        .await;
    assert!(
        results.iter().all(|r| r.is_ok()),
        "paragraphs should parse: {results:?}"
    );
    results.into_iter().filter_map(Result::ok).collect()
}

fn titles_of(paragraphs: &[Paragraph]) -> Vec<&str> {
    paragraphs
        .iter()
        .filter_map(|p| match p {
            Paragraph::Title { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

fn text_of(paragraphs: &[Paragraph]) -> Vec<&str> {
    paragraphs
        .iter()
        .filter_map(|p| match p {
            Paragraph::Text { content, .. } => Some(content.as_str()),
            _ => None,
        })
        .collect()
}

fn image_urls(paragraphs: &[Paragraph]) -> Vec<&str> {
    paragraphs
        .iter()
        .filter_map(|p| match p {
            Paragraph::Image { url, .. } => Some(url.as_str()),
            _ => None,
        })
        .collect()
}

fn by_source_id<'a>(paragraphs: &'a [Paragraph], id: &str) -> &'a Paragraph {
    paragraphs
        .iter()
        .find(|p| p.id().source_id() == Some(id))
        .unwrap_or_else(|| panic!("paragraph with source id {id} missing"))
}

fn contains_pua(text: &str) -> bool {
    text.chars().any(|c| ('\u{E000}'..='\u{F8FF}').contains(&c))
}

/// Serve a getNovelParagraphCommentNum response for the given novel/chapter.
async fn mock_counts(
    server: &mut ServerGuard,
    novel: &str,
    chapter: &str,
    body: &str,
) -> mockito::Mock {
    server
        .mock("GET", "/app.jjwxc/Pc/comment/getNovelParagraphCommentNum")
        .match_query(regex(&format!("^novelid={novel}&chapterid={chapter}$")))
        .with_status(200)
        .with_body(body)
        .expect(1)
        .create_async()
        .await
}

fn counts_body(entries: &[(&str, u32)]) -> String {
    serde_json::json!({
        "data": entries
            .iter()
            .map(|(id, count)| serde_json::json!({
                "paragraph_id": id,
                "comment_total": count,
            }))
            .collect::<Vec<_>>(),
    })
    .to_string()
}

// ── Comment fixtures ────────────────────────────────────────────────────────

fn comments_query(paragraph_id: Option<&str>) -> CommentsQuery {
    CommentsQuery {
        book_id: "10620154".to_owned(),
        chapter_id: "17".to_owned(),
        paragraph_id: paragraph_id.map(str::to_owned),
        parent_id: None,
    }
}

/// One getCommentList entry. The live API reports `commentId` as a string,
/// `isAuthor` as "1"/"0" and Beijing-time `commentDateOrigin`.
fn comment_entry(
    id: u32,
    author: &str,
    is_author: bool,
    body: &str,
    date: &str,
) -> serde_json::Value {
    serde_json::json!({
        "commentId": id.to_string(),
        "commentAuthor": author,
        "commentBody": body,
        "commentDateOrigin": date,
        "agreenum": id,
        "isAuthor": if is_author { "1" } else { "0" },
        "userCover": format!("//i9.jjwxc.net/user/{id}.jpg"),
        "replyTotal": 3,
    })
}

fn comment_list_body(total: u32, entries: Vec<serde_json::Value>) -> String {
    serde_json::json!({ "data": { "commentTotal": total, "commentList": entries } }).to_string()
}

fn reply_list_body(entries: Vec<serde_json::Value>) -> String {
    serde_json::json!({ "data": entries }).to_string()
}

// ── Search ───────────────────────────────────────────────────────────────────

/// Second search page: pure ASCII so it can live inline. No pager means the
/// stream must stop after this page.
fn search_page_two() -> Vec<u8> {
    // The 作者： label is inert page furniture (only the hrefs are parsed),
    // so its UTF-8 bytes are fine even though the script decodes as GBK.
    "<html><head><meta charset=\"gb18030\"/></head><body>
<div id=\"search_result\">
<div>
<h3 class=\"title\"><a href=\"http://www.jjwxc.net/onebook.php?novelid=7777777\">Page Two Book</a></h3>
<div class=\"intro\">page two intro</div>
<div class=\"info\">作者：<a href=\"http://www.jjwxc.net/oneauthor.php?authorid=99\"><span>author99</span></a></div>
</div>
</div>
</body></html>"
        .to_owned()
        .into_bytes()
}

#[tokio::test]
async fn search_encodes_keyword_in_gbk_and_follows_pager() {
    let mut server = mockito::Server::new_async().await;

    // 诡秘 GBK-encoded is %B9%EE%C3%D8 — UTF-8 bytes would be a wrong keyword.
    let first = server
        .mock("GET", "/search.php")
        .match_query(regex("^kw=%B9%EE%C3%D8&t=1$"))
        .with_status(200)
        .with_body(SEARCH_PAGE)
        .expect(1)
        .create_async()
        .await;
    let second = server
        .mock("GET", "/search.php")
        .match_query(regex("^kw=%B9%EE%C3%D8&t=1&p=2$"))
        .with_status(200)
        .with_body(search_page_two())
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.search("诡秘").collect::<Vec<_>>().await;
    assert!(
        results.iter().all(|r| r.is_ok()),
        "search should parse: {results:?}"
    );
    let items: Vec<_> = results.into_iter().filter_map(Result::ok).collect();

    assert_eq!(items.len(), 3);
    assert_eq!(items[0].id, "4281809");
    assert_eq!(items[0].title, "诡秘");
    assert_eq!(items[0].author, "拾素");
    assert_eq!(
        items[0].cover_url.as_deref(),
        Some("https://i9-static.jjwxc.net/novelimage.php?novelid=4281809")
    );
    assert!(items[0].description.as_deref().unwrap().contains("缘更"));
    assert_eq!(items[1].id, "6605435");
    assert_eq!(items[1].title, "诡秘");
    assert_eq!(items[1].author, "水兴");
    assert_eq!(items[2].id, "7777777");
    assert_eq!(items[2].title, "Page Two Book");
    assert_eq!(items[2].author, "author99");

    first.assert_async().await;
    second.assert_async().await;
}

#[tokio::test]
async fn search_returns_empty_when_no_match() {
    let mut server = mockito::Server::new_async().await;
    let _mock = server
        .mock("GET", "/search.php")
        .match_query(regex("^kw=%B9%EE%C3%D8&t=1$"))
        .with_status(200)
        .with_body(
            "<html><body><div id=\"search_result\"><div class=\"page\">\
             没有找到相关作品</div></div></body></html>",
        )
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.search("诡秘").collect::<Vec<_>>().await;
    assert!(
        results.iter().all(|r| r.is_ok()),
        "empty search should not error: {results:?}"
    );
    assert_eq!(results.len(), 0);
}

// ── Book info & chapters ───────────────────────────────────────────────────

#[tokio::test]
async fn book_info_parses_metadata_and_cover() {
    let mut server = mockito::Server::new_async().await;
    let page = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154$"))
        .with_status(200)
        .with_body(BOOK_PAGE)
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let info = feed.book_info("10620154").await.expect("book_info failed");
    assert_eq!(info.id, "10620154");
    assert_eq!(info.title, "樊笼外");
    assert_eq!(info.author, "青城妹子");
    // Custom cover: the img src (the author's own image), not the _src
    // default-cover fallback the onerror handler would load.
    assert_eq!(
        info.cover_url.as_deref(),
        Some("https://wx2.sinaimg.cn/mw690/d3eba5e7ly1iirp5azkxej20c20f9q4k.jpg")
    );
    assert!(
        info.description
            .as_deref()
            .unwrap()
            .contains("少年群像武侠")
    );

    page.assert_async().await;
}

#[tokio::test]
async fn chapters_list_free_and_vip_rows_in_order() {
    let mut server = mockito::Server::new_async().await;
    let _page = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154$"))
        .with_status(200)
        .with_body(BOOK_PAGE)
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.chapters("10620154").collect::<Vec<_>>().await;
    assert!(
        results.iter().all(|r| r.is_ok()),
        "chapters should parse: {results:?}"
    );
    let items: Vec<_> = results.into_iter().filter_map(Result::ok).collect();

    // Free chapters carry href=onebook.php, VIP chapters only a rel=
    // onebook_vip.php anchor; both stay in the table of contents.
    let ids: Vec<&str> = items.iter().map(|c| c.id.as_str()).collect();
    let titles: Vec<&str> = items.iter().map(|c| c.title.as_str()).collect();
    assert_eq!(ids, ["1", "2", "17", "18"]);
    assert_eq!(
        titles,
        ["茶庄初遇", "诱人入笼", "群雄盛会（5）", "群雄盛会（6）"]
    );
}

// ── Paragraphs: free chapter ────────────────────────────────────────────────

#[tokio::test]
async fn paragraphs_free_chapter_includes_note_and_counts() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=1$"))
        .with_status(200)
        .with_body(FREE_CHAPTER)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(
        &mut server,
        "10620154",
        "1",
        &counts_body(&[("1", 7), ("-2", 2)]),
    )
    .await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "1").await;

    // chapter title + 85 body texts + note title + 2 emoji images + 2 note texts
    assert_eq!(paragraphs.len(), 91);
    assert_eq!(titles_of(&paragraphs), ["茶庄初遇", "作者有话"]);
    // The chapter title has no site id; the note unit is paragraph -2.
    assert_eq!(paragraphs[0].id().source_id(), None);
    let note_title = by_source_id(&paragraphs, "-2");
    assert_eq!(note_title.comment_count(), Some(2));

    let texts = text_of(&paragraphs);
    assert_eq!(texts.len(), 87);
    assert_eq!(texts[0], "湘楚，芦淞镇。");
    assert_eq!(texts[84], "静慧瞧见，低头一乐。");
    assert!(texts[85].starts_with("一直想写一本金庸式的传统武侠"));
    assert_eq!(texts[86], "下一本仙侠预收：《上仙，您下错凡了》");

    // Emoji images inside the note become image paragraphs.
    assert_eq!(image_urls(&paragraphs), [EMOJI_URL, EMOJI_URL]);

    // Badges from getNovelParagraphCommentNum: reported paragraphs get their
    // count, every other numbered paragraph is reported as zero, and the
    // unnumbered chapter title stays unknown.
    assert_eq!(by_source_id(&paragraphs, "1").comment_count(), Some(7));
    assert_eq!(by_source_id(&paragraphs, "2").comment_count(), Some(0));
    assert_eq!(by_source_id(&paragraphs, "85").comment_count(), Some(0));
    assert_eq!(paragraphs[0].comment_count(), None);
}

#[tokio::test]
async fn paragraphs_counts_api_failure_leaves_comment_counts_unknown() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=1$"))
        .with_status(200)
        .with_body(FREE_CHAPTER)
        .expect(1)
        .create_async()
        .await;
    let _counts = server
        .mock("GET", "/app.jjwxc/Pc/comment/getNovelParagraphCommentNum")
        .match_query(regex("^novelid=10620154&chapterid=1$"))
        .with_status(500)
        .with_body("boom")
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "1").await;
    // The badge call is a decoration only: its failure must not fail the
    // chapter or fabricate zero counts.
    assert_eq!(text_of(&paragraphs).len(), 87);
    assert!(paragraphs.iter().all(|p| p.comment_count().is_none()));
}

// ── Paragraphs: VIP chapter ─────────────────────────────────────────────────

#[tokio::test]
async fn vip_cross_origin_redirect_retries_with_auth_once() {
    for (vip_body, expected_error) in [
        (VIP_PURCHASED, None),
        (LOGIN_PAGE, Some(ExpectedErrorCode::AuthRequired)),
        (VIP_UNPAID, Some(ExpectedErrorCode::ContentNotFound)),
    ] {
        let mut www = mockito::Server::new_async().await;
        let mut account = mockito::Server::new_async().await;
        let vip_url = format!("{}/onebook_vip.php", account.url());
        let entry = www
            .mock("GET", "/onebook.php")
            .match_query(regex("^novelid=10620154&chapterid=17$"))
            .match_header("cookie", regex(&format!("token={TOKEN_COOKIE}")))
            .with_status(302)
            .with_header(
                "location",
                &format!("{vip_url}?novelid=10620154&chapterid=17"),
            )
            .expect(1)
            .create_async()
            .await;
        // Distinct origins reproduce credential stripping on www → my.
        let stripped = account
            .mock("GET", "/onebook_vip.php")
            .match_query(mockito::Matcher::Any)
            .match_header("cookie", mockito::Matcher::Missing)
            .with_status(302)
            .with_header("location", &format!("{}/login.php", account.url()))
            .expect(1)
            .create_async()
            .await;
        let login = account
            .mock("GET", "/login.php")
            .with_status(200)
            .with_body(LOGIN_PAGE)
            .expect(1)
            .create_async()
            .await;
        let authenticated = account
            .mock("GET", "/onebook_vip.php")
            .match_query(regex("^novelid=10620154&chapterid=17$"))
            .match_header("cookie", regex(&format!("token={TOKEN_COOKIE}")))
            .with_status(200)
            .with_body(vip_body)
            .expect(1)
            .create_async()
            .await;
        let font = www
            .mock("GET", "/tmp/fonts/jjwxcfont_9erly.ttf")
            .with_status(200)
            .with_body(FONT_TTF)
            .expect(usize::from(expected_error.is_none()))
            .create_async()
            .await;
        let _counts = mock_counts(&mut www, "10620154", "17", &counts_body(&[])).await;
        let script = load_script_for_server(&www)
            .replace(&format!("{}/onebook_vip.php", www.url()), &vip_url);
        let feed = ScriptEngine::new().load_js_feed(&script).unwrap();
        let support = feed.supports_auth().unwrap();
        feed.set_auth_info(
            &support,
            Some(serde_json::json!({
                "cookie_header": format!("token={TOKEN_COOKIE}")
            })),
        )
        .unwrap();
        let results: Vec<_> = feed.paragraphs("10620154", "17").collect().await;
        if let Some(expected) = expected_error {
            assert!(
                results.iter().any(|result| matches!(result,
                    Err(Error::Script(ScriptError::Expected { code, .. })) if *code == expected
                )),
                "expected {expected:?}, got {results:?}"
            );
        } else {
            let paragraphs: Vec<_> = results.into_iter().collect::<Result<_, _>>().unwrap();
            assert_eq!(text_of(&paragraphs)[0], VIP_FIRST);
        }
        entry.assert_async().await;
        stripped.assert_async().await;
        login.assert_async().await;
        authenticated.assert_async().await;
        font.assert_async().await;
    }
}

#[tokio::test]
async fn paragraphs_vip_purchased_decrypts_and_restores_font() {
    let mut server = mockito::Server::new_async().await;
    let chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=17$"))
        .with_status(200)
        .with_body(VIP_PURCHASED)
        .expect(1)
        .create_async()
        .await;
    // The anti-crawler font is fetched from the CDN and parsed to restore
    // the PUA glyph substitution.
    let font = server
        .mock("GET", "/tmp/fonts/jjwxcfont_9erly.ttf")
        .with_status(200)
        .with_body(FONT_TTF)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "10620154", "17", &counts_body(&[("1", 3)])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "17").await;

    assert_eq!(paragraphs.len(), 65); // chapter title + 64 body texts
    assert_eq!(titles_of(&paragraphs), ["群雄盛会（5）"]);
    let texts = text_of(&paragraphs);
    assert_eq!(texts.len(), 64);
    assert_eq!(texts[0], VIP_FIRST);
    assert_eq!(texts[1], VIP_SECOND);
    assert_eq!(texts[63], VIP_LAST);
    assert!(
        !texts.iter().any(|t| contains_pua(t)),
        "font mapping should restore every PUA glyph"
    );

    assert_eq!(by_source_id(&paragraphs, "1").comment_count(), Some(3));
    assert_eq!(by_source_id(&paragraphs, "64").comment_count(), Some(0));
    assert_eq!(paragraphs[0].comment_count(), None);

    chapter.assert_async().await;
    font.assert_async().await;
}

#[tokio::test]
async fn paragraphs_vip_font_fetch_failure_keeps_pua_text() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=17$"))
        .with_status(200)
        .with_body(VIP_PURCHASED)
        .expect(1)
        .create_async()
        .await;
    // Font CDN down: the chapter must still complete, with raw PUA
    // codepoints left in place instead of restored characters.
    let font = server
        .mock("GET", "/tmp/fonts/jjwxcfont_9erly.ttf")
        .with_status(404)
        .with_body("gone")
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "10620154", "17", &counts_body(&[])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "17").await;
    let texts = text_of(&paragraphs);
    assert_eq!(texts.len(), 64);
    assert!(
        texts.iter().any(|t| contains_pua(t)),
        "unmapped PUA glyphs should stay in the text"
    );

    font.assert_async().await;
}

#[tokio::test]
async fn paragraphs_vip_readerid_from_token_cookie() {
    let mut server = mockito::Server::new_async().await;
    // The page's readerid field is blank; the id must come from the login
    // token cookie (base64 "readerid|…", URL-encoded in the WebView jar).
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=17$"))
        .with_status(200)
        .with_body(VIP_NO_READERID)
        .expect(1)
        .create_async()
        .await;
    let _font = server
        .mock("GET", "/tmp/fonts/jjwxcfont_9erly.ttf")
        .with_status(200)
        .with_body(FONT_TTF)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "10620154", "17", &counts_body(&[])).await;

    let feed = authed_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "17").await;
    let texts = text_of(&paragraphs);
    assert_eq!(texts.len(), 64);
    assert_eq!(texts[0], VIP_FIRST);
    assert!(!texts.iter().any(|t| contains_pua(t)));
}

#[tokio::test]
async fn paragraphs_vip_legacy_window_chain_url_decodes_and_keeps_pua() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=9942287&chapterid=23$"))
        .with_status(200)
        .with_body(VIP_OLD_CHAIN)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "9942287", "23", &counts_body(&[])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "9942287", "23").await;

    // The plaintext is percent-encoded and carries a PUA glyph; without a
    // font class on the page the codepoint must survive verbatim.
    assert_eq!(titles_of(&paragraphs), ["舊鏈章節"]);
    let texts = text_of(&paragraphs);
    assert_eq!(texts, ["甲&乙", "丙\u{E044}丁"]);
    assert!(contains_pua(texts[1]));
}

#[tokio::test]
async fn paragraphs_vip_odd_chapter_key_variant_decrypts() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=100&chapterid=1$"))
        .with_status(200)
        .with_body(VIP_ODD_CHAIN)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "100", "1", &counts_body(&[])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "100", "1").await;

    // (novelid + chapterid) odd selects the access-novel-chapter-reader
    // md5 variant for cryptInfo.
    assert_eq!(titles_of(&paragraphs), ["奇數章"]);
    assert_eq!(text_of(&paragraphs), [CHAIN_FIRST, CHAIN_SECOND]);
}

#[tokio::test]
async fn paragraphs_vip_des_chain_decrypts() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=8718162&chapterid=19$"))
        .with_status(200)
        .with_body(VIP_DES_CHAIN)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "8718162", "19", &counts_body(&[])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "8718162", "19").await;

    // The m-site chain encrypts cryptInfo with DES-CBC and carries the
    // meta as raw JSON rather than base64.
    assert_eq!(titles_of(&paragraphs), ["DES 鏈章節"]);
    assert_eq!(text_of(&paragraphs), [CHAIN_FIRST, CHAIN_SECOND]);
}

#[tokio::test]
async fn paragraphs_vip_seam_splice_restores_text() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=200&chapterid=4$"))
        .with_status(200)
        .with_body(VIP_SEAM)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "200", "4", &counts_body(&[])).await;

    let feed = load_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "200", "4").await;

    // Characters pulled out of the body hang on .c_xx:before/:after content
    // rules (including a \7f1d hex escape); the .c_zz decoy selector must
    // not splice anything.
    assert_eq!(titles_of(&paragraphs), ["縫拼接章節"]);
    assert_eq!(text_of(&paragraphs), ["甲缝1乙丙缝2丁"]);
}

#[tokio::test]
async fn paragraphs_vip_wrong_access_key_raises_source_unavailable() {
    let mut server = mockito::Server::new_async().await;
    let _chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=9942287&chapterid=23$"))
        .with_status(200)
        .with_body(VIP_BAD_ACCESS)
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.paragraphs("9942287", "23").collect::<Vec<_>>().await;
    let err = results
        .iter()
        .find_map(|r| r.as_ref().err())
        .expect("expected a source_unavailable error");
    assert!(
        matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::SourceUnavailable,
                ..
            })
        ),
        "expected source_unavailable, got: {err:?}"
    );
}

#[tokio::test]
async fn paragraphs_vip_unpaid_raises_content_not_found() {
    let mut server = mockito::Server::new_async().await;
    let base = server.url();
    // www/onebook.php redirects to the purchase page. That page carries pay
    // password inputs too, so the unpaid markers must win over the login
    // probe (ordering guard).
    let _redirect = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=18$"))
        .with_status(302)
        .with_header(
            "Location",
            &format!("{base}/backend/buynovel.php?t=1&novelid=10620154&chapterid=18"),
        )
        .expect(1)
        .create_async()
        .await;
    let target = server
        .mock("GET", "/backend/buynovel.php")
        // The redirect Location carries a query string; without an explicit
        // query matcher mockito compares path+query against the bare path.
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(VIP_UNPAID)
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.paragraphs("10620154", "18").collect::<Vec<_>>().await;
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

    target.assert_async().await;
}

#[tokio::test]
async fn paragraphs_vip_anonymous_raises_auth_required() {
    let mut server = mockito::Server::new_async().await;
    let base = server.url();
    // Anonymous www requests for VIP chapters land on login.php after the
    // host follows the redirect chain.
    let _redirect = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=17$"))
        .with_status(302)
        .with_header(
            "Location",
            &format!("{base}/login.php?referer=%2F%2Fmy.jjwxc.net%2F"),
        )
        .expect(1)
        .create_async()
        .await;
    let target = server
        .mock("GET", "/login.php")
        // The redirect Location carries a query string; without an explicit
        // query matcher mockito compares path+query against the bare path.
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(LOGIN_PAGE)
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let results: Vec<_> = feed.paragraphs("10620154", "17").collect::<Vec<_>>().await;
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
        "expected auth_required for anonymous VIP chapter, got: {err:?}"
    );

    target.assert_async().await;
}

// ── Login flow ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn login_entry_uses_desktop_my_jjwxc() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");

    let entry = feed.auth_entry(&support).expect("auth_entry failed");
    assert_eq!(
        entry.url,
        "https://my.jjwxc.net/login.php?referer=%2F%2Fmy.jjwxc.net%2F"
    );
    assert_eq!(entry.title.as_deref(), Some("晉江文學城登入"));
    // Desktop UA: the login form on my.jjwxc.net is a desktop page.
    assert_eq!(
        entry.user_agent,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
         (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    );
}

#[tokio::test]
async fn login_parse_captures_jjwxc_session_cookies() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");

    let page = AuthPageContext {
        current_url: "https://my.jjwxc.net/".to_owned(),
        response: HttpBody::from("<html></html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("Hm_lvt_tracker", "1730000000", ".jjwxc.net"),
            cookie("token", TOKEN_COOKIE, ".jjwxc.net"),
            cookie("foreign_session", "nope", ".example.com"),
            cookie("bbstoken", "bbs-session-key", ".jjwxc.net"),
        ],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    // Baidu analytics and foreign-domain cookies are filtered out; the
    // session cookies survive in order.
    let header = auth
        .get("cookie_header")
        .and_then(serde_json::Value::as_str)
        .expect("cookie_header in auth info");
    assert_eq!(
        header,
        format!("token={TOKEN_COOKIE}; bbstoken=bbs-session-key")
    );
    assert_eq!(
        auth.get("captured_url").and_then(serde_json::Value::as_str),
        Some("https://my.jjwxc.net/")
    );
}

#[tokio::test]
async fn login_parse_rejects_cookies_without_session_marker() {
    let server = mockito::Server::new_async().await;
    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");

    // No token/readerid among the captured cookies: incomplete login.
    let page = AuthPageContext {
        current_url: "https://my.jjwxc.net/login.php".to_owned(),
        response: HttpBody::from("<html>login form</html>"),
        response_headers: vec![],
        cookies: vec![
            cookie("Hm_lvt_tracker", "1730000000", ".jjwxc.net"),
            cookie("reader_nickname", "书友", "my.jjwxc.net"),
        ],
    };
    let err = feed
        .parse_auth(&support, &page)
        .expect_err("parse_auth must fail without token/readerid");
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
async fn auth_status_logged_in_when_user_setting_page_reachable() {
    let mut server = mockito::Server::new_async().await;
    let settings = server
        .mock("GET", "/backend/user_setting.php")
        .with_status(200)
        .with_body("user settings")
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");

    // Without auth info the host short-circuits to logged out: the probe
    // mock must stay untouched until a session is installed.
    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        AuthStatus::LoggedOut
    );

    let page = AuthPageContext {
        current_url: "https://my.jjwxc.net/".to_owned(),
        response: HttpBody::from("<html></html>"),
        response_headers: vec![],
        cookies: vec![cookie("token", TOKEN_COOKIE, ".jjwxc.net")],
    };
    let auth = feed.parse_auth(&support, &page).expect("parse_auth failed");
    feed.set_auth_info(&support, Some(auth))
        .expect("set_auth_info failed");

    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        AuthStatus::LoggedIn
    );
    settings.assert_async().await;
}

#[tokio::test]
async fn auth_status_expired_when_probe_lands_on_login_page() {
    let mut server = mockito::Server::new_async().await;
    let base = server.url();
    // A stale session gets bounced from user_setting.php to login.php; the
    // final URL after the redirect marks the session as expired.
    let _redirect = server
        .mock("GET", "/backend/user_setting.php")
        .with_status(302)
        .with_header("Location", &format!("{base}/login.php?referer=setting"))
        .expect(1)
        .create_async()
        .await;
    let _login = server
        .mock("GET", "/login.php")
        // The redirect Location carries a query string; without an explicit
        // query matcher mockito compares path+query against the bare path.
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(LOGIN_PAGE)
        .expect(1)
        .create_async()
        .await;

    let feed = authed_feed(&server).await;
    let support = feed.supports_auth().expect("jjwxc feed supports auth");
    assert_eq!(
        feed.auth_status(&support).await.unwrap(),
        AuthStatus::Expired
    );
}

#[tokio::test]
async fn auth_cookie_is_sent_with_content_requests() {
    let mut server = mockito::Server::new_async().await;
    // The chapter request must carry the captured cookies — the mock only
    // matches when the Cookie header contains the session token.
    let chapter = server
        .mock("GET", "/onebook.php")
        .match_query(regex("^novelid=10620154&chapterid=1$"))
        .match_header("Cookie", regex(&format!("token={TOKEN_COOKIE}")))
        .with_status(200)
        .with_body(FREE_CHAPTER)
        .expect(1)
        .create_async()
        .await;
    let _counts = mock_counts(&mut server, "10620154", "1", &counts_body(&[])).await;

    let feed = authed_feed(&server).await;
    let paragraphs = ok_paragraphs(&feed, "10620154", "1").await;
    assert!(!paragraphs.is_empty());

    chapter.assert_async().await;
}

// ── Comments ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn chapter_comments_advance_offset_by_raw_entry_count() {
    let mut server = mockito::Server::new_async().await;

    // Page one carries 20 raw entries; one has an empty body and is
    // dropped, but the cursor must still advance by 20 because the API
    // counts deleted/empty entries against the offset.
    let mut entries: Vec<_> = (1..=20_u32)
        .map(|i| comment_entry(i, "路人乙", false, &format!("第 {i} 樓"), COMMENT_DATE))
        .collect();
    entries[0] = comment_entry(1, "青城妹子", true, "第 1 樓", COMMENT_DATE);
    entries[1] = comment_entry(2, "路人乙", false, "第 2 樓", "not-a-date");
    entries[6] = comment_entry(7, "路人乙", false, "", COMMENT_DATE);

    let first = server
        .mock("GET", "/app.jjwxc/Pc/comment/getCommentList")
        .match_query(regex(
            "^novelId=10620154&chapterId=17&paragraph_id=0&offset=0&limit=20$",
        ))
        .with_status(200)
        .with_body(comment_list_body(21, entries))
        .expect(1)
        .create_async()
        .await;
    let second = server
        .mock("GET", "/app.jjwxc/Pc/comment/getCommentList")
        .match_query(regex(
            "^novelId=10620154&chapterId=17&paragraph_id=0&offset=20&limit=20$",
        ))
        .with_status(200)
        .with_body(comment_list_body(
            21,
            vec![comment_entry(21, "路人丙", false, "最後一樓", COMMENT_DATE)],
        ))
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    assert_eq!(feed.comment_support(), (true, true));

    let page = feed
        .comments_page(&comments_query(None), serde_json::Value::Null)
        .await
        .expect("first chapter comments page");
    assert_eq!(page.items.len(), 19);

    let first_item = &page.items[0];
    assert_eq!(first_item.id, "1");
    assert_eq!(first_item.author.name, "[作者] 青城妹子");
    assert_eq!(
        first_item.author.avatar_url.as_deref(),
        Some("https://i9.jjwxc.net/user/1.jpg")
    );
    assert_eq!(first_item.text, "第 1 樓");
    assert_eq!(first_item.created_at_ms, Some(COMMENT_DATE_MS));
    assert_eq!(first_item.like_count, Some(1));
    let replies = first_item
        .replies
        .as_ref()
        .expect("replyTotal must surface as a replies block");
    assert_eq!(replies.total_count, Some(3));
    // Unparseable dates stay unknown rather than being dropped.
    assert_eq!(page.items[1].id, "2");
    assert_eq!(page.items[1].created_at_ms, None);

    let next = page.next_cursor.expect("a full page must chain");
    assert_eq!(next, serde_json::json!(20));
    let last = feed
        .comments_page(&comments_query(None), next)
        .await
        .expect("second chapter comments page");
    assert_eq!(last.items.len(), 1);
    assert_eq!(last.items[0].id, "21");
    assert!(
        last.next_cursor.is_none(),
        "a short final page must end paging"
    );

    first.assert_async().await;
    second.assert_async().await;
}

#[tokio::test]
async fn comment_replies_use_app_formatter_fields() {
    let mut server = mockito::Server::new_async().await;
    let replies = server
        .mock("GET", "/app.jjwxc/Pc/comment/getReplyList")
        .match_query(regex(
            "^novelid=10620154&chapterid=17&commentid=7&offset=0&limit=20&formatter=app$",
        ))
        .with_status(200)
        .with_body(reply_list_body(vec![
            serde_json::json!({
                "replyId": "71",
                "replyAuthor": "路人甲",
                "replyBody": "回覆甲",
                "comment_date_time": "1779119194",
                "agreenum": 2,
                "isAuthor": "0",
                "userCover": "",
            }),
            serde_json::json!({
                "replyId": "72",
                "replyAuthor": "青城妹子",
                "replyBody": "作者回覆",
                "comment_date_time": "1779119200",
                "agreenum": 5,
                "isAuthor": "1",
                "userCover": "",
            }),
        ]))
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let mut query = comments_query(None);
    query.parent_id = Some("7".to_owned());
    let page = feed
        .comments_page(&query, serde_json::Value::Null)
        .await
        .expect("replies page");

    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].id, "71");
    assert_eq!(page.items[0].author.name, "路人甲");
    assert_eq!(page.items[0].author.avatar_url, None);
    assert_eq!(page.items[0].text, "回覆甲");
    // Reply times are Unix seconds, not Beijing-time strings.
    assert_eq!(page.items[0].created_at_ms, Some(1_779_119_194_000));
    assert_eq!(page.items[0].like_count, Some(2));
    assert!(
        page.items[0].replies.is_none(),
        "replies of replies are not exposed"
    );
    assert_eq!(page.items[1].author.name, "[作者] 青城妹子");
    assert_eq!(page.items[1].created_at_ms, Some(1_779_119_200_000));
    assert!(page.next_cursor.is_none(), "a short reply page must end");

    replies.assert_async().await;
}

#[tokio::test]
async fn paragraph_comments_target_paragraph_id() {
    let mut server = mockito::Server::new_async().await;
    let comments = server
        .mock("GET", "/app.jjwxc/Pc/comment/getCommentList")
        .match_query(regex(
            "^novelId=10620154&chapterId=17&paragraph_id=1&offset=0&limit=20$",
        ))
        .with_status(200)
        .with_body(comment_list_body(
            1,
            vec![comment_entry(31, "段評人", false, "段評內容", COMMENT_DATE)],
        ))
        .expect(1)
        .create_async()
        .await;

    let feed = load_feed(&server).await;
    let page = feed
        .comments_page(&comments_query(Some("1")), serde_json::Value::Null)
        .await
        .expect("paragraph comments page");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "31");
    assert_eq!(page.items[0].text, "段評內容");
    assert!(page.next_cursor.is_none());

    comments.assert_async().await;
}

// ── Live smoke test ──────────────────────────────────────────────────────────

/// Real-site smoke test against https://www.jjwxc.net.
///
/// This test is ignored by default because it depends on external network,
/// target-site availability, and anti-bot behavior.
#[tokio::test]
#[ignore = "hits real website"]
async fn search_live_site_smoke() {
    let script = include_str!("../../../docs/book-sources/jjwxc.js");
    let engine = ScriptEngine::new();
    let feed = engine.load_js_feed(script).expect("load_feed failed");

    // Bound runtime to avoid hanging on network issues.
    let collect_future = feed.search("诡秘").take(10).collect::<Vec<_>>();
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
}
