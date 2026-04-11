//! This `hub` crate is the
//! entry point of the Rust logic.

#[allow(clippy::wildcard_imports)]
mod frb_generated;

#[macro_use]
extern crate rust_i18n;

rust_i18n::i18n!("locales", fallback = "en");

mod actors;
pub mod api;
mod logging;

#[cfg(target_os = "android")]
use jni::JNIEnv;
#[cfg(target_os = "android")]
use jni::objects::JObject;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

#[cfg(target_os = "android")]
#[unsafe(export_name = "Java_org_eu_ywxt_langhuan_MainActivity_initRustlsVerifier")]
pub extern "system" fn init_rustls_verifier(mut env: JNIEnv, _activity: JObject, context: JObject) {
    rustls_platform_verifier::android::init_with_env(&mut env, context)
        .expect("failed to initialize rustls-platform-verifier");
}

/// Produce a locale-aware error string for a [`langhuan::error::Error`] using
/// the global rust-i18n locale set by the `SetLocale` signal handler.
pub(crate) fn localize_error(e: &langhuan::error::Error) -> String {
    use langhuan::error::{Error, PersistenceError, RegistryError, ScriptError};
    match e {
        Error::Script(inner) => match inner {
            ScriptError::Lua(e) => t!("error.lua", error = e).to_string(),
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
        },
        Error::Registry(inner) => match inner {
            RegistryError::NotFound(e) => t!("error.registry_not_found", error = e).to_string(),
            RegistryError::Parse { message } => {
                t!("error.registry_parse", message = message).to_string()
            }
            RegistryError::Write(msg) => t!("error.registry_write", error = msg).to_string(),
            RegistryError::FeedNotFound { id } => t!("error.feed_not_found", id = id).to_string(),
            RegistryError::DuplicateFeedId { id } => {
                t!("error.duplicate_feed_id", id = id).to_string()
            }
            RegistryError::SchemaTooNew {
                file_version,
                supported_version,
            } => t!(
                "error.registry_schema_too_new",
                file_version = file_version,
                supported_version = supported_version
            )
            .to_string(),
        },
        Error::Persistence(inner) => match inner {
            PersistenceError::Storage {
                kind,
                operation,
                message,
            } => t!(
                "error.storage",
                target = localize_storage_kind(*kind),
                operation = localize_storage_operation(*operation),
                message = message
            )
            .to_string(),
            PersistenceError::Format {
                kind,
                operation,
                message,
            } => t!(
                "error.format",
                target = localize_format_kind(*kind),
                operation = localize_format_operation(*operation),
                message = message
            )
            .to_string(),
            PersistenceError::CacheSchemaMismatch { details } => t!(
                "error.cache_schema_mismatch",
                feed_id = details.feed_id,
                book_id = details.book_id,
                chapter_id = details.chapter_id,
                cached_version = details.cached_version,
                expected_version = details.expected_version
            )
            .to_string(),
            PersistenceError::CacheKeyMismatch { details } => t!(
                "error.cache_key_mismatch",
                expected_feed_id = details.expected_feed_id,
                expected_book_id = details.expected_book_id,
                expected_chapter_id = details.expected_chapter_id,
                actual_feed_id = details.actual_feed_id,
                actual_book_id = details.actual_book_id,
                actual_chapter_id = details.actual_chapter_id,
            )
            .to_string(),
        },
        Error::Http(inner) => t!("error.http", error = inner).to_string(),
    }
}

fn localize_storage_kind(kind: langhuan::error::StorageKind) -> String {
    use langhuan::error::StorageKind;

    match kind {
        StorageKind::Bookshelf => t!("error_target.bookshelf").to_string(),
        StorageKind::ReadingProgress => t!("error_target.reading_progress").to_string(),
        StorageKind::ChapterCache => t!("error_target.chapter_cache").to_string(),
        StorageKind::Auth => t!("error_target.auth").to_string(),
    }
}

fn localize_storage_operation(operation: langhuan::error::StorageOperation) -> String {
    use langhuan::error::StorageOperation;

    match operation {
        StorageOperation::Read => t!("error_operation.read").to_string(),
        StorageOperation::Write => t!("error_operation.write").to_string(),
        StorageOperation::CreateDir => t!("error_operation.create_dir").to_string(),
        StorageOperation::RemoveFile => t!("error_operation.remove_file").to_string(),
        StorageOperation::RemoveDir => t!("error_operation.remove_dir").to_string(),
    }
}

fn localize_format_kind(kind: langhuan::error::FormatKind) -> String {
    use langhuan::error::FormatKind;

    match kind {
        FormatKind::Bookshelf => t!("error_target.bookshelf_file").to_string(),
        FormatKind::ReadingProgress => t!("error_target.reading_progress_file").to_string(),
        FormatKind::ChapterCache => t!("error_target.chapter_cache_file").to_string(),
        FormatKind::Auth => t!("error_target.auth_file").to_string(),
    }
}

fn localize_format_operation(operation: langhuan::error::FormatOperation) -> String {
    use langhuan::error::FormatOperation;

    match operation {
        FormatOperation::Serialize => t!("error_operation.serialize").to_string(),
        FormatOperation::Deserialize => t!("error_operation.deserialize").to_string(),
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
