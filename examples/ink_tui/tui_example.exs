# Ink TUI rendering example
# Run: TYREX_BUILD=true mix run examples/ink_tui/tui_example.exs
# Note: First run downloads npm packages (react, ink) and may take longer.

IO.puts("=== Tyrex Ink TUI Example ===\n")

{:ok, pid} = Tyrex.start(main_module_path: "examples/ink_tui/tui.js")

# Status Dashboard
services =
  Jason.encode!([
    %{name: "API Gateway", status: "up"},
    %{name: "Database", status: "up"},
    %{name: "Cache Layer", status: "degraded"},
    %{name: "Worker Queue", status: "down"},
    %{name: "CDN", status: "up"}
  ])

{:ok, output} = Tyrex.eval("renderStatusDashboard(#{services})", pid: pid, timeout: 30_000)
IO.puts("Status Dashboard:\n#{output}\n")

# Data Table
table =
  Jason.encode!(%{
    headers: ["Name", "Role", "Status", "Tasks"],
    rows: [
      ["Alice", "Engineer", "Active", 12],
      ["Bob", "Designer", "Away", 5],
      ["Charlie", "PM", "Active", 23],
      ["Diana", "DevOps", "Active", 8]
    ]
  })

{:ok, output} = Tyrex.eval("renderDataTable(#{table})", pid: pid, timeout: 30_000)
IO.puts("Data Table:\n#{output}\n")

# Progress Bars
tasks =
  Jason.encode!([
    %{name: "Build", progress: 100},
    %{name: "Test Suite", progress: 72},
    %{name: "Deployment", progress: 45},
    %{name: "Migration", progress: 15},
    %{name: "Health Check", progress: 90}
  ])

{:ok, output} = Tyrex.eval("renderProgressBars(#{tasks})", pid: pid, timeout: 30_000)
IO.puts("Progress Bars:\n#{output}\n")

# Combined System Dashboard
dashboard =
  Jason.encode!(%{
    services: [
      %{name: "Web Server", status: "up"},
      %{name: "Background Jobs", status: "degraded"},
      %{name: "Mailer", status: "up"}
    ],
    table: %{
      headers: ["Metric", "Value", "Change"],
      rows: [
        ["Requests/s", "1,247", "+12%"],
        ["Avg Latency", "45ms", "-3%"],
        ["Error Rate", "0.02%", "-8%"],
        ["Uptime", "99.97%", "+0.01%"]
      ]
    },
    tasks: [
      %{name: "CPU Usage", progress: 62},
      %{name: "Memory", progress: 78},
      %{name: "Disk I/O", progress: 34}
    ]
  })

{:ok, output} = Tyrex.eval("renderSystemDashboard(#{dashboard})", pid: pid, timeout: 30_000)
IO.puts("System Dashboard:\n#{output}\n")

Tyrex.stop(pid: pid)
IO.puts("=== Done! ===")
