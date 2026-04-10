use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::bookshelf::models::BookshelfEntry;
use crate::error::{Error, FormatKind, FormatOperation, Result, StorageKind, StorageOperation};
use crate::util::fs::write_atomic;

pub const BOOKSHELF_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookshelfFile {
    pub schema_version: u32,
    pub entries: Vec<BookshelfEntry>,
}

impl Default for BookshelfFile {
    fn default() -> Self {
        Self {
            schema_version: BOOKSHELF_SCHEMA_VERSION,
            entries: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct JsonBookshelfStore {
    path: PathBuf,
}

impl JsonBookshelfStore {
    #[must_use]
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn load(&self) -> Result<BookshelfFile> {
        tracing::debug!(path = %self.path.display(), "loading bookshelf file");
        if !self.path.exists() {
            tracing::info!(path = %self.path.display(), "bookshelf file missing, using default");
            return Ok(BookshelfFile::default());
        }

        let content = tokio::fs::read_to_string(&self.path).await.map_err(|e| {
            Error::storage(
                StorageKind::Bookshelf,
                StorageOperation::Read,
                e.to_string(),
            )
        })?;

        let parsed = serde_json::from_str(&content).map_err(|e| {
            Error::format(
                FormatKind::Bookshelf,
                FormatOperation::Deserialize,
                e.to_string(),
            )
        })?;
        tracing::debug!(path = %self.path.display(), "bookshelf file loaded");
        Ok(parsed)
    }

    pub async fn save(&self, file: &BookshelfFile) -> Result<()> {
        tracing::debug!(
            path = %self.path.display(),
            entries = file.entries.len(),
            "saving bookshelf file"
        );
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::storage(
                    StorageKind::Bookshelf,
                    StorageOperation::CreateDir,
                    e.to_string(),
                )
            })?;
        }

        let content = serde_json::to_string_pretty(file).map_err(|e| {
            Error::format(
                FormatKind::Bookshelf,
                FormatOperation::Serialize,
                e.to_string(),
            )
        })?;
        write_atomic(&self.path, &content).await.map_err(|e| {
            Error::storage(
                StorageKind::Bookshelf,
                StorageOperation::Write,
                e.to_string(),
            )
        })?;
        tracing::debug!(path = %self.path.display(), "bookshelf file saved");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bookshelf::models::BookIdentity;
    use crate::error::{Error, PersistenceError};

    #[tokio::test]
    async fn load_missing_file_returns_default() {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = JsonBookshelfStore::new(dir.path().join("bookshelf.json"));

        let file = store.load().await.expect("load default");
        assert!(file.entries.is_empty());
    }

    #[tokio::test]
    async fn load_malformed_json_returns_parse_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("bookshelf.json");
        tokio::fs::write(&path, "not valid json")
            .await
            .expect("write malformed");

        let store = JsonBookshelfStore::new(path);
        let err = store.load().await.expect_err("expected parse error");
        assert!(matches!(
            err,
            Error::Persistence(PersistenceError::Format {
                kind: FormatKind::Bookshelf,
                operation: FormatOperation::Deserialize,
                ..
            })
        ));
    }

    #[tokio::test]
    async fn save_then_load_roundtrip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("bookshelf.json");
        let store = JsonBookshelfStore::new(&path);

        let mut file = BookshelfFile::default();
        file.entries.push(BookshelfEntry {
            identity: BookIdentity {
                feed_id: "feed-a".to_owned(),
                source_book_id: "123".to_owned(),
            },
            added_at_unix_ms: 1,
        });

        store.save(&file).await.expect("save");
        let loaded = store.load().await.expect("load");
        assert_eq!(loaded.entries.len(), 1);
        assert_eq!(loaded.entries[0].identity.feed_id, "feed-a");
        assert_eq!(loaded.entries[0].identity.source_book_id, "123");
    }
}
