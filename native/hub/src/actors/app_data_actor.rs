use std::path::Path;

use async_trait::async_trait;
use langhuan::db::Db;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::BridgeError;

use super::bookmark_actor::BookmarkActor;
use super::bookshelf_actor::BookshelfActor;
use super::login_actor::LoginActor;
use super::reading_progress_actor::ReadingProgressActor;
use super::registry_actor::{ListFeeds, RegistryActor};

/// Hands a clone of the application database to a storage actor. Sent by the
/// [`AppDataActor`] after it opened the database successfully.
pub struct InitializeAppDataDirectory {
    pub db: Db,
}

/// Result returned on successful app-data initialization.
pub struct AppDataInitResult {
    pub feed_count: u32,
}

pub struct AppDataActor {
    registry_addr: Address<RegistryActor>,
    login_addr: Address<LoginActor>,
    bookshelf_addr: Address<BookshelfActor>,
    reading_progress_addr: Address<ReadingProgressActor>,
    bookmark_addr: Address<BookmarkActor>,
    app_data_dir: Option<String>,
}

impl Actor for AppDataActor {}

impl AppDataActor {
    pub fn new(
        registry_addr: Address<RegistryActor>,
        login_addr: Address<LoginActor>,
        bookshelf_addr: Address<BookshelfActor>,
        reading_progress_addr: Address<ReadingProgressActor>,
        bookmark_addr: Address<BookmarkActor>,
    ) -> Self {
        Self {
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
            bookmark_addr,
            app_data_dir: None,
        }
    }

    async fn set_data_directory(&mut self, path: String) -> Result<AppDataInitResult, BridgeError> {
        tracing::info!(path = %path, "initializing app data directory");

        if let Some(dir) = &self.app_data_dir {
            if *dir == path {
                // A new Flutter engine (activity recreation after a config
                // change) re-runs the Dart bootstrap and re-sends the same
                // app-data path. The actor tree and database survive the
                // engine swap and are already bound to this directory, so
                // succeed idempotently with the registry's current feed
                // count.
                tracing::debug!(
                    "app data directory already initialized — reporting live feed count"
                );
                let feed_count = self.registry_addr.send(ListFeeds).await?.len() as u32;
                return Ok(AppDataInitResult { feed_count });
            }
            tracing::warn!("app data directory already set to another path — ignoring");
            return Err(BridgeError::from(
                t!("error.app_data_reload_not_supported").to_string(),
            ));
        }

        // One database for everything: registry, cache, bookshelf, progress,
        // bookmarks, and auth.
        let db_path = Path::new(&path).join("langhuan.db");
        let db = Db::open(&db_path).await?;
        tracing::info!(path = %db_path.display(), "database opened");

        // The registry compiles every installed script (this also validates
        // that the stored scripts still load under the current engine).
        let registry_result = self
            .registry_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await??;

        self.login_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await??;

        self.bookshelf_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await??;

        self.reading_progress_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await??;

        self.bookmark_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await??;

        // Feed script storage: hydrate the read cache from the new
        // database and start the async writer (the script engine holds the
        // singleton). Before this point no feed can run — feeds live in
        // the database — so storage calls cannot precede the attach.
        crate::feed_storage::FeedStorage::shared()
            .attach(db.clone())
            .await?;

        // Publish the handle for the api layer (covers, stats, maintenance).
        if crate::actors::set_hub_db(db.clone()).is_err() {
            tracing::warn!("database handle already published — ignoring duplicate");
        }

        // Startup maintenance, throttled to once per 24 h inside the task.
        tokio::spawn({
            let db = db.clone();
            async move {
                if let Err(e) = langhuan::db::maintenance::run_maintenance(&db, false).await {
                    tracing::warn!(error = %e, "startup maintenance failed");
                }
            }
        });

        tracing::info!(
            feed_count = registry_result.feed_count,
            "app data directory initialized"
        );

        self.app_data_dir = Some(path);

        Ok(AppDataInitResult {
            feed_count: registry_result.feed_count,
        })
    }
}

/// Message: set the app data directory (called from FRB API).
pub struct SetAppDataDirectory {
    pub path: String,
}

#[async_trait]
impl Handler<SetAppDataDirectory> for AppDataActor {
    type Result = Result<AppDataInitResult, BridgeError>;

