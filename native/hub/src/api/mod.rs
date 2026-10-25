//! FRB API surface — public async functions that `flutter_rust_bridge_codegen`
//! scans to generate Dart bindings.

pub mod types;

pub mod app_data;
pub mod auth;
pub mod bookmark;
pub mod bookshelf;
pub mod cache;
pub mod conversion;
pub mod feed_stream;
pub mod init;
pub mod locale;
pub mod reading_progress;
pub mod registry;
pub mod transfer;

// Re-export all public API functions so FRB can find them.
pub use app_data::*;
pub use auth::*;
pub use bookmark::*;
pub use bookshelf::*;
pub use cache::*;
pub use conversion::*;
pub use feed_stream::*;
pub use locale::*;
pub use reading_progress::*;
pub use registry::*;
pub use transfer::*;
