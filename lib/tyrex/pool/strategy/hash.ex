defmodule Tyrex.Pool.Strategy.Hash do
  @moduledoc """
  Hash-based dispatch strategy for sticky sessions.

  Routes requests by a `:key` option — the same key always hits the same runtime.
  Useful for stateful JavaScript sessions (e.g., per-user state).

      Tyrex.Pool.eval(:pool, "getCart()", key: user_id)

  If no `:key` is provided, falls back to random selection.
  """

  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(_pool_name, size) do
    size
  end

  @doc """
  Selects a runtime index in 0..size-1 deterministically from `opts[:key]`
  using `:erlang.phash2/2`. Falls back to a random index when no `:key` is
  provided.
  """
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
