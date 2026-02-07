defmodule Arbor.Actions.MemoryReviewTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.MemoryReview

  @moduletag :fast

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_memory)

    for table <- [:arbor_memory_graphs, :arbor_working_memory, :arbor_memory_proposals] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ]

    for child <- children do
      Supervisor.start_child(Arbor.Memory.Supervisor, child)
    end

    :ok
  end

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)

    on_exit(fn ->
      Arbor.Memory.cleanup_for_agent(agent_id)
    end)

    {:ok, agent_id: agent_id, context: %{agent_id: agent_id}}
  end

  # ============================================================================
  # ReviewQueue
  # ============================================================================

  describe "ReviewQueue" do
    test "lists empty queue", %{context: ctx} do
      assert {:ok, result} =
               MemoryReview.ReviewQueue.run(%{}, ctx)

      assert result.action == :list
      assert result.proposals == []
      assert result.count == 0
    end

    test "lists proposals after creating one", %{agent_id: agent_id, context: ctx} do
      {:ok, _proposal} =
        Arbor.Memory.create_proposal(agent_id, :fact, %{
          content: "Test fact",
          confidence: 0.8
        })

      assert {:ok, result} =
               MemoryReview.ReviewQueue.run(%{action: "list"}, ctx)

      assert result.count >= 1
    end

    test "filters by type", %{agent_id: agent_id, context: ctx} do
      {:ok, _} =
        Arbor.Memory.create_proposal(agent_id, :fact, %{content: "A fact", confidence: 0.8})

      {:ok, _} =
        Arbor.Memory.create_proposal(agent_id, :learning, %{
          content: "A learning",
          confidence: 0.7
        })

      assert {:ok, result} =
               MemoryReview.ReviewQueue.run(%{action: "list", type: "fact"}, ctx)

      assert Enum.all?(result.proposals, &(&1.type == :fact))
    end

    test "approves a proposal", %{agent_id: agent_id, context: ctx} do
      {:ok, proposal} =
        Arbor.Memory.create_proposal(agent_id, :fact, %{content: "Approved fact", confidence: 0.9})

      assert {:ok, result} =
               MemoryReview.ReviewQueue.run(
                 %{action: "approve", item_id: proposal.id},
                 ctx
               )

      assert result.approved == true
    end

    test "rejects a proposal", %{agent_id: agent_id, context: ctx} do
      {:ok, proposal} =
        Arbor.Memory.create_proposal(agent_id, :fact, %{
          content: "Rejected fact",
          confidence: 0.3
        })

      assert {:ok, result} =
               MemoryReview.ReviewQueue.run(
                 %{action: "reject", item_id: proposal.id},
                 ctx
               )

      assert result.rejected == true
    end

    test "approve requires item_id", %{context: ctx} do
      assert {:error, :item_id_required} =
               MemoryReview.ReviewQueue.run(%{action: "approve"}, ctx)
    end

    test "reject requires item_id", %{context: ctx} do
      assert {:error, :item_id_required} =
               MemoryReview.ReviewQueue.run(%{action: "reject"}, ctx)
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryReview.ReviewQueue.run(%{}, %{})
    end

    test "validates action metadata" do
      assert MemoryReview.ReviewQueue.name() == "memory_review_queue"
      assert MemoryReview.ReviewQueue.category() == "memory_review"
      assert "review" in MemoryReview.ReviewQueue.tags()
    end

    test "has taint roles" do
      roles = MemoryReview.ReviewQueue.taint_roles()
      assert roles[:action] == :control
      assert roles[:item_id] == :data
    end
  end

  # ============================================================================
  # ReviewSuggestions
  # ============================================================================

  describe "ReviewSuggestions" do
    test "lists suggestions (empty)", %{context: ctx} do
      assert {:ok, result} =
               MemoryReview.ReviewSuggestions.run(%{}, ctx)

      assert is_list(result.suggestions)
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryReview.ReviewSuggestions.run(%{}, %{})
    end

    test "validates action metadata" do
      assert MemoryReview.ReviewSuggestions.name() == "memory_review_suggestions"
      assert "suggestions" in MemoryReview.ReviewSuggestions.tags()
    end

    test "generates tool schema" do
      tool = MemoryReview.ReviewSuggestions.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_review_suggestions"
    end
  end

  # ============================================================================
  # AcceptSuggestion
  # ============================================================================

  describe "AcceptSuggestion" do
    test "accepts a proposal", %{agent_id: agent_id, context: ctx} do
      {:ok, proposal} =
        Arbor.Memory.create_proposal(agent_id, :insight, %{
          content: "Pattern detected",
          confidence: 0.7
        })

      assert {:ok, result} =
               MemoryReview.AcceptSuggestion.run(
                 %{suggestion_id: proposal.id},
                 ctx
               )

      assert result.accepted == true
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryReview.AcceptSuggestion.run(
                 %{suggestion_id: "some_id"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert MemoryReview.AcceptSuggestion.name() == "memory_accept_suggestion"
      assert "accept" in MemoryReview.AcceptSuggestion.tags()
    end
  end

  # ============================================================================
  # RejectSuggestion
  # ============================================================================

  describe "RejectSuggestion" do
    test "rejects a proposal", %{agent_id: agent_id, context: ctx} do
      {:ok, proposal} =
        Arbor.Memory.create_proposal(agent_id, :insight, %{
          content: "Bad pattern",
          confidence: 0.3
        })

      assert {:ok, result} =
               MemoryReview.RejectSuggestion.run(
                 %{suggestion_id: proposal.id},
                 ctx
               )

      assert result.rejected == true
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryReview.RejectSuggestion.run(
                 %{suggestion_id: "some_id"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert MemoryReview.RejectSuggestion.name() == "memory_reject_suggestion"
      assert "reject" in MemoryReview.RejectSuggestion.tags()
    end
  end
end
