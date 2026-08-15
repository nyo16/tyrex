defmodule Tyrex.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    base_url: "https://github.com/nyo16/tyrex/releases/download/v#{version}",
    crate: "tyrex",
    force_build: System.get_env("TYREX_BUILD") == "true",
    nif_versions: ["2.16"],
    otp_app: :tyrex,
    targets: [
      "aarch64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-apple-darwin",
      "x86_64-unknown-linux-gnu"
    ],
    version: version

  @doc """
  Spawn a Deno worker thread for the given Elixir pid and report success or
  failure back to that pid as `{:ok, reference}` or `{:error, error}`.

  `apply_enabled` decides whether the `Tyrex.apply` JS bridge is installed at
  all; when `false`, `globalThis.Tyrex` is deleted after bootstrap so guest code
  holds no reference to it. `max_heap_mb` caps the V8 heap; `nil` leaves it
  uncapped, in which case a guest OOM aborts the whole VM.

  Returns `:ok` once the spawn request is enqueued. The runtime resource is
  delivered asynchronously via the message above.
  """
  @spec start_runtime(pid(), binary(), binary(), boolean(), non_neg_integer() | nil) :: :ok
  def start_runtime(_pid, _main_module_path, _permissions_json, _apply_enabled, _max_heap_mb),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Interrupt the JavaScript currently executing on `reference` and shut the
  runtime down.

  This works even on a guest that never yields, because it acts on the V8
  isolate from outside rather than queueing a message the worker thread will
  never read. Pending in-flight promises receive a `:dead_runtime_error`
  response, then the worker exits its event loop and its OS thread.

  Termination is uncatchable and one-way: the runtime is dead afterwards.
  """
  @spec terminate_runtime(reference()) :: :ok
  def terminate_runtime(_reference), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Enqueue a JavaScript evaluation on the worker. The reply is sent
  asynchronously to the calling GenServer as
  `{:eval_reply, from, result}`. Returns `:ok` once enqueued.
  """
  @spec eval(GenServer.from(), reference(), binary()) :: :ok
  def eval(_from, _reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Run JavaScript synchronously, parking the calling dirty-IO scheduler thread
  until the worker replies or `timeout_ms` elapses. Faster for sub-millisecond
  code. On expiry the guest is terminated and `{:error, %Tyrex.Error{name:
  :timeout}}` is returned; the runtime is dead at that point.
  """
  @spec eval_blocking(reference(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, Tyrex.Error.t()}
  def eval_blocking(_reference, _code, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deliver the result of an Elixir-side `Tyrex.apply` callback back to the
  worker so the JS-side promise can be resolved or rejected. Returns
  `{:ok, {}}` on success, or `{:error, %Tyrex.Error{}}` if the worker is gone.
  """
  @spec apply_reply(reference(), binary(), {:ok, binary()} | {:error, binary()}) ::
          {:ok, {}} | {:error, Tyrex.Error.t()}
  def apply_reply(_reference, _application_id, _result), do: :erlang.nif_error(:nif_not_loaded)
end
