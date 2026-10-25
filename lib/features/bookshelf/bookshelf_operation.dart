/// Expected result of adding a book to the local bookshelf.
///
/// Operational failures are thrown as exceptions and are deliberately not
/// represented here.
enum BookshelfAddResult { added, alreadyExists }

/// Expected result of removing a book from the local bookshelf.
///
/// Operational failures are thrown as exceptions and are deliberately not
/// represented here.
enum BookshelfRemoveResult { removed, notFound }
