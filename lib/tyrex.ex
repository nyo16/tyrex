defmodule Tyrex do
  @moduledoc """
  Embedded Deno JS/TS runtime for Elixir.

  Tyrex wraps the Deno runtime as a GenServer, allowing you to evaluate JavaScript
  and TypeScript code directly from Elixir. Each runtime is an isolated V8 instance
  with access to Deno APIs, subject to the permissions you grant it.

  ## Quick Start

      {:ok, pid} = Tyrex.start(permissions: :none)
      {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
      Tyrex.stop(pid: pid)

  ## Named Runtime

      # In your supervision tree
      {Tyrex, name: MyApp.JS, main_module_path: "priv/js/app.js"}

      # Then anywhere
      {:ok, result} = Tyrex.eval("processData()", name: MyApp.JS)

  ## Calling Elixir from JavaScript

  The `Tyrex.apply` bridge is a **privileged capability and is off by default**.
  When enabled you must name exactly which functions guest JavaScript may reach:

      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      Tyrex.eval(~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|, pid: pid)
      # => {:ok, 6}

  Anything not on the allowlist rejects the JavaScript promise with a message
  beginning `permission_denied:`. With `apply: false` (the default) the bridge is
  not installed at all — `globalThis.Tyrex` is deleted after bootstrap, so guest
  code has no reference to reach.

  > #### `:permissions` does not govern this {: .warning}
  >
  > `:permissions` controls Deno's own I/O — files, network, env, subprocesses.
  > It has never governed which Elixir code the bridge can reach. Before v0.4.0
  > the bridge was installed unconditionally, so `permissions: :none` denied
  > `Deno.readTextFileSync` while still granting `File.read!` and `:os.cmd`
  > through `Tyrex.apply`. That is why the bridge is now opt-in.

  ## Supervision and error handling

  `Tyrex.start_link/1` follows the standard OTP shape, so a `Tyrex` runtime
  (and `Tyrex.Pool`) can be added directly to a supervisor's child list.
  Runtime errors are returned as `{:error, %Tyrex.Error{}}` from the run/eval
  API; see the **Error handling** section of the README for a full breakdown
  of the possible `:name` values and how to pattern-match them.

  A runtime that hits its `:timeout` deadline or its `:max_heap_mb` cap is
  **terminated and dead**. V8 termination is uncatchable and sticky, so tyrex
  does not attempt to nurse a poisoned isolate back to health; under a
  supervisor the child is simply replaced.

  Replacement is not free, and guest code chooses how often it happens. Under a
  `Tyrex.Pool` the runtimes are supervised `:one_for_one`, so one guest's
  deadline does not disturb its siblings — but the caller whose runtime died
  still has to retry, a call arriving during the restart window gets
  `{:error, %Tyrex.Error{name: :dead_runtime_error}}`, and the pool's
  `:max_restarts` / `:max_seconds` ceiling still applies. Tune those if untrusted
  guests are expected to trip deadlines routinely; see `Tyrex.Pool.start_link/1`.
  """

  use GenServer

  require Logger

  alias Tyrex.Error
  alias Tyrex.Native
  alias Tyrex.Runtime

  @default_eval_timeout 5_000
  @default_startup_timeout 30_000
  @default_stop_timeout 5_000

  # The server-side deadline must win the race against the caller's own
  # `GenServer.call` timeout, otherwise the caller exits with `:timeout` before
  # the runtime is ever terminated — which is precisely the pre-0.4.0 defect.
  @deadline_grace_ms 1_000

  # `:max_heap_mb` reaches V8 as `CreateParams::heap_limits`, which is honoured
  # from isolate creation — but the near-heap-limit callback that turns an
  # exhausted heap into a terminated *guest* cannot be installed until the
  # isolate exists, so deno's bootstrap and snapshot deserialization (the
  # heaviest allocation phase in a runtime's life) always run under V8's default
  # `abort()`. Measured on arm64 macOS with V8 146.4.0: `max_heap_mb: 13` aborts
  # the whole BEAM inside `bootstrap_from_options` with `v8::base::FatalOOM`,
  # while 14 boots reliably (5/5). The enforced floor is ~2.3x the measured
  # minimum, deliberately generous because the failure mode is loss of the
  # entire VM rather than a failed `start/1`.
  @min_heap_mb 32
  @measured_min_heap_mb 14

  @runtime_opts [:main_module_path, :permissions, :startup_timeout, :apply, :max_heap_mb]

  @permission_keys [
    :allow_all,
    :allow_env,
    :deny_env,
    :allow_net,
    :deny_net,
    :allow_ffi,
    :deny_ffi,
    :allow_read,
    :deny_read,
    :allow_run,
    :deny_run,
    :allow_sys,
    :deny_sys,
    :allow_write,
    :deny_write,
    :allow_import,
    :deny_import
  ]

  @doc """
  Start a Tyrex process without any main module.

  See `start/1` for more information.

  ## Examples

      iex> {:ok, pid} = Tyrex.start(permissions: :none)
      iex> Tyrex.eval("1 + 2", pid: pid)
      {:ok, 3}
  """
  @spec start() :: GenServer.on_start()
  def start do
    start([])
  end

  @doc """
  Start a Tyrex process.

  ## Options

    * `:main_module_path` - Path to the main JavaScript module. The default is
      to start the runtime without a main module.
    * `:permissions` - Runtime permissions. Defaults to `:none`. See
      "Permissions" below.
    * `:apply` - Whether guest JavaScript may call Elixir through
      `Tyrex.apply`. Defaults to `false`. See "The apply bridge" below.
    * `:max_heap_mb` - Cap the V8 heap, in megabytes. Unset by default, in
      which case a guest that exhausts memory `abort()`s the entire BEAM. The
      minimum is #{@min_heap_mb}; a smaller cap raises `ArgumentError`, because
      deno's bootstrap allocates before the near-heap-limit callback can be
      installed and so would `abort()` the BEAM at `start/1` — the outcome this
      option exists to prevent. Note the cap converts *incremental* heap growth
      into `:heap_limit_error`; it cannot save the node from a single allocation
      far larger than the cap, because V8 termination only takes effect at an
      interrupt check and a builtin never reaches one. See the README.
    * `:startup_timeout` - Maximum time in milliseconds to wait for the NIF
      to acknowledge runtime startup. Defaults to `30_000`. If the NIF does
      not respond in time, `init/1` returns `{:stop, :nif_startup_timeout}`.

  ## Permissions

  Control what Deno I/O the JavaScript runtime can perform:

    * `:none` — No permissioned Deno I/O (default). JavaScript can compute, but
      not read files, open sockets, read env, or spawn processes. It does **not**
      cover stdio: file descriptors 0/1/2 are inherited from the host OS process
      and Deno's permission model does not govern them, so guest code can still
      write to the node's stdout and read its stdin.
    * `:allow_all` — Full access to everything.
    * Keyword list — Granular control per permission type.

  Each permission key accepts `true`, `false`, or a list of strings. The same
  literal means opposite things depending on the key's direction, so the two
  directions are stated separately rather than together:

    * `allow_x: true` grants the permission without restriction.
      `allow_x: false` grants nothing. `allow_x: []` also grants nothing — an
      empty allowlist names zero paths, hosts or variables.
      `allow_x: ["a", "b"]` grants exactly those.
    * `deny_x: true` denies the permission outright. `deny_x: false` denies
      **nothing**; it is not "deny all", and `deny_read: false` leaves the file
      readable. `deny_x: []` likewise denies nothing.
      `deny_x: ["a", "b"]` denies exactly those.

  The keys:

    * `:allow_net` / `:deny_net` — Network access (`true`, `false`, or `["host:port", ...]`)
    * `:allow_read` / `:deny_read` — File read access (`true`, `false`, or `["/path", ...]`)
    * `:allow_write` / `:deny_write` — File write access
    * `:allow_env` / `:deny_env` — Environment variables (`true`, `false`, or `["VAR", ...]`)
    * `:allow_run` / `:deny_run` — Subprocess execution
    * `:allow_ffi` / `:deny_ffi` — Foreign function interface
    * `:allow_sys` / `:deny_sys` — System info (hostname, OS, etc.)
    * `:allow_import` / `:deny_import` — Dynamic `import()` of non-`file:`
      specifiers. **Deny-only in practice:** the module loader reads `file:` URLs
      only, so a remote import fails regardless of permissions and
      `allow_import` cannot make one succeed. `deny_import: true` is still
      worthwhile — it turns a confusing "is not a file URL" into an explicit
      permission denial. A dynamic `import()` of a `file:` specifier is governed
      by the read permissions above instead; the main module and its static
      import graph are operator-supplied and exempt from both. Vendor remote
      dependencies to disk if you need them.

  Parsing fails closed. An unknown key raises `ArgumentError` rather than being
  silently dropped, an empty `allow_x` list grants nothing rather than
  everything, and an explicit `allow_x: false` still denies under
  `allow_all: true`.

  ## The apply bridge

  `:apply` takes `false` (the default) or a list of `{Module, :function, arity}`
  tuples. Only those exact MFAs are callable from JavaScript; every entry must
  be exported at start time or `ArgumentError` is raised. Enforcement lives in
  this GenServer, not in JavaScript — a guard inside the isolate would be inside
  the blast radius.

  ## Examples

      iex> Tyrex.start(main_module_path: "path/to/main.js")

      # No Deno I/O (the default)
      iex> Tyrex.start(permissions: :none)

      # Only allow network and reading from /tmp
      iex> Tyrex.start(permissions: [allow_net: true, allow_read: ["/tmp"]])

      # Let JavaScript call exactly two Elixir functions
      iex> Tyrex.start(apply: [{Enum, :sum, 1}, {String, :upcase, 1}])
  """
  @spec start(Keyword.t()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, validate_opts!(opts))
  end

  @doc """
  Same as `stop/1`, but it assumes that there is a process with the name
  `Tyrex` (the default if you don't provide a name to `start_link/1`).
  """
  @spec stop() :: :ok
  def stop do
    stop([])
  end

  @doc """
  Stop a Tyrex process.

  ## Options

    * `:name` - The name of the Tyrex process. The default is `Tyrex`.
      Can't be provided if `:pid` is provided.
    * `:pid` - The pid of the Tyrex process. Can't be provided if `:name` is
      provided.
    * `:reason` - See `GenServer.stop/3`.
    * `:timeout` - Milliseconds to wait for a graceful stop. Defaults to
      `5_000`. On expiry the runtime is killed rather than waited on forever.

  The default was `:infinity` before v0.4.0, which meant a caller who did not
  override it hung permanently on a wedged runtime.
  """
  @spec stop(Keyword.t()) :: :ok
  def stop(opts) do
    server = server(opts)
    reason = Keyword.get(opts, :reason, :normal)
    timeout = Keyword.get(opts, :timeout, @default_stop_timeout)

    GenServer.stop(server, reason, timeout)
  catch
    :exit, exit_reason ->
      # Only two reasons mean "escalate": the runtime did not shut down in time,
      # or it was already gone. The previous `catch :exit, _reason` also
      # swallowed a `terminate/2` that raised and any abnormal stop reason, then
      # returned `:ok` — so a crashing `terminate/2` was invisible. That is the
      # same swallow `dead_runtime_exit?/1` was introduced to avoid for `eval/2`;
      # the two paths now classify consistently.
      if stop_escalation_reason?(exit_reason) do
        # A brutal kill is enough. The worker's OS thread is reclaimed by
        # `Runtime`'s `Resource::down` callback, which fires on owner death
        # whatever the owner was executing — including parked inside
        # `eval_blocking`, where `Drop` alone never runs because the NIF frame
        # still holds a reference. Before that callback existed, this branch
        # killed the process and leaked the thread: three `blocking: true`
        # runaways left 3.00 cores burning after `stop/1` returned `:ok`.
        case GenServer.whereis(server(opts)) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _ -> :ok
        end

        :ok
      else
        :erlang.raise(:exit, exit_reason, __STACKTRACE__)
      end
  end

  # `GenServer.stop/3` wraps the reason as `{reason, {GenServer, :stop, args}}`.
  defp stop_escalation_reason?({reason, {GenServer, :stop, _args}}),
    do: stop_escalation_reason?(reason)

  defp stop_escalation_reason?(:timeout), do: true
  defp stop_escalation_reason?(reason), do: dead_runtime_exit?(reason)

  @doc """
  Same as `kill/1`, but it assumes that there is a process with the name
  `Tyrex` (the default if you don't provide a name to `start_link/1`).
  """
  @spec kill() :: :ok
  def kill do
    kill([])
  end

  @doc """
  Interrupt whatever the runtime is executing and shut it down, immediately.

  Unlike `stop/1` this works on a runtime wedged inside a guest that never
  yields — `while (true) {}` cannot be stopped cooperatively, only terminated —
  and it does not wait for a graceful shutdown first. Any in-flight `eval`
  callers receive `{:error, %Tyrex.Error{name: :dead_runtime_error}}`.

  Termination is one-way: the runtime is dead afterwards and must be replaced.

  ## Options

    * `:name` - The name of the Tyrex process. The default is `Tyrex`.
      Can't be provided if `:pid` is provided.
    * `:pid` - The pid of the Tyrex process. Can't be provided if `:name` is
      provided.
    * `:timeout` - How long to wait for the process to actually be gone.
      Defaults to `5_000`. An untrappable exit does not need a deadline, so
      reaching it would mean something is very wrong.
  """
  @spec kill(Keyword.t()) :: :ok
  def kill(opts) do
    # An untrappable exit, NOT a `GenServer.call`.
    #
    # This used to be `GenServer.call(server, :kill)`, which needed the very
    # message loop a wedged runtime cannot reach — so on the one case the
    # docstring above promises, it did nothing, waited out its 5s timeout, and
    # `catch :exit, _ -> :ok` reported that no-op as success. Measured against a
    # `blocking: true` runaway: `kill/1` returned `:ok` after 5002ms with the
    # runtime still alive, while `stop/1` on the identical wedge killed it.
    #
    # `Process.exit(pid, :kill)` cannot be trapped or deferred, and the worker's
    # OS thread is reclaimed by `Runtime`'s `Resource::down` callback, which
    # fires on owner death whatever the owner was executing. Before that
    # callback existed this route killed the process but leaked the thread.
    case GenServer.whereis(server(opts)) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          Keyword.get(opts, :timeout, @default_stop_timeout) ->
            Process.demonitor(ref, [:flush])
            :ok
        end

      # Already gone, or an unregistered name. Nothing to kill.
      _ ->
        :ok
    end
  end

  @doc """
  Start a Tyrex process linked to the current process.

  ## Options

    * `:name` - The name of the process. The default is `Tyrex`.

  See `start/1` for more options.

  ## Examples

      iex> Tyrex.start_link(name: MyApp.Tyrex, permissions: :none)
      iex> Tyrex.eval("1 + 2", name: MyApp.Tyrex)
      {:ok, 3}
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      validate_opts!(Keyword.take(opts, @runtime_opts)),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Same as `eval/2`, but it assumes that there is a process with the name
  `Tyrex` (the default if you don't provide a name to `start_link/1`).

  ## Examples

      iex> Tyrex.eval("1 + 2")
      {:ok, 3}
  """
  @spec eval(binary()) :: {:ok, term()} | {:error, Error.t()}
  def eval(code) do
    eval(code, name: __MODULE__)
  end

  @doc """
  Run the given JavaScript code and return the result. If a promise is returned,
  it will be awaited.

  ## Options

    * `:blocking` - Indicates whether the NIF call should block until the
      JavaScript execution finishes or not. Blocking is more performant, but it
      cannot be combined with the `:apply` bridge — the GenServer would be
      parked in the NIF while the bridge needs that same GenServer to service
      the call, which deadlocks. The default is `false`.
    * `:name` - The name of the Tyrex process. The default is `Tyrex`.
      Can't be provided if `:pid` is provided.
    * `:pid` - The pid of the Tyrex process. Can't be provided if `:name` is
      provided.
    * `:timeout` - Wall-clock deadline in milliseconds for the JavaScript to
      finish. Defaults to `5_000`. On expiry the V8 isolate is terminated and
      `{:error, %Tyrex.Error{name: :timeout}}` is returned; the runtime is dead
      afterwards.

  `:timeout` rejects two different ways, deliberately, and the difference is
  whether the value is *malformed* or merely *unsupported*:

    * **Malformed raises.** Anything that is not a positive integer within the
      BEAM's timer range raises `ArgumentError` in the calling process. That is
      a bug in the caller, in the same class as a bad `:max_heap_mb`, and it
      raises rather than returning a tuple so it cannot be pattern-matched past
      and ignored. It also keeps the failure with the caller: `timeout: -1` used
      to reach the server and raise inside `Process.send_after/3`, killing the
      runtime.
    * **`:infinity` returns an error tuple.** `{:error, %Tyrex.Error{name:
      :unsupported_option}}`, on both the default and the `blocking: true` path.
      It is a well-formed value that tyrex refuses on policy, not a mistake in
      the shape of the argument, and the blocking path already answered this way
      before v0.4.0 — so the tuple is the compatible answer. An unbounded
      deadline arms no timer, so a runaway guest burns a per-runtime OS thread at
      100% for the life of the VM — invisible to BEAM scheduler-utilization
      monitoring because it is not a dirty scheduler — and through
      `Tyrex.Pool.eval/3` it permanently consumes a pool slot. Before v0.4.0
      `:timeout` was only a `GenServer.call/3` timeout, which had that effect by
      default: the caller gave up and the JavaScript kept running.

  Evaluating against a runtime that has already terminated — the window every
  deadline, heap trip and `kill/1` opens — returns
  `{:error, %Tyrex.Error{name: :dead_runtime_error}}` rather than exiting, so
  the `@spec` holds. Every other exit reason still propagates: a `:timeout`
  exit from `GenServer.call/3` itself means the server-side deadline lost its
  race, which is a bug and must not be swallowed.

  ## Examples

      iex> Tyrex.eval("1 + 2")
      {:ok, 3}

      iex> Tyrex.eval("1 + 2", blocking: true)
      {:ok, 3}

      iex> {:ok, pid} = Tyrex.start(permissions: :none)
      iex> Tyrex.eval("1 + 2", pid: pid)
      {:ok, 3}
  """
  @spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Error.t()}
  def eval(code, opts) do
    case validate_timeout!(Keyword.get(opts, :timeout, @default_eval_timeout)) do
      :infinity ->
        {:error, unsupported_option(:without_deadline)}

      timeout ->
        GenServer.call(server(opts), {:eval, code, opts}, call_timeout(timeout))
    end
  catch
    :exit, reason ->
      if dead_runtime_exit?(reason) do
        {:error,
         %Error{
           name: :dead_runtime_error,
           message:
             "the runtime was already gone when this call was made, or died " <>
               "before it could reply"
         }}
      else
        :erlang.raise(:exit, reason, __STACKTRACE__)
      end
  end

  @doc """
  Same as `eval/1`, but raises `Tyrex.Error` if the result isn't successful.

  Use this when you'd rather treat runtime errors as exceptions than handle
  them in a `case` block. See `Tyrex.Error` for the possible `:name` values.
  """
  @spec eval!(binary()) :: term() | no_return()
  def eval!(code) do
    case eval(code) do
      {:ok, result} -> result
      {:error, %Error{} = e} -> raise e
    end
  end

  @doc """
  Same as `eval/2`, but raises `Tyrex.Error` if the result isn't successful.

  Use this when you'd rather treat runtime errors as exceptions than handle
  them in a `case` block. See `Tyrex.Error` for the possible `:name` values.
  """
  @spec eval!(binary(), Keyword.t()) :: term() | no_return()
  def eval!(code, opts) do
    case eval(code, opts) do
      {:ok, result} -> result
      {:error, %Error{} = e} -> raise e
    end
  end

  @impl GenServer
  def init(opts) do
    pid = self()
    startup_timeout = Keyword.fetch!(opts, :startup_timeout)
    allowlist = Keyword.fetch!(opts, :apply_allowlist)

    task =
      Task.async(fn ->
        :ok =
          Native.start_runtime(
            pid,
            Keyword.fetch!(opts, :main_module_path),
            Keyword.fetch!(opts, :permissions_json),
            allowlist != nil,
            Keyword.fetch!(opts, :max_heap_mb)
          )

        receive do
          {:ok, reference} ->
            {:ok, reference}

          error ->
            error
        after
          startup_timeout ->
            {:error, :nif_startup_timeout}
        end
      end)

    # Give the Task an extra second to return after its inner timeout fires —
    # otherwise `Task.await` would race the inner `after` clause.
    case Task.await(task, startup_timeout + 1_000) do
      {:ok, reference} ->
        {:ok, %Runtime{reference: reference, apply_allowlist: allowlist}}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call({:eval, code, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, @default_eval_timeout)

    cond do
      # First, so it guards both paths for anyone calling this GenServer
      # directly. `eval/2` refuses `:infinity` at the API boundary, which is
      # where a caller sees the message.
      timeout == :infinity ->
        {:reply, {:error, unsupported_option(:without_deadline)}, state}

      not Keyword.get(opts, :blocking, false) ->
        :ok = Native.eval(from, state.reference, code)
        {:noreply, arm_deadline(state, from, timeout)}

      state.apply_allowlist != nil ->
        {:reply, {:error, unsupported_option(:blocking_with_apply)}, state}

      true ->
        blocking_eval(code, timeout, state)
    end
  end

  # An allowlisted MFA runs INLINE here, on the runtime's own message loop, so
  # while it runs this GenServer cannot process its own `{:deadline, from}`
  # message. A slow bridge call therefore suspends the eval deadline rather than
  # racing it: measured with an allowlisted function sleeping 6000ms, a caller
  # with `timeout: 500` exited `{:timeout, {GenServer, :call, ...}}` at ~1504ms
  # with the runtime still alive, and the runtime was terminated only when the
  # MFA returned. A pool slot is held throughout.
  #
  # This is deliberate and is not being moved. Authorization lives in the
  # GenServer precisely so it is outside the isolate's blast radius; running the
  # MFA on a task would move execution away from the process holding that
  # decision, and would let one guest fan out unbounded concurrent Elixir work.
  # The honest boundary is therefore documented rather than papered over: bridge
  # time is not covered by the eval deadline. Keep allowlisted functions fast,
  # and do slow work by handing it to your own supervised process.
  #
  # `blocking: true` is refused with the bridge enabled for the inverse of this
  # reason — that direction deadlocks outright rather than merely delaying.
  @impl GenServer
  def handle_info({:apply, application_id, module, function_name, args}, state) do
    result = authorize_and_apply(state.apply_allowlist, module, function_name, args)

    case Native.apply_reply(state.reference, application_id, result) do
      {:ok, _} ->
        {:noreply, state}

      # The worker is gone, so the JS promise this reply was destined for can
      # never settle. Matching only `{:ok, {}}` here used to raise a MatchError
      # and take the GenServer down with an unhelpful reason.
      {:error, %Error{}} ->
        {:stop, {:shutdown, :dead_runtime_error}, fail_inflight(state, :dead_runtime_error)}
    end
  end

  @impl GenServer
  def handle_info({:eval_reply, from, result}, state) do
    case Map.pop(state.inflight, from, :absent) do
      {:absent, _inflight} ->
        # The deadline already fired and replied for this caller.
        {:noreply, state}

      {timer, inflight} ->
        cancel_timer(timer)
        state = %{state | inflight: inflight}
        GenServer.reply(from, decode_promise_rejection(result))

        case result do
          {:error, %Error{name: name}} when name in [:dead_runtime_error, :heap_limit_error] ->
            {:stop, {:shutdown, name}, fail_inflight(state, name)}

          _ ->
            {:noreply, state}
        end
    end
  end

  @impl GenServer
  def handle_info({:deadline, from}, state) do
    case Map.pop(state.inflight, from, :absent) do
      {:absent, _inflight} ->
        {:noreply, state}

      {_timer, inflight} ->
        # The worker thread is inside `execute_script` and cannot read a
        # channel message, so this has to reach into the isolate from outside.
        :ok = Native.terminate_runtime(state.reference)

        GenServer.reply(
          from,
          {:error,
           %Error{
             name: :timeout,
             message: "evaluation exceeded its deadline; the runtime was terminated"
           }}
        )

        state = %{state | inflight: inflight}
        {:stop, {:shutdown, :timeout}, fail_inflight(state, :dead_runtime_error)}
    end
  end

  # The worker thread unwound. Its `catch_unwind` still ran the slab cleanup, but
  # this GenServer is left holding a resource with nothing behind it: without
  # this clause `Process.alive?/1` reports true, a `Tyrex.Pool` keeps dispatching
  # to it, and every call answers `:dead_runtime_error` forever. Stop so the
  # supervisor replaces it, and drain anyone already waiting.
  @impl GenServer
  def handle_info({:worker_panicked, reason}, state) do
    Logger.error("Tyrex worker thread panicked, terminating the runtime: #{inspect(reason)}")
    {:stop, {:shutdown, :dead_runtime_error}, fail_inflight(state, :dead_runtime_error)}
  end

  # A runtime must not die because something unexpected landed in its mailbox.
  # Without this clause any stray message — a late `Task` reply from `init/1`
  # whose `Task.await` had already timed out, a `:DOWN` from a monitor set by
  # calling code, anything a future deno extension sends — raises
  # `FunctionClauseError` and takes a working runtime down. Logged rather than
  # silently dropped, because an unexpected message here is a real signal.
  @impl GenServer
  def handle_info(message, state) do
    Logger.warning("Tyrex runtime received an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # `{:stop, ...}` from a handler runs terminate/2, so this one call also
    # covers `blocking_eval/3`'s three stop returns and a plain `Tyrex.stop/1` —
    # both of which used to leave pending non-blocking callers to exit instead
    # of receiving the `dead_runtime_error` that `kill/1` documents for exactly
    # this situation. Handlers that already drain leave `inflight: %{}`, so no
    # caller is replied to twice.
    state = fail_inflight(state, :dead_runtime_error)

    # Terminate rather than merely signalling a stop. A guest that never yields
    # will never read a cooperative stop message, and its per-runtime OS thread
    # would then spin at 100% for the life of the VM — uncapped, and invisible
    # to BEAM scheduler-utilization monitoring because it is not a dirty
    # scheduler. `terminate_runtime/1` unwinds the guest and stops the worker.
    _ = Native.terminate_runtime(state.reference)
    :ok
  end

  defp blocking_eval(code, timeout, state) do
    case Native.eval_blocking(state.reference, code, timeout) do
      {:ok, json} ->
        {:reply, {:ok, Jason.decode!(json)}, state}

      {:error, %Error{name: name}} = error
      when name in [:dead_runtime_error, :timeout, :heap_limit_error] ->
        # Reply before stopping. Stopping without a reply left the caller
        # blocked until its own call timeout, then exiting.
        {:stop, {:shutdown, name}, error, state}

      error ->
        {:reply, decode_promise_rejection(error), state}
    end
  end

  defp server(opts) do
    Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__)
  end

  defp call_timeout(timeout), do: timeout + @deadline_grace_ms

  # `:timeout` ends up in `Process.send_after/3` on the server, where a value
  # outside the BEAM's timer range raises *inside the GenServer* and kills the
  # runtime — and under `Tyrex.Pool`'s supervision, potentially its siblings.
  # Nothing upstream caught that, because `call_timeout(-1)` is itself a legal
  # `GenServer.call` timeout. Validating here keeps a caller's bad argument with
  # the caller.
  #
  # The upper bound is as load-bearing as the lower one, and was missed on the
  # first pass. Two bands escaped a sign-only check:
  #
  #   * above `4_294_967_295 - @deadline_grace_ms`, `call_timeout/1` overflows
  #     `GenServer.call`'s own `receive after` ceiling, so the caller raises
  #     `:timeout_value` *after* the eval was already dispatched — leaving a
  #     runaway guest with an effectively unbounded deadline, which is precisely
  #     what refusing `:infinity` exists to prevent;
  #   * above `9_223_372_034_790`, `Process.send_after/3` raises `:badarg` and
  #     takes the runtime down. Reproduced: `timeout: 10_000_000_000_000` left
  #     `Process.alive?/1` false.
  #
  # One bound covers both, since the tighter of the two is the call ceiling.
  @max_timeout 4_294_967_295 - @deadline_grace_ms

  # `:infinity` is well-formed and so does not raise: `eval/2` refuses it with
  # `:unsupported_option`, which is what the blocking path already did.
  defp validate_timeout!(:infinity), do: :infinity

  defp validate_timeout!(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout,
       do: timeout

  defp validate_timeout!(other) do
    raise ArgumentError,
          ":timeout must be a positive integer number of milliseconds between 1 and " <>
            "#{@max_timeout} (or :infinity, which is refused), got: #{inspect(other)}"
  end

  # `GenServer.call/3` wraps the server's exit reason as
  # `{reason, {GenServer, :call, args}}`. Only reasons that mean "the runtime was
  # already gone" become an error tuple, honouring `eval/2`'s `@spec` across the
  # window every deadline, heap trip and `kill/1` opens. Everything else — most
  # importantly a `:timeout` from the call itself, which means the server-side
  # deadline lost its race — keeps propagating.
  #
  # The bare `:shutdown` atom and `:killed` matter as much as the 2-tuple and
  # were missed on the first pass: bare `:shutdown` is what a *supervisor* sends
  # a child, which is the dominant window under `Tyrex.Pool`, and `:killed` is
  # both `:brutal_kill` and `stop/1`'s own escalation branch. `terminate/2` does
  # not run on either, so `fail_inflight/2` cannot cover them.
  defp dead_runtime_exit?({reason, {GenServer, :call, _args}}), do: dead_runtime_exit?(reason)
  defp dead_runtime_exit?(:noproc), do: true
  defp dead_runtime_exit?(:normal), do: true
  defp dead_runtime_exit?(:shutdown), do: true
  defp dead_runtime_exit?(:killed), do: true
  defp dead_runtime_exit?({:shutdown, _reason}), do: true
  defp dead_runtime_exit?(_reason), do: false

  defp arm_deadline(state, from, timeout) do
    timer = Process.send_after(self(), {:deadline, from}, timeout)
    %{state | inflight: Map.put(state.inflight, from, timer)}
  end

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp fail_inflight(state, name) do
    error = %Error{
      name: name,
      message: "the runtime was terminated while this call was in flight"
    }

    Enum.each(state.inflight, fn {from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, error})
    end)

    %{state | inflight: %{}}
  end

  defp unsupported_option(:blocking_with_apply) do
    %Error{
      name: :unsupported_option,
      message:
        "`blocking: true` cannot be combined with the :apply bridge — the GenServer " <>
          "would park inside the NIF while the bridge needs that same GenServer to " <>
          "service the call, which deadlocks the runtime permanently"
    }
  end

  defp unsupported_option(:without_deadline) do
    %Error{
      name: :unsupported_option,
      message:
        "an eval requires a finite :timeout — with `timeout: :infinity` no deadline " <>
          "is armed, so a runaway guest burns a per-runtime OS thread at 100% for the " <>
          "life of the VM, invisible to BEAM scheduler-utilization monitoring because " <>
          "it is not a dirty scheduler; with `blocking: true` it also parks a dirty-IO " <>
          "scheduler thread permanently"
    }
  end

  defp decode_promise_rejection(error) do
    case error do
      {:error, %Error{name: :promise_rejection} = e} ->
        {:error, %{e | value: Jason.decode!(e.value)}}

      {:ok, json} when is_binary(json) ->
        {:ok, Jason.decode!(json)}

      _ ->
        error
    end
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, _} = result ->
        result

      {:error, error} ->
        {:error, "Could not convert to JSON: #{inspect(error.value)}"}
    end
  end

  # The bridge was never installed, so this can only be reached by a runtime
  # whose global survived — belt and braces rather than a reachable path.
  defp authorize_and_apply(nil, module, function_name, _args) do
    reject(
      "permission_denied: the Tyrex.apply bridge is disabled on this runtime " <>
        "(#{module}.#{function_name} was requested); start it with " <>
        "`apply: [{Module, :function, arity}]` to enable specific functions"
    )
  end

  defp authorize_and_apply(allowlist, module, function_name, args) do
    with {:ok, decoded_args} <- decode_args(args),
         arity = length(decoded_args),
         {:ok, {mod, fun}} <- authorize(allowlist, module, function_name, arity) do
      invoke(mod, fun, decoded_args)
    end
  end

  defp decode_args(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      {:ok, other} -> reject("Tyrex.apply arguments must be a list, got: #{inspect(other)}")
      {:error, _} -> reject("Tyrex.apply arguments were not valid JSON")
    end
  end

  # Authorization happens before any atom conversion, and the module and
  # function are taken from the allowlist rather than from the guest's strings.
  # Guest input is therefore only ever used as a map key: it cannot mint atoms,
  # and it cannot probe which modules exist. Arity matching alone was never
  # authorization.
  defp authorize(allowlist, module, function_name, arity) do
    case Map.fetch(allowlist, {module, function_name, arity}) do
      {:ok, {mod, fun}} ->
        if function_exported?(mod, fun, arity) do
          {:ok, {mod, fun}}
        else
          reject("No such function: #{module}.#{function_name}/#{arity}")
        end

      :error ->
        reject(
          "permission_denied: #{module}.#{function_name}/#{arity} is not in the :apply allowlist"
        )
    end
  end

  defp invoke(mod, fun, args) do
    case encode_json(apply(mod, fun, args)) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, message} -> reject(message)
    end
  rescue
    exception ->
      # An allowlisted function raising is the guest's problem, not grounds to
      # destroy the runtime. Reject the JS promise and keep serving; the
      # exception type is preserved in the message so nothing is hidden.
      reject("#{inspect(exception.__struct__)}: #{Exception.message(exception)}")
  catch
    kind, reason ->
      reject("#{kind}: #{inspect(reason)}")
  end

  defp reject(message), do: {:error, Jason.encode!(message)}

  defp validate_opts!(opts) do
    [
      main_module_path:
        Keyword.get(opts, :main_module_path, "#{Application.app_dir(:tyrex)}/priv/main.js"),
      permissions_json: encode_permissions(resolve_permissions(opts)),
      apply_allowlist: build_apply_allowlist(Keyword.get(opts, :apply, false)),
      max_heap_mb: validate_max_heap_mb!(Keyword.get(opts, :max_heap_mb)),
      startup_timeout: Keyword.get(opts, :startup_timeout, @default_startup_timeout)
    ]
  end

  defp resolve_permissions(opts) do
    case Keyword.fetch(opts, :permissions) do
      {:ok, permissions} ->
        permissions

      :error ->
        warn_missing_permissions()
        :none
    end
  end

  defp warn_missing_permissions do
    if :persistent_term.get({__MODULE__, :permissions_warned}, false) do
      :ok
    else
      :persistent_term.put({__MODULE__, :permissions_warned}, true)

      Logger.warning("""
      Tyrex was started without an explicit :permissions option.

      As of v0.4.0 the default is :none (no Deno I/O). Before v0.4.0 it was
      :allow_all. Pass `permissions: :allow_all` to restore the previous
      behaviour, or pass `permissions: :none` explicitly to silence this
      warning. This warning is emitted once per VM.
      """)
    end
  end

  defp validate_max_heap_mb!(nil), do: nil

  defp validate_max_heap_mb!(mb) when is_integer(mb) and mb >= @min_heap_mb, do: mb

  defp validate_max_heap_mb!(other) do
    raise ArgumentError, """
    :max_heap_mb must be a positive integer of at least #{@min_heap_mb} megabytes, \
    got: #{inspect(other)}

    V8 honours the cap from isolate creation, but the near-heap-limit callback
    that converts an exhausted heap into a terminated guest cannot be installed
    until the isolate exists. Deno's bootstrap and snapshot deserialization —
    the heaviest allocation phase in a runtime's life — therefore always run
    under V8's default `abort()`, which takes down the whole BEAM rather than
    the guest. #{@measured_min_heap_mb} MB was the smallest cap that booted
    reliably on the reference machine (arm64 macOS, V8 146.4.0); the enforced
    floor is #{@min_heap_mb}, because the failure mode is loss of the entire VM
    rather than a failed `start/1`.
    """
  end

  defp build_apply_allowlist(false), do: nil
  defp build_apply_allowlist(nil), do: nil

  # An empty allowlist grants nothing, so installing the bridge would only
  # enlarge the reachable surface for no benefit.
  defp build_apply_allowlist([]), do: nil

  defp build_apply_allowlist(mfas) when is_list(mfas) do
    Map.new(mfas, &allowlist_entry!/1)
  end

  defp build_apply_allowlist(other) do
    raise ArgumentError, """
    invalid :apply option: #{inspect(other)}

    Expected `false` (the default) or a list of `{Module, :function, arity}`
    tuples, e.g. `apply: [{Enum, :sum, 1}]`. There is deliberately no
    `apply: true` — an unrestricted bridge is the hole this option closes.
    """
  end

  defp allowlist_entry!({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    if not Code.ensure_loaded?(module) do
      raise ArgumentError, "invalid :apply entry: module #{inspect(module)} could not be loaded"
    end

    if not function_exported?(module, function, arity) do
      raise ArgumentError,
            "invalid :apply entry: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    {{js_module_name(module), Atom.to_string(function), arity}, {module, function}}
  end

  defp allowlist_entry!(other) do
    raise ArgumentError,
          "invalid :apply entry: #{inspect(other)}, expected `{Module, :function, arity}`"
  end

  # The key is the exact string guest JavaScript passes as the module name:
  # "Enum" for Elixir modules, ":os" for Erlang ones.
  defp js_module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      erlang -> ":" <> erlang
    end
  end

  defp encode_permissions(:allow_all), do: ~s("allow_all")

  defp encode_permissions(:none), do: "{}"

  defp encode_permissions(opts) when is_map(opts) do
    encode_permissions(Map.to_list(opts))
  end

  defp encode_permissions(opts) when is_list(opts) do
    opts
    |> Map.new(fn
      {key, value} -> {validate_permission_key!(key), validate_permission_value!(key, value)}
      other -> raise ArgumentError, "invalid :permissions entry: #{inspect(other)}"
    end)
    |> Jason.encode!()
  end

  defp encode_permissions(other) do
    raise ArgumentError, """
    invalid :permissions option: #{inspect(other)}

    Expected `:none`, `:allow_all`, or a keyword list of permission keys.
    """
  end

  defp validate_permission_key!(key) when is_atom(key) do
    if key in @permission_keys do
      key
    else
      raise ArgumentError, """
      unknown permission key: #{inspect(key)}

      A typo in a permission key is silently permissive, so it is rejected
      rather than dropped. Known keys:

      #{@permission_keys |> Enum.map(&inspect/1) |> Enum.join(", ")}
      """
    end
  end

  defp validate_permission_key!(key) do
    raise ArgumentError, "permission keys must be atoms, got: #{inspect(key)}"
  end

  defp validate_permission_value!(_key, value) when is_boolean(value), do: value

  defp validate_permission_value!(key, values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) ->
        value

      value when is_atom(value) ->
        Atom.to_string(value)

      value ->
        raise ArgumentError,
              "entries of permission #{inspect(key)} must be strings, got: #{inspect(value)}"
    end)
  end

  defp validate_permission_value!(key, value) do
    raise ArgumentError,
          "permission #{inspect(key)} must be true, false, or a list of strings, " <>
            "got: #{inspect(value)}"
  end
end
