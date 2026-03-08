# Pool usage examples
# Run: TYREX_BUILD=true mix run examples/pool.exs

IO.puts("=== Tyrex Pool Examples ===\n")

# Start a pool with 4 runtimes
{:ok, _} = Tyrex.Pool.start_link(name: :my_pool, size: 4)

# Basic eval
{:ok, result} = Tyrex.Pool.eval(:my_pool, "2 + 2")
IO.puts("Pool eval: 2 + 2 = #{result}")

# Round-robin distribution
for i <- 1..8 do
  Tyrex.Pool.eval(:my_pool, "globalThis.id = #{i}")
end

for _ <- 1..8 do
  {:ok, id} = Tyrex.Pool.eval(:my_pool, "globalThis.id")
  IO.write("Runtime has id=#{id}  ")
end

IO.puts("")

Supervisor.stop(:"my_pool.Supervisor")

# Hash strategy - sticky sessions
{:ok, _} =
  Tyrex.Pool.start_link(
    name: :sticky_pool,
    size: 4,
    strategy: Tyrex.Pool.Strategy.Hash
  )

# Same user always hits same runtime
for _ <- 1..5 do
  Tyrex.Pool.eval(:sticky_pool, "globalThis.visits = (globalThis.visits || 0) + 1",
    key: "user_abc"
  )
end

{:ok, visits} = Tyrex.Pool.eval(:sticky_pool, "globalThis.visits", key: "user_abc")
IO.puts("\nSticky session - user_abc visited #{visits} times")

Supervisor.stop(:"sticky_pool.Supervisor")

# Concurrent pool usage
{:ok, _} = Tyrex.Pool.start_link(name: :conc_pool, size: 4)

tasks =
  for i <- 1..20 do
    Task.async(fn ->
      {:ok, result} = Tyrex.Pool.eval(:conc_pool, "#{i} * #{i}")
      result
    end)
  end

results = Task.await_many(tasks)
IO.puts("\nConcurrent squares: #{inspect(Enum.sort(results))}")

Supervisor.stop(:"conc_pool.Supervisor")

IO.puts("\n=== Done! ===")
