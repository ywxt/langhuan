//! HTTP tracing for the developer tools.
//!
//! This module is the recording side of the app's debug environment; the
//! only hook into the production path is [`crate::http::execute`], which
//! checks [`active`] once per request and, when a recorder is attached,
//! reports the request's outcome through it. Production code never sets
//! the task-local, so outside a debug run the hook costs one task-local
//! lookup and nothing else.
//!
//! The recorder is scoped to a single task: only requests made by the
//! debug run itself are captured. Concurrent production traffic — even for
//! the same feed — is untouched.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use bytes::Bytes;

use crate::http::HttpRequest;

// Task-local recorder set by debug tooling around a pipeline-stage run.
tokio::task_local! {
    static HTTP_TRACE: TraceHandle;
}

/// Entries kept per run; requests past this limit are counted, not stored.
const TRACE_ENTRY_LIMIT: usize = 64;

/// Total body-preview budget per run. Once exhausted, entries keep their
/// metadata but carry no preview.
const TRACE_BODY_BUDGET_BYTES: usize = 256 * 1024;

/// Per-entry preview cap. A single truncation from the top: SSR payloads
/// sit near the beginning of the document and error pages are small.
const TRACE_PREVIEW_MAX_BYTES: usize = 64 * 1024;

/// The recorder attached to the current task, if any. `None` everywhere
/// except inside a [`TraceRecorder::scope`] debug run.
pub(crate) fn active() -> Option<TraceHandle> {
    HTTP_TRACE.try_get().ok()
}

/// One recorded HTTP request: what was sent, what came back, and how long
/// it took. Credential-bearing header values are masked.
#[derive(Debug, Clone)]
pub struct TraceEntry {
    /// HTTP method as requested (`GET`, `POST`, …).
    pub method: String,
    /// The requested URL.
    pub url: String,
    /// Final URL after redirects; `None` when the request never produced a
    /// response.
    pub final_url: Option<String>,
    /// Response status code; `None` when the request failed or was blocked.
    pub status: Option<u16>,
    /// Request headers as sent, with sensitive values masked.
    pub request_headers: Vec<(String, String)>,
    /// Time from the start of [`crate::http::execute`] to the recorded
    /// outcome.
    pub elapsed_ms: u64,
    /// Response body size in bytes; `None` when no body was received.
    pub response_size: Option<u64>,
    /// Lossy-UTF-8 prefix of the response body, bounded by the per-entry
    /// cap and the run's remaining preview budget.
    pub body_preview: Option<String>,
    /// Why the request never produced a usable response (blocked by the
    /// domain allowlist, network failure, …).
    pub error: Option<String>,
}

/// Cloneable handle to a run's trace buffer, handed out only by
/// [`TraceRecorder`]; the task-local and [`active`] are the only holders.
#[derive(Clone)]
pub(crate) struct TraceHandle {
    buffer: Arc<TraceBuffer>,
}

impl TraceHandle {
    /// A request rejected by the domain allowlist before any network call.
    pub(crate) fn record_blocked(&self, req: &HttpRequest, start: Option<Instant>) {
        let mut entry = self.entry(req, start);
        entry.error = Some("blocked by access_domains".to_owned());
        self.push(entry);
    }

    /// A request that failed before a response arrived (DNS, connect,
    /// TLS, timeout, …).
    pub(crate) fn record_send_error(
        &self,
        req: &HttpRequest,
        start: Option<Instant>,
        error: &reqwest::Error,
    ) {
        let mut entry = self.entry(req, start);
        entry.error = Some(error.to_string());
        self.push(entry);
    }

    /// A response whose body download failed mid-way.
    pub(crate) fn record_body_error(
        &self,
        req: &HttpRequest,
        status: u16,
        final_url: &str,
        start: Option<Instant>,
        error: &reqwest::Error,
    ) {
        let mut entry = self.entry(req, start);
        entry.status = Some(status);
        entry.final_url = Some(crate::http::redact_url_secrets(final_url));
        entry.error = Some(error.to_string());
        self.push(entry);
    }

    /// A fully received response.
    pub(crate) fn record_response(
        &self,
        req: &HttpRequest,
        status: u16,
        final_url: &str,
        body: &Bytes,
        start: Option<Instant>,
    ) {
        let mut entry = self.entry(req, start);
        entry.status = Some(status);
        entry.final_url = Some(crate::http::redact_url_secrets(final_url));
        entry.response_size = Some(body.len() as u64);
        entry.body_preview = Some(trace_body_preview(body));
        self.push(entry);
    }

    /// The per-request fields every outcome shares.
    fn entry(&self, req: &HttpRequest, start: Option<Instant>) -> TraceEntry {
        TraceEntry {
            method: req.method.clone(),
            url: req.url.clone(),
            final_url: None,
            status: None,
            request_headers: mask_request_headers(&req.headers),
            elapsed_ms: elapsed_ms(start),
            response_size: None,
            body_preview: None,
            error: None,
        }
    }

