use std::collections::HashSet;

/// Errors that can occur in the langhuan feed engine.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// An error originating from the Lua runtime.
    #[error("lua error: {0}")]
    Lua(#[from] mlua::Error),

    /// An error originating from an HTTP request.
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),

    /// The feed script is missing a required function.
    #[error("missing required function: {name}")]
    MissingFunction {
        /// The name of the missing function.
        name: String,
    },

    /// The feed script metadata is invalid or incomplete.
    #[error("invalid feed metadata: {message}")]
    InvalidFeed {
        /// A description of what is wrong with the metadata.
        message: String,
    },

    /// An error occurred while parsing the feed script header.
    #[error("script parse error at line {line}: {message}")]
    ScriptParse {
        /// The line number where the error occurred (1-based).
        line: usize,
        /// A description of the parse error.
        message: String,
    },

    /// The `registry.toml` file could not be found or read.
    #[error("registry not found: {0}")]
    RegistryNotFound(#[from] std::io::Error),

    /// The `registry.toml` file could not be parsed.
    #[error("registry parse error: {message}")]
    RegistryParse {
        /// A description of the parse error.
        message: String,
    },

    /// The requested feed ID was not found in the registry.
    #[error("feed not found: {id}")]
    FeedNotFound {
        /// The feed ID that was not found.
        id: String,
    },

    /// The registry contains duplicate feed IDs.
    #[error("duplicate feed id in registry: {id}")]
    DuplicateFeedId {
        /// The duplicated feed ID.
        id: String,
    },

    /// An HTTP request was blocked because the target domain is not in the
    /// feed's `allowed_domains` list.
    #[error("domain not allowed: {url} (allowed: {allowed:?})")]
    DomainNotAllowed {
        /// The blocked URL.
        url: String,
        /// The list of allowed domain patterns from the feed metadata.
        allowed: HashSet<String>,
    },

    /// A write to the registry directory or script file failed.
    #[error("registry write error: {0}")]
    RegistryWrite(String),

    /// A read/write operation for local bookshelf storage failed.
    #[error("bookshelf storage error: {0}")]
    BookshelfStorage(String),

    /// The local bookshelf TOML file could not be parsed.
    #[error("bookshelf parse error: {message}")]
    BookshelfParse {
        /// A description of the parse error.
        message: String,
    },
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
                // Retry on connection errors, timeouts, and 5xx status codes.
                if e.is_connect() || e.is_timeout() || e.is_request() {
                    return true;
                }
                if let Some(status) = e.status() {
                    return status.is_server_error();
                }
                false
            }
            // Lua errors, parse errors, metadata errors, and registry errors are permanent.
            Error::Lua(_)
            | Error::MissingFunction { .. }
            | Error::InvalidFeed { .. }
            | Error::ScriptParse { .. }
            | Error::RegistryNotFound(_)
            | Error::RegistryParse { .. }
            | Error::FeedNotFound { .. }
            | Error::DuplicateFeedId { .. }
            | Error::DomainNotAllowed { .. }
            | Error::RegistryWrite(_)
            | Error::BookshelfStorage(_)
            | Error::BookshelfParse { .. } => false,
        }
    }
}

/// A specialized `Result` type for langhuan operations.
pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lua_error_not_retryable() {
        let err = Error::Lua(mlua::Error::RuntimeError("test".into()));
        assert!(!err.is_retryable());
    }

    #[test]
    fn missing_function_not_retryable() {
        let err = Error::MissingFunction {
            name: "search".into(),
        };
        assert!(!err.is_retryable());
    }

    #[test]
    fn invalid_feed_not_retryable() {
        let err = Error::InvalidFeed {
            message: "bad metadata".into(),
        };
        assert!(!err.is_retryable());
    }

    #[test]
    fn script_parse_not_retryable() {
        let err = Error::ScriptParse {
            line: 1,
            message: "unexpected token".into(),
        };
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
}
