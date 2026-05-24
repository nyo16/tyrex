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
        tokio_rt.block_on(async {
            match worker::new(runtime_id, main_module_path, permissions_json).await {
                Ok(worker) => {
                    util::send_to_pid(
                        &task_pid,
                        (
                            atoms::ok(),
                            ResourceArc::new(runtime::Runtime { worker_sender }),
                        ),
                    );
                    worker::run(runtime_id, worker, worker_receiver).await;
                }
                Err(message) => {
                    util::send_to_pid(&task_pid, (atoms::error(), message));
                    runtimes::lock_or_recover().try_remove(runtime_id);
                }
            }
        });
    });
    atoms::ok()
}

#[rustler::nif]
fn stop_runtime(env: Env, resource: ResourceArc<runtime::Runtime>) -> rustler::Atom {
    let pid = env.pid();
    let worker_sender = resource.worker_sender.clone();
    tokio_runtime::get().spawn(async move {
        let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
        if worker_sender
            .send(worker::Message::Stop(response_sender))
            .is_ok()
        {
            // If the worker dies before acking, treat the stop as successful
            // — the worker is gone either way, which is what the caller wants.
            let _ = response_receiver.await.ok();
            util::send_to_pid(&pid, atoms::ok());
        } else {
            util::send_to_pid(
                &pid,
                (
                    atoms::error(),
                    error::Error {
                        message: None,
                        name: atoms::dead_runtime_error(),
                        value: None,
                    },
                ),
            );
        };
    });
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
                Err(_) => Err(error::Error {
                    message: None,
                    name: atoms::execution_error(),
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

#[rustler::nif(schedule = "DirtyCpu")]
fn eval_blocking(
    resource: ResourceArc<runtime::Runtime>,
    code: String,
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
    match response_receiver.blocking_recv() {
        Ok(result) => result,
        Err(_) => Err(error::Error {
            message: None,
            name: atoms::execution_error(),
            value: None,
        }),
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
