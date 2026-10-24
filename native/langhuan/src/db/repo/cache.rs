//! Content cache: `books`, `covers`, `chapter_lists`, `chapters`.
//!
//! The `books` table doubles as the book metadata cache and the anchor every
//! other cache table references (`ON DELETE CASCADE`), so evicting a book
//! row drops its whole cache footprint in one statement.
//!
//! # Cover state machine
//!
//! `books.cover_state` is a negative cache for cover downloads:
//!
//! ```text
//! none ───────────► pending ──► downloaded
//!   ▲                  │
//!   │                  └─► failed ──(retry after 7d)──► pending
//!   └──(cover_url removed / cache cleared)
//! ```
//!
//! `pending` rows older than [`COVER_INFLIGHT_RETRY_MS`] are re-attempted
//! (the app may have died mid-download), which also makes duplicate spawns
//! single-flight within that window.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};
use crate::model::{BookInfo, ChapterInfo, Paragraph};

use super::decode_json;

/// A cover download is considered in-flight for this long; afterwards a
/// `pending` row may be re-attempted.
pub const COVER_INFLIGHT_RETRY_MS: i64 = 10 * 60 * 1000;

/// A `failed` cover download is re-attempted after this long.
pub const COVER_FAILED_RETRY_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// Chapter lists go stale after this long (they change when a book updates).
pub const CHAPTER_LIST_TTL_MS: i64 = 6 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Book info rows
// ---------------------------------------------------------------------------

/// Book metadata as stored in the `books` table.
#[derive(Debug, Clone)]
pub struct BookRow {
    pub feed_id: String,
    pub book_id: String,
    pub title: String,
    pub author: String,
    pub description: Option<String>,
    pub cover_url: Option<String>,
    pub info_fetched_at_ms: i64,
}

impl BookRow {
    /// Whether this row holds a real fetch (as opposed to a search-result
    /// placeholder, which has `info_fetched_at_ms == 0`).
    pub fn is_fetched(&self) -> bool {
        self.info_fetched_at_ms > 0
    }

    /// Convert the row back into a [`BookInfo`] for cache hits.
    ///
    /// `cover_url` is the *remote* URL as published by the feed — downloaded
    /// bytes live in the `covers` table and are read through
    /// [`super::super::cache::get_cover`] style APIs.
    pub fn into_book_info(self) -> BookInfo {
        BookInfo {
            id: self.book_id,
            title: self.title,
            author: self.author,
            cover_url: self.cover_url,
            description: self.description,
        }
    }
}

const BOOK_COLUMNS: &str =
    "feed_id, book_id, title, author, description, cover_url, info_fetched_at_ms";

fn map_book_row(row: &tokio_rusqlite::rusqlite::Row<'_>) -> tokio_rusqlite::rusqlite::Result<BookRow> {
    Ok(BookRow {
        feed_id: row.get(0)?,
        book_id: row.get(1)?,
        title: row.get(2)?,
        author: row.get(3)?,
        description: row.get(4)?,
        cover_url: row.get(5)?,
        info_fetched_at_ms: row.get(6)?,
    })
}

