use rinf::SignalPiece;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, SignalPiece)]
pub struct CookieEntry {
    pub name: String,
    pub value: String,
    pub domain: Option<String>,
    pub path: Option<String>,
    pub expires: Option<String>,
    pub secure: Option<bool>,
    pub http_only: Option<bool>,
    pub same_site: Option<String>,
}
