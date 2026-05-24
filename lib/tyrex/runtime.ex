defmodule Tyrex.Runtime do
  @moduledoc """
  Struct holding a reference to a Deno runtime NIF resource.

  This is an opaque value managed internally by `Tyrex` — you should not
  create or modify it directly.

  The `:reference` field is the opaque NIF resource handle (a Rustler
  `ResourceArc`) that keeps the underlying Deno worker alive for as long as
  this struct is reachable. Dropping the struct without a matching
  `Tyrex.stop/1` lets the resource be garbage-collected, which best-effort
  signals the worker to shut down.
  """

  @enforce_keys [
    :reference
  ]

  @typedoc """
  Tyrex runtime handle wrapping the opaque NIF resource reference.
  """
  @type t :: %__MODULE__{reference: reference()}

  defstruct [:reference]
end
