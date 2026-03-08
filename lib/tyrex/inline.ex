defmodule Tyrex.Inline do
  @moduledoc """
  Process-local runtime management for the `~JS` sigil.

  Stores the current Tyrex runtime reference in the process dictionary so
  `~JS` sigils don't need to specify a runtime on every call.

  ## Usage

      import Tyrex.Sigil

      {:ok, pid} = Tyrex.start()
      Tyrex.Inline.set_runtime(pid)

      {:ok, 3} = ~JS"1 + 2"

  ## Scoped Runtime

      Tyrex.Inline.with_runtime(pid, fn ->
        {:ok, 3} = ~JS"1 + 2"
      end)
  """

  @runtime_key :tyrex_inline_runtime

  @doc """
  Set the Tyrex runtime for the current process.

  Accepts a PID or a registered name.

      Tyrex.Inline.set_runtime(pid)
      Tyrex.Inline.set_runtime(MyApp.JS)
  """
  @spec set_runtime(pid() | atom()) :: pid() | atom() | nil
  def set_runtime(pid_or_name) do
    Process.put(@runtime_key, pid_or_name)
  end

  @doc """
  Get the current Tyrex runtime for this process, or `nil` if not set.
  """
  @spec get_runtime() :: pid() | atom() | nil
  def get_runtime do
    Process.get(@runtime_key)
  end

  @doc """
  Execute a function with a temporary runtime binding.

  The previous runtime (if any) is restored after the function returns.

      Tyrex.Inline.with_runtime(pid, fn ->
        {:ok, 3} = ~JS"1 + 2"
      end)
  """
  @spec with_runtime(pid() | atom(), (-> result)) :: result when result: var
  def with_runtime(pid_or_name, fun) do
    previous = Process.get(@runtime_key)
    Process.put(@runtime_key, pid_or_name)

    try do
      fun.()
    after
      if previous do
        Process.put(@runtime_key, previous)
      else
        Process.delete(@runtime_key)
      end
    end
  end

  @doc """
  Evaluate JavaScript code on the current process's runtime.

  This is called by the `~JS` sigil — you typically don't call it directly.
  """
  @spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Tyrex.Error.t()}
  def eval(code, opts \\ []) do
    case Process.get(@runtime_key) do
      nil ->
        raise "No Tyrex runtime set for this process. Call Tyrex.Inline.set_runtime/1 first."

      runtime when is_pid(runtime) ->
        Tyrex.eval(code, Keyword.put(opts, :pid, runtime))

      runtime when is_atom(runtime) ->
        Tyrex.eval(code, Keyword.put(opts, :name, runtime))
    end
  end
end
