use super::types::{
    BookTransformerConfiguration, BridgeError, ChineseConversionMode, TransformerConfiguration,
    TransformerConfigurationEntry, TransformerRule,
};
use crate::actors::hub_db;
use langhuan::transform::{
    TransformChain,
    dedup_title::DedupTitleTransform,
    opencc::{ConversionMode, OpenCcTransform},
    regex::RegexTransform,
    text_indent::TextIndentTransform,
};
use langhuan::{
    db::{
        Db,
        repo::{BookTransformerRow, Repo},
    },
    error::Error,
};
use std::collections::HashSet;

impl Default for TransformerConfiguration {
    fn default() -> Self {
        Self {
            application: vec![
                TransformerRule::DeduplicateTitles,
                TransformerRule::ParagraphIndent { spaces: 2 },
            ]
            .into_iter()
            .map(|rule| TransformerConfigurationEntry {
                name: String::new(),
                enabled: true,
                rule,
            })
            .collect(),
            books: vec![],
        }
    }
}

/// Read persisted user settings; `None` allows a one-time preferences import.
pub async fn get_transformer_configuration() -> Result<Option<TransformerConfiguration>, BridgeError>
{
    TransformerConfigurationStore::new(hub_db()?).load().await
}

/// Atomically create settings if absent. Existing database settings always win.
pub async fn initialize_transformer_configuration(
    configuration: Option<TransformerConfiguration>,
) -> Result<TransformerConfiguration, BridgeError> {
    TransformerConfigurationStore::new(hub_db()?)
        .initialize(configuration.unwrap_or_default())
        .await
}

/// Update only the application chain; book scopes remain unchanged.
pub async fn save_application_transformers(
    rules: Vec<TransformerConfigurationEntry>,
) -> Result<(), BridgeError> {
    TransformerConfigurationStore::new(hub_db()?)
        .save_application(rules)
        .await
}

/// Update only one book's ordered rules and inheritance setting.
pub async fn save_book_transformers(
    configuration: BookTransformerConfiguration,
) -> Result<(), BridgeError> {
    TransformerConfigurationStore::new(hub_db()?)
        .save_book(configuration)
        .await
}

/// Remove one book override, restoring application inheritance.
pub async fn delete_book_transformers(feed_id: String, book_id: String) -> Result<(), BridgeError> {
    TransformerConfigurationStore::new(hub_db()?)
        .delete_book(feed_id, book_id)
        .await
}

/// Persistence boundary for transformer settings. An explicit database handle
/// keeps storage operations testable without global actor initialization.
pub(crate) struct TransformerConfigurationStore {
    db: Db,
}

impl TransformerConfigurationStore {
    pub(crate) fn new(db: Db) -> Self {
        Self { db }
    }

    pub(crate) async fn load(&self) -> Result<Option<TransformerConfiguration>, BridgeError> {
        Ok(self
            .db
            .call(TransformerConfiguration::from_repository)
            .await?)
    }

    pub(crate) async fn initialize(
        &self,
        configuration: TransformerConfiguration,
    ) -> Result<TransformerConfiguration, BridgeError> {
        if let Some(existing) = self.load().await? {
            return Ok(existing);
        }
        configuration.validate()?;
        let (application, books) = configuration.encoded_rows()?;
        Ok(self
            .db
            .write(move |repo| {
                if let Some(existing) = TransformerConfiguration::from_repository(repo)? {
                    return Ok(existing);
                }
                repo.set_application_transformers(&application)?;
                for book in &books {
                    repo.set_book_transformers(book)?;
                }
                TransformerConfiguration::from_repository(repo)?.ok_or_else(|| {
                    Error::database(
                        "transformer initialization did not persist application settings",
                    )
                })
            })
            .await?)
    }

    pub(crate) async fn save_application(
        &self,
        rules: Vec<TransformerConfigurationEntry>,
    ) -> Result<(), BridgeError> {
        let json = TransformerConfiguration::encode_rules(&rules)?;
        self.db
            .write(move |repo| {
                // Validate inherited effective chains against this exact transaction
                // snapshot. Independent book chains are unaffected by an app edit.
                let books = repo
                    .list_book_transformers()?
                    .into_iter()
                    .filter(|book| book.inherit_application)
                    .map(BookTransformerConfiguration::try_from)
                    .collect::<langhuan::error::Result<Vec<_>>>()?;
                let configuration = TransformerConfiguration {
                    application: rules,
                    books,
                };
                if let Err(error) = configuration.validate() {
                    return Ok(Err(error));
                }
                repo.set_application_transformers(&json)?;
                Ok(Ok(()))
            })
            .await?
    }

