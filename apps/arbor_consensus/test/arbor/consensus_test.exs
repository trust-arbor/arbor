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
end
