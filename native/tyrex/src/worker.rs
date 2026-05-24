use crate::atoms;
use crate::error::Error;
use crate::runtimes;
use crate::util;
use deno_core::op2;
use deno_runtime::worker::MainWorker;
use tokio::sync::oneshot::Sender;

pub enum Message {
    ApplyReply(String, Result<String, String>),
    Eval(String, Sender<Result<String, Error>>),
    Stop(Sender<()>),
}

#[op2(fast)]
fn op_apply(
    #[string] runtime_id: String,
    #[string] application_id: String,
    #[string] module: String,
    #[string] function_name: String,
    #[string] args: String,
) {
    // op_apply is reachable from arbitrary JS in the runtime; every input
    // must be tolerated. Misparses (e.g. someone overwrote `Tyrex._runtimeId`)
    // are logged and dropped — never panicked on.
    let parsed_id = match runtime_id.parse::<usize>() {
        Ok(id) => id,
        Err(err) => {
            eprintln!("tyrex: op_apply got invalid runtime_id {runtime_id:?}: {err}");
            return;
        }
    };
    let slab = runtimes::lock_or_recover();
    let pid = match slab.get(parsed_id) {
        Some(pid) => pid,
        None => {
            eprintln!(
                "tyrex: op_apply could not find pid for runtime_id {parsed_id}; dropping reply"
            );
            return;
        }
    };
    util::send_to_pid(
        pid,
        (atoms::apply(), application_id, module, function_name, args),
    );
}

deno_core::extension!(
    extension,
    ops = [op_apply],
    esm_entry_point = "ext:extension/main.js",
    esm = [dir "extension", "main.js"],
    state = |state| {
        state.put(deno_runtime::ops::bootstrap::SnapshotOptions::default());
    }
);

fn parse_string_list(value: &serde_json::Value) -> Option<Vec<String>> {
    match value {
        serde_json::Value::Bool(true) => Some(vec![]),
        serde_json::Value::Bool(false) => None,
        serde_json::Value::Array(arr) => Some(
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect(),
        ),
        _ => None,
    }
}

fn build_permissions(
    permissions_json: &str,
) -> Result<deno_runtime::deno_permissions::PermissionsContainer, Error> {
    let descriptor_parser = std::sync::Arc::new(
        deno_runtime::permissions::RuntimePermissionDescriptorParser::new(
            sys_traits::impls::RealSys,
        ),
    );

    let parsed: serde_json::Value = match serde_json::from_str(permissions_json) {
        Ok(v) => v,
        Err(_) => {
            return Ok(deno_runtime::deno_permissions::PermissionsContainer::allow_all(
                descriptor_parser,
            ));
        }
    };

    if parsed.is_string() && parsed.as_str() == Some("allow_all") {
        return Ok(deno_runtime::deno_permissions::PermissionsContainer::allow_all(descriptor_parser));
    }

    let obj = match parsed.as_object() {
        Some(o) => o,
        None => {
            // Same fallback behavior as before: unexpected JSON shape =>
            // allow_all (callers that want strict perms must pass an object).
            return Ok(deno_runtime::deno_permissions::PermissionsContainer::allow_all(descriptor_parser));
        }
    };

    // `allow_all: true` is a baseline that still honors any `deny_*` overrides
    // layered on top — documented in the README as `[allow_all: true, deny_X: true]`.
    // Implemented by defaulting every `allow_*` to `Some(vec![])` (Deno semantics:
    // empty list = allow all) when allow_all is set, then letting explicit keys
    // override.
    let allow_all = obj
        .get("allow_all")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let allow_default = || if allow_all { Some(vec![]) } else { None };
    let allow = |key: &str| {
        obj.get(key)
            .and_then(parse_string_list)
            .or_else(allow_default)
    };

    let opts = deno_runtime::deno_permissions::PermissionsOptions {
        allow_env: allow("allow_env"),
        deny_env: obj.get("deny_env").and_then(parse_string_list),
        allow_net: allow("allow_net"),
        deny_net: obj.get("deny_net").and_then(parse_string_list),
        allow_ffi: allow("allow_ffi"),
        deny_ffi: obj.get("deny_ffi").and_then(parse_string_list),
        allow_read: allow("allow_read"),
        deny_read: obj.get("deny_read").and_then(parse_string_list),
        allow_run: allow("allow_run"),
        deny_run: obj.get("deny_run").and_then(parse_string_list),
        allow_sys: allow("allow_sys"),
        deny_sys: obj.get("deny_sys").and_then(parse_string_list),
        allow_write: allow("allow_write"),
        deny_write: obj.get("deny_write").and_then(parse_string_list),
        allow_import: allow("allow_import"),
        deny_import: obj.get("deny_import").and_then(parse_string_list),
        ignore_env: None,
        ignore_read: None,
        prompt: false,
    };

    let perms =
        deno_runtime::deno_permissions::Permissions::from_options(descriptor_parser.as_ref(), &opts)
            .map_err(|err| Error {
                message: Some(format!("invalid permissions: {err}")),
                name: atoms::execution_error(),
                value: None,
            })?;

    Ok(deno_runtime::deno_permissions::PermissionsContainer::new(
        descriptor_parser,
        perms,
    ))
}

