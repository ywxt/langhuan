//! The JavaScript prelude evaluated in the feed realm before feed source.
//!
//! It provides the small browser-like surface book sources expect — `console`,
//! timers, `atob`/`btoa`, `navigator` — plus `FeedError`, the sanctioned way
//! for a script to signal an anticipated failure back to the host. Nothing
//! here reaches the filesystem, the network, or the clock.

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

// QuickJS intentionally has no browser APIs. These pure helpers are enough
// for site-provided decryptors without granting network or system access.
globalThis.atob = function(input) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  let str = String(input).replace(/=+$/, "");
  let output = "";
  if (str.length % 4 === 1) throw new TypeError("invalid base64");
  for (let bc = 0, bs, buffer, idx = 0;
       (buffer = str.charAt(idx++));
       ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer,
       bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
    buffer = chars.indexOf(buffer);
  }
  return output;
};
globalThis.btoa = function(input) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let str = String(input);
  let output = "";
  for (let idx = 0; idx < str.length; idx += 3) {
    const a = str.charCodeAt(idx);
    const b = str.charCodeAt(idx + 1);
    const c = str.charCodeAt(idx + 2);
    const hasB = idx + 1 < str.length;
    const hasC = idx + 2 < str.length;
    output += chars.charAt(a >> 2);
    output += chars.charAt(((a & 3) << 4) | (hasB ? b >> 4 : 0));
    output += hasB ? chars.charAt(((b & 15) << 2) | (hasC ? c >> 6 : 0)) : "=";
    output += hasC ? chars.charAt(c & 63) : "=";
  }
  return output;
};
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.navigator = { userAgent: "Langhuan QuickJS" };
globalThis.console = {
  log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {}
};
globalThis.performance = { now() { return Date.now(); } };
globalThis.setTimeout = function(callback) {
  if (typeof callback === "function") callback();
  return 0;
};
globalThis.clearTimeout = function() {};
globalThis.setInterval = function() { return 0; };
globalThis.clearInterval = function() {};
"#;
