use async_trait::async_trait;
use messages::prelude::{Actor, Address, Context, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::signals::{
    AppDataDirectoryOutcome, AppDataDirectorySet, SetAppDataDirectory,
};

use super::bookshelf_actor::BookshelfActor;
use super::registry_actor::RegistryActor;

pub struct InitializeAppDataDirectory {
    pub path: String,
}

pub struct AppDataActor {
    registry_addr: Address<RegistryActor>,
    bookshelf_addr: Address<BookshelfActor>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for AppDataActor {}

impl AppDataActor {
    pub fn new(
        self_addr: Address<Self>,
        registry_addr: Address<RegistryActor>,
        bookshelf_addr: Address<BookshelfActor>,
    ) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_set_directory(self_addr));
        Self {
            registry_addr,
            bookshelf_addr,
            _owned_tasks,
        }
    }

    async fn set_data_directory(&mut self, req: SetAppDataDirectory) -> AppDataDirectorySet {
        let registry_result = match self
            .registry_addr
            .send(InitializeAppDataDirectory {
                path: req.path.clone(),
            })
            .await
        {
            Ok(Ok(result)) => result,
            Ok(Err(message)) => {
                return AppDataDirectorySet {
                    outcome: AppDataDirectoryOutcome::Error { message },
                };
            }
            Err(_) => {
                return AppDataDirectorySet {
                    outcome: AppDataDirectoryOutcome::Error {
                        message: t!("error.app_data_dir_not_set").to_string(),
                    },
                };
            }
        };

        match self
            .bookshelf_addr
            .send(InitializeAppDataDirectory { path: req.path })
            .await
        {
            Ok(Ok(())) => AppDataDirectorySet {
                outcome: match registry_result.warning_message {
                    None => AppDataDirectoryOutcome::Success {
                        feed_count: registry_result.feed_count,
                    },
                    Some(message) => AppDataDirectoryOutcome::Error { message },
                },
            },
            Ok(Err(message)) => AppDataDirectorySet {
                outcome: AppDataDirectoryOutcome::Error { message },
            },
            Err(_) => AppDataDirectorySet {
                outcome: AppDataDirectoryOutcome::Error {
                    message: t!("error.bookshelf_unavailable").to_string(),
                },
            },
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
        self.set_data_directory(message).await.send_signal_to_dart();
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io;

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

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let bookshelf_actor = BookshelfActor::new(bookshelf_addr.clone(), registry_addr.clone());
        let app_data_actor = AppDataActor::new(app_data_addr, registry_addr, bookshelf_addr);

        spawn(registry_context.run(registry_actor));
        spawn(bookshelf_context.run(bookshelf_actor));

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
        assert!(dir.path().join("scripts/registry.toml").is_file());
        assert!(dir.path().join("bookshelf").is_dir());
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

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        let bookshelf_actor = BookshelfActor::new(bookshelf_addr.clone(), registry_addr.clone());
        let app_data_actor = AppDataActor::new(app_data_addr, registry_addr, bookshelf_addr);

        spawn(registry_context.run(registry_actor));
        spawn(bookshelf_context.run(bookshelf_actor));

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