defmodule Tyrex.Pool.Strategy.RoundRobin do
  @moduledoc """
  Round-robin dispatch strategy (default).

  Uses an ETS atomic counter for lock-free, sequential cycling through runtimes.
  """

  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(pool_name, size) do
    table = :ets.new(:"#{pool_name}.RoundRobin", [:public, :set])
    :ets.insert(table, {:counter, 0})
    {table, size}
  end

  @impl true
  def select({table, size}, _opts) do
    :ets.update_counter(table, :counter, {2, 1, size - 1, 0})
  end

  @impl true
  def terminate({table, _size}) do
    :ets.delete(table)
    :ok
  end
end
