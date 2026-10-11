defmodule Arbor.Sandbox.CodeDynamicDispatchSecurityRegressionTest do
  @moduledoc """
  Security regression tests for F-007 (2026-10-11 cross-library review):
  `Arbor.Sandbox.Code.validate/2` was not a barrier.

  - Erlang atom modules other than `:os` were never gated by level, so
    `:file`, `:code`, `:rpc`, `:erpc`, `:init`, `:timer.apply_after` ... passed
    even at `:pure`.
  - Only remote calls with a literal receiver were inspected: a variable
    receiver (`m = System; m.cmd(...)`), `import System` + bare `cmd(...)`,
    `apply/2`, `&m.f/arity` and `alias System, as: Enum` all passed.
  - The `Kernel.apply/3` clause was dead (the generic remote-call clause
    matched first and `Kernel` is always allowed).
  - An atom receiver spelled `:"Elixir.File"` was routed to the Erlang path
    and bypassed the Elixir module allowlist.
  - Dynamic code loading (`Code.string_to_quoted` + `Module.create`) was
    allowed at `:limited`.

  Every "refuses" case here passed validation before the fix.
  """

  use ExUnit.Case, async: true

  alias Arbor.Sandbox.Code, as: Sandbox

  @moduletag :fast

  # Same entry point HotLoad uses: parse real source text, not `quote`.
  defp validate(source, level) do
    Sandbox.validate(Code.string_to_quoted!(source), level)
  end

  defp assert_refused(source, level) do
    assert {:error, {:code_violations, violations}} = validate(source, level),
           "expected #{inspect(level)} to refuse: #{source}"

    assert violations != []
    violations
  end

  @escapes [
    {"variable receiver", ~S|m = System; m.cmd("id", [])|},
    {"variable receiver, zero-arity with parens", ~S|m = System; m.get_env()|},
    {"module attribute receiver", ~S|@m System; @m.cmd("id", [])|},
    {"nested field receiver", ~S|state.mod.cmd("id", [])|},
    {"import + bare call", ~S|import System; cmd("id", [])|},
    {"import with only:", ~S|import System, only: [cmd: 2]; cmd("id", [])|},
    {"Kernel.apply/3 literal module", ~S|Kernel.apply(System, :cmd, ["id", []])|},
    {"Elixir.Kernel.apply/3", ~S|Elixir.Kernel.apply(System, :cmd, ["id", []])|},
    {"apply/3 literal module", ~S|apply(System, :cmd, ["id", []])|},
    {"apply/3 nested through Kernel", ~S|apply(Kernel, :apply, [System, :cmd, ["id", []]])|},
    {"apply/2", ~S|apply(fun, ["id", []])|},
    {"Kernel.apply/2", ~S|Kernel.apply(fun, ["id", []])|},
    {"capture of dynamic receiver", ~S|f = &m.cmd/2; f.("id", [])|},
    {"Function.capture", ~S|Function.capture(System, :cmd, 2)|},
    {":erlang.make_fun", ~S|:erlang.make_fun(System, :cmd, 2)|},
    {"shadowing alias", ~S|alias System, as: Enum; Enum.cmd("id", [])|},
    {":erpc.call", ~S|:erpc.call(:n, :os, :cmd, [~c"id"])|},
    {":rpc.block_call", ~S|:rpc.block_call(:n, :os, :cmd, [])|},
    {":rpc.multicall", ~S|:rpc.multicall(:os, :cmd, [~c"id"])|},
    {":file.write_file", ~S|:file.write_file("/tmp/x", "y")|},
    {":code.load_binary", ~S|:code.load_binary(X, ~c"x", <<>>)|},
    {":init.stop", ~S|:init.stop()|},
    {":timer.apply_after", ~S|:timer.apply_after(0, :os, :cmd, [~c"id"])|},
    {":ets.delete", ~S|:ets.delete(:some_table)|},
    {":persistent_term.put", ~S|:persistent_term.put(:k, :v)|},
    {":application.set_env", ~S|:application.set_env(:arbor_security, :x, false)|},
    {":net_kernel.connect_node", ~S|:net_kernel.connect_node(:evil@host)|},
    {":compile.forms", ~S|:compile.forms([])|},
    {":erlang.spawn_opt", ~S|:erlang.spawn_opt(fn -> 1 end, [])|},
    {":erlang.port_command", ~S|:erlang.port_command(port, "id")|},
    {":erlang.load_nif", ~S|:erlang.load_nif(~c"x", 0)|},
    {":erlang.system_flag", ~S|:erlang.system_flag(:x, 1)|},
    {"atom-spelled Elixir module", ~S|:"Elixir.Code".ensure_loaded(X)|},
    {"Module.create", ~S|Module.create(X, quote(do: 1), [])|},
    {"string_to_quoted + Module.create",
     ~S'Code.string_to_quoted("1") |> elem(1) |> then(&Module.create(X, &1, []))'},
    {"Code.ensure_loaded", ~S|Code.ensure_loaded(X)|},
    {"Code.compile_file", ~S|Code.compile_file("/tmp/x.ex")|},
    {"spawn with anonymous function", ~S|spawn(fn -> :os.cmd(~c"id") end)|},
    {"no-parens halt on dynamic receiver", ~S|m = :init; m.stop|}
  ]

  for level <- [:pure, :limited, :hot_load] do
    describe "security regression: dynamic dispatch and Erlang escapes at #{level}" do
      for {name, source} <- @escapes do
        test "refuses #{name}" do
          assert_refused(unquote(source), unquote(level))
        end
      end
    end
  end

  describe "security regression: :pure allowlist is still usable" do
    test "allows Enum.map" do
      assert :ok = validate(~S|Enum.map([1], & &1)|, :pure)
    end

    test "allows :lists.map" do
      assert :ok = validate(~S|:lists.map(& &1, [1])|, :pure)
    end

    test "allows pure Erlang stdlib modules" do
      assert :ok = validate(~S|:maps.get(:a, %{a: 1})|, :pure)
      assert :ok = validate(~S|:binary.split("a,b", ",")|, :pure)
      assert :ok = validate(~S|:math.pow(2, 3)|, :pure)
      assert :ok = validate(~S|:erlang.phash2({1, 2})|, :pure)
      assert :ok = validate(~S|:crypto.hash(:sha256, "x")|, :pure)
      assert :ok = validate(~S|:timer.sleep(1)|, :pure)
    end

    test "allows map field access on a dynamic receiver" do
      assert :ok = validate(~S|state.count + state.config.limit|, :pure)
    end

    test "allows __MODULE__ self-calls and anonymous fun invocation" do
      assert :ok = validate(~S|__MODULE__.helper(1)|, :pure)
      assert :ok = validate(~S|f = fn x -> x end; f.(1)|, :pure)
    end

    test "allows import/alias of pure modules" do
      assert :ok = validate(~S|import Bitwise; 1 &&& 2|, :pure)
      assert :ok = validate(~S|import :lists; map(& &1, [1])|, :pure)
      assert :ok = validate(~S|alias Enum; Enum.map([1], & &1)|, :pure)
    end

    test "refuses an atom-spelled Elixir module that is not in the :pure allowlist" do
      # Pre-fix an atom receiver was routed to the Erlang path, which never
      # consulted the Elixir allowlist.
      assert_refused(~S|:"Elixir.File".read("/etc/passwd")|, :pure)
    end
  end

  describe "security regression: :limited keeps its documented semantics" do
    test "allows System.cmd, File and Port at :limited" do
      # Pinned by code_test.exs: :limited is the level that permits these.
      assert :ok = validate(~S|System.cmd("echo", ["hello"])|, :limited)
      assert :ok = validate(~S|File.read("/tmp/safe.txt")|, :limited)
      assert :ok = validate(~S|Port.open({:spawn, "ls"}, [])|, :limited)
    end

    test "allows a typical GenServer module at :limited" do
      source = ~S"""
      defmodule Sample.Server do
        use GenServer
        require Logger

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        @impl true
        def init(opts), do: {:ok, Map.new(opts)}

        @impl true
        def handle_info(:tick, state) do
          Logger.info("tick #{state.count}")
          Process.send_after(self(), :tick, 1_000)
          {:noreply, %{state | count: state.count + 1}}
        end
      end
      """

      assert :ok = validate(source, :limited)
      assert :ok = validate(source, :hot_load)
    end

    test "import of a function-restricted module is refused even when the module is allowed" do
      assert_refused(~S|import File; read("/etc/passwd")|, :limited)
      assert_refused(~S|import Code; ensure_loaded(X)|, :limited)
    end
  end

  describe "security regression: :hot_load denies OS exec, code loading and cluster escape" do
    test "denies what :limited allows for process/code/cluster escape" do
      for source <- [
            ~S|System.cmd("id", [])|,
            ~S|System.shell("id")|,
            ~S|System.halt()|,
            ~S|System.at_exit(fn _ -> :ok end)|,
            ~S|System.trap_signal(:sigterm, fn -> :ok end)|,
            ~S|Port.open({:spawn, "id"}, [])|,
            ~S|Port.command(port, "x")|,
            ~S|Node.list()|,
            ~S|Node.connect(:evil@host)|,
            ~S|Code.ensure_loaded?(X)|,
            ~S|Code.string_to_quoted("1")|,
            ~S|Module.create(X, quote(do: 1), [])|,
            ~S|use Node|,
            ~S|require Code|
          ] do
        assert_refused(source, :hot_load)
      end
    end

    test "still allows the :limited surface that legitimate hot-loads need" do
      assert :ok = validate(~S|File.read("/tmp/x")|, :hot_load)
      assert :ok = validate(~S|Logger.info("x")|, :hot_load)
      assert :ok = validate(~S|GenServer.call(pid, :x)|, :hot_load)
      assert :ok = validate(~S|Task.async(fn -> 1 end)|, :hot_load)
      assert :ok = validate(~S|Application.get_env(:arbor, :x)|, :hot_load)
    end

    test "allowed_modules/1 and restricted_functions/1 expose the :hot_load posture" do
      modules = Sandbox.allowed_modules(:hot_load)
      assert GenServer in modules
      assert Logger in modules
      assert File in modules
      refute Port in modules
      refute Node in modules
      refute Elixir.Code in modules

      restricted = Sandbox.restricted_functions(:hot_load)
      assert {System, :cmd} in restricted
      assert {System, :shell} in restricted
      assert {Module, :create} in restricted
      assert {Elixir.Code, :eval_string} in restricted
    end
  end

  describe "non-restrictive levels keep historical behaviour" do
    test ":full still allows dynamic dispatch and Erlang modules" do
      assert :ok = validate(~S|m = System; m.cmd("id", [])|, :full)
      assert :ok = validate(~S|:file.write_file("/tmp/x", "y")|, :full)
      assert :ok = validate(~S|apply(fun, [1])|, :full)
    end

    test ":full still refuses never-allowed modules and functions" do
      assert_refused(~S|:os.cmd(~c"id")|, :full)
      assert_refused(~S|apply(:os, :cmd, [~c"id"])|, :full)
      assert_refused(~S|Kernel.apply(Code, :eval_string, ["1"])|, :full)
      assert_refused(~S|import :os|, :full)
    end
  end
end
