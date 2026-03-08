# Basic Tyrex usage examples
# Run: TYREX_BUILD=true mix run examples/basic.exs

IO.puts("=== Tyrex Basic Examples ===\n")

# Start a single runtime
{:ok, pid} = Tyrex.start()

# Simple arithmetic
{:ok, result} = Tyrex.eval("1 + 2", pid: pid)
IO.puts("1 + 2 = #{result}")

# String manipulation
{:ok, result} = Tyrex.eval("'Hello, Tyrex!'.toUpperCase()", pid: pid)
IO.puts("Uppercase: #{result}")

# JSON handling
{:ok, result} = Tyrex.eval("JSON.stringify({name: 'Tyrex', lang: 'Elixir+Rust+Deno'})", pid: pid)
IO.puts("JSON: #{result}")

# Arrays and functional JS
{:ok, result} = Tyrex.eval("[1,2,3,4,5].filter(x => x % 2 === 0).map(x => x * x)", pid: pid)
IO.puts("Even squares: #{inspect(result)}")

# Deno APIs
{:ok, version} = Tyrex.eval("Deno.version", pid: pid)
IO.puts("Deno version: #{inspect(version)}")

# Stateful - set then get
Tyrex.eval("globalThis.counter = 0", pid: pid)
for _ <- 1..5, do: Tyrex.eval("globalThis.counter++", pid: pid)
{:ok, count} = Tyrex.eval("globalThis.counter", pid: pid)
IO.puts("Counter after 5 increments: #{count}")

# Async - setTimeout
{:ok, result} =
  Tyrex.eval(
    """
      new Promise(resolve => setTimeout(() => resolve("delayed result"), 100))
    """,
    pid: pid
  )

IO.puts("Async result: #{result}")

# Bidirectional - call Elixir from JS
{:ok, result} =
  Tyrex.eval(
    ~s|(async () => await Tyrex.apply("Enum", "sum", [[10, 20, 30]]))()|,
    pid: pid
  )

IO.puts("Enum.sum from JS: #{result}")

# Call Enum.reverse from JS
{:ok, result} =
  Tyrex.eval(
    ~s|(async () => await Tyrex.apply("Enum", "reverse", [[1,2,3]]))()|,
    pid: pid
  )

IO.puts("Enum.reverse from JS: #{inspect(result)}")

Tyrex.stop(pid: pid)
IO.puts("\n=== Done! ===")
