//! Scoped user transformer settings, independent of chapter/book caches.
use super::Repo;
use crate::error::Result;
use tokio_rusqlite::rusqlite::{Row, params};

#[derive(Debug, Clone)]
pub struct BookTransformerRow {
    pub feed_id: String,
    pub book_id: String,
    pub inherit_application: bool,
    pub rules_json: String,
}

impl BookTransformerRow {
    fn from_row(row: &Row<'_>) -> tokio_rusqlite::rusqlite::Result<Self> {
        Ok(Self {
            feed_id: row.get(0)?,
            book_id: row.get(1)?,
            inherit_application: row.get(2)?,
            rules_json: row.get(3)?,
        })
    }
}

impl Repo<'_> {
    pub fn get_application_transformers(&self) -> Result<Option<String>> {
        super::maybe_row(
            self.conn,
            "SELECT rules_json FROM application_transformers WHERE id = 1",
            &[],
            |row| row.get(0),
        )
    }

    pub fn get_book_transformers(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Option<BookTransformerRow>> {
        super::maybe_row(
            self.conn,
            "SELECT feed_id, book_id, inherit_application, rules_json FROM book_transformers WHERE feed_id = ?1 AND book_id = ?2",
            &[&feed_id, &book_id],
            BookTransformerRow::from_row,
        )
    }

    pub fn list_book_transformers(&self) -> Result<Vec<BookTransformerRow>> {
        let mut query = self.conn.prepare_cached("SELECT feed_id, book_id, inherit_application, rules_json FROM book_transformers ORDER BY feed_id, book_id")?;
        Ok(query
            .query_map([], BookTransformerRow::from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// Called within `Db::write`: commit the complete snapshot atomically.
    /// Ignore stale scopes of removed feeds; a settings snapshot must never
    /// recreate preferences that were deleted with their source.
    pub fn replace_transformer_configuration(
        &self,
        application: &str,
        books: &[BookTransformerRow],
    ) -> Result<()> {
        self.conn.execute("INSERT INTO application_transformers (id, rules_json) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET rules_json = excluded.rules_json", [application])?;
        self.conn.execute("DELETE FROM book_transformers", [])?;
        let mut insert = self.conn.prepare_cached("INSERT INTO book_transformers (feed_id, book_id, inherit_application, rules_json) SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM feeds WHERE id = ?1)")?;
        for book in books {
            insert.execute(params![
                book.feed_id,
                book.book_id,
                book.inherit_application,
                book.rules_json
            ])?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn book_scopes_survive_cache_cleanup_but_cascade_with_their_feed() {
        let db = TestDb::new();
        db.seed_feed("f");
        let repo = db.repo();
        assert!(repo.get_application_transformers().unwrap().is_none());
        let books = vec![BookTransformerRow {
            feed_id: "f".into(),
            book_id: "b".into(),
            inherit_application: false,
            rules_json: "[]".into(),
        }];
        repo.replace_transformer_configuration("[]", &books)
            .unwrap();
        repo.clear_cache().unwrap();
        assert!(
            !repo
                .get_book_transformers("f", "b")
                .unwrap()
                .unwrap()
                .inherit_application
        );
        repo.delete_feed("f").unwrap();
        assert!(repo.list_book_transformers().unwrap().is_empty());
        assert_eq!(
            repo.get_application_transformers().unwrap().as_deref(),
            Some("[]")
        );
        repo.replace_transformer_configuration("[]", &books)
            .unwrap();
        assert!(repo.list_book_transformers().unwrap().is_empty());
    }
}
