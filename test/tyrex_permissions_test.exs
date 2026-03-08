defmodule TyrexPermissionsTest do
  use ExUnit.Case, async: false

  describe "permissions: :allow_all (default)" do
    test "can access network" do
      {:ok, pid} = Tyrex.start()
      {:ok, cwd} = Tyrex.eval("Deno.cwd()", pid: pid)
      assert is_binary(cwd)
      Tyrex.stop(pid: pid)
    end

    test "can read files" do
      {:ok, pid} = Tyrex.start()

      {:ok, content} =
        Tyrex.eval(
          "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
          pid: pid
        )

      assert content =~ "test file"
      Tyrex.stop(pid: pid)
    end

    test "can read env" do
      {:ok, pid} = Tyrex.start()
      {:ok, home} = Tyrex.eval("Deno.env.get('HOME')", pid: pid)
      assert is_binary(home)
      Tyrex.stop(pid: pid)
    end
  end

  describe "permissions: :none" do
    test "can still compute" do
      {:ok, pid} = Tyrex.start(permissions: :none)
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
      assert {:ok, "hello"} = Tyrex.eval("'hello'", pid: pid)
      Tyrex.stop(pid: pid)
    end

    test "cannot read files" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{}} =
               Tyrex.eval(
                 "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "cannot access env" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{}} =
               Tyrex.eval("Deno.env.get('HOME')", pid: pid)

      Tyrex.stop(pid: pid)
    end
  end

  describe "granular permissions" do
    test "allow_read only specific path" do
      {:ok, pid} = Tyrex.start(permissions: [allow_read: ["test/support"]])

      {:ok, content} =
        Tyrex.eval(
          "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
          pid: pid
        )

      assert content =~ "test file"
      Tyrex.stop(pid: pid)
    end

    test "allow_env only specific vars" do
      {:ok, pid} = Tyrex.start(permissions: [allow_env: ["HOME"]])
      {:ok, home} = Tyrex.eval("Deno.env.get('HOME')", pid: pid)
      assert is_binary(home)
      Tyrex.stop(pid: pid)
    end

    test "allow_read true allows all reads" do
      {:ok, pid} = Tyrex.start(permissions: [allow_read: true])

      {:ok, content} =
        Tyrex.eval(
          "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
          pid: pid
        )

      assert content =~ "test file"
      Tyrex.stop(pid: pid)
    end

    test "deny_net blocks network" do
      {:ok, pid} = Tyrex.start(permissions: [allow_all: true, deny_net: true])

      assert {:error, %Tyrex.Error{}} =
               Tyrex.eval(
                 "(async () => await fetch('https://example.com'))()",
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end
  end

  describe "pool with permissions" do
    test "pool passes permissions to all runtimes" do
      {:ok, _} =
        Tyrex.Pool.start_link(
          name: :perm_pool,
          size: 2,
          permissions: :none
        )

      # Can still compute
      assert {:ok, 42} = Tyrex.Pool.eval(:perm_pool, "42")

      # Cannot read env
      assert {:error, %Tyrex.Error{}} =
               Tyrex.Pool.eval(:perm_pool, "Deno.env.get('HOME')")

      Supervisor.stop(:"perm_pool.Supervisor")
    end
  end
end
