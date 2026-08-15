mod atoms;
mod error;
mod runtime;
mod runtimes;
mod tokio_runtime;
mod util;
mod worker;

use rustler::Env;
use rustler::ResourceArc;

#[rustler::nif(schedule = "DirtyCpu")]
fn start_runtime(
    env: Env,
    pid: rustler::LocalPid,
    main_module_path: String,
    permissions_json: String,
    apply_enabled: bool,
    max_heap_mb: Option<u64>,
) -> rustler::Atom {
    let task_pid = env.pid();
    let runtime_id = runtimes::lock_or_recover().insert(pid);
    let (worker_sender, worker_receiver) =
        tokio::sync::mpsc::unbounded_channel::<worker::Message>();
    std::thread::spawn(move || {
        let tokio_rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(build_err) => {
                util::send_to_pid(
                    &task_pid,
                    (
                        atoms::error(),
                        error::Error {
                            message: Some(format!("tokio runtime build failed: {build_err}")),
                            name: atoms::execution_error(),
                            value: None,
                        },
                    ),
                );
                runtimes::lock_or_recover().try_remove(runtime_id);
                return;
            }
        };
        // Whether startup already reported an outcome to the waiting Elixir
        // process. Read only on the panic path, where sending a second reply
        // would be wrong but sending none leaves `init/1` waiting out its whole
        // `:startup_timeout`.
        let startup_reported = std::cell::Cell::new(false);
        // This thread is a bare `std::thread::spawn`, so it sits outside
        // rustler's own `catch_unwind`: an unwind here would skip
        // `try_remove(runtime_id)` and leak the slab entry forever. That is not
        // hypothetical — v0.4.0 made termination asynchronous and arbitrary
        // (`terminate_runtime`, `Runtime::drop`, the `eval_blocking` timeout
        // arm, the heap-limit callback), and under a pending termination V8
        // returns empty `MaybeLocal`s that `serde_v8` unwraps; upstream marks
        // those "fixme: this unwrap is not safe".
        //
        // In-flight callers need no special handling: unwinding drops the
        // promise slab, and dropping a `oneshot::Sender` without sending makes
        // its receiver fail, which both `eval` and `eval_blocking` report as
        // `:dead_runtime_error`.
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            tokio_rt.block_on(async {
                match worker::new(
                    runtime_id,
                    main_module_path,
                    permissions_json,
                    apply_enabled,
                    max_heap_mb,
                )
                .await
                {
                    Ok(handle) => {
                        // Ship the isolate handle with the resource. Without it there
                        // is no way to interrupt a guest that never yields — this
                        // thread is the one burning CPU, so it cannot rescue itself.
                        let isolate_handle = handle.isolate_handle.clone();
                        util::send_to_pid(
                            &task_pid,
                            (
                                atoms::ok(),
                                ResourceArc::new(runtime::Runtime {
                                    worker_sender,
                                    isolate_handle,
                                }),
                            ),
                        );
                        startup_reported.set(true);
                        worker::run(runtime_id, handle, worker_receiver).await;
                    }
                    Err(message) => {
                        util::send_to_pid(&task_pid, (atoms::error(), message));
                        startup_reported.set(true);
                        runtimes::lock_or_recover().try_remove(runtime_id);
                    }
                }
            })
        }));

        if let Err(payload) = outcome {
            let reason = panic_reason(payload.as_ref());
            eprintln!("tyrex: worker thread for runtime {runtime_id} panicked: {reason}");
            runtimes::lock_or_recover().try_remove(runtime_id);
            if !startup_reported.get() {
                util::send_to_pid(
                    &task_pid,
                    (
                        atoms::error(),
                        error::Error {
                            message: Some(format!("worker thread panicked at startup: {reason}")),
                            name: atoms::execution_error(),
                            value: None,
                        },
                    ),
                );
            }
        }
    });
    atoms::ok()
}

fn panic_reason(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_string()
    }
}

