# Run: TYREX_BUILD=true mix run bench/concurrency_bench.exs
#
# Compares throughput of a single runtime vs a pool under concurrent load.

{:ok, single} = Tyrex.start()
{:ok, _} = Tyrex.Pool.start_link(name: :conc_pool, size: System.schedulers_online())

code = "[1,2,3,4,5].reduce((a, b) => a + b, 0)"

Benchee.run(
  %{
    "single runtime (sequential)" => fn ->
      {:ok, _} = Tyrex.eval(code, pid: single)
    end,
    "pool (sequential)" => fn ->
      {:ok, _} = Tyrex.Pool.eval(:conc_pool, code)
    end,
    "single runtime (10 concurrent)" => fn ->
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Tyrex.eval(code, pid: single) end) end)
      |> Task.await_many()
    end,
    "pool (10 concurrent)" => fn ->
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Tyrex.Pool.eval(:conc_pool, code) end) end)
      |> Task.await_many()
    end,
    "pool (50 concurrent)" => fn ->
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> Tyrex.Pool.eval(:conc_pool, code) end) end)
      |> Task.await_many()
    end
  },
  time: 5,
  warmup: 2,
  print: [configuration: false]
)

Tyrex.stop(pid: single)
Supervisor.stop(:"conc_pool.Supervisor")