pub async fn new(
    runtime_id: usize,
    main_module_path: String,
    permissions_json: String,
) -> Result<MainWorker, Error> {
    let _ = deno_runtime::deno_tls::rustls::crypto::aws_lc_rs::default_provider().install_default();
    let cwd = std::env::current_dir().map_err(|err| Error {
        message: Some(format!("could not get current dir: {err}")),
        name: atoms::execution_error(),
        value: None,
    })?;
    let path = cwd.join(main_module_path);
    let main_module = deno_core::ModuleSpecifier::from_file_path(&path).map_err(|_| Error {
        message: Some(format!(
            "could not build module specifier from path: {}",
            path.display()
        )),
        name: atoms::execution_error(),
        value: None,
    })?;
    let permissions = build_permissions(&permissions_json)?;
    let mut worker = MainWorker::bootstrap_from_options(
        &main_module,
        deno_runtime::worker::WorkerServiceOptions::<
            deno_resolver::npm::DenoInNpmPackageChecker,
            deno_resolver::npm::NpmResolver<sys_traits::impls::RealSys>,
            sys_traits::impls::RealSys,
        > {
            blob_store: Default::default(),
            broadcast_channel: Default::default(),
            compiled_wasm_module_store: Default::default(),
            feature_checker: Default::default(),
            fetch_dns_resolver: Default::default(),
            fs: std::sync::Arc::new(deno_fs::RealFs),
            module_loader: std::rc::Rc::new(deno_core::FsModuleLoader),
            node_services: Default::default(),
            npm_process_state_provider: Default::default(),
            permissions,
            root_cert_store_provider: Default::default(),
            shared_array_buffer_store: Default::default(),
            v8_code_cache: Default::default(),
            deno_rt_native_addon_loader: None,
            bundle_provider: None,
        },
        deno_runtime::worker::WorkerOptions {
            extensions: vec![extension::init()],
            ..Default::default()
        },
    );
    worker
        .execute_script(
            "<anon>",
            format!("Tyrex._runtimeId = \"{}\"", runtime_id)
                .to_string()
                .into(),
        )
        .map_err(|err| Error {
            message: Some(format!("could not seed Tyrex._runtimeId: {err}")),
            name: atoms::execution_error(),
            value: None,
        })?;
    worker
        .execute_main_module(&main_module)
        .await
        .map_err(|error| Error {
            message: Some(error.to_string()),
            name: atoms::execution_error(),
            value: None,
        })?;
    Ok(worker)
}

type PromiseSlab = slab::Slab<(
    deno_core::v8::Global<deno_core::v8::Value>,
    Sender<Result<String, Error>>,
)>;

/// Send a `dead_runtime_error` to every pending promise's response sender, so
/// callers waiting on `Tyrex.eval` get an immediate error instead of hanging
/// until their GenServer timeout fires.
fn drain_pending_promises(promises: &mut PromiseSlab) {
    let drained = std::mem::take(promises);
    for (_, (_global, response_sender)) in drained {
        let _ = response_sender
            .send(Err(Error {
                message: None,
                name: atoms::dead_runtime_error(),
                value: None,
            }))
            .ok();
    }
}

