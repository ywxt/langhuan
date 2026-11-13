use crate::error::Result;
use crate::feed::SharedStorageHandler;
use crate::http::FeedClient;
use crate::script::feed::ScriptFeed;
use crate::script::js::JsFeed;
use crate::script::meta;

/// Loads JavaScript feeds into the native QuickJS sandbox runtime.
///
/// Every feed owns its HTTP client — built from the feed's own
/// `access_domains` so its redirect hops are gated — so the engine itself
/// holds no client state.
#[derive(Clone)]
pub struct ScriptEngine {
    storage: Option<SharedStorageHandler>,
}

impl ScriptEngine {
    pub fn new() -> Self {
        Self { storage: None }
    }

    /// Install a per-feed storage backend for the feeds this engine loads;
    /// feeds may then `import { storage } from "langhuan:storage"`.
    pub fn with_storage(mut self, storage: SharedStorageHandler) -> Self {
        self.storage = Some(storage);
        self
    }

    pub async fn load_script(&self, script: &str) -> Result<ScriptFeed> {
        self.load_js_feed(script)
    }

    pub fn load_js_feed(&self, script: &str) -> Result<JsFeed> {
        let outcome = self.parse_and_load(script);
        if let Err(error) = &outcome {
            tracing::warn!(error = %error, "failed to load feed script");
        }
        outcome
    }

    fn parse_and_load(&self, script: &str) -> Result<JsFeed> {
        let (feed_meta, body_offset) = meta::parse_meta(script)?;
        if feed_meta.schema_version > crate::feed::meta::FEED_SCHEMA_VERSION {
            return Err(crate::error::Error::feed_schema_too_new(
                feed_meta.id.clone(),
                feed_meta.schema_version,
                crate::feed::meta::FEED_SCHEMA_VERSION,
            ));
        }
        if feed_meta.schema_version != crate::feed::meta::FEED_SCHEMA_VERSION {
            return Err(crate::error::Error::invalid_feed(format!(
                "JavaScript feeds require schema_version {}; schema {} must migrate: \
                 requests carry a full URL instead of `params` (encode query strings \
                 with HTML.encodeURIComponents), and the HTML module follows the \
                 jQuery and DOM interface (find, parent(), children())",
                crate::feed::meta::FEED_SCHEMA_VERSION,
                feed_meta.schema_version,
            )));
        }
        // The feed's own client: redirect hops are gated by this feed's
        // access_domains for every request it makes.
        let client = FeedClient::new(&feed_meta.access_domains);
        JsFeed::new(
            script[body_offset..].to_owned(),
            feed_meta,
            client,
            self.storage.clone(),
        )
    }
}