    async fn handle(&mut self, msg: SetAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.set_data_directory(msg.path).await
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io;

    use langhuan::script::runtime::ScriptEngine;
    use messages::prelude::Context;
    use tokio::spawn;

    use super::super::bookmark_actor::BookmarkActor;
    use super::super::bookshelf_actor::BookshelfActor;
    use super::super::login_actor::LoginActor;
    use super::super::reading_progress_actor::ReadingProgressActor;
    use super::super::registry_actor::RegistryActor;
    use super::super::webview_actor::WebviewActor;
    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    async fn spawn_actor_tree(dir: &std::path::Path) -> AppDataActor {
        let registry_context: Context<RegistryActor> = Context::new();
        let registry_addr = registry_context.address();
        let bookshelf_context: Context<BookshelfActor> = Context::new();
        let bookshelf_addr = bookshelf_context.address();
        let app_data_context: Context<AppDataActor> = Context::new();
        let _app_data_addr = app_data_context.address();
        let login_context: Context<LoginActor> = Context::new();
        let login_addr = login_context.address();
        let reading_progress_context: Context<ReadingProgressActor> = Context::new();
        let reading_progress_addr = reading_progress_context.address();
        let bookmark_context: Context<BookmarkActor> = Context::new();
        let bookmark_addr = bookmark_context.address();
        let webview_context: Context<WebviewActor> = Context::new();
        let webview_addr = webview_context.address();

        let registry_actor = RegistryActor::new(ScriptEngine::new(), webview_addr);
        let login_actor = LoginActor::new(registry_addr.clone());
        let bookshelf_actor = BookshelfActor::new();
        let reading_progress_actor = ReadingProgressActor::new();
        let bookmark_actor = BookmarkActor::new();
        let app_data_actor = AppDataActor::new(
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
            bookmark_addr,
        );

        spawn(registry_context.run(registry_actor));
        spawn(webview_context.run(WebviewActor::new()));
        spawn(login_context.run(login_actor));
        spawn(bookshelf_context.run(bookshelf_actor));
        spawn(reading_progress_context.run(reading_progress_actor));
        spawn(bookmark_context.run(bookmark_actor));

        let _ = dir;
        app_data_actor
    }

    #[tokio::test]
    async fn set_app_data_directory_creates_single_sqlite_database() -> TestResult {
        let dir = tempfile::tempdir()?;
        let mut actor = spawn_actor_tree(dir.path()).await;

        let result = actor
            .set_data_directory(dir.path().to_string_lossy().into_owned())
            .await;

        let result = result.map_err(|e| io::Error::other(e.message))?;
        assert_eq!(result.feed_count, 0);
        // Everything lives in one database file now.
        assert!(dir.path().join("langhuan.db").is_file());

        // Re-initializing with the same directory — as happens when Android
        // recreates the activity and the new Flutter engine re-runs the Dart
        // bootstrap — must succeed idempotently, reporting the registry's
        // live feed count.
        let result = actor
            .set_data_directory(dir.path().to_string_lossy().into_owned())
            .await;
        let result = result.map_err(|e| io::Error::other(e.message))?;
        assert_eq!(result.feed_count, 0);

        // A different directory still cannot be loaded at runtime.
        let other = tempfile::tempdir()?;
        assert!(
            actor
                .set_data_directory(other.path().to_string_lossy().into_owned())
                .await
                .is_err()
        );
        Ok(())
    }

    #[tokio::test]
    async fn set_app_data_directory_reports_unusable_path() -> TestResult {
        let dir = tempfile::tempdir()?;
        // A plain file cannot host a database file beneath it.
        let blocked_path = dir.path().join("blocked");
        std::fs::write(&blocked_path, "file")?;

        let mut actor = spawn_actor_tree(dir.path()).await;
        let result = actor
            .set_data_directory(blocked_path.to_string_lossy().into_owned())
            .await;

        match result {
            Err(e) => {
                assert!(!e.message.is_empty());
            }
            Ok(_) => panic!("expected error for blocked path"),
        }
        Ok(())
    }

    #[tokio::test]
    async fn invalid_feed_does_not_fail_or_poison_app_bootstrap() -> TestResult {
        let dir = tempfile::tempdir()?;
        let db_path = dir.path().join("langhuan.db");
        let db = Db::open(&db_path).await?;
        let meta = langhuan::feed::FeedMeta {
            id: "legacy-feed".to_owned(),
            name: "Legacy Feed".to_owned(),
            version: "1.0.0".to_owned(),
            author: None,
            description: None,
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        };
        db.write(move |repo| {
            repo.upsert_feed(&meta, None, "legacy-hash", 1)?;
            repo.upsert_script(
                "legacy-feed",
                "1.0.0",
                "legacy-hash",
                "-- legacy Lua feed",
                1,
            )
        })
        .await?;
        drop(db);

        let mut actor = spawn_actor_tree(dir.path()).await;
        let path = dir.path().to_string_lossy().into_owned();

        let result = actor.set_data_directory(path.clone()).await;
        let result = result.map_err(|e| io::Error::other(e.message))?;
        assert_eq!(result.feed_count, 0);

        // The invalid source remains visible with its per-feed error instead
        // of preventing the feed list from leaving its loading state.
        let feeds = actor.registry_addr.send(ListFeeds).await?;
        assert_eq!(feeds.len(), 1);
        assert!(feeds[0].error.is_some());

        // A repeated Flutter bootstrap is idempotent, rather than trying to
        // initialize the already-live registry again.
        actor
            .set_data_directory(path)
            .await
            .map_err(|e| io::Error::other(e.message))?;
        Ok(())
    }
}
