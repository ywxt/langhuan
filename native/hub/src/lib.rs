//! This `hub` crate is the
//! entry point of the Rust logic.

#[allow(clippy::wildcard_imports)]
mod frb_generated;

#[macro_use]
extern crate rust_i18n;

rust_i18n::i18n!("locales", fallback = "en");

mod actors;
pub mod api;
mod feed_storage;
mod logging;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Produce a locale-aware error string for a [`langhuan::error::Error`] using
/// the global rust-i18n locale set by the `SetLocale` signal handler.
pub(crate) fn localize_error(e: &langhuan::error::Error) -> String {
    use langhuan::error::{Error, ExpectedErrorCode, PersistenceError, RegistryError, ScriptError};
    match e {
        Error::Script(inner) => match inner {
            ScriptError::JavaScript(e) => t!("error.javascript", error = e).to_string(),
            ScriptError::MissingFunction { name } => {
                t!("error.missing_function", name = name).to_string()
            }
            ScriptError::InvalidFeed { message } => {
                t!("error.invalid_feed", message = message).to_string()
            }
            ScriptError::Parse { line, message } => {
                t!("error.script_parse", line = line, message = message).to_string()
            }
            ScriptError::DomainNotAllowed {
                url,
                access_domains,
            } => t!(
                "error.domain_not_allowed",
                url = url,
                allowed = join(access_domains.iter().map(|s| s.as_str()), ", ")
            )
            .to_string(),
            ScriptError::SchemaTooNew {
                feed_id,
                file_version,
                supported_version,
            } => t!(
                "error.feed_schema_too_new",
                feed_id = feed_id,
                file_version = file_version,
                supported_version = supported_version
            )
            .to_string(),
            ScriptError::AuthStatusNotSupported { feed_id } => {
                t!("error.auth_status_not_supported", feed_id = feed_id).to_string()
            }
            ScriptError::DuplicateId { feed_id, kind, id } => t!(
                "error.duplicate_id",
                feed_id = feed_id,
                kind = kind,
                id = id
            )
            .to_string(),
            ScriptError::Expected { code, message } => match code {
                ExpectedErrorCode::AuthRequired => {
                    t!("error.expected.auth_required", message = message).to_string()
                }
                ExpectedErrorCode::CfChallenge => {
                    t!("error.expected.cf_challenge", message = message).to_string()
                }
                ExpectedErrorCode::RateLimited => {
                    t!("error.expected.rate_limited", message = message).to_string()
                }
                ExpectedErrorCode::ContentNotFound => {
                    t!("error.expected.content_not_found", message = message).to_string()
                }
                ExpectedErrorCode::SourceUnavailable => {
                    t!("error.expected.source_unavailable", message = message).to_string()
                }
                ExpectedErrorCode::Unknown(code) => {
                    t!("error.expected.unknown", code = code, message = message).to_string()
                }
            },
        },
        Error::Registry(inner) => match inner {
            RegistryError::FeedNotFound { id } => t!("error.feed_not_found", id = id).to_string(),
        },
        Error::Persistence(inner) => match inner {
            PersistenceError::Database { message } => {
                t!("error.database", message = message).to_string()
            }
        },
        Error::Http(inner) => t!("error.http", error = inner).to_string(),
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
