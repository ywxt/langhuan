use rinf::DartSignal;
use serde::Deserialize;

/// Set the locale used for Rust-side error messages.
/// Dart should call this once at startup and whenever the locale changes.
#[derive(Deserialize, DartSignal)]
pub struct SetLocale {
    /// BCP 47 locale tag, e.g. "zh", "zh-TW", "en".
    pub locale: String,
}
