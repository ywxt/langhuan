//! Reducer-step tracing for the feed developer tools.
//!
//! Like [`crate::trace`], this is task-local and inert in production. The
//! JavaScript feed runner reports the step returned by each reducer round;
//! debug tooling scopes a recorder around one operation and reads it back.

use std::future::Future;
use std::sync::{Arc, Mutex};

tokio::task_local! {
    static STEP_TRACE: StepTraceHandle;
}

const STEP_TRACE_LIMIT: usize = 128;
const STEP_SUMMARY_LIMIT_BYTES: usize = 4096;

#[derive(Debug, Clone)]
pub struct StepTraceEntry {
    pub operation: String,
    pub round: u32,
    pub kind: String,
    pub summary: String,
}

#[derive(Clone)]
pub(crate) struct StepTraceHandle {
    buffer: Arc<Mutex<StepTraceState>>,
}

#[derive(Default)]
struct StepTraceState {
    entries: Vec<StepTraceEntry>,
    dropped: u32,
}

pub(crate) fn record(operation: &str, round: usize, kind: &str, mut summary: String) {
    let Ok(handle) = STEP_TRACE.try_get() else {
        return;
    };
    let Ok(mut state) = handle.buffer.lock() else {
        return;
    };
    if state.entries.len() >= STEP_TRACE_LIMIT {
        state.dropped += 1;
        return;
    }
    if summary.len() > STEP_SUMMARY_LIMIT_BYTES {
        let mut end = STEP_SUMMARY_LIMIT_BYTES;
        while !summary.is_char_boundary(end) {
            end -= 1;
        }
        summary.truncate(end);
        summary.push('…');
    }
    state.entries.push(StepTraceEntry {
        operation: operation.to_owned(),
        round: u32::try_from(round).unwrap_or(u32::MAX),
        kind: kind.to_owned(),
        summary,
    });
}

pub struct StepTraceRecorder {
    handle: StepTraceHandle,
}

impl Default for StepTraceRecorder {
    fn default() -> Self {
        Self::new()
    }
}

impl StepTraceRecorder {
    pub fn new() -> Self {
        Self {
            handle: StepTraceHandle {
                buffer: Arc::new(Mutex::new(StepTraceState::default())),
            },
        }
    }

    pub async fn scope<F: Future>(&self, future: F) -> F::Output {
        STEP_TRACE.scope(self.handle.clone(), future).await
    }

    pub fn finish(&self) -> (Vec<StepTraceEntry>, u32) {
        let Ok(state) = self.handle.buffer.lock() else {
            return (Vec::new(), 0);
        };
        (state.entries.clone(), state.dropped)
    }
}
