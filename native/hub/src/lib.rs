//! This `hub` crate is the
//! entry point of the Rust logic.

// The generated bindings are formatted by FRB's own prettyplease pass,
// which orders use-items differently from rustfmt; skipping keeps
// `cargo fmt --check` green on freshly generated bindings (CI
// regenerates them every run — they are gitignored).
#[allow(clippy::wildcard_imports)]
#[rustfmt::skip]
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
            ScriptError::TooLarge { limit } => {
                t!("error.script_too_large", limit = size_label(*limit)).to_string()
            }
            ScriptError::ResponseTooLarge { limit } => {
                t!("error.response_too_large", limit = size_label(*limit)).to_string()
            }
            ScriptError::Parse { line, message } => {
                t!("error.script_parse", line = line, message = message).to_string()
            }
            ScriptError::DomainNotAllowed {
                host,
                access_domains,
            } => t!(
                "error.domain_not_allowed",
                host = host,
                allowed = if access_domains.is_empty() {
                    t!("error.none").to_string()
                } else {
                    join(access_domains.iter().map(|s| s.as_str()), ", ")
                }
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
                ExpectedErrorCode::VerificationRequired => {
                    t!("error.expected.verification_required", message = message).to_string()
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

/// Render a byte size the way the UI does (e.g. `2 MB`).
pub(crate) fn size_label(bytes: usize) -> String {
    const MB: usize = 1024 * 1024;
    const KB: usize = 1024;
    if bytes >= MB {
        format!("{} MB", bytes / MB)
    } else {
        format!("{} KB", bytes / KB)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::localize_error;

    #[test]
    fn chinese_locales_use_the_correct_script() {
        assert_eq!(
            t!("error.feed_not_found", locale = "zh-CN", id = "example"),
            "找不到书源：example"
        );
        assert_eq!(
            t!("error.feed_not_found", locale = "zh", id = "example"),
            "找不到書源：example"
        );
    }

    #[test]
    fn domain_errors_report_the_host_and_the_allowlist() {
        let error = langhuan::error::Error::domain_not_allowed(
            "https://Example.com/books",
            HashSet::from(["api.example.com".to_owned()]),
        );
        assert_eq!(
            localize_error(&error),
            "Domain not allowed: example.com (allowed: api.example.com)"
        );
    }

    #[test]
    fn domain_errors_without_an_allowlist_say_none() {
        let error =
            langhuan::error::Error::domain_not_allowed("https://example.com/books", HashSet::new());
        assert_eq!(
            localize_error(&error),
            "Domain not allowed: example.com (allowed: none)"
        );
    }
}
