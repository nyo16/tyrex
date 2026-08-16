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

/// Terminate the isolate and stop the worker. Idempotent: `terminate_execution`
/// is safe to call on an already-terminated isolate, and a `Stop` send on a
/// closed channel is a benign `Err`.
impl Runtime {
    fn shut_down(&self) {
        // Terminate FIRST. A runaway guest never returns to the worker's select
        // loop, so a bare `Stop` would sit unread in the channel forever while
        // the per-runtime OS thread spun at 100% for the life of the VM.
        self.isolate_handle.terminate_execution();
        let (tx, _rx) = tokio::sync::oneshot::channel();
        let _ = self.worker_sender.send(worker::Message::Stop(tx));
    }
}

#[rustler::resource_impl]
impl rustler::Resource for Runtime {
    const IMPLEMENTS_DOWN: bool = true;

    /// The owning GenServer died, so tear the runtime down from here.
    ///
    /// `Drop` is not sufficient and this is not belt-and-braces. With
    /// `blocking: true` the owning GenServer parks inside `eval_blocking`, which
    /// holds a `ResourceArc` in its own NIF call frame. Killing that process —
    /// which is what `stop/1`'s escalation and `kill/1` both come down to — does
    /// not drop the refcount to zero, because the NIF frame still holds one, and
    /// the NIF is itself waiting on a worker that never yields. `Drop` therefore
    /// never runs and the per-runtime OS thread spins forever.
    ///
    /// Measured before this callback existed: three runtimes running `for(;;){}`
    /// under `blocking: true`, then `stop/1` on each — every process dead,
    /// `stop/1` returning `:ok`, and 3.00 cores still burning. That is the same
    /// leak v0.4.0 was released to fix, surviving on the blocking path because
    /// the regression probe only exercised the non-blocking one.
    ///
    /// A process monitor fires on process death regardless of what that process
    /// was executing, so it is the only hook that reaches this case.
    fn down<'a>(
        &'a self,
        _env: rustler::Env<'a>,
        _pid: rustler::LocalPid,
        _monitor: rustler::Monitor,
    ) {
        self.shut_down();
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        // Reached when the last `ResourceArc` goes away: the GenServer exited
        // normally, or the reference was simply garbage-collected.
        //
        // This is NOT the path that covers a brutally killed owner — see `down`
        // above for why a `ResourceArc` held inside a parked NIF frame keeps the
        // refcount off zero and never gets here. Both paths are needed and
        // neither subsumes the other.
        self.shut_down();
    }
}
