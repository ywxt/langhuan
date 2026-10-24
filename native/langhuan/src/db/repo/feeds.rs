//! `feeds` + `feed_scripts` — the feed registry and its script history.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;
use crate::feed::FeedMeta;

/// One row of the `feeds` table.
#[derive(Debug, Clone)]
pub struct FeedRow {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub source_url: Option<String>,
    pub content_hash: String,
    pub installed_at_ms: i64,
    pub updated_at_ms: i64,
}

/// A script-history row (newest first).
#[derive(Debug, Clone)]
pub struct ScriptRow {
    pub version: String,
    pub content_hash: String,
    pub script: String,
    pub installed_at_ms: i64,
}

/// Install or upgrade a feed: upsert the `feeds` row and the `feed_scripts`
/// row for this version.
///
/// `installed_at_ms` is preserved across upgrades (`updated_at_ms` moves).
/// A `None` `source_url` never erases a previously recorded URL.
pub fn upsert_feed(
    conn: &Connection,
    meta: &FeedMeta,
    source_url: Option<&str>,
    content_hash: &str,
    now_ms: i64,
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO feeds (id, name, version, author, source_url, content_hash, installed_at_ms, updated_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7) \
         ON CONFLICT(id) DO UPDATE SET \
             name = excluded.name, \
             version = excluded.version, \
             author = excluded.author, \
             source_url = COALESCE(excluded.source_url, feeds.source_url), \
             content_hash = excluded.content_hash, \
             updated_at_ms = excluded.updated_at_ms",
    )?
    .execute(tokio_rusqlite::params![
        meta.id,
        meta.name,
        meta.version,
        meta.author,
        source_url,
        content_hash,
        now_ms,
    ])?;
    Ok(())
}

/// Insert or refresh the script-history row for `(feed_id, version)`.
pub fn upsert_script(
    conn: &Connection,
    feed_id: &str,
    version: &str,
    content_hash: &str,
    script: &str,
    now_ms: i64,
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO feed_scripts (feed_id, version, content_hash, script, installed_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT(feed_id, version) DO UPDATE SET \
             content_hash = excluded.content_hash, \
             script = excluded.script, \
             installed_at_ms = excluded.installed_at_ms",
    )?
    .execute(tokio_rusqlite::params![feed_id, version, content_hash, script, now_ms])?;
    Ok(())
}

/// Delete all but the newest `keep` script versions for `feed_id`.
///
/// Returns the number of history rows pruned.
pub fn prune_scripts(conn: &Connection, feed_id: &str, keep: usize) -> Result<u64> {
    let pruned = conn
        .prepare_cached(
            "DELETE FROM feed_scripts WHERE feed_id = ?1 AND version NOT IN ( \
                 SELECT version FROM feed_scripts WHERE feed_id = ?1 \
                 ORDER BY installed_at_ms DESC, version DESC LIMIT ?2)",
        )?
        .execute(tokio_rusqlite::params![feed_id, keep as i64])?;
    Ok(pruned as u64)
}

