defmodule Arbor.Commands.ModelTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Commands.Model
  alias Arbor.Contracts.Commands.{Context, Result}

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  defmodule FakeSession do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, %{})
    @impl true
    def init(_), do: {:ok, %{}}
    @impl true
    def handle_call({:set_model, m}, _, state),
      do: {:reply, {:ok, m}, Map.put(state, :model, m)}

    def handle_call({:set_runtime, r}, _, state),
      do: {:reply, {:ok, r}, Map.put(state, :runtime, r)}
  end

  defp start_fake_session, do: FakeSession.start_link()

  describe "execute/2 — display" do
    test "shows current model from context" do
      context = ctx(model: "anthropic/claude-sonnet-4", provider: "anthropic")
      assert {:ok, %Result{text: text}} = Model.execute("", context)
      assert String.contains?(text, "anthropic/claude-sonnet-4")
    end

    test "no model set" do
      assert {:ok, %Result{text: text}} = Model.execute("", ctx())
      assert String.contains?(text, "not set") or String.contains?(text, "No model")
    end

    test "list points at the registry" do
      assert {:ok, %Result{text: text}} = Model.execute("list", ctx())
      assert String.contains?(text, "registry") or String.contains?(text, "backend")
    end
  end

  describe "execute/2 — switching (live FakeSession)" do
    test "switch model emits model_changed effect" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects, type: :info}} =
               Model.execute("gpt-4o", ctx(agent_id: "agent_test", session_pid: session))

      assert Keyword.get(effects, :model_changed) == "gpt-4o"
    end

    test "switch model + runtime emits both effects" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects}} =
               Model.execute(
                 "claude-opus-4-6 runtime=acp",
                 ctx(agent_id: "agent_test", session_pid: session)
               )

      assert Keyword.get(effects, :model_changed) == "claude-opus-4-6"
      assert Keyword.get(effects, :runtime_changed) == :acp
    end

    test "switch model with runtime=arbor (explicit default)" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects}} =
               Model.execute(
                 "claude-opus-4-6 runtime=arbor",
                 ctx(agent_id: "agent_test", session_pid: session)
               )

      assert Keyword.get(effects, :runtime_changed) == :arbor
    end

    test "unrelated kwargs silently skip" do
      {:ok, session} = start_fake_session()

      assert {:ok, %Result{effects: effects}} =
               Model.execute(
                 "claude-opus-4-6 future_arg=42 runtime=acp",
                 ctx(agent_id: "agent_test", session_pid: session)
               )

      assert Keyword.get(effects, :model_changed) == "claude-opus-4-6"
      assert Keyword.get(effects, :runtime_changed) == :acp
    end
  end

  describe "execute/2 — error paths" do
    test "switch without agent errors" do
      assert {:ok, %Result{text: text}} = Model.execute("gpt-4o", ctx())
      assert String.contains?(text, "no current agent") or String.contains?(text, "Cannot")
    end

    test "runtime= with no model points at /runtime" do
      assert {:ok, %Result{text: text, type: :error}} =
               Model.execute("runtime=acp", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "/runtime")
    end

    test "unknown runtime value errors with valid options" do
      assert {:ok, %Result{text: text, type: :error}} =
               Model.execute("claude-opus-4-6 runtime=garbage", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "Unknown runtime")
    end

    test "missing session_pid errors" do
      assert {:ok, %Result{text: text, type: :error}} =
               Model.execute("gpt-4o", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "session pid")
    end
  end
end
