defmodule Tyrex.Pool.Strategy do
  @doc "Initialize strategy state. Called once at pool startup. Returns opaque state."
  @callback init(pool_name :: atom(), size :: pos_integer()) :: state :: term()

  @doc "Select a runtime index (0..size-1). Receives state and optional dispatch key."
  @callback select(state :: term(), opts :: keyword()) :: non_neg_integer()

  @doc "Clean up strategy state on pool shutdown."
  @callback terminate(state :: term()) :: :ok

  @optional_callbacks [terminate: 1]
end
