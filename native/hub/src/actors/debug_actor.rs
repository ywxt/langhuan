//! Owns the debug environment the developer tools run in.
//!
//! The environment is the loaded script instance: runs execute on it
//! directly, so module state and the session's in-memory storage persist
//! across runs. [`LoadDebugScript`] compiles the script over a fresh
//! engine — a load is a state reset, with a new realm and new in-memory
//! storage. The page loads when it opens (with the restored editor
//! contents), on the explicit load/reload action, and whenever the editor
//! is replaced wholesale (agent loads, imports); typing alone changes
//! nothing until the next load. [`LeaveDebugTools`] drops the environment
//! when the page closes: a closed session's data dies with it, and the
//! persistent storage of installed feeds is never involved. Because the
//! actor processes messages one at a time, a lifecycle change never
//! interleaves with an in-flight run: the run finishes on the environment
//! it started with.

use std::sync::Arc;

use async_trait::async_trait;
use langhuan::feed::storage::MemoryStorage;
use langhuan::script::feed::ScriptFeed;
use langhuan::script::runtime::ScriptEngine;
use messages::actor::Actor;
use messages::prelude::{Address, Context, Handler};

use super::webview_actor::{WebviewActor, attach_webview_handler};
use crate::api::debug::{self, DebugRunResult, DebugStage};
use crate::api::types::BridgeError;

/// Message: make `script` the loaded debug script — compiled over a fresh
/// engine, so loading is also reloading: previous state and storage die
/// with the environment they belonged to.
pub struct LoadDebugScript {
    pub script: String,
}

/// Message: run one stage of the loaded script with full observability.
pub struct RunDebugStage {
    pub stage: DebugStage,
}

/// Message: the developer tools page closed — drop the debug environment.
pub struct LeaveDebugTools;

pub struct DebugActor {
    /// The loaded script, present exactly while the developer tools page
    /// is open (and something compiled). Runs execute on this instance
    /// directly, so module state and the session's in-memory storage
    /// persist across runs.
    feed: Option<ScriptFeed>,
    webview: Address<WebviewActor>,
}

impl DebugActor {
    /// `webview` is the app's verification actor, so gated debug runs
    /// pause on the same interactive page production uses.
    pub fn new(webview: Address<WebviewActor>) -> Self {
        Self {
            feed: None,
            webview,
        }
    }

    /// Compile `script` over a fresh engine and make it the environment.
    async fn load(&mut self, script: String) -> Result<(), BridgeError> {
        // A fresh engine per load: the realm and the in-memory storage
        // backend are new, so a load is a complete state reset.
        let engine = ScriptEngine::new().with_storage(Arc::new(MemoryStorage::new()));
        let feed = engine
            .load_script(&script)
            .await
            .map_err(BridgeError::from)?;
        // Attach once at load: the feed keeps the handler for its whole
        // lifetime, so webview steps in any run reach the app's
        // interactive verification page.
        attach_webview_handler(&feed, &self.webview).map_err(BridgeError::from)?;
        self.feed = Some(feed);
        Ok(())
    }
}

impl Actor for DebugActor {}

#[async_trait]
impl Handler<LoadDebugScript> for DebugActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, message: LoadDebugScript, _: &Context<Self>) -> Self::Result {
        self.load(message.script).await
    }
}

#[async_trait]
impl Handler<RunDebugStage> for DebugActor {
    type Result = Result<DebugRunResult, BridgeError>;

    async fn handle(&mut self, message: RunDebugStage, _: &Context<Self>) -> Self::Result {
        let feed = self.feed.as_ref().ok_or_else(|| {
            BridgeError::from(
                "no script loaded — load a script into the developer tools first".to_owned(),
            )
        })?;
        Ok(debug::run_stage(feed, message.stage).await)
    }
}

#[async_trait]
impl Handler<LeaveDebugTools> for DebugActor {
    type Result = ();

