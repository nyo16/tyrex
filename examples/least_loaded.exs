# Least-loaded dispatch strategy
# Run: TYREX_BUILD=true mix run examples/least_loaded.exs
#
# Demonstrates a custom `Tyrex.Pool.Strategy` that picks the runtime with the
# shortest message queue. This is useful when individual evaluations have wildly
# different costs and you'd rather keep busy workers busy than block on them.

defmodule LeastLoaded do
  @moduledoc """
  Picks the `Tyrex` runtime with the smallest mailbox.

  State shape: `{pool_name :: atom(), size :: pos_integer()}`.
  No ETS, no GenServer — just `Process.info/2` on each runtime per select.
  Fine for small pools; consider caching for larger ones.
  """

  @behaviour Tyrex.Pool.Strategy

  @impl true
  def init(pool_name, size), do: {pool_name, size}

  @impl true
  def select({pool_name, size}, _opts) do
    Enum.min_by(0..(size - 1), fn i ->
      case Process.whereis(:"#{pool_name}.Runtime.#{i}") do
        nil ->
          # Runtime currently down — pretend it's saturated so we skip it.
          :infinity

        pid ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, len} -> len
            nil -> :infinity
          end
      end
    end)
  end

  @impl true
  def terminate(_state), do: :ok
end

IO.puts("=== Tyrex Least-Loaded Pool Strategy ===\n")

size = 4
{:ok, _} = Tyrex.Pool.start_link(name: :ll_pool, size: size, strategy: LeastLoaded)

# Tag each runtime so we can attribute calls to it after the fact.
# Init via the named runtime (NOT the pool) so every runtime gets initialized —
# the LeastLoaded strategy would route all four init calls to runtime 0 since
# it's always the least-loaded when nothing's queued.
for i <- 0..(size - 1) do
  Tyrex.eval("globalThis.runtimeId = #{i}; globalThis.calls = 0",
    name: :"ll_pool.Runtime.#{i}"
  )
end

# Mixed workload: 1/3 "expensive" (a JS setTimeout), 2/3 cheap math.
workload =
  for i <- 1..40 do
    if rem(i, 3) == 0 do
      {:slow,
       "await new Promise(r => setTimeout(r, 200)); globalThis.calls++; return globalThis.runtimeId;"}
    else
      {:fast, "globalThis.calls++; const _ = #{i} * 2; return globalThis.runtimeId;"}
    end
  end

IO.puts("Dispatching #{length(workload)} mixed jobs (1/3 slow, 2/3 fast)...")

started = System.monotonic_time(:millisecond)

results =
  workload
  |> Task.async_stream(
    fn {kind, code} ->
      {:ok, runtime_id} =
        Tyrex.Pool.eval(:ll_pool, "(async () => { #{code} })()", timeout: 10_000)

      {kind, runtime_id}
    end,
    max_concurrency: size * 2,
    timeout: 15_000
  )
  |> Enum.map(fn {:ok, pair} -> pair end)

elapsed = System.monotonic_time(:millisecond) - started

distribution =
  results
  |> Enum.group_by(fn {_kind, runtime_id} -> runtime_id end)
  |> Enum.map(fn {runtime_id, jobs} ->
    {runtime_id,
     %{
       total: length(jobs),
       slow: Enum.count(jobs, fn {k, _} -> k == :slow end),
       fast: Enum.count(jobs, fn {k, _} -> k == :fast end)
     }}
  end)
  |> Enum.sort_by(fn {runtime_id, _} -> runtime_id end)

IO.puts("\nElapsed: #{elapsed}ms\n")
IO.puts("Per-runtime breakdown:")

for {runtime_id, %{total: total, slow: slow, fast: fast}} <- distribution do
  IO.puts("  runtime #{runtime_id}: total=#{total}  slow=#{slow}  fast=#{fast}")
end

# Cross-check via JS-side counter — should match the totals above.
IO.puts("\nJS-side `globalThis.calls` per runtime:")

for i <- 0..(size - 1) do
  {:ok, calls} = Tyrex.eval("globalThis.calls", name: :"ll_pool.Runtime.#{i}")
  IO.puts("  runtime #{i}: calls=#{calls}")
end

Supervisor.stop(:"ll_pool.Supervisor")

IO.puts("\n=== Done! ===")