    pub(crate) async fn save_book(
        &self,
        book: BookTransformerConfiguration,
    ) -> Result<(), BridgeError> {
        let row = book.encoded_row()?;
        self.db
            .write(move |repo| {
                let application = repo.get_application_transformers()?;
                let rules = application
                    .as_deref()
                    .map(TransformerConfiguration::decode_rules)
                    .transpose()?
                    .unwrap_or_else(|| TransformerConfiguration::default().application);
                let configuration = TransformerConfiguration {
                    application: rules,
                    books: vec![book],
                };
                if let Err(error) = configuration.validate() {
                    return Ok(Err(error));
                }
                if !repo.set_book_transformers(&row)? {
                    return Err(Error::feed_not_found(row.feed_id));
                }
                if application.is_none() {
                    repo.set_application_transformers(&TransformerConfiguration::encode_rules(
                        &configuration.application,
                    )?)?;
                }
                Ok(Ok(()))
            })
            .await?
    }

    pub(crate) async fn delete_book(
        &self,
        feed_id: String,
        book_id: String,
    ) -> Result<(), BridgeError> {
        self.db
            .write(move |repo| repo.delete_book_transformers(&feed_id, &book_id))
            .await?;
        Ok(())
    }

    /// Only the application and requested book scopes are read for a chapter.
    pub(crate) async fn rules_for_book(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Vec<TransformerRule>, BridgeError> {
        let feed_id = feed_id.to_owned();
        let book_id = book_id.to_owned();
        Ok(self
            .db
            .call(move |repo| {
                let application = repo
                    .get_application_transformers()?
                    .map(|json| TransformerConfiguration::decode_rules(&json))
                    .transpose()?
                    .unwrap_or_else(|| TransformerConfiguration::default().application);
                let book = repo
                    .get_book_transformers(&feed_id, &book_id)?
                    .map(BookTransformerConfiguration::try_from)
                    .transpose()?;
                Ok(TransformerConfiguration {
                    application,
                    books: vec![],
                }
                .effective_rules(book.as_ref()))
            })
            .await?)
    }
}

impl TryFrom<BookTransformerRow> for BookTransformerConfiguration {
    type Error = Error;
    fn try_from(row: BookTransformerRow) -> Result<Self, Self::Error> {
        Ok(Self {
            feed_id: row.feed_id,
            book_id: row.book_id,
            inherit_application: row.inherit_application,
            rules: TransformerConfiguration::decode_rules(&row.rules_json)?,
        })
    }
}

impl BookTransformerConfiguration {
    fn encoded_row(&self) -> langhuan::error::Result<BookTransformerRow> {
        Ok(BookTransformerRow {
            feed_id: self.feed_id.clone(),
            book_id: self.book_id.clone(),
            inherit_application: self.inherit_application,
            rules_json: TransformerConfiguration::encode_rules(&self.rules)?,
        })
    }
}

impl TransformerConfigurationEntry {
    fn active_rule(&self) -> Option<TransformerRule> {
        self.enabled.then(|| self.rule.clone())
    }
}

impl TransformerConfiguration {
    fn decode_rules(json: &str) -> langhuan::error::Result<Vec<TransformerConfigurationEntry>> {
        serde_json::from_str(json)
            .map_err(|e| Error::database(format!("corrupt transformer rules: {e}")))
    }

    fn from_repository(repo: &Repo<'_>) -> langhuan::error::Result<Option<Self>> {
        let Some(application) = repo.get_application_transformers()? else {
            return Ok(None);
        };
        Ok(Some(Self {
            application: Self::decode_rules(&application)?,
            books: repo
                .list_book_transformers()?
                .into_iter()
                .map(BookTransformerConfiguration::try_from)
                .collect::<langhuan::error::Result<_>>()?,
        }))
    }

    fn encode_rules(rules: &[TransformerConfigurationEntry]) -> langhuan::error::Result<String> {
        serde_json::to_string(rules)
            .map_err(|error| Error::database(format!("serialize transformer rules: {error}")))
    }

