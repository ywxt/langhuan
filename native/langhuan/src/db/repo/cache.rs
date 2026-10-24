//! Content cache: `books`, `covers`, `chapter_lists`, `chapters`.
//!
//! The `books` table doubles as the book metadata cache and the anchor every
//! other cache table references (`ON DELETE CASCADE`), so evicting a book
//! row drops its whole cache footprint in one statement.
//!
//! # Cover state machine
//!
//! `books.cover_state` is a negative cache for cover downloads, stored as
//! [`CoverState`]:
//!
//! ```text
//! none ───────────► pending ──► downloaded
//!   ▲                  │
//!   │                  └─► failed ──(retry after 7d)──► pending
//!   └──(cover_url removed / cache cleared)
//! ```
//!
//! Whether a download is *due* is decided in exactly one place:
//! [`CacheRepo::claim_cover_download`]. Callers spawn a download task
//! whenever a book has a `cover_url`; the claim then sorts out single-flight
//! (fresh `pending`), failure backoff, and drift repair, and is the only
//! writer of the `pending` state. Upserts merely reset the state to `none`
//! when the stored `cover_url` changes, so a download for the new URL can
//! claim again.

use tokio_rusqlite::rusqlite::types::{
    FromSql, FromSqlError, FromSqlResult, ToSql, ToSqlOutput, ValueRef,
};
use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};
use crate::model::{BookInfo, ChapterInfo, Paragraph};

use super::decode_json;

/// A cover download is considered in-flight for this long; afterwards a
/// `pending` row may be re-attempted (the app may have died mid-download).
pub const COVER_INFLIGHT_RETRY_MS: i64 = 10 * 60 * 1000;

/// A `failed` cover download is re-attempted after this long.
pub const COVER_FAILED_RETRY_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// Chapter lists go stale after this long (they change when a book updates).
pub const CHAPTER_LIST_TTL_MS: i64 = 6 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Cover state
// ---------------------------------------------------------------------------

/// Lifecycle of a book's cover download, stored in `books.cover_state`.
///
/// The SQL literals (`'none'`, `'pending'`, `'downloaded'`, `'failed'`) are
/// pinned by the schema's CHECK constraint; this enum is their only
/// Rust-side representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoverState {
    /// Never attempted, reset because the `cover_url` changed, or cleared.
    None,
    /// A download is in flight.
    Pending,
    /// Cover bytes are stored in the `covers` table.
    Downloaded,
    /// The last attempt failed; retried after [`COVER_FAILED_RETRY_MS`].
    Failed,
}

impl CoverState {
    pub fn as_str(&self) -> &'static str {
        match self {
            CoverState::None => "none",
            CoverState::Pending => "pending",
            CoverState::Downloaded => "downloaded",
            CoverState::Failed => "failed",
        }
    }
}

impl FromSql for CoverState {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        match value.as_str()? {
            "none" => Ok(CoverState::None),
            "pending" => Ok(CoverState::Pending),
            "downloaded" => Ok(CoverState::Downloaded),
            "failed" => Ok(CoverState::Failed),
            other => Err(FromSqlError::Other(
                format!("unknown cover_state: {other}").into(),
            )),
        }
    }
}

impl ToSql for CoverState {
    fn to_sql(&self) -> tokio_rusqlite::rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::Borrowed(ValueRef::Text(
            self.as_str().as_bytes(),
        )))
    }
}

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
}

