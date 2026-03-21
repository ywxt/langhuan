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

/// A specialized `Result` type for langhuan operations.
pub type Result<T> = std::result::Result<T, Error>;
