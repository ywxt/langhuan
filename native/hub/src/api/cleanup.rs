use std::time::Duration;

use super::types::BridgeError;
use crate::actors::addresses;
use crate::actors::bookshelf_actor::GetProtectedBooks;
use crate::actors::reading_progress_actor::CleanupStaleProgress;
use crate::actors::registry_actor::CleanupStaleCache;

/// Default max age for stale data: 15 days.
const DEFAULT_MAX_AGE_DAYS: u64 = 15;

/// Clean up stale cache and reading progress data.
///
/// Removes cached book data and reading progress entries that are older than
/// 15 days, while preserving data for books currently on the bookshelf.
///
/// Returns the total number of items removed (cache directories + progress
/// entries).
pub async fn cleanup_stale_data() -> Result<u64, BridgeError> {
    let addrs = addresses()?;
    let max_age = Duration::from_hours(DEFAULT_MAX_AGE_DAYS * 24);

    // 1. Get the set of books on the bookshelf (protected from cleanup).
    let protected = addrs
        .bookshelf
        .clone()
        .send(GetProtectedBooks)
        .await??;

    // 2. Clean up stale cache directories.
    let cache_removed = addrs
        .registry
        .clone()
        .send(CleanupStaleCache {
            protected: protected.clone(),
            max_age,
        })
        .await??;

    // 3. Clean up stale reading progress entries.
    let progress_removed = addrs
        .reading_progress
        .clone()
        .send(CleanupStaleProgress {
            protected,
            max_age,
        })
        .await??;

    let total = cache_removed + progress_removed;
    tracing::info!(
        cache_removed,
        progress_removed,
        total,
        "stale data cleanup complete"
    );

    Ok(total)
}
