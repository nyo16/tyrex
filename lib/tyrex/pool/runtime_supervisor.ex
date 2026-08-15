defmodule Tyrex.Pool.RuntimeSupervisor do
  @moduledoc false

  # The runtime children of a `Tyrex.Pool`, supervised `:one_for_one`.
  #
  # This layer exists because of the blast radius, not for tidiness. As of
  # v0.4.0 an eval deadline or a `:max_heap_mb` trip stops the runtime's
  # GenServer, which turns a *guest-triggered* event into a supervisor restart
  # event. When the runtimes sat directly under the pool's `:rest_for_one`
  # supervisor, one guest that simply did not finish restarted every runtime
  # ordered after it (measured: 4/4 for a pool of four), and five such events in
  # a couple of seconds exhausted the default restart intensity and took the
  # pool supervisor down with it. Siblings are *signalled* rather than stopped
  # and `Tyrex` does not trap exits, so their `terminate/2` — and the in-flight
  # drain it performs — was skipped, and `{:shutdown, _}` terminations are not
  # logged, so the churn was silent. In a library whose premise is untrusted
  # code, that is a denial of service reachable from a `while (true) {}`.
  #
  # Runtimes are independent of one another: nothing about runtime N's state is
  # derived from runtime N-1. Only the pool Registry needs ordering with respect
  # to them, and that ordering is preserved by the parent, which keeps
  # `:rest_for_one` so that a Registry crash still rebuilds every runtime
  # against a fresh `:persistent_term` entry.
  #
  # The restart intensity is deliberately generous and configurable, because the
  # guest chooses the failure rate. Supervisor intensity exists to catch "this
  # child cannot start"; here a terminated runtime is ordinary operation, so the
  # default has to accommodate a pool-wide burst without treating it as a
  # systemic fault.

  use Supervisor

  @default_max_seconds 5

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl Supervisor
  def init(opts) do
    children = Keyword.fetch!(opts, :children)
    size = Keyword.fetch!(opts, :size)

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: Keyword.get(opts, :max_restarts, max(size * 4, 12)),
      max_seconds: Keyword.get(opts, :max_seconds, @default_max_seconds)
    )
  end
end
