//! `meta` — small key-value metadata (e.g. `last_cleanup_ms`).

use super::Repo;

use crate::error::Result;

const GET: &str = "SELECT value FROM meta WHERE key = ?1";
const SET: &str = "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value";

impl Repo<'_> {
    pub fn get_meta(&self, key: &str) -> Result<Option<String>> {
        super::maybe_row(self.conn, GET, &[&key], |row| row.get(0))
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.conn.prepare_cached(SET)?.execute([key, value])?;
        Ok(())
    }

    /// Read a numeric metadata value; `default` when missing or malformed.
    pub fn get_meta_i64(&self, key: &str, default: i64) -> Result<i64> {
        Ok(self
            .get_meta(key)?
            .and_then(|v| v.parse().ok())
            .unwrap_or(default))
    }
}

#[cfg(test)]
mod tests {
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn set_get_roundtrip() {
        let db = TestDb::new();
        let conn = db.repo();
        conn.set_meta("k", "v").expect("set");
        assert_eq!(conn.get_meta("k").expect("get").as_deref(), Some("v"));

        conn.set_meta("k", "v2").expect("overwrite");
        assert_eq!(conn.get_meta("k").expect("get").as_deref(), Some("v2"));
    }

    #[test]
    fn missing_key_returns_none() {
        let db = TestDb::new();
        assert_eq!(db.repo().get_meta("nope").expect("get"), None);
    }

    #[test]
    fn get_meta_i64_defaults() {
        let db = TestDb::new();
        let conn = db.repo();
        assert_eq!(conn.get_meta_i64("n", 7).expect("get"), 7);
        conn.set_meta("n", "42").expect("set");
        assert_eq!(conn.get_meta_i64("n", 7).expect("get"), 42);
    }
}
