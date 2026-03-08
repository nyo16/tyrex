defmodule Tyrex.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    base_url: "https://github.com/nyo16/tyrex/releases/download/v#{version}",
    crate: "tyrex",
    force_build: System.get_env("TYREX_BUILD") == "true",
    nif_versions: ["2.15"],
    otp_app: :tyrex,
    targets: [
      "aarch64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-apple-darwin",
      "x86_64-pc-windows-msvc",
      "x86_64-unknown-linux-gnu"
    ],
    version: version

  def start_runtime(_pid, _main_module_path), do: :erlang.nif_error(:nif_not_loaded)

  def stop_runtime(_reference), do: :erlang.nif_error(:nif_not_loaded)

  def eval(_from, _reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  def eval_blocking(_reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  def apply_reply(_reference, _application_id, _result), do: :erlang.nif_error(:nif_not_loaded)
end
