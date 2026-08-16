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
      unique = System.unique_integer([:positive])
      dir = Path.join(System.tmp_dir!(), "tyrex_import_#{unique}")
      # A sibling directory that no test grants, so it is not merely unlisted but
      # outside every granted prefix.
      forbidden = Path.join(System.tmp_dir!(), "tyrex_forbidden_#{unique}")
      File.mkdir_p!(dir)
      File.mkdir_p!(forbidden)
      File.write!(Path.join(dir, "secret.js"), ~s|export default "SECRET-FROM-DISK";\n|)
      File.write!(Path.join(dir, "secret.json"), ~s|{"secret": "json-secret"}\n|)
      File.write!(Path.join(forbidden, "outside.js"), ~s|export default "OUTSIDE-THE-GRANT";\n|)

      # A one-line trampoline: readable, but its static import graph reaches out
      # of the granted directory.
      File.write!(
        Path.join(dir, "trampoline.js"),
        ~s|import outside from "file://#{Path.join(forbidden, "outside.js")}";\nexport default outside;\n|
      )

      on_exit(fn ->
        File.rm_rf!(dir)
        File.rm_rf!(forbidden)
      end)

      %{dir: dir, forbidden: forbidden}
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

    test "a dynamically imported file cannot statically import outside the grant", %{
      dir: dir,
      forbidden: forbidden
    } do
      # The property `PermissionedModuleLoader`'s main-module exemption rests on:
      # deno propagates `is_dynamic_import` from a `RecursiveModuleLoad` into
      # every transitive `load`, so the loader's hooks fire for the whole graph of
      # a guest `import()`, not just its top-level specifier. Narrow the check to
      # the entry specifier — a plausible "simplification" of the double
      # resolve/load check, which already reads as redundant — and a guest holding
      # `allow_read` on one directory regains arbitrary file read by dropping a
      # trampoline module into it. Every other import test here imports a leaf,
      # so none of them would notice.
      {:ok, pid} = Tyrex.start(permissions: [allow_read: [dir]])

      # The entry module itself is readable, so the denial below is about its
      # dependency and not about the grant failing.
      assert {:ok, "SECRET-FROM-DISK"} =
               Tyrex.eval(
                 ~s|(async () => (await import(#{Jason.encode!("file://" <> Path.join(dir, "secret.js"))})).default)()|,
                 pid: pid,
                 timeout: 15_000
               )

      assert {:ok, message} =
               import_message(pid, "file://" <> Path.join(dir, "trampoline.js"))

      assert message =~ "Requires read access"
      assert message =~ Path.join(forbidden, "outside.js")
      refute message =~ "NOT DENIED"

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

    # `Deno.core` is `undefined` in EVERY runtime — deno_runtime builds `denoNs`
    # without a `core` key and exposes the whole of core at
    # `Deno[Deno.internal].core` instead. The previous version of this test
    # asserted `typeof Deno?.core?.ops?.op_apply == "undefined"`, which
    # short-circuits at the first hop and is therefore satisfied by every op
    # name, including ops that demonstrably exist: `op_read_all` and
    # `op_base64_encode` both answer `"undefined"` through that chain. It would
    # have stayed green with `op_apply` fully exposed. These two tests assert
    # against the namespace deno actually populates.
    test "op_apply is absent from the real op table with the bridge disabled" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # The scenario the old test's title claimed but never built: bridge off,
      # so the global really is gone.
      assert {:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)

      # Positive control, and it is load-bearing. Every assertion below is an
      # `"undefined"`/absence claim about a property of
      # `Deno[Deno.internal].core.ops`; if that accessor ever moves again — a
      # renamed `Deno.internal`, core relocated — the expressions would throw or
      # answer vacuously and the test would stop measuring anything, which is
      # exactly the failure being fixed here. So first prove the table is
      # reachable and populated.
      assert {:ok, "object"} = Tyrex.eval("typeof Deno[Deno.internal].core.ops", pid: pid)

      assert {:ok, "function"} =
               Tyrex.eval("typeof Deno[Deno.internal].core.ops.op_base64_encode", pid: pid)

      # The claim itself.
      assert {:ok, "undefined"} =
               Tyrex.eval("typeof Deno[Deno.internal].core.ops.op_apply", pid: pid)

      assert {:ok, []} =
               Tyrex.eval(
                 ~s|Object.keys(Deno[Deno.internal].core.ops).filter(k => k.startsWith("op_apply"))|,
                 pid: pid
               )

      assert_op_table_pinned(pid)

      Tyrex.stop(pid: pid)
    end

    # The bridge being installed must not put its op on the guest-visible table
    # either. This is the runtime where `op_apply` genuinely exists, so it is the
    # interesting half of the pair.
    test "op_apply is absent from the real op table with the bridge enabled too" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      assert {:ok, "object"} = Tyrex.eval("typeof Deno[Deno.internal].core.ops", pid: pid)

      assert {:ok, "function"} =
               Tyrex.eval("typeof Deno[Deno.internal].core.ops.op_base64_encode", pid: pid)

      assert {:ok, "undefined"} =
               Tyrex.eval("typeof Deno[Deno.internal].core.ops.op_apply", pid: pid)

      # The bridge is installed, so this is not "the extension never loaded".
      assert {:ok, "function"} = Tyrex.eval("typeof Tyrex.apply", pid: pid)

      assert_op_table_pinned(pid)

      Tyrex.stop(pid: pid)
    end

    test "ext: modules are unimportable, so the bridge module cannot be re-acquired" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      # ext: modules are structurally unimportable from user code. Only the
      # name is pinned here: `import()` always returns a promise, so the refusal
      # can only arrive as a rejection, but whether deno_core's resolver or the
      # import permission check refuses first is an internal detail, and either
      # way the payload is an `Error` that does not survive into `:value` (see
      # `import_message/2`).
      assert {:error, %Tyrex.Error{name: :promise_rejection}} =
               Tyrex.eval(~s|(async () => await import("ext:extension/main.js"))()|, pid: pid)

      Tyrex.stop(pid: pid)
    end

    # Not an apply-bridge escape, but the same shape of hole and the reason this
    # block exists: a capability the guest reaches that no permission governs.
    #
    # `WorkerOptions::default()` supplies
    # `create_web_worker_cb = |_| unimplemented!("web workers are not
    # supported")`, and `op_create_worker` checks no permission on the specifier.
    # So before the fix, `new Worker(url, {type: "module"})` under
    # `permissions: :none` reached that `unimplemented!()` on a spawned thread,
    # dropped the handle sender, and made the worker thread's
    # `handle_receiver.recv().unwrap()` panic inside a V8 `extern "C"` callback —
    # `panic_cannot_unwind`, SIGABRT, whole node gone (reproduced: exit 134). No
    # `catch_unwind` could contain it, so the constructor is deleted at bootstrap.
    #
    # If this ever regresses, the test does not fail: it takes the whole test VM
    # with it. That is the strongest possible signal and there is no gentler one
    # available, because the failure mode is `abort()`.
    test "the Worker constructor is gone, so guest JS cannot abort the node" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:ok, "undefined"} = Tyrex.eval("typeof Worker", pid: pid)
      assert {:ok, false} = Tyrex.eval(~s|"Worker" in globalThis|, pid: pid)

      # And constructing one is now an ordinary JS error the guest can catch,
      # rather than an abort. The runtime must still be serving afterwards.
      assert {:ok, message} =
               Tyrex.eval(
                 ~s|(() => { try { new Worker("file:///tmp/x.js", {type: "module"}); return "CONSTRUCTED"; } catch (e) { return String(e && e.name ? e.name : e); } })()|,
                 pid: pid
               )

      refute message == "CONSTRUCTED"
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)

      Tyrex.stop(pid: pid)
    end

    # The bridge being on must not put `Worker` back.
    test "the Worker constructor is gone with the apply bridge enabled too" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      assert {:ok, "undefined"} = Tyrex.eval("typeof Worker", pid: pid)
      assert {:ok, "object"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)

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

    # Blocker B5 of the v0.4.0 audit, which shipped fixed but untested:
    # `op_apply` used to take the runtime id as a JS argument, and a bootstrap
    # script published it as `Tyrex._runtimeId` on the guest-writable bridge
    # object. The id selects *which runtime's GenServer* is asked to authorize
    # the call, so a guest that overwrote it had its `:apply` calls judged
    # against a sibling runtime's allowlist — a cross-runtime confused deputy in
    # four lines of JavaScript. The id now lives in per-runtime `OpState` and
    # `main.js` passes exactly four arguments, none of them an id.
    test "the runtime id is not exposed to the guest" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      assert {:ok, "undefined"} = Tyrex.eval("typeof Tyrex._runtimeId", pid: pid)
      assert {:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex._runtimeId", pid: pid)

      # The bridge itself is present, so the two assertions above are about the
      # id being absent rather than about `Tyrex` being absent.
      assert {:ok, ["_applications", "_applyReply", "apply"]} =
               Tyrex.eval("Object.keys(globalThis.Tyrex).sort()", pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "a guest cannot redirect its apply calls to a sibling runtime's allowlist" do
      # Disjoint allowlists, so any authorization that answers for the wrong
      # runtime is directly observable: `String.upcase/1` is legal on B and on
      # nothing else, `Enum.sum/1` is legal on A and on nothing else.
      {:ok, a} = Tyrex.start(apply: [{Enum, :sum, 1}])
      {:ok, b} = Tyrex.start(apply: [{String, :upcase, 1}])

      # The write lands — the bridge object is an ordinary extensible object, so
      # the guest really can set this. What it cannot do is make it mean
      # anything. If the assignment threw instead, the refusal below would prove
      # nothing.
      assert {:ok, "1"} =
               Tyrex.eval(
                 ~s|(() => { Tyrex._runtimeId = "1"; globalThis.Tyrex._runtimeId = "1"; return String(Tyrex._runtimeId); })()|,
                 pid: a
               )

      # Every id a guest might guess, including B's. The refusal must name
      # `String.upcase/1`: that is A's allowlist answering, not a generic
      # failure.
      for id <- ["0", "1", "2", "3", 0, 1, 2, 3, nil] do
        assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} =
                 Tyrex.eval(
                   """
                   (async () => {
                     Tyrex._runtimeId = #{Jason.encode!(id)};
                     globalThis.Tyrex._runtimeId = #{Jason.encode!(id)};
                     return await Tyrex.apply("String", "upcase", ["x"]);
                   })()
                   """,
                   pid: a
                 )

        assert value =~ "permission_denied",
               "id #{inspect(id)} was not refused: #{inspect(value)}"

        assert value =~ "String.upcase/1"
      end

      # And B never saw the call: its own allowlisted function is untouched.
      assert {:ok, "X"} =
               Tyrex.eval(~s|(async () => await Tyrex.apply("String", "upcase", ["x"]))()|,
                 pid: b
               )

      # A is still serving its own allowlist, so the loop above did not pass by
      # the bridge being broken on A.
      assert {:ok, 6} =
               Tyrex.eval(~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|, pid: a)

      Tyrex.stop(pid: a)
      Tyrex.stop(pid: b)
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

    test "allow_all given a list", %{main: main} do
      # `allow_all` is a baseline switch, not a list of paths. It used to be read
      # through `matches!(perm, PermValue::True)`, so `allow_all: ["/tmp"]`
      # silently became `allow_all: false` — fail-closed, so never a hole, but
      # the one shape this parser reinterpreted instead of refusing. Revert that
      # exhaustive `match` in `build_permissions` and the runtime starts happily
      # with a baseline the operator did not ask for.
      :ok = Tyrex.Native.start_runtime(self(), main, ~s({"allow_all": ["/tmp"]}), false, nil)
      assert_receive {:error, %Tyrex.Error{message: message}}, 30_000
      assert message =~ "allow_all must be true or false, not a list"
      assert message =~ "baseline"
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

  # The op table deno exposes to guest JS, in full. Pinned deliberately: nothing
  # in tyrex keeps `op_apply` (or any other registered op) off this table —
  # `deno_core` installs every registered op on `core.ops` unconditionally
  # (`deno_core-0.391.0/src/runtime/bindings.rs`), and what empties it again is
  # deno's own `removeImportedOps()`, which keeps a hardcoded `NOT_IMPORTED_OPS`
  # allowlist and deletes every other key
  # (`deno_runtime-0.246.0/js/99_main.js:500-556, 968`). The three names below are
  # that allowlist intersected with what this build registers — deno's list, not
  # tyrex's. So this is an upstream invariant tyrex neither states nor controls,
  # and a deno bump that shortened the deletion would be silent without this
  # assertion. It would expose `op_apply` (still allowlist-checked in Elixir, so
  # not an escalation on its own) and, worse, `op_import_sync`, which drives a
  # `LoadInit::Side` load — the one load shape `PermissionedModuleLoader` does not
  # check, i.e. an unchecked read of any file the BEAM user can read.
  defp assert_op_table_pinned(pid) do
    assert {:ok, ["op_base64_encode", "op_napi_open", "op_set_exit_code"]} =
             Tyrex.eval("Object.keys(Deno[Deno.internal].core.ops).sort()", pid: pid)
  end
end