    fn encoded_rows(&self) -> Result<(String, Vec<BookTransformerRow>), BridgeError> {
        Ok((
            Self::encode_rules(&self.application)?,
            self.books
                .iter()
                .map(BookTransformerConfiguration::encoded_row)
                .collect::<langhuan::error::Result<_>>()?,
        ))
    }

    fn effective_rules(&self, book: Option<&BookTransformerConfiguration>) -> Vec<TransformerRule> {
        let mut rules = if book.is_none_or(|book| book.inherit_application) {
            self.application
                .iter()
                .filter_map(TransformerConfigurationEntry::active_rule)
                .collect()
        } else {
            vec![]
        };
        if let Some(book) = book {
            rules.extend(
                book.rules
                    .iter()
                    .filter_map(TransformerConfigurationEntry::active_rule),
            );
        }
        rules
    }

    pub(crate) fn validate(&self) -> Result<(), BridgeError> {
        build_transform_chain(self.effective_rules(None))?;
        let mut keys = HashSet::new();
        for book in &self.books {
            if book.feed_id.is_empty()
                || book.book_id.is_empty()
                || !keys.insert((&book.feed_id, &book.book_id))
            {
                return Err(BridgeError::from(
                    "Book transformer scopes must be non-empty and unique".to_string(),
                ));
            }
            build_transform_chain(self.effective_rules(Some(book)))?;
        }
        Ok(())
    }
}

impl From<ChineseConversionMode> for ConversionMode {
    fn from(mode: ChineseConversionMode) -> Self {
        match mode {
            ChineseConversionMode::None => Self::None,
            ChineseConversionMode::S2t => Self::S2t,
            ChineseConversionMode::T2s => Self::T2s,
            ChineseConversionMode::S2tw => Self::S2tw,
            ChineseConversionMode::S2hk => Self::S2hk,
        }
    }
}

impl TransformerRule {
    pub(crate) fn into_transform(
        self,
    ) -> Result<Box<dyn langhuan::transform::ParagraphTransform>, BridgeError> {
        Ok(match self {
            Self::ParagraphIndent { spaces } => {
                if spaces > 8 {
                    return Err(BridgeError::from(
                        "Indentation must be between 0 and 8 characters".to_string(),
                    ));
                }
                Box::new(TextIndentTransform::with_spaces(spaces))
            }
            Self::DeduplicateTitles => Box::new(DedupTitleTransform::new()),
            Self::ChineseConversion { mode } => Box::new(OpenCcTransform::new(mode.into())),
            Self::RegexReplace {
                pattern,
                replacement,
                include_titles,
            } => Box::new(
                RegexTransform::new(&pattern, Some(replacement), include_titles)
                    .map_err(BridgeError::from)?,
            ),
            Self::RegexDelete {
                pattern,
                include_titles,
            } => Box::new(
                RegexTransform::new(&pattern, None, include_titles).map_err(BridgeError::from)?,
            ),
        })
    }
}

/// Validate using the same regex engine and limits as chapter processing.
pub async fn validate_transformers(rules: Vec<TransformerRule>) -> Result<(), BridgeError> {
    build_transform_chain(rules).map(|_| ())
}

pub(crate) fn build_transform_chain(
    rules: Vec<TransformerRule>,
) -> Result<TransformChain, BridgeError> {
    if rules.len() > 64 {
        return Err(BridgeError::from(
            "At most 64 active transformers are supported".to_string(),
        ));
    }
    let mut chain = TransformChain::new();
    for rule in rules {
        chain.push(rule.into_transform()?);
    }
    Ok(chain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use langhuan::model::{Paragraph, ParagraphId};

    async fn seed_scope_feeds(db: &Db) {
        db.write(|repo| {
            for id in ["feed-a", "feed-b"] {
                let meta = langhuan::feed::FeedMeta {
                    id: id.into(),
                    name: id.into(),
                    version: "1.0.0".into(),
                    author: None,
                    description: None,
                    base_url: "https://example.com".into(),
                    access_domains: Default::default(),
                    schema_version: 6,
                };
                repo.upsert_feed(&meta, None, "hash", 1)?;
            }
            Ok(())
        })
        .await
        .unwrap();
    }

    fn configuration() -> TransformerConfiguration {
        TransformerConfiguration {
            application: vec![TransformerConfigurationEntry {
                name: "Application conversion".into(),
                enabled: true,
                rule: TransformerRule::ChineseConversion {
                    mode: ChineseConversionMode::S2t,
                },
            }],
            books: vec![
                BookTransformerConfiguration {
                    feed_id: "feed-a".into(),
                    book_id: "book".into(),
                    inherit_application: true,
                    rules: vec![TransformerConfigurationEntry {
                        name: "Remove ads".into(),
                        enabled: false,
                        rule: TransformerRule::RegexDelete {
                            pattern: "advertisement".into(),
                            include_titles: false,
                        },
                    }],
                },
                BookTransformerConfiguration {
                    feed_id: "feed-b".into(),
                    book_id: "book".into(),
                    inherit_application: false,
                    rules: vec![TransformerConfigurationEntry {
                        name: "Indent".into(),
                        enabled: true,
                        rule: TransformerRule::ParagraphIndent { spaces: 4 },
                    }],
                },
            ],
        }
    }

    #[tokio::test]
    async fn database_configuration_survives_cache_cleanup_reopen_and_backup() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("app.db");
        let backup = directory.path().join("backup.db");
        let db = Db::open(&path).await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let expected = configuration();
        store.initialize(expected.clone()).await.unwrap();
        langhuan::db::maintenance::clear_cache(&db).await.unwrap();
        let backup_path = backup.to_str().unwrap().to_owned();
        db.call(move |repo| repo.vacuum_into(&backup_path))
            .await
            .unwrap();
        drop(store);
        drop(db);
        for file in [&path, &backup] {
            let reopened = TransformerConfigurationStore::new(Db::open(file).await.unwrap());
            assert_eq!(reopened.load().await.unwrap(), Some(expected.clone()));
            assert_eq!(
                reopened.rules_for_book("feed-a", "book").await.unwrap(),
                vec![TransformerRule::ChineseConversion {
                    mode: ChineseConversionMode::S2t
                }]
            );
            assert_eq!(
                reopened.rules_for_book("feed-b", "book").await.unwrap(),
                vec![TransformerRule::ParagraphIndent { spaces: 4 }]
            );
        }
    }

    #[tokio::test]
    async fn migration_initializes_once_and_never_overwrites_database_settings() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        assert!(store.load().await.unwrap().is_none());
        let initial = configuration();
        assert_eq!(store.initialize(initial.clone()).await.unwrap(), initial);
        assert_eq!(
            store
                .initialize(TransformerConfiguration::default())
                .await
                .unwrap(),
            initial
        );
        let invalid = TransformerConfiguration {
            application: vec![TransformerConfigurationEntry {
                name: "Invalid import".into(),
                enabled: true,
                rule: TransformerRule::RegexDelete {
                    pattern: "[".into(),
                    include_titles: false,
                },
            }],
            books: vec![],
        };
        assert_eq!(store.initialize(invalid).await.unwrap(), initial);
    }

