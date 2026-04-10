use std::path::PathBuf;

use crate::error::{Error, FormatKind, FormatOperation, Result, StorageKind, StorageOperation};
use crate::util::fs::write_atomic;

use super::models::{ReadingProgress, ReadingProgressFile};

#[derive(Debug)]
pub struct ReadingProgressStore {
    base_dir: PathBuf,
    file: ReadingProgressFile,
}

impl ReadingProgressStore {
    pub async fn open(base_dir: impl Into<PathBuf>) -> Result<Self> {
        let base_dir = base_dir.into();
        let path = base_dir.join("progress.json");

        let file = if !path.exists() {
            ReadingProgressFile::default()
        } else {
            let content = tokio::fs::read_to_string(&path).await.map_err(|e| {
                Error::storage(
                    StorageKind::ReadingProgress,
                    StorageOperation::Read,
                    e.to_string(),
                )
            })?;

            serde_json::from_str::<ReadingProgressFile>(&content).map_err(|e| {
                Error::format(
                    FormatKind::ReadingProgress,
                    FormatOperation::Deserialize,
                    e.to_string(),
                )
            })?
        };

        Ok(Self { base_dir, file })
    }

    fn progress_path(&self) -> PathBuf {
        self.base_dir.join("progress.json")
    }

    async fn save_progress_file(&self, file: &ReadingProgressFile) -> Result<()> {
        let path = self.progress_path();
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::storage(
                    StorageKind::ReadingProgress,
                    StorageOperation::CreateDir,
                    e.to_string(),
                )
            })?;
        }

        let content = serde_json::to_string_pretty(file).map_err(|e| {
            Error::format(
                FormatKind::ReadingProgress,
                FormatOperation::Serialize,
                e.to_string(),
            )
        })?;

        write_atomic(&path, &content).await.map_err(|e| {
            Error::storage(
                StorageKind::ReadingProgress,
                StorageOperation::Write,
                e.to_string(),
            )
        })?;

        Ok(())
    }

    pub async fn get_reading_progress(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Option<ReadingProgress>> {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "loading reading progress");
        let result = self
            .file
            .entries
            .iter()
            .find(|&entry| entry.feed_id == feed_id && entry.book_id == book_id)
            .cloned();
        match &result {
            Some(p) => tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                chapter_id = %p.chapter_id,
                paragraph_index = p.paragraph_index,
                "reading progress found"
            ),
            None => {
                tracing::debug!(feed_id = %feed_id, book_id = %book_id, "no saved reading progress")
            }
        }
        Ok(result)
    }

    pub async fn set_reading_progress(&mut self, progress: ReadingProgress) -> Result<()> {
        tracing::debug!(
            feed_id = %progress.feed_id,
            book_id = %progress.book_id,
            chapter_id = %progress.chapter_id,
            paragraph_index = progress.paragraph_index,
            "saving reading progress"
        );
        if let Some(existing) =
            self.file.entries.iter_mut().find(|entry| {
                entry.feed_id == progress.feed_id && entry.book_id == progress.book_id
            })
        {
            *existing = progress;
        } else {
            self.file.entries.push(progress);
        }

        let snapshot = self.file.clone();

        self.save_progress_file(&snapshot).await?;
        tracing::debug!("reading progress saved");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    #[tokio::test]
    async fn test_set_and_get_reading_progress() {
        let temp_dir = TempDir::new().unwrap();
        let mut store = ReadingProgressStore::open(temp_dir.path())
            .await
            .expect("open reading progress store");

        let progress = ReadingProgress {
            feed_id: "feed-a".to_string(),
            book_id: "book-1".to_string(),
            chapter_id: "chapter-10".to_string(),
            paragraph_index: 12,
            updated_at_ms: 1_712_345_678_000,
        };

        store.set_reading_progress(progress.clone()).await.unwrap();

        let loaded = store
            .get_reading_progress("feed-a", "book-1")
            .await
            .unwrap()
            .expect("expected stored progress");

        assert_eq!(loaded.chapter_id, "chapter-10");
        assert_eq!(loaded.paragraph_index, 12);
    }
}