    /// Append an entry, enforcing the entry limit and the preview budget.
    fn push(&self, mut entry: TraceEntry) {
        // A poisoned lock means the recording side already panicked; the
        // request pipeline must not follow it. Drop the entry instead.
        let Ok(mut state) = self.buffer.state.lock() else {
            return;
        };
        if state.entries.len() >= TRACE_ENTRY_LIMIT {
            state.dropped += 1;
            return;
        }
        if let Some(preview) = entry.body_preview.take() {
            if preview.len() > state.body_budget {
                if state.body_budget > 0 {
                    // Shrink to the remaining budget on a char boundary.
                    let mut end = state.body_budget;
                    while !preview.is_char_boundary(end) {
                        end -= 1;
                    }
                    let mut preview = preview;
                    preview.truncate(end);
                    entry.body_preview = Some(preview);
                }
                // A zero budget leaves the entry with metadata only.
                state.body_budget = 0;
            } else {
                state.body_budget -= preview.len();
                entry.body_preview = Some(preview);
            }
        }
        state.entries.push(entry);
    }
}

struct TraceBuffer {
    state: Mutex<TraceBufferState>,
}

#[derive(Default)]
struct TraceBufferState {
    entries: Vec<TraceEntry>,
    /// Requests recorded past [`TRACE_ENTRY_LIMIT`] so the UI can signal
    /// that the trace was truncated.
    dropped: u32,
    /// Remaining bytes of the body-preview budget.
    body_budget: usize,
}

impl TraceBufferState {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
            dropped: 0,
            body_budget: TRACE_BODY_BUDGET_BYTES,
        }
    }
}

/// Owner of one debug run's trace buffer.
///
/// Debug tooling creates a recorder, wraps a pipeline-stage execution in
/// [`TraceRecorder::scope`], and then reads the captured entries with
/// [`TraceRecorder::finish`]. The recorder is bounded: at most
/// [`TRACE_ENTRY_LIMIT`] entries and [`TRACE_BODY_BUDGET_BYTES`] bytes of
/// body previews per run.
pub struct TraceRecorder {
    handle: TraceHandle,
}

impl Default for TraceRecorder {
    fn default() -> Self {
        Self::new()
    }
}

impl TraceRecorder {
    pub fn new() -> Self {
        Self {
            handle: TraceHandle {
                buffer: Arc::new(TraceBuffer {
                    state: Mutex::new(TraceBufferState::new()),
                }),
            },
        }
    }

    /// Run `fut` with this recorder active for the current task. Every
    /// [`crate::http::execute`] call made inside it — at any await depth,
    /// within the same task — is recorded here. Requests made by other
    /// tasks (e.g. the production pipeline) are unaffected.
    pub async fn scope<F: Future>(&self, fut: F) -> F::Output {
        HTTP_TRACE.scope(self.handle.clone(), fut).await
    }

    /// The captured entries, in execution order, plus the number of
    /// requests recorded past the entry limit.
    pub fn finish(&self) -> (Vec<TraceEntry>, u32) {
        // A poisoned lock means the recording side panicked; an empty trace
        // is a better debug outcome than propagating the panic here.
        let Ok(state) = self.handle.buffer.state.lock() else {
            return (Vec::new(), 0);
        };
        (state.entries.clone(), state.dropped)
    }
}

fn elapsed_ms(start: Option<Instant>) -> u64 {
    start.map(|s| s.elapsed().as_millis() as u64).unwrap_or(0)
}

/// Lossy-UTF-8 prefix of `body`, bounded by the per-entry preview cap.
fn trace_body_preview(body: &Bytes) -> String {
    let cap = body.len().min(TRACE_PREVIEW_MAX_BYTES);
    String::from_utf8_lossy(&body[..cap]).into_owned()
}

/// Mask credential-bearing request header values for display.
///
/// * `Cookie`: cookie names survive, values become `<masked>`
///   (`ywkey=<masked>`).
/// * `Authorization`-style: the scheme survives (`Bearer <masked>`).
/// * Everything else passes through verbatim.
fn mask_request_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|(name, value)| {
            let lower = name.to_ascii_lowercase();
            if lower == "cookie" || lower == "set-cookie" {
                (name.clone(), mask_cookie_value(value))
            } else if lower == "authorization" || lower == "proxy-authorization" {
                (name.clone(), mask_authorization_value(value))
            } else {
                (name.clone(), value.clone())
            }
        })
        .collect()
}

fn mask_cookie_value(value: &str) -> String {
    value
        .split(';')
        .map(|part| match part.trim().split_once('=') {
            Some((name, _)) => format!("{name}=<masked>"),
            None => "<masked>".to_owned(),
        })
        .collect::<Vec<_>>()
        .join("; ")
}

