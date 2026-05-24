defmodule Tyrex.Pool.Registry do
  @moduledoc false
  # Internal: owns the persistent_term entry for a Tyrex.Pool and is responsible
  # for cleaning it up — and the strategy's ETS/state — on shutdown.
  #
  # The Registry is started as the FIRST child of the `Tyrex.Pool` supervisor
  # with a `:rest_for_one` strategy. Because Supervisor stops children in
  # reverse start order, the runtime children stop before the Registry, and
  # the Registry's `terminate/2` is invoked last — exactly when the
  # persistent_term entry and any strategy-owned resources should be erased.

  use GenServer

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{name: name} = args) do
    GenServer.start_link(__MODULE__, args, name: :"#{name}.Registry")
  end

  @impl GenServer
  def init(%{name: name, size: size, strategy_mod: strategy_mod, strategy_state: strategy_state}) do
    Process.flag(:trap_exit, true)

    :persistent_term.put({Tyrex.Pool, name}, %{
      size: size,
      strategy_mod: strategy_mod,
      strategy_state: strategy_state
    })

    {:ok,
     %{
       name: name,
       strategy_mod: strategy_mod,
       strategy_state: strategy_state
     }}
  end

  @impl GenServer
  def terminate(_reason, %{name: name, strategy_mod: strategy_mod, strategy_state: strategy_state}) do
    :persistent_term.erase({Tyrex.Pool, name})

    Code.ensure_loaded(strategy_mod)

    if function_exported?(strategy_mod, :terminate, 1) do
      try do
        strategy_mod.terminate(strategy_state)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end
end
