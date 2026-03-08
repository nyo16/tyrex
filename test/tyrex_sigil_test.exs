defmodule TyrexSigilTest do
  use ExUnit.Case, async: false

  import Tyrex.Sigil

  describe "~JS sigil" do
    setup do
      {:ok, pid} = Tyrex.start()
      Tyrex.Inline.set_runtime(pid)
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "simple expression" do
      assert {:ok, 3} = ~JS"1 + 2"
    end

    test "string result" do
      assert {:ok, "hello"} = ~JS"'hello'"
    end

    test "JS template literals work" do
      assert {:ok, "Value: 42"} = ~JS"`Value: ${40 + 2}`"
    end

    test "multi-line code" do
      assert {:ok, [2, 4, 6]} = ~JS"""
             const arr = [1, 2, 3];
             arr.map(n => n * 2)
             """
    end

    test "object result" do
      assert {:ok, %{"a" => 1, "b" => 2}} = ~JS"({a: 1, b: 2})"
    end

    test "blocking modifier" do
      assert {:ok, 42} = ~JS"42"b
    end

    test "error returns error tuple" do
      assert {:error, %Tyrex.Error{name: :execution_error}} = ~JS"nonExistent"
    end

    test "promise is awaited" do
      assert {:ok, "done"} = ~JS"Promise.resolve('done')"
    end

    test "array operations" do
      assert {:ok, 15} = ~JS"[1, 2, 3, 4, 5].reduce((a, b) => a + b, 0)"
    end

    test "globalThis state" do
      {:ok, 42} = ~JS"globalThis.testVal = 42"
      assert {:ok, 42} = ~JS"globalThis.testVal"
    end
  end

  describe "Tyrex.Inline.eval with interpolation" do
    setup do
      {:ok, pid} = Tyrex.start()
      Tyrex.Inline.set_runtime(pid)
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "passes Elixir values via string interpolation" do
      x = 10
      assert {:ok, 15} = Tyrex.Inline.eval("#{x} + 5")
    end

    test "string interpolation" do
      name = "world"
      assert {:ok, "Hello, world!"} = Tyrex.Inline.eval("'Hello, ' + '#{name}!'")
    end

    test "complex interpolation" do
      items = Jason.encode!([1, 2, 3])

      assert {:ok, 6} =
               Tyrex.Inline.eval("""
               const items = #{items};
               items.reduce((a, b) => a + b, 0)
               """)
    end

    test "blocking option" do
      x = 21
      assert {:ok, 42} = Tyrex.Inline.eval("#{x} * 2", blocking: true)
    end
  end

  describe "Tyrex.Inline.with_runtime/2" do
    test "scoped runtime binding" do
      {:ok, pid} = Tyrex.start()

      result =
        Tyrex.Inline.with_runtime(pid, fn ->
          ~JS"1 + 1"
        end)

      assert {:ok, 2} = result
      assert Tyrex.Inline.get_runtime() == nil

      Tyrex.stop(pid: pid)
    end

    test "restores previous runtime" do
      {:ok, pid1} = Tyrex.start()
      {:ok, pid2} = Tyrex.start()

      Tyrex.Inline.set_runtime(pid1)

      Tyrex.Inline.with_runtime(pid2, fn ->
        assert Tyrex.Inline.get_runtime() == pid2
      end)

      assert Tyrex.Inline.get_runtime() == pid1

      Tyrex.stop(pid: pid1)
      Tyrex.stop(pid: pid2)
    end
  end

  describe "Tyrex.Inline without runtime" do
    test "raises when no runtime is set" do
      Process.delete(:tyrex_inline_runtime)

      assert_raise RuntimeError, ~r/No Tyrex runtime set/, fn ->
        ~JS"1 + 1"
      end
    end
  end

  describe "~JS with named runtime" do
    test "works with named process" do
      {:ok, _pid} = Tyrex.start_link(name: :sigil_test_runtime)
      Tyrex.Inline.set_runtime(:sigil_test_runtime)

      assert {:ok, 42} = ~JS"42"

      Tyrex.stop(name: :sigil_test_runtime)
    end
  end
end
