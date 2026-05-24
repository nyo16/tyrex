use crate::worker;

pub struct Runtime {
    pub worker_sender: tokio::sync::mpsc::UnboundedSender<worker::Message>,
}

#[rustler::resource_impl]
impl rustler::Resource for Runtime {}

impl Drop for Runtime {
    fn drop(&mut self) {
        // Best-effort shutdown if the Elixir GenServer never called stop_runtime
        // (e.g. the ResourceArc was simply GC'd). We don't await the ack; the
        // worker still drains its pending promises on Stop, so callers waiting
        // on those replies still get a `dead_runtime_error`.
        let (tx, _rx) = tokio::sync::oneshot::channel();
        let _ = self.worker_sender.send(worker::Message::Stop(tx));
    }
}
