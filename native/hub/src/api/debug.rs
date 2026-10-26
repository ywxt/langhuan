//! Developer tools for feed scripts: a stage runner with an HTTP inspector.
//!
//! The debug environment is deliberately independent from the app's normal
//! operation. Scripts are compiled from source handed in by the caller (the
//! developer page) — never from the installed registry — and run on a
//! dedicated engine with no response cache and no bookshelf pipeline.
//! Nothing a run does is written back. The only reads into app state are
//! the "import installed script" convenience ([`debug_get_installed_script`])
//! and the stored auth payload for the script's feed id, so login-gated
//! stages observe the same cookies as production.
//!
//! A run reuses the production execution path exactly — same sandbox, same
//! `access_domains` enforcement, same auth patching — while recording every
//! HTTP request the stage makes (see `langhuan::trace`). The toolkit
//! observes; it never widens what a script is allowed to do.
//!
//! Unlike production, results are returned as data: a failing run still
//! carries the items collected before the failure, so a script author can
//! see a half-parsed page and its error side by side.

use std::sync::LazyLock;
use std::time::Instant;

use langhuan::feed::{AuthStatus as FeedAuthStatus, Feed, FeedAuthFlow};
use langhuan::model::Paragraph;
use langhuan::script::feed::ScriptFeed;
use langhuan::script::runtime::ScriptEngine;
use langhuan::trace::{TraceEntry, TraceRecorder};
use tokio_stream::StreamExt;

use super::types::{
    AuthStatus, BookInfo, BridgeError, ChapterItem, ParagraphContent, ParagraphId, SearchResultItem,
};
use crate::actors::hub_db;

/// Script engine shared by all debug runs.
///
/// Debug feeds are compiled fresh from the caller's script source on every
/// run — no cached [`ScriptFeed`], no shared state with the production
/// registry — but the engine (and with it one HTTP client and connection
/// pool) is reused so repeated runs do not rebuild TLS state.
static DEBUG_ENGINE: LazyLock<ScriptEngine> = LazyLock::new(ScriptEngine::new);

/// Stage selection plus its input, mirroring the reading pipeline's
/// operations one to one.
pub enum DebugStage {
    /// `search(keyword)` → every result page, until the cursor runs out.
    Search { keyword: String },
    /// `book_info(book_id)` → metadata.
    BookInfo { book_id: String },
    /// `chapters(book_id)` → the full table of contents.
    Chapters { book_id: String },
    /// `paragraphs(book_id, chapter_id)` → the chapter's paragraphs.
    Paragraphs { book_id: String, chapter_id: String },
    /// The login-status probe (requires a feed with a `login` block).
    AuthStatus,
}

/// Typed output of a stage run, using the reading pipeline's own models.
pub enum DebugStageOutput {
    Search { items: Vec<SearchResultItem> },
    BookInfo { info: BookInfo },
    Chapters { items: Vec<ChapterItem> },
    Paragraphs { items: Vec<ParagraphContent> },
    AuthStatus { status: AuthStatus },
}

/// Metadata of the compiled script, reported with every run so the
/// developer page can confirm *what* it just executed.
pub struct DebugScriptMeta {
    pub id: String,
    pub name: String,
    pub version: String,
    pub base_url: String,
}

/// How the run handled auth, reported with every run.
pub enum DebugAuthUse {
    /// The script declares no login block; stages run without auth.
    NotSupported,
    /// A login block exists but no auth is stored for this feed id.
    Missing,
    /// The stored auth payload was hydrated into the run.
    Applied,
}

/// One recorded HTTP request of a debug run.
///
/// The bridge-facing mirror of [`langhuan::trace::TraceEntry`]; header
/// values that could carry credentials are already masked when they get
/// here.
pub struct HttpTraceEntry {
    pub method: String,
    pub url: String,
    pub final_url: Option<String>,
    pub status: Option<u16>,
    pub request_headers: Vec<(String, String)>,
    pub elapsed_ms: u64,
    pub response_size: Option<u64>,
    pub body_preview: Option<String>,
    pub error: Option<String>,
}

