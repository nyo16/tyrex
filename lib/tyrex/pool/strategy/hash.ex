defmodule Tyrex.Pool.Strategy.Hash do
  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(_pool_name, size) do
    size
  end

  @impl true
  def select(size, opts) do
    case Keyword.fetch(opts, :key) do
      {:ok, key} ->
        :erlang.phash2(key, size)

      :error ->
        :rand.uniform(size) - 1
    end
  end
end
