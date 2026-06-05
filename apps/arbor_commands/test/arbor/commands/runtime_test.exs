defmodule Arbor.Commands.RuntimeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Commands.Runtime
  alias Arbor.Contracts.Commands.{Context, Result}

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  # FakeSession responds to Arbor.Orchestrator.Session's set_runtime call
  # — used to verify the command's side-effect path end-to-end. Real
  # Session GenServer tests live alongside Session in arbor_orchestrator.
  defmodule FakeSession do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, %{})
    @impl true
    def init(_), do: {:ok, %{}}
    @impl true
    def handle_call({:set_runtime, r}, _, state),
      do: {:reply, {:ok, r}, Map.put(state, :runtime, r)}
  end

  defp start_fake_session, do: FakeSession.start_link()

  describe "available?/1" do
    test "requires an agent" do
      refute Runtime.available?(ctx())
      assert Runtime.available?(ctx(agent_id: "agent_test"))
    end
  end

  describe "execute/2 — display" do
    test "no args shows default runtime" do
      assert {:ok, %Result{text: text}} = Runtime.execute("", ctx(agent_id: "agent_test"))
      assert String.contains?(text, "arbor") and String.contains?(text, "default")
    end

    test "shows runtime when context has one" do
      context = ctx(agent_id: "agent_test") |> Map.put(:runtime, :acp)
      assert {:ok, %Result{text: text}} = Runtime.execute("", context)
      assert String.contains?(text, "acp")
    end
  end

  describe "execute/2 — switching" do
    test "switch to acp emits runtime_changed effect" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{text: text, effects: effects, type: :info}} =
               Runtime.execute("acp", ctx(agent_id: "agent_test", session_pid: session))

      assert Keyword.get(effects, :runtime_changed) == :acp
      assert String.contains?(text, "acp")
    end

    test "switch to arbor emits runtime_changed effect" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects}} =
               Runtime.execute("arbor", ctx(agent_id: "agent_test", session_pid: session))

      assert Keyword.get(effects, :runtime_changed) == :arbor
    end

    test "case-insensitive parse" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects}} =
               Runtime.execute("ACP", ctx(agent_id: "agent_test", session_pid: session))

      assert Keyword.get(effects, :runtime_changed) == :acp
    end

    test "unknown runtime errors with valid options" do
      assert {:ok, %Result{text: text, type: :error}} =
               Runtime.execute("garbage", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "arbor") and String.contains?(text, "acp")
    end

    test "switch without agent context errors" do
      assert {:ok, %Result{text: text, type: :error}} = Runtime.execute("acp", ctx())
      assert String.contains?(text, "Cannot") or String.contains?(text, "no current agent")
    end

    test "missing session_pid errors" do
      assert {:ok, %Result{text: text, type: :error}} =
               Runtime.execute("acp", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "session pid")
    end

    test "dead session_pid surfaces error" do
      pid = spawn(fn -> :ok end)
      Process.sleep(20)
      refute Process.alive?(pid)

      assert {:ok, %Result{text: text, type: :error}} =
               Runtime.execute("acp", ctx(agent_id: "agent_test", session_pid: pid))

      assert String.contains?(text, "no longer alive")
    end
  end
end
