defmodule Tyrex.Runtime do
  @moduledoc """
  State of a running `Tyrex` GenServer.

  This is an opaque value managed internally by `Tyrex` — you should not
  create or modify it directly.

  The `:reference` field is the opaque NIF resource handle (a Rustler
  `ResourceArc`) that keeps the underlying Deno worker alive for as long as
  this struct is reachable. Dropping the struct without a matching
  `Tyrex.stop/1` lets the resource be garbage-collected, which terminates the
  isolate and signals the worker to shut down.
  """

  @enforce_keys [
    :reference
  ]

  @typedoc """
  A single entry of the `:apply` allowlist, keyed by the exact strings guest
  JavaScript passes to `Tyrex.apply` and the argument count it supplies.
  """
  @type allowlist :: %{{binary(), binary(), arity()} => {module(), atom()}} | nil

  @typedoc """
  Tyrex runtime state: the opaque NIF resource reference, the resolved
  `Tyrex.apply` allowlist (`nil` when the bridge is disabled), and the map of
  in-flight `eval` callers to their deadline timers.
  """
  @type t :: %__MODULE__{
          reference: reference(),
          apply_allowlist: allowlist(),
          inflight: %{GenServer.from() => reference()}
        }

  defstruct [:reference, apply_allowlist: nil, inflight: %{}]
end