/// Interrupt whatever JavaScript the runtime is executing, right now.
///
/// A plain (non-dirty) NIF on purpose: `terminate_execution` takes a short
/// mutex and sets a flag on the isolate. It is designed to be called from a
/// foreign thread and never blocks on the guest.
///
/// Termination is sticky and uncatchable, so this is a one-way door: the
/// runtime is dead afterwards and the worker thread winds down. That is the
/// contract — no `cancel_terminate_execution` resurrection, because a pooled
/// runtime that silently became a brick after its first timeout would be far
/// worse than one that was replaced.
#[rustler::nif]
fn terminate_runtime(resource: ResourceArc<runtime::Runtime>) -> rustler::Atom {
    resource.isolate_handle.terminate_execution();
    // Unblocking the guest is only half of it; the worker loop still has to be
    // told to stop, or the thread would sit in `select!` forever.
    let (response_sender, _response_receiver) = tokio::sync::oneshot::channel();
    let _ = resource
        .worker_sender
        .send(worker::Message::Stop(response_sender));
    atoms::ok()
}

#[rustler::nif]
fn eval(
    env: Env,
    from: rustler::Term,
    resource: ResourceArc<runtime::Runtime>,
    code: String,
) -> rustler::Atom {
    let pid = env.pid();
    let worker_sender = resource.worker_sender.clone();
    let mut from_env = rustler::OwnedEnv::new();
    let saved_from = from_env.save(from);
    tokio_runtime::get().spawn(async move {
        let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
        let result = if worker_sender
            .send(worker::Message::Eval(code, response_sender))
            .is_ok()
        {
            match response_receiver.await {
                Ok(result) => result,
                // The sender was dropped without replying, which only happens
                // when the worker thread went away — including a panic, whose
                // unwind drops the promise slab.
                Err(_) => Err(error::Error {
                    message: None,
                    name: atoms::dead_runtime_error(),
                    value: None,
                }),
            }
        } else {
            Err(error::Error {
                message: None,
                name: atoms::dead_runtime_error(),
                value: None,
            })
        };
        let _ = from_env.send_and_clear(&pid, |env| {
            (atoms::eval_reply(), saved_from.load(env), result)
        });
    });
    atoms::ok()
}

/// `DirtyIo`, not `DirtyCpu`: this NIF parks on a channel waiting for another
/// thread to finish. That is I/O-shaped waiting, and classifying it as CPU work
/// misreports the BEAM's own scheduler accounting.
#[rustler::nif(schedule = "DirtyIo")]
fn eval_blocking(
    resource: ResourceArc<runtime::Runtime>,
    code: String,
    timeout_ms: u64,
) -> Result<String, error::Error> {
    let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
    resource
        .worker_sender
        .send(worker::Message::Eval(code, response_sender))
        .or(Err(error::Error {
            message: None,
            name: atoms::dead_runtime_error(),
            value: None,
        }))?;

    // A bare `blocking_recv()` here is an unbounded park with no escape: if the
    // guest never finishes, this dirty-IO thread never comes back. Bound it, and
    // terminate the guest on expiry so the runtime's own thread is reclaimed too
    // rather than spinning for the life of the VM.
    let received = tokio_runtime::get().block_on(async {
        tokio::time::timeout(
            std::time::Duration::from_millis(timeout_ms),
            response_receiver,
        )
        .await
    });

    match received {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(error::Error {
            message: None,
            name: atoms::dead_runtime_error(),
            value: None,
        }),
        Err(_elapsed) => {
            resource.isolate_handle.terminate_execution();
            let (stop_sender, _stop_receiver) = tokio::sync::oneshot::channel();
            let _ = resource
                .worker_sender
                .send(worker::Message::Stop(stop_sender));
            Err(error::Error {
                message: Some(format!(
                    "blocking eval exceeded its {timeout_ms}ms deadline; the runtime was terminated"
                )),
                name: atoms::timeout(),
                value: None,
            })
        }
    }
}

#[rustler::nif]
fn apply_reply(
    resource: ResourceArc<runtime::Runtime>,
    application_id: String,
    result: Result<String, String>,
) -> Result<(), error::Error> {
    resource
        .worker_sender
        .send(worker::Message::ApplyReply(application_id, result))
        .or(Err(error::Error {
            message: None,
            name: atoms::dead_runtime_error(),
            value: None,
        }))
}

rustler::init!("Elixir.Tyrex.Native");
