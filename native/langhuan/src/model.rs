use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Paginated result (internal implementation detail)
// ---------------------------------------------------------------------------

/// A page of results with an opaque cursor for fetching the next page.
///
/// This type is used internally by script feeds to drive pagination. Callers
/// of the public [`Feed`] trait never see `Page` — they receive a stream of
/// individual items instead.
///
/// `next_cursor` is determined entirely by the feed reducer:
/// - `None` means this is the last page.
/// - `Some(cursor)` is an opaque value passed back to the next `*_request`
///   call. It can be a page number, a URL, a token, a table — whatever the
///   script needs.
#[derive(Debug, Clone)]
pub(crate) struct Page<T, C> {
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

/// Identity before text transforms. Tags prevent numeric source IDs from
/// being confused with host-assigned positions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum OriginalParagraphId {
    Source(String),
    Generated(u64),
}

/// A paragraph retains its original identity through every transform.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ParagraphId {
    pub original: OriginalParagraphId,
    pub path: Vec<u32>,
}

impl ParagraphId {
    pub fn generated(index: u64) -> Self {
        Self {
            original: OriginalParagraphId::Generated(index),
            path: Vec::new(),
        }
    }

    pub fn source(id: String) -> Self {
        Self {
            original: OriginalParagraphId::Source(id),
            path: Vec::new(),
        }
    }

    pub fn source_id(&self) -> Option<&str> {
        match &self.original {
            OriginalParagraphId::Source(id) => Some(id),
            _ => None,
        }
    }

    /// Canonical, typed storage/UI key; never infer type from its contents.
    pub fn to_string_lossy(&self) -> String {
        serde_json::to_string(self).expect("paragraph IDs are serializable")
    }

    pub fn from_stored(value: String) -> Option<Self> {
        serde_json::from_str(&value).ok()
    }
}

impl std::fmt::Display for ParagraphId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.to_string_lossy())
    }
}

/// A single content unit in a chapter, emitted as part of a paragraphs stream.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Paragraph {
    /// The chapter title (typically emitted first).
    Title {
        id: ParagraphId,
        text: String,
        /// Paragraph-comment total for this unit, when the source reports it.
        /// `None` means unknown or unsupported.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment_count: Option<u32>,
    },
    /// A text paragraph.
    Text {
        id: ParagraphId,
        content: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment_count: Option<u32>,
    },
    /// An image.
    Image {
        id: ParagraphId,
        url: String,
        #[serde(default)]
        alt: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment_count: Option<u32>,
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

    /// The paragraph-comment total reported by the source, if known.
    ///
    /// `None` means unknown or unsupported; `Some(0)` means supported with no
    /// comments. Only meaningful on source-identity paragraphs — a count is
    /// useless without an addressable comment thread.
    pub fn comment_count(&self) -> Option<u32> {
        match self {
            Paragraph::Title { comment_count, .. }
            | Paragraph::Text { comment_count, .. }
            | Paragraph::Image { comment_count, .. } => *comment_count,
        }
    }
}

// ---------------------------------------------------------------------------
// Raw paragraph (for script deserialization with optional id)
// ---------------------------------------------------------------------------

/// Intermediate representation used when deserializing script paragraphs.
/// The `id` field is optional here — the host assigns a [`ParagraphId::Index`]
/// when the script omits it.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum RawParagraph {
    Title {
        #[serde(default)]
        id: Option<String>,
        text: String,
        #[serde(default)]
        comment_count: Option<u32>,
    },
    Text {
        #[serde(default)]
        id: Option<String>,
        content: String,
        #[serde(default)]
        comment_count: Option<u32>,
    },
    Image {
        #[serde(default)]
        id: Option<String>,
        url: String,
        #[serde(default)]
        alt: Option<String>,
        #[serde(default)]
        comment_count: Option<u32>,
    },
}

impl RawParagraph {
    /// Convert to a [`Paragraph`], using the given `index` as fallback ID
    /// when the script did not provide one.
    pub(crate) fn into_paragraph(self, index: usize) -> Paragraph {
        let make_id = |opt: Option<String>| match opt {
            Some(s) => ParagraphId::source(s),
            None => ParagraphId::generated(index as u64),
        };
        match self {
            RawParagraph::Title {
                id,
                text,
                comment_count,
            } => Paragraph::Title {
                id: make_id(id),
                text,
                comment_count,
            },
            RawParagraph::Text {
                id,
                content,
                comment_count,
            } => Paragraph::Text {
                id: make_id(id),
                content,
                comment_count,
            },
            RawParagraph::Image {
                id,
                url,
                alt,
                comment_count,
            } => Paragraph::Image {
                id: make_id(id),
                url,
                alt,
                comment_count,
            },
        }
    }
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    #[test]
    fn numeric_source_ids_never_become_indices() {
        let mut source = ParagraphId::source("839".into());
        source.path = vec![1, 0];
        let key = source.to_string_lossy();
        assert_eq!(ParagraphId::from_stored(key), Some(source.clone()));
        assert_eq!(source.source_id(), Some("839"));
        assert_ne!(source, ParagraphId::generated(839));
        assert!(ParagraphId::from_stored("839".into()).is_none());
    }
}

#[cfg(test)]
mod comment_count_tests {
    use super::*;

    /// Script paragraphs report counts as `comment_count` (the script JSON
    /// protocol is snake_case throughout); omission reads as unknown.
    #[test]
    fn raw_paragraph_reads_snake_case_comment_count() {
        let raw: RawParagraph = serde_json::from_str(
            r#"{"type":"text","id":"3","content":"正文","comment_count":5139}"#,
        )
        .expect("valid script paragraph");
        assert_eq!(
            raw.into_paragraph(0),
            Paragraph::Text {
                id: ParagraphId::source("3".into()),
                content: "正文".to_string(),
                comment_count: Some(5139),
            }
        );

        let raw: RawParagraph = serde_json::from_str(r#"{"type":"text","content":"正文"}"#)
            .expect("valid script paragraph");
        let paragraph = raw.into_paragraph(1);
        assert_eq!(
            paragraph,
            Paragraph::Text {
                id: ParagraphId::generated(1),
                content: "正文".to_string(),
                comment_count: None,
            }
        );
        assert_eq!(paragraph.comment_count(), None);
    }

    /// Stored paragraphs round-trip counts, including the supported-with-zero
    /// case that must stay distinct from unknown.
    #[test]
    fn paragraph_roundtrips_comment_count() {
        for value in [Some(0u32), Some(42), None] {
            let paragraph = Paragraph::Title {
                id: ParagraphId::source("-1".into()),
                text: "章節".to_string(),
                comment_count: value,
            };
            let json = serde_json::to_string(&paragraph).expect("serialize");
            let back: Paragraph = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(back, paragraph);
            assert_eq!(back.comment_count(), value);
        }
    }
}
