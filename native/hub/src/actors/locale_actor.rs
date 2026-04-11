use async_trait::async_trait;
use messages::{
    actor::Actor,
    prelude::Context,
};

/// Message sent from the FRB API layer to update the locale.
pub struct SetLocale {
    pub locale: String,
}

pub struct LocaleActor;

impl LocaleActor {
    pub fn new() -> Self {
        Self
    }
}

impl Actor for LocaleActor {}

#[async_trait]
impl messages::prelude::Handler<SetLocale> for LocaleActor {
    type Result = ();

    async fn handle(&mut self, message: SetLocale, _: &Context<Self>) {
        tracing::debug!(locale = %message.locale, "locale updated from Dart");
        rust_i18n::set_locale(&message.locale);
    }
}
