defmodule TyrexStrategyTest do
  use ExUnit.Case, async: true

  describe "RoundRobin strategy" do
    test "cycles through indices" do
      state = Tyrex.Pool.Strategy.RoundRobin.init(:test_rr, 3)

      # Should cycle: 1, 2, 0, 1, 2, 0, ...
      assert Tyrex.Pool.Strategy.RoundRobin.select(state, []) == 1
      assert Tyrex.Pool.Strategy.RoundRobin.select(state, []) == 2
      assert Tyrex.Pool.Strategy.RoundRobin.select(state, []) == 0
      assert Tyrex.Pool.Strategy.RoundRobin.select(state, []) == 1

      assert :ok = Tyrex.Pool.Strategy.RoundRobin.terminate(state)
    end

    test "handles single pool size" do
      state = Tyrex.Pool.Strategy.RoundRobin.init(:test_rr_single, 1)

      for _ <- 1..5 do
        assert Tyrex.Pool.Strategy.RoundRobin.select(state, []) == 0
      end

      Tyrex.Pool.Strategy.RoundRobin.terminate(state)
    end
  end

  describe "Random strategy" do
    test "returns values within range" do
      state = Tyrex.Pool.Strategy.Random.init(:test_rand, 4)

      results =
        for _ <- 1..100 do
          Tyrex.Pool.Strategy.Random.select(state, [])
        end

      assert Enum.all?(results, &(&1 >= 0 and &1 < 4))
      # With 100 samples and 4 buckets, all should appear
      assert Enum.sort(Enum.uniq(results)) == [0, 1, 2, 3]
    end
  end

  describe "Hash strategy" do
    test "same key gives same index" do
      state = Tyrex.Pool.Strategy.Hash.init(:test_hash, 4)

      for _ <- 1..20 do
        idx = Tyrex.Pool.Strategy.Hash.select(state, key: "user_abc")
        assert idx == Tyrex.Pool.Strategy.Hash.select(state, key: "user_abc")
        assert idx >= 0 and idx < 4
      end
    end

    test "different keys distribute" do
      state = Tyrex.Pool.Strategy.Hash.init(:test_hash2, 8)

      indices =
        for i <- 1..100 do
          Tyrex.Pool.Strategy.Hash.select(state, key: "key_#{i}")
        end

      # With 100 keys and 8 buckets, should hit most buckets
      unique = Enum.uniq(indices)
      assert length(unique) >= 4
    end

    test "missing key falls back to random" do
      state = Tyrex.Pool.Strategy.Hash.init(:test_hash3, 4)
      idx = Tyrex.Pool.Strategy.Hash.select(state, [])
      assert idx >= 0 and idx < 4
    end
  end
end
