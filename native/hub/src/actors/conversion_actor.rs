//! [`ConversionActor`] — holds the current Chinese conversion setting and
//! produces [`TransformChain`] instances that `FeedActor` uses per-chapter.
//!
//! Flutter sends a [`SetConversionMode`] message whenever the user changes
//! the setting.  When `FeedActor` opens a paragraphs stream it sends
//! [`BuildTransformChain`] to obtain a `TransformChain` configured with the
//! current mode.

use async_trait::async_trait;
use langhuan::transform::TransformChain;
use langhuan::transform::dedup_title::DedupTitleTransform;
use langhuan::transform::opencc::{ConversionMode, OpenCcTransform};
use langhuan::transform::text_indent::TextIndentTransform;
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::ChineseConversionMode;

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Set the current Chinese conversion mode.
pub struct SetConversionMode {
    pub mode: ChineseConversionMode,
}

/// Request a [`TransformChain`] configured with the current conversion settings.
pub struct BuildTransformChain;

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct ConversionActor {
    mode: ConversionMode,
}

impl Actor for ConversionActor {}

impl ConversionActor {
    pub fn new() -> Self {
        Self {
            mode: ConversionMode::None,
        }
    }
}

impl Default for ConversionActor {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<SetConversionMode> for ConversionActor {
    type Result = ();

    async fn handle(&mut self, msg: SetConversionMode, _: &Context<Self>) -> Self::Result {
        self.mode = match msg.mode {
            ChineseConversionMode::None => ConversionMode::None,
            ChineseConversionMode::S2t => ConversionMode::S2t,
            ChineseConversionMode::T2s => ConversionMode::T2s,
            ChineseConversionMode::S2tw => ConversionMode::S2tw,
            ChineseConversionMode::S2hk => ConversionMode::S2hk,
        };
        tracing::info!(mode = ?self.mode, "conversion mode updated");
    }
}

#[async_trait]
impl Handler<BuildTransformChain> for ConversionActor {
    type Result = TransformChain;

    async fn handle(&mut self, _msg: BuildTransformChain, _: &Context<Self>) -> Self::Result {
        let mut chain = TransformChain::new();
        chain.push(Box::new(DedupTitleTransform::new()));
        chain.push(Box::new(TextIndentTransform::new()));
        if self.mode != ConversionMode::None {
            chain.push(Box::new(OpenCcTransform::new(self.mode)));
        }
        chain
    }
}
