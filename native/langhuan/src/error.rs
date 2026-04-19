use std::collections::HashSet;

// ---------------------------------------------------------------------------
// Auxiliary types (unchanged)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageKind {
    Bookshelf,
    ReadingProgress,
    ChapterCache,
    Auth,
    Bookmark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageOperation {
    Read,
    Write,
    CreateDir,
    RemoveFile,
    RemoveDir,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatKind {
    Bookshelf,
    ReadingProgress,
    ChapterCache,
    Auth,
    Bookmark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatOperation {
    Serialize,
    Deserialize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheSchemaMismatchError {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub cached_version: u32,
    pub expected_version: u32,
}

impl std::fmt::Display for CacheSchemaMismatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}/{}/{}: cached={}, expected={}",
            self.feed_id, self.book_id, self.chapter_id, self.cached_version, self.expected_version
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheKeyMismatchError {
    pub expected_feed_id: String,
    pub expected_book_id: String,
    pub expected_chapter_id: String,
    pub actual_feed_id: String,
    pub actual_book_id: String,
    pub actual_chapter_id: String,
}

impl std::fmt::Display for CacheKeyMismatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "expected {}/{}/{} but found {}/{}/{}",
            self.expected_feed_id,
            self.expected_book_id,
            self.expected_chapter_id,
            self.actual_feed_id,
            self.actual_book_id,
            self.actual_chapter_id
        )
    }
}

// ---------------------------------------------------------------------------
// Expected error codes (Lua → Rust structured errors)
// ---------------------------------------------------------------------------

/// Error codes that Lua scripts can raise via `@langhuan/error` to signal
/// an anticipated condition (as opposed to a runtime bug).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExpectedErrorCode {
    AuthRequired,
    CfChallenge,
    RateLimited,
    ContentNotFound,
    SourceUnavailable,
    Unknown(String),
}

impl ExpectedErrorCode {
    pub fn from_code(code: &str) -> Self {
        match code {
            "auth_required" => Self::AuthRequired,
            "cf_challenge" => Self::CfChallenge,
            "rate_limited" => Self::RateLimited,
            "content_not_found" => Self::ContentNotFound,
            "source_unavailable" => Self::SourceUnavailable,
            other => Self::Unknown(other.to_owned()),
        }
    }
}

pub(crate) const EXPECTED_ERROR_PREFIX: &str = "@langhuan_expected:";

/// Try to extract an expected error from an `mlua::Error`.
///
/// Walks through `CallbackError` wrappers to find a `RuntimeError` whose
/// message starts with `@langhuan_expected:<code>:<message>`.
pub fn extract_expected_error(e: &mlua::Error) -> Option<(ExpectedErrorCode, String)> {
    match e {
        mlua::Error::RuntimeError(msg) => parse_expected_message(msg),
        mlua::Error::CallbackError { cause, .. } => extract_expected_error(cause),
        _ => None,
    }
}

fn parse_expected_message(msg: &str) -> Option<(ExpectedErrorCode, String)> {
    let rest = msg.strip_prefix(EXPECTED_ERROR_PREFIX)?;
    let (code_str, message) = rest.split_once(':')?;
    Some((ExpectedErrorCode::from_code(code_str), message.to_owned()))
}

// ---------------------------------------------------------------------------
// Sub-error: ScriptError — feed script loading / validation
// ---------------------------------------------------------------------------

