use crate::atoms;
use crate::error::Error;
use crate::runtimes;
use crate::util;
use deno_core::error::ModuleLoaderError;
use deno_core::op2;
use deno_core::OpState;
use deno_runtime::worker::MainWorker;
use tokio::sync::oneshot::Sender;

pub enum Message {
    ApplyReply(String, Result<String, String>),
    Eval(String, Sender<Result<String, Error>>),
    Stop(Sender<()>),
}

/// The runtime's slab id, kept in per-runtime `OpState`.
///
/// It used to travel from JS as `Tyrex._runtimeId`, which made it a
/// guest-writable choice of *which* runtime's GenServer authorizes an `:apply`
/// call. Since the allowlist is per-runtime, a guest that overwrote it could
/// have its call authorized against a sibling runtime's allowlist. `OpState` is
/// per-runtime and unreachable from JavaScript, so the id is no longer input.
struct RuntimeId(usize);

#[op2(fast)]
fn op_apply(
    state: &mut OpState,
    #[string] application_id: String,
    #[string] module: String,
    #[string] function_name: String,
    #[string] args: String,
) {
    let runtime_id = state.borrow::<RuntimeId>().0;
    let slab = runtimes::lock_or_recover();
    // op_apply is reachable from arbitrary JS in the runtime; every input must
    // be tolerated. A missing pid means the runtime is being torn down, which
    // is logged and dropped — never panicked on.
    //
    // "Logged" means `eprintln!`, here and at every other diagnostic in this
    // file: the OS stderr, not `Logger`. A NIF cannot call `Logger`, so a
    // released app sees these only if it captures the node's stderr, and
    // otherwise loses them. Routing them to the host means sending a message
    // to the owning GenServer, which needs a receiving clause on the Elixir
    // side (`handle_info/2` has no catch-all today, so an unmatched
    // diagnostic would crash the very runtime it describes). That is a design
    // decision about a log-forwarding channel, not a cleanup, so it is not
    // taken here.
    let pid = match slab.get(runtime_id) {
        Some(pid) => pid,
        None => {
            eprintln!(
                "tyrex: op_apply could not find pid for runtime_id {runtime_id}; dropping reply"
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
    options = { runtime_id: usize },
    state = |state, options| {
        state.put(deno_runtime::ops::bootstrap::SnapshotOptions::default());
        state.put(RuntimeId(options.runtime_id));
    }
);

/// `FsModuleLoader` receives no `PermissionsContainer` and ends in a bare
/// `std::fs::read`, so before this wrapper `import()` read any file the BEAM
/// user could read under *any* permission set: `permissions: :none` denied
/// `Deno.readTextFileSync` while
/// `import("file:///etc/passwd", {with: {type: "json"}})` returned the parsed
/// contents, and `deny_import` was inert.
///
/// The check is `PermissionsContainer::check_specifier`, which is what deno
/// itself uses: a `file:` specifier is checked against *read* permissions, and
/// any other scheme against `allow_import`/`deny_import`.
///
/// The exemption is **positive**, not a negative test on deno's flags. Only
/// loads that happen before `execute_main_module` returns are exempt; after
/// that, every load is checked whatever deno labels it. That distinction is the
/// whole point:
///
/// `ModuleLoadOptions::is_dynamic_import` alone would be a proxy for the
/// operator/guest boundary rather than the boundary itself. `deno_core` has a
/// third load shape, `LoadInit::Side`, which resolves as
/// `ResolutionKind::Import` with `is_dynamic_import: false`
/// (`recursive_load.rs:202-204,248`) and is driven by the guest-facing
/// `op_import_sync` (`ops_builtin.rs:511-523`) — so it would bypass both hooks.
/// It is unreachable today only because deno's own `removeImportedOps()` strips
/// that op from `Deno.core.ops`, an upstream invariant tyrex neither states nor
/// pins. A `bootstrap_complete` latch does not care how a load is labelled or
/// which ops happen to be exposed, so a deno bump cannot silently reopen this.
///
/// The dynamic flags are still consulted, because they catch a guest `import()`
/// during bootstrap — a main module that dynamically imports at
/// module-evaluation time is guest-shaped even though the latch is still open.
struct PermissionedModuleLoader {
    inner: deno_core::FsModuleLoader,
    permissions: deno_runtime::deno_permissions::PermissionsContainer,
    /// Flipped once, after `execute_main_module` returns. `Cell` is sufficient:
    /// a `ModuleLoader` is held behind `Rc` on the single worker thread.
    bootstrap_complete: std::cell::Cell<bool>,
}

impl PermissionedModuleLoader {
    fn new(permissions: deno_runtime::deno_permissions::PermissionsContainer) -> Self {
        PermissionedModuleLoader {
            inner: deno_core::FsModuleLoader,
            permissions,
            bootstrap_complete: std::cell::Cell::new(false),
        }
    }

    /// Closes the operator's static-graph exemption. Everything loaded after
    /// this point is guest-initiated by definition.
    fn finish_bootstrap(&self) {
        self.bootstrap_complete.set(true);
    }

    fn must_check(&self, is_dynamic: bool) -> bool {
        is_dynamic || self.bootstrap_complete.get()
    }

    fn check(&self, specifier: &deno_core::ModuleSpecifier) -> Result<(), ModuleLoaderError> {
        self.permissions
            .check_specifier(
                specifier,
                deno_runtime::deno_permissions::CheckSpecifierKind::Dynamic,
            )
            .map_err(|err| ModuleLoaderError::generic(err.to_string()))
    }
}

impl deno_core::ModuleLoader for PermissionedModuleLoader {
    /// Checked here as well as in `load`, and both are load-bearing.
    ///
    /// `ModuleMap::load_dynamic_import` resolves *before* it consults the module
    /// map, so this is the only hook that sees an `import()` of an
    /// already-loaded specifier. Without it, a guest could re-import the main
    /// module's own static graph — no `load`, no read, no check — and the
    /// exemption for operator-supplied code would quietly extend to anything
    /// the operator had ever imported.
    fn resolve(
        &self,
        specifier: &str,
        referrer: &str,
        kind: deno_core::ResolutionKind,
    ) -> Result<deno_core::ModuleSpecifier, ModuleLoaderError> {
        let is_dynamic = kind == deno_core::ResolutionKind::DynamicImport;
        let resolved = self.inner.resolve(specifier, referrer, kind)?;

        if self.must_check(is_dynamic) {
            self.check(&resolved)?;
        }

        Ok(resolved)
    }

    /// `import.meta.resolve` is pure URL arithmetic — it reads nothing — so it
    /// keeps the unchecked path even though its default implementation would
    /// route through `resolve` with `DynamicImport`.
    fn import_meta_resolve(
        &self,
        specifier: &str,
        referrer: &str,
    ) -> Result<deno_core::ModuleSpecifier, ModuleLoaderError> {
        self.inner.import_meta_resolve(specifier, referrer)
    }

    /// The check that guards the actual `std::fs::read`. `resolve` already
    /// rejected the specifier, but a loader whose only check lives in `resolve`
    /// is one refactor away from reading files again.
    fn load(
        &self,
        module_specifier: &deno_core::ModuleSpecifier,
        maybe_referrer: Option<&deno_core::ModuleLoadReferrer>,
        options: deno_core::ModuleLoadOptions,
    ) -> deno_core::ModuleLoadResponse {
        if self.must_check(options.is_dynamic_import) {
            if let Err(err) = self.check(module_specifier) {
                return deno_core::ModuleLoadResponse::Sync(Err(err));
            }
        }

        self.inner.load(module_specifier, maybe_referrer, options)
    }
}

/// Every permission key tyrex understands. Anything else is a typo, and a typo
/// in a security control must not be silently ignored: `[deny_nett: true]`
/// previously produced a fully permissive runtime that reported success.
const PERMISSION_KEYS: &[&str] = &[
    "allow_all",
    "allow_env",
    "deny_env",
    "allow_net",
    "deny_net",
    "allow_ffi",
    "deny_ffi",
    "allow_read",
    "deny_read",
    "allow_run",
    "deny_run",
    "allow_sys",
    "deny_sys",
    "allow_write",
    "deny_write",
    "allow_import",
    "deny_import",
];

fn permissions_error(message: String) -> Error {
    Error {
        message: Some(message),
        name: atoms::execution_error(),
        value: None,
    }
}

/// The three shapes a permission value may take. Kept direction-neutral,
/// because the same literal means opposite things for `allow_*` and `deny_*`:
/// an empty list allows nothing but denies nothing.
enum PermValue {
    True,
    False,
    List(Vec<String>),
}

fn parse_perm_value(key: &str, value: &serde_json::Value) -> Result<PermValue, Error> {
    match value {
        serde_json::Value::Bool(true) => Ok(PermValue::True),
        serde_json::Value::Bool(false) => Ok(PermValue::False),
        serde_json::Value::Array(arr) => {
            let mut items = Vec::with_capacity(arr.len());
            for (index, item) in arr.iter().enumerate() {
                match item.as_str() {
                    // Silently dropping a non-string entry would quietly widen
                    // the grant, so refuse the whole runtime instead.
                    Some(s) => items.push(s.to_string()),
                    None => {
                        return Err(permissions_error(format!(
                            "permission {key}[{index}] must be a string, got {item}"
                        )))
                    }
                }
            }
            Ok(PermValue::List(items))
        }
        other => Err(permissions_error(format!(
            "permission {key} must be true, false, or a list of strings, got {other}"
        ))),
    }
}

/// Deno encodes an `allow_*` grant as `Option<Vec<String>>`, where `None` is
/// "not granted" and `Some(vec![])` is "granted without restriction".
fn allow_option(value: PermValue) -> Option<Vec<String>> {
    match value {
        PermValue::True => Some(vec![]),
        PermValue::False => None,
        // An empty allowlist grants zero paths/hosts/vars. Mapping it to
        // `Some(vec![])` — as the previous code did — inverted it into a grant
        // over everything, so `allow_read: []` handed out the whole filesystem.
        PermValue::List(list) if list.is_empty() => None,
        PermValue::List(list) => Some(list),
    }
}

/// For `deny_*` the polarity flips: `Some(vec![])` denies everything and an
/// empty list denies nothing.
fn deny_option(value: PermValue) -> Option<Vec<String>> {
    match value {
        PermValue::True => Some(vec![]),
        PermValue::False => None,
        PermValue::List(list) if list.is_empty() => None,
        PermValue::List(list) => Some(list),
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

    // Every failure below returns Err. A sandbox that cannot understand its own
    // configuration must refuse to start; the previous code fell back to
    // `allow_all`, so a malformed payload silently produced the most privileged
    // runtime available while still reporting success.
    let parsed: serde_json::Value = serde_json::from_str(permissions_json)
        .map_err(|err| permissions_error(format!("permissions are not valid JSON: {err}")))?;

    if let Some(name) = parsed.as_str() {
        return if name == "allow_all" {
            Ok(deno_runtime::deno_permissions::PermissionsContainer::allow_all(descriptor_parser))
        } else {
            Err(permissions_error(format!(
                "unknown permissions preset {name:?}, expected \"allow_all\""
            )))
        };
    }

    let obj = parsed.as_object().ok_or_else(|| {
        permissions_error(format!(
            "permissions must be an object or \"allow_all\", got {parsed}"
        ))
    })?;

    for key in obj.keys() {
        if !PERMISSION_KEYS.contains(&key.as_str()) {
            return Err(permissions_error(format!(
                "unknown permission key {key:?}; known keys: {}",
                PERMISSION_KEYS.join(", ")
            )));
        }
    }

    // `allow_all` is a baseline switch, not a list. `allow_all: ["/tmp"]` used
    // to parse to `PermValue::List` and then read as `false` through
    // `matches!(..., True)` — fail-closed, so never a hole, but the one place in
    // this parser that silently reinterpreted a shape it was handed. That is
    // exactly what the comment above `PERMISSION_KEYS` refuses to do.
    let allow_all =
        match obj.get("allow_all") {
            Some(value) => match parse_perm_value("allow_all", value)? {
                PermValue::True => true,
                PermValue::False => false,
                PermValue::List(_) => return Err(permissions_error(
                    "permission allow_all must be true or false, not a list — it is a baseline \
                     for every other key, so a list of paths or hosts has no meaning here"
                        .to_string(),
                )),
            },
            None => false,
        };

    // `allow_all: true` is a baseline that explicit keys override in BOTH
    // directions. Previously an explicit `allow_X: false` parsed to `None` and
    // was then swallowed by `.or_else(allow_default)`, so under `allow_all`
    // every explicit denial was re-granted as unrestricted access.
    let allow = |key: &str| -> Result<Option<Vec<String>>, Error> {
        match obj.get(key) {
            Some(value) => Ok(allow_option(parse_perm_value(key, value)?)),
            None if allow_all => Ok(Some(vec![])),
            None => Ok(None),
        }
    };
    let deny = |key: &str| -> Result<Option<Vec<String>>, Error> {
        match obj.get(key) {
            Some(value) => Ok(deny_option(parse_perm_value(key, value)?)),
            None => Ok(None),
        }
    };

    let opts = deno_runtime::deno_permissions::PermissionsOptions {
        allow_env: allow("allow_env")?,
        deny_env: deny("deny_env")?,
        allow_net: allow("allow_net")?,
        deny_net: deny("deny_net")?,
        allow_ffi: allow("allow_ffi")?,
        deny_ffi: deny("deny_ffi")?,
        allow_read: allow("allow_read")?,
        deny_read: deny("deny_read")?,
        allow_run: allow("allow_run")?,
        deny_run: deny("deny_run")?,
        allow_sys: allow("allow_sys")?,
        deny_sys: deny("deny_sys")?,
        allow_write: allow("allow_write")?,
        deny_write: deny("deny_write")?,
        allow_import: allow("allow_import")?,
        deny_import: deny("deny_import")?,
        ignore_env: None,
        ignore_read: None,
        prompt: false,
    };

    let perms = deno_runtime::deno_permissions::Permissions::from_options(
        descriptor_parser.as_ref(),
        &opts,
    )
    .map_err(|err| permissions_error(format!("invalid permissions: {err}")))?;

    Ok(deno_runtime::deno_permissions::PermissionsContainer::new(
        descriptor_parser,
        perms,
    ))
}

/// A booted runtime plus the out-of-band handles the rest of the crate needs.
pub struct Worker {
    pub worker: MainWorker,
    pub isolate_handle: deno_core::v8::IsolateHandle,
    /// Set when the heap cap is hit, so the subsequent uncatchable termination
    /// error can be reported as `:heap_limit_error` rather than a bare dead
    /// runtime. Sticky on purpose: V8 clears its own
    /// `is_execution_terminating` flag once the termination has propagated out
    /// of the outermost script.
    ///
    /// The near-heap-limit closure owns a clone of this `Arc`, and
    /// `JsRuntime::add_near_heap_limit_callback` boxes that closure into
    /// `JsRuntime::allocations` — a field declared after `inner` precisely so it
    /// outlives the isolate. That is the invariant; tyrex does not hand-roll it.
    pub heap_limit_tripped: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}

/// Headroom handed to V8 once when the heap cap is hit, so it can unwind and
/// report instead of calling `abort()` — which would take down the whole BEAM,
/// not just the guest.
const HEAP_LIMIT_SLACK_BYTES: usize = 8 * 1024 * 1024;

/// Which of the host process's standard streams guest JavaScript inherits.
///
/// **stdin is closed; stdout and stderr are inherited.** The asymmetry is
/// deliberate, and it follows from where each capability actually lives.
///
/// Deno's permission model does not govern file descriptors 0/1/2 at all — the
/// `deno_io` extension registers them as rids 0/1/2 from `Stdio::default()`,
/// which inherits. Correct for a CLI; wrong for a runtime embedded in someone
/// else's OS process. Under `permissions: :none`, guest JS could read the host's
/// stdin, which on an attached `iex` is the operator's keyboard. Nothing wants
/// that, so it is pointed at `/dev/null` and `Deno.stdin.readSync` returns EOF.
///
/// Output is a different case and is NOT closed, because closing it would be
/// theatre. `console.log` does not go through these rids: it reaches
/// `op_print`, which writes to Rust's own `stdout()` directly
/// (`deno_core-0.391.0/ops_builtin.rs:219-231`). Piping rid 1 would therefore
/// stop `Deno.stdout.writeSync` while leaving a guest perfectly able to forge
/// host output through `console.log` — half a fix, at the cost of the most
/// useful debugging affordance JavaScript has. Output forging is inherent to
/// embedding a JS runtime in-process and is documented as such rather than
/// papered over.
///
/// If the null device cannot be opened, inherit rather than refuse to start: a
/// runtime that boots with an unexpectedly readable stdin is worse than no
/// runtime only if the operator is not told, and this is logged.
fn guest_stdio() -> deno_runtime::deno_io::Stdio {
    let stdin = match std::fs::OpenOptions::new().read(true).open(NULL_DEVICE) {
        Ok(file) => deno_runtime::deno_io::StdioPipe::file(file),
        Err(err) => {
            eprintln!(
                "tyrex: could not open {NULL_DEVICE} to close the guest's stdin ({err}); \
                 guest JavaScript will inherit the host's stdin"
            );
            deno_runtime::deno_io::StdioPipe::inherit()
        }
    };

    deno_runtime::deno_io::Stdio {
        stdin,
        stdout: deno_runtime::deno_io::StdioPipe::inherit(),
        stderr: deno_runtime::deno_io::StdioPipe::inherit(),
    }
}

#[cfg(windows)]
const NULL_DEVICE: &str = "NUL";
#[cfg(not(windows))]
const NULL_DEVICE: &str = "/dev/null";

pub async fn new(
    runtime_id: usize,
    main_module_path: String,
    permissions_json: String,
    apply_enabled: bool,
    max_heap_mb: Option<u64>,
) -> Result<Worker, Error> {
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
    let create_params = max_heap_mb.map(|mb| {
        let max_bytes = (mb as usize).saturating_mul(1024 * 1024);
        deno_core::v8::CreateParams::default().heap_limits(0, max_bytes)
    });
    let module_loader = std::rc::Rc::new(PermissionedModuleLoader::new(permissions.clone()));
    // Kept so the exemption can be closed once the operator's main module has
    // finished evaluating. Everything loaded after that is guest-initiated.
    let loader = std::rc::Rc::clone(&module_loader);
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
            module_loader,
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
            extensions: vec![extension::init(runtime_id)],
            create_params,
            stdio: guest_stdio(),
            ..Default::default()
        },
    );

    let isolate_handle = worker.js_runtime.v8_isolate().thread_safe_handle();

    // `create_params` caps the heap at isolate creation, but V8's default
    // response to hitting that cap is `abort()` — the whole BEAM, not the guest.
    // This callback is what turns the cap into a reportable error. It cannot be
    // installed any earlier: the isolate does not exist until
    // `bootstrap_from_options` returns, so deno's bootstrap and snapshot
    // deserialization run unprotected. That is why `:max_heap_mb` has a floor.
    let heap_limit_tripped = max_heap_mb.map(|_| {
        let tripped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = std::sync::Arc::clone(&tripped);
        let handle = isolate_handle.clone();
        worker.js_runtime.add_near_heap_limit_callback(
            move |current_heap_limit, _initial_heap_limit| {
                flag.store(true, std::sync::atomic::Ordering::SeqCst);
                handle.terminate_execution();
                // Raising the limit is what lets V8 unwind rather than abort, and
                // execution is already terminated, so the slack only ever funds
                // teardown.
                //
                // This MUST return a strictly greater limit every single time.
                // `Heap::InvokeNearHeapLimitCallback` treats an unraised limit as
                // callback failure and calls `FatalProcessOutOfMemory` — abort()
                // — so V8 offers no way to say "fail this allocation". A previous
                // version granted the slack only once, to stop the ceiling
                // ratcheting by 8MB per invocation; that made every second
                // invocation fatal to the whole BEAM. Verified by making the
                // callback never grow: an allocation shape that terminates
                // cleanly with growth instead died with "Fatal JavaScript out of
                // memory". The ratchet is bounded by terminate-means-dead: the
                // runtime is already dead, so growth is bounded in wall-clock.
                current_heap_limit + HEAP_LIMIT_SLACK_BYTES
            },
        );
        tripped
    });

    // `Worker` is removed unconditionally, and it is not optional hardening.
    // tyrex takes `WorkerOptions { ..Default::default() }`, whose
    // `create_web_worker_cb` is `|_| unimplemented!("web workers are not
    // supported")`. `op_create_worker` checks no permission, so under
    // `permissions: :none` two lines of guest JavaScript —
    // `new Worker(url, {type: "module"})` — reach that `unimplemented!()` on a
    // spawned thread, drop the handle sender, and make this thread's
    // `handle_receiver.recv().unwrap()` panic inside a V8 `extern "C"` callback.
    // That converts to `panic_cannot_unwind` and aborts the OS process: no
    // `catch_unwind` anywhere can contain it, and `deno_core` has none. Deleting
    // the constructor costs nothing, because web workers never worked here.
    //
    // The bridge is a privileged capability, not an ambient one. When it is off
    // we remove the global outright rather than leaving a disabled stub: guest
    // code then has no reference to reach, and `ext:` modules are structurally
    // unimportable from user code, so the op cannot be re-acquired. Nothing is
    // injected when the bridge is on — the runtime id lives in `OpState`, out of
    // guest reach.
    //
    // Both scripts are compile-time ASCII constants, so `ascii_str!` hands V8
    // an external one-byte const (`FastString`'s `StaticConst` arm) instead of
    // the heap-allocated `Owned` arm a built `String` lands in. They stay two
    // `execute_script` calls rather than one concatenated `String` for exactly
    // that reason, and each failure now names which seal did not take.
    let sealed = worker.execute_script(
        "<anon>",
        deno_core::ascii_str!("delete globalThis.Worker;").into(),
    );
    if let Err(err) = sealed {
        return Err(startup_error(
            &mut worker,
            heap_limit_tripped.as_deref(),
            format!("could not seal the guest global scope: {err}"),
        ));
    }

    if !apply_enabled {
        let removed = worker.execute_script(
            "<anon>",
            deno_core::ascii_str!("delete globalThis.Tyrex;").into(),
        );
        if let Err(err) = removed {
            return Err(startup_error(
                &mut worker,
                heap_limit_tripped.as_deref(),
                format!("could not remove the disabled Tyrex bridge: {err}"),
            ));
        }
    }

    let evaluated = worker.execute_main_module(&main_module).await;

    // Close the operator's static-graph exemption before returning, on the error
    // path too: a main module that failed to evaluate must not leave a runtime
    // whose loader still trusts static loads.
    loader.finish_bootstrap();

    if let Err(error) = evaluated {
        return Err(startup_error(
            &mut worker,
            heap_limit_tripped.as_deref(),
            error.to_string(),
        ));
    }

    Ok(Worker {
        worker,
        isolate_handle,
        heap_limit_tripped,
    })
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

/// Whether execution ended because tyrex tore it down, and if so why.
///
/// Termination is uncatchable inside V8 and leaves the isolate refusing all
/// further JavaScript until `cancel_terminate_execution` is called, so tyrex
/// does not try to nurse a terminated isolate back to health: terminate means
/// the runtime is dead, and the caller (or its supervisor) starts a fresh one.
/// That contract is cheap, deterministic, and testable; "sometimes recovers"
/// is none of those.
///
/// `is_execution_terminating` alone is not sufficient. V8 clears the flag once
/// the termination has propagated out of the outermost script, so by the time
/// `execute_script` returns it frequently reads false — which is why the heap
/// cap has its own sticky flag rather than relying on the isolate's state.
fn termination_error(
    worker: &mut MainWorker,
    heap_limit_tripped: Option<&std::sync::atomic::AtomicBool>,
) -> Option<Error> {
    let tripped_heap_limit =
        heap_limit_tripped.is_some_and(|tripped| tripped.load(std::sync::atomic::Ordering::SeqCst));

    if tripped_heap_limit {
        Some(Error {
            message: Some("guest exceeded its :max_heap_mb heap limit".to_string()),
            name: atoms::heap_limit_error(),
            value: None,
        })
    } else if worker.js_runtime.v8_isolate().is_execution_terminating() {
        Some(Error {
            message: Some("execution was terminated".to_string()),
            name: atoms::dead_runtime_error(),
            value: None,
        })
    } else {
        None
    }
}

/// Attribute a failure from one of `worker::new`'s post-bootstrap steps.
///
/// The near-heap-limit callback is installed, and its sticky flag live, before
/// the bootstrap scripts and `execute_main_module` run, so a
/// `:main_module_path` that blows a tight `:max_heap_mb` trips the cap *here*,
/// not in `run`. Mapping those errors straight to `execution_error` handed the
/// operator V8's uninformative post-termination message at `Tyrex.start/1`
/// with no hint that the cap was what killed it — and the `Worker`, and with
/// it the flag, is dropped on the error return, so nothing downstream can
/// recover the attribution.
fn startup_error(
    worker: &mut MainWorker,
    heap_limit_tripped: Option<&std::sync::atomic::AtomicBool>,
    fallback: String,
) -> Error {
    termination_error(worker, heap_limit_tripped).unwrap_or_else(|| Error {
        message: Some(fallback),
        name: atoms::execution_error(),
        value: None,
    })
}

pub async fn run(
    runtime_id: usize,
    handle: Worker,
    mut worker_receiver: tokio::sync::mpsc::UnboundedReceiver<Message>,
) {
    let Worker {
        mut worker,
        isolate_handle: _isolate_handle,
        heap_limit_tripped,
    } = handle;
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
                        if termination_error(&mut worker, heap_limit_tripped.as_deref()).is_some() {
                                drain_pending_promises(&mut promises);
                            break;
                        }
                        poll_event_loop = true;
                    },
                    Message::Eval(code, response_sender) => {
                        let mut terminated = false;
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
                                // A terminated script reports an uncatchable,
                                // uninformative error. Attribute it correctly:
                                // the caller asked for a deadline or blew the
                                // heap cap, and deserves to be told which.
                                let reply = match termination_error(
                                    &mut worker,
                                    heap_limit_tripped.as_deref(),
                                ) {
                                    Some(reason) => {
                                        terminated = true;
                                        reason
                                    }
                                    None => Error {
                                        message: Some(error.to_string()),
                                        name: atoms::execution_error(),
                                        value: None,
                                    },
                                };
                                if response_sender.send(Err(reply)).is_err() {
                                    eprintln!(
                                        "tyrex: lost reply for Eval execution-error on runtime {runtime_id}"
                                    );
                                }
                            }
                        };
                        if terminated {
                                drain_pending_promises(&mut promises);
                            break;
                        }
                        poll_event_loop = true;
                    }
                }
            },
            _ = run_event_loop(&mut worker, &mut promises, runtime_id), if poll_event_loop => {
                // A termination raised while draining microtasks would otherwise
                // spin here forever: `poll_event_loop` on a terminated isolate
                // returns Ready(Err) immediately, every time.
                if termination_error(&mut worker, heap_limit_tripped.as_deref()).is_some() {
                    drain_pending_promises(&mut promises);
                    break;
                }
                poll_event_loop = false;
            },
            else => {
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
