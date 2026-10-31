//! Text paragraph indentation transform.
//!
//! Prepends two ideographic spaces to [`Paragraph::Text`] content so rendered
//! paragraphs start with a first-line indent.

use crate::model::Paragraph;

use super::{ParagraphTransform, TransformOutput};

const FIRST_LINE_INDENT: &str = "\u{3000}\u{3000}";

pub struct TextIndentTransform;

impl TextIndentTransform {
    pub fn new() -> Self {
        Self
    }
}

impl Default for TextIndentTransform {
    fn default() -> Self {
        Self::new()
    }
}

impl ParagraphTransform for TextIndentTransform {
    fn init(&mut self, _chapter_id: &str) {}

    fn apply(&mut self, paragraph: Paragraph, out: &mut TransformOutput<'_>) {
        match paragraph {
            Paragraph::Text { id, mut content } => {
                if !content.starts_with(FIRST_LINE_INDENT) {
                    content.insert_str(0, FIRST_LINE_INDENT);
                }
                out.push(Paragraph::Text { id, content });
            }
            other => out.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::TextIndentTransform;
    use crate::model::{Paragraph, ParagraphId};
    use crate::transform::{ParagraphTransform, TransformOutput};

    #[test]
    fn indents_text_paragraph() {
        let mut transform = TextIndentTransform::new();
        transform.init("chapter-1");

        let mut buf = Vec::new();
        let mut out = TransformOutput::new(&mut buf);
        transform.apply(
            Paragraph::Text {
                id: ParagraphId::generated(1),
                content: "第一段".to_string(),
            },
            &mut out,
        );

        assert_eq!(buf.len(), 1);
        match &buf[0] {
            Paragraph::Text { content, .. } => {
                assert_eq!(content, "\u{3000}\u{3000}第一段");
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
            },
            &mut out,
        );

        assert_eq!(buf.len(), 1);
        assert!(matches!(buf[0], Paragraph::Title { .. }));
    }
}
