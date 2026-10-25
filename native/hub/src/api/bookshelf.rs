use super::types::{
    BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BookshelfUpdateItem,
    BridgeError,
};
use crate::actors::{
    addresses,
    bookshelf_actor::{BookshelfAdd, BookshelfList, BookshelfMarkSeen, BookshelfRemove},
    feed_actor::{OpenChaptersStream, PullStream, spawn_pull_stream},
    hub_db,
};

/// Add a book to the bookshelf.
///
/// The display snapshot (title/author/cover/description) is taken from the
/// search result or detail page the user is looking at, so the shelf renders
/// instantly even before the book info is (re-)fetched.
#[allow(clippy::too_many_arguments)]
pub async fn bookshelf_add(
    feed_id: String,
    source_book_id: String,
    title: String,
    author: String,
    cover_url: Option<String>,
    description: Option<String>,
) -> Result<BookshelfAddOutcome, BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfAdd {
            feed_id,
            source_book_id,
            title,
            author,
            cover_url,
            description,
        })
        .await?
}

pub async fn bookshelf_remove(
    feed_id: String,
    source_book_id: String,
) -> Result<BookshelfRemoveOutcome, BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfRemove {
            feed_id,
            source_book_id,
        })
        .await?
}

pub async fn bookshelf_list() -> Result<Vec<BookshelfListItem>, BridgeError> {
    addresses()?.bookshelf.clone().send(BookshelfList).await?
}

/// Record the chapter count the user has just seen (detail page or reader
/// chapter-list load) so the next update check can diff against it.
pub async fn mark_bookshelf_seen(
    feed_id: String,
    source_book_id: String,
    chapter_count: i64,
) -> Result<(), BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfMarkSeen {
            feed_id,
            source_book_id,
            chapter_count,
        })
        .await?
}

/// A pull-based stream of per-book update results.
pub struct BookshelfUpdatesStream(PullStream<BookshelfUpdateItem>);

impl BookshelfUpdatesStream {
    pub async fn next(&mut self) -> Result<Option<BookshelfUpdateItem>, BridgeError> {
        self.0.next().await
    }

    pub fn cancel(&mut self) {
        self.0.cancel();
    }
}

/// Check every shelved book for new chapters.
///
/// For each book (in shelf order): fetch a fresh chapter list from its source
/// (also refreshing the cache) and diff the count against the chapter count
/// the user last saw. A book that has never been seen adopts the fresh count
/// as its baseline without reporting an update. A failed book yields an item
/// with `error` set — the check continues with the remaining books.
pub async fn open_bookshelf_updates_stream() -> Result<BookshelfUpdatesStream, BridgeError> {
    // Snapshot the shelf before spawning: each result below is paired with
    // the last-seen count from this same snapshot. Books from paused feeds
    // are skipped — the check resumes for them when the feed is re-enabled.
    let (items, disabled_feeds) = hub_db()?
        .call(|repo| Ok((repo.shelf_items()?, repo.disabled_feed_ids()?)))
        .await?;
    let items: Vec<_> = items
        .into_iter()
        .filter(|item| !disabled_feeds.contains(&item.feed_id))
        .collect();

    let mut feed_addr = addresses()?.feed.clone();
    let db = hub_db()?;

    let stream = spawn_pull_stream(|tx| async move {
        for item in items {
            let mut result = BookshelfUpdateItem {
                feed_id: item.feed_id.clone(),
                source_book_id: item.book_id.clone(),
                new_chapters: 0,
                error: None,
            };

            let mut chapters = match feed_addr
                .send(OpenChaptersStream {
                    feed_id: item.feed_id.clone(),
                    book_id: item.book_id.clone(),
                    force_refresh: true,
                })
                .await
            {
                Ok(Ok(stream)) => stream,
                Ok(Err(e)) => {
                    result.error = Some(e.message);
                    let _ = tx.send(Ok(result)).await;
                    continue;
                }
                Err(e) => {
                    result.error = Some(e.to_string());
                    let _ = tx.send(Ok(result)).await;
                    continue;
                }
            };

            let mut fresh_count: i64 = 0;
            loop {
                match chapters.next().await {
                    Ok(Some(_)) => fresh_count += 1,
                    Ok(None) => break,
                    Err(e) => {
                        result.error = Some(e.message);
                        break;
                    }
                }
            }
            chapters.cancel();

            if result.error.is_none() {
                if item.last_seen_chapters < 0 {
                    // Never seen: adopt the fresh count as the baseline.
                    let (feed_id, book_id) = (item.feed_id.clone(), item.book_id.clone());
                    let _ = db
                        .write(move |repo| {
                            repo.set_last_seen_chapters(&feed_id, &book_id, fresh_count)
                        })
                        .await;
                    result.new_chapters = 0;
                } else {
                    result.new_chapters = (fresh_count - item.last_seen_chapters).max(0);
                }
            }

            if tx.send(Ok(result)).await.is_err() {
                return;
            }
        }
    });

    Ok(BookshelfUpdatesStream(stream))
}
