use std::collections::HashSet;

// ---------------------------------------------------------------------------
// Expected error codes (JavaScript → Rust structured errors)
// ---------------------------------------------------------------------------

pub(crate) const ERROR_AUTH_REQUIRED: &str = "auth_required";
pub(crate) const ERROR_CF_CHALLENGE: &str = "cf_challenge";
pub(crate) const ERROR_RATE_LIMITED: &str = "rate_limited";
pub(crate) const ERROR_CONTENT_NOT_FOUND: &str = "content_not_found";
pub(crate) const ERROR_SOURCE_UNAVAILABLE: &str = "source_unavailable";

/// Error codes that scripts can return to signal an anticipated condition.
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
            ERROR_AUTH_REQUIRED => Self::AuthRequired,
            ERROR_CF_CHALLENGE => Self::CfChallenge,
            ERROR_RATE_LIMITED => Self::RateLimited,
            ERROR_CONTENT_NOT_FOUND => Self::ContentNotFound,
            ERROR_SOURCE_UNAVAILABLE => Self::SourceUnavailable,
            other => Self::Unknown(other.to_owned()),
        }
    }
}

// ---------------------------------------------------------------------------
// Sub-error: ScriptError — feed script loading / validation
// ---------------------------------------------------------------------------

/// Errors related to feed script loading, parsing, and runtime validation.
#[derive(Debug, thiserror::Error)]
pub enum ScriptError {
    /// An error originating from the JavaScript runtime.
    #[error("javascript error: {0}")]
    JavaScript(String),

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

    /// A feed script returned duplicate IDs in a single stream.
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
// Sub-error: RegistryError — feed registry management
// ---------------------------------------------------------------------------

/// Errors related to the feed registry (the `feeds` table).
#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    /// The requested feed ID is not registered.
    #[error("feed not found: {id}")]
    FeedNotFound { id: String },
}

// ---------------------------------------------------------------------------
// Sub-error: PersistenceError — local storage
// ---------------------------------------------------------------------------

/// Errors related to the SQLite persistence layer.
#[derive(Debug, thiserror::Error)]
pub enum PersistenceError {
    /// A database operation failed (SQL error, corrupt payload, or the
    /// connection was closed).
    #[error("database error: {message}")]
    Database { message: String },
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

    /// Local persistence (SQLite) error.
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
    /// Returns `false` for permanent failures such as script parse errors,
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

// Transitive From: rusqlite::Error → Error::Persistence
// Every SQL failure surfaces as `PersistenceError::Database`; callers never
// need to import rusqlite types themselves.
impl From<tokio_rusqlite::rusqlite::Error> for Error {
    fn from(e: tokio_rusqlite::rusqlite::Error) -> Self {
        Error::database(e.to_string())
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
    pub fn javascript(message: impl Into<String>) -> Self {
        ScriptError::JavaScript(message.into()).into()
    }

    #[inline]
    pub fn expected(code: ExpectedErrorCode, message: impl Into<String>) -> Self {
        ScriptError::Expected {
            code,
            message: message.into(),
        }
        .into()
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
    pub fn feed_not_found(id: impl Into<String>) -> Self {
        RegistryError::FeedNotFound { id: id.into() }.into()
    }

    #[inline]
    pub fn database(message: impl Into<String>) -> Self {
        PersistenceError::Database {
            message: message.into(),
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
    fn javascript_error_not_retryable() {
        let err = Error::javascript("test");
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
        let result = crate::http::new_client()
            .get("http://127.0.0.1:0/")
            .send()
            .await;
        let e = result.expect_err("expected connect failure");
        let err = Error::Http(e);
        assert!(err.is_retryable(), "connect errors must be retryable");
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

    #[test]
    fn database_error_not_retryable() {
        let err = Error::database("locked");
        assert!(!err.is_retryable());
    }
}
