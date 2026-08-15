use crate::worker;

pub struct Runtime {
    pub worker_sender: tokio::sync::mpsc::UnboundedSender<worker::Message>,
    /// Thread-safe handle to the runtime's V8 isolate. This is the only way to
    /// interrupt JavaScript that is already running: the worker thread is
    /// inside `execute_script` and cannot receive a channel message until the
    /// script yields, which a `for(;;){}` never does.
    ///
    /// `terminate_execution` is safe to call from any thread and never blocks.
    pub isolate_handle: deno_core::v8::IsolateHandle,
}

#[rustler::resource_impl]
impl rustler::Resource for Runtime {}

impl Drop for Runtime {
    fn drop(&mut self) {
        // Best-effort shutdown if the Elixir GenServer never got to terminate
        // the runtime (e.g. the ResourceArc was simply GC'd, or the owning
        // process was brutally killed).
        //
        // Terminate FIRST. A runaway guest never returns to the worker's select
        // loop, so a bare `Stop` would sit unread in the channel forever while
        // the per-runtime OS thread spun at 100% CPU for the life of the VM —
        // uncapped, and invisible to BEAM scheduler-utilization monitoring
        // because this is not a dirty scheduler. Terminating unwinds the script
        // so the loop can observe `Stop` and exit the thread.
        self.isolate_handle.terminate_execution();
        let (tx, _rx) = tokio::sync::oneshot::channel();
        let _ = self.worker_sender.send(worker::Message::Stop(tx));
    }
}
