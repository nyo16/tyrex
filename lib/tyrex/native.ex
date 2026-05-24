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

  Returns `:ok` once the spawn request is enqueued. The runtime resource is
  delivered asynchronously via the message above.
  """
  def start_runtime(_pid, _main_module_path, _permissions_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Signal the worker associated with `reference` to shut down. Best-effort:
  pending in-flight promises receive a `:dead_runtime_error` response, then
  the worker exits its event loop.
  """
  def stop_runtime(_reference), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Enqueue a JavaScript evaluation on the worker. The reply is sent
  asynchronously to the calling GenServer as
  `{:eval_reply, from, result}`. Returns `:ok` once enqueued.
  """
  def eval(_from, _reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Run JavaScript synchronously, blocking the calling scheduler until the
  worker replies. Faster for sub-millisecond code; can starve the BEAM
  scheduler for long-running runs. Returns `{:ok, json}` or
  `{:error, %Tyrex.Error{}}`.
  """
  def eval_blocking(_reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deliver the result of an Elixir-side `Tyrex.apply` callback back to the
  worker so the JS-side promise can be resolved or rejected. Returns
  `{:ok, {}}` once the worker accepts the reply.
  """
  def apply_reply(_reference, _application_id, _result), do: :erlang.nif_error(:nif_not_loaded)
end
