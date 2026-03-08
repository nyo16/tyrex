# Run: TYREX_BUILD=true mix run bench/eval_bench.exs

{:ok, pid} = Tyrex.start()
{:ok, _} = Tyrex.Pool.start_link(name: :bench_pool, size: 4)

Benchee.run(
  %{
    "eval: simple arithmetic" => fn ->
      {:ok, _} = Tyrex.eval("1 + 2", pid: pid)
    end,
    "eval: string ops" => fn ->
      {:ok, _} = Tyrex.eval("'hello world'.toUpperCase()", pid: pid)
    end,
    "eval: JSON parse" => fn ->
      {:ok, _} = Tyrex.eval(~s|JSON.parse('{"a":1,"b":[2,3]}')|, pid: pid)
    end,
    "eval: array operations" => fn ->
      {:ok, _} = Tyrex.eval("[1,2,3,4,5].map(n => n * n).filter(n => n > 4)", pid: pid)
    end,
    "eval: promise (async)" => fn ->
      {:ok, _} = Tyrex.eval("Promise.resolve(42)", pid: pid)
    end,
    "eval: blocking arithmetic" => fn ->
      {:ok, _} = Tyrex.eval("1 + 2", pid: pid, blocking: true)
    end,
    "eval: blocking string ops" => fn ->
      {:ok, _} = Tyrex.eval("'hello world'.toUpperCase()", pid: pid, blocking: true)
    end,
    "pool: round-robin eval" => fn ->
      {:ok, _} = Tyrex.Pool.eval(:bench_pool, "1 + 2")
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  print: [configuration: false]
)

Tyrex.stop(pid: pid)
Supervisor.stop(:"bench_pool.Supervisor")
