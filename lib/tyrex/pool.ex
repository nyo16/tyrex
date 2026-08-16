defmodule Tyrex.Pool do
  @moduledoc """
  A pool of Deno runtimes with pluggable dispatch strategies.

  `Tyrex.Pool` is a `Supervisor` that starts multiple `Tyrex` GenServer children
  and distributes `eval` calls across them using a configurable strategy.

  ## Usage

      # In your supervision tree
      children = [
        {Tyrex.Pool, name: :js_pool, size: 4}
      ]

      # Evaluate code on a pool-selected runtime
      {:ok, result} = Tyrex.Pool.eval(:js_pool, "1 + 2")

  ## Strategies

    * `Tyrex.Pool.Strategy.RoundRobin` (default) — cycles through runtimes sequentially
    * `Tyrex.Pool.Strategy.Random` — picks a random runtime
    * `Tyrex.Pool.Strategy.Hash` — routes by `:key` option for sticky sessions

  See `Tyrex.Pool.Strategy` for implementing custom strategies.

  ## Lifecycle

  The pool registers its metadata in `:persistent_term` and may own ETS tables
  via its strategy. Both are cleaned up automatically when the supervisor is
  stopped — `Tyrex.Pool` is safe to start and stop dynamically (e.g. one pool
  per tenant) without leaking persistent_term or ETS resources.
  """

  use Supervisor

  alias Tyrex.Error

  @doc """
  Start a pool of Tyrex runtimes.

  ## Options

    * `:name` - Required. The name of the pool.
    * `:size` - Number of runtimes. Defaults to `System.schedulers_online()`.
    * `:strategy` - Dispatch strategy module. Defaults to `Tyrex.Pool.Strategy.RoundRobin`.
    * `:main_module_path` - Path to the main JS module for all runtimes.
    * `:permissions` - Runtime permissions. See `Tyrex.start/1` for details.
    * `:apply` - Elixir bridge allowlist. See `Tyrex.start/1` for details.
    * `:max_heap_mb` - Per-runtime V8 heap cap. See `Tyrex.start/1` for details.
    * `:max_restarts` / `:max_seconds` - Restart intensity for the runtime
      children. Defaults to `max(size * 4, 12)` restarts in 5 seconds.

  Runtimes are supervised `:one_for_one`, so one runtime hitting its `:timeout`
  or `:max_heap_mb` cap does not disturb its siblings. The default intensity is
  deliberately generous because guest code chooses the failure rate: a
  terminated runtime is ordinary operation here, not a systemic fault.
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: :"#{name}.Supervisor")
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    size = Keyword.get(opts, :size, System.schedulers_online())
    strategy_mod = Keyword.get(opts, :strategy, Tyrex.Pool.Strategy.RoundRobin)

    runtime_opts =
      Keyword.take(opts, [:main_module_path, :permissions, :startup_timeout, :apply, :max_heap_mb])

    strategy_state = strategy_mod.init(name, size)

    registry_child =
      Supervisor.child_spec(
        {Tyrex.Pool.Registry,
         %{
           name: name,
           size: size,
           strategy_mod: strategy_mod,
           strategy_state: strategy_state
         }},
        id: Tyrex.Pool.Registry
      )

    runtime_children =
      for i <- 0..(size - 1) do
        Supervisor.child_spec(
          {Tyrex, Keyword.merge(runtime_opts, name: :"#{name}.Runtime.#{i}")},
          id: {Tyrex, i}
        )
      end

    runtime_supervisor =
      Supervisor.child_spec(
        {Tyrex.Pool.RuntimeSupervisor,
         [children: runtime_children, size: size] ++
           Keyword.take(opts, [:max_restarts, :max_seconds])},
        id: Tyrex.Pool.RuntimeSupervisor
      )

    # Registry is the FIRST child so it terminates LAST — its terminate/2 then
    # gets to erase the persistent_term entry after all runtimes have stopped.
    # `:rest_for_one` ensures a Registry crash takes down the runtimes so the
    # supervisor rebuilds them with a fresh persistent_term entry.
    #
    # The runtimes themselves sit one level down, `:one_for_one`, so that a
    # single guest's deadline or heap trip does not restart its siblings. See
    # `Tyrex.Pool.RuntimeSupervisor` for why that mattered enough to add a layer.
    Supervisor.init([registry_child, runtime_supervisor], strategy: :rest_for_one)
  end

  @doc """
  Run JavaScript code on a runtime selected by the pool's strategy.

  ## Options

    * `:key` - Dispatch key (used by hash strategy for sticky sessions).
    * `:timeout` - Timeout for the call.
    * `:blocking` - Whether to use blocking mode.
  """
  @spec eval(atom(), binary(), Keyword.t()) :: {:ok, term()} | {:error, Tyrex.Error.t()}
  def eval(pool_name, code, opts \\ []) do
    %{strategy_mod: mod, strategy_state: state} =
      :persistent_term.get({__MODULE__, pool_name})

    index = mod.select(state, opts)
    Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))
  end

  @doc """
  Same as `eval/3`, but raises `Tyrex.Error` on error.
  """
  @spec eval!(atom(), binary(), Keyword.t()) :: term() | no_return()
  def eval!(pool_name, code, opts \\ []) do
    case eval(pool_name, code, opts) do
      {:ok, result} -> result
      {:error, %Error{} = e} -> raise e
    end
  end
end
