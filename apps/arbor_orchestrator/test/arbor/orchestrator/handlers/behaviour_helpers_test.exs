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
    test "runs prepare -> run -> apply_result and returns the Outcome" do
      defmodule GoodThreePhaseHandler do
        @behaviour Arbor.Orchestrator.Handlers.Handler

        @impl true
        def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

        @impl true
        def run(:prepared), do: {:ok, :ran}

        @impl true
        def apply_result(:ran, _node, _ctx),
          do: {:ok, %Outcome{status: :success, context_updates: %{"three_phase" => true}}}

        @impl true
        def idempotency, do: :idempotent
      end

      outcome =
        BehaviourHelpers.execute_three_phase(
          GoodThreePhaseHandler,
          make_node("good-three"),
          make_context(),
          make_graph(),
          []
        )

      assert outcome.status == :success
      assert outcome.context_updates["three_phase"] == true
    end

    test "a phase returning {:error, reason} yields a fail Outcome with that reason" do
      defmodule ErrorThreePhaseHandler do
        @behaviour Arbor.Orchestrator.Handlers.Handler

        @impl true
        def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

        @impl true
        def run(:prepared), do: {:error, "boom in run"}

        @impl true
        def apply_result(_result, _node, _ctx), do: {:ok, %Outcome{status: :success}}

        @impl true
        def idempotency, do: :side_effecting
      end

      outcome =
        BehaviourHelpers.execute_three_phase(
          ErrorThreePhaseHandler,
          make_node("err-three"),
          make_context(),
          make_graph(),
          []
        )

      assert outcome.status == :fail
      assert outcome.failure_reason == "boom in run"
    end

    test "a malformed callback return is hardened into a fail Outcome instead of crashing" do
      # Regression guard: this exact handler used to raise WithClauseError because the
      # `with` else only matched {:error, reason}. Three-phase hardening converts the
      # contract violation into a clean fail Outcome whose reason names the bad return.
      defmodule BadThreePhaseHandler do
        @behaviour Arbor.Orchestrator.Handlers.Handler

        @impl true
        def prepare(_node, _ctx, _opts), do: {:ok, :prepared}

        @impl true
        def run(:prepared), do: {:ok, :result}

        @impl true
        # contract violation: neither {:ok, _} nor {:error, _}
        def apply_result(_result, _node, _ctx), do: :not_an_outcome

        @impl true
        def idempotency, do: :side_effecting
      end

      outcome =
        BehaviourHelpers.execute_three_phase(
          BadThreePhaseHandler,
          make_node("bad-three"),
          make_context(),
          make_graph(),
          []
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "invalid value"
      assert outcome.failure_reason =~ "BadThreePhaseHandler"
    end
  end
end
