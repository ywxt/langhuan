use crate::actors::{addresses, locale_actor::SetLocale};

/// Set the locale used for Rust-side error messages.
/// Dart should call this once at startup and whenever the locale changes.
pub async fn set_locale(locale: String) {
    if let Ok(addrs) = addresses() {
        let _ = addrs.locale.clone().send(SetLocale { locale }).await;
    }
}
