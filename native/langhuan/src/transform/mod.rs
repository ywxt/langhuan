//! Paragraph transforms — stateful per-chapter transformations.
//!
//! A [`ParagraphTransform`] is initialised once per chapter and then called for
//! each [`Paragraph`] in sequence.  Results are pushed into an output `Vec`
//! to avoid per-call allocations:
//!
//! - push nothing → drop
//! - push one → keep / modify
//! - push many → insert additional paragraphs
//!
//! Implementations are expected to be cheap to construct — expensive resources
//! (e.g. OpenCC dictionaries) should be shared via `Arc` or lazy statics.

pub mod dedup_title;
pub mod opencc;
pub mod regex;
pub mod text_indent;

use std::collections::HashSet;

use crate::model::Paragraph;

// ---------------------------------------------------------------------------
// TransformOutput — append-only output sink
// ---------------------------------------------------------------------------

/// An append-only output sink for [`ParagraphTransform::apply`].
///
/// Wraps a `&mut Vec<Paragraph>` but only exposes `push`, preventing
/// transforms from inspecting or mutating previously emitted paragraphs.
///
/// Tracks emitted IDs and auto-reassigns duplicates to maintain uniqueness.
pub struct TransformOutput<'a> {
    buf: &'a mut Vec<Paragraph>,
    seen: HashSet<String>,
    next_index: u64,
}

impl<'a> TransformOutput<'a> {
    pub fn new(buf: &'a mut Vec<Paragraph>) -> Self {
        Self {
            buf,
            seen: HashSet::new(),
            next_index: 0,
        }
    }

    /// Emit a paragraph to the output.
    ///
    /// If the paragraph's ID has already been emitted, it is replaced with a
    /// descendant path, preserving its original source identity.
    #[inline]
    pub fn push(&mut self, mut paragraph: Paragraph) {
        let key = paragraph.id().to_string();
        if !self.seen.insert(key) {
            let mut id = paragraph.id().clone();
            id.path.push(self.next_index as u32);
            paragraph.set_id(id);
            self.seen.insert(paragraph.id().to_string());
        }
        self.next_index += 1;
        self.buf.push(paragraph);
    }
}

// ---------------------------------------------------------------------------
// ParagraphTransform trait
// ---------------------------------------------------------------------------

/// A stateful, per-chapter paragraph transform.
///
/// # Lifecycle
///
/// 1. [`init`](Self::init) is called once when a chapter stream is opened.
/// 2. [`apply`](Self::apply) is called for every paragraph in order.
/// 3. The transform is dropped when the stream ends or is cancelled.
pub trait ParagraphTransform: Send + Sync {
    /// Initialise the transform for a chapter.
    ///
    /// `chapter_id` is provided so transforms can use chapter-specific state
    /// if needed.
    fn init(&mut self, chapter_id: &str);

    /// Transform a paragraph, pushing results into `out`.
    ///
    /// - push nothing → drop the paragraph
    /// - push one → keep or modify
    /// - push many → expand into multiple paragraphs
    ///
    /// You should never change the ID of the input paragraph if you want
    /// to keep or modify it. If you want to push multiple paragraphs, you
    /// can push paragraphs with the same ID as the input, and the `TransformOutput`
    /// will automatically reassign IDs to ensure uniqueness.
    fn apply(&mut self, paragraph: Paragraph, out: &mut TransformOutput<'_>);
}

// ---------------------------------------------------------------------------
// TransformChain — compose multiple transforms
// ---------------------------------------------------------------------------

/// Applies a chain of [`ParagraphTransform`]s in order.
///
/// Each transform sees the output of the previous one.  When a transform
/// drops a paragraph, subsequent transforms never see it.
///
/// Internally uses two pre-allocated buffers that are swapped each stage,
/// so steady-state operation involves zero heap allocations.
pub struct TransformChain {
    transforms: Vec<Box<dyn ParagraphTransform>>,
}

impl TransformChain {
    /// Create an empty chain (pass-through).
    pub fn new() -> Self {
        Self {
            transforms: Vec::new(),
        }
    }

    /// Append a transform to the end of the chain.
    pub fn push(&mut self, transform: Box<dyn ParagraphTransform>) {
        self.transforms.push(transform);
    }

    /// Returns `true` if the chain contains no transforms (pure pass-through).
    pub fn is_empty(&self) -> bool {
        self.transforms.is_empty()
    }

