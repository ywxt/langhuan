use async_trait::async_trait;
use messages::{
    actor::Actor,
    prelude::{Address, Context, Notifiable},
};
use tokio::task::JoinSet;

use crate::signals::SetLocale;

pub struct LocaleActor {
    _owned_tasks: JoinSet<()>,
}

impl LocaleActor {
    pub fn new(addr: Address<Self>) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_for_locale_changes(addr));
        Self { _owned_tasks }
    }

    async fn listen_for_locale_changes(mut self_addr: Address<Self>) {
        use rinf::DartSignal;
        let rx = SetLocale::get_dart_signal_receiver();
        while let Some(pack) = rx.recv().await {
            let _ = self_addr.notify(pack.message).await;
        }
    }
}

impl Actor for LocaleActor {}

#[async_trait]
impl Notifiable<SetLocale> for LocaleActor {
    async fn notify(&mut self, _message: SetLocale, _: &Context<Self>) {
        rust_i18n::set_locale(&_message.locale);
    }
}