/// List all registered feeds, oldest install first.
pub fn list_feeds(conn: &Connection) -> Result<Vec<FeedRow>> {
    let mut stmt = conn.prepare_cached(
        "SELECT id, name, version, author, source_url, content_hash, installed_at_ms, updated_at_ms \
         FROM feeds ORDER BY installed_at_ms, id",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok(FeedRow {
                id: row.get(0)?,
                name: row.get(1)?,
                version: row.get(2)?,
                author: row.get(3)?,
                source_url: row.get(4)?,
                content_hash: row.get(5)?,
                installed_at_ms: row.get(6)?,
                updated_at_ms: row.get(7)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn get_feed(conn: &Connection, id: &str) -> Result<Option<FeedRow>> {
    super::maybe_row(
        conn,
        "SELECT id, name, version, author, source_url, content_hash, installed_at_ms, updated_at_ms \
         FROM feeds WHERE id = ?1",
        &[&id],
        |row| {
            Ok(FeedRow {
                id: row.get(0)?,
                name: row.get(1)?,
                version: row.get(2)?,
                author: row.get(3)?,
                source_url: row.get(4)?,
                content_hash: row.get(5)?,
                installed_at_ms: row.get(6)?,
                updated_at_ms: row.get(7)?,
            })
        },
    )
}

/// List all registered feeds together with the script content of their
/// active version (`None` when the history row is missing — an internal
/// invariant violation).
///
/// Single pass used by the registry actor to compile all feeds at startup.
pub fn list_feeds_with_scripts(conn: &Connection) -> Result<Vec<(FeedRow, Option<String>)>> {
    let mut stmt = conn.prepare_cached(
        "SELECT f.id, f.name, f.version, f.author, f.source_url, f.content_hash, f.installed_at_ms, f.updated_at_ms, s.script \
         FROM feeds f \
         LEFT JOIN feed_scripts s ON s.feed_id = f.id AND s.version = f.version \
         ORDER BY f.installed_at_ms, f.id",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                FeedRow {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    version: row.get(2)?,
                    author: row.get(3)?,
                    source_url: row.get(4)?,
                    content_hash: row.get(5)?,
                    installed_at_ms: row.get(6)?,
                    updated_at_ms: row.get(7)?,
                },
                row.get::<_, Option<String>>(8)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// The active script content for `feed_id` (the row matching `feeds.version`).
pub fn get_current_script(conn: &Connection, feed_id: &str) -> Result<Option<String>> {
    super::maybe_row(
        conn,
        "SELECT s.script FROM feed_scripts s \
         JOIN feeds f ON f.id = s.feed_id AND f.version = s.version \
         WHERE s.feed_id = ?1",
        &[&feed_id],
        |row| row.get(0),
    )
}

/// Delete a feed. Everything attached to it (scripts, cached books, covers,
/// bookshelf entries, progress, bookmarks, auth) cascades.
///
/// Returns `false` when the feed id is unknown.
pub fn delete_feed(conn: &Connection, feed_id: &str) -> Result<bool> {
    let deleted = conn
        .prepare_cached("DELETE FROM feeds WHERE id = ?1")?
        .execute([feed_id])?;
    Ok(deleted > 0)
}

/// Script history for `feed_id`, newest first.
pub fn list_scripts(conn: &Connection, feed_id: &str) -> Result<Vec<ScriptRow>> {
    let mut stmt = conn.prepare_cached(
        "SELECT version, content_hash, script, installed_at_ms FROM feed_scripts \
         WHERE feed_id = ?1 ORDER BY installed_at_ms DESC, version DESC",
    )?;
    let rows = stmt
        .query_map([feed_id], |row| {
            Ok(ScriptRow {
                version: row.get(0)?,
                content_hash: row.get(1)?,
                script: row.get(2)?,
                installed_at_ms: row.get(3)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;

    fn meta(id: &str, version: &str) -> FeedMeta {
        FeedMeta {
            id: id.to_owned(),
            name: format!("Feed {id}"),
            version: version.to_owned(),
            author: Some("a".to_owned()),
            description: None,
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        }
    }

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
             CREATE TABLE feed_scripts (feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, version TEXT NOT NULL, content_hash TEXT NOT NULL, script TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, version)) WITHOUT ROWID;",
        )
        .expect("schema");
        conn
    }

    #[test]
    fn upsert_feed_installs_then_upgrades() {
        let conn = setup();
        let now = now_ms();
        upsert_feed(&conn, &meta("f1", "1.0.0"), Some("https://src"), "h1", now)
            .expect("install");
        upsert_feed(&conn, &meta("f1", "1.1.0"), None, "h2", now + 10)
            .expect("upgrade");

        let row = get_feed(&conn, "f1").expect("get").expect("exists");
        assert_eq!(row.version, "1.1.0");
        assert_eq!(row.content_hash, "h2");
        // source_url preserved across a file-based upgrade (None)
        assert_eq!(row.source_url.as_deref(), Some("https://src"));
        assert_eq!(row.installed_at_ms, now);
        assert_eq!(row.updated_at_ms, now + 10);
    }

    #[test]
    fn script_history_prunes_to_limit() {
        let conn = setup();
        let now = now_ms();
        upsert_feed(&conn, &meta("f1", "1.0.3"), None, "h", now).expect("feed");
        for (i, v) in ["1.0.1", "1.0.2", "1.0.3", "1.0.4"].iter().enumerate() {
            upsert_script(&conn, "f1", v, "h", &format!("--{v}"), now + i as i64)
                .expect("script");
        }

        let pruned = prune_scripts(&conn, "f1", 3).expect("prune");
        assert_eq!(pruned, 1);

        let versions: Vec<String> = list_scripts(&conn, "f1")
            .expect("list")
            .into_iter()
            .map(|s| s.version)
            .collect();
        assert_eq!(versions, ["1.0.4", "1.0.3", "1.0.2"]);
    }

    #[test]
    fn current_script_follows_feeds_version() {
        let conn = setup();
        let now = now_ms();
        upsert_feed(&conn, &meta("f1", "1.0.0"), None, "h", now).expect("feed");
        upsert_script(&conn, "f1", "1.0.0", "h", "--active", now).expect("script");
        upsert_script(&conn, "f1", "0.9.0", "h", "--old", now - 10).expect("script");

        assert_eq!(
            get_current_script(&conn, "f1").expect("current").as_deref(),
            Some("--active")
        );
    }

    #[test]
    fn delete_feed_returns_false_when_missing() {
        let conn = setup();
        assert!(!delete_feed(&conn, "nope").expect("delete"));
    }
}
