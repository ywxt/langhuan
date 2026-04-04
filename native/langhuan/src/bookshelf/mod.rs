pub mod local;
pub mod models;
pub mod storage;

pub use local::{LocalBookshelf, LocalBookshelfAddOutcome, LocalBookshelfRemoveOutcome};
pub use models::{BookIdentity, BookshelfCapabilities, BookshelfEntry};
pub use storage::{BookshelfFile, TomlBookshelfStore};
