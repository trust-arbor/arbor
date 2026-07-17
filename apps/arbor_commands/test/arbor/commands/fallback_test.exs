defmodule Arbor.Commands.FallbackTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Commands.Fallback
  alias Arbor.Contracts.Commands.{Context, Result}

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  # FakeSession answers the Session.set_fallback_chain / get_fallback_chain
  # protocol so the command's side-effect path is exercised without
  # spinning up a real Session GenServer.
  defmodule FakeSession do
    use GenServer
    def start_link(initial \\ []), do: GenServer.start_link(__MODULE__, initial)

    @impl true
    def init(initial), do: {:ok, %{chain: initial}}

    @impl true
    def handle_call({:set_fallback_chain, chain}, _, state),
      do: {:reply, {:ok, chain}, %{state | chain: chain}}

    @impl true
    def handle_call(:get_fallback_chain, _, %{chain: chain} = state),
      do: {:reply, {:ok, chain}, state}
  end

  defp start_fake_session(initial \\ []) do
    {:ok, pid} = FakeSession.start_link(initial)
    pid
  end

  describe "available?/1" do
    test "requires an agent" do
      refute Fallback.available?(ctx())
      assert Fallback.available?(ctx(agent_id: "agent_test"))
    end
  end

  describe "execute/2 — show / no-args" do
    test "no args → shows empty chain" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text}} =
               Fallback.execute("", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "empty"
    end

    test "show subcommand → renders current chain" do
      chain = [%{runtime: :acp}, %{model: "claude-sonnet-4-6"}]
      pid = start_fake_session(chain)

      assert {:ok, %Result{text: text}} =
               Fallback.execute("show", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "2 entries"
      assert text =~ "runtime: :acp"
      assert text =~ "claude-sonnet-4-6"
    end
  end

  describe "execute/2 — clear" do
    test "clears non-empty chain" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text, effects: effects}} =
               Fallback.execute("clear", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "cleared"
      assert Keyword.get(effects, :fallback_chain_changed) == []
    end
  end

  describe "execute/2 — set" do
    test "single entry" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, effects: effects}} =
               Fallback.execute(
                 "set runtime=acp",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "1 entries"
      assert Keyword.fetch!(effects, :fallback_chain_changed) == [%{runtime: :acp}]
    end

    test "multiple entries separated by ;" do
      pid = start_fake_session([])

      assert {:ok, %Result{effects: effects}} =
               Fallback.execute(
                 "set runtime=acp ; model=claude-sonnet-4-6 ; provider=anthropic",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert Keyword.fetch!(effects, :fallback_chain_changed) == [
               %{runtime: :acp},
               %{model: "claude-sonnet-4-6"},
               %{provider: :anthropic}
             ]
    end

    test "mixed fields in same entry" do
      pid = start_fake_session([])

      assert {:ok, %Result{effects: effects}} =
               Fallback.execute(
                 "set provider=anthropic,model=claude-haiku-4-5-20251001",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert Keyword.fetch!(effects, :fallback_chain_changed) == [
               %{provider: :anthropic, model: "claude-haiku-4-5-20251001"}
             ]
    end

    test "no entries → error" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("set", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "unknown subcommand"
    end

    test "unknown atom in runtime value rejects entry (no new atoms)" do
      pid = start_fake_session([])

      # 'mystery_atom_xyzzy_that_doesnt_exist' isn't an existing atom →
      # fail closed without creating a new atom or applying a partial entry.
      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set runtime=mystery_atom_xyzzy_that_doesnt_exist",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "invalid runtime value"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
    end

    test "mixed valid+invalid fields reject without applying chain change" do
      initial = [%{model: "keep-me"}]
      pid = start_fake_session(initial)

      # Valid provider + unknown runtime atom must not partially apply provider alone.
      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set provider=openai,runtime=mystery_atom_xyzzy_that_doesnt_exist",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "invalid runtime value"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "unknown key in multi-field entry rejects without applying" do
      initial = [%{runtime: :acp}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set provider=openai,bogus=value",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "unknown field"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "malformed pair rejects the whole entry" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set provider=openai,not-a-pair",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "malformed pair"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
    end

    test "duplicate fields reject as ambiguous" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set provider=openai,provider=anthropic",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "duplicate field"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
    end

    test "empty field value rejects the entry" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set model=,provider=openai",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "empty value"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
    end

    test "invalid second entry aborts set without applying first entry" do
      initial = [%{model: "keep-me"}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set runtime=acp ; model=good,unknown_key=x",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "unknown field"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "doubled commas reject without applying chain change" do
      initial = [%{model: "keep-me"}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set model=x,,provider=openai",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "malformed pair"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "leading comma rejects without applying chain change" do
      initial = [%{runtime: :acp}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set ,model=x",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "malformed pair"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "trailing comma rejects without applying chain change" do
      initial = [%{provider: :openai}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "set model=x,",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "malformed pair"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end
  end

  describe "execute/2 — add" do
    test "appends to existing chain" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text, effects: effects}} =
               Fallback.execute(
                 "add model=claude-sonnet-4-6",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "Added"

      assert Keyword.fetch!(effects, :fallback_chain_changed) == [
               %{runtime: :acp},
               %{model: "claude-sonnet-4-6"}
             ]
    end

    test "mixed valid+invalid fields reject without appending" do
      initial = [%{runtime: :acp}]
      pid = start_fake_session(initial)

      assert {:ok, %Result{text: text, type: :error, effects: effects}} =
               Fallback.execute(
                 "add provider=openai,runtime=mystery_atom_xyzzy_that_doesnt_exist",
                 ctx(agent_id: "x", session_pid: pid)
               )

      assert text =~ "invalid runtime value"
      refute Keyword.has_key?(effects, :fallback_chain_changed)
      assert {:ok, ^initial} = GenServer.call(pid, :get_fallback_chain)
    end

    test "empty add → error" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("add", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "unknown subcommand"
    end
  end

  describe "execute/2 — remove" do
    test "removes by index" do
      pid = start_fake_session([%{runtime: :acp}, %{model: "x"}, %{provider: :openai}])

      assert {:ok, %Result{text: text, effects: effects}} =
               Fallback.execute("remove 1", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "index 1"

      assert Keyword.fetch!(effects, :fallback_chain_changed) == [
               %{runtime: :acp},
               %{provider: :openai}
             ]
    end

    test "out-of-range → error" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("remove 5", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "out of range"
    end

    test "non-integer → error" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("remove foo", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "non-negative integer"
    end

    test "negative index → error" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("remove -1", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "non-negative integer"
    end
  end

  describe "execute/2 — error cases" do
    test "unknown subcommand → error" do
      pid = start_fake_session([])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("nonsense", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "unknown subcommand"
    end

    test "session pid missing → error" do
      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("show", ctx(agent_id: "x"))

      assert text =~ "session pid missing"
    end

    test "dead session pid → error" do
      pid = start_fake_session([])
      GenServer.stop(pid)
      # Give the process time to actually die
      Process.sleep(10)

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("show", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "no longer alive"
    end
  end

  describe "execute/2 — preview" do
    test "no current model → error" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text, type: :error}} =
               Fallback.execute("preview", ctx(agent_id: "x", session_pid: pid))

      assert text =~ "needs a current model"
    end

    test "with current model → renders enumerate_chain output" do
      pid = start_fake_session([%{runtime: :acp}])

      assert {:ok, %Result{text: text}} =
               Fallback.execute(
                 "preview",
                 ctx(agent_id: "x", session_pid: pid, model: "claude-opus-4-6")
               )

      assert text =~ "Selection preview"
      assert text =~ "claude-opus-4-6"
      assert text =~ "primary"
      assert text =~ "runtime: :acp"
    end
  end
end
