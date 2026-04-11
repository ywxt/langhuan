use crate::actors::create_actors;

/// FRB init function — called once from Dart via `RustLib.init()`.
#[flutter_rust_bridge::frb(init)]
pub async fn init() {
    flutter_rust_bridge::setup_backtrace();

    crate::logging::init();
    tracing::info!("hub runtime starting");

    tracing::info!("spawning actor system");
    create_actors().await;
    tracing::info!("actor system ready");
}
