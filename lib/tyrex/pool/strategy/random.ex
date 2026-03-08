defmodule Tyrex.Pool.Strategy.Random do
  @moduledoc """
  Random dispatch strategy.

  Selects a random runtime for each request. Good for bursty workloads
  where even distribution isn't critical.
  """

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
