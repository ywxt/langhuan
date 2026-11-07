//! Linear-time regular expressions for text replacement and paragraph removal.
use super::{ParagraphTransform, TransformOutput};
use crate::model::Paragraph;
use regex::{Regex, RegexBuilder};

pub struct RegexTransform {
    regex: Regex,
    replacement: Option<String>,
    include_titles: bool,
}

impl RegexTransform {
    pub fn new(
        pattern: &str,
        replacement: Option<String>,
        include_titles: bool,
    ) -> Result<Self, String> {
        if pattern.len() > 4096 || replacement.as_ref().is_some_and(|value| value.len() > 4096) {
            return Err("Pattern and replacement must each fit within 4096 bytes".into());
        }
        let regex = RegexBuilder::new(pattern)
            .size_limit(1024 * 1024)
            .nest_limit(128)
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            regex,
            replacement,
            include_titles,
        })
    }
}

impl ParagraphTransform for RegexTransform {
    fn init(&mut self, _: &str) {}
    fn apply(&mut self, mut paragraph: Paragraph, output: &mut TransformOutput<'_>) {
        let text = match &mut paragraph {
            Paragraph::Text { content, .. } => Some(content),
            Paragraph::Title { text, .. } if self.include_titles => Some(text),
            _ => None,
        };
        if let Some(text) = text {
            if let Some(replacement) = &self.replacement {
                *text = self
                    .regex
                    .replace_all(text, replacement.as_str())
                    .into_owned();
            } else if self.regex.is_match(text) {
                return;
            }
        }
        output.push(paragraph);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ParagraphId;
    fn text(value: &str) -> Paragraph {
        Paragraph::Text {
            id: ParagraphId::source("original".into()),
            content: value.into(),
            comment_count: Some(5),
            layout: Default::default(),
        }
    }
    #[test]
    fn replacement_preserves_identity_and_comments() {
        let mut rule = RegexTransform::new(r"(廣告)(\d+)", Some("$2/$1".into()), false).unwrap();
        let mut items = vec![];
        rule.apply(text("廣告12 廣告34"), &mut TransformOutput::new(&mut items));
        assert!(
            matches!(&items[0], Paragraph::Text {content, comment_count: Some(5), id, .. } if content == "12/廣告 34/廣告" && id.source_id() == Some("original"))
        );
    }
    #[test]
    fn deletion_filters_entire_matching_paragraph_but_not_titles() {
        let mut rule = RegexTransform::new("廣告", None, false).unwrap();
        let mut items = vec![];
        let mut output = TransformOutput::new(&mut items);
        rule.apply(text("這是廣告內容"), &mut output);
        rule.apply(
            Paragraph::Title {
                id: ParagraphId::source("title".into()),
                text: "廣告".into(),
                comment_count: None,
            },
            &mut output,
        );
        rule.apply(text("正文"), &mut output);
        assert_eq!(items.len(), 2);
    }
    #[test]
    fn invalid_regex_is_rejected() {
        assert!(RegexTransform::new("[", None, false).is_err());
    }

    #[test]
    fn title_opt_in_and_image_passthrough() {
        let mut rule = RegexTransform::new("舊", Some("新".into()), true).unwrap();
        let mut items = vec![];
        let mut output = TransformOutput::new(&mut items);
        rule.apply(
            Paragraph::Title {
                id: ParagraphId::source("title".into()),
                text: "舊標題".into(),
                comment_count: None,
            },
            &mut output,
        );
        let image = Paragraph::Image {
            id: ParagraphId::source("image".into()),
            url: "https://example.com/舊.png".into(),
            alt: Some("舊圖".into()),
            comment_count: Some(2),
        };
        rule.apply(image.clone(), &mut output);
        assert!(matches!(&items[0], Paragraph::Title { text, .. } if text == "新標題"));
        assert_eq!(items[1], image);
    }
}
