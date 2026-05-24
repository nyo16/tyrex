# Error handling patterns
# Run: TYREX_BUILD=true mix run examples/error_handling.exs
#
# Demonstrates how Tyrex surfaces the different failure modes in JS/TS via
# `%Tyrex.Error{}`. Every error path returns `{:error, %Tyrex.Error{name: ...}}`
# from `Tyrex.eval/2`, and `Tyrex.eval!/2` raises the same struct.

IO.puts("=== Tyrex Error Handling Examples ===\n")

# --- A "happy path" runtime for most demos ----------------------------------
{:ok, pid} = Tyrex.start()

# --- 1. Syntax / reference error -> :execution_error ------------------------
IO.puts("1) Syntax error (:execution_error)")

case Tyrex.eval("this is not js", pid: pid) do
  {:error, %Tyrex.Error{name: :execution_error, message: msg}} ->
    IO.puts("   matched :execution_error")
    IO.puts("   message: #{msg}")

  other ->
    IO.puts("   UNEXPECTED: #{inspect(other)}")
end

IO.puts("")

# --- 2. Promise rejection with a structured value ---------------------------
IO.puts("2) Rejected promise carrying a structured value (:promise_rejection)")

case Tyrex.eval("Promise.reject({code: 'OOPS', detail: 'boom'})", pid: pid) do
  {:error, %Tyrex.Error{name: :promise_rejection, value: value}} ->
    IO.puts("   matched :promise_rejection")
    # `:value` is the decoded JSON object the JS code rejected with.
    IO.inspect(value, label: "   value")

  other ->
    IO.puts("   UNEXPECTED: #{inspect(other)}")
end

IO.puts("")

# --- 3. Permission denial in a no-permissions runtime -----------------------
IO.puts("3) Permission denial inside a `permissions: :none` runtime")

{:ok, locked_pid} = Tyrex.start(permissions: :none)

case Tyrex.eval("(async () => await fetch('https://example.com'))()", pid: locked_pid) do
  {:error, %Tyrex.Error{name: name, message: msg, value: value}} ->
    IO.puts("   matched :#{name}")
    IO.puts("   message: #{inspect(msg)}")
    # `fetch` rejects with a permission error -> Deno surfaces it as a promise
    # rejection containing the permission message.
    IO.inspect(value, label: "   value")

  other ->
    IO.puts("   UNEXPECTED: #{inspect(other)}")
end

IO.puts("")

# --- 4. `eval!` raising on the same shape -----------------------------------
IO.puts("4) `Tyrex.eval!/2` raises `Tyrex.Error` instead of returning a tuple")

try do
  Tyrex.eval!("throw new Error('boom from bang')", pid: pid)
rescue
  e in Tyrex.Error ->
    IO.puts("   rescued Tyrex.Error")
    IO.puts("   name: :#{e.name}")
    IO.puts("   Exception.message/1: #{Exception.message(e)}")
end

IO.puts("")

# --- Cleanup ----------------------------------------------------------------
Tyrex.stop(pid: pid)
Tyrex.stop(pid: locked_pid)

IO.puts("=== Done! ===")
