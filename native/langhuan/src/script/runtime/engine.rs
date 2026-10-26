use std::sync::Arc;

use reqwest::Client;

use crate::error::Result;
use crate::http::new_client;
use crate::script::feed::ScriptFeed;
use crate::script::js::JsFeed;
use crate::script::meta;

/// Loads schema-3 JavaScript feeds into the native QuickJS sandbox runtime.
#[derive(Clone)]
pub struct ScriptEngine {
    client: Arc<Client>,
}

impl ScriptEngine {
    pub fn new() -> Self {
        Self {
            client: Arc::new(new_client()),
        }
    }

    pub fn with_client(client: Client) -> Self {
        Self {
            client: Arc::new(client),
        }
    }

    pub async fn load_script(&self, script: &str) -> Result<ScriptFeed> {
        self.load_js_feed(script)
    }

    pub fn load_js_feed(&self, script: &str) -> Result<JsFeed> {
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
                "JavaScript feeds require schema_version {}",
                crate::feed::meta::FEED_SCHEMA_VERSION,
            )));
        }
        JsFeed::new(
            script[body_offset..].to_owned(),
            feed_meta,
            (*self.client).clone(),
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
    use crate::error::{Error, ScriptError};
    use crate::feed::{Feed, FeedAuthFlow};
    use tokio_stream::StreamExt as _;

    use super::*;

    fn source(schema: u32, body: &str) -> String {
        format!(
            r#"// ==Feed==
// @id test
// @name Test
// @version 3.0.0
// @base_url https://example.com
// @schema_version {schema}
// ==/Feed==
{body}
"#,
        )
    }

    const RETURNED_FEED: &str = r#"(() => {
      const complete = () => ({ type: "complete", items: [] });
      const bookInfo = () => ({
        type: "complete", value: { id: "1", title: "One", author: "Author" },
      });
      return { search: complete, bookInfo, chapters: complete, paragraphs: complete };
    })()"#;

    #[tokio::test]
    async fn schema_three_accepts_returned_feed_object() {
        ScriptEngine::new()
            .load_script(&source(3, RETURNED_FEED))
            .await
            .expect("returned feed object should load");
    }

    #[tokio::test]
    async fn rejects_legacy_schema() {
        let error = ScriptEngine::new()
            .load_script(&source(2, RETURNED_FEED))
            .await
            .err()
            .expect("schema 2 must not be accepted");
        assert!(matches!(
            error,
            Error::Script(ScriptError::InvalidFeed { .. })
        ));
    }

    #[tokio::test]
    async fn rejects_newer_schema() {
        let error = ScriptEngine::new()
            .load_script(&source(4, RETURNED_FEED))
            .await
            .err()
            .expect("schema 4 must not be accepted");
        assert!(matches!(
            error,
            Error::Script(ScriptError::SchemaTooNew { .. })
        ));
    }

    #[tokio::test]
    async fn rejects_global_feed_registration() {
        let body = format!("globalThis.feed = {RETURNED_FEED}");
        let error = ScriptEngine::new()
            .load_script(&source(3, &body))
            .await
            .err()
            .expect("globalThis.feed registration must be rejected");
        assert!(error.to_string().contains("return its handler object"));
    }

    #[tokio::test]
    async fn rejects_partial_login_contract() {
        let body = RETURNED_FEED.replace(
            "return { search: complete, bookInfo, chapters: complete, paragraphs: complete };",
            "return { search: complete, bookInfo, chapters: complete, paragraphs: complete, login: { entry() {} } };",
        );
        let error = ScriptEngine::new()
            .load_script(&source(3, &body))
            .await
            .err()
            .expect("partial login contract must be rejected");
        assert!(error.to_string().contains("login.entry, login.parse"));
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
        let body = r#"(() => {
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
              value: { id: event.input.bookId, title: event.response.body, author: "Test" },
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
          return { search: empty, bookInfo, chapters: empty, paragraphs: empty, login };
        })()"#
            .replace("__BASE__", &server.url());
        let feed = ScriptEngine::new()
            .load_script(&source(3, &body))
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
    async fn keeps_returned_feed_object_between_calls() {
        let body = r#"(() => {
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
          return { search, bookInfo, chapters: empty, paragraphs: empty };
        })()"#;
        let feed = ScriptEngine::new()
            .load_script(&source(3, body))
            .await
            .unwrap();

        let first = feed.search("x").collect::<Vec<_>>().await;
        let second = feed.search("x").collect::<Vec<_>>().await;
        assert_eq!(first[0].as_ref().unwrap().id, "1");
        assert_eq!(second[0].as_ref().unwrap().id, "2");
    }

    #[tokio::test]
    async fn feed_realm_cannot_compile_dynamic_code() {
        let body = r#"(() => {
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
          return { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        })()"#;
        let feed = ScriptEngine::new()
            .load_script(&source(3, body))
            .await
            .unwrap();

        let book = feed.book_info("1").await.unwrap();
        assert_eq!(book.title, "undefined:undefined:blocked");
    }

    #[tokio::test]
    async fn compute_runs_in_a_separate_json_only_realm() {
        let body = r#"(() => {
          const empty = () => ({ type: "complete", items: [] });
          function bookInfo(event) {
            if (event.state == null) {
              return {
                type: "compute",
                programs: [
                  "globalThis.remoteOnly = eval('input.value + 1')",
                  "({ title: String(globalThis.remoteOnly), html: typeof HTML, fetch: typeof fetch })",
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
          return { search: empty, bookInfo, chapters: empty, paragraphs: empty };
        })()"#;
        let feed = ScriptEngine::new()
            .load_script(&source(3, body))
            .await
            .unwrap();

        let book = feed.book_info("42").await.unwrap();
        assert_eq!(book.title, "42");
        assert_eq!(book.author, "undefined:undefined:undefined");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn serializes_persistent_object_calls_across_threads() {
        let body = r#"(() => {
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
          return { search, bookInfo, chapters: empty, paragraphs: empty };
        })()"#;
        let feed = Arc::new(
            ScriptEngine::new()
                .load_script(&source(3, body))
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
}
