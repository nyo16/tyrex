defmodule Tyrex.Pool.Strategy.RoundRobin do
  @moduledoc """
  Round-robin dispatch strategy (default).

  Uses an ETS atomic counter for lock-free, sequential cycling through runtimes.
  """

  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(pool_name, size) do
    table = :ets.new(:"#{pool_name}.RoundRobin", [:public, :set])
    # Seed at `size - 1` so the first `update_counter/3` increments to `size`,
    # which wraps via the threshold/setvalue tuple to `0` — making the first
    # selected index 0 rather than 1.
    :ets.insert(table, {:counter, size - 1})
    {table, size}
  end

  @doc """
  Selects the next runtime index in 0..size-1 using a lock-free ETS
  `update_counter` with a wrap-around threshold. Safe to call concurrently
  from any number of processes.
  """
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
