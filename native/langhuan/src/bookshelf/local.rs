use std::path::Path;

use crate::bookshelf::models::{BookIdentity, BookshelfEntry};
use crate::bookshelf::storage::{BookshelfFile, TomlBookshelfStore};
use crate::error::Result;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalBookshelfAddOutcome {
    Added,
    AlreadyExists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalBookshelfRemoveOutcome {
    Removed,
    NotFound,
}

pub struct LocalBookshelf {
    store: TomlBookshelfStore,
    file: BookshelfFile,
}

impl LocalBookshelf {
    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        tracing::info!(path = %path.as_ref().display(), "opening local bookshelf");
        let store = TomlBookshelfStore::new(path.as_ref());
        let file = store.load().await?;
        tracing::info!(
            path = %store.path().display(),
            entries = file.entries.len(),
            "local bookshelf ready"
        );
        Ok(Self { store, file })
    }

    #[must_use]
    pub fn entries(&self) -> &[BookshelfEntry] {
        &self.file.entries
    }

    #[must_use]
    pub fn contains(&self, identity: &BookIdentity) -> bool {
        self.file.entries.iter().any(|entry| &entry.identity == identity)
    }

    pub async fn add(&mut self, entry: BookshelfEntry) -> Result<LocalBookshelfAddOutcome> {
        tracing::debug!(
            feed_id = %entry.identity.feed_id,
            source_book_id = %entry.identity.source_book_id,
            "adding book to local bookshelf"
        );
        if self.contains(&entry.identity) {
            tracing::debug!(
                feed_id = %entry.identity.feed_id,
                source_book_id = %entry.identity.source_book_id,
                "book already exists in local bookshelf"
            );
            return Ok(LocalBookshelfAddOutcome::AlreadyExists);
        }

        self.file.entries.push(entry);
        self.persist().await?;
        tracing::debug!(entries = self.file.entries.len(), "book added to local bookshelf");
        Ok(LocalBookshelfAddOutcome::Added)
    }

    pub async fn remove(&mut self, identity: &BookIdentity) -> Result<LocalBookshelfRemoveOutcome> {
        tracing::debug!(
            feed_id = %identity.feed_id,
            source_book_id = %identity.source_book_id,
            "removing book from local bookshelf"
        );
        let before = self.file.entries.len();
        self.file.entries.retain(|entry| &entry.identity != identity);

        if self.file.entries.len() == before {
            tracing::debug!(
                feed_id = %identity.feed_id,
                source_book_id = %identity.source_book_id,
                "book not found in local bookshelf"
            );
            return Ok(LocalBookshelfRemoveOutcome::NotFound);
        }

        self.persist().await?;
        tracing::debug!(entries = self.file.entries.len(), "book removed from local bookshelf");
        Ok(LocalBookshelfRemoveOutcome::Removed)
    }

    async fn persist(&mut self) -> Result<()> {
        self.file
            .entries
            .sort_by_key(|entry| std::cmp::Reverse(entry.added_at_unix_ms));
        tracing::debug!(entries = self.file.entries.len(), "persisting local bookshelf");
        self.store.save(&self.file).await
    }
}

#[cfg(test)]
mod tests {
    use crate::bookshelf::models::BookIdentity;

    use super::*;

    fn make_entry(feed_id: &str, source_book_id: &str, at: i64) -> BookshelfEntry {
        BookshelfEntry {
            identity: BookIdentity {
                feed_id: feed_id.to_owned(),
                source_book_id: source_book_id.to_owned(),
            },
            title: format!("Book {source_book_id}"),
            author: "Author".to_owned(),
            cover_url: None,
            description_snapshot: None,
            source_name_snapshot: Some("source".to_owned()),
            added_at_unix_ms: at,
        }
    }

    #[tokio::test]
    async fn add_remove_and_persist_toml() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("bookshelf.toml");

        let mut shelf = LocalBookshelf::open(&path).await.expect("open shelf");

        let a = make_entry("feed-a", "100", 100);
        let b = make_entry("feed-b", "100", 200);

        assert_eq!(
            shelf.add(a.clone()).await.expect("add a"),
            LocalBookshelfAddOutcome::Added
        );
        assert_eq!(
            shelf.add(a.clone()).await.expect("re-add a"),
            LocalBookshelfAddOutcome::AlreadyExists
        );
        assert_eq!(
            shelf.add(b.clone()).await.expect("add b"),
            LocalBookshelfAddOutcome::Added
        );

        let mut reloaded = LocalBookshelf::open(&path).await.expect("reload shelf");
        assert_eq!(reloaded.entries().len(), 2);
        assert!(reloaded.contains(&a.identity));
        assert!(reloaded.contains(&b.identity));
        assert_eq!(reloaded.entries()[0].identity.feed_id, "feed-b");

        assert_eq!(
            reloaded.remove(&a.identity).await.expect("remove a"),
            LocalBookshelfRemoveOutcome::Removed
        );
        assert_eq!(
            reloaded.remove(&a.identity).await.expect("remove missing a"),
            LocalBookshelfRemoveOutcome::NotFound
        );

        let final_reloaded = LocalBookshelf::open(&path).await.expect("final reload");
        assert_eq!(final_reloaded.entries().len(), 1);
        assert!(final_reloaded.contains(&b.identity));
    }
}
