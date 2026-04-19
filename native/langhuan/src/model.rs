use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Paginated result (internal implementation detail)
// ---------------------------------------------------------------------------

/// A page of results with an opaque cursor for fetching the next page.
///
/// This type is used internally by [`LuaFeed`] to drive pagination.  Callers
/// of the public [`Feed`] trait never see `Page` — they receive a stream of
/// individual items instead.
///
/// `next_cursor` is determined entirely by the Lua feed script:
/// - `None` means this is the last page.
/// - `Some(cursor)` is an opaque value passed back to the next `*_request`
///   call. It can be a page number, a URL, a token, a table — whatever the
///   script needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Page<T, C = String> {
    /// The items on this page.
    pub items: Vec<T>,
    /// An opaque cursor for the next page, or `None` if this is the last page.
    pub next_cursor: Option<C>,
}

// ---------------------------------------------------------------------------
// Domain models
// ---------------------------------------------------------------------------

/// A single search result returned by a feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// Unique identifier for the book within this feed.
    pub id: String,
    /// Title of the book.
    pub title: String,
    /// Author of the book.
    pub author: String,
    /// URL to a cover image, if available.
    #[serde(default)]
    pub cover_url: Option<String>,
    /// A short description or summary, if available.
    #[serde(default)]
    pub description: Option<String>,
}

impl SearchResult {
    pub fn id(&self) -> &str {
        &self.id
    }
}

/// Detailed information about a book.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookInfo {
    /// Unique identifier for the book within this feed.
    pub id: String,
    /// Title of the book.
    pub title: String,
    /// Author of the book.
    pub author: String,
    /// URL to a cover image, if available.
    #[serde(default)]
    pub cover_url: Option<String>,
    /// A short description or summary, if available.
    #[serde(default)]
    pub description: Option<String>,
}

/// An entry in a book's table of contents.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    /// Unique identifier for the chapter within this feed.
    pub id: String,
    /// Title of the chapter.
    pub title: String,
}

impl ChapterInfo {
    pub fn id(&self) -> &str {
        &self.id
    }
}

/// Identifies a paragraph within a chapter.
///
/// - `Index(usize)` — a sequential position assigned automatically by `LuaFeed`
///   when the Lua script does not provide an explicit `id`.  Stable across
///   requests as long as the chapter content doesn't change.
/// - `Id(String)` — an explicit identifier provided by the book source.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ParagraphId {
    Index(usize),
    Id(String),
}

impl ParagraphId {
    pub fn to_string_lossy(&self) -> String {
        match self {
            ParagraphId::Index(i) => i.to_string(),
            ParagraphId::Id(s) => s.clone(),
        }
    }
}

impl std::fmt::Display for ParagraphId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParagraphId::Index(i) => write!(f, "{i}"),
            ParagraphId::Id(s) => f.write_str(s),
        }
    }
}

/// A single content unit in a chapter, emitted as part of a paragraphs stream.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Paragraph {
    /// The chapter title (typically emitted first).
    Title { id: ParagraphId, text: String },
    /// A text paragraph.
    Text { id: ParagraphId, content: String },
    /// An image.
    Image {
        id: ParagraphId,
        url: String,
        #[serde(default)]
        alt: Option<String>,
    },
}

impl Paragraph {
    pub fn id(&self) -> &ParagraphId {
        match self {
            Paragraph::Title { id, .. }
            | Paragraph::Text { id, .. }
            | Paragraph::Image { id, .. } => id,
        }
    }

    pub fn set_id(&mut self, new_id: ParagraphId) {
        match self {
            Paragraph::Title { id, .. }
            | Paragraph::Text { id, .. }
            | Paragraph::Image { id, .. } => *id = new_id,
        }
    }
}

// ---------------------------------------------------------------------------
// Raw paragraph (for Lua deserialization with optional id)
// ---------------------------------------------------------------------------

/// Intermediate representation used when deserializing paragraphs from Lua.
/// The `id` field is optional here — `LuaFeed` assigns a [`ParagraphId::Index`]
/// when the script omits it.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum RawParagraph {
    Title {
        #[serde(default)]
        id: Option<String>,
        text: String,
    },
    Text {
        #[serde(default)]
        id: Option<String>,
        content: String,
    },
    Image {
        #[serde(default)]
        id: Option<String>,
        url: String,
        #[serde(default)]
        alt: Option<String>,
    },
}

impl RawParagraph {
    /// Convert to a [`Paragraph`], using the given `index` as fallback ID
    /// when the script did not provide one.
    pub(crate) fn into_paragraph(self, index: usize) -> Paragraph {
        let make_id = |opt: Option<String>| match opt {
            Some(s) => ParagraphId::Id(s),
            None => ParagraphId::Index(index),
        };
        match self {
            RawParagraph::Title { id, text } => Paragraph::Title {
                id: make_id(id),
                text,
            },
            RawParagraph::Text { id, content } => Paragraph::Text {
                id: make_id(id),
                content,
            },
            RawParagraph::Image { id, url, alt } => Paragraph::Image {
                id: make_id(id),
                url,
                alt,
            },
        }
    }
}