/// Convert a stored row back into a [`BookInfo`] for cache hits.
///
/// `cover_url` is the *remote* URL as published by the feed — downloaded
/// bytes live in the `covers` table and are read through
/// [`CacheRepo::get_cover_bytes`].
impl From<BookRow> for BookInfo {
    fn from(row: BookRow) -> Self {
        BookInfo {
            id: row.book_id,
            title: row.title,
            author: row.author,
            cover_url: row.cover_url,
            description: row.description,
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

/// Delete stored cover bytes when the incoming `cover_url` differs from the
/// stored one (`IS NOT` is NULL-safe), so a changed or removed URL never
/// leaves stale bytes behind. Must run *before* the row is upserted (it
/// compares against the stored URL).
const DELETE_STALE_COVER: &str = "\
    DELETE FROM covers WHERE feed_id = ?1 AND book_id = ?2 \
      AND EXISTS (SELECT 1 FROM books b \
                  WHERE b.feed_id = covers.feed_id AND b.book_id = covers.book_id \
                    AND b.cover_url IS NOT ?3)";

/// Upsert a freshly fetched [`BookInfo`].
///
/// When the stored `cover_url` differs from the incoming one the cover state
/// resets to `none` (and its timestamp to 0) so the next download claim
/// succeeds; an unchanged URL keeps the stored state — `downloaded` bytes
/// stay valid, and `failed`/`pending` keep their backoff/in-flight windows.
const UPSERT_FETCHED_BOOK: &str = "\
    INSERT INTO books (feed_id, book_id, title, author, description, cover_url, cover_state, cover_fetched_at_ms, info_fetched_at_ms, last_used_at_ms) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'none', 0, ?7, ?7) \
     ON CONFLICT(feed_id, book_id) DO UPDATE SET \
         title = excluded.title, \
         author = excluded.author, \
         description = excluded.description, \
         cover_url = excluded.cover_url, \
         cover_state = CASE WHEN books.cover_url IS NOT excluded.cover_url \
                            THEN 'none' ELSE books.cover_state END, \
         cover_fetched_at_ms = CASE WHEN books.cover_url IS NOT excluded.cover_url \
                                    THEN 0 ELSE books.cover_fetched_at_ms END, \
         info_fetched_at_ms = excluded.info_fetched_at_ms, \
         last_used_at_ms = excluded.last_used_at_ms";

/// Claim the cover download slot for a book — the single decision point for
/// whether a (re-)download is due:
///
/// * `none` with a `cover_url` — never attempted (or reset by a URL change).
/// * `pending` older than the in-flight window — the app died mid-download.
/// * `failed` past its backoff — retry.
/// * `downloaded` without a `covers` row — drift (bytes lost behind the
///   state's back); repair by re-downloading.
///
/// Claiming writes `pending` atomically, so concurrent claims are
/// single-flight.
const CLAIM_COVER_DOWNLOAD: &str = "\
    UPDATE books SET cover_state = 'pending', cover_fetched_at_ms = ?3 \
     WHERE feed_id = ?1 AND book_id = ?2 \
       AND ( \
           (cover_state = 'none' AND cover_url IS NOT NULL) \
           OR (cover_state = 'pending' AND ?3 - cover_fetched_at_ms >= ?4) \
           OR (cover_state = 'failed' AND ?3 - cover_fetched_at_ms >= ?5) \
           OR (cover_state = 'downloaded' AND NOT EXISTS ( \
               SELECT 1 FROM covers c WHERE c.feed_id = books.feed_id AND c.book_id = books.book_id)))";

// ---------------------------------------------------------------------------
// Repo trait
// ---------------------------------------------------------------------------

/// Content-cache operations, as methods on [`Connection`].
pub trait CacheRepo {
    /// Ensure a `books` row exists (minimal placeholder) so cache tables
    /// have something to reference.
    fn ensure_book(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()>;

    /// Read the cached book row and refresh `last_used_at_ms`.
    ///
    /// Returns `None` when no row exists.
    fn get_book_and_touch(
        &self,
        feed_id: &str,
        book_id: &str,
        now_ms: i64,
    ) -> Result<Option<BookRow>>;

    /// Refresh `last_used_at_ms` for LRU accounting.
    fn touch_book(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()>;

    /// Persist a freshly fetched [`BookInfo`] (see [`UPSERT_FETCHED_BOOK`]).
    fn upsert_fetched_book(&self, feed_id: &str, info: &BookInfo, now_ms: i64) -> Result<()>;

    /// Overwrite the display fields of a placeholder row from a
    /// search-result snapshot. Only rows with `info_fetched_at_ms = 0` are
    /// touched — fetched data always wins over a search snapshot.
    #[allow(clippy::too_many_arguments)]
    fn upsert_snapshot(
        &self,
        feed_id: &str,
        book_id: &str,
        title: &str,
        author: &str,
        description: Option<&str>,
        cover_url: Option<&str>,
        now_ms: i64,
    ) -> Result<()>;

    /// Read the stored cover bytes for a book, with the recorded MIME type.
    fn get_cover_bytes(&self, feed_id: &str, book_id: &str) -> Result<Option<(String, Vec<u8>)>>;

    /// Store downloaded cover bytes and mark the state `downloaded`.
    fn set_cover(
        &self,
        feed_id: &str,
        book_id: &str,
        mime: &str,
        bytes: &[u8],
        now_ms: i64,
    ) -> Result<()>;

    /// Set the cover state and its timestamp (e.g. `failed`).
    fn mark_cover(
        &self,
        feed_id: &str,
        book_id: &str,
        state: CoverState,
        now_ms: i64,
    ) -> Result<()>;

    /// Atomically claim the cover download slot (see
    /// [`CLAIM_COVER_DOWNLOAD`]). Returns `false` when another download is
    /// in flight, the cover is already stored, or the failure backoff has
    /// not elapsed — the caller must skip.
    fn claim_cover_download(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<bool>;

    /// Drop the stored cover bytes (the `books` row and its state remain).
    fn delete_cover(&self, feed_id: &str, book_id: &str) -> Result<()>;

    /// Read the cached chapter list, if present and not older than the TTL.
    fn get_chapter_list(
        &self,
        feed_id: &str,
        book_id: &str,
        now_ms: i64,
    ) -> Result<Option<Vec<ChapterInfo>>>;

    fn set_chapter_list(
        &self,
        feed_id: &str,
        book_id: &str,
        chapters: &[ChapterInfo],
        now_ms: i64,
    ) -> Result<()>;

    fn delete_chapter_list(&self, feed_id: &str, book_id: &str) -> Result<()>;

    /// Read cached chapter paragraphs and refresh `last_used_at_ms`.
    fn get_paragraphs(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
        now_ms: i64,
    ) -> Result<Option<Vec<Paragraph>>>;

    fn set_paragraphs(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
        paragraphs: &[Paragraph],
        now_ms: i64,
    ) -> Result<()>;

    fn delete_paragraphs(&self, feed_id: &str, book_id: &str, chapter_id: &str) -> Result<()>;
}

impl CacheRepo for Connection {
    fn ensure_book(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()> {
        self.prepare_cached(
            "INSERT OR IGNORE INTO books (feed_id, book_id, title, author, last_used_at_ms) \
             VALUES (?1, ?2, ?2, '', ?3)",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
        Ok(())
    }

    fn get_book_and_touch(
        &self,
        feed_id: &str,
        book_id: &str,
        now_ms: i64,
    ) -> Result<Option<BookRow>> {
        let row = super::maybe_row(
            self,
            &format!("SELECT {BOOK_COLUMNS} FROM books WHERE feed_id = ?1 AND book_id = ?2"),
            &[&feed_id, &book_id],
            map_book_row,
        )?;
        if row.is_some() {
            self.touch_book(feed_id, book_id, now_ms)?;
        }
        Ok(row)
    }

    fn touch_book(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<()> {
        self.prepare_cached(
            "UPDATE books SET last_used_at_ms = ?3 WHERE feed_id = ?1 AND book_id = ?2",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
        Ok(())
    }

    fn upsert_fetched_book(&self, feed_id: &str, info: &BookInfo, now_ms: i64) -> Result<()> {
        self.prepare_cached(DELETE_STALE_COVER)?
            .execute(tokio_rusqlite::params![feed_id, info.id, info.cover_url])?;
        self.prepare_cached(UPSERT_FETCHED_BOOK)?
            .execute(tokio_rusqlite::params![
                feed_id,
                info.id,
                info.title,
                info.author,
                info.description,
                info.cover_url,
                now_ms,
            ])?;
        Ok(())
    }

    fn upsert_snapshot(
        &self,
        feed_id: &str,
        book_id: &str,
        title: &str,
        author: &str,
        description: Option<&str>,
        cover_url: Option<&str>,
        now_ms: i64,
    ) -> Result<()> {
        self.prepare_cached(DELETE_STALE_COVER)?
            .execute(tokio_rusqlite::params![feed_id, book_id, cover_url])?;
        self.prepare_cached(
            "INSERT INTO books (feed_id, book_id, title, author, description, cover_url, cover_state, cover_fetched_at_ms, info_fetched_at_ms, last_used_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'none', 0, 0, ?7) \
             ON CONFLICT(feed_id, book_id) DO UPDATE SET \
                 title = CASE WHEN books.info_fetched_at_ms = 0 THEN excluded.title ELSE books.title END, \
                 author = CASE WHEN books.info_fetched_at_ms = 0 THEN excluded.author ELSE books.author END, \
                 description = CASE WHEN books.info_fetched_at_ms = 0 THEN excluded.description ELSE books.description END, \
                 cover_url = CASE WHEN books.info_fetched_at_ms = 0 THEN excluded.cover_url ELSE books.cover_url END, \
                 cover_state = CASE WHEN books.info_fetched_at_ms = 0 AND books.cover_url IS NOT excluded.cover_url \
                                    THEN 'none' ELSE books.cover_state END, \
                 cover_fetched_at_ms = CASE WHEN books.info_fetched_at_ms = 0 AND books.cover_url IS NOT excluded.cover_url \
                                            THEN 0 ELSE books.cover_fetched_at_ms END, \
                 last_used_at_ms = CASE WHEN books.info_fetched_at_ms = 0 THEN excluded.last_used_at_ms ELSE books.last_used_at_ms END",
        )?
        .execute(tokio_rusqlite::params![
            feed_id,
            book_id,
            title,
            author,
            description,
            cover_url,
            now_ms,
        ])?;
        Ok(())
    }

    fn get_cover_bytes(&self, feed_id: &str, book_id: &str) -> Result<Option<(String, Vec<u8>)>> {
        super::maybe_row(
            self,
            "SELECT mime, bytes FROM covers WHERE feed_id = ?1 AND book_id = ?2",
            &[&feed_id, &book_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
        )
    }

    fn set_cover(
        &self,
        feed_id: &str,
        book_id: &str,
        mime: &str,
        bytes: &[u8],
        now_ms: i64,
    ) -> Result<()> {
        self.prepare_cached(
            "INSERT INTO covers (feed_id, book_id, mime, bytes, fetched_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(feed_id, book_id) DO UPDATE SET \
                 mime = excluded.mime, bytes = excluded.bytes, fetched_at_ms = excluded.fetched_at_ms",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, mime, bytes, now_ms])?;
        self.prepare_cached(
            "UPDATE books SET cover_state = 'downloaded', cover_fetched_at_ms = ?3 \
             WHERE feed_id = ?1 AND book_id = ?2",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
        Ok(())
    }

    fn mark_cover(
        &self,
        feed_id: &str,
        book_id: &str,
        state: CoverState,
        now_ms: i64,
    ) -> Result<()> {
        self.prepare_cached(
            "UPDATE books SET cover_state = ?3, cover_fetched_at_ms = ?4 \
             WHERE feed_id = ?1 AND book_id = ?2",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, state, now_ms])?;
        Ok(())
    }

    fn claim_cover_download(&self, feed_id: &str, book_id: &str, now_ms: i64) -> Result<bool> {
        let claimed = self
            .prepare_cached(CLAIM_COVER_DOWNLOAD)?
            .execute(tokio_rusqlite::params![
                feed_id,
                book_id,
                now_ms,
                COVER_INFLIGHT_RETRY_MS,
                COVER_FAILED_RETRY_MS,
            ])?;
        Ok(claimed > 0)
    }

    fn delete_cover(&self, feed_id: &str, book_id: &str) -> Result<()> {
        self.prepare_cached("DELETE FROM covers WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        Ok(())
    }

    fn get_chapter_list(
        &self,
        feed_id: &str,
        book_id: &str,
        now_ms: i64,
    ) -> Result<Option<Vec<ChapterInfo>>> {
        let cached = super::maybe_row(
            self,
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
                    decode_json("chapter list", &json).inspect_err(|_| {
                        // Drop the broken row so the next call re-fetches.
                        let _ = self.delete_chapter_list(feed_id, book_id);
                    })?;
                self.touch_book(feed_id, book_id, now_ms)?;
                Ok(Some(chapters))
            }
            _ => Ok(None),
        }
    }

    fn set_chapter_list(
        &self,
        feed_id: &str,
        book_id: &str,
        chapters: &[ChapterInfo],
        now_ms: i64,
    ) -> Result<()> {
        self.ensure_book(feed_id, book_id, now_ms)?;
        let json = serde_json::to_string(chapters)
            .map_err(|e| Error::database(format!("serialize chapter list: {e}")))?;
        self.prepare_cached(
            "INSERT INTO chapter_lists (feed_id, book_id, chapters_json, cached_at_ms) \
             VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(feed_id, book_id) DO UPDATE SET \
                 chapters_json = excluded.chapters_json, cached_at_ms = excluded.cached_at_ms",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, json, now_ms])?;
        self.touch_book(feed_id, book_id, now_ms)?;
        Ok(())
    }

    fn delete_chapter_list(&self, feed_id: &str, book_id: &str) -> Result<()> {
        self.prepare_cached("DELETE FROM chapter_lists WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        Ok(())
    }

    fn get_paragraphs(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
        now_ms: i64,
    ) -> Result<Option<Vec<Paragraph>>> {
        let json = super::maybe_row(
            self,
            "SELECT paragraphs_json FROM chapters \
             WHERE feed_id = ?1 AND book_id = ?2 AND chapter_id = ?3",
            &[&feed_id, &book_id, &chapter_id],
            |row| row.get::<_, String>(0),
        )?;
        match json {
            Some(json) => {
                let paragraphs: Vec<Paragraph> =
                    decode_json("chapter paragraphs", &json).inspect_err(|_| {
                        // Drop the broken row so the next call re-fetches.
                        let _ = self.delete_paragraphs(feed_id, book_id, chapter_id);
                    })?;
                self.touch_book(feed_id, book_id, now_ms)?;
                Ok(Some(paragraphs))
            }
            None => Ok(None),
        }
    }

    fn set_paragraphs(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
        paragraphs: &[Paragraph],
        now_ms: i64,
    ) -> Result<()> {
        self.ensure_book(feed_id, book_id, now_ms)?;
        let json = serde_json::to_string(paragraphs)
            .map_err(|e| Error::database(format!("serialize paragraphs: {e}")))?;
        self.prepare_cached(
            "INSERT INTO chapters (feed_id, book_id, chapter_id, paragraphs_json, cached_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(feed_id, book_id, chapter_id) DO UPDATE SET \
                 paragraphs_json = excluded.paragraphs_json, cached_at_ms = excluded.cached_at_ms",
        )?
        .execute(tokio_rusqlite::params![
            feed_id,
            book_id,
            chapter_id,
            json,
            now_ms
        ])?;
        self.touch_book(feed_id, book_id, now_ms)?;
        Ok(())
    }

    fn delete_paragraphs(&self, feed_id: &str, book_id: &str, chapter_id: &str) -> Result<()> {
        self.prepare_cached(
            "DELETE FROM chapters WHERE feed_id = ?1 AND book_id = ?2 AND chapter_id = ?3",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, chapter_id])?;
        Ok(())
    }
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

    /// Read `books.cover_state` directly as a [`CoverState`] (exercises the
    /// `FromSql` impl).
    fn state(conn: &Connection, book_id: &str) -> CoverState {
        conn.query_row(
            "SELECT cover_state FROM books WHERE feed_id = 'f1' AND book_id = ?1",
            [book_id],
            |row| row.get(0),
        )
        .expect("read cover_state")
    }

    #[test]
    fn fetched_book_roundtrip() {
        let conn = conn();
        let now = now_ms();
        conn.upsert_fetched_book("f1", &info("b1", Some("https://c")), now)
            .expect("upsert");
        let row = conn
            .get_book_and_touch("f1", "b1", now)
            .expect("get")
            .expect("row");
        assert_eq!(row.title, "Book b1");
        assert!(row.is_fetched());
        assert_eq!(row.cover_url.as_deref(), Some("https://c"));
        assert_eq!(state(&conn, "b1"), CoverState::None);
    }

    #[test]
    fn claim_decides_whether_a_download_is_due() {
        let conn = conn();
        let now = now_ms();

        // Fresh row with a cover URL → due.
        conn.upsert_fetched_book("f1", &info("b1", Some("u1")), now)
            .unwrap();
        assert!(conn.claim_cover_download("f1", "b1", now).unwrap());
        // Claimed → pending; a second claim is single-flighted away.
        assert!(!conn.claim_cover_download("f1", "b1", now + 1000).unwrap());
        assert_eq!(state(&conn, "b1"), CoverState::Pending);

        // Completed download → not due again…
        conn.set_cover("f1", "b1", "image/jpeg", b"junk", now + 2000)
            .unwrap();
        assert_eq!(state(&conn, "b1"), CoverState::Downloaded);
        assert!(!conn.claim_cover_download("f1", "b1", now + 3000).unwrap());
        // …not even after a re-fetch with the same URL.
        conn.upsert_fetched_book("f1", &info("b1", Some("u1")), now + 4000)
            .unwrap();
        assert_eq!(state(&conn, "b1"), CoverState::Downloaded);
        assert!(!conn.claim_cover_download("f1", "b1", now + 5000).unwrap());

        // A failed download is not retried within the backoff window…
        conn.mark_cover("f1", "b1", CoverState::Failed, now + 6000)
            .unwrap();
        assert!(!conn.claim_cover_download("f1", "b1", now + 7000).unwrap());
        // …but is retried after 7 days.
        assert!(
            conn.claim_cover_download("f1", "b1", now + 6000 + COVER_FAILED_RETRY_MS + 1)
                .unwrap()
        );
    }

    #[test]
    fn url_change_resets_state_and_drops_bytes() {
        let conn = conn();
        let now = now_ms();

        conn.upsert_fetched_book("f1", &info("b1", Some("u1")), now)
            .unwrap();
        conn.set_cover("f1", "b1", "image/jpeg", b"junk", now + 1000)
            .unwrap();
        assert_eq!(state(&conn, "b1"), CoverState::Downloaded);

        // A different URL resets the state and removes the stale bytes.
        conn.upsert_fetched_book("f1", &info("b1", Some("u2")), now + 2000)
            .unwrap();
        assert_eq!(state(&conn, "b1"), CoverState::None);
        assert_eq!(conn.get_cover_bytes("f1", "b1").unwrap(), None);
        assert!(conn.claim_cover_download("f1", "b1", now + 3000).unwrap());

        // The site dropping the cover also resets and clears the bytes.
        conn.set_cover("f1", "b1", "image/jpeg", b"junk", now + 4000)
            .unwrap();
        conn.upsert_fetched_book("f1", &info("b1", None), now + 5000)
            .unwrap();
        assert_eq!(state(&conn, "b1"), CoverState::None);
        assert_eq!(conn.get_cover_bytes("f1", "b1").unwrap(), None);
        // No URL → nothing to download.
        assert!(!conn.claim_cover_download("f1", "b1", now + 6000).unwrap());
    }

    #[test]
    fn claim_repairs_downloaded_state_without_bytes() {
        let conn = conn();
        let now = now_ms();
        conn.upsert_fetched_book("f1", &info("b1", Some("u1")), now)
            .unwrap();
        conn.set_cover("f1", "b1", "image/jpeg", b"junk", now + 1000)
            .unwrap();

        // Simulate drift: the covers row disappears behind the state's back.
        conn.execute("DELETE FROM covers", []).unwrap();
        assert!(conn.claim_cover_download("f1", "b1", now + 2000).unwrap());
    }

    #[test]
    fn stale_pending_is_retried_after_inflight_window() {
        let conn = conn();
        let now = now_ms();
        conn.upsert_fetched_book("f1", &info("b1", Some("u1")), now)
            .unwrap();
        assert!(conn.claim_cover_download("f1", "b1", now).unwrap());

        // The claim is single-flight while the download is considered
        // in-flight…
        assert!(!conn.claim_cover_download("f1", "b1", now + 1000).unwrap());
        // …and eligible again after the window (crashed download).
        assert!(
            conn.claim_cover_download("f1", "b1", now + COVER_INFLIGHT_RETRY_MS + 1)
                .unwrap()
        );
    }

    #[test]
    fn cover_state_sql_roundtrip() {
        let conn = conn();
        let now = now_ms();
        for wanted in [
            CoverState::None,
            CoverState::Pending,
            CoverState::Downloaded,
            CoverState::Failed,
        ] {
            conn.upsert_fetched_book("f1", &info("b1", Some("u")), now)
                .unwrap();
            conn.mark_cover("f1", "b1", wanted, now).unwrap();
            assert_eq!(state(&conn, "b1"), wanted);
        }
    }

    #[test]
    fn snapshot_only_refreshes_placeholders() {
        let conn = conn();
        let now = now_ms();

        conn.upsert_snapshot("f1", "b1", "Snap", "A", Some("d"), Some("u1"), now)
            .expect("snapshot");
        let row = conn.get_book_and_touch("f1", "b1", now).unwrap().unwrap();
        assert_eq!(row.title, "Snap");
        assert!(!row.is_fetched());

        // A real fetch lands…
        conn.upsert_fetched_book("f1", &info("b1", Some("u2")), now + 10)
            .unwrap();
        // …and a later snapshot must NOT clobber it.
        conn.upsert_snapshot("f1", "b1", "Stale", "B", None, None, now + 20)
            .unwrap();
        let row = conn.get_book_and_touch("f1", "b1", now + 30).unwrap().unwrap();
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
        conn.set_chapter_list("f1", "b1", &chapters, now).expect("set");

        let fresh = conn
            .get_chapter_list("f1", "b1", now + 1000)
            .expect("get")
            .expect("fresh");
        assert_eq!(fresh.len(), 1);

        // After the TTL the row is reported as a miss…
        assert!(
            conn.get_chapter_list("f1", "b1", now + CHAPTER_LIST_TTL_MS + 1)
                .expect("get")
                .is_none()
        );
        // …and a re-set refreshes it.
        conn.set_chapter_list("f1", "b1", &chapters, now + CHAPTER_LIST_TTL_MS + 2)
            .expect("re-set");
        assert!(
            conn.get_chapter_list("f1", "b1", now + CHAPTER_LIST_TTL_MS + 3)
                .expect("get")
                .is_some()
        );
    }

    #[test]
    fn paragraphs_roundtrip_and_delete() {
        let conn = conn();
        let now = now_ms();
        conn.set_paragraphs("f1", "b1", "c1", &paragraphs(), now)
            .expect("set");

        let loaded = conn
            .get_paragraphs("f1", "b1", "c1", now + 1)
            .expect("get")
            .expect("some");
        assert_eq!(loaded.len(), 2);

        conn.delete_paragraphs("f1", "b1", "c1").expect("delete");
        assert!(conn
            .get_paragraphs("f1", "b1", "c1", now + 2)
            .expect("get")
            .is_none());
    }
}
