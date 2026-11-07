//! Text paragraph indentation transform.
//!
//! Sets first-line layout metadata without changing paragraph text.

use crate::model::Paragraph;

use super::{ParagraphTransform, TransformOutput};

pub struct TextIndentTransform {
    spaces: u8,
}

impl TextIndentTransform {
    pub fn new() -> Self {
        Self::with_spaces(2)
    }

    pub fn with_spaces(spaces: u8) -> Self {
        Self { spaces }
    }
}

impl Default for TextIndentTransform {
    fn default() -> Self {
        Self::new()
    }
}

impl ParagraphTransform for TextIndentTransform {
    fn init(&mut self, _chapter_id: &str) {}

    fn apply(&mut self, mut paragraph: Paragraph, out: &mut TransformOutput<'_>) {
        if let Paragraph::Text { layout, .. } = &mut paragraph {
            layout.first_line_indent = self.spaces;
        }
        out.push(paragraph);
    }
}

#[cfg(test)]
mod tests {
    use super::TextIndentTransform;
    use crate::model::{Paragraph, ParagraphId};
    use crate::transform::{ParagraphTransform, TransformOutput};

    #[test]
    fn sets_layout_without_modifying_text() {
        let mut transform = TextIndentTransform::new();
        transform.init("chapter-1");

        let mut buf = Vec::new();
        let mut out = TransformOutput::new(&mut buf);
        transform.apply(
            Paragraph::Text {
                id: ParagraphId::generated(1),
                content: "第一段".to_string(),
                comment_count: Some(7),
                layout: Default::default(),
            },
            &mut out,
        );

        assert_eq!(buf.len(), 1);
        match &buf[0] {
            Paragraph::Text {
                content,
                comment_count,
                layout,
                ..
            } => {
                assert_eq!(content, "第一段");
                assert_eq!(layout.first_line_indent, 2);
                assert_eq!(*comment_count, Some(7));
            }
            _ => panic!("expected text paragraph"),
        }
    }

    #[test]
    fn keeps_non_text_unchanged() {
        let mut transform = TextIndentTransform::new();
        transform.init("chapter-1");

        let mut buf = Vec::new();
        let mut out = TransformOutput::new(&mut buf);
        transform.apply(
            Paragraph::Title {
                id: ParagraphId::generated(0),
                text: "章節標題".to_string(),
                comment_count: Some(42),
            },
            &mut out,
        );

        assert_eq!(buf.len(), 1);
        assert!(matches!(&buf[0], Paragraph::Title { .. }));
        assert_eq!(buf[0].comment_count(), Some(42));
    }
}