/// Errors related to feed script loading, parsing, and runtime validation.
#[derive(Debug, thiserror::Error)]
pub enum ScriptError {
    /// An error originating from the Lua runtime.
    #[error("lua error: {0}")]
    Lua(#[from] mlua::Error),

    /// The feed script is missing a required function.
    #[error("missing required function: {name}")]
    MissingFunction { name: String },

    /// The feed script metadata is invalid or incomplete.
    #[error("invalid feed metadata: {message}")]
    InvalidFeed { message: String },

    /// An error occurred while parsing the feed script header.
    #[error("script parse error at line {line}: {message}")]
    Parse { line: usize, message: String },

    /// An HTTP request was blocked because the target domain is not in the
    /// feed's `access_domains` list.
    #[error("domain not allowed: {url} (access_domains: {access_domains:?})")]
    DomainNotAllowed {
        url: String,
        access_domains: HashSet<String>,
    },

    /// The feed script declares a schema version newer than this application
    /// supports.
    #[error(
        "feed {feed_id}: schema version {file_version} is newer than supported version {supported_version}"
    )]
    SchemaTooNew {
        feed_id: String,
        file_version: u32,
        supported_version: u32,
    },

    /// The feed script does not implement a `status` handler but
    /// `auth_status` was called.
    #[error("feed {feed_id}: auth status check is not supported by this feed")]
    AuthStatusNotSupported { feed_id: String },

    /// A Lua feed script returned duplicate IDs in a single stream.
    #[error("feed {feed_id}: duplicate {kind} id: {id}")]
    DuplicateId {
        feed_id: String,
        kind: String,
        id: String,
    },

    /// An expected/anticipated error raised by the script via `@langhuan/error`.
    #[error("expected script error [{code:?}]: {message}")]
    Expected {
        code: ExpectedErrorCode,
        message: String,
    },
}

// ---------------------------------------------------------------------------
// Sub-error: RegistryError — registry management
// ---------------------------------------------------------------------------

/// Errors related to the script registry (`registry.json`).
#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    /// The `registry.json` file could not be found or read.
    #[error("registry not found: {0}")]
    NotFound(std::io::Error),

    /// The `registry.json` file could not be parsed.
    #[error("registry parse error: {message}")]
    Parse { message: String },

    /// A write to the registry directory or script file failed.
    #[error("registry write error: {0}")]
    Write(String),

    /// The requested feed ID was not found in the registry.
    #[error("feed not found: {id}")]
    FeedNotFound { id: String },

    /// The registry contains duplicate feed IDs.
    #[error("duplicate feed id in registry: {id}")]
    DuplicateFeedId { id: String },

    /// The `registry.json` schema version is newer than this application
    /// supports.
    #[error(
        "registry schema version {file_version} is newer than supported version {supported_version}"
    )]
    SchemaTooNew {
        file_version: u32,
        supported_version: u32,
    },
}

// ---------------------------------------------------------------------------
// Sub-error: PersistenceError — local storage / serialization / cache
// ---------------------------------------------------------------------------

/// Errors related to local file persistence (bookshelf, progress, cache).
#[derive(Debug, thiserror::Error)]
pub enum PersistenceError {
    /// A local storage I/O operation failed.
    #[error("storage error in {kind:?} during {operation:?}: {message}")]
    Storage {
        kind: StorageKind,
        operation: StorageOperation,
        message: String,
    },

    /// Serializing or deserializing a JSON-backed data file failed.
    #[error("format error in {kind:?} during {operation:?}: {message}")]
    Format {
        kind: FormatKind,
        operation: FormatOperation,
        message: String,
    },

    /// The chapter cache file schema version does not match the current code.
    #[error("chapter cache schema mismatch: {details}")]
    CacheSchemaMismatch {
        details: Box<CacheSchemaMismatchError>,
    },

    /// The content of a chapter cache file does not match the expected key.
    #[error("chapter cache key mismatch: {details}")]
    CacheKeyMismatch { details: Box<CacheKeyMismatchError> },
}

// ---------------------------------------------------------------------------
// Top-level Error
// ---------------------------------------------------------------------------

