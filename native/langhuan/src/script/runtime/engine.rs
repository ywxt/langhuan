use std::sync::Arc;

use reqwest::Client;

use crate::error::Result;
use crate::feed::SharedStorageHandler;
use crate::http::new_client;
use crate::script::feed::ScriptFeed;
use crate::script::js::JsFeed;
use crate::script::meta;

/// Loads JavaScript feeds into the native QuickJS sandbox runtime.
#[derive(Clone)]
pub struct ScriptEngine {
    client: Arc<Client>,
    storage: Option<SharedStorageHandler>,
}

impl ScriptEngine {
    pub fn new() -> Self {
        Self {
            client: Arc::new(new_client()),
            storage: None,
        }
    }

    pub fn with_client(client: Client) -> Self {
        Self {
            client: Arc::new(client),
            storage: None,
        }
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
                 response bodies are now Uint8Array (decode with TextDecoder) and \
                 compute input/results may carry bytes",
                crate::feed::meta::FEED_SCHEMA_VERSION,
                feed_meta.schema_version,
            )));
        }
        JsFeed::new(
            script[body_offset..].to_owned(),
            feed_meta,
            (*self.client).clone(),
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
    use std::collections::HashMap;
    use std::sync::Mutex;

    use serde_json::Value;

    use crate::error::{Error, ExpectedErrorCode, ScriptError};
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
      const complete = () => ({ type: "complete", items: [] });
      const bookInfo = () => ({
        type: "complete", value: { id: "1", title: "One", author: "Author" },
      });
      export default { search: complete, bookInfo, chapters: complete, paragraphs: complete };
    "#;

    #[tokio::test]
    async fn schema_four_accepts_exported_feed_object() {
        ScriptEngine::new()
            .load_script(&source(4, RETURNED_FEED))
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
    async fn rejects_schema_three_with_a_migration_hint() {
        let error = ScriptEngine::new()
            .load_script(&source(3, RETURNED_FEED))
            .await
            .expect_err("schema 3 must not be accepted");
        let message = error.to_string();
        assert!(message.contains("schema_version 4"));
        assert!(message.contains("TextDecoder"));
    }

    #[tokio::test]
    async fn rejects_newer_schema() {
        let error = ScriptEngine::new()
            .load_script(&source(5, RETURNED_FEED))
            .await
            .expect_err("schema 4 must not be accepted");
        assert!(matches!(
            error,
            Error::Script(ScriptError::SchemaTooNew { .. })
        ));
    }

    #[tokio::test]
    async fn rejects_global_feed_registration() {
        let body = r#"
          const handlers = {
            search: () => ({ type: "complete", items: [] }),
            bookInfo: () => ({ type: "complete", value: { id: "1" } }),
            chapters: () => ({ type: "complete", items: [] }),
            paragraphs: () => ({ type: "complete", items: [] }),
          };
          globalThis.feed = handlers;
        "#;
        let error = ScriptEngine::new()
            .load_script(&source(4, body))
            .await
            .expect_err("globalThis.feed registration must be rejected");
        assert!(error.to_string().contains("export default"));
    }

    #[tokio::test]
    async fn rejects_partial_login_contract() {
        let body = RETURNED_FEED.replace(
            "export default { search: complete, bookInfo, chapters: complete, paragraphs: complete };",
            "export default { search: complete, bookInfo, chapters: complete, paragraphs: complete, login: { entry() {} } };",
        );
        let error = ScriptEngine::new()
            .load_script(&source(4, &body))
            .await
            .expect_err("partial login contract must be rejected");
        assert!(error.to_string().contains("login.entry, login.parse"));
    }

    #[tokio::test]
    async fn auth_entry_rejects_unsafe_user_agent() {
        let body = r#"
          const complete = () => ({ type: "complete", items: [] });
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Author" },
          });
          const login = {
            entry: () => ({ url: "https://example.com/login", user_agent: "Bad\nAgent" }),
            parse: () => ({}),
            patchRequest: (_operation, request) => request,
          };
          export default { search: complete, bookInfo, chapters: complete, paragraphs: complete, login };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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
            .match_header("x-operation", "book_info:42")
            .with_status(200)
            .with_body("ok")
            .create_async()
            .await;
        let body = r#"
          import { TextDecoder } from "langhuan:encoding";
          const empty = () => ({ type: "complete", items: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "request",
                request: { url: "__BASE__/book", method: "GET" },
                next_state: true,
              };
            }
            return {
              type: "complete",
              value: { id: event.input.bookId, title: new TextDecoder().decode(event.response.body), author: "Test" },
            };
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
            .load_script(&source(4, &body))
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
          const empty = () => ({ type: "complete", items: [] });
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
            return {
              type: "complete",
              value: {
                id: "1",
                title: keptDate && keptBlob && keptUndefinedKey ? "ok" : "broken",
                author: "Test",
              },
            };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#
        .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(4, &body))
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
          const empty = () => ({ type: "complete", items: [] });
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
            return {
              type: "complete",
              value: { id: "1", title: new TextDecoder().decode(event.response.body), author: "Test" },
            };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#
            .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(4, &body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "stored");
    }

    #[tokio::test]
    async fn completed_items_reject_bytes_with_guidance() {
        let body = r#"
          function search() {
            return {
              type: "complete",
              items: [{ id: "1", title: new Uint8Array([1]), author: "Test" }],
            };
          }
          const empty = () => ({ type: "complete", items: [] });
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
            .await
            .unwrap();

        let collected = feed.search("x").collect::<Vec<_>>().await;
        let Some(error) = collected[0].as_ref().err() else {
            panic!("bytes must be rejected in completed items");
        };
        assert!(error.to_string().contains("Uint8Array"));
    }

    #[tokio::test]
    async fn keeps_returned_feed_object_between_calls() {
        let body = r#"
          let calls = 0;
          function search() {
            calls += 1;
            return { type: "complete", items: [{
              id: String(calls), title: "Call " + calls, author: "Test",
            }] };
          }
          const empty = () => ({ type: "complete", items: [] });
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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
          const empty = () => ({ type: "complete", items: [] });
          function bookInfo() {
            let constructorResult = "blocked";
            try {
              constructorResult = (() => {}).constructor("return 'open'")();
            } catch (_) {}
            return {
              type: "complete",
              value: {
                id: "1",
                title: [typeof eval, typeof Function, constructorResult].join(":"),
                author: "Test",
              },
            };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "undefined:undefined:blocked");
    }

    #[tokio::test]
    async fn compute_runs_in_a_separate_json_only_realm() {
        let body = r#"
          const empty = () => ({ type: "complete", items: [] });
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
            return {
              type: "complete",
              value: {
                id: event.input.bookId,
                title: event.compute.title,
                author: [event.compute.html, event.compute.fetch, typeof globalThis.remoteOnly].join(":"),
              },
            };
          }
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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
            return { type: "complete", items: [{
              id: String(calls), title: "Call " + calls, author: "Test",
            }] };
          }
          const empty = () => ({ type: "complete", items: [] });
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = Arc::new(
            ScriptEngine::new()
                .load_script(&source(4, body))
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
          const empty = () => ({ type: "complete", items: [] });
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
              return {
                type: "complete",
                items: [{
                  id: "1",
                  title: cookie.value,
                  author: event.webview.html,
                }],
              };
            }
            return { type: "fail", code: "auth_required", message: "unexpected state" };
          }
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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
          const empty = () => ({ type: "complete", items: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
            };
          }
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let script = source(4, body)
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
          const empty = () => ({ type: "complete", items: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
              next_state: {},
            };
          }
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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
          const empty = () => ({ type: "complete", items: [] });
          function search() {
            return {
              type: "webview",
              url: "https://example.com/verify",
              user_agent: "TestWebView/1.0",
              next_state: {},
            };
          }
          const bookInfo = () => ({
            type: "complete", value: { id: "1", title: "One", author: "Test" },
          });
          export default { search, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let feed = ScriptEngine::new()
            .load_script(&source(4, body))
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

    /// An in-memory [`StorageHandler`] shared across feeds.
    #[derive(Default)]
    struct MemoryStorage(Mutex<HashMap<(String, String), Value>>);

    impl StorageHandler for MemoryStorage {
        fn get(&self, feed_id: &str, key: &str) -> Result<Option<Value>> {
            Ok(self
                .0
                .lock()
                .unwrap()
                .get(&(feed_id.to_owned(), key.to_owned()))
                .cloned())
        }

        fn set(&self, feed_id: &str, key: &str, value: Value) -> Result<()> {
            self.0
                .lock()
                .unwrap()
                .insert((feed_id.to_owned(), key.to_owned()), value);
            Ok(())
        }

        fn delete(&self, feed_id: &str, key: &str) -> Result<()> {
            self.0
                .lock()
                .unwrap()
                .remove(&(feed_id.to_owned(), key.to_owned()));
            Ok(())
        }
    }

    /// A feed that stores its "device" in `search`, reads it in `bookInfo`,
    /// and deletes it in `chapters`.
    const STORAGE_FEED: &str = r#"
      import { storage } from "langhuan:storage";
      const empty = () => ({ type: "complete", items: [] });
      function search() {
        storage.set("device", { device_id: "abc" });
        return { type: "complete", items: [] };
      }
      function bookInfo() {
        const device = storage.get("device");
        return {
          type: "complete",
          value: { id: "1", title: device ? device.device_id : "none", author: "Test" },
        };
      }
      function chapters() {
        storage.delete("device");
        return { type: "complete", items: [] };
      }
      export default { search, bookInfo, chapters, paragraphs: empty };
    "#;

    #[tokio::test]
    async fn storage_round_trips_persists_and_isolates_feeds() {
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);

        let feed = engine.load_script(&source(4, STORAGE_FEED)).await.unwrap();
        feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(feed.book_info("1").await.unwrap().title, "abc");
        feed.chapters("1").collect::<Vec<_>>().await;
        assert_eq!(feed.book_info("1").await.unwrap().title, "none");

        // A freshly loaded feed reads what the previous instance stored:
        // values live in the host backend, not in the realm.
        feed.search("x").collect::<Vec<_>>().await;
        let reloaded = engine.load_script(&source(4, STORAGE_FEED)).await.unwrap();
        assert_eq!(reloaded.book_info("1").await.unwrap().title, "abc");

        // Another feed never sees the first feed's namespace.
        let other = format!(
            r#"// ==Feed==
// @id other
// @name Other
// @version 3.0.0
// @base_url https://example.com
// @schema_version 4
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
            .load_script(&source(4, STORAGE_FEED))
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
        let feed = engine.load_script(&source(4, STORAGE_FEED)).await.unwrap();
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
            return { type: "complete", items: [] };
          }
          function bookInfo() {
            storage.set("k", undefined);
            return { type: "complete", value: { id: "1", title: "t", author: "a" } };
          }
          function chapters() {
            storage.set("k", new Uint8Array(4));
            return { type: "complete", items: [] };
          }
          function paragraphs() {
            storage.get("x".repeat(257));
            return { type: "complete", items: [] };
          }
          export default { search, bookInfo, chapters, paragraphs };
        "#;
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);
        let feed = engine.load_script(&source(4, body)).await.unwrap();

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
            return {
              type: "complete",
              value: {
                id: "1",
                title: typeof globalThis.__langhuan_storage + ":" + storage.get("probe"),
                author: "Test",
              },
            };
          }
          const empty = () => ({ type: "complete", items: [] });
          export default { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        "#;
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::default()) as _);
        let feed = engine.load_script(&source(4, body)).await.unwrap();
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
            ("../../docs/book-sources/fanqie.js", false),
            ("../../docs/book-sources/fanqie-app.js", true),
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
