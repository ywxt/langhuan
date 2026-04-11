use async_trait::async_trait;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::BridgeError;

use super::bookshelf_actor::BookshelfActor;
use super::login_actor::LoginActor;
use super::reading_progress_actor::ReadingProgressActor;
use super::registry_actor::RegistryActor;

pub struct InitializeAppDataDirectory {
    pub path: String,
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
    app_data_dir: Option<String>,
}

impl Actor for AppDataActor {}

impl AppDataActor {
    pub fn new(
        registry_addr: Address<RegistryActor>,
        login_addr: Address<LoginActor>,
        bookshelf_addr: Address<BookshelfActor>,
        reading_progress_addr: Address<ReadingProgressActor>,
    ) -> Self {
        Self {
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
            app_data_dir: None,
        }
    }

    async fn set_data_directory(&mut self, path: String) -> Result<AppDataInitResult, BridgeError> {
        tracing::info!(path = %path, "initializing app data directory");

        if self.app_data_dir.is_some() {
            tracing::warn!("app data directory already set — ignoring");
            return Err(BridgeError::from(
                t!("error.app_data_reload_not_supported").to_string(),
            ));
        }

        let registry_result = self
            .registry_addr
            .send(InitializeAppDataDirectory { path: path.clone() })
            .await??;

        self.login_addr
            .send(InitializeAppDataDirectory { path: path.clone() })
            .await??;

        self.bookshelf_addr
            .send(InitializeAppDataDirectory { path: path.clone() })
            .await??;

        self.reading_progress_addr
            .send(InitializeAppDataDirectory { path: path.clone() })
            .await??;

        tracing::info!(
            feed_count = registry_result.feed_count,
            "app data directory initialized"
        );

        if let Some(message) = registry_result.warning_message {
            return Err(BridgeError::from(message));
        }

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

    use super::super::bookshelf_actor::BookshelfActor;
    use super::super::login_actor::LoginActor;
    use super::super::reading_progress_actor::ReadingProgressActor;
    use super::super::registry_actor::RegistryActor;
    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn set_app_data_directory_initializes_scripts_and_bookshelf_dirs() -> TestResult {
        let dir = tempfile::tempdir()?;

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

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let login_actor = LoginActor::new(registry_addr.clone());
        let bookshelf_actor = BookshelfActor::new(registry_addr.clone());
        let reading_progress_actor = ReadingProgressActor::new();
        let app_data_actor = AppDataActor::new(
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
        );

        spawn(registry_context.run(registry_actor));
        spawn(login_context.run(login_actor));
        spawn(bookshelf_context.run(bookshelf_actor));
        spawn(reading_progress_context.run(reading_progress_actor));

        let mut actor = app_data_actor;
        let result = actor
            .set_data_directory(dir.path().to_string_lossy().into_owned())
            .await;

        let result = result.map_err(|e| io::Error::other(e.message))?;
        assert_eq!(result.feed_count, 0);
        assert!(dir.path().join("scripts").is_dir());
        assert!(dir.path().join("scripts/registry.json").is_file());
        assert!(dir.path().join("bookshelf").is_dir());
        assert!(dir.path().join("progress").is_dir());
        Ok(())
    }

    #[tokio::test]
    async fn set_app_data_directory_returns_bookshelf_error() -> TestResult {
        let dir = tempfile::tempdir()?;
        let blocked_path = dir.path().join("blocked");
        std::fs::write(&blocked_path, "file")?;

        let registry_context: Context<RegistryActor> = Context::new();
        let registry_addr = registry_context.address();
        let bookshelf_context: Context<BookshelfActor> = Context::new();
        let bookshelf_addr = bookshelf_context.address();
        let login_context: Context<LoginActor> = Context::new();
        let login_addr = login_context.address();
        let reading_progress_context: Context<ReadingProgressActor> = Context::new();
        let reading_progress_addr = reading_progress_context.address();

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let login_actor = LoginActor::new(registry_addr.clone());
        let bookshelf_actor = BookshelfActor::new(registry_addr.clone());
        let reading_progress_actor = ReadingProgressActor::new();
        let app_data_actor = AppDataActor::new(
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
        );

        spawn(registry_context.run(registry_actor));
        spawn(login_context.run(login_actor));
        spawn(bookshelf_context.run(bookshelf_actor));
        spawn(reading_progress_context.run(reading_progress_actor));

        let mut actor = app_data_actor;
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
}
