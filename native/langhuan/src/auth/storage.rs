use std::collections::HashMap;
use std::path::PathBuf;

use crate::auth::models::{AUTH_SCHEMA_VERSION, AuthFile};
use crate::error::{Error, FormatKind, FormatOperation, Result, StorageKind, StorageOperation};
use crate::util::fs::write_atomic;
use crate::util::path_key::encode_path_component;

#[derive(Debug)]
pub struct AuthStore {
    auth_dir: PathBuf,
    auth_info_by_feed: HashMap<String, serde_json::Value>,
}

impl AuthStore {
    pub async fn open(auth_dir: impl Into<PathBuf>) -> Result<Self> {
        let auth_dir = auth_dir.into();
        let mut auth_info_by_feed: HashMap<String, serde_json::Value> = HashMap::new();

        if auth_dir.exists() {
            let mut entries = tokio::fs::read_dir(&auth_dir).await.map_err(|e| {
                Error::storage(StorageKind::Auth, StorageOperation::Read, e.to_string())
            })?;

            while let Some(entry) = entries.next_entry().await.map_err(|e| {
                Error::storage(StorageKind::Auth, StorageOperation::Read, e.to_string())
            })? {
                let file_type = entry.file_type().await.map_err(|e| {
                    Error::storage(StorageKind::Auth, StorageOperation::Read, e.to_string())
                })?;
                if !file_type.is_dir() {
                    continue;
                }

                let path = entry.path().join("auth.json");
                if !path.exists() {
                    continue;
                }

                let content = tokio::fs::read_to_string(&path).await.map_err(|e| {
                    Error::storage(StorageKind::Auth, StorageOperation::Read, e.to_string())
                })?;
                let parsed: AuthFile = serde_json::from_str(&content).map_err(|e| {
                    Error::format(
                        FormatKind::Auth,
                        FormatOperation::Deserialize,
                        e.to_string(),
                    )
                })?;

                if parsed.schema_version != AUTH_SCHEMA_VERSION {
                    return Err(Error::format(
                        FormatKind::Auth,
                        FormatOperation::Deserialize,
                        format!(
                            "auth schema mismatch: file={}, expected={}",
                            parsed.schema_version, AUTH_SCHEMA_VERSION
                        ),
                    ));
                }

                auth_info_by_feed.insert(parsed.feed_id, parsed.auth_info);
            }
        }

        Ok(Self {
            auth_dir,
            auth_info_by_feed,
        })
    }

    fn auth_file_path(&self, feed_id: &str) -> PathBuf {
        self.auth_dir
            .join(encode_path_component(feed_id))
            .join("auth.json")
    }

    pub async fn get_auth_info(&self, feed_id: &str) -> Result<Option<serde_json::Value>> {
        Ok(self.auth_info_by_feed.get(feed_id).cloned())
    }

    pub async fn set_auth_info(
        &mut self,
        feed_id: &str,
        auth_info: serde_json::Value,
    ) -> Result<()> {
        self.auth_info_by_feed
            .insert(feed_id.to_owned(), auth_info.clone());

        let path = self.auth_file_path(feed_id);
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::storage(
                    StorageKind::Auth,
                    StorageOperation::CreateDir,
                    e.to_string(),
                )
            })?;
        }

        let content = serde_json::to_string_pretty(&AuthFile::new(feed_id.to_owned(), auth_info))
            .map_err(|e| {
            Error::format(FormatKind::Auth, FormatOperation::Serialize, e.to_string())
        })?;

        write_atomic(&path, &content).await.map_err(|e| {
            Error::storage(StorageKind::Auth, StorageOperation::Write, e.to_string())
        })?;

        Ok(())
    }

    pub async fn clear_auth_info(&mut self, feed_id: &str) -> Result<()> {
        self.auth_info_by_feed.remove(feed_id);

        let path = self.auth_file_path(feed_id);
        if path.exists() {
            tokio::fs::remove_file(&path).await.map_err(|e| {
                Error::storage(
                    StorageKind::Auth,
                    StorageOperation::RemoveFile,
                    e.to_string(),
                )
            })?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn get_missing_returns_none() {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = AuthStore::open(dir.path().join("auth"))
            .await
            .expect("open auth store");

        let result = store
            .get_auth_info("feed-a")
            .await
            .expect("get auth info should succeed");
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn set_then_get_roundtrip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut store = AuthStore::open(dir.path().join("auth"))
            .await
            .expect("open auth store");

        let payload = serde_json::json!({"token": "abc", "uid": 42});
        store
            .set_auth_info("feed-a", payload.clone())
            .await
            .expect("set auth info");

        let loaded = store
            .get_auth_info("feed-a")
            .await
            .expect("get auth info")
            .expect("auth should exist");

        assert_eq!(loaded, payload);
    }

    #[tokio::test]
    async fn clear_removes_saved_auth() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut store = AuthStore::open(dir.path().join("auth"))
            .await
            .expect("open auth store");

        store
            .set_auth_info("feed-a", serde_json::json!({"token": "abc"}))
            .await
            .expect("set auth info");

        store
            .clear_auth_info("feed-a")
            .await
            .expect("clear auth info");

        let loaded = store
            .get_auth_info("feed-a")
            .await
            .expect("get after clear");
        assert!(loaded.is_none());
    }
}
