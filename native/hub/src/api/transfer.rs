//! Data transfer: feed (source) export/import and full backups.
//!
//! Feeds are exported as a self-contained JSON document (scripts included);
//! importing re-installs each script through the registry, so imported feeds
//! get the same compile-check-and-persist treatment as manual installs.
//! Backups are standalone `VACUUM INTO` snapshots of the whole database.

use serde::{Deserialize, Serialize};

use super::types::{BridgeError, FeedImportEntry, FeedImportOutcome};
use crate::actors::addresses;
use crate::actors::hub_db;
use crate::actors::registry_actor::{ImportFeedScript, ImportFeeds, classify_version_change};
use langhuan::db::Db;

/// Marker of the feed-export format.
const EXPORT_FORMAT: &str = "langhuan-feeds";
/// Version of the feed-export format (bump on breaking changes).
const EXPORT_FORMAT_VERSION: u32 = 1;

/// The on-disk shape of a feed export.
#[derive(Serialize)]
struct FeedExportFile {
    format: &'static str,
    version: u32,
    feeds: Vec<FeedExportEntry>,
}

/// One exported feed. `id`/`name`/`version`/`author` are informational —
/// imports take the real metadata from the script itself; only
/// `source_url` is registry state that the script cannot carry.
#[derive(Serialize, Deserialize)]
struct FeedExportEntry {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    source_url: Option<String>,
    script: String,
}

/// Export every installed feed — scripts included — as a portable JSON
/// document [`import_feeds`] accepts back.
pub async fn export_feeds() -> Result<String, BridgeError> {
    export_feeds_from_db(&hub_db()?).await
}

/// The export core, over an explicit database handle (tests).
pub(crate) async fn export_feeds_from_db(db: &Db) -> Result<String, BridgeError> {
    let rows = db.call(|repo| repo.list_feeds_with_scripts()).await?;

    let mut feeds = Vec::with_capacity(rows.len());
    for (row, script) in rows {
        // A missing history row is an invariant violation; skip it rather
        // than export an entry that cannot be reinstalled.
        let Some(script) = script else {
            tracing::warn!(feed_id = %row.id, "feed without script history — skipped in export");
            continue;
        };
        feeds.push(FeedExportEntry {
            id: Some(row.id),
            name: Some(row.name),
            version: Some(row.version),
            author: row.author,
            source_url: row.source_url,
            script,
        });
    }

    serde_json::to_string(&FeedExportFile {
        format: EXPORT_FORMAT,
        version: EXPORT_FORMAT_VERSION,
        feeds,
    })
    .map_err(|e| BridgeError::from(format!("feed export serialization failed: {e}")))
}

/// Parse a feed export: either the wrapper object or a bare entry array.
fn parse_export_entries(json: &str) -> Result<Vec<FeedExportEntry>, BridgeError> {
    let value: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| BridgeError::from(format!("not a feed export: {e}")))?;

    let entries_value = match value {
        serde_json::Value::Array(_) => value,
        serde_json::Value::Object(ref map) => match map.get("format") {
            Some(format) if format.as_str() != Some(EXPORT_FORMAT) => {
                return Err(BridgeError::from(format!(
                    "unknown feed export format: expected {EXPORT_FORMAT}"
                )));
            }
            _ => map.get("feeds").cloned().unwrap_or(serde_json::Value::Null),
        },
        _ => serde_json::Value::Null,
    };

    let entries: Vec<FeedExportEntry> = serde_json::from_value(entries_value)
        .map_err(|e| BridgeError::from(format!("malformed feed export: {e}")))?;
    if entries.is_empty() {
        return Err(BridgeError::from(
            "feed export contains no feeds".to_owned(),
        ));
    }
    Ok(entries)
}

/// Classify a feed import against the installed registry: parse every
/// script's metadata (validating it) and report how its version relates to
/// the installed one. Nothing is installed.
pub async fn preview_import_feeds(json: String) -> Result<Vec<FeedImportEntry>, BridgeError> {
    preview_import_feeds_from_db(&hub_db()?, &json).await
}

/// The preview core, over an explicit database handle (tests).
pub(crate) async fn preview_import_feeds_from_db(
    db: &Db,
    json: &str,
) -> Result<Vec<FeedImportEntry>, BridgeError> {
    let entries = parse_export_entries(json)?;
    let installed = db.call(|repo| repo.list_feeds()).await?;

    let mut preview = Vec::with_capacity(entries.len());
    for entry in &entries {
        // The script is the source of truth for everything but source_url.
        let (meta, _) = langhuan::script::meta::parse_meta(&entry.script)?;
        let current = installed
            .iter()
            .find(|row| row.id == meta.id)
            .map(|row| row.version.as_str());
        preview.push(FeedImportEntry {
            change: classify_version_change(current, &meta.version),
            id: meta.id,
            name: meta.name,
            version: meta.version,
            author: meta.author,
        });
    }
    Ok(preview)
}

/// Install every feed from an export. Entries already installed at the
/// exact same version and content are skipped; each other entry installs
/// independently, and failures are collected per entry.
pub async fn import_feeds(json: String) -> Result<FeedImportOutcome, BridgeError> {
    let entries = parse_export_entries(&json)?;
    addresses()?
        .registry
        .clone()
        .send(ImportFeeds {
            entries: entries
                .into_iter()
                .map(|entry| ImportFeedScript {
                    script: entry.script,
                    source_url: entry.source_url,
                })
                .collect(),
        })
        .await?
}

