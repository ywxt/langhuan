//! The JavaScript prelude evaluated in the feed realm before feed source.
//!
//! Only FeedError is installed. Encoding belongs to langhuan:encoding;
//! browser environments for site code must be explicitly supplied in compute.

pub(super) const PRELUDE: &str = r#"
globalThis.FeedError = Object.freeze({
  authRequired(message) {
    return { type: "fail", code: "auth_required", message: String(message) };
  },
  cfChallenge(message) {
    return { type: "fail", code: "cf_challenge", message: String(message) };
  },
  rateLimited(message) {
    return { type: "fail", code: "rate_limited", message: String(message) };
  },
  contentNotFound(message) {
    return { type: "fail", code: "content_not_found", message: String(message) };
  },
  sourceUnavailable(message) {
    return { type: "fail", code: "source_unavailable", message: String(message) };
  },
  raise(code, message) {
    return { type: "fail", code: String(code), message: String(message) };
  },
});

"#;