/// Ensure a `books` row exists (minimal placeholder) so cache tables have
/// something to reference.
pub fn ensure_book(conn: &Connection, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()> {
    conn.prepare_cached(
        "INSERT OR IGNORE INTO books (feed_id, book_id, title, author, last_used_at_ms) \
         VALUES (?1, ?2, ?2, '', ?3)",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
    Ok(())
}

/// Read the cached book row and refresh `last_used_at_ms`.
///
/// Returns `None` when no row exists.
pub fn get_book_and_touch(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    now_ms: i64,
) -> Result<Option<BookRow>> {
    let row = super::maybe_row(
        conn,
        &format!("SELECT {BOOK_COLUMNS} FROM books WHERE feed_id = ?1 AND book_id = ?2"),
        &[&feed_id, &book_id],
        map_book_row,
    )?;
    if row.is_some() {
        touch_book(conn, feed_id, book_id, now_ms)?;
    }
    Ok(row)
}

pub fn touch_book(conn: &Connection, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()> {
    conn.prepare_cached(
        "UPDATE books SET last_used_at_ms = ?3 WHERE feed_id = ?1 AND book_id = ?2",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
    Ok(())
}

/// Persist a freshly fetched [`BookInfo`] and advance the cover state.
///
/// Returns whether a cover download should be spawned now (the state machine
/// decided `pending` and a `cover_url` is available).
pub fn upsert_fetched_book(
    conn: &Connection,
    feed_id: &str,
    info: &BookInfo,
    now_ms: i64,
) -> Result<bool> {
    let existing = read_cover_existing(conn, feed_id, &info.id)?;
    let plan = advance_cover_state(&existing, info.cover_url.as_deref(), now_ms);
    if plan.state == "none" {
        delete_cover(conn, feed_id, &info.id)?;
    }

    // 1. Seed the row when absent (plan values were computed for that case).
    conn.prepare_cached(
        "INSERT OR IGNORE INTO books (feed_id, book_id, title, author, description, cover_url, cover_state, cover_fetched_at_ms, info_fetched_at_ms, last_used_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
    )?
    .execute(tokio_rusqlite::params![
        feed_id,
        info.id,
        info.title,
        info.author,
        info.description,
        info.cover_url,
        plan.state,
        plan.fetched_at_ms,
        now_ms,
    ])?;

    // 2. Overwrite the display fields and cover columns.
    conn.prepare_cached(
        "UPDATE books SET title = ?3, author = ?4, description = ?5, cover_url = ?6, \
             cover_state = ?7, cover_fetched_at_ms = ?8, info_fetched_at_ms = ?9, last_used_at_ms = ?9 \
         WHERE feed_id = ?1 AND book_id = ?2",
    )?
    .execute(tokio_rusqlite::params![
        feed_id,
        info.id,
        info.title,
        info.author,
        info.description,
        info.cover_url,
        plan.state,
        plan.fetched_at_ms,
        now_ms,
    ])?;
    Ok(plan.spawn)
}

/// Current cover-related columns of a `books` row.
struct CoverExisting {
    state: String,
    url: Option<String>,
    fetched_at_ms: i64,
    has_cover_row: bool,
}

fn read_cover_existing(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
) -> Result<Option<CoverExisting>> {
    super::maybe_row(
        conn,
        "SELECT cover_state, cover_url, cover_fetched_at_ms, \
                EXISTS(SELECT 1 FROM covers c WHERE c.feed_id = books.feed_id AND c.book_id = books.book_id) \
         FROM books WHERE feed_id = ?1 AND book_id = ?2",
        &[&feed_id, &book_id],
        |row| {
            Ok(CoverExisting {
                state: row.get(0)?,
                url: row.get(1)?,
                fetched_at_ms: row.get(2)?,
                has_cover_row: row.get::<_, i64>(3)? == 1,
            })
        },
    )
}

/// Concrete values to write into the cover columns, plus the spawn decision.
struct CoverPlan {
    spawn: bool,
    state: String,
    fetched_at_ms: i64,
}

/// Shared state-machine step: given the existing cover columns and the new
/// `cover_url`, decide whether to spawn a download and what to write.
///
/// When a download should be spawned the state is reset to `none` — the
/// **download task itself** claims the slot and writes `pending` (see
/// [`claim_cover_download`]); writing `pending` here would make that claim
/// fail and the spawn a no-op. Writing `none` also self-heals: if the spawn
/// is lost, the next evaluation spawns again.
fn advance_cover_state(
    existing: &Option<CoverExisting>,
    new_url: Option<&str>,
    _now_ms: i64,
) -> CoverPlan {
    let Some(new_url) = new_url else {
        // Site no longer reports a cover — reset; the caller drops any
        // stored bytes.
        return CoverPlan {
            spawn: false,
            state: "none".to_owned(),
            fetched_at_ms: 0,
        };
    };
    match existing {
        None => CoverPlan {
            spawn: true,
            state: "none".to_owned(),
            fetched_at_ms: 0,
        },
        Some(existing) => {
            let url_changed = existing.url.as_deref() != Some(new_url);
            let spawn = url_changed
                || spawn_decision(
                    &existing.state,
                    existing.has_cover_row,
                    _now_ms - existing.fetched_at_ms,
                );
            if spawn {
                CoverPlan {
                    spawn: true,
                    state: "none".to_owned(),
                    fetched_at_ms: 0,
                }
            } else {
                // Keep the stored state (downloaded / failed within backoff /
                // pending in flight) and its timestamp.
                CoverPlan {
                    spawn: false,
                    state: existing.state.clone(),
                    fetched_at_ms: existing.fetched_at_ms,
                }
            }
        }
    }
}

/// Should a cover download be spawned, given the current state?
///
/// * `state == "downloaded"` with a live cover row — nothing to do.
/// * `"downloaded"` without a cover row — drift (cache cleared behind the
///   state's back); repair by re-downloading.
/// * `"failed"` — retry after [`COVER_FAILED_RETRY_MS`].
/// * `"pending"` — treat as in-flight; retry only after
///   [`COVER_INFLIGHT_RETRY_MS`] (crashed download).
/// * `"none"` — never attempted.
fn spawn_decision(state: &str, has_cover_row: bool, age_ms: i64) -> bool {
    match state {
        "downloaded" => !has_cover_row,
        "failed" => age_ms >= COVER_FAILED_RETRY_MS,
        "pending" => age_ms >= COVER_INFLIGHT_RETRY_MS,
        _ => true,
    }
}

/// Evaluate a cache hit: refresh `last_used_at_ms`, repair cover drift, and
/// decide whether a (re-)download should be spawned.
///
/// Returns the row plus the spawn decision.
pub fn get_cached_book_for_hit(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    now_ms: i64,
) -> Result<Option<(BookRow, bool)>> {
    let Some(row) = get_book_and_touch(conn, feed_id, book_id, now_ms)? else {
        return Ok(None);
    };
    let existing = read_cover_existing(conn, feed_id, book_id)?;
    let plan = advance_cover_state(&existing, row.cover_url.as_deref(), now_ms);
    // No state write here: when a download is due, the spawned task claims
    // the slot (and writes `pending`) itself.
    Ok(Some((row, plan.spawn)))
}

/// Overwrite the display fields of a placeholder row from a search-result
/// snapshot (only rows with `info_fetched_at_ms = 0` are touched).
///
/// Returns whether a cover download should be spawned for this book.
pub fn upsert_snapshot(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    title: &str,
    author: &str,
    description: Option<&str>,
    cover_url: Option<&str>,
    now_ms: i64,
) -> Result<bool> {
    let existing = read_cover_existing(conn, feed_id, book_id)?;
    let plan = advance_cover_state(&existing, cover_url, now_ms);

    // 1. Seed a placeholder row when absent.
    conn.prepare_cached(
        "INSERT OR IGNORE INTO books (feed_id, book_id, title, author, description, cover_url, cover_state, cover_fetched_at_ms, info_fetched_at_ms, last_used_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9)",
    )?
    .execute(tokio_rusqlite::params![
        feed_id,
        book_id,
        title,
        author,
        description,
        cover_url,
        plan.state,
        plan.fetched_at_ms,
        now_ms,
    ])?;

    // 2. Refresh the display fields — but only while the row is still a
    //    placeholder; fetched data always wins over a search snapshot.
    conn.prepare_cached(
        "UPDATE books SET title = ?3, author = ?4, description = ?5, cover_url = ?6, \
             cover_state = ?7, cover_fetched_at_ms = ?8, last_used_at_ms = ?9 \
         WHERE feed_id = ?1 AND book_id = ?2 AND info_fetched_at_ms = 0",
    )?
    .execute(tokio_rusqlite::params![
        feed_id,
        book_id,
        title,
        author,
        description,
        cover_url,
        plan.state,
        plan.fetched_at_ms,
        now_ms,
    ])?;
    Ok(plan.spawn)
}

// ---------------------------------------------------------------------------
// Covers
// ---------------------------------------------------------------------------

/// Read the stored cover bytes for a book, with the recorded MIME type.
pub fn get_cover_bytes(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
) -> Result<Option<(String, Vec<u8>)>> {
    super::maybe_row(
        conn,
        "SELECT mime, bytes FROM covers WHERE feed_id = ?1 AND book_id = ?2",
        &[&feed_id, &book_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
    )
}

/// Store downloaded cover bytes and mark the state `downloaded`.
pub fn set_cover(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    mime: &str,
    bytes: &[u8],
    now_ms: i64,
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO covers (feed_id, book_id, mime, bytes, fetched_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT(feed_id, book_id) DO UPDATE SET \
             mime = excluded.mime, bytes = excluded.bytes, fetched_at_ms = excluded.fetched_at_ms",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, mime, bytes, now_ms])?;
    conn.prepare_cached(
        "UPDATE books SET cover_state = 'downloaded', cover_fetched_at_ms = ?3 \
         WHERE feed_id = ?1 AND book_id = ?2",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
    Ok(())
}

/// Set the cover state and its timestamp (e.g. `failed`, `pending`).
pub fn mark_cover(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    state: &str,
    now_ms: i64,
) -> Result<()> {
    conn.prepare_cached(
        "UPDATE books SET cover_state = ?3, cover_fetched_at_ms = ?4 \
         WHERE feed_id = ?1 AND book_id = ?2",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, state, now_ms])?;
    Ok(())
}

/// Claim the cover download slot for this book.
///
/// Returns `false` when another download is already in flight (state
/// `pending`, younger than the in-flight window) or already `downloaded` —
/// the caller should skip. Advancing a stale `pending` or an expired
/// `failed` state claims the slot and returns `true`.
pub fn claim_cover_download(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    now_ms: i64,
) -> Result<bool> {
    let claimed = conn
        .prepare_cached(
            "UPDATE books SET cover_state = 'pending', cover_fetched_at_ms = ?3 \
             WHERE feed_id = ?1 AND book_id = ?2 \
               AND (cover_state IN ('none', 'failed') \
                    OR (cover_state = 'pending' AND ?3 - cover_fetched_at_ms >= ?4))",
        )?
        .execute(tokio_rusqlite::params![
            feed_id,
            book_id,
            now_ms,
            COVER_INFLIGHT_RETRY_MS,
        ])?;
    Ok(claimed > 0)
}

pub fn delete_cover(conn: &Connection, feed_id: &str, book_id: &str) -> Result<()> {
    conn.prepare_cached("DELETE FROM covers WHERE feed_id = ?1 AND book_id = ?2")?
        .execute([feed_id, book_id])?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Chapter lists (table of contents)
// ---------------------------------------------------------------------------

/// Read the cached chapter list, if present and not older than the TTL.
pub fn get_chapter_list(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    now_ms: i64,
) -> Result<Option<Vec<ChapterInfo>>> {
    let cached = super::maybe_row(
        conn,
        "SELECT chapters_json, cached_at_ms FROM chapter_lists \
         WHERE feed_id = ?1 AND book_id = ?2",
        &[&feed_id, &book_id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
            ))
        },
    )?;
    match cached {
        Some((json, cached_at)) if now_ms - cached_at <= CHAPTER_LIST_TTL_MS => {
            let chapters: Vec<ChapterInfo> =
                decode_json("chapter list", &json).map_err(|e| {
                    // Drop the broken row so the next call re-fetches.
                    let _ = delete_chapter_list(conn, feed_id, book_id);
                    e
                })?;
            touch_book(conn, feed_id, book_id, now_ms)?;
            Ok(Some(chapters))
        }
        _ => Ok(None),
    }
}

pub fn set_chapter_list(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    chapters: &[ChapterInfo],
    now_ms: i64,
) -> Result<()> {
    ensure_book(conn, feed_id, book_id, now_ms)?;
    let json = serde_json::to_string(chapters)
        .map_err(|e| Error::database(format!("serialize chapter list: {e}")))?;
    conn.prepare_cached(
        "INSERT INTO chapter_lists (feed_id, book_id, chapters_json, cached_at_ms) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(feed_id, book_id) DO UPDATE SET \
             chapters_json = excluded.chapters_json, cached_at_ms = excluded.cached_at_ms",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, json, now_ms])?;
    touch_book(conn, feed_id, book_id, now_ms)?;
    Ok(())
}

pub fn delete_chapter_list(conn: &Connection, feed_id: &str, book_id: &str) -> Result<()> {
    conn.prepare_cached("DELETE FROM chapter_lists WHERE feed_id = ?1 AND book_id = ?2")?
        .execute([feed_id, book_id])?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Chapter content (paragraphs)
// ---------------------------------------------------------------------------

/// Read cached chapter paragraphs and refresh `last_used_at_ms`.
pub fn get_paragraphs(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    chapter_id: &str,
    now_ms: i64,
) -> Result<Option<Vec<Paragraph>>> {
    let json = super::maybe_row(
        conn,
        "SELECT paragraphs_json FROM chapters \
         WHERE feed_id = ?1 AND book_id = ?2 AND chapter_id = ?3",
        &[&feed_id, &book_id, &chapter_id],
        |row| row.get::<_, String>(0),
    )?;
    match json {
        Some(json) => {
            let paragraphs: Vec<Paragraph> =
                decode_json("chapter paragraphs", &json).map_err(|e| {
                    let _ = delete_paragraphs(conn, feed_id, book_id, chapter_id);
                    e
                })?;
            touch_book(conn, feed_id, book_id, now_ms)?;
            Ok(Some(paragraphs))
        }
        None => Ok(None),
    }
}

pub fn set_paragraphs(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    chapter_id: &str,
    paragraphs: &[Paragraph],
    now_ms: i64,
) -> Result<()> {
    ensure_book(conn, feed_id, book_id, now_ms)?;
    let json = serde_json::to_string(paragraphs)
        .map_err(|e| Error::database(format!("serialize paragraphs: {e}")))?;
    conn.prepare_cached(
        "INSERT INTO chapters (feed_id, book_id, chapter_id, paragraphs_json, cached_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT(feed_id, book_id, chapter_id) DO UPDATE SET \
             paragraphs_json = excluded.paragraphs_json, cached_at_ms = excluded.cached_at_ms",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, chapter_id, json, now_ms])?;
    touch_book(conn, feed_id, book_id, now_ms)?;
    Ok(())
}

pub fn delete_paragraphs(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    chapter_id: &str,
) -> Result<()> {
    conn.prepare_cached(
        "DELETE FROM chapters WHERE feed_id = ?1 AND book_id = ?2 AND chapter_id = ?3",
    )?
    .execute(tokio_rusqlite::params![feed_id, book_id, chapter_id])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;
    use crate::model::ParagraphId;

    const SCHEMA: &str = "\
        CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
        CREATE TABLE books (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, description TEXT, cover_url TEXT, cover_state TEXT NOT NULL DEFAULT 'none' CHECK (cover_state IN ('none','pending','downloaded','failed')), cover_fetched_at_ms INTEGER NOT NULL DEFAULT 0, info_fetched_at_ms INTEGER NOT NULL DEFAULT 0, last_used_at_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE covers (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, mime TEXT NOT NULL, bytes BLOB NOT NULL, fetched_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE chapter_lists (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapters_json TEXT NOT NULL, cached_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE chapters (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL, paragraphs_json TEXT NOT NULL, cached_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id, chapter_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID;";

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(SCHEMA).expect("schema");
        conn.execute_batch("INSERT INTO feeds VALUES ('f1', 'Feed', '1.0', NULL, NULL, 'h', 1, 1);")
            .expect("seed feed");
        conn
    }

    fn info(id: &str, cover: Option<&str>) -> BookInfo {
        BookInfo {
            id: id.to_owned(),
            title: format!("Book {id}"),
            author: "Author".to_owned(),
            cover_url: cover.map(str::to_owned),
            description: Some("desc".to_owned()),
        }
    }

    fn paragraphs() -> Vec<Paragraph> {
        vec![
            Paragraph::Title {
                id: ParagraphId::Index(0),
                text: "ch".to_owned(),
            },
            Paragraph::Text {
                id: ParagraphId::Index(1),
                content: "hello".to_owned(),
            },
        ]
    }

    #[test]
    fn fetched_book_roundtrip() {
        let conn = conn();
        let now = now_ms();
        assert!(
            upsert_fetched_book(&conn, "f1", &info("b1", Some("https://c")), now)
                .expect("upsert")
        );
        let row = get_book_and_touch(&conn, "f1", "b1", now)
            .expect("get")
            .expect("row");
        assert_eq!(row.title, "Book b1");
        assert!(row.is_fetched());
        assert_eq!(row.cover_url.as_deref(), Some("https://c"));
    }

    #[test]
    fn cover_state_transitions() {
        let conn = conn();
        let now = now_ms();

        // Fresh fetch with cover → spawn.
        assert!(upsert_fetched_book(&conn, "f1", &info("b1", Some("u1")), now).unwrap());

        // Simulate a completed download.
        set_cover(&conn, "f1", "b1", "image/jpeg", b"junk", now).unwrap();
        // Same URL, downloaded — no re-spawn.
        assert!(
            !upsert_fetched_book(&conn, "f1", &info("b1", Some("u1")), now + 1000)
                .unwrap()
        );
        // Hit path agrees: downloaded + cover row → no spawn.
        let (_, spawn) = get_cached_book_for_hit(&conn, "f1", "b1", now + 2000)
            .unwrap()
            .expect("row");
        assert!(!spawn);

        // URL changes → re-download.
        assert!(
            upsert_fetched_book(&conn, "f1", &info("b1", Some("u2")), now + 3000).unwrap()
        );

        // A failed download is not retried within the backoff window…
        mark_cover(&conn, "f1", "b1", "failed", now + 4000).unwrap();
        let (_, spawn) = get_cached_book_for_hit(&conn, "f1", "b1", now + 5000)
            .unwrap()
            .expect("row");
        assert!(!spawn);
        // …but is retried after 7 days.
        let (_, spawn) = get_cached_book_for_hit(
            &conn,
            "f1",
            "b1",
            now + 4000 + COVER_FAILED_RETRY_MS + 1,
        )
        .unwrap()
        .expect("row");
        assert!(spawn);

        // Site drops the cover → state resets to none and bytes are deleted.
        assert!(
            !upsert_fetched_book(&conn, "f1", &info("b1", None), now + 9000).unwrap()
        );
        assert_eq!(get_cover_bytes(&conn, "f1", "b1").unwrap(), None);
    }

    #[test]
    fn claim_cover_download_is_single_flight() {
        let conn = conn();
        let now = now_ms();
        upsert_fetched_book(&conn, "f1", &info("b1", Some("u1")), now).unwrap();

        assert!(claim_cover_download(&conn, "f1", "b1", now).unwrap());
        // Second claim within the in-flight window → rejected.
        assert!(!claim_cover_download(&conn, "f1", "b1", now + 1000).unwrap());
        // After the window (crashed download) → allowed again.
        assert!(
            claim_cover_download(&conn, "f1", "b1", now + COVER_INFLIGHT_RETRY_MS + 1).unwrap()
        );
    }

    #[test]
    fn snapshot_only_refreshes_placeholders() {
        let conn = conn();
        let now = now_ms();

        upsert_snapshot(&conn, "f1", "b1", "Snap", "A", Some("d"), Some("u1"), now)
            .expect("snapshot");
        let row = get_book_and_touch(&conn, "f1", "b1", now).unwrap().unwrap();
        assert_eq!(row.title, "Snap");
        assert!(!row.is_fetched());

        // A real fetch lands…
        upsert_fetched_book(&conn, "f1", &info("b1", Some("u2")), now + 10).unwrap();
        // …and a later snapshot must NOT clobber it.
        upsert_snapshot(&conn, "f1", "b1", "Stale", "B", None, None, now + 20).unwrap();
        let row = get_book_and_touch(&conn, "f1", "b1", now + 30).unwrap().unwrap();
        assert_eq!(row.title, "Book b1");
        assert!(row.is_fetched());
    }

    #[test]
    fn chapter_list_ttl() {
        let conn = conn();
        let now = now_ms();
        let chapters = vec![ChapterInfo {
            id: "c1".to_owned(),
            title: "One".to_owned(),
        }];
        set_chapter_list(&conn, "f1", "b1", &chapters, now).expect("set");

        let fresh = get_chapter_list(&conn, "f1", "b1", now + 1000)
            .expect("get")
            .expect("fresh");
        assert_eq!(fresh.len(), 1);

        // After the TTL the row is reported as a miss…
        assert_eq!(
            get_chapter_list(&conn, "f1", "b1", now + CHAPTER_LIST_TTL_MS + 1)
                .expect("get")
                .is_none(),
            true
        );
        // …and a re-set refreshes it.
        set_chapter_list(&conn, "f1", "b1", &chapters, now + CHAPTER_LIST_TTL_MS + 2)
            .expect("re-set");
        assert!(
            get_chapter_list(&conn, "f1", "b1", now + CHAPTER_LIST_TTL_MS + 3)
                .expect("get")
                .is_some()
        );
    }

    #[test]
    fn paragraphs_roundtrip_and_delete() {
        let conn = conn();
        let now = now_ms();
        set_paragraphs(&conn, "f1", "b1", "c1", &paragraphs(), now).expect("set");

        let loaded = get_paragraphs(&conn, "f1", "b1", "c1", now + 1)
            .expect("get")
            .expect("some");
        assert_eq!(loaded.len(), 2);

        delete_paragraphs(&conn, "f1", "b1", "c1").expect("delete");
        assert_eq!(
            get_paragraphs(&conn, "f1", "b1", "c1", now + 2).expect("get").is_none(),
            true
        );
    }
}
