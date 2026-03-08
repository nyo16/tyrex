defmodule Tyrex.Runtime do
  @moduledoc """
  Struct holding a reference to a Deno runtime NIF resource.

  This is an opaque value managed internally by `Tyrex` — you should not
  create or modify it directly.
  """

  @enforce_keys [
    :reference
  ]

  @type t :: %__MODULE__{}

  defstruct [:reference]
end
