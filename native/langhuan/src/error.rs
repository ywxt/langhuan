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
            // Lua errors, parse errors, and metadata errors are permanent.
            Error::Lua(_)
            | Error::MissingFunction { .. }
            | Error::InvalidFeed { .. }
            | Error::ScriptParse { .. } => false,
        }
    }
}

/// A specialized `Result` type for langhuan operations.
pub type Result<T> = std::result::Result<T, Error>;
