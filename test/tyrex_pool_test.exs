defmodule TyrexPoolTest do
  use ExUnit.Case, async: false

  # Runtimes live one level down, under `Tyrex.Pool.RuntimeSupervisor`, so that a
  # single guest's deadline or heap trip cannot restart its siblings.
  defp runtime_supervisor(pool_sup) do
    pool_sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Tyrex.Pool.RuntimeSupervisor, pid, _type, _mods} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp runtime_children(pool_sup) do
    pool_sup
    |> runtime_supervisor()
    |> Supervisor.which_children()
    |> Enum.filter(fn
      {{Tyrex, _i}, _pid, _type, _mods} -> true
      _ -> false
    end)
  end

  describe "pool basics" do
    test "start a pool and eval" do
      {:ok, _} = Tyrex.Pool.start_link(name: :basic_pool, size: 2)
      assert {:ok, 3} = Tyrex.Pool.eval(:basic_pool, "1 + 2")
      assert {:ok, "hello"} = Tyrex.Pool.eval(:basic_pool, "'hello'")
      Supervisor.stop(:"basic_pool.Supervisor")
    end

    test "pool defaults size to schedulers_online" do
      {:ok, sup} = Tyrex.Pool.start_link(name: :default_size_pool)
      runtimes = runtime_children(sup)
      assert length(runtimes) == System.schedulers_online()
      Supervisor.stop(sup)
    end

    test "pool with explicit size" do
      {:ok, sup} = Tyrex.Pool.start_link(name: :sized_pool, size: 3)
      runtimes = runtime_children(sup)
      assert length(runtimes) == 3
      Supervisor.stop(sup)
    end

    test "eval! returns unwrapped value" do
      {:ok, _} = Tyrex.Pool.start_link(name: :bang_pool, size: 1)
      assert 42 = Tyrex.Pool.eval!(:bang_pool, "42")
      Supervisor.stop(:"bang_pool.Supervisor")
    end
  end

  describe "round-robin strategy" do
    test "distributes across runtimes" do
      {:ok, _} = Tyrex.Pool.start_link(name: :rr_pool, size: 2)

      # Set state on alternating runtimes
      Tyrex.Pool.eval(:rr_pool, "globalThis.who = 'runtime_0'")
      Tyrex.Pool.eval(:rr_pool, "globalThis.who = 'runtime_1'")

      # Should cycle back
      assert {:ok, "runtime_0"} = Tyrex.Pool.eval(:rr_pool, "globalThis.who")
      assert {:ok, "runtime_1"} = Tyrex.Pool.eval(:rr_pool, "globalThis.who")

      Supervisor.stop(:"rr_pool.Supervisor")
    end
  end

  describe "random strategy" do
    test "selects randomly" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :rand_pool,
          size: 4,
          strategy: Tyrex.Pool.Strategy.Random
        )

      # Just verify it works (can't test randomness deterministically)
      results =
        for _ <- 1..20 do
          {:ok, result} = Tyrex.Pool.eval(:rand_pool, "1 + 1")
          result
        end

      assert Enum.all?(results, &(&1 == 2))

      Supervisor.stop(:"rand_pool.Supervisor")
    end
  end

  describe "hash strategy" do
    test "same key always hits same runtime" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :hash_pool,
          size: 4,
          strategy: Tyrex.Pool.Strategy.Hash
        )

      # Set state with a specific key
      Tyrex.Pool.eval(:hash_pool, "globalThis.session = Math.random()", key: "user_123")

      # Same key should always get the same value back
      {:ok, value} = Tyrex.Pool.eval(:hash_pool, "globalThis.session", key: "user_123")

      for _ <- 1..10 do
        assert {:ok, ^value} =
                 Tyrex.Pool.eval(:hash_pool, "globalThis.session", key: "user_123")
      end

      Supervisor.stop(:"hash_pool.Supervisor")
    end

    test "different keys may hit different runtimes" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :hash_pool2,
          size: 4,
          strategy: Tyrex.Pool.Strategy.Hash
        )

      # Set unique values per key using key-specific variable names
      for i <- 1..20 do
        Tyrex.Pool.eval(:hash_pool2, "globalThis.val_key_#{i} = #{i}", key: "key_#{i}")
      end

      # Verify sticky sessions - same key hits same runtime with key-specific var
      for i <- 1..20 do
        {:ok, val} = Tyrex.Pool.eval(:hash_pool2, "globalThis.val_key_#{i}", key: "key_#{i}")
        assert val == i
      end

      Supervisor.stop(:"hash_pool2.Supervisor")
    end

    test "no key falls back to random" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :hash_pool3,
          size: 2,
          strategy: Tyrex.Pool.Strategy.Hash
        )

      # Without key, should still work
      assert {:ok, 5} = Tyrex.Pool.eval(:hash_pool3, "2 + 3")

      Supervisor.stop(:"hash_pool3.Supervisor")
    end
  end

  describe "pool with main module" do
    test "all runtimes share the same main module" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :module_pool,
          size: 2,
          main_module_path: "test/support/main_module.js"
        )

      # Both runtimes should have the module loaded
      assert {:ok, 5} = Tyrex.Pool.eval(:module_pool, "addNumbers(2, 3)")
      assert {:ok, 7} = Tyrex.Pool.eval(:module_pool, "addNumbers(3, 4)")

      Supervisor.stop(:"module_pool.Supervisor")
    end
  end

  # `Tyrex.Pool.init/1` re-lists the options it hands to each child, so a
  # runtime option can exist on `Tyrex.start_link/1` and never reach a pooled
  # runtime — `:apply` and `:max_heap_mb` were dropped exactly that way until
  # v0.4.0, and a pooled runtime has no other route to a heap cap.
  describe "pool option forwarding" do
    test ":apply reaches every runtime in the pool" do
      {:ok, _} = Tyrex.Pool.start_link(name: :apply_pool, size: 2, apply: [{Enum, :sum, 1}])

      # Round-robin, so two calls exercise both children: the allowlist has to
      # have reached each of them, not just the one the first eval landed on.
      for _ <- 1..2 do
        assert {:ok, 6} =
                 Tyrex.Pool.eval(
                   :apply_pool,
                   ~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|
                 )
      end

      # And the allowlist travelled, not merely the bridge: an MFA outside it is
      # refused by the runtime that received the list.
      assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} =
               Tyrex.Pool.eval(
                 :apply_pool,
                 ~s|(async () => await Tyrex.apply("File", "read!", ["mix.exs"]))()|
               )

      assert value =~ "permission_denied"

      Supervisor.stop(:"apply_pool.Supervisor")
    end

    test "a pool started without :apply has no bridge in its runtimes" do
      {:ok, _} = Tyrex.Pool.start_link(name: :no_apply_pool, size: 2)

      # The negative case that makes the positive one mean something: without
      # `:apply` the bootstrap deletes the global, so a bridge observed above
      # can only have come from the forwarded allowlist.
      for _ <- 1..2 do
        assert {:ok, "undefined"} = Tyrex.Pool.eval(:no_apply_pool, "typeof globalThis.Tyrex")
      end

      Supervisor.stop(:"no_apply_pool.Supervisor")
    end

    @tag timeout: 120_000
    test ":max_heap_mb reaches a pooled runtime and caps it" do
      {:ok, sup} =
        Tyrex.Pool.start_link(
          name: :heap_pool,
          size: 1,
          permissions: :none,
          max_heap_mb: 64
        )

      code = """
      const chunks = [];
      for (;;) { chunks.push(new Array(1_000_000).fill(7)); }
      """

      # Pinned by equality. If the cap never reached the child the guest just
      # allocates until the eval deadline and reports `:timeout`, which would
      # leave this green over a pool whose runtimes have no heap limit at all.
      assert {:error, %Tyrex.Error{name: :heap_limit_error}} =
               Tyrex.Pool.eval(:heap_pool, code, timeout: 30_000)

      Supervisor.stop(sup)
    end
  end

  describe "pool concurrency" do
    test "handles concurrent requests" do
      {:ok, _} = Tyrex.Pool.start_link(name: :conc_pool, size: 4)

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            {:ok, result} = Tyrex.Pool.eval(:conc_pool, "#{i} * 3")
            result
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.sort(results) == Enum.map(1..50, &(&1 * 3))

      Supervisor.stop(:"conc_pool.Supervisor")
    end
  end

  describe "pool cleanup" do
    test "pool stop erases persistent_term and ETS state" do
      {:ok, sup} = Tyrex.Pool.start_link(name: :cleanup_pool, size: 2)
      # Ensure init has completed before sampling state.
      :sys.get_state(sup)

      assert %{size: 2} = :persistent_term.get({Tyrex.Pool, :cleanup_pool})

      # The default RoundRobin strategy owns an ETS table named after the pool.
      ets_names_before = :ets.all() |> Enum.map(&:ets.info(&1, :name))
      assert :"cleanup_pool.RoundRobin" in ets_names_before

      Supervisor.stop(sup)
      refute Process.alive?(sup)

      assert :persistent_term.get({Tyrex.Pool, :cleanup_pool}, :missing) == :missing

      ets_names_after = :ets.all() |> Enum.map(&:ets.info(&1, :name))
      refute :"cleanup_pool.RoundRobin" in ets_names_after
    end

    test "repeated start/stop cycles do not leak persistent_term entries" do
      base = :persistent_term.info().count

      for i <- 1..5 do
        name = :"leak_pool_#{i}"
        {:ok, sup} = Tyrex.Pool.start_link(name: name, size: 1)
        :sys.get_state(sup)
        assert %{size: 1} = :persistent_term.get({Tyrex.Pool, name})
        Supervisor.stop(sup)
        assert :persistent_term.get({Tyrex.Pool, name}, :missing) == :missing
      end

      # Count should be unchanged after the cycle (allow a tiny drift for
      # unrelated entries created by other code in this VM).
      after_count = :persistent_term.info().count
      assert after_count - base <= 1
    end
  end

  # Making eval deadlines real turned a guest-triggered, caller-local timeout
  # into a supervisor restart event. With the runtimes directly under the pool's
  # `:rest_for_one` supervisor that was a denial of service reachable from
  # `while (true) {}`: one deadline restarted every runtime ordered after the
  # victim (measured 4/4 for a pool of four), and five deadlines in ~2.5s
  # exhausted the default intensity and took the pool supervisor down with
  # `:shutdown`. Siblings were signalled rather than stopped, so their
  # `terminate/2` — and the in-flight drain it performs — was skipped, and
  # `{:shutdown, _}` terminations are not logged, so the churn was silent.
  describe "one guest cannot take out the pool" do
    @tag timeout: 120_000
    test "a deadline on one runtime leaves its siblings untouched" do
      {:ok, sup} = Tyrex.Pool.start_link(name: :blast_pool, size: 4, permissions: :none)
      names = for i <- 0..3, do: :"blast_pool.Runtime.#{i}"
      before = Map.new(names, fn n -> {n, Process.whereis(n)} end)
      assert Enum.all?(before, fn {_n, pid} -> is_pid(pid) end)

      victim = before[:"blast_pool.Runtime.0"]
      ref = Process.monitor(victim)
      spawn(fn -> Tyrex.eval("for(;;){}", pid: victim, timeout: 300) end)
      assert_receive {:DOWN, ^ref, :process, ^victim, {:shutdown, :timeout}}, 5_000

      # Let the supervisor replace it.
      assert eventually(fn -> is_pid(Process.whereis(:"blast_pool.Runtime.0")) end)

      # The victim was replaced...
      refute Process.whereis(:"blast_pool.Runtime.0") == victim

      # ...and nothing else moved. This is the assertion: under `:rest_for_one`
      # all three siblings had a new pid here.
      for n <- tl(names) do
        assert Process.whereis(n) == before[n],
               "#{n} was restarted by an unrelated runtime's deadline"

        assert Process.alive?(before[n])
      end

      Supervisor.stop(sup)
    end

    @tag timeout: 120_000
    test "repeated deadlines do not exhaust the pool supervisor" do
      {:ok, sup} = Tyrex.Pool.start_link(name: :storm_pool, size: 2, permissions: :none)

      # Six is comfortably past the default intensity of 3-in-5s that killed the
      # supervisor before the runtimes were rescoped.
      for _ <- 1..6 do
        victim = Process.whereis(:"storm_pool.Runtime.0")

        if is_pid(victim) do
          ref = Process.monitor(victim)
          spawn(fn -> Tyrex.eval("for(;;){}", pid: victim, timeout: 200) end)
          assert_receive {:DOWN, ^ref, :process, ^victim, _}, 5_000
        end

        assert Process.alive?(sup), "the pool supervisor died after a guest deadline"
      end

      assert eventually(fn -> match?({:ok, 1}, Tyrex.Pool.eval(:storm_pool, "1")) end)

      Supervisor.stop(sup)
    end
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end
end
