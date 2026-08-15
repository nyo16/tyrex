defmodule TyrexPermissionsTest do
  use ExUnit.Case, async: false

  describe "permissions: :allow_all" do
    test "can access network" do
      {:ok, pid} = Tyrex.start(permissions: :allow_all)
      {:ok, cwd} = Tyrex.eval("Deno.cwd()", pid: pid)
      assert is_binary(cwd)
      Tyrex.stop(pid: pid)
    end

    test "can read files" do
      {:ok, pid} = Tyrex.start(permissions: :allow_all)

      {:ok, content} =
        Tyrex.eval(
          "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
          pid: pid
        )

      assert content =~ "test file"
      Tyrex.stop(pid: pid)
    end

    test "can read env" do
      {:ok, pid} = Tyrex.start(permissions: :allow_all)
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

      # Pinned to :promise_rejection: the async IIFE turns the synchronous
      # NotCapable throw into a rejected promise, so the bare struct match this
      # replaces also accepted :timeout and the :dead_runtime_error of a runtime
      # that died before it evaluated anything. The payload is not asserted
      # because a thrown `Error` does not survive into `:value` — see the note
      # on `import_message/2` at the bottom of this file. `allow_read only
      # specific path` below is the positive control for the same read.
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 "(async () => await Deno.readTextFile('test/support/read_file.txt'))()",
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "cannot access env" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # `Deno.env.get` is synchronous, so the NotCapable throw comes straight
      # back out of execute_script as :execution_error with the text intact.
      # The bare struct match this replaces also accepted a runtime that never
      # got as far as evaluating anything.
      assert {:error, %Tyrex.Error{name: :execution_error, message: message}} =
               Tyrex.eval("Deno.env.get('HOME')", pid: pid)

      assert message =~ "NotCapable"
      assert message =~ "--allow-env"

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

      # The denial is re-thrown as a string because a thrown `Error` does not
      # survive into `:value` — see the note on `import_message/2` at the bottom
      # of this file. Unlike that helper this re-throws rather than returning,
      # because the error tuple is half of what this test asserts. The text is
      # load-bearing here: on an offline runner `fetch` rejects for reasons that
      # have nothing to do with permissions, and :promise_rejection alone
      # accepts that.
      assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} =
               Tyrex.eval(
                 """
                 (async () => {
                   try {
                     await fetch('https://example.com');
                   } catch (e) {
                     throw String(e && e.message ? e.message : e);
                   }
                 })()
                 """,
                 pid: pid
               )

      assert value =~ "Requires net access"
      assert value =~ "--allow-net"

      Tyrex.stop(pid: pid)
    end
  end

  # Before v0.4.0's fix these were the sandbox's loudest lie. `FsModuleLoader`
  # received no PermissionsContainer and ended in a bare `std::fs::read`, so
  # `import()` read any file the BEAM user could read under any permission set:
  # `permissions: :none` denied `Deno.readTextFileSync` while
  # `import("file:///etc/passwd", {with: {type: "json"}})` returned the parsed
  # contents, and `deny_import` was inert.
  #
  # The previous version of this test used an `https:` specifier, which
  # `FsModuleLoader` rejected as "not a file URL" regardless of permissions, and
  # asserted only `err.name in [:promise_rejection, :execution_error]`. It passed
  # against a completely unguarded loader.
  #
  # Deno surfaces a rejected dynamic import as an `Error` whose `code` is
  # `ERR_MODULE_NOT_FOUND`; `message` is not an own enumerable property, so it
  # does not survive serialization to `Tyrex.Error.value`. These tests therefore
  # read the message inside the isolate, which is also the only way to tell a
  # permission denial apart from a genuinely missing file.
  describe "dynamic import() respects permissions" do
    setup do
      dir = Path.join(System.tmp_dir!(), "tyrex_import_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "secret.js"), ~s|export default "SECRET-FROM-DISK";\n|)
      File.write!(Path.join(dir, "secret.json"), ~s|{"secret": "json-secret"}\n|)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a file: import is denied under permissions: :none", %{dir: dir} do
      specifier = "file://" <> Path.join(dir, "secret.js")
      {:ok, pid} = Tyrex.start(permissions: :none)

      # The import must reject, not resolve.
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => (await import(#{Jason.encode!(specifier)})).default)()|,
                 pid: pid,
                 timeout: 15_000
               )

      # ...and it must reject *because of the read permission*, not because the
      # loader could not make sense of the specifier.
      assert {:ok, message} = import_message(pid, specifier)
      assert message =~ "Requires read access"
      assert message =~ "secret.js"

      Tyrex.stop(pid: pid)
    end

    test "a JSON import is denied under permissions: :none", %{dir: dir} do
      # `type: "json"` is the probe the original audit should have used. Note
      # that `type: "text"` is NOT a valid module type: it throws for an
      # unrelated reason and makes the bypass look closed.
      specifier = "file://" <> Path.join(dir, "secret.json")
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => (await import(#{Jason.encode!(specifier)}, {with: {type: "json"}})).default)()|,
                 pid: pid,
                 timeout: 15_000
               )

      Tyrex.stop(pid: pid)
    end

    test "the same file imports fine once read is granted", %{dir: dir} do
      specifier = "file://" <> Path.join(dir, "secret.js")
      {:ok, pid} = Tyrex.start(permissions: [allow_read: [dir]])

      assert {:ok, "SECRET-FROM-DISK"} =
               Tyrex.eval(
                 ~s|(async () => (await import(#{Jason.encode!(specifier)})).default)()|,
                 pid: pid,
                 timeout: 15_000
               )

      Tyrex.stop(pid: pid)
    end

    test "the main module and its static imports still load under permissions: :none" do
      # The exemption 1.1 depends on. The main module is operator-supplied and
      # loaded once at bootstrap; a naive read check on every load would break
      # `main_module_path` under `:none`, which is the documented way to give a
      # locked-down runtime its code.
      dir = Path.join(System.tmp_dir!(), "tyrex_main_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "dep.js"), "export const N = 41;\n")

      File.write!(
        Path.join(dir, "main.js"),
        ~s|import {N} from "./dep.js";\nglobalThis.FROM_MAIN = N + 1;\n|
      )

      {:ok, pid} =
        Tyrex.start(permissions: :none, main_module_path: Path.join(dir, "main.js"))

      assert {:ok, 42} = Tyrex.eval("globalThis.FROM_MAIN", pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "the exemption is not a general read primitive", %{dir: dir} do
      # A guest cannot widen the main-module exemption to a file the operator
      # never imported: the main module's specifier is fixed at `worker::new`
      # and a guest cannot choose it, and every dynamic load is checked.
      main = Path.join(dir, "empty_main.js")
      File.write!(main, "\n")
      {:ok, pid} = Tyrex.start(permissions: :none, main_module_path: main)

      assert {:ok, message} = import_message(pid, "file://" <> main)
      assert message =~ "Requires read access"

      Tyrex.stop(pid: pid)
    end

    test "deny_import blocks a non-file: dynamic import" do
      # Non-`file:` specifiers are governed by allow_import/deny_import rather
      # than by read permissions. Deno checks the import permission before any
      # network call, so this never leaves the machine.
      {:ok, pid} = Tyrex.start(permissions: [allow_all: true, deny_import: true])

      assert {:ok, message} =
               import_message(pid, "https://deno.land/std@0.224.0/uuid/mod.ts")

      assert message =~ "Requires import access"
      assert message =~ "deno.land"

      Tyrex.stop(pid: pid)
    end
  end

  # Each of these reproduces a vector from the v0.4.0 security audit. They are
  # written as escapes that must fail, not as features that must work.
  describe "the apply bridge is a privileged capability" do
    test "is not installed by default" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "permissions: :none no longer leaks Elixir through the bridge" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # Deno's own I/O is denied, as it always was. `readTextFileSync` throws
      # synchronously, so the denial comes back out of execute_script as
      # :execution_error with its text intact — and the text is what separates
      # a real denial from a runtime that never started.
      assert {:error, %Tyrex.Error{name: :execution_error, message: message}} =
               Tyrex.eval("Deno.readTextFileSync('mix.exs')", pid: pid)

      assert message =~ "NotCapable"
      assert message =~ "--allow-read"

      # ...and so are the two routes that used to walk straight around it.
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("File", "read!", ["mix.exs"]))()|,
                 pid: pid
               )

      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply(":os", "cmd", [[105, 100]]))()|,
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "the underlying op is not reachable even with the global deleted" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      # Deno.core is not exposed, so the op cannot be re-acquired directly.
      assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", pid: pid)

      # And ext: modules are structurally unimportable from user code. Only the
      # name is pinned here: `import()` always returns a promise, so the refusal
      # can only arrive as a rejection, but whether deno_core's resolver or the
      # import permission check refuses first is an internal detail, and either
      # way the payload is an `Error` that does not survive into `:value` (see
      # `import_message/2`).
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(~s|(async () => await import("ext:extension/main.js"))()|, pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "an allowlisted MFA is permitted" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      assert {:ok, 6} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|,
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "a non-allowlisted MFA is rejected as permission_denied" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("File", "read!", ["mix.exs"]))()|,
                 pid: pid
               )

      assert value =~ "permission_denied"

      Tyrex.stop(pid: pid)
    end

    test "the allowlist is keyed by arity, not just name" do
      {:ok, pid} = Tyrex.start(apply: [{String, :upcase, 1}])

      assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("String", "upcase", ["hello", ":ascii"]))()|,
                 pid: pid
               )

      assert value =~ "permission_denied"

      Tyrex.stop(pid: pid)
    end

    test "an allowlisted function that raises rejects the promise instead of killing the runtime" do
      {:ok, pid} = Tyrex.start(apply: [{String, :upcase, 1}])

      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("String", "upcase", [123]))()|,
                 pid: pid
               )

      # The runtime is still serving.
      assert {:ok, "HI"} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("String", "upcase", ["hi"]))()|,
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "an unexported MFA is refused at start rather than at first call" do
      assert_raise ArgumentError, ~r/is not exported/, fn ->
        Tyrex.start(apply: [{Enum, :definitely_not_a_function, 1}])
      end
    end

    test "there is no apply: true" do
      assert_raise ArgumentError, ~r/deliberately no\n`apply: true`/, fn ->
        Tyrex.start(apply: true)
      end
    end
  end

  describe "permissions fail closed" do
    test "an explicit allow_x: false denies even under allow_all: true" do
      {:ok, pid} = Tyrex.start(permissions: [allow_all: true, allow_run: false])

      # Synchronous throw, so the name is :execution_error. `--allow-run` is the
      # proof that the run permission refused, rather than `echo` failing to
      # spawn or the runtime having died.
      assert {:error, %Tyrex.Error{name: :execution_error, message: message}} =
               Tyrex.eval(
                 ~s|new Deno.Command("echo", {args: ["hi"]}).outputSync()|,
                 pid: pid
               )

      assert message =~ "NotCapable"
      assert message =~ "--allow-run"

      Tyrex.stop(pid: pid)
    end

    test "allow_read: [] grants no paths rather than the whole filesystem" do
      {:ok, pid} = Tyrex.start(permissions: [allow_read: []])

      # `--allow-read` in the message is the whole point: an empty list must
      # refuse the read, not fail for some unrelated reason.
      assert {:error, %Tyrex.Error{name: :execution_error, message: message}} =
               Tyrex.eval("Deno.readTextFileSync('mix.exs')", pid: pid)

      assert message =~ "NotCapable"
      assert message =~ "--allow-read"

      Tyrex.stop(pid: pid)
    end

    test "an unknown permission key raises instead of being silently dropped" do
      assert_raise ArgumentError, ~r/unknown permission key/, fn ->
        Tyrex.start(permissions: [deny_nett: true])
      end
    end

    test "a non-string entry in a permission list raises" do
      assert_raise ArgumentError, ~r/must be strings/, fn ->
        Tyrex.start(permissions: [allow_read: [123]])
      end
    end
  end

  # These bypass the Elixir-side validation on purpose: they are the last
  # line of defence in the Rust parser, which used to answer every one of
  # them with PermissionsContainer::allow_all.
  describe "the native parser refuses malformed input" do
    setup do
      %{main: "#{Application.app_dir(:tyrex)}/priv/main.js"}
    end

    test "invalid JSON", %{main: main} do
      :ok = Tyrex.Native.start_runtime(self(), main, "not json at all", false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "not valid JSON"
    end

    test "unexpected top-level shape", %{main: main} do
      :ok = Tyrex.Native.start_runtime(self(), main, "[1,2,3]", false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "must be an object"
    end

    test "unknown preset string", %{main: main} do
      :ok = Tyrex.Native.start_runtime(self(), main, ~s("allow_everything"), false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "unknown permissions preset"
    end

    test "unknown key", %{main: main} do
      :ok = Tyrex.Native.start_runtime(self(), main, ~s({"allow_nett": true}), false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "unknown permission key"
    end

    test "non-string list entry", %{main: main} do
      :ok = Tyrex.Native.start_runtime(self(), main, ~s({"allow_read": [1]}), false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "must be a string"
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

      # Cannot read env. Pinned to the synchronous NotCapable path so that a
      # pool whose runtimes died — which now answers :dead_runtime_error — can
      # no longer pass for a pool that forwarded the permissions.
      assert {:error, %Tyrex.Error{name: :execution_error, message: message}} =
               Tyrex.Pool.eval(:perm_pool, "Deno.env.get('HOME')")

      assert message =~ "NotCapable"
      assert message =~ "--allow-env"

      Supervisor.stop(:"perm_pool.Supervisor")
    end
  end

  # Reads the rejection message from inside the isolate. Deno's dynamic-import
  # rejection is an `Error` whose `message` is not an own enumerable property,
  # so it does not survive serialization into `Tyrex.Error.value` — and the
  # message is the only thing that distinguishes a permission denial from a
  # missing file.
  defp import_message(pid, specifier) do
    code = """
    (async () => {
      try {
        await import(#{Jason.encode!(specifier)});
        return "NOT DENIED";
      } catch (e) {
        return String(e && e.message ? e.message : e);
      }
    })()
    """

    Tyrex.eval(code, pid: pid, timeout: 15_000)
  end
end