impl From<TraceEntry> for HttpTraceEntry {
    fn from(entry: TraceEntry) -> Self {
        Self {
            method: entry.method,
            url: entry.url,
            final_url: entry.final_url,
            status: entry.status,
            request_headers: entry.request_headers,
            elapsed_ms: entry.elapsed_ms,
            response_size: entry.response_size,
            body_preview: entry.body_preview,
            error: entry.error,
        }
    }
}

/// The outcome of a debug run: what the stage produced, what failed, and
/// the HTTP traffic it generated.
pub struct DebugRunResult {
    /// Metadata of the compiled script; `None` when the script failed to
    /// compile.
    pub script_meta: Option<DebugScriptMeta>,
    /// How auth was handled for the run.
    pub auth: DebugAuthUse,
    /// What the stage produced. Streams terminate on their first error, so
    /// a failing run can still carry the items that made it through —
    /// `None` when the stage produced nothing at all or never ran.
    pub output: Option<DebugStageOutput>,
    /// The run's terminal error (script error, network error, …); `None`
    /// on a clean run.
    pub error: Option<BridgeError>,
    /// Recorded HTTP traffic, in execution order.
    pub trace: Vec<HttpTraceEntry>,
    /// Requests recorded past the trace's entry limit.
    pub dropped_entries: u32,
    /// Wall-clock duration of the run in milliseconds.
    pub duration_ms: u64,
}

/// Run one pipeline stage of a feed script with full observability.
///
/// The script is compiled from `script` — the developer page's editor
/// contents, which may be a work-in-progress that is not installed
/// anywhere. The stage then executes exactly as production would, while
/// every HTTP request — including ones the domain allowlist blocks — is
/// recorded into the result's trace.
pub async fn debug_run_stage(script: String, stage: DebugStage) -> DebugRunResult {
    let start = Instant::now();
    let recorder = TraceRecorder::new();

    // Compilation and the stage run both happen inside the scope: script
    // loading performs no HTTP, so only the stage's own traffic is traced.
    let core = recorder.scope(run_script_stage(script, stage)).await;
    let (trace, dropped) = recorder.finish();

    DebugRunResult {
        script_meta: core.script_meta,
        auth: core.auth,
        output: core.output,
        error: core.error,
        trace: trace.into_iter().map(HttpTraceEntry::from).collect(),
        dropped_entries: dropped,
        duration_ms: start.elapsed().as_millis() as u64,
    }
}

/// Everything a run produced, before the recorder is consulted.
struct DebugRunCore {
    script_meta: Option<DebugScriptMeta>,
    auth: DebugAuthUse,
    output: Option<DebugStageOutput>,
    error: Option<BridgeError>,
}

async fn run_script_stage(script: String, stage: DebugStage) -> DebugRunCore {
    let feed = match DEBUG_ENGINE.load_script(&script).await {
        Ok(feed) => feed,
        Err(e) => {
            return DebugRunCore {
                script_meta: None,
                auth: DebugAuthUse::NotSupported,
                output: None,
                error: Some(e.into()),
            };
        }
    };

    let meta = feed.meta();
    let script_meta = DebugScriptMeta {
        id: meta.id.clone(),
        name: meta.name.clone(),
        version: meta.version.clone(),
        base_url: meta.base_url.clone(),
    };

    // Reuse the stored login of a feed with the same id (read-only):
    // login-gated stages observe exactly the cookies production would.
    let auth = match feed.supports_auth() {
        None => DebugAuthUse::NotSupported,
        Some(support) => {
            let (applied, error) = match load_stored_auth(&meta.id).await {
                Ok(stored) => {
                    let applied = if stored.is_some() {
                        DebugAuthUse::Applied
                    } else {
                        DebugAuthUse::Missing
                    };
                    match feed.set_auth_info(&support, stored) {
                        Ok(()) => (applied, None),
                        Err(e) => (applied, Some(e.into())),
                    }
                }
                Err(e) => (DebugAuthUse::Missing, Some(e)),
            };
            if let Some(error) = error {
                return DebugRunCore {
                    script_meta: Some(script_meta),
                    auth: applied,
                    output: None,
                    error: Some(error),
                };
            }
            applied
        }
    };

    let (output, error) = run_stage(&feed, stage).await;
    DebugRunCore {
        script_meta: Some(script_meta),
        auth,
        output,
        error,
    }
}

