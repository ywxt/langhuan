use async_trait::async_trait;
use messages::prelude::{Actor, Address, Context, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::signals::{AppDataDirectorySet, SetAppDataDirectory};

use super::bookshelf_actor::BookshelfActor;
use super::login_actor::LoginActor;
use super::reading_progress_actor::ReadingProgressActor;
use super::registry_actor::RegistryActor;

pub struct InitializeAppDataDirectory {
    pub path: String,
}

pub struct AppDataActor {
    registry_addr: Address<RegistryActor>,
    login_addr: Address<LoginActor>,
    bookshelf_addr: Address<BookshelfActor>,
    reading_progress_addr: Address<ReadingProgressActor>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for AppDataActor {}

impl AppDataActor {
    pub fn new(
        self_addr: Address<Self>,
        registry_addr: Address<RegistryActor>,
        login_addr: Address<LoginActor>,
        bookshelf_addr: Address<BookshelfActor>,
        reading_progress_addr: Address<ReadingProgressActor>,
    ) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_set_directory(self_addr));
        Self {
            registry_addr,
            login_addr,
            bookshelf_addr,
            reading_progress_addr,
            _owned_tasks,
        }
    }

    fn handle_init_result<T, E>(
        result: Result<Result<T, String>, E>,
        fallback_message: impl Into<String>,
    ) -> Result<T, AppDataDirectorySet> {
        match result {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(message)) => Err(AppDataDirectorySet::error(message)),
            Err(_) => Err(AppDataDirectorySet::error(fallback_message.into())),
        }
    }

    async fn set_data_directory(&mut self, req: SetAppDataDirectory) -> AppDataDirectorySet {
        tracing::info!(path = %req.path, "initializing app data directory");
        let app_data_dir_error = t!("error.app_data_dir_not_set");
        let bookshelf_error = t!("error.bookshelf_unavailable");
        let app_data_path = req.path;

        let registry_result = match Self::handle_init_result(
            self.registry_addr
                .send(InitializeAppDataDirectory {
                    path: app_data_path.clone(),
                })
                .await,
            app_data_dir_error.as_ref(),
        ) {
            Ok(result) => result,
            Err(result) => {
                tracing::warn!("failed to initialize registry actor storage");
                return result;
            }
        };

        if let Err(result) = Self::handle_init_result(
            self.login_addr
                .send(InitializeAppDataDirectory {
                    path: app_data_path.clone(),
                })
                .await,
            app_data_dir_error.as_ref(),
        ) {
            tracing::warn!("failed to initialize login actor storage");
            return result;
        }

        if let Err(result) = Self::handle_init_result(
            self.bookshelf_addr
                .send(InitializeAppDataDirectory {
                    path: app_data_path.clone(),
                })
                .await,
            bookshelf_error.as_ref(),
        ) {
            tracing::warn!("failed to initialize bookshelf actor storage");
            return result;
        }

        match Self::handle_init_result(
            self.reading_progress_addr
                .send(InitializeAppDataDirectory {
                    path: app_data_path,
                })
                .await,
            app_data_dir_error,
        ) {
            Ok(()) => {
                tracing::info!(
                    feed_count = registry_result.feed_count,
                    "app data directory initialized"
                );
                match registry_result.warning_message {
                    None => AppDataDirectorySet::success(registry_result.feed_count),
                    Some(message) => AppDataDirectorySet::error(message),
                }
            }
            Err(result) => {
                tracing::warn!("failed to initialize reading progress actor storage");
                result
            }
        }
    }

    async fn listen_to_set_directory(mut self_addr: Address<Self>) {
        let receiver = SetAppDataDirectory::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }
}

#[async_trait]
impl Notifiable<SetAppDataDirectory> for AppDataActor {
    async fn notify(&mut self, message: SetAppDataDirectory, _: &Context<Self>) {
        tracing::debug!(path = %message.path, "received app data directory request");
        self.set_data_directory(message).await.send_signal_to_dart();
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io;

    use crate::signals::AppDataDirectoryOutcome;
    use langhuan::script::runtime::ScriptEngine;
    use messages::prelude::Context;
    use tokio::spawn;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn set_app_data_directory_initializes_scripts_and_bookshelf_dirs() -> TestResult {
        let dir = tempfile::tempdir()?;

        let registry_context = Context::new();
        let registry_addr = registry_context.address();
        let bookshelf_context = Context::new();
        let bookshelf_addr = bookshelf_context.address();
        let app_data_context = Context::new();
        let app_data_addr = app_data_context.address();
        let login_context = Context::new();
        let login_addr = login_context.address();
        let reading_progress_context = Context::new();
        let reading_progress_addr = reading_progress_context.address();

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let login_actor = LoginActor::new(login_addr.clone(), registry_addr.clone());
        let bookshelf_actor = BookshelfActor::new(bookshelf_addr.clone(), registry_addr.clone());
        let reading_progress_actor = ReadingProgressActor::new(reading_progress_addr.clone());
        let app_data_actor = AppDataActor::new(
            app_data_addr,
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
            .set_data_directory(SetAppDataDirectory {
                path: dir.path().to_string_lossy().into_owned(),
            })
            .await;

        assert!(matches!(
            result.outcome,
            AppDataDirectoryOutcome::Success { feed_count: 0 }
        ));
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

        let registry_context = Context::new();
        let registry_addr = registry_context.address();
        let bookshelf_context = Context::new();
        let bookshelf_addr = bookshelf_context.address();
        let app_data_context = Context::new();
        let app_data_addr = app_data_context.address();
        let login_context = Context::new();
        let login_addr = login_context.address();
        let reading_progress_context = Context::new();
        let reading_progress_addr = reading_progress_context.address();

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let login_actor = LoginActor::new(login_addr.clone(), registry_addr.clone());
        let bookshelf_actor = BookshelfActor::new(bookshelf_addr.clone(), registry_addr.clone());
        let reading_progress_actor = ReadingProgressActor::new(reading_progress_addr.clone());
        let app_data_actor = AppDataActor::new(
            app_data_addr,
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
            .set_data_directory(SetAppDataDirectory {
                path: blocked_path.to_string_lossy().into_owned(),
            })
            .await;

        match result.outcome {
            AppDataDirectoryOutcome::Error { message } => {
                assert!(!message.is_empty());
                Ok(())
            }
            _ => Err(io::Error::other("expected error outcome").into()),
        }
    }
}
