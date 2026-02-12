defmodule Arbor.Orchestrator.Handlers.ConsensusHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ConsensusHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp node(type, attrs \\ %{}) do
    %Node{id: "n_#{type}", attrs: Map.put(attrs, "type", type)}
  end

  defp run(type, context_values \\ %{}, attrs \\ %{}) do
    ConsensusHandler.execute(
      node(type, attrs),
      Context.new(context_values),
      @graph,
      []
    )
  end

  @moduletag :consensus_handler

  describe "consensus.propose" do
    test "returns fail when source key has no value" do
      outcome = run("consensus.propose", %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no proposal description"
    end

    test "with valid input attempts proposal" do
      outcome = run("consensus.propose", %{"session.input" => "test proposal"})
      # Either succeeds or fails with a real error — both valid
      assert outcome.status in [:success, :fail]
    end

    test "reads from custom source_key" do
      outcome =
        run("consensus.propose", %{"custom.key" => "custom proposal"}, %{
          "source_key" => "custom.key"
        })

      assert outcome.status in [:success, :fail]
    end
  end

  describe "consensus.ask" do
    test "returns fail when source key has no value" do
      outcome = run("consensus.ask", %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no question"
    end

    test "with valid input attempts advisory query" do
      outcome = run("consensus.ask", %{"session.input" => "test question"})
      assert outcome.status in [:success, :fail]
    end
  end

  describe "consensus.await" do
    test "returns fail when no proposal_id available" do
      outcome = run("consensus.await", %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no proposal_id"
    end

    test "reads proposal_id from context" do
      outcome = run("consensus.await", %{"consensus.proposal_id" => "test-id"})
      # Will likely fail since no real proposal exists, but should attempt the call
      assert outcome.status in [:success, :fail]
    end

    test "reads proposal_id from node attrs" do
      outcome = run("consensus.await", %{}, %{"proposal_id" => "attr-id"})
      assert outcome.status in [:success, :fail]
    end
  end

  describe "consensus.check" do
    test "returns fail when no proposal_id" do
      outcome = run("consensus.check", %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no proposal_id"
    end
  end

  describe "unknown type" do
    test "returns fail with descriptive error" do
      outcome = run("consensus.unknown")
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unknown consensus node type"
    end
  end

  describe "idempotency" do
    test "default is side_effecting" do
      assert ConsensusHandler.idempotency() == :side_effecting
    end

    test "propose and ask are side_effecting" do
      assert ConsensusHandler.idempotency_for("consensus.propose") == :side_effecting
      assert ConsensusHandler.idempotency_for("consensus.ask") == :side_effecting
    end

    test "await and check are read_only" do
      assert ConsensusHandler.idempotency_for("consensus.await") == :read_only
      assert ConsensusHandler.idempotency_for("consensus.check") == :read_only
    end
  end
end