/// Read the current script of an installed feed — the developer page's
/// "import from installed feed" convenience. Read-only, like everything
/// else in the debug environment.
pub async fn debug_get_installed_script(feed_id: String) -> Result<String, BridgeError> {
    let db = hub_db()?;
    let id = feed_id.clone();
    let script = db
        .call(move |repo| repo.get_current_script(&id))
        .await
        .map_err(BridgeError::from)?;
    match script {
        Some(script) => Ok(script),
        None => Err(BridgeError::from(
            rust_i18n::t!("error.feed_not_found", id = feed_id).to_string(),
        )),
    }
}

async fn load_stored_auth(feed_id: &str) -> Result<Option<serde_json::Value>, BridgeError> {
    let db = hub_db()?;
    let id = feed_id.to_owned();
    db.call(move |repo| repo.get_auth(&id))
        .await
        .map_err(BridgeError::from)
}

/// Execute one stage on a freshly compiled feed, collecting stream items
/// until exhaustion or the first error.
async fn run_stage(
    feed: &ScriptFeed,
    stage: DebugStage,
) -> (Option<DebugStageOutput>, Option<BridgeError>) {
    match stage {
        DebugStage::Search { keyword } => {
            let mut items = Vec::new();
            let mut error = None;
            let mut stream = feed.search(&keyword);
            while let Some(result) = stream.next().await {
                match result {
                    Ok(item) => items.push(SearchResultItem {
                        id: item.id,
                        title: item.title,
                        author: item.author,
                        cover_url: item.cover_url,
                        description: item.description,
                    }),
                    Err(e) => {
                        error = Some(e.into());
                        break;
                    }
                }
            }
            wrap_stream_output(
                error.is_none() || !items.is_empty(),
                DebugStageOutput::Search { items },
                error,
            )
        }
        DebugStage::BookInfo { book_id } => match feed.book_info(&book_id).await {
            Ok(info) => (
                Some(DebugStageOutput::BookInfo {
                    info: BookInfo {
                        id: info.id,
                        title: info.title,
                        author: info.author,
                        cover_url: info.cover_url,
                        description: info.description,
                    },
                }),
                None,
            ),
            Err(e) => (None, Some(e.into())),
        },
        DebugStage::Chapters { book_id } => {
            let mut items = Vec::new();
            let mut error = None;
            let mut stream = feed.chapters(&book_id);
            while let Some(result) = stream.next().await {
                match result {
                    Ok(chapter) => items.push(ChapterItem {
                        id: chapter.id,
                        title: chapter.title,
                    }),
                    Err(e) => {
                        error = Some(e.into());
                        break;
                    }
                }
            }
            wrap_stream_output(
                error.is_none() || !items.is_empty(),
                DebugStageOutput::Chapters { items },
                error,
            )
        }
        DebugStage::Paragraphs {
            book_id,
            chapter_id,
        } => {
            let mut items = Vec::new();
            let mut error = None;
            let mut stream = feed.paragraphs(&book_id, &chapter_id);
            while let Some(result) = stream.next().await {
                match result {
                    Ok(paragraph) => items.push(paragraph_content(paragraph)),
                    Err(e) => {
                        error = Some(e.into());
                        break;
                    }
                }
            }
            wrap_stream_output(
                error.is_none() || !items.is_empty(),
                DebugStageOutput::Paragraphs { items },
                error,
            )
        }
        DebugStage::AuthStatus => {
            let Some(support) = feed.supports_auth() else {
                return (
                    None,
                    Some(BridgeError::from(
                        rust_i18n::t!("error.auth_status_not_supported", feed_id = feed.meta().id)
                            .to_string(),
                    )),
                );
            };
            match feed.auth_status(&support).await {
                Ok(status) => (
                    Some(DebugStageOutput::AuthStatus {
                        status: bridge_auth_status(status),
                    }),
                    None,
                ),
                Err(e) => (None, Some(e.into())),
            }
        }
    }
}