/// Write a standalone snapshot of the whole database to `path` via
/// `VACUUM INTO` — one compacted file with the WAL folded in, consistent
/// as of this call. An existing file at `path` is replaced.
pub async fn export_backup(path: String) -> Result<(), BridgeError> {
    let db = hub_db()?;
    // VACUUM INTO refuses to overwrite; the caller's temp target must be
    // fresh (a leftover from a failed earlier attempt is fine to drop).
    let _ = tokio::fs::remove_file(&path).await;
    db.call({
        let target = path.clone();
        move |repo| repo.vacuum_into(&target)
    })
    .await?;
    tracing::info!(path = %path, "backup exported");
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::db::now_ms;

    use super::*;
    use crate::api::types::VersionChange::*;

    type TestResult = Result<(), Box<dyn Error>>;

    async fn test_db() -> Result<Db, Box<dyn Error>> {
        Ok(Db::open_in_memory().await?)
    }

    /// A minimal script with parseable metadata.
    fn script(id: &str, version: &str) -> String {
        format!(
            "-- ==Feed==\n-- @id  {id}\n-- @name Feed {id}\n-- @version {version}\n\
             -- @schema_version 1\n-- @base_url http://127.0.0.1:1/\n\
             -- @access_domain 127.0.0.1\n-- ==/Feed==\nreturn {{}}\n"
        )
    }

    async fn seed(db: &Db, id: &str, version: &str, hash: &str) -> Result<(), Box<dyn Error>> {
        let content = script(id, version);
        let (meta, _) = langhuan::script::meta::parse_meta(&content)?;
        let id = id.to_owned();
        let version = version.to_owned();
        let hash = hash.to_owned();
        db.write(move |repo| {
            repo.upsert_feed(&meta, None, &hash, now_ms())?;
            repo.upsert_script(&id, &version, &hash, &content, now_ms())
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn export_roundtrips_through_import_preview() -> TestResult {
        let db = test_db().await?;
        seed(&db, "f1", "1.0.0", "hash-1").await?;
        seed(&db, "f2", "2.0.0", "hash-2").await?;

        let json = export_feeds_from_db(&db).await?;
        let parsed: serde_json::Value = serde_json::from_str(&json)?;
        assert_eq!(parsed["format"], "langhuan-feeds");
        assert_eq!(parsed["version"], 1);

        // Against the same database everything classifies as Same.
        let preview = preview_import_feeds_from_db(&db, &json).await?;
        assert_eq!(preview.len(), 2);
        assert!(preview.iter().all(|e| e.change == Same));

        // Against an empty database everything is New, with metadata taken
        // from the scripts, not the JSON.
        let fresh = test_db().await?;
        let preview = preview_import_feeds_from_db(&fresh, &json).await?;
        assert!(preview.iter().all(|e| e.change == New));
        assert_eq!(preview[0].id, "f1");
        assert_eq!(preview[0].name, "Feed f1");
        assert_eq!(preview[0].version, "1.0.0");
        Ok(())
    }

    #[tokio::test]
    async fn preview_classifies_upgrades_and_downgrades() -> TestResult {
        let db = test_db().await?;
        seed(&db, "f1", "1.2.0", "hash").await?;

        let older = format!(
            "{{\"format\":\"langhuan-feeds\",\"version\":1,\"feeds\":[{{\"script\":{}}}]}}",
            serde_json::to_string(&script("f1", "1.0.0"))?
        );
        let newer = format!(
            "{{\"format\":\"langhuan-feeds\",\"version\":1,\"feeds\":[{{\"script\":{}}}]}}",
            serde_json::to_string(&script("f1", "1.3.0"))?
        );

        let preview = preview_import_feeds_from_db(&db, &older).await?;
        assert_eq!(preview[0].change, Downgrade);
        let preview = preview_import_feeds_from_db(&db, &newer).await?;
        assert_eq!(preview[0].change, Upgrade);
        Ok(())
    }

    #[tokio::test]
    async fn export_rejects_unknown_format_and_empty_files() -> TestResult {
        assert!(parse_export_entries("{\"format\":\"other\",\"feeds\":[]}").is_err());
        assert!(parse_export_entries("{\"format\":\"langhuan-feeds\",\"feeds\":[]}").is_err());
        assert!(parse_export_entries("[]").is_err());
        assert!(parse_export_entries("not json").is_err());

        // A bare array with one entry is accepted.
        let bare = format!(
            "[{{\"script\":{}}}]",
            serde_json::to_string(&script("f1", "1.0.0"))?
        );
        assert_eq!(parse_export_entries(&bare)?.len(), 1);
        Ok(())
    }

    #[tokio::test]
    async fn backup_snapshot_is_a_valid_database() -> TestResult {
        let db = test_db().await?;
        seed(&db, "f1", "1.0.0", "hash").await?;

        let dir = tempfile::tempdir()?;
        let backup_path = dir.path().join("backup.db");
        db.call({
            let path = backup_path
                .to_str()
                .ok_or("backup path is not valid UTF-8")?
                .to_owned();
            move |repo| repo.vacuum_into(&path)
        })
        .await?;

        // The snapshot opens as a database and carries the data over.
        let snapshot = Db::open(&backup_path).await?;
        let rows = snapshot.call(|repo| repo.list_feeds()).await?;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "f1");

        // A second VACUUM INTO over an existing target fails (caller-owned).
        let result = db
            .call({
                let path = backup_path
                    .to_str()
                    .ok_or("backup path is not valid UTF-8")?
                    .to_owned();
                move |repo| repo.vacuum_into(&path)
            })
            .await;
        assert!(result.is_err(), "VACUUM INTO must not overwrite");
        Ok(())
    }
}
