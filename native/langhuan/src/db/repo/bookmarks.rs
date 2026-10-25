//! `bookmarks` — user-created bookmarks, newest first.

use super::Repo;

use crate::error::Result;

#[derive(Debug, Clone)]
pub struct BookmarkRow {
    pub id: String,
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: String,
    pub paragraph_name: String,
    pub paragraph_preview: String,
    pub label: String,
    pub created_at_ms: i64,
}

impl Repo<'_> {
    pub fn add_bookmark(&self, row: &BookmarkRow) -> Result<()> {
        self.conn.prepare_cached(
            "INSERT INTO bookmarks (id, feed_id, book_id, chapter_id, paragraph_id, paragraph_name, paragraph_preview, label, created_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        )?
        .execute(tokio_rusqlite::params![
            row.id,
            row.feed_id,
            row.book_id,
            row.chapter_id,
            row.paragraph_id,
            row.paragraph_name,
            row.paragraph_preview,
            row.label,
            row.created_at_ms,
        ])?;
        Ok(())
    }

    /// Delete a bookmark by id. Returns `false` when it did not exist.
    pub fn remove_bookmark(&self, id: &str) -> Result<bool> {
        let deleted = self
            .conn
            .prepare_cached("DELETE FROM bookmarks WHERE id = ?1")?
            .execute([id])?;
        Ok(deleted > 0)
    }

    /// All bookmarks for one book, newest first.
    pub fn list_bookmarks(&self, feed_id: &str, book_id: &str) -> Result<Vec<BookmarkRow>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, feed_id, book_id, chapter_id, paragraph_id, paragraph_name, paragraph_preview, label, created_at_ms \
             FROM bookmarks WHERE feed_id = ?1 AND book_id = ?2 \
             ORDER BY created_at_ms DESC, id",
        )?;
        let rows = stmt
            .query_map([feed_id, book_id], |row| {
                Ok(BookmarkRow {
                    id: row.get(0)?,
                    feed_id: row.get(1)?,
                    book_id: row.get(2)?,
                    chapter_id: row.get(3)?,
                    paragraph_id: row.get(4)?,
                    paragraph_name: row.get(5)?,
                    paragraph_preview: row.get(6)?,
                    label: row.get(7)?,
                    created_at_ms: row.get(8)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;
    use crate::db::repo::test_support::TestDb;

    fn row(id: &str, at: i64) -> BookmarkRow {
        BookmarkRow {
            id: id.to_owned(),
            feed_id: "f1".to_owned(),
            book_id: "b1".to_owned(),
            chapter_id: "c1".to_owned(),
            paragraph_id: "p1".to_owned(),
            paragraph_name: "Name".to_owned(),
            paragraph_preview: "Preview".to_owned(),
            label: String::new(),
            created_at_ms: at,
        }
    }

    #[test]
    fn add_list_remove() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        let now = now_ms();
        conn.add_bookmark(&row("bm1", now)).unwrap();
        conn.add_bookmark(&row("bm2", now + 10)).unwrap();

        let items = conn.list_bookmarks("f1", "b1").unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "bm2"); // newest first
        assert!(conn.list_bookmarks("f1", "other").unwrap().is_empty());

        assert!(conn.remove_bookmark("bm1").unwrap());
        assert!(!conn.remove_bookmark("bm1").unwrap());
        assert_eq!(conn.list_bookmarks("f1", "b1").unwrap().len(), 1);
    }
}
