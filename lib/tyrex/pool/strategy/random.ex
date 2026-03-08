defmodule Tyrex.Pool.Strategy.Random do
  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(_pool_name, size) do
    size
  end

  @impl true
  def select(size, _opts) do
    :rand.uniform(size) - 1
  end
end