impl Default for ScriptEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::Value;

    use crate::error::{Error, ExpectedErrorCode, ScriptError};
    use crate::feed::storage::MemoryStorage;
    use crate::feed::{
        CookieEntry, Feed, FeedAuthFlow, StorageHandler, WebviewFuture, WebviewHandler,
        WebviewRequest, WebviewSnapshot,
    };
    use tokio_stream::StreamExt as _;

    use super::*;

    fn source(schema: u32, body: &str) -> String {
        format!(
            r#"// ==Feed==
// @id test
// @name Test
// @version 3.0.0
// @base_url https://example.com
// @access_domain example.com
// @access_domain 127.0.0.1
// @schema_version {schema}
// ==/Feed==
{body}
"#,
        )
    }

    const RETURNED_FEED: &str = r#"
      const complete = () => ({ type: "complete", result: [] });
      const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Author" } });
      export default { search: complete, bookInfo, chapters: complete, paragraphs: complete };
    "#;

    #[tokio::test]
    async fn comments_are_optional_strict_and_explicitly_paged() {
        use crate::feed::comments::CommentsQuery;
        let script = r#"
          const empty = () => ({ type: "complete", result: [] });
          export default {
            search: empty, bookInfo: empty, chapters: empty, paragraphs: empty,
            comments: { paragraph: null, chapter(event) {
              const page = event.cursor?.page ?? 1;
              return JSON.parse(JSON.stringify({ type: "complete", result: [{ id: `${event.input.parentId ?? 'root'}-${page}`,
                  author: { name: "Reader" }, text: "Comment", replies: { total_count: null } }], next_cursor: page === 1 ? { page: 2 } : null }));
            } }
          };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, script))
            .await
            .unwrap();
        assert_eq!(feed.comment_support(), (true, false));
        let debug_page = feed
            .debug_operation_page(
                "comments.chapter",
                serde_json::json!({ "bookId": "b", "chapterId": "c" }),
                Value::Null,
            )
            .await
            .unwrap();
        assert_eq!(debug_page.result[0]["id"], "root-1");
        let mut query = CommentsQuery {
            book_id: "b".into(),
            chapter_id: "c".into(),
            paragraph_id: None,
            parent_id: None,
        };
        let first = feed.comments_page(&query, Value::Null).await.unwrap();
        assert_eq!(first.items.len(), 1);
        assert_eq!(first.items[0].id, "root-1");
        let second = feed
            .comments_page(&query, first.next_cursor.unwrap())
            .await
            .unwrap();
        assert!(second.next_cursor.is_none());
        assert_eq!(second.items[0].id, "root-2");
        query.parent_id = Some("root-1".into());
        assert_eq!(
            feed.comments_page(&query, Value::Null).await.unwrap().items[0].id,
            "root-1-1"
        );
        query.paragraph_id = Some("839".into());
        assert!(feed.comments_page(&query, Value::Null).await.is_err());
        let invalid = script.replace("paragraph: null", "paragraph: 42");
        assert!(
            ScriptEngine::new()
                .load_script(&source(6, &invalid))
                .await
                .is_err()
        );
        let no_progress = script.replace("{ page: 2 }", "{ page: 1 }");
        let feed = ScriptEngine::new()
            .load_script(&source(6, &no_progress))
            .await
            .unwrap();
        query.paragraph_id = None;
        assert!(
            feed.comments_page(&query, serde_json::json!({ "page": 1 }))
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn schema_six_accepts_exported_feed_object() {
        ScriptEngine::new()
            .load_script(&source(6, RETURNED_FEED))
            .await
            .expect("exported feed object should load");
    }

    #[tokio::test]
    async fn rejects_legacy_schema() {
        let error = ScriptEngine::new()
            .load_script(&source(2, RETURNED_FEED))
            .await
            .expect_err("schema 2 must not be accepted");
        assert!(matches!(
            error,
            Error::Script(ScriptError::InvalidFeed { .. })
        ));
    }

    #[tokio::test]
    async fn rejects_schema_five_with_a_migration_hint() {
        let error = ScriptEngine::new()
            .load_script(&source(5, RETURNED_FEED))
            .await
            .expect_err("schema 5 must not be accepted");
        let message = error.to_string();
        assert!(message.contains("schema_version 6"));
        assert!(message.contains("params"));
    }

    #[tokio::test]
    async fn rejects_newer_schema() {
        let error = ScriptEngine::new()
            .load_script(&source(7, RETURNED_FEED))
            .await
            .expect_err("schema 7 must not be accepted");
        assert!(matches!(
            error,
            Error::Script(ScriptError::SchemaTooNew { .. })
        ));
    }

    #[tokio::test]
    async fn rejects_global_feed_registration() {
        let body = r#"
          const handlers = {
            search: () => ({ type: "complete", result: [] }),
            bookInfo: () => ({ type: "complete", result: { id: "1" } }),
            chapters: () => ({ type: "complete", result: [] }),
            paragraphs: () => ({ type: "complete", result: [] }),
          };
          globalThis.feed = handlers;
        "#;
        let error = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .expect_err("globalThis.feed registration must be rejected");
        assert!(error.to_string().contains("export default"));
    }

    #[tokio::test]
    async fn rejects_global_feed_even_with_a_default_export() {
        let body = format!("globalThis.feed = {{}};\n{RETURNED_FEED}");
        let error = ScriptEngine::new()
            .load_script(&source(6, &body))
            .await
            .expect_err("legacy registration must not coexist with the default export");
        assert!(error.to_string().contains("globalThis.feed"));
    }

    #[tokio::test]
    async fn single_page_comments_validate_required_fields_and_shape() {
        for result in [
            r#"{ items: [], total_count: 0 }"#,
            r#"[{ author: { name: "Reader" }, text: "Text" }]"#,
            r#"[{ id: "c", text: "Text" }]"#,
            r#"[{ id: "c", author: {}, text: "Text" }]"#,
            r#"[{ id: "c", author: { name: "Reader" } }]"#,
            r#"[{ id: "", author: { name: "Reader" }, text: "Text" }]"#,
        ] {
            let body = format!(
                r#"const empty = () => ({{ type: "complete", result: [] }});
                const comments = () => ({{ type: "complete", result: {result} }});
                export default {{ search: empty, bookInfo: empty, chapters: empty,
                    paragraphs: empty, comments: {{ chapter: comments, paragraph: comments }} }};"#
            );
            let feed = ScriptEngine::new().load_js_feed(&source(6, &body)).unwrap();
            for operation in ["comments.chapter", "comments.paragraph"] {
                assert!(
                    feed.debug_operation_page(operation, serde_json::json!({}), Value::Null)
                        .await
                        .is_err(),
                    "{operation} must reject {result}"
                );
            }
        }
    }

    #[tokio::test]
    async fn rejects_partial_login_contract() {
        let body = RETURNED_FEED.replace(
            "export default { search: complete, bookInfo, chapters: complete, paragraphs: complete };",
            "export default { search: complete, bookInfo, chapters: complete, paragraphs: complete, login: { entry() {} } };",
        );
        let error = ScriptEngine::new()
            .load_script(&source(6, &body))
            .await
            .expect_err("partial login contract must be rejected");
        assert!(error.to_string().contains("login.entry, login.parse"));
    }

    #[tokio::test]
    async fn auth_entry_rejects_unsafe_user_agent() {
        let body = r#"
          const complete = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Author" } });
          const login = {
            entry: () => ({ url: "https://example.com/login", user_agent: "Bad\nAgent" }),
            parse: () => ({}),
            patchRequest: (_operation, request) => request,
          };
          export default { search: complete, bookInfo, chapters: complete, paragraphs: complete, login };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .expect("feed should compile");
        let support = feed.supports_auth().expect("login should be supported");
        let error = feed
            .auth_entry(&support)
            .expect_err("control characters must be rejected");
        assert!(error.to_string().contains("control characters"));
    }

    #[tokio::test]
    async fn reducer_and_request_patch_share_one_operation_descriptor() {
        let mut server = mockito::Server::new_async().await;
        let _request = server
            .mock("GET", "/book")
            .match_header("x-operation", "bookInfo:42")
            .with_status(200)
            .with_body("ok")
            .create_async()
            .await;
        let body = r#"
          import { TextDecoder } from "langhuan:encoding";
          const empty = () => ({ type: "complete", result: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "request",
                request: { url: "__BASE__/book", method: "GET" },
                next_state: true,
              };
            }
            return { type: "complete", result: { id: event.input.bookId, title: new TextDecoder().decode(event.response.body), author: "Test" } };
          }
          const login = {
            entry() { return { url: "__BASE__/login" }; },
            parse() { return {}; },
            patchRequest(operation, request) {
              request.headers ??= {};
              request.headers["X-Operation"] = [
                operation.operation,
                operation.input.bookId,
              ].join(":");
              return request;
            },
          };
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty, login };
        "#
            .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(6, &body))
            .await
            .unwrap();
        let support = feed.supports_auth().unwrap();
        feed.set_auth_info(&support, Some(serde_json::json!({})))
            .unwrap();

        let book = feed.book_info("42").await.unwrap();
        assert_eq!(book.id, "42");
        assert_eq!(book.title, "ok");
    }

    #[tokio::test]
    async fn state_passes_through_as_a_live_javascript_value() {
        let mut server = mockito::Server::new_async().await;
        let _request = server
            .mock("GET", "/book")
            .with_status(200)
            .with_body("ok")
            .create_async()
            .await;
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "request",
                request: { url: "__BASE__/book" },
                next_state: {
                  when: new Date(1234567890),
                  blob: new Uint8Array([200, 201]),
                  label: undefined,
                },
              };
            }
            const keptDate =
              event.state.when instanceof Date &&
              event.state.when.getTime() === 1234567890;
            const keptBlob =
              event.state.blob instanceof Uint8Array &&
              event.state.blob.length === 2 &&
              event.state.blob[1] === 201;
            const keptUndefinedKey = "label" in event.state;
            return { type: "complete", result: {
                id: "1",
                title: keptDate && keptBlob && keptUndefinedKey ? "ok" : "broken",
                author: "Test",
              } };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#
        .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(6, &body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "ok");
    }

    #[tokio::test]
    async fn request_body_can_carry_bytes() {
        let mut server = mockito::Server::new_async().await;
        let _request = server
            .mock("POST", "/submit")
            .match_body(mockito::Matcher::from(vec![65, 255, 0, 127]))
            .with_status(200)
            .with_body("stored")
            .create_async()
            .await;
        let body = r#"
          import { TextDecoder } from "langhuan:encoding";
          const empty = () => ({ type: "complete", result: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "request",
                request: {
                  url: "__BASE__/submit",
                  method: "POST",
                  body: new Uint8Array([65, 255, 0, 127]),
                },
                next_state: true,
              };
            }
            return { type: "complete", result: { id: "1", title: new TextDecoder().decode(event.response.body), author: "Test" } };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#
            .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(6, &body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "stored");
    }

    #[tokio::test]
    async fn completed_items_reject_bytes_with_guidance() {
        let body = r#"
          function search() {
            return { type: "complete", result: [{ id: "1", title: new Uint8Array([1]), author: "Test" }] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        let Some(error) = collected[0].as_ref().err() else {
            panic!("bytes must be rejected in completed items");
        };
        assert!(error.to_string().contains("Uint8Array"));
    }

    #[tokio::test]
    async fn search_keeps_first_book_when_pages_overlap() {
        let body = r#"
          function search(event) {
            if (event.cursor == null) {
              return { type: "complete", result: [
                  { id: "1", title: "One", author: "Test" },
                  { id: "2", title: "Two", author: "Test" },
                ], next_cursor: 1 };
            }
            return { type: "complete", result: [
                { id: "2", title: "Two repeated", author: "Test" },
                { id: "3", title: "Three", author: "Test" },
              ] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let books = feed
            .search("x")
            .collect::<Vec<_>>()
            .await
            .into_iter()
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("overlapping search pages must remain usable");
        assert_eq!(
            books.into_iter().map(|book| book.id).collect::<Vec<_>>(),
            ["1", "2", "3"]
        );
    }

    #[tokio::test]
    async fn pipeline_rejects_a_handler_that_never_advances_the_cursor() {
        let body = r#"
          function search() {
            return { type: "complete",
              result: [{ id: "1", title: "One", author: "Test" }],
              next_cursor: { page: 1 } };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        // The first page flows through; its frozen next cursor fails page two.
        assert_eq!(collected.len(), 2);
        assert!(collected[0].is_ok());
        let error = collected[1]
            .as_ref()
            .expect_err("a cursor that never advances must fail the stream");
        assert!(
            error
                .to_string()
                .contains("pipeline cursor does not advance")
        );
    }

    #[tokio::test]
    async fn pipeline_rejects_oversized_cursors() {
        // Each page returns a distinct cursor well past the size budget, so
        // only the size check — not the advance check — can stop the stream.
        let body = r#"
          function search(event) {
            const page = event.cursor?.page ?? 0;
            return { type: "complete", result: [],
              next_cursor: { page: page + 1, pad: "x".repeat(5000) } };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("an oversized cursor must be refused before any page is consumed");
        assert!(
            error
                .to_string()
                .contains("pipeline cursor does not advance")
        );
    }

    #[tokio::test]
    async fn pipeline_cuts_off_cursor_cycles_at_the_page_budget() {
        let body = r#"
          function search(event) {
            const page = event.cursor?.page ?? 0;
            return { type: "complete", result: [], next_cursor: { page: (page + 1) % 2 } };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("a cursor cycle must hit the page budget instead of looping");
        assert!(error.to_string().contains("pipeline page limit exceeded"));
    }

    #[tokio::test]
    async fn comments_page_rejects_a_frozen_cursor() {
        use crate::feed::comments::CommentsQuery;
        let script = r#"
          const empty = () => ({ type: "complete", result: [] });
          export default {
            search: empty, bookInfo: empty, chapters: empty, paragraphs: empty,
            comments: { paragraph: null, chapter() {
              return JSON.parse(JSON.stringify({ type: "complete",
                result: [{ id: "c1", author: { name: "Reader" }, text: "Comment" }],
                next_cursor: { page: 2 } }));
            } }
          };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, script))
            .await
            .unwrap();
        let query = CommentsQuery {
            book_id: "b".into(),
            chapter_id: "c".into(),
            paragraph_id: None,
            parent_id: None,
        };
        let error = feed
            .comments_page(&query, serde_json::json!({ "page": 2 }))
            .await
            .expect_err("a cursor equal to the page's input must be rejected");
        assert!(error.to_string().contains("does not advance"));
    }

    #[tokio::test]
    async fn comments_stream_follows_pages_until_the_cursor_runs_out() {
        use crate::feed::comments::CommentsQuery;
        let script = r#"
          const empty = () => ({ type: "complete", result: [] });
          export default {
            search: empty, bookInfo: empty, chapters: empty, paragraphs: empty,
            comments: { paragraph: null, chapter(event) {
              const page = event.cursor?.page ?? 1;
              return JSON.parse(JSON.stringify({ type: "complete",
                result: [{ id: `c${page}`, author: { name: "Reader" }, text: "Comment" }],
                next_cursor: page === 3 ? null : { page: page + 1 } }));
            } }
          };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, script))
            .await
            .unwrap();
        let query = CommentsQuery {
            book_id: "b".into(),
            chapter_id: "c".into(),
            paragraph_id: None,
            parent_id: None,
        };
        let collected = feed.comments_stream(query).collect::<Vec<_>>().await;
        let items = collected
            .into_iter()
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("a paged comment thread must stream to its end");
        assert_eq!(
            items.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
            ["c1", "c2", "c3"]
        );

        // The operation follows the query, not the stream entry: a
        // paragraph target hits the script's unsupported paragraph handler.
        let paragraph = CommentsQuery {
            book_id: "b".into(),
            chapter_id: "c".into(),
            paragraph_id: Some("839".into()),
            parent_id: None,
        };
        let collected = feed.comments_stream(paragraph).collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        assert!(collected[0].is_err());
    }

    #[tokio::test]
    async fn comments_stream_rejects_an_oversized_page_before_yielding_items() {
        use crate::feed::comments::CommentsQuery;
        let script = r#"
          const empty = () => ({ type: "complete", result: [] });
          export default {
            search: empty, bookInfo: empty, chapters: empty, paragraphs: empty,
            comments: { paragraph: null, chapter() {
              const items = Array.from({ length: 201 }, (_, i) => ({
                id: `c${i}`, author: { name: "Reader" }, text: "Comment",
              }));
              return { type: "complete", result: items };
            } }
          };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, script))
            .await
            .unwrap();
        let query = CommentsQuery {
            book_id: "b".into(),
            chapter_id: "c".into(),
            paragraph_id: None,
            parent_id: None,
        };
        let collected = feed.comments_stream(query).collect::<Vec<_>>().await;
        // The page is rejected whole: no partial prefix flows before the
        // error, mirroring the explicit page API.
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("a page over the item cap must fail the stream");
        assert!(
            error
                .to_string()
                .contains("comment page exceeds item or text limits")
        );
    }

    #[tokio::test]
    async fn search_page_rejects_more_than_two_hundred_items() {
        let body = r#"
          function search() {
            return { type: "complete", result: Array.from({ length: 201 }, (_, i) => ({
              id: String(i), title: "T", author: "A",
            })) };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("an oversized search page must fail the stream");
        assert!(
            error
                .to_string()
                .contains("search page exceeds item or field limits")
        );
    }

    #[tokio::test]
    async fn chapter_page_rejects_more_than_ten_thousand_entries() {
        let body = r#"
          function chapters() {
            return { type: "complete", result: Array.from({ length: 10001 }, (_, i) => ({
              id: String(i), title: "C",
            })) };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search: empty, bookInfo, chapters, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.chapters("b").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("an oversized directory page must fail the stream");
        assert!(
            error
                .to_string()
                .contains("chapter page exceeds item or field limits")
        );
    }

    #[tokio::test]
    async fn paragraph_page_rejects_oversized_content() {
        let body = r#"
          function paragraphs() {
            return { type: "complete", result: [
              { type: "text", content: "x".repeat(32769) },
            ] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search: empty, bookInfo, chapters: empty, paragraphs };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.paragraphs("b", "c").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        let error = collected[0]
            .as_ref()
            .expect_err("an oversized paragraph must fail the stream");
        assert!(
            error
                .to_string()
                .contains("paragraph page exceeds item or field limits")
        );
    }

    #[tokio::test]
    async fn paragraph_page_rejects_an_empty_image_url() {
        let body = r#"
          function paragraphs() {
            return { type: "complete", result: [{ type: "image", url: "" }] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search: empty, bookInfo, chapters: empty, paragraphs };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let collected = feed.paragraphs("b", "c").collect::<Vec<_>>().await;
        assert_eq!(collected.len(), 1);
        assert!(collected[0].is_err());
    }

    #[tokio::test]
    async fn book_info_rejects_oversized_fields() {
        let body = r#"
          function bookInfo() {
            return { type: "complete", result: {
              id: "1", title: "x".repeat(1025), author: "Test",
            } };
          }
          const empty = () => ({ type: "complete", result: [] });
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let error = feed
            .book_info("1")
            .await
            .expect_err("an oversized book info must fail");
        assert!(error.to_string().contains("book info exceeds field limits"));
    }

    #[tokio::test]
    async fn keeps_returned_feed_object_between_calls() {
        let body = r#"
          let calls = 0;
          function search() {
            calls += 1;
            return { type: "complete", result: [{
              id: String(calls), title: "Call " + calls, author: "Test",
            }] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let first = feed.search("x").collect::<Vec<_>>().await;
        let second = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(first[0].as_ref().unwrap().id, "1");
        assert_eq!(second[0].as_ref().unwrap().id, "2");
    }

    #[tokio::test]
    async fn feed_realm_cannot_compile_dynamic_code() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function bookInfo() {
            let constructorResult = "blocked";
            try {
              constructorResult = (() => {}).constructor("return 'open'")();
            } catch (_) {}
            return { type: "complete", result: {
                id: "1",
                title: [typeof eval, typeof Function, constructorResult].join(":"),
                author: "Test",
              } };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "undefined:undefined:blocked");
    }

    #[tokio::test]
    async fn compute_runs_in_a_separate_json_only_realm() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "compute",
                programs: [
                  "globalThis.remoteOnly = eval('input.value + 1')",
                  "export default { title: String(globalThis.remoteOnly), html: typeof HTML, fetch: typeof fetch };",
                ],
                input: { value: 41 },
                next_state: true,
              };
            }
            return { type: "complete", result: {
                id: event.input.bookId,
                title: event.compute.title,
                author: [event.compute.html, event.compute.fetch, typeof globalThis.remoteOnly].join(":"),
              } };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let book = feed.book_info("42").await.unwrap();
        assert_eq!(book.title, "42");
        assert_eq!(book.author, "undefined:undefined:undefined");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn serializes_persistent_object_calls_across_threads() {
        let body = r#"
          let calls = 0;
          function search() {
            calls += 1;
            return { type: "complete", result: [{
              id: String(calls), title: "Call " + calls, author: "Test",
            }] };
          }
          const empty = () => ({ type: "complete", result: [] });
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = Arc::new(
            ScriptEngine::new()
                .load_script(&source(6, body))
                .await
                .unwrap(),
        );
        let mut tasks = Vec::new();
        for _ in 0..16 {
            let feed = Arc::clone(&feed);
            tasks.push(tokio::spawn(async move {
                feed.search("x").collect::<Vec<_>>().await[0]
                    .as_ref()
                    .unwrap()
                    .id
                    .parse::<usize>()
                    .unwrap()
            }));
        }
        let mut calls = Vec::new();
        for task in tasks {
            calls.push(task.await.unwrap());
        }
        calls.sort_unstable();
        assert_eq!(calls, (1..=16).collect::<Vec<_>>());
    }

    // -----------------------------------------------------------------------
    // WebView steps
    // -----------------------------------------------------------------------

    /// Handler that records every request and replies with one canned
    /// snapshot, or with an auth-required error when `snapshot` is `None`.
    struct CannedWebview {
        requests: std::sync::Mutex<Vec<WebviewRequest>>,
        snapshot: Option<WebviewSnapshot>,
    }

    impl CannedWebview {
        fn with_snapshot(snapshot: WebviewSnapshot) -> Arc<Self> {
            Arc::new(Self {
                requests: std::sync::Mutex::new(Vec::new()),
                snapshot: Some(snapshot),
            })
        }

        fn canceled() -> Arc<Self> {
            Arc::new(Self {
                requests: std::sync::Mutex::new(Vec::new()),
                snapshot: None,
            })
        }
    }

    impl WebviewHandler for CannedWebview {
        fn open(&self, request: WebviewRequest) -> WebviewFuture {
            self.requests.lock().unwrap().push(request);
            let snapshot = self.snapshot.clone();
            Box::pin(async move {
                snapshot.ok_or_else(|| {
                    crate::error::Error::expected(
                        ExpectedErrorCode::AuthRequired,
                        "verification canceled",
                    )
                })
            })
        }
    }

    fn sample_snapshot() -> WebviewSnapshot {
        WebviewSnapshot {
            current_url: "https://example.com/verify".into(),
            html: "<html>ok</html>".into(),
            cookies: vec![CookieEntry {
                name: "msToken".into(),
                value: "device-token".into(),
                domain: Some(".example.com".into()),
                path: Some("/".into()),
                expires: None,
                secure: Some(true),
                http_only: Some(false),
                same_site: None,
            }],
        }
    }

    #[tokio::test]
    async fn webview_step_round_trips_snapshot_to_reducer() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function search(event) {
            if (event.state == null) {
              return {
                type: "webview",
                url: "https://example.com/verify",
                title: "Verify",
                user_agent: "TestWebView/1.0",
                next_state: { stage: 1 },
              };
            }
            if (event.state.stage === 1 && event.webview != null) {
              const cookie = event.webview.cookies.find((c) => c.name === "msToken");
              if (event.webview.current_url !== "https://example.com/verify") {
                return { type: "fail", code: "source_unavailable", message: "bad url" };
              }
              return { type: "complete", result: [{
                  id: "1",
                  title: cookie.value,
                  author: event.webview.html,
                }] };
            }
            return { type: "fail", code: "auth_required", message: "unexpected state" };
          }
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();
        let handler = CannedWebview::with_snapshot(sample_snapshot());
        feed.set_webview_handler(Some(handler.clone())).unwrap();

        let items = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(items.len(), 1);
        let item = items[0].as_ref().unwrap();
        assert_eq!(item.title, "device-token");
        assert_eq!(item.author, "<html>ok</html>");

        let requests = handler.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].url, "https://example.com/verify");
        assert_eq!(requests[0].title.as_deref(), Some("Verify"));
        assert_eq!(requests[0].feed_id, "test");
        assert_eq!(requests[0].feed_name, "Test");
        assert_eq!(requests[0].user_agent, "TestWebView/1.0");
    }

    #[tokio::test]
    async fn webview_step_is_blocked_when_allowlist_is_empty() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
            };
          }
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let script = source(6, body)
            .replace("// @access_domain example.com\n", "")
            .replace("// @access_domain 127.0.0.1\n", "");
        let feed = ScriptEngine::new().load_script(&script).await.unwrap();
        let handler = CannedWebview::with_snapshot(sample_snapshot());
        feed.set_webview_handler(Some(handler.clone())).unwrap();

        let items = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(items.len(), 1);
        assert!(matches!(
            items[0].as_ref().expect_err("must fail"),
            Error::Script(ScriptError::DomainNotAllowed { access_domains, .. })
                if access_domains.is_empty()
        ));
        assert!(handler.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn webview_step_without_handler_fails_auth_required() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
              next_state: {},
            };
          }
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();

        let items = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(items.len(), 1);
        let error = items[0].as_ref().expect_err("must fail");
        assert!(
            matches!(
                error,
                Error::Script(ScriptError::Expected {
                    code: ExpectedErrorCode::AuthRequired,
                    ..
                })
            ),
            "unexpected error: {error:?}"
        );
    }

    #[tokio::test]
    async fn webview_handler_error_aborts_operation() {
        let body = r#"
          const empty = () => ({ type: "complete", result: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
              next_state: {},
            };
          }
          const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(6, body))
            .await
            .unwrap();
        feed.set_webview_handler(Some(CannedWebview::canceled()))
            .unwrap();

        let items = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(items.len(), 1);
        let error = items[0].as_ref().expect_err("must fail");
        assert!(
            matches!(
                error,
                Error::Script(ScriptError::Expected {
                    code: ExpectedErrorCode::AuthRequired,
                    ..
                })
            ),
            "unexpected error: {error:?}"
        );
    }

    // -----------------------------------------------------------------------
    // langhuan:storage
    // -----------------------------------------------------------------------

    // The backend is the shipped `MemoryStorage` — the same type debug
    // tooling installs per session.

    /// A feed that stores its "device" in `search`, reads it in `bookInfo`,
    /// and deletes it in `chapters`.
    const STORAGE_FEED: &str = r#"
      import { storage } from "langhuan:storage";
      const empty = () => ({ type: "complete", result: [] });
      function search() {
        storage.set("device", { device_id: "abc" });
        return { type: "complete", result: [] };
      }
      function bookInfo() {
        const device = storage.get("device");
        return { type: "complete", result: { id: "1", title: device ? device.device_id : "none", author: "Test" } };
      }
      function chapters() {
        storage.delete("device");
        return { type: "complete", result: [] };
      }
      export default { search, bookInfo, chapters, paragraphs: empty };
    "#;

    #[tokio::test]
    async fn storage_round_trips_persists_and_isolates_feeds() {
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);

        let feed = engine.load_script(&source(6, STORAGE_FEED)).await.unwrap();
        feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(feed.book_info("1").await.unwrap().title, "abc");
        feed.chapters("1").collect::<Vec<_>>().await;
        assert_eq!(feed.book_info("1").await.unwrap().title, "none");

        // A freshly loaded feed reads what the previous instance stored:
        // values live in the host backend, not in the realm.
        feed.search("x").collect::<Vec<_>>().await;
        let reloaded = engine.load_script(&source(6, STORAGE_FEED)).await.unwrap();
        assert_eq!(reloaded.book_info("1").await.unwrap().title, "abc");

        // Another feed never sees the first feed's namespace.
        let other = format!(
            r#"// ==Feed==
// @id other
// @name Other
// @version 3.0.0
// @base_url https://example.com
// @schema_version 6
// ==/Feed==
{STORAGE_FEED}
"#
        );
        let other = engine.load_script(&other).await.unwrap();
        assert_eq!(other.book_info("1").await.unwrap().title, "none");
    }

    #[tokio::test]
    async fn storage_module_fails_to_load_without_a_backend() {
        let error = ScriptEngine::new()
            .load_script(&source(6, STORAGE_FEED))
            .await
            .expect_err("importing langhuan:storage without a backend must fail");
        assert!(
            error.to_string().contains("langhuan:storage"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn storage_handler_errors_reach_the_operation() {
        struct FailingStorage;
        impl StorageHandler for FailingStorage {
            fn get(&self, _: &str, _: &str) -> Result<Option<Value>> {
                Err(Error::database("disk on fire"))
            }
            fn set(&self, _: &str, _: &str, _: Value) -> Result<()> {
                Err(Error::database("disk on fire"))
            }
            fn delete(&self, _: &str, _: &str) -> Result<()> {
                Err(Error::database("disk on fire"))
            }
        }

        let engine = ScriptEngine::new().with_storage(Arc::new(FailingStorage) as _);
        let feed = engine.load_script(&source(6, STORAGE_FEED)).await.unwrap();
        let collected = feed.search("x").collect::<Vec<_>>().await;
        let error = collected[0]
            .as_ref()
            .expect_err("handler failure must surface");
        assert!(
            error.to_string().contains("disk on fire"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn storage_rejects_bad_keys_undefined_values_and_bytes() {
        let body = r#"
          import { storage } from "langhuan:storage";
          function search() {
            storage.get("");
            return { type: "complete", result: [] };
          }
          function bookInfo() {
            storage.set("k", undefined);
            return { type: "complete", result: { id: "1", title: "t", author: "a" } };
          }
          function chapters() {
            storage.set("k", new Uint8Array(4));
            return { type: "complete", result: [] };
          }
          function paragraphs() {
            storage.get("x".repeat(257));
            return { type: "complete", result: [] };
          }
          export default { search, bookInfo, chapters, paragraphs };
        "#;
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);
        let feed = engine.load_script(&source(6, body)).await.unwrap();

        let search = feed.search("x").collect::<Vec<_>>().await;
        let chapters = feed.chapters("1").collect::<Vec<_>>().await;
        let paragraphs = feed.paragraphs("1", "1").collect::<Vec<_>>().await;
        let cases = [
            (
                "empty key",
                search[0]
                    .as_ref()
                    .expect_err("empty key must fail")
                    .to_string(),
                "storage.get: `key` must be between 1 and 256 bytes",
            ),
            (
                "undefined value",
                feed.book_info("1")
                    .await
                    .expect_err("undefined must fail")
                    .to_string(),
                "storage.set: `value` must not be undefined",
            ),
            (
                "bytes value",
                chapters[0]
                    .as_ref()
                    .expect_err("bytes must fail")
                    .to_string(),
                "Bytes.toBase64/Bytes.toHex first",
            ),
            (
                "oversized key",
                paragraphs[0]
                    .as_ref()
                    .expect_err("oversized key must fail")
                    .to_string(),
                "storage.get: `key` must be between 1 and 256 bytes",
            ),
        ];
        for (name, error, expected) in cases {
            assert!(error.contains(expected), "{name}: {error}");
        }
    }

    #[tokio::test]
    async fn storage_wiring_global_is_swept_after_load() {
        let body = r#"
          import { storage } from "langhuan:storage";
          function bookInfo() {
            storage.set("probe", 1);
            return { type: "complete", result: {
                id: "1",
                title: typeof globalThis.__langhuan_storage + ":" + storage.get("probe"),
                author: "Test",
              } };
          }
          const empty = () => ({ type: "complete", result: [] });
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);
        let feed = engine.load_script(&source(6, body)).await.unwrap();
        // The wiring global is gone once the feed is loaded, while the
        // module's own handle keeps working.
        assert_eq!(feed.book_info("1").await.unwrap().title, "undefined:1");
    }

    /// Every checked-in book source must load: schema header, module
    /// imports, and the exported handler contract. `fanqie-app.js` imports
    /// `langhuan:storage`, so it needs an engine with a backend installed.
    #[test]
    fn checked_in_book_sources_load() {
        let manifest = env!("CARGO_MANIFEST_DIR");
        let sources = [
            ("../../docs/book-sources/biquge-tw.js", false),
            ("../../docs/book-sources/fanqie.js", false),
            ("../../docs/book-sources/fanqie-app.js", true),
            ("../../docs/book-sources/jjwxc.js", false),
            ("../../docs/book-sources/qidian.js", false),
        ];
        for (path, needs_storage) in sources {
            let script =
                std::fs::read_to_string(format!("{manifest}/{path}")).expect("source file");
            let engine = if needs_storage {
                ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _)
            } else {
                ScriptEngine::new()
            };
            engine
                .load_js_feed(&script)
                .unwrap_or_else(|error| panic!("{path} should load: {error}"));
        }
    }
}
