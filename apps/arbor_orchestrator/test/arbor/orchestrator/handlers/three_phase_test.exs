defmodule Arbor.Orchestrator.Handlers.ThreePhaseTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Handler

  # A mock three-phase handler that succeeds
  defmodule SuccessHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts), do: %Outcome{status: :success}

    @impl true
    def idempotency, do: :idempotent

    @impl true
    def prepare(node, _ctx, _opts) do
      {:ok, %{node_id: node.id, prepared: true}}
    end

    @impl true
    def run(%{node_id: node_id, prepared: true}) do
      {:ok, %{node_id: node_id, result: "computed"}}
    end

    @impl true
    def apply_result(%{node_id: node_id, result: result}, _node, _ctx) do
      {:ok,
       %Outcome{
         status: :success,
         context_updates: %{"last_response" => result},
         notes: "three-phase: #{node_id}"
       }}
    end
  end

  # A handler that fails in prepare phase
  defmodule PrepareFailHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts), do: %Outcome{status: :success}

    @impl true
    def prepare(_node, _ctx, _opts), do: {:error, "invalid inputs"}

    @impl true
    def run(_prepared), do: {:ok, :should_not_reach}

    @impl true
    def apply_result(_result, _node, _ctx), do: {:ok, %Outcome{status: :success}}
  end

  # A handler that fails in run phase
  defmodule RunFailHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts), do: %Outcome{status: :success}

    @impl true
    def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

    @impl true
    def run(_prepared), do: {:error, :execution_failed}

    @impl true
    def apply_result(_result, _node, _ctx), do: {:ok, %Outcome{status: :success}}
  end

  # A handler that fails in apply_result phase
  defmodule ApplyFailHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts), do: %Outcome{status: :success}

    @impl true
    def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

    @impl true
    def run(_prepared), do: {:ok, :result}

    @impl true
    def apply_result(_result, _node, _ctx), do: {:error, "cannot apply result"}
  end

  # A standard handler (no three-phase)
  defmodule StandardHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts) do
      %Outcome{status: :success, notes: "standard"}
    end
  end

  defp make_node(id) do
    Node.from_attrs(id, %{"shape" => "box", "type" => "test"})
  end

  describe "three_phase?/1" do
    test "returns true for handler with all three callbacks" do
      assert Handler.three_phase?(SuccessHandler)
    end

    test "returns false for standard handler" do
      refute Handler.three_phase?(StandardHandler)
    end

    test "returns true for partial-fail handlers (they implement all 3)" do
      assert Handler.three_phase?(PrepareFailHandler)
      assert Handler.three_phase?(RunFailHandler)
      assert Handler.three_phase?(ApplyFailHandler)
    end
  end

  describe "execute_three_phase/5" do
    test "success path returns outcome with context updates" do
      node = make_node("test_node")
      context = Context.new()
      graph = %Graph{}

      outcome = Handler.execute_three_phase(SuccessHandler, node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates == %{"last_response" => "computed"}
      assert outcome.notes == "three-phase: test_node"
    end

    test "prepare failure returns fail outcome" do
      node = make_node("test")
      context = Context.new()
      graph = %Graph{}

      outcome = Handler.execute_three_phase(PrepareFailHandler, node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason == "invalid inputs"
    end

    test "run failure returns fail outcome" do
      node = make_node("test")
      context = Context.new()
      graph = %Graph{}

      outcome = Handler.execute_three_phase(RunFailHandler, node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason == ":execution_failed"
    end

    test "apply_result failure returns fail outcome" do
      node = make_node("test")
      context = Context.new()
      graph = %Graph{}

      outcome = Handler.execute_three_phase(ApplyFailHandler, node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason == "cannot apply result"
    end
  end

  describe "idempotency_of/1" do
    test "returns declared idempotency" do
      assert Handler.idempotency_of(SuccessHandler) == :idempotent
    end

    test "defaults to :side_effecting" do
      assert Handler.idempotency_of(StandardHandler) == :side_effecting
    end
  end
end