    async fn handle(&mut self, _: LeaveDebugTools, _: &Context<Self>) -> Self::Result {
        self.feed = None;
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use messages::prelude::{Address, Context};

    use super::{DebugActor, LeaveDebugTools, LoadDebugScript, RunDebugStage};
    use crate::actors::webview_actor::{CompleteWebview, SubscribeWebviewPrompts, WebviewActor};
    use crate::api::debug::{DebugRunResult, DebugStage, DebugStageOutput};
    use crate::api::types::{ParagraphContent, WebviewPrompt};

    type TestResult = Result<(), Box<dyn Error>>;

    /// Spawns an idle WebviewActor and hands back its address.
    fn webview_address() -> Address<WebviewActor> {
        let context = Context::new();
        let address = context.address();
        tokio::spawn(context.run(WebviewActor::new()));
        address
    }

    fn spawn_debug_actor() -> Address<DebugActor> {
        let context = Context::new();
        let address = context.address();
        tokio::spawn(context.run(DebugActor::new(webview_address())));
        address
    }

    fn load(script: &str) -> LoadDebugScript {
        LoadDebugScript {
            script: script.to_owned(),
        }
    }

    fn run_paragraphs() -> RunDebugStage {
        RunDebugStage {
            stage: DebugStage::Paragraphs {
                book_id: "1".to_owned(),
                chapter_id: "1".to_owned(),
            },
        }
    }

    fn paragraph_texts(result: DebugRunResult) -> Vec<String> {
        match result.output {
            Some(DebugStageOutput::Paragraphs { items }) => items
                .into_iter()
                .map(|item| match item {
                    ParagraphContent::Text { content, .. } => content,
                    _ => panic!("expected a text paragraph"),
                })
                .collect(),
            None => panic!("expected paragraphs output, got none"),
            Some(_) => panic!("expected paragraphs output, got another stage"),
        }
    }

    /// A script that counts its runs twice: once in module state, once in
    /// `langhuan:storage`. Both counters advance across runs of one load
    /// and both restart after a reload.
    const COUNTER_SCRIPT: &str = r#"
// ==Feed==
// @id           dbg-counter
// @name         Debug Counter
// @version      3.0.0
// @base_url     https://example.com
// @access_domain example.com
// @schema_version 6
// ==/Feed==
import { storage } from "langhuan:storage";
let moduleRuns = 0;
const empty = () => ({ type: "complete", result: [] });
function paragraphs() {
  moduleRuns += 1;
  const stored = (storage.get("runs") ?? 0) + 1;
  storage.set("runs", stored);
  return {
    type: "complete",
    result: [{ type: "text", content: `${moduleRuns}/${stored}` }],
  };
}
const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
export default { search: empty, bookInfo, chapters: empty, paragraphs };
"#;

    #[tokio::test]
    async fn state_persists_across_runs_and_resets_on_reload() -> TestResult {
        let mut actor = spawn_debug_actor();

        // Before anything is loaded there is no script to run.
        let refused = actor.send(run_paragraphs()).await?;
        assert!(refused.is_err(), "a run without a loaded script must fail");

        // Load: the environment is stateful from here on.
        actor.send(load(COUNTER_SCRIPT)).await??;
        let first = actor.send(run_paragraphs()).await??;
        assert!(first.error.is_none());
        assert_eq!(paragraph_texts(first), ["1/1"]);

        // A second run executes the SAME instance: module state and
        // storage both advance — runs must not recompile the script.
        let second = actor.send(run_paragraphs()).await??;
        assert!(second.error.is_none());
        assert_eq!(paragraph_texts(second), ["2/2"]);

        // Reloading compiles over a fresh engine: a complete reset.
        actor.send(load(COUNTER_SCRIPT)).await??;
        let third = actor.send(run_paragraphs()).await??;
        assert!(third.error.is_none());
        assert_eq!(paragraph_texts(third), ["1/1"]);

        // Leaving drops the environment; runs refuse again.
        actor.send(LeaveDebugTools).await?;
        let refused = actor.send(run_paragraphs()).await?;
        assert!(refused.is_err(), "a run after leaving must fail");
        Ok(())
    }

    /// A script that fails to compile leaves the environment empty — the
    /// previous load, if any, survives untouched.
    #[tokio::test]
    async fn a_failed_load_rejects_the_script_and_keeps_the_previous_one() -> TestResult {
        let mut actor = spawn_debug_actor();

        assert!(
            actor
                .send(load("this is not a feed script"))
                .await?
                .is_err(),
            "compiling garbage must fail"
        );
        // Still nothing loaded: the failed load did not become the
        // environment.
        assert!(actor.send(run_paragraphs()).await?.is_err());

        actor.send(load(COUNTER_SCRIPT)).await??;
        assert!(
            actor.send(load("still not a feed script")).await?.is_err(),
            "compiling garbage must fail"
        );
        // The working script is still the loaded one.
        let result = actor.send(run_paragraphs()).await??;
        assert!(result.error.is_none());
        assert_eq!(paragraph_texts(result), ["1/1"]);
        Ok(())
    }

    /// A webview step in a debug run reaches the real verification actor:
    /// the prompt it pushes is answered, and the snapshot flows back into
    /// the run's result.
    const WEBVIEW_SCRIPT: &str = r#"
// ==Feed==
// @id           dbg-webview
// @name         Debug Webview
// @version      3.0.0
// @base_url     https://example.com
// @access_domain example.com
// @schema_version 6
// ==/Feed==
const empty = () => ({ type: "complete", result: [] });
function paragraphs(event) {
  if (event.state == null) {
    return {
      type: "webview",
      url: "https://example.com/verify",
      user_agent: "DebugWebView/1.0",
      next_state: 1,
    };
  }
  return { type: "complete", result: [{ type: "text", content: event.webview.html }] };
}
const bookInfo = () => ({ type: "complete", result: { id: "1", title: "One", author: "Test" } });
export default { search: empty, bookInfo, chapters: empty, paragraphs };
"#;

    #[tokio::test]
    async fn webview_steps_reach_the_verification_actor() -> TestResult {
        // Stand in for the app's prompt page: answer every prompt with a
        // known snapshot.
        let mut webview = webview_address();
        let mut prompts = webview.send(SubscribeWebviewPrompts).await??;
        let mut answerer = webview.clone();
        let answered = Arc::new(AtomicUsize::new(0));
        let counter = answered.clone();
        tokio::spawn(async move {
            while let Some(WebviewPrompt { request_id, .. }) = prompts.recv().await {
                counter.fetch_add(1, Ordering::SeqCst);
                let _ = answerer
                    .send(CompleteWebview {
                        request_id,
                        current_url: "https://example.com/verify".to_owned(),
                        html: "<p>verified</p>".to_owned(),
                        cookies: vec![],
                    })
                    .await;
            }
        });

        let context = Context::new();
        let mut actor = context.address();
        tokio::spawn(context.run(DebugActor::new(webview)));
        actor.send(load(WEBVIEW_SCRIPT)).await??;

        let result = actor.send(run_paragraphs()).await??;
        assert!(result.error.is_none(), "error: {:?}", result.error);
        assert_eq!(paragraph_texts(result), ["<p>verified</p>"]);
        // The run was gated by exactly one verification prompt.
        assert_eq!(answered.load(Ordering::SeqCst), 1);
        Ok(())
    }
}