    #[tokio::test]
    async fn failed_validation_preserves_the_previous_configuration() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let initial = store.initialize(configuration()).await.unwrap();
        let mut invalid = initial.clone();
        invalid.books[1].rules[0].rule = TransformerRule::ParagraphIndent { spaces: 9 };
        assert!(store.save_book(invalid.books.remove(1)).await.is_err());
        assert_eq!(store.load().await.unwrap(), Some(initial));
    }

    #[tokio::test]
    async fn competing_imports_commit_one_complete_snapshot() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let (first, second) = tokio::join!(
            store.initialize(configuration()),
            store.initialize(TransformerConfiguration::default()),
        );
        let first = first.unwrap();
        assert_eq!(first, second.unwrap());
        assert_eq!(store.load().await.unwrap(), Some(first));
    }

    #[tokio::test]
    async fn scoped_updates_never_rewrite_other_books_and_delete_resets_one_override() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let initial = store.initialize(configuration()).await.unwrap();
        db.write(|repo| {
            repo.conn().execute_batch("CREATE TRIGGER protect_other_update BEFORE UPDATE ON transformer_configurations WHEN OLD.feed_id = 'feed-b' BEGIN SELECT RAISE(ABORT, 'unrelated book updated'); END; CREATE TRIGGER protect_other_delete BEFORE DELETE ON transformer_configurations WHEN OLD.feed_id = 'feed-b' BEGIN SELECT RAISE(ABORT, 'unrelated book deleted'); END;")?;
            Ok(())
        }).await.unwrap();
        let mut book = initial.books[0].clone();
        book.inherit_application = false;
        book.rules.clear();
        store.save_book(book.clone()).await.unwrap();
        store.save_application(vec![]).await.unwrap();
        let saved = store.load().await.unwrap().unwrap();
        assert!(saved.application.is_empty());
        assert_eq!(saved.books, vec![book, initial.books[1].clone()]);
        store
            .save_application(initial.application.clone())
            .await
            .unwrap();
        store
            .delete_book("feed-a".into(), "book".into())
            .await
            .unwrap();
        let reset = store.load().await.unwrap().unwrap();
        assert_eq!(reset.books, vec![initial.books[1].clone()]);
        assert_eq!(
            store.rules_for_book("feed-a", "book").await.unwrap(),
            vec![TransformerRule::ChineseConversion {
                mode: ChineseConversionMode::S2t
            }]
        );
        let removed = BookTransformerConfiguration {
            feed_id: "removed".into(),
            book_id: "book".into(),
            inherit_application: true,
            rules: vec![],
        };
        assert!(store.save_book(removed).await.is_err());
        assert_eq!(store.load().await.unwrap(), Some(reset));
    }

    #[tokio::test]
    async fn first_book_edit_initializes_defaults_only_after_a_valid_write() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let mut book = configuration().books.remove(0);
        book.rules = vec![TransformerConfigurationEntry {
            name: String::new(),
            enabled: true,
            rule: TransformerRule::ParagraphIndent { spaces: 9 },
        }];
        assert!(store.save_book(book.clone()).await.is_err());
        assert!(store.load().await.unwrap().is_none());
        book.rules.clear();
        store.save_book(book.clone()).await.unwrap();
        let saved = store.load().await.unwrap().unwrap();
        assert_eq!(
            saved.application,
            TransformerConfiguration::default().application
        );
        assert_eq!(saved.books, vec![book]);
        assert_eq!(store.initialize(configuration()).await.unwrap(), saved);
        let invalid_app = vec![TransformerConfigurationEntry {
            name: String::new(),
            enabled: true,
            rule: TransformerRule::RegexDelete {
                pattern: "[".into(),
                include_titles: false,
            },
        }];
        assert!(store.save_application(invalid_app).await.is_err());
        assert_eq!(store.load().await.unwrap(), Some(saved));
    }

    #[tokio::test]
    async fn concurrent_scoped_writes_preserve_all_completed_updates() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        let mut expected = store.initialize(configuration()).await.unwrap();
        expected.application.clear();
        expected.books[0].inherit_application = false;
        expected.books[0].rules.clear();
        expected.books[1].rules[0].name = "Updated book".into();
        let (application, first, second) = tokio::join!(
            store.save_application(expected.application.clone()),
            store.save_book(expected.books[0].clone()),
            store.save_book(expected.books[1].clone()),
        );
        application.unwrap();
        first.unwrap();
        second.unwrap();
        assert_eq!(store.load().await.unwrap(), Some(expected));
    }

    #[tokio::test]
    async fn concurrent_scope_validation_enforces_the_combined_chain_limit() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        store
            .initialize(TransformerConfiguration {
                application: vec![],
                books: vec![],
            })
            .await
            .unwrap();
        let rule = TransformerConfigurationEntry {
            name: String::new(),
            enabled: true,
            rule: TransformerRule::DeduplicateTitles,
        };
        let book = BookTransformerConfiguration {
            feed_id: "feed-a".into(),
            book_id: "book".into(),
            inherit_application: true,
            rules: vec![rule.clone()],
        };
        let (application, book) = tokio::join!(
            store.save_application(vec![rule; 64]),
            store.save_book(book)
        );
        assert_ne!(application.is_ok(), book.is_ok());
        let stored = store.load().await.unwrap().unwrap();
        stored.validate().unwrap();
        assert!(store.rules_for_book("feed-a", "book").await.unwrap().len() <= 64);
    }

    #[tokio::test]
    async fn scoped_rule_reads_do_not_decode_unrelated_books() {
        let db = Db::open_in_memory().await.unwrap();
        seed_scope_feeds(&db).await;
        let store = TransformerConfigurationStore::new(db.clone());
        store.initialize(configuration()).await.unwrap();
        db.write(|repo| {
            repo.conn().execute(
                "UPDATE transformer_configurations SET rules_json = '[{}]' WHERE feed_id = 'feed-b'",
                [],
            )?;
            Ok(())
        })
        .await
        .unwrap();
        assert_eq!(
            store.rules_for_book("feed-a", "book").await.unwrap().len(),
            1
        );
        assert!(store.rules_for_book("feed-b", "book").await.is_err());
    }

    fn text(value: &str) -> Paragraph {
        Paragraph::Text {
            id: ParagraphId::source("source-paragraph".into()),
            content: value.into(),
            comment_count: Some(7),
            layout: Default::default(),
        }
    }

    #[test]
    fn ordered_rules_convert_then_replace_then_remove_whole_paragraphs() {
        let mut chain = build_transform_chain(vec![
            TransformerRule::ChineseConversion {
                mode: ChineseConversionMode::S2t,
            },
            TransformerRule::RegexReplace {
                pattern: "广告|廣告".into(),
                replacement: "移除".into(),
                include_titles: false,
            },
            TransformerRule::RegexDelete {
                pattern: "移除".into(),
                include_titles: false,
            },
        ])
        .unwrap();
        chain.init("chapter");
        assert!(chain.apply(text("这里是广告")).is_empty());
        let output = chain.apply(text("这是正文"));
        assert!(
            matches!(&output[0], Paragraph::Text { content, id, comment_count: Some(7), .. }
            if content == "這是正文" && id.source_id() == Some("source-paragraph"))
        );
    }

    #[test]
    fn text_and_layout_rules_compose_without_inserting_spaces() {
        let original = text("鼠标旧文字");
        let mut chain = build_transform_chain(vec![
            TransformerRule::ParagraphIndent { spaces: 4 },
            TransformerRule::ChineseConversion {
                mode: ChineseConversionMode::S2t,
            },
            TransformerRule::RegexReplace {
                pattern: "舊".into(),
                replacement: "新".into(),
                include_titles: false,
            },
            TransformerRule::ParagraphIndent { spaces: 2 },
        ])
        .unwrap();
        let result = chain.apply(original.clone());
        assert!(
            matches!(&result[0], Paragraph::Text { content, layout, id, comment_count: Some(7) }
            if content == "鼠標新文字" && layout.first_line_indent == 2 && id == original.id())
        );
        let bridge = crate::api::types::ParagraphContent::from(result[0].clone());
        assert!(
            matches!(bridge, crate::api::types::ParagraphContent::Text { content, layout, .. }
            if content == "鼠標新文字" && layout.first_line_indent == 2)
        );
    }

    #[test]
    fn empty_chain_is_raw_and_indentation_is_explicit() {
        let original = text("  正文");
        let mut empty = build_transform_chain(vec![]).unwrap();
        assert_eq!(empty.apply(original.clone()), vec![original.clone()]);
        let mut indented =
            build_transform_chain(vec![TransformerRule::ParagraphIndent { spaces: 4 }]).unwrap();
        assert!(
            matches!(&indented.apply(original.clone())[0], Paragraph::Text {content, layout, ..} if content == "正文" && layout.first_line_indent == 4)
        );
        let mut no_indent =
            build_transform_chain(vec![TransformerRule::ParagraphIndent { spaces: 0 }]).unwrap();
        assert!(
            matches!(&no_indent.apply(original)[0], Paragraph::Text {content, layout, ..} if content == "正文" && layout.first_line_indent == 0)
        );
        assert!(
            build_transform_chain(vec![TransformerRule::ParagraphIndent { spaces: 9 }]).is_err()
        );
    }

    #[test]
    fn changing_rule_order_changes_the_result() {
        let replacement = || TransformerRule::RegexReplace {
            pattern: "广告".into(),
            replacement: "正文".into(),
            include_titles: false,
        };
        let conversion = || TransformerRule::ChineseConversion {
            mode: ChineseConversionMode::S2t,
        };
        let mut first = build_transform_chain(vec![replacement(), conversion()]).unwrap();
        let mut second = build_transform_chain(vec![conversion(), replacement()]).unwrap();
        assert_ne!(first.apply(text("广告")), second.apply(text("广告")));
    }

    #[test]
    fn validation_rejects_invalid_patterns_and_excessive_rules() {
        assert!(
            build_transform_chain(vec![TransformerRule::RegexDelete {
                pattern: "[".into(),
                include_titles: false,
            }])
            .is_err()
        );
        let rules = (0..65)
            .map(|_| TransformerRule::ChineseConversion {
                mode: ChineseConversionMode::None,
            })
            .collect();
        assert!(build_transform_chain(rules).is_err());
    }
}
