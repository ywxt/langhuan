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
            "SELECT rules_json FROM transformer_configurations WHERE feed_id IS NULL",
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
            "SELECT feed_id, book_id, inherit_application, rules_json FROM transformer_configurations WHERE feed_id = ?1 AND book_id = ?2",
            &[&feed_id, &book_id],
            BookTransformerRow::from_row,
        )
    }

    pub fn list_book_transformers(&self) -> Result<Vec<BookTransformerRow>> {
        let mut query = self.conn.prepare_cached("SELECT feed_id, book_id, inherit_application, rules_json FROM transformer_configurations WHERE feed_id IS NOT NULL ORDER BY feed_id, book_id")?;
        Ok(query
            .query_map([], BookTransformerRow::from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn set_application_transformers(&self, rules_json: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO transformer_configurations (feed_id, book_id, inherit_application, rules_json) VALUES (NULL, NULL, 0, ?1) ON CONFLICT DO UPDATE SET rules_json = excluded.rules_json",
            [rules_json],
        )?;
        Ok(())
    }

    /// Returns false if the source no longer exists. Never restores a deleted
    /// source's settings from an old import or an in-flight editor.
    pub fn set_book_transformers(&self, book: &BookTransformerRow) -> Result<bool> {
        let changed = self.conn.execute(
            "INSERT INTO transformer_configurations (feed_id, book_id, inherit_application, rules_json) SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM feeds WHERE id = ?1) ON CONFLICT(feed_id, book_id) WHERE feed_id IS NOT NULL DO UPDATE SET inherit_application = excluded.inherit_application, rules_json = excluded.rules_json",
            params![book.feed_id, book.book_id, book.inherit_application, book.rules_json],
        )?;
        Ok(changed != 0)
    }

    pub fn delete_book_transformers(&self, feed_id: &str, book_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM transformer_configurations WHERE feed_id = ?1 AND book_id = ?2",
            params![feed_id, book_id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn unified_scope_constraints_reject_duplicates_and_malformed_rows() {
        let db = TestDb::new();
        db.conn().execute_batch("PRAGMA foreign_keys=ON;").unwrap();
        db.seed_feed("f");
        let insert = "INSERT INTO transformer_configurations (feed_id, book_id, inherit_application, rules_json) VALUES (?1, ?2, ?3, ?4)";
        db.conn()
            .execute(insert, params![None::<String>, None::<String>, 0, "[]"])
            .unwrap();
        assert!(
            db.conn()
                .execute(insert, params![None::<String>, None::<String>, 0, "[]"])
                .is_err()
        );
        db.conn()
            .execute(insert, params!["f", "b", 1, "[]"])
            .unwrap();
        assert!(
            db.conn()
                .execute(insert, params!["f", "b", 0, "[]"])
                .is_err()
        );
        for (feed, book, inherit, rules) in [
            (Some("f"), None, 0, "[]"),
            (None, Some("b"), 0, "[]"),
            (None, None, 1, "[]"),
            (Some(""), Some("b"), 0, "[]"),
            (Some("f"), Some(""), 0, "[]"),
            (Some("f"), Some("other"), 2, "[]"),
            (Some("f"), Some("other"), 0, "{}"),
            (Some("f"), Some("other"), 0, "broken"),
            (Some("missing"), Some("b"), 0, "[]"),
        ] {
            assert!(
                db.conn()
                    .execute(insert, params![feed, book, inherit, rules])
                    .is_err()
            );
        }
    }

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
        repo.set_application_transformers("[]").unwrap();
        for book in &books {
            repo.set_book_transformers(book).unwrap();
        }
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
        repo.set_application_transformers("[]").unwrap();
        for book in &books {
            repo.set_book_transformers(book).unwrap();
        }
        assert!(repo.list_book_transformers().unwrap().is_empty());
    }
}
