use std::path::PathBuf;

use crate::error::{
    Error, FormatKind, FormatOperation, Result, StorageKind, StorageOperation,
};
use crate::util::fs::write_atomic;

use super::models::{ReadingProgress, ReadingProgressFile};

#[derive(Debug, Clone)]
pub struct ReadingProgressStore {
    base_dir: PathBuf,
}

impl ReadingProgressStore {
    pub fn new(base_dir: impl Into<PathBuf>) -> Self {
        Self {
            base_dir: base_dir.into(),
        }
    }

    fn progress_path(&self) -> PathBuf {
        self.base_dir.join("progress.toml")
    }

    async fn load_progress_file(&self) -> Result<ReadingProgressFile> {
        let path = self.progress_path();
        if !path.exists() {
            return Ok(ReadingProgressFile::default());
        }

        let content = tokio::fs::read_to_string(&path)
            .await
            .map_err(|e| Error::Storage {
                kind: StorageKind::ReadingProgress,
                operation: StorageOperation::Read,
                message: e.to_string(),
            })?;

        toml::from_str::<ReadingProgressFile>(&content).map_err(|e| Error::Format {
            kind: FormatKind::ReadingProgress,
            operation: FormatOperation::Deserialize,
            message: e.to_string(),
        })
    }

    async fn save_progress_file(&self, file: &ReadingProgressFile) -> Result<()> {
        let path = self.progress_path();
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| Error::Storage {
                    kind: StorageKind::ReadingProgress,
                    operation: StorageOperation::CreateDir,
                    message: e.to_string(),
                })?;
        }

        let content = toml::to_string(file).map_err(|e| Error::Format {
            kind: FormatKind::ReadingProgress,
            operation: FormatOperation::Serialize,
            message: e.to_string(),
        })?;

        write_atomic(&path, &content)
            .await
            .map_err(|e| Error::Storage {
                kind: StorageKind::ReadingProgress,
                operation: StorageOperation::Write,
                message: e.to_string(),
            })?;

        Ok(())
    }

    pub async fn get_reading_progress(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Option<ReadingProgress>> {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "loading reading progress");
        let file = self.load_progress_file().await?;
        let result = file
            .entries
            .into_iter()
            .find(|entry| entry.feed_id == feed_id && entry.book_id == book_id);
        match &result {
            Some(p) => tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                chapter_id = %p.chapter_id,
                paragraph_index = p.paragraph_index,
                scroll_offset = p.scroll_offset,
                "reading progress found"
            ),
            None => tracing::debug!(feed_id = %feed_id, book_id = %book_id, "no saved reading progress"),
        }
        Ok(result)
    }

    pub async fn set_reading_progress(&self, progress: ReadingProgress) -> Result<()> {
        tracing::debug!(
            feed_id = %progress.feed_id,
            book_id = %progress.book_id,
            chapter_id = %progress.chapter_id,
            paragraph_index = progress.paragraph_index,
            scroll_offset = progress.scroll_offset,
            "saving reading progress"
        );
        let mut file = self.load_progress_file().await?;
        if let Some(existing) = file
            .entries
            .iter_mut()
            .find(|entry| entry.feed_id == progress.feed_id && entry.book_id == progress.book_id)
        {
            *existing = progress;
        } else {
            file.entries.push(progress);
        }

        self.save_progress_file(&file).await?;
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
        let store = ReadingProgressStore::new(temp_dir.path());

        let progress = ReadingProgress {
            feed_id: "feed-a".to_string(),
            book_id: "book-1".to_string(),
            chapter_id: "chapter-10".to_string(),
            paragraph_index: 12,
            scroll_offset: 328.5,
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
