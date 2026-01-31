defmodule Arbor.ConsensusTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus
  alias Arbor.Consensus.TestHelpers

  @moduletag :integration

  setup do
    {_es_pid, es_name} = TestHelpers.start_test_event_store()
    {_pid, coord} = TestHelpers.start_test_coordinator()
    %{coordinator: coord, event_store: es_name}
  end

  describe "facade API" do
    test "submit/2 delegates to coordinator", %{coordinator: coord} do
      {:ok, id} =
        Consensus.submit(
          %{proposer: "agent_1", change_type: :code_modification, description: "test"},
          server: coord
        )

      assert is_binary(id)
    end

    test "get_status/2 delegates to coordinator", %{coordinator: coord} do
      {:ok, id} =
        Consensus.submit(
          %{proposer: "agent_1", change_type: :code_modification, description: "test"},
          server: coord
        )

      {:ok, status} = Consensus.get_status(id, coord)
      assert status in [:evaluating, :approved, :rejected, :deadlock]
    end

    test "get_decision/2 returns decision after evaluation", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Consensus.submit(proposal, server: coord)

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)

      {:ok, decision} = Consensus.get_decision(id, coord)
      assert decision.proposal_id == id
    end

    test "get_proposal/2 retrieves proposal", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Consensus.submit(proposal, server: coord)

      {:ok, retrieved} = Consensus.get_proposal(id, coord)
      assert retrieved.id == id
    end

    test "list_proposals/1 lists all proposals", %{coordinator: coord} do
      Consensus.submit(
        %{proposer: "a1", change_type: :code_modification, description: "p1"},
        server: coord
      )

      Consensus.submit(
        %{proposer: "a2", change_type: :test_change, description: "p2"},
        server: coord
      )

      proposals = Consensus.list_proposals(coord)
      assert length(proposals) == 2
    end

    test "cancel/2 vetoes a proposal" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Consensus.submit(
          %{proposer: "a1", change_type: :code_modification, description: "cancel me"},
          server: coord
        )

      :ok = Consensus.cancel(id, coord)
      {:ok, status} = Consensus.get_status(id, coord)
      assert status == :vetoed
    end

    test "force_approve/3 overrides decision" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Consensus.submit(
          %{proposer: "a1", change_type: :code_modification, description: "force me"},
          server: coord
        )

      :ok = Consensus.force_approve(id, "admin", coord)
      {:ok, status} = Consensus.get_status(id, coord)
      assert status == :approved
    end

    test "force_reject/3 overrides decision" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Consensus.submit(
          %{proposer: "a1", change_type: :code_modification, description: "reject me"},
          server: coord
        )

      :ok = Consensus.force_reject(id, "admin", coord)
      {:ok, status} = Consensus.get_status(id, coord)
      assert status == :rejected
    end

    test "stats/1 returns statistics", %{coordinator: coord} do
      stats = Consensus.stats(coord)
      assert is_map(stats)
      assert Map.has_key?(stats, :total_proposals)
    end
  end

  describe "event store facade" do
    test "query_events/2 queries events", %{event_store: es} do
      events = Consensus.query_events([], es)
      assert is_list(events)
    end

    test "events_for/2 returns events for a proposal", %{event_store: es} do
      events = Consensus.events_for("nonexistent", es)
      assert events == []
    end

    test "timeline/2 returns indexed timeline", %{event_store: es} do
      timeline = Consensus.timeline("nonexistent", es)
      assert timeline == []
    end
  end

  describe "list_pending/1" do
    test "returns pending proposals" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      Consensus.submit(
        %{proposer: "a1", change_type: :code_modification, description: "pending test"},
        server: coord
      )

      pending = Consensus.list_pending(coord)
      assert length(pending) == 1
      assert hd(pending).status in [:pending, :evaluating]
    end
  end

  describe "list_decisions/1" do
    test "returns decisions after evaluation", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Consensus.submit(proposal, server: coord)
      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)

      decisions = Consensus.list_decisions(coord)
      assert decisions != []
      assert hd(decisions).proposal_id == id
    end

    test "returns empty list when no decisions exist" do
      {_es_pid, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.SlowBackend,
        config: [evaluation_timeout_ms: 60_000]
      )

      decisions = Consensus.list_decisions(coord)
      assert decisions == []
    end
  end

  describe "recent_decisions/2" do
    test "returns recent decisions ordered by time", %{coordinator: coord} do
      for i <- 1..3 do
        {:ok, id} =
          Consensus.submit(
            %{proposer: "a#{i}", change_type: :code_modification, description: "p#{i}"},
            server: coord
          )

        {:ok, _} = TestHelpers.wait_for_decision(coord, id)
      end

      recent = Consensus.recent_decisions(2, coord)
      assert length(recent) == 2
    end

    test "returns all decisions when limit exceeds count", %{coordinator: coord} do
      {:ok, id} =
        Consensus.submit(
          %{proposer: "a1", change_type: :code_modification, description: "single"},
          server: coord
        )

      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      recent = Consensus.recent_decisions(100, coord)
      assert length(recent) == 1
    end
  end

  describe "contract callbacks" do
    test "submit_proposal_for_consensus_evaluation/2" do
      attrs = %{
        proposer: "contract_agent",
        change_type: :code_modification,
        description: "contract test"
      }

      {:ok, id} = Consensus.submit_proposal_for_consensus_evaluation(attrs, [])
      assert is_binary(id)
    end

    test "get_proposal_status_by_id/1" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "status_agent", change_type: :code_modification, description: "status"},
          []
        )

      {:ok, status} = Consensus.get_proposal_status_by_id(id)
      assert status in [:evaluating, :approved, :rejected, :deadlock, :pending]
    end

    test "get_council_decision_for_proposal/1" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "decision_agent", change_type: :code_modification, description: "decision"},
          []
        )

      # Give a moment for evaluation to complete
      Process.sleep(100)
      result = Consensus.get_council_decision_for_proposal(id)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "get_proposal_by_id/1" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "proposal_agent", change_type: :code_modification, description: "get"},
          []
        )

      {:ok, proposal} = Consensus.get_proposal_by_id(id)
      assert proposal.id == id
    end

    test "cancel_proposal_by_id/1" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "cancel_agent", change_type: :code_modification, description: "cancel"},
          []
        )

      result = Consensus.cancel_proposal_by_id(id)
      assert result in [:ok, {:error, :already_decided}]
    end

    test "healthy?/0 checks supervisor status" do
      result = Consensus.healthy?()
      assert is_boolean(result)
    end

    test "list_pending_proposals/0" do
      result = Consensus.list_pending_proposals()
      assert is_list(result)
    end

    test "list_all_proposals/0" do
      result = Consensus.list_all_proposals()
      assert is_list(result)
    end

    test "list_all_decisions/0" do
      result = Consensus.list_all_decisions()
      assert is_list(result)
    end

    test "get_recent_decisions_with_limit/1" do
      result = Consensus.get_recent_decisions_with_limit(5)
      assert is_list(result)
    end

    test "force_approve_proposal_by_authority/2" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "force_agent", change_type: :code_modification, description: "force"},
          []
        )

      result = Consensus.force_approve_proposal_by_authority(id, "admin")
      assert result in [:ok, {:error, :already_decided}]
    end

    test "force_reject_proposal_by_authority/2" do
      {:ok, id} =
        Consensus.submit_proposal_for_consensus_evaluation(
          %{proposer: "reject_agent", change_type: :code_modification, description: "reject"},
          []
        )

      result = Consensus.force_reject_proposal_by_authority(id, "admin")
      assert result in [:ok, {:error, :already_decided}]
    end

    test "get_consensus_system_stats/0" do
      stats = Consensus.get_consensus_system_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :total_proposals)
    end

    test "query_consensus_events_with_filters/1" do
      events = Consensus.query_consensus_events_with_filters([])
      assert is_list(events)
    end

    test "get_events_for_proposal/1" do
      events = Consensus.get_events_for_proposal("nonexistent")
      assert is_list(events)
    end

    test "get_timeline_for_proposal/1" do
      timeline = Consensus.get_timeline_for_proposal("nonexistent")
      assert is_list(timeline)
    end
  end
end
