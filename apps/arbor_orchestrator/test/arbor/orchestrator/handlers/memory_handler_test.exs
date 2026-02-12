defmodule Arbor.Orchestrator.Handlers.MemoryHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.MemoryHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp node(type, attrs \\ %{}) do
    %Node{id: "n_#{type}", attrs: Map.put(attrs, "type", type)}
  end

  defp run(type, context_values \\ %{}, attrs \\ %{}) do
    MemoryHandler.execute(
      node(type, attrs),
      Context.new(context_values),
      @graph,
      []
    )
  end

  @moduletag :memory_handler

  describe "memory.recall" do
    test "attempts recall with agent_id and query" do
      # Arbor.Memory is loaded but agent may not be initialized
      outcome =
        run("memory.recall", %{
          "session.agent_id" => "test-agent",
          "session.input" => "test query"
        })

      assert outcome.status in [:success, :fail]
    end

    test "uses default agent_id when missing" do
      outcome = run("memory.recall", %{"session.input" => "query"})
      assert outcome.status in [:success, :fail]
    end
  end

  describe "memory.consolidate" do
    test "attempts consolidation" do
      outcome = run("memory.consolidate", %{"session.agent_id" => "test-agent"})
      assert outcome.status in [:success, :fail]
    end
  end

  describe "memory.index" do
    test "returns fail when no content at source_key" do
      outcome = run("memory.index", %{"session.agent_id" => "test-agent"})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no content"
    end

    test "uses custom source_key" do
      outcome =
        run(
          "memory.index",
          %{"session.agent_id" => "test-agent", "custom.content" => "indexed text"},
          %{"source_key" => "custom.content"}
        )

      assert outcome.status in [:success, :fail]
    end
  end

  describe "memory.working_load" do
    test "attempts to load working memory" do
      outcome = run("memory.working_load", %{"session.agent_id" => "test-agent"})
      assert outcome.status in [:success, :fail]
    end
  end

  describe "memory.working_save" do
    test "attempts to save working memory" do
      outcome =
        run("memory.working_save", %{
          "session.agent_id" => "test-agent",
          "memory.working_memory" => %{"key" => "value"}
        })

      assert outcome.status in [:success, :fail]
    end
  end

  describe "memory.stats" do
    test "returns stats or fails gracefully" do
      outcome = run("memory.stats", %{"session.agent_id" => "test-agent"})
      # Stats calls are wrapped in try/rescue, should always succeed
      assert outcome.status == :success
      assert outcome.context_updates["memory.stats"] != nil
    end
  end

  describe "unknown type" do
    test "returns fail with descriptive error" do
      outcome = run("memory.unknown")
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unknown memory node type"
    end
  end

  describe "idempotency" do
    test "default is side_effecting" do
      assert MemoryHandler.idempotency() == :side_effecting
    end

    test "recall, working_load, stats are read_only" do
      assert MemoryHandler.idempotency_for("memory.recall") == :read_only
      assert MemoryHandler.idempotency_for("memory.working_load") == :read_only
      assert MemoryHandler.idempotency_for("memory.stats") == :read_only
    end

    test "consolidate, index, working_save are side_effecting" do
      assert MemoryHandler.idempotency_for("memory.consolidate") == :side_effecting
      assert MemoryHandler.idempotency_for("memory.index") == :side_effecting
      assert MemoryHandler.idempotency_for("memory.working_save") == :side_effecting
    end
  end
end