fn mask_authorization_value(value: &str) -> String {
    match value.split_once(' ') {
        Some((scheme, _)) => format!("{scheme} <masked>"),
        None => "<masked>".to_owned(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{
        TRACE_BODY_BUDGET_BYTES, TRACE_ENTRY_LIMIT, TraceEntry, TraceRecorder, mask_request_headers,
    };
    use crate::http::{HttpRequest, execute, shared_client};

    /// Masking keeps cookie names and auth schemes, hides the secrets.
    #[test]
    fn masking_keeps_cookie_names_and_auth_schemes() {
        let masked = mask_request_headers(&[
            (
                "Cookie".to_owned(),
                "ywkey=secret; ywguid=42; plain".to_owned(),
            ),
            (
                "Authorization".to_owned(),
                "Bearer super-secret-token".to_owned(),
            ),
            ("User-Agent".to_owned(), "langhuan/1.0".to_owned()),
            ("X-Trace".to_owned(), "keep-me".to_owned()),
        ]);

        let cookie = &masked[0];
        assert_eq!(cookie.0, "Cookie");
        assert_eq!(cookie.1, "ywkey=<masked>; ywguid=<masked>; <masked>");
        assert_eq!(masked[1].1, "Bearer <masked>");
        assert_eq!(masked[2].1, "langhuan/1.0");
        assert_eq!(masked[3].1, "keep-me");
        // Nothing sensitive may survive anywhere in the masked output.
        let all = format!("{masked:?}");
        assert!(!all.contains("secret") && !all.contains("super-secret"));
    }

    /// A request blocked by `access_domains` is recorded with an error and
    /// without leaving the task (no network involved).
    #[tokio::test]
    async fn trace_records_blocked_request() {
        let recorder = TraceRecorder::new();
        let domains: HashSet<String> = HashSet::from(["allowed.example".to_owned()]);
        let req = HttpRequest {
            url: "https://blocked.example/page".to_owned(),
            method: "GET".to_owned(),
            params: Default::default(),
            headers: Vec::new(),
            body: None,
        };

        let result = recorder
            .scope(execute(shared_client(), "feed", &domains, &req))
            .await;

        assert!(result.is_err());
        let (entries, dropped) = recorder.finish();
        assert_eq!(dropped, 0);
        let entry = entries.first().expect("blocked request recorded");
        assert_eq!(entry.url, "https://blocked.example/page");
        assert_eq!(entry.status, None);
        assert_eq!(entry.final_url, None);
        assert!(
            entry
                .error
                .as_deref()
                .unwrap_or_default()
                .contains("blocked")
        );
    }

    /// Entries past the limit are counted, not stored.
    #[tokio::test]
    async fn trace_entry_limit_drops_excess() {
        let recorder = TraceRecorder::new();
        recorder
            .scope(async {
                let handle = super::HTTP_TRACE.get();
                for i in 0..(TRACE_ENTRY_LIMIT as u32 + 3) {
                    handle.push(stub_entry(&format!("https://x.example/{i}"), None));
                }
            })
            .await;

        let (entries, dropped) = recorder.finish();
        assert_eq!(entries.len(), TRACE_ENTRY_LIMIT);
        assert_eq!(dropped, 3);
    }

    /// Previews share one budget: once it is spent, later entries keep
    /// their metadata but carry no preview.
    #[tokio::test]
    async fn trace_body_budget_truncates_previews() {
        let recorder = TraceRecorder::new();
        recorder
            .scope(async {
                let handle = super::HTTP_TRACE.get();
                // Ten 64 KiB previews overrun the 256 KiB budget mid-way.
                for i in 0..10 {
                    handle.push(stub_entry(
                        &format!("https://x.example/{i}"),
                        Some("x".repeat(64 * 1024)),
                    ));
                }
            })
            .await;

        let (entries, _) = recorder.finish();
        let with_preview = entries.iter().filter(|e| e.body_preview.is_some()).count();
        assert!(with_preview >= TRACE_BODY_BUDGET_BYTES / (64 * 1024));
        assert!(with_preview < entries.len(), "budget must run out");
        // The last preview is truncated to the remaining budget, on a char
        // boundary, so it is valid UTF-8 by construction.
        let truncated = entries.iter().rfind(|e| e.body_preview.is_some()).unwrap();
        let _ = truncated.body_preview.as_deref().unwrap().chars().count();
    }

    fn stub_entry(url: &str, preview: Option<String>) -> TraceEntry {
        TraceEntry {
            method: "GET".to_owned(),
            url: url.to_owned(),
            final_url: None,
            status: None,
            request_headers: Vec::new(),
            elapsed_ms: 0,
            response_size: None,
            body_preview: preview,
            error: None,
        }
    }
}
