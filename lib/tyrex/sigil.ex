defmodule Tyrex.Sigil do
  @moduledoc ~s'''
  Provides the `~JS` sigil for inline JavaScript evaluation.

  ## Setup

      import Tyrex.Sigil

  ## Usage

  The `~JS` sigil evaluates raw JavaScript code using the runtime set via
  `Tyrex.Inline.set_runtime/1`.

      import Tyrex.Sigil

      {:ok, pid} = Tyrex.start()
      Tyrex.Inline.set_runtime(pid)

      {:ok, 3} = ~JS"1 + 2"
      {:ok, "hello"} = ~JS"'hello'.toLowerCase()"

      # JS template literals work since ~JS doesn't interpolate
      {:ok, "Value: 42"} = ~JS"`Value: ${40 + 2}`"

      # Multi-line
      {:ok, [2, 4, 6]} = ~JS"""
      const arr = [1, 2, 3];
      arr.map(n => n * 2)
      """

  For passing Elixir values into JavaScript, use `Tyrex.Inline.eval/1`
  with standard string interpolation:

      x = 10
      {:ok, 15} = Tyrex.Inline.eval("\#{x} + 5")

  ## Modifiers

    * `b` — Use blocking mode (fast, for <1ms evaluations)

          {:ok, 3} = ~JS"1 + 2"b

  ## Runtime Selection

  The sigil uses whatever runtime was set in the current process:

      Tyrex.Inline.set_runtime(pid)
      Tyrex.Inline.set_runtime(MyApp.JS)

  Or use `Tyrex.Inline.with_runtime/2` for scoped execution:

      Tyrex.Inline.with_runtime(pid, fn ->
        {:ok, 3} = ~JS"1 + 2"
      end)
  '''

  @doc """
  Raw JavaScript sigil (no interpolation).

  Evaluates JavaScript code on the current process's Tyrex runtime.
  Returns `{:ok, result}` or `{:error, %Tyrex.Error{}}`.

  Use modifier `b` for blocking mode.
  """
  defmacro sigil_JS({:<<>>, _meta, _pieces} = code, modifiers) do
    opts = if ?b in modifiers, do: [blocking: true], else: []

    quote do
      Tyrex.Inline.eval(unquote(code), unquote(opts))
    end
  end
end
