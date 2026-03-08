defmodule Tyrex.Pool do
  use Supervisor

  @doc """
  Start a pool of Tyrex runtimes.

  ## Options

    * `:name` - Required. The name of the pool.
    * `:size` - Number of runtimes. Defaults to `System.schedulers_online()`.
    * `:strategy` - Dispatch strategy module. Defaults to `Tyrex.Pool.Strategy.RoundRobin`.
    * `:main_module_path` - Path to the main JS module for all runtimes.
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
    runtime_opts = Keyword.take(opts, [:main_module_path])

    strategy_state = strategy_mod.init(name, size)

    :persistent_term.put({__MODULE__, name}, %{
      size: size,
      strategy_mod: strategy_mod,
      strategy_state: strategy_state
    })

    children =
      for i <- 0..(size - 1) do
        Supervisor.child_spec(
          {Tyrex, Keyword.merge(runtime_opts, name: :"#{name}.Runtime.#{i}")},
          id: {Tyrex, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Evaluate JavaScript code on a runtime selected by the pool's strategy.

  ## Options

    * `:key` - Dispatch key (used by hash strategy for sticky sessions).
    * `:timeout` - Timeout for the eval call.
    * `:blocking` - Whether to use blocking eval.
  """
  @spec eval(atom(), binary(), Keyword.t()) :: {:ok, term()} | {:error, Tyrex.Error.t()}
  def eval(pool_name, code, opts \\ []) do
    %{strategy_mod: mod, strategy_state: state} =
      :persistent_term.get({__MODULE__, pool_name})

    index = mod.select(state, opts)
    Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))
  end

  @doc """
  Same as `eval/3`, but raises on error.
  """
  @spec eval!(atom(), binary(), Keyword.t()) :: term()
  def eval!(pool_name, code, opts \\ []) do
    {:ok, result} = eval(pool_name, code, opts)
    result
  end
end
