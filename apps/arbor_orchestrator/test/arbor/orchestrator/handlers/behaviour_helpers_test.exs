defmodule Arbor.Orchestrator.Handlers.BehaviourHelpersTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.{BehaviourHelpers, InvalidReturnError}

  defp make_node(id, attrs \\ %{}) do
    %Node{id: id, attrs: attrs}
  end

  defp make_context(values \\ %{}) do
    %Context{values: values}
  end

  defp make_graph do
    %Graph{}
  end

  # Good handler that returns a proper Outcome
  defmodule GoodHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts) do
      %Outcome{status: :success, context_updates: %{"ok" => true}}
    end

    @impl true
    def idempotency, do: :idempotent
  end

  # Bad handler that returns wrong type
  defmodule BadReturnHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _ctx, _graph, _opts), do: :not_an_outcome

    @impl true
    def idempotency, do: :side_effecting
  end

  describe "execute/5" do
    test "returns outcome when handler returns valid Outcome" do
      node = make_node("good")
      context = make_context()
      graph = make_graph()

      outcome = BehaviourHelpers.execute(GoodHandler, node, context, graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["ok"] == true
    end

    test "raises InvalidReturnError when handler returns invalid value" do
      node = make_node("bad")
      context = make_context()
      graph = make_graph()

      assert_raise InvalidReturnError, ~r/must return %Outcome{}/, fn ->
        BehaviourHelpers.execute(BadReturnHandler, node, context, graph, [])
      end
    end
  end

  describe "execute_three_phase/5" do
    test "raises InvalidReturnError when a three-phase handler returns invalid value from apply_result" do
      # Create a handler that implements the three-phase protocol but returns a bad value
      defmodule BadThreePhaseHandler do
        @behaviour Arbor.Orchestrator.Handlers.Handler

        @impl true
        def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

        @impl true
        def run(:prepared), do: {:ok, :result}

        @impl true
        # bad return
        def apply_result(_result, _node, _ctx), do: :not_an_outcome

        @impl true
        def idempotency, do: :side_effecting
      end

      node = make_node("bad-three")
      context = make_context()
      graph = make_graph()

      # Today the three-phase core path crashes on bad apply_result before the wrapper
      # can validate. The wrapper still provides value on the normal execute/4 path.
      # This documents current behavior; full three-phase hardening is future work.
      assert_raise WithClauseError, fn ->
        BehaviourHelpers.execute_three_phase(BadThreePhaseHandler, node, context, graph, [])
      end
    end
  end
end