/// Errors that can occur in the langhuan feed engine.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Feed script loading, parsing, or runtime error.
    #[error(transparent)]
    Script(#[from] ScriptError),

    /// Registry management error.
    #[error(transparent)]
    Registry(#[from] RegistryError),

    /// Local persistence (storage / format / cache) error.
    #[error(transparent)]
    Persistence(#[from] PersistenceError),

    /// An error originating from an HTTP request.
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
}

impl Error {
    /// Returns `true` if this error is transient and the operation may be
    /// retried (e.g. network timeouts, connection resets, 5xx responses).
    ///
    /// Returns `false` for permanent failures such as Lua parse errors,
    /// invalid feed metadata, or 4xx HTTP responses.
    pub fn is_retryable(&self) -> bool {
        match self {
            Error::Http(e) => {
                if e.is_connect() || e.is_timeout() || e.is_request() {
                    return true;
                }
                if let Some(status) = e.status() {
                    return status.is_server_error();
                }
                false
            }
            Error::Script(ScriptError::Expected { code, .. }) => matches!(
                code,
                ExpectedErrorCode::RateLimited | ExpectedErrorCode::SourceUnavailable
            ),
            Error::Script(_) | Error::Registry(_) | Error::Persistence(_) => false,
        }
    }
}

/// A specialized `Result` type for langhuan operations.
pub type Result<T> = std::result::Result<T, Error>;

// Transitive From: mlua::Error → Error::Script
// Inspects the error for the `@langhuan_expected:` convention before falling
// back to `ScriptError::Lua`.
impl From<mlua::Error> for Error {
    fn from(e: mlua::Error) -> Self {
        if let Some((code, message)) = extract_expected_error(&e) {
            return Error::Script(ScriptError::Expected { code, message });
        }
        Error::Script(ScriptError::Lua(e))
    }
}

// ---------------------------------------------------------------------------
// Convenience constructors — keep call-site churn minimal
// ---------------------------------------------------------------------------

/// Shorthand constructors so that existing code can write e.g.
/// `Error::invalid_feed("message")` instead of
/// `Error::Script(ScriptError::InvalidFeed { message: … })`.
impl Error {
    #[inline]
    pub fn lua(e: mlua::Error) -> Self {
        ScriptError::Lua(e).into()
    }

    #[inline]
    pub fn invalid_feed(message: impl Into<String>) -> Self {
        ScriptError::InvalidFeed {
            message: message.into(),
        }
        .into()
    }

    #[inline]
    pub fn script_parse(line: usize, message: impl Into<String>) -> Self {
        ScriptError::Parse {
            line,
            message: message.into(),
        }
        .into()
    }

    #[inline]
    pub fn domain_not_allowed(url: impl Into<String>, access_domains: HashSet<String>) -> Self {
        ScriptError::DomainNotAllowed {
            url: url.into(),
            access_domains,
        }
        .into()
    }

    #[inline]
    pub fn feed_schema_too_new(
        feed_id: impl Into<String>,
        file_version: u32,
        supported_version: u32,
    ) -> Self {
        ScriptError::SchemaTooNew {
            feed_id: feed_id.into(),
            file_version,
            supported_version,
        }
        .into()
    }

    #[inline]
    pub fn registry_not_found(e: std::io::Error) -> Self {
        RegistryError::NotFound(e).into()
    }

    #[inline]
    pub fn registry_parse(message: impl Into<String>) -> Self {
        RegistryError::Parse {
            message: message.into(),
        }
        .into()
    }

    #[inline]
    pub fn registry_write(message: impl Into<String>) -> Self {
        RegistryError::Write(message.into()).into()
    }

    #[inline]
    pub fn feed_not_found(id: impl Into<String>) -> Self {
        RegistryError::FeedNotFound { id: id.into() }.into()
    }

    #[inline]
    pub fn duplicate_feed_id(id: impl Into<String>) -> Self {
        RegistryError::DuplicateFeedId { id: id.into() }.into()
    }

    #[inline]
    pub fn registry_schema_too_new(file_version: u32, supported_version: u32) -> Self {
        RegistryError::SchemaTooNew {
            file_version,
            supported_version,
        }
        .into()
    }

    #[inline]
    pub fn storage(
        kind: StorageKind,
        operation: StorageOperation,
        message: impl Into<String>,
    ) -> Self {
        PersistenceError::Storage {
            kind,
            operation,
            message: message.into(),
        }
        .into()
    }

    #[inline]
    pub fn format(
        kind: FormatKind,
        operation: FormatOperation,
        message: impl Into<String>,
    ) -> Self {
        PersistenceError::Format {
            kind,
            operation,
            message: message.into(),
        }
        .into()
    }

    #[inline]
    pub fn cache_schema_mismatch(details: CacheSchemaMismatchError) -> Self {
        PersistenceError::CacheSchemaMismatch {
            details: Box::new(details),
        }
        .into()
    }

    #[inline]
    pub fn cache_key_mismatch(details: CacheKeyMismatchError) -> Self {
        PersistenceError::CacheKeyMismatch {
            details: Box::new(details),
        }
        .into()
    }

    #[inline]
    pub fn auth_status_not_supported(feed_id: impl Into<String>) -> Self {
        ScriptError::AuthStatusNotSupported {
            feed_id: feed_id.into(),
        }
        .into()
    }

    #[inline]
    pub fn duplicate_id(
        feed_id: impl Into<String>,
        kind: impl Into<String>,
        id: impl Into<String>,
    ) -> Self {
        ScriptError::DuplicateId {
            feed_id: feed_id.into(),
            kind: kind.into(),
            id: id.into(),
        }
        .into()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lua_error_not_retryable() {
        let err = Error::lua(mlua::Error::RuntimeError("test".into()));
        assert!(!err.is_retryable());
    }

    #[test]
    fn missing_function_not_retryable() {
        let err: Error = ScriptError::MissingFunction {
            name: "search".into(),
        }
        .into();
        assert!(!err.is_retryable());
    }

    #[test]
    fn invalid_feed_not_retryable() {
        let err = Error::invalid_feed("bad metadata");
        assert!(!err.is_retryable());
    }

    #[test]
    fn script_parse_not_retryable() {
        let err = Error::script_parse(1, "unexpected token");
        assert!(!err.is_retryable());
    }

    /// A real TCP connect to an unroutable address yields a connection error,
    /// which should be considered retryable.
    #[tokio::test]
    async fn connect_error_is_retryable() {
        let result = reqwest::Client::new()
            .get("http://127.0.0.1:0/")
            .send()
            .await;
        let e = result.expect_err("expected connect failure");
        let err = Error::Http(e);
        assert!(err.is_retryable(), "connect errors must be retryable");
    }

    #[test]
    fn extract_expected_error_parses_runtime_error() {
        let lua_err =
            mlua::Error::RuntimeError("@langhuan_expected:auth_required:please login".into());
        let result = extract_expected_error(&lua_err);
        assert_eq!(
            result,
            Some((ExpectedErrorCode::AuthRequired, "please login".into()))
        );
    }

    #[test]
    fn extract_expected_error_returns_none_for_plain_runtime() {
        let lua_err = mlua::Error::RuntimeError("some random error".into());
        assert!(extract_expected_error(&lua_err).is_none());
    }

    #[test]
    fn extract_expected_error_unwraps_callback_error() {
        let inner = mlua::Error::RuntimeError(
            "@langhuan_expected:cf_challenge:cloudflare blocked".into(),
        );
        let lua_err = mlua::Error::CallbackError {
            traceback: String::new(),
            cause: inner.into(),
        };
        let result = extract_expected_error(&lua_err);
        assert_eq!(
            result,
            Some((ExpectedErrorCode::CfChallenge, "cloudflare blocked".into()))
        );
    }

    #[test]
    fn extract_expected_error_unknown_code() {
        let lua_err =
            mlua::Error::RuntimeError("@langhuan_expected:custom_code:details".into());
        let result = extract_expected_error(&lua_err);
        assert_eq!(
            result,
            Some((ExpectedErrorCode::Unknown("custom_code".into()), "details".into()))
        );
    }

    #[test]
    fn from_mlua_error_routes_expected() {
        let lua_err =
            mlua::Error::RuntimeError("@langhuan_expected:rate_limited:slow down".into());
        let err: Error = lua_err.into();
        assert!(matches!(
            err,
            Error::Script(ScriptError::Expected {
                code: ExpectedErrorCode::RateLimited,
                ..
            })
        ));
    }

    #[test]
    fn from_mlua_error_routes_plain_to_lua() {
        let lua_err = mlua::Error::RuntimeError("ordinary error".into());
        let err: Error = lua_err.into();
        assert!(matches!(err, Error::Script(ScriptError::Lua(_))));
    }

    #[test]
    fn expected_rate_limited_is_retryable() {
        let err: Error = ScriptError::Expected {
            code: ExpectedErrorCode::RateLimited,
            message: "slow down".into(),
        }
        .into();
        assert!(err.is_retryable());
    }

    #[test]
    fn expected_source_unavailable_is_retryable() {
        let err: Error = ScriptError::Expected {
            code: ExpectedErrorCode::SourceUnavailable,
            message: "down".into(),
        }
        .into();
        assert!(err.is_retryable());
    }

    #[test]
    fn expected_auth_required_not_retryable() {
        let err: Error = ScriptError::Expected {
            code: ExpectedErrorCode::AuthRequired,
            message: "login".into(),
        }
        .into();
        assert!(!err.is_retryable());
    }
}
