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
    use crate::feed::Feed;
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
