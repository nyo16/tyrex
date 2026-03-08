defmodule Tyrex.Runtime do
  @enforce_keys [
    :reference
  ]

  @type t :: %__MODULE__{}

  defstruct [:reference]
end
