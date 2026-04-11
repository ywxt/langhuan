//! FRB API surface — public async functions that `flutter_rust_bridge_codegen`
//! scans to generate Dart bindings.

pub mod types;

pub mod app_data;
pub mod auth;
pub mod bookshelf;
pub mod feed_stream;
pub mod init;
pub mod locale;
pub mod reading_progress;
pub mod registry;

// Re-export all public API functions so FRB can find them.
pub use app_data::*;
pub use auth::*;
pub use bookshelf::*;
pub use feed_stream::*;
pub use locale::*;
pub use reading_progress::*;
pub use registry::*;
