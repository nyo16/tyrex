# Run: TYREX_BUILD=true mix run bench/startup_bench.exs
#
# Measures runtime startup/shutdown overhead and first-eval latency.

Benchee.run(
  %{
    "start + stop (no module)" => fn ->
      {:ok, pid} = Tyrex.start(permissions: :none)
      Tyrex.stop(pid: pid)
    end,
    "start + first eval + stop" => fn ->
      {:ok, pid} = Tyrex.start(permissions: :none)
      {:ok, _} = Tyrex.eval("1", pid: pid)
      Tyrex.stop(pid: pid)
    end,
    "start with module + eval + stop" => fn ->
      {:ok, pid} = Tyrex.start(permissions: :none, main_module_path: "priv/main.js")
      {:ok, _} = Tyrex.eval("1", pid: pid)
      Tyrex.stop(pid: pid)
    end
  },
  time: 5,
  warmup: 2,
  print: [configuration: false]
)