    /// Initialize every transform in the chain for the given chapter.
    pub fn init(&mut self, chapter_id: &str) {
        for t in &mut self.transforms {
            t.init(chapter_id);
        }
    }

    /// Run a single paragraph through the full chain.
    pub fn apply(&mut self, paragraph: Paragraph) -> Vec<Paragraph> {
        // Seed buf_a with the input paragraph.
        let mut buf_a = Vec::new();
        let mut buf_b = vec![paragraph];

        for transform in &mut self.transforms {
            buf_a.clear();
            let mut out = TransformOutput::new(&mut buf_a);
            for p in buf_b.drain(..) {
                let parent = p.id().clone();
                let start = out.buf.len();
                transform.apply(p, &mut out);
                let count = out.buf.len() - start;
                for (index, child) in out.buf[start..].iter_mut().enumerate() {
                    let mut id = parent.clone();
                    if count > 1 {
                        id.path.push(index as u32);
                    }
                    child.set_id(id);
                }
            }
            drop(out);
            std::mem::swap(&mut buf_a, &mut buf_b);
        }

        buf_b
    }
}

impl Default for TransformChain {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::ParagraphTransform;
    use super::TransformChain;
    use super::TransformOutput;
    use crate::model::Paragraph;
    use crate::model::ParagraphId;

    /// A test transform that duplicates every paragraph.
    struct Duplicator;

    impl ParagraphTransform for Duplicator {
        fn init(&mut self, _chapter_id: &str) {}

        fn apply(&mut self, paragraph: Paragraph, out: &mut TransformOutput<'_>) {
            out.push(paragraph.clone());
            out.push(paragraph);
        }
    }

    #[test]
    fn test_transform_chain() {
        let mut chain = TransformChain::new();
        chain.push(Box::new(Duplicator));
        chain.push(Box::new(Duplicator));

        let input = Paragraph::Text {
            id: ParagraphId::generated(0),
            content: "Hello".to_string(),
            comment_count: None,
        };
        let output = chain.apply(input);

        assert_eq!(output.len(), 4);
        // All IDs must be unique.
        let mut ids: Vec<String> = output.iter().map(|p| p.id().to_string()).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 4);
    }

    #[test]
    fn test_push_dedup() {
        let mut buf = Vec::new();
        let mut out = TransformOutput::new(&mut buf);

        out.push(Paragraph::Text {
            id: ParagraphId::generated(0),
            content: "a".into(),
            comment_count: None,
        });
        out.push(Paragraph::Text {
            id: ParagraphId::generated(0),
            content: "b".into(),
            comment_count: None,
        });
        out.push(Paragraph::Text {
            id: ParagraphId::source("custom".into()),
            content: "c".into(),
            comment_count: None,
        });
        out.push(Paragraph::Text {
            id: ParagraphId::source("custom".into()),
            content: "d".into(),
            comment_count: None,
        });
        drop(out);

        assert_eq!(buf.len(), 4);
        // First of each pair keeps original ID.
        assert_eq!(*buf[0].id(), ParagraphId::generated(0));
        assert_eq!(*buf[2].id(), ParagraphId::source("custom".into()));
        // Duplicates get reassigned — just verify uniqueness.
        assert_ne!(buf[1].id(), buf[0].id());
        assert_ne!(buf[3].id(), buf[2].id());
        let ids: std::collections::HashSet<String> =
            buf.iter().map(|p| p.id().to_string()).collect();
        assert_eq!(ids.len(), 4);
    }

    #[test]
    fn splitting_twice_keeps_source_and_builds_distinct_paths() {
        struct Split;
        impl ParagraphTransform for Split {
            fn init(&mut self, _: &str) {}
            fn apply(&mut self, p: Paragraph, out: &mut TransformOutput<'_>) {
                out.push(p.clone());
                out.push(p);
            }
        }
        let mut chain = TransformChain::new();
        chain.push(Box::new(Split));
        chain.push(Box::new(Split));
        let result = chain.apply(Paragraph::Text {
            id: ParagraphId::source("839".into()),
            content: "text".into(),
            comment_count: None,
        });
        assert_eq!(
            result
                .iter()
                .map(|p| p.id().path.clone())
                .collect::<Vec<_>>(),
            vec![vec![0, 0], vec![0, 1], vec![1, 0], vec![1, 1]]
        );
        assert!(result.iter().all(|p| p.id().source_id() == Some("839")));
    }
}
