defmodule TyrexTest do
  use ExUnit.Case, async: false

  describe "start/stop" do
    test "start and stop a runtime" do
      {:ok, pid} = Tyrex.start()
      assert Process.alive?(pid)
      assert :ok = Tyrex.stop(pid: pid)
      refute Process.alive?(pid)
    end

    test "start_link with name" do
      {:ok, pid} = Tyrex.start_link(name: :test_named)
      assert Process.alive?(pid)
      assert Process.whereis(:test_named) == pid
      Tyrex.stop(name: :test_named)
    end

    test "start with main_module_path" do
      {:ok, pid} = Tyrex.start(main_module_path: "test/support/main_module.js")
      assert {:ok, "TyrexTestApp"} = Tyrex.eval("appName", pid: pid)
      Tyrex.stop(pid: pid)
    end

    test "start with invalid main_module_path returns error" do
      assert {:error, _} = Tyrex.start(main_module_path: "nonexistent/file.js")
    end
  end

  describe "eval/2 - basic expressions" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "integer arithmetic", %{pid: pid} do
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
      assert {:ok, 42} = Tyrex.eval("6 * 7", pid: pid)
      assert {:ok, 10} = Tyrex.eval("100 / 10", pid: pid)
      assert {:ok, 1} = Tyrex.eval("10 % 3", pid: pid)
    end

    test "floating point arithmetic", %{pid: pid} do
      assert {:ok, 3.14} = Tyrex.eval("3.14", pid: pid)
      assert {:ok, result} = Tyrex.eval("0.1 + 0.2", pid: pid)
      assert_in_delta result, 0.3, 0.0001
    end

    test "string operations", %{pid: pid} do
      assert {:ok, "hello world"} = Tyrex.eval("'hello' + ' ' + 'world'", pid: pid)
      assert {:ok, "HELLO"} = Tyrex.eval("'hello'.toUpperCase()", pid: pid)
      assert {:ok, 5} = Tyrex.eval("'hello'.length", pid: pid)
    end

    test "boolean values", %{pid: pid} do
      assert {:ok, true} = Tyrex.eval("true", pid: pid)
      assert {:ok, false} = Tyrex.eval("false", pid: pid)
      assert {:ok, true} = Tyrex.eval("1 === 1", pid: pid)
      assert {:ok, false} = Tyrex.eval("1 === 2", pid: pid)
    end

    test "null and undefined", %{pid: pid} do
      assert {:ok, nil} = Tyrex.eval("null", pid: pid)
      assert {:ok, nil} = Tyrex.eval("undefined", pid: pid)
    end

    test "arrays", %{pid: pid} do
      assert {:ok, [1, 2, 3]} = Tyrex.eval("[1, 2, 3]", pid: pid)
      assert {:ok, []} = Tyrex.eval("[]", pid: pid)
      assert {:ok, ["a", "b"]} = Tyrex.eval("['a', 'b']", pid: pid)
    end

    test "objects", %{pid: pid} do
      assert {:ok, %{"a" => 1, "b" => 2}} = Tyrex.eval("({a: 1, b: 2})", pid: pid)
      assert {:ok, %{}} = Tyrex.eval("({})", pid: pid)
    end

    test "nested structures", %{pid: pid} do
      assert {:ok, %{"users" => [%{"name" => "Alice"}, %{"name" => "Bob"}]}} =
               Tyrex.eval("({users: [{name: 'Alice'}, {name: 'Bob'}]})", pid: pid)
    end

    test "template literals", %{pid: pid} do
      assert {:ok, "Value is 42"} = Tyrex.eval("`Value is ${40 + 2}`", pid: pid)
    end
  end

  describe "eval/2 - JavaScript features" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "destructuring", %{pid: pid} do
      assert {:ok, 3} = Tyrex.eval("const [a, b, c] = [1, 2, 3]; c", pid: pid)
    end

    test "spread operator", %{pid: pid} do
      assert {:ok, [1, 2, 3, 4, 5]} = Tyrex.eval("[...[1, 2], ...[3, 4, 5]]", pid: pid)
    end

    test "Map and Set", %{pid: pid} do
      assert {:ok, 3} = Tyrex.eval("new Map([['a',1],['b',2],['c',3]]).size", pid: pid)
      assert {:ok, 2} = Tyrex.eval("new Set([1,1,2,2]).size", pid: pid)
    end

    test "JSON operations", %{pid: pid} do
      assert {:ok, %{"x" => 1}} = Tyrex.eval("JSON.parse('{\"x\": 1}')", pid: pid)

      assert {:ok, "{\"x\":1}"} =
               Tyrex.eval("JSON.stringify({x: 1})", pid: pid)
    end

    test "Date operations", %{pid: pid} do
      assert {:ok, year} = Tyrex.eval("new Date().getFullYear()", pid: pid)
      assert is_integer(year)
      assert year >= 2024
    end

    test "RegExp", %{pid: pid} do
      assert {:ok, true} = Tyrex.eval("/hello/.test('hello world')", pid: pid)
      assert {:ok, "hello"} = Tyrex.eval("'hello world'.match(/hello/)[0]", pid: pid)
    end

    test "globalThis state persists across evals", %{pid: pid} do
      assert {:ok, 42} = Tyrex.eval("globalThis.myVar = 42", pid: pid)
      assert {:ok, 42} = Tyrex.eval("globalThis.myVar", pid: pid)
      assert {:ok, 43} = Tyrex.eval("globalThis.myVar + 1", pid: pid)
    end

    test "function definitions persist", %{pid: pid} do
      {:ok, _} =
        Tyrex.eval(
          "globalThis.double = (x) => x * 2",
          pid: pid
        )

      assert {:ok, 10} = Tyrex.eval("double(5)", pid: pid)
    end
  end

  describe "eval/2 - async/promises" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "resolved promise", %{pid: pid} do
      assert {:ok, 42} = Tyrex.eval("Promise.resolve(42)", pid: pid)
    end

    test "rejected promise", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval("Promise.reject('oops')", pid: pid)
    end

    test "async IIFE", %{pid: pid} do
      assert {:ok, 5} =
               Tyrex.eval("(async () => { return 2 + 3; })()", pid: pid)
    end

    test "setTimeout with promise", %{pid: pid} do
      code = """
      new Promise(resolve => setTimeout(() => resolve("delayed"), 50))
      """

      assert {:ok, "delayed"} = Tyrex.eval(code, pid: pid)
    end

    test "Promise.all", %{pid: pid} do
      code = "Promise.all([Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)])"
      assert {:ok, [1, 2, 3]} = Tyrex.eval(code, pid: pid)
    end

    test "Promise.race", %{pid: pid} do
      code = """
      Promise.race([
        new Promise(resolve => setTimeout(() => resolve("slow"), 100)),
        Promise.resolve("fast")
      ])
      """

      assert {:ok, "fast"} = Tyrex.eval(code, pid: pid)
    end
  end

  describe "eval/2 - Deno APIs" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "Deno.version", %{pid: pid} do
      assert {:ok, %{"deno" => _, "v8" => _}} = Tyrex.eval("Deno.version", pid: pid)
    end

    test "Deno.readTextFile", %{pid: pid} do
      assert {:ok, content} =
               Tyrex.eval(
                 "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
                 pid: pid
               )

      assert content =~ "test file for Deno.readTextFile"
    end

    test "Deno.env", %{pid: pid} do
      assert {:ok, home} = Tyrex.eval("Deno.env.get('HOME')", pid: pid)
      assert is_binary(home)
    end

    test "Deno.cwd", %{pid: pid} do
      assert {:ok, cwd} = Tyrex.eval("Deno.cwd()", pid: pid)
      assert is_binary(cwd)
    end
  end

  describe "eval/2 - blocking mode" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "blocking eval", %{pid: pid} do
      assert {:ok, 42} = Tyrex.eval("21 * 2", pid: pid, blocking: true)
    end

    test "blocking string eval", %{pid: pid} do
      assert {:ok, "hello"} = Tyrex.eval("'hello'", pid: pid, blocking: true)
    end

    test "blocking object eval", %{pid: pid} do
      assert {:ok, %{"x" => 1}} = Tyrex.eval("({x: 1})", pid: pid, blocking: true)
    end
  end

  describe "eval/2 - error handling" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "syntax error", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :execution_error}} =
               Tyrex.eval("const x = {", pid: pid)
    end

    test "reference error", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :execution_error}} =
               Tyrex.eval("nonExistentVariable", pid: pid)
    end

    test "type error", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :execution_error}} =
               Tyrex.eval("null.property", pid: pid)
    end

    test "throw string", %{pid: pid} do
      assert {:error, %Tyrex.Error{}} =
               Tyrex.eval("throw 'custom error'", pid: pid)
    end
  end

  describe "eval!/2" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "returns unwrapped value", %{pid: pid} do
      assert 42 = Tyrex.eval!("42", pid: pid)
    end

    test "raises on error", %{pid: pid} do
      assert_raise MatchError, fn ->
        Tyrex.eval!("throw 'error'", pid: pid)
      end
    end
  end

  describe "module loading" do
    test "main module with imports" do
      {:ok, pid} = Tyrex.start(main_module_path: "test/support/main_module.js")
      assert {:ok, 7} = Tyrex.eval("addNumbers(3, 4)", pid: pid)
      assert {:ok, 12} = Tyrex.eval("multiplyNumbers(3, 4)", pid: pid)
      Tyrex.stop(pid: pid)
    end

    test "chained imports" do
      {:ok, pid} =
        Tyrex.start(main_module_path: "test/support/import_b.js")

      # import_b imports from import_a
      assert {:ok, _} = Tyrex.eval("true", pid: pid)
      Tyrex.stop(pid: pid)
    end

    test "node APIs module" do
      {:ok, pid} = Tyrex.start(main_module_path: "test/support/node_apis.js")
      assert {:ok, path} = Tyrex.eval("testNodePath()", pid: pid)
      assert path =~ "baz.js"

      assert {:ok, "file.txt"} = Tyrex.eval("testNodeBasename()", pid: pid)

      assert {:ok, base64} = Tyrex.eval("testNodeBuffer()", pid: pid)
      assert Base.decode64!(base64) == "hello tyrex"

      Tyrex.stop(pid: pid)
    end

    test "syntax error in module returns error" do
      assert {:error, _} = Tyrex.start(main_module_path: "test/support/syntax_error.js")
    end
  end

  describe "bidirectional - Tyrex.apply (JS -> Elixir)" do
    setup do
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
    end

    test "call Enum.sum", %{pid: pid} do
      assert {:ok, 6} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|,
                 pid: pid
               )
    end

    test "call Enum.reverse", %{pid: pid} do
      assert {:ok, [3, 2, 1]} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("Enum", "reverse", [[1,2,3]]))()|,
                 pid: pid
               )
    end

    test "call String.upcase", %{pid: pid} do
      assert {:ok, "HELLO"} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("String", "upcase", ["hello"]))()|,
                 pid: pid
               )
    end

    test "call Kernel functions via erlang atom syntax", %{pid: pid} do
      assert {:ok, 3} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply(":erlang", "length", [[1,2,3]]))()|,
                 pid: pid
               )
    end

    test "non-existent module returns error", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("NonExistent", "foo", []))()|,
                 pid: pid
               )
    end

    test "non-existent function returns error", %{pid: pid} do
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("Enum", "nonexistent", [[]]))()|,
                 pid: pid
               )
    end
  end

  describe "multiple runtimes" do
    test "runtimes are isolated" do
      {:ok, pid1} = Tyrex.start()
      {:ok, pid2} = Tyrex.start()

      Tyrex.eval("globalThis.x = 'from_runtime_1'", pid: pid1)
      Tyrex.eval("globalThis.x = 'from_runtime_2'", pid: pid2)

      assert {:ok, "from_runtime_1"} = Tyrex.eval("globalThis.x", pid: pid1)
      assert {:ok, "from_runtime_2"} = Tyrex.eval("globalThis.x", pid: pid2)

      Tyrex.stop(pid: pid1)
      Tyrex.stop(pid: pid2)
    end

    test "stopping one runtime doesn't affect another" do
      {:ok, pid1} = Tyrex.start()
      {:ok, pid2} = Tyrex.start()

      Tyrex.stop(pid: pid1)
      assert {:ok, 42} = Tyrex.eval("42", pid: pid2)

      Tyrex.stop(pid: pid2)
    end
  end

  describe "concurrency" do
    test "concurrent evals on same runtime" do
      {:ok, pid} = Tyrex.start()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, result} = Tyrex.eval("#{i} * 2", pid: pid)
            result
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.sort(results) == Enum.map(1..10, &(&1 * 2))

      Tyrex.stop(pid: pid)
    end
  end
end