/// A stream stage always reports its page on a clean run (even "0 items",
/// which is itself a finding); a failed stream still reports whatever
/// items made it through before the error, alongside the error itself.
fn wrap_stream_output(
    has_output: bool,
    output: DebugStageOutput,
    error: Option<BridgeError>,
) -> (Option<DebugStageOutput>, Option<BridgeError>) {
    (has_output.then_some(output), error)
}

fn paragraph_content(paragraph: Paragraph) -> ParagraphContent {
    match paragraph {
        Paragraph::Title { id, text } => ParagraphContent::Title {
            id: ParagraphId::from(id),
            text,
        },
        Paragraph::Text { id, content } => ParagraphContent::Text {
            id: ParagraphId::from(id),
            content,
        },
        Paragraph::Image { id, url, alt } => ParagraphContent::Image {
            id: ParagraphId::from(id),
            url,
            alt,
        },
    }
}

fn bridge_auth_status(status: FeedAuthStatus) -> AuthStatus {
    match status {
        FeedAuthStatus::LoggedIn => AuthStatus::LoggedIn,
        FeedAuthStatus::Expired => AuthStatus::Expired,
        FeedAuthStatus::LoggedOut => AuthStatus::LoggedOut,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::script::runtime::ScriptEngine;
    use langhuan::trace::TraceRecorder;

    use super::*;
    use crate::api::types::ErrorKind;

    type TestResult = Result<(), Box<dyn Error>>;

    /// Minimal script against a mockito server: search returns a JSON page
    /// with `__IDS__` split into items; book_info echoes the id.
    fn fixture_script(base_url: &str, _search_ids: &str) -> String {
        format!(
            r#"
// ==Feed==
// @id           dbg-fixture
// @name         Debug Fixture
// @version      3.0.0
// @base_url     {base_url}
// @access_domain 127.0.0.1
// @schema_version 3
// ==/Feed==
(() => {{
  const request = (path) => ({{
    type: "request",
    request: {{ url: meta.base_url + path, method: "GET" }},
    next_state: {{ requested: true }},
  }});
  function search(event) {{
    if (event.state == null) return request("/search");
    const ids = JSON.parse(event.response.body).ids;
    return {{ type: "complete", items: ids.map((id) => ({{
      id, title: "Book " + id, author: "Author",
    }})) }};
  }}
  function bookInfo(event) {{
    if (event.state == null) return request("/book/" + event.input.bookId);
    return {{ type: "complete", value: JSON.parse(event.response.body) }};
  }}
  function chapters(event) {{
    return event.state == null
      ? request("/chapters")
      : {{ type: "complete", items: [] }};
  }}
  function paragraphs(event) {{
    return event.state == null
      ? request("/content")
      : {{ type: "complete", items: [] }};
  }}
  return {{ search, bookInfo, chapters, paragraphs }};
}})()
"#
        )
    }

    async fn mock_search(server: &mut mockito::Server, body: &'static str) -> mockito::Mock {
        server
            .mock("GET", "/search")
            .with_status(200)
            .with_body(body)
            .create_async()
            .await
    }

    /// A clean run reports every item and no error.
    #[tokio::test]
    async fn search_run_collects_all_items() -> TestResult {
        let mut server = mockito::Server::new_async().await;
        let _mock = mock_search(&mut server, r#"{"ids":["1","2","3"]}"#).await;
        let feed = ScriptEngine::new()
            .load_script(&fixture_script(
                &server.url(),
                r#"json.decode(resp.body).ids"#,
            ))
            .await?;

        let (output, error) = run_stage(
            &feed,
            DebugStage::Search {
                keyword: "k".to_owned(),
            },
        )
        .await;

        assert!(error.is_none());
        let Some(DebugStageOutput::Search { items }) = output else {
            panic!("expected search output");
        };
        let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["1", "2", "3"]);
        Ok(())
    }

    /// A duplicate id mid-stream terminates the stage: the items before the
    /// duplicate survive alongside the error — the exact situation the
    /// debug page must be able to show.
    #[tokio::test]
    async fn duplicate_id_keeps_partial_items_and_reports_error() -> TestResult {
        let mut server = mockito::Server::new_async().await;
        let _mock = mock_search(&mut server, r#"{"ids":["1","2","2","3"]}"#).await;
        let feed = ScriptEngine::new()
            .load_script(&fixture_script(
                &server.url(),
                r#"json.decode(resp.body).ids"#,
            ))
            .await?;

        let (output, error) = run_stage(
            &feed,
            DebugStage::Search {
                keyword: "k".to_owned(),
            },
        )
        .await;

        let error = error.expect("duplicate id must surface as an error");
        assert!(matches!(
            error.kind,
            ErrorKind::ScriptConfig | ErrorKind::ScriptRuntime
        ));
        let Some(DebugStageOutput::Search { items }) = output else {
            panic!("partial items must survive");
        };
        // Items 1 and 2 were yielded before the duplicate was detected.
        let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["1", "2"]);
        Ok(())
    }

    /// A clean run that produces nothing still reports an empty page (0
    /// items is a finding, not an absence of output).
    #[tokio::test]
    async fn empty_clean_search_reports_empty_page() -> TestResult {
        let mut server = mockito::Server::new_async().await;
        let _mock = mock_search(&mut server, r#"{"ids":[]}"#).await;
        let feed = ScriptEngine::new()
            .load_script(&fixture_script(
                &server.url(),
                r#"json.decode(resp.body).ids"#,
            ))
            .await?;

        let (output, error) = run_stage(
            &feed,
            DebugStage::Search {
                keyword: "k".to_owned(),
            },
        )
        .await;

        assert!(error.is_none());
        let Some(DebugStageOutput::Search { items }) = output else {
            panic!("empty page must still be reported");
        };
        assert!(items.is_empty());
        Ok(())
    }

    /// The auth-status stage on a feed without a login block reports the
    /// localized "not supported" error instead of panicking.
    #[tokio::test]
    async fn auth_status_without_login_block_reports_error() -> TestResult {
        let feed = ScriptEngine::new()
            .load_script(&fixture_script("http://127.0.0.1:1", "{}"))
            .await?;

        let (output, error) = run_stage(&feed, DebugStage::AuthStatus).await;
        assert!(output.is_none());
        assert!(error.is_some());
        Ok(())
    }

    /// The recorder wiring used by `debug_run_stage`: scoping a stage run
    /// captures the HTTP traffic it generated, including the blocked
    /// pre-flight of a disallowed domain.
    #[tokio::test]
    async fn scoped_stage_run_records_traffic() -> TestResult {
        let mut server = mockito::Server::new_async().await;
        let _mock = mock_search(&mut server, r#"{"ids":["1"]}"#).await;
        let feed = ScriptEngine::new()
            .load_script(&fixture_script(
                &server.url(),
                r#"json.decode(resp.body).ids"#,
            ))
            .await?;

        let recorder = TraceRecorder::new();
        let (output, error) = recorder
            .scope(run_stage(
                &feed,
                DebugStage::Search {
                    keyword: "k".to_owned(),
                },
            ))
            .await;
        let (trace, dropped) = recorder.finish();

        assert!(error.is_none());
        assert!(output.is_some());
        assert_eq!(dropped, 0);
        assert_eq!(trace.len(), 1, "one request, one entry");
        let entry = &trace[0];
        assert_eq!(entry.method, "GET");
        assert_eq!(entry.status, Some(200));
        assert!(entry.error.is_none());
        // The preview carries the raw body — this is what makes SSR pages
        // debuggable in-app.
        assert!(
            entry
                .body_preview
                .as_deref()
                .is_some_and(|p| p.contains(r#""ids":["1"]"#))
        );
        Ok(())
    }
}
