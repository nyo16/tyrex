defmodule TyrexPoolTest do
  use ExUnit.Case, async: false

  defp runtime_children(sup) do
    sup
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
end
