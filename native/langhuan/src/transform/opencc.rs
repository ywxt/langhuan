//! OpenCC-based paragraph transform for Chinese simplified ↔ traditional conversion.
//!
//! Uses [`ferrous-opencc`] (pure Rust) so there is no C++ dependency and
//! cross-compilation for Android / iOS works out of the box.
//!
//! The heavy `OpenCC` instances are lazily initialised in `OnceLock` statics
//! and shared across all transform instances.

use std::sync::OnceLock;

use ferrous_opencc::OpenCC;
use ferrous_opencc::config::BuiltinConfig;

use crate::model::Paragraph;

use super::{ParagraphTransform, TransformOutput};

// ---------------------------------------------------------------------------
// Lazy-init converters (shared across all transform instances)
// ---------------------------------------------------------------------------

static S2T: OnceLock<OpenCC> = OnceLock::new();
static T2S: OnceLock<OpenCC> = OnceLock::new();
static S2TW: OnceLock<OpenCC> = OnceLock::new();
static S2HK: OnceLock<OpenCC> = OnceLock::new();

fn s2t_converter() -> &'static OpenCC {
    S2T.get_or_init(|| {
        OpenCC::from_config(BuiltinConfig::S2t).expect("failed to initialise OpenCC S2T")
    })
}

fn t2s_converter() -> &'static OpenCC {
    T2S.get_or_init(|| {
        OpenCC::from_config(BuiltinConfig::T2s).expect("failed to initialise OpenCC T2S")
    })
}

fn s2tw_converter() -> &'static OpenCC {
    S2TW.get_or_init(|| {
        OpenCC::from_config(BuiltinConfig::S2twp).expect("failed to initialise OpenCC S2TW")
    })
}

fn s2hk_converter() -> &'static OpenCC {
    S2HK.get_or_init(|| {
        OpenCC::from_config(BuiltinConfig::S2hk).expect("failed to initialise OpenCC S2HK")
    })
}

// ---------------------------------------------------------------------------
// Conversion mode
// ---------------------------------------------------------------------------

/// Which direction to convert, or no conversion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversionMode {
    /// No conversion — pass through unchanged.
    None,
    /// Simplified Chinese → Traditional Chinese.
    S2t,
    /// Traditional Chinese → Simplified Chinese.
    T2s,
    /// Simplified Chinese → Taiwan traditional, including local vocabulary.
    S2tw,
    /// Simplified Chinese → Hong Kong traditional.
    S2hk,
}

// ---------------------------------------------------------------------------
// OpenCcTransform
// ---------------------------------------------------------------------------

/// A [`ParagraphTransform`] that converts Chinese text using OpenCC.
///
/// Converts the text fields of [`Paragraph::Title`] and [`Paragraph::Text`].
/// [`Paragraph::Image`] is passed through unchanged.
pub struct OpenCcTransform {
    mode: ConversionMode,
}

impl OpenCcTransform {
    /// Create a new transform with the given conversion mode.
    ///
    /// If `mode` is [`ConversionMode::None`], the transform acts as a
    /// pass-through and no OpenCC instance is initialised.
    pub fn new(mode: ConversionMode) -> Self {
        Self { mode }
    }

    /// Convert a single string according to the current mode.
    fn convert(&self, text: &str) -> String {
        match self.mode {
            ConversionMode::None => text.to_owned(),
            ConversionMode::S2t => s2t_converter().convert(text),
            ConversionMode::T2s => t2s_converter().convert(text),
            ConversionMode::S2tw => s2tw_converter().convert(text),
            ConversionMode::S2hk => s2hk_converter().convert(text),
        }
    }
}

impl ParagraphTransform for OpenCcTransform {
    fn init(&mut self, _chapter_id: &str) {
        // No per-chapter state needed — the converter is global.
    }

    fn apply(&mut self, paragraph: Paragraph, out: &mut TransformOutput<'_>) {
        if self.mode == ConversionMode::None {
            out.push(paragraph);
            return;
        }

        out.push(match paragraph {
            Paragraph::Title { id, text } => Paragraph::Title {
                id,
                text: self.convert(&text),
            },
            Paragraph::Text { id, content } => Paragraph::Text {
                id,
                content: self.convert(&content),
            },
            img @ Paragraph::Image { .. } => img,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{ConversionMode, OpenCcTransform};

    #[test]
    fn converts_simplified_chinese_to_taiwan_usage() {
        let transform = OpenCcTransform::new(ConversionMode::S2tw);
        assert_eq!(
            transform.convert("鼠标里面的硅二极管坏了，导致光标分辨率降低。"),
            "滑鼠裡面的矽二極體壞了，導致游標解析度降低。"
        );
    }

    #[test]
    fn converts_simplified_chinese_to_hong_kong_variants() {
        let transform = OpenCcTransform::new(ConversionMode::S2hk);
        assert_eq!(transform.convert("为了核实这说法"), "為了核實這説法");
    }
}
