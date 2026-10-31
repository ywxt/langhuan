//! Public names used by the hub for script-backed feeds.
//!
//! Feed schema 5 has one runtime only: JavaScript inside native QuickJS.
pub type ScriptFeed = super::js::JsFeed;
pub type ScriptSupportAuth = super::js::JsSupportAuth;
pub use super::js::DebugOperationPage;
