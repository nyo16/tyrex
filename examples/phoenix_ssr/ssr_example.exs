# Phoenix SSR-like example
# Run: TYREX_BUILD=true mix run examples/phoenix_ssr/ssr_example.exs

IO.puts("=== Tyrex SSR Example ===\n")

# Start a pool for SSR
{:ok, _} =
  Tyrex.Pool.start_link(
    name: :ssr_pool,
    size: 2,
    main_module_path: "examples/phoenix_ssr/server.js"
  )

# Render a greeting component
props = Jason.encode!(%{name: "World", app: "Tyrex"})
{:ok, html} = Tyrex.Pool.eval(:ssr_pool, "renderComponent('greeting', #{props})")
IO.puts("Greeting HTML:\n#{html}\n")

# Render a card
props = Jason.encode!(%{title: "Tyrex", body: "Embedded Deno runtime for Elixir"})
{:ok, html} = Tyrex.Pool.eval(:ssr_pool, "renderComponent('card', #{props})")
IO.puts("Card HTML:\n#{html}\n")

# Render a list
props = Jason.encode!(%{items: ["Elixir", "Rust", "Deno", "TypeScript"]})
{:ok, html} = Tyrex.Pool.eval(:ssr_pool, "renderComponent('list', #{props})")
IO.puts("List HTML:\n#{html}\n")

# Template rendering
{:ok, html} =
  Tyrex.Pool.eval(:ssr_pool, """
    renderTemplate(
      '<h1>{{title}}</h1><p>By {{author}}</p>',
      {title: 'Tyrex Guide', author: 'The Team'}
    )
  """)

IO.puts("Template HTML:\n#{html}\n")

# Markdown to HTML
{:ok, html} =
  Tyrex.Pool.eval(:ssr_pool, """
    markdownToHtml('# Hello Tyrex\\n\\nThis is **bold** and *italic* text.\\n\\nUse `Tyrex.eval/2` to run JS.')
  """)

IO.puts("Markdown HTML:\n#{html}\n")

Supervisor.stop(:"ssr_pool.Supervisor")
IO.puts("=== Done! ===")
