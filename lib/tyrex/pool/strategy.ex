defmodule Tyrex.Pool.Strategy do
  @moduledoc """
  Behaviour for pool dispatch strategies.

  Implement this behaviour to create custom routing logic for `Tyrex.Pool`.

  ## Example

      defmodule MyApp.LeastLoaded do
        @behaviour Tyrex.Pool.Strategy

        def init(pool_name, size), do: {pool_name, size}

        def select({pool_name, size}, _opts) do
          0..(size - 1)
          |> Enum.min_by(fn i ->
            :\"\#{pool_name}.Runtime.\#{i}\"
            |> Process.whereis()
            |> Process.info(:message_queue_len)
            |> elem(1)
          end)
        end
      end
  """

  @doc "Initialize strategy state. Called once at pool startup. Returns opaque state."
  @callback init(pool_name :: atom(), size :: pos_integer()) :: state :: term()

  @doc "Select a runtime index (0..size-1). Receives state and optional dispatch key."
  @callback select(state :: term(), opts :: keyword()) :: non_neg_integer()

  @doc "Clean up strategy state on pool shutdown."
  @callback terminate(state :: term()) :: :ok

  @optional_callbacks [terminate: 1]
end