pub async fn run(
    runtime_id: usize,
    mut worker: MainWorker,
    mut worker_receiver: tokio::sync::mpsc::UnboundedReceiver<Message>,
) {
    let mut promises: PromiseSlab = slab::Slab::new();
    let mut poll_event_loop = true;
    loop {
        tokio::select! {
            Some(message) = worker_receiver.recv() => {
                match message {
                    Message::Stop(response_sender) => {
                        worker_receiver.close();
                        // Stop's ack is shutdown synchronization, not caller data.
                        // The Drop impl on `Runtime` sends a fire-and-forget Stop
                        // whose oneshot receiver is dropped immediately, so this
                        // send routinely fails on benign teardown. Silently OK.
                        let _ = response_sender.send(());
                        runtimes::lock_or_recover().try_remove(runtime_id);
                        drain_pending_promises(&mut promises);
                        break;
                    },
                    Message::ApplyReply(application_id, result) => {
                        let (kind, value) = match result {
                            Ok(value) => ("resolve", value),
                            Err(value) => ("reject", value),
                        };
                        // Avoid string-format injection by building each argument
                        // as a properly JSON-encoded literal that the JS bridge
                        // will JSON.parse internally.
                        let script = match (
                            serde_json::to_string(&application_id),
                            serde_json::to_string(kind),
                            serde_json::to_string(&value),
                        ) {
                            (Ok(id_lit), Ok(kind_lit), Ok(value_lit)) => {
                                format!(
                                    "globalThis.Tyrex._applyReply({id_lit}, {kind_lit}, {value_lit})"
                                )
                            }
                            _ => {
                                eprintln!(
                                    "tyrex: could not serialize ApplyReply payload for runtime {runtime_id}"
                                );
                                continue;
                            }
                        };
                        if let Err(err) = worker.execute_script("<anon>", script.into()) {
                            eprintln!(
                                "tyrex: Tyrex._applyReply execute_script failed on runtime {runtime_id}: {err}"
                            );
                        }
                        poll_event_loop = true;
                    },
                    Message::Eval(code, response_sender) => {
                        match worker.execute_script("<anon>", code.into()) {
                            Ok(global) => {
                                let is_promise = {
                                    deno_core::scope!(scope, worker.js_runtime);
                                    let local = deno_core::v8::Local::new(scope, &global);
                                    local.is_promise()
                                };
                                if is_promise {
                                    promises.insert((global, response_sender));
                                } else {
                                    deno_core::scope!(scope, worker.js_runtime);
                                    let local = deno_core::v8::Local::new(scope, &global);
                                    match serde_v8::from_v8::<serde_json::Value>(scope, local) {
                                        Ok(value) => {
                                            if response_sender.send(Ok(value.to_string())).is_err() {
                                                eprintln!(
                                                    "tyrex: lost reply for Eval result on runtime {runtime_id}"
                                                );
                                            }
                                        },
                                        Err(_) => {
                                            if response_sender.send(
                                                Err(
                                                    Error {
                                                        message: None,
                                                        name: atoms::conversion_error(),
                                                        value: None
                                                    }
                                                )
                                            ).is_err() {
                                                eprintln!(
                                                    "tyrex: lost reply for Eval conversion-error on runtime {runtime_id}"
                                                );
                                            }
                                        }
                                    }
                                }
                            },
                            Err(error) => {
                                if response_sender.send(
                                    Err(
                                        Error {
                                            message: Some(error.to_string()),
                                            name: atoms::execution_error(),
                                            value: None
                                        }
                                    )
                                ).is_err() {
                                    eprintln!(
                                        "tyrex: lost reply for Eval execution-error on runtime {runtime_id}"
                                    );
                                }
                            }
                        };
                        poll_event_loop = true;
                    }
                }
            },
            _ = run_event_loop(&mut worker, &mut promises, runtime_id), if poll_event_loop => {
                poll_event_loop = false;
            },
            else => {
                runtimes::lock_or_recover().try_remove(runtime_id);
                drain_pending_promises(&mut promises);
                break;
            }
        }
    }
}

async fn run_event_loop(
    worker: &mut MainWorker,
    promises: &mut PromiseSlab,
    runtime_id: usize,
) -> Result<(), deno_core::error::CoreError> {
    std::future::poll_fn(|cx| {
        let poll = worker.js_runtime.poll_event_loop(cx, Default::default());
        deno_core::scope!(scope, worker.js_runtime);
        let resolved_promises: Vec<_> = promises
            .iter()
            .filter_map(|(key, (global, _))| {
                let local = deno_core::v8::Local::new(scope, global);
                let promise = match deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local) {
                    Ok(p) => p,
                    Err(_) => {
                        eprintln!(
                            "tyrex: stored promise on runtime {runtime_id} was not a Promise; skipping"
                        );
                        return None;
                    }
                };
                if matches!(
                    promise.state(),
                    deno_core::v8::PromiseState::Fulfilled | deno_core::v8::PromiseState::Rejected
                ) {
                    Some(key)
                } else {
                    None
                }
            })
            .collect();
        for promise_key in resolved_promises {
            let (global, response_sender) = promises.remove(promise_key);
            let local = deno_core::v8::Local::new(scope, global);
            let promise = match deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local) {
                Ok(p) => p,
                Err(_) => {
                    eprintln!(
                        "tyrex: resolved entry on runtime {runtime_id} was not a Promise; skipping reply"
                    );
                    continue;
                }
            };
            let result = promise.result(scope);
            match serde_v8::from_v8::<serde_json::Value>(scope, result) {
                Ok(value) => {
                    if promise.state() == deno_core::v8::PromiseState::Fulfilled {
                        if response_sender.send(Ok(value.to_string())).is_err() {
                            eprintln!(
                                "tyrex: lost reply for promise-resolve on runtime {runtime_id}"
                            );
                        }
                    } else if response_sender
                        .send(Err(Error {
                            message: None,
                            name: atoms::promise_rejection(),
                            value: Some(value.to_string()),
                        }))
                        .is_err()
                    {
                        eprintln!(
                            "tyrex: lost reply for promise-rejection on runtime {runtime_id}"
                        );
                    }
                }
                Err(_) => {
                    if response_sender
                        .send(Err(Error {
                            message: None,
                            name: atoms::conversion_error(),
                            value: None,
                        }))
                        .is_err()
                    {
                        eprintln!(
                            "tyrex: lost reply for promise conversion-error on runtime {runtime_id}"
                        );
                    }
                }
            }
        }
        poll
    })
    .await
}
