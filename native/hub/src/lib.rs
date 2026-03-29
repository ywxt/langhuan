//! This `hub` crate is the
//! entry point of the Rust logic.

#[macro_use]
extern crate rust_i18n;

rust_i18n::i18n!("locales", fallback = "en");

mod actors;
mod signals;

use actors::create_actors;
use rinf::{dart_shutdown, write_interface};
use signals::SetLocale;
use tokio::spawn;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

write_interface!();

// You can go with any async library, not just `tokio`.
#[tokio::main(flavor = "current_thread")]
async fn main() {
    // Spawn concurrent tasks.
    // Always use non-blocking async functions like `tokio::fs::File::open`.
    // If you must use blocking code, use `tokio::task::spawn_blocking`
    // or the equivalent provided by your async library.

    // Listen for locale changes from Dart (sent at startup and on system
    // language change) and update the global rust-i18n locale accordingly.
    // rust-i18n has built-in RFC 4647 lookup fallback, so we pass the full
    // BCP 47 tag directly: e.g. "zh-CN" → tries zh-CN → zh → fallback "en".
    spawn(async {
        use rinf::DartSignal;
        let rx = SetLocale::get_dart_signal_receiver();
        while let Some(pack) = rx.recv().await {
            rust_i18n::set_locale(&pack.message.locale);
        }
    });

    spawn(create_actors());

    // Keep the main function running until Dart shutdown.
    dart_shutdown().await;
}
/// Produce a locale-aware error string for a [`langhuan::error::Error`] using
/// the global rust-i18n locale set by the `SetLocale` signal handler.
fn localize_error(e: &langhuan::error::Error) -> String {
    use langhuan::error::Error;
    match e {
        Error::Lua(inner) => t!("error.lua", error = inner).to_string(),
        Error::Http(inner) => t!("error.http", error = inner).to_string(),
        Error::MissingFunction { name } => {
            t!("error.missing_function", name = name).to_string()
        }
        Error::InvalidFeed { message } => {
            t!("error.invalid_feed", message = message).to_string()
        }
        Error::ScriptParse { line, message } => t!(
            "error.script_parse",
            line = line,
            message = message
        )
        .to_string(),
        Error::RegistryNotFound(inner) => {
            t!("error.registry_not_found", error = inner).to_string()
        }
        Error::RegistryParse { message } => {
            t!("error.registry_parse", message = message).to_string()
        }
        Error::FeedNotFound { id } => t!("error.feed_not_found", id = id).to_string(),
        Error::DuplicateFeedId { id } => {
            t!("error.duplicate_feed_id", id = id).to_string()
        }
        Error::DomainNotAllowed { url, allowed } => t!(
            "error.domain_not_allowed",
            url = url,
            allowed = join(allowed.iter().map(|s| s.as_str()), ", ")
        )
        .to_string(),
        Error::RegistryWrite(msg) => t!("error.registry_write", error = msg).to_string(),
    }
}

fn join<'a>(mut iter: impl Iterator<Item = &'a str>, joiner: &str) -> String {
    let mut joined = String::new();

    if let Some(item) = iter.next() {
        joined.push_str(item);
    }

    for item in iter {
        joined.push_str(joiner);
        joined.push_str(item);
    }

    joined
}
