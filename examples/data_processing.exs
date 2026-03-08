# Data processing example
# Run: TYREX_BUILD=true mix run examples/data_processing.exs

IO.puts("=== Tyrex Data Processing Examples ===\n")

{:ok, pid} = Tyrex.start(main_module_path: "examples/data_processing.js")

# CSV parsing
csv = "name,age,city\nAlice,30,NYC\nBob,25,LA\nCharlie,35,Chicago"
{:ok, result} = Tyrex.eval("parseCSV(`#{csv}`)", pid: pid)
IO.puts("CSV parsed:")
for row <- result, do: IO.puts("  #{row["name"]} (#{row["age"]}) from #{row["city"]}")

# Statistics
{:ok, result} = Tyrex.eval("stats([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])", pid: pid)
IO.puts("\nStatistics for 1..10:")

IO.puts(
  "  Mean: #{result["mean"]}, Median: #{result["median"]}, StdDev: #{Float.round(result["stddev"], 2)}"
)

# URL parsing
{:ok, result} =
  Tyrex.eval(~s|parseUrl("https://example.com/api/users?page=2&limit=10")|, pid: pid)

IO.puts("\nURL parsed:")
IO.puts("  Host: #{result["host"]}, Path: #{result["pathname"]}")
IO.puts("  Params: #{inspect(result["params"])}")

# HTML sanitization
{:ok, result} = Tyrex.eval(~s|sanitizeHtml('<script>alert("xss")</script>')|, pid: pid)
IO.puts("\nSanitized: #{result}")

# Data transformation
data =
  Jason.encode!([
    %{first_name: "Alice", last_name: "Smith"},
    %{first_name: "Bob", last_name: "Jones"}
  ])

mapping = Jason.encode!(%{name: "first_name", surname: "last_name"})
{:ok, result} = Tyrex.eval("transformData(#{data}, #{mapping})", pid: pid)
IO.puts("\nTransformed data:")
for row <- result, do: IO.puts("  #{row["name"]} #{row["surname"]}")

Tyrex.stop(pid: pid)
IO.puts("\n=== Done! ===")
