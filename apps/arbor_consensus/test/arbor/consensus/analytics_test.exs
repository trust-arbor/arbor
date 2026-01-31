defmodule Arbor.Consensus.AnalyticsTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.{Analytics, Coordinator}
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.CouncilDecision

  @moduletag :integration

  # ============================================================================
  # feedback_size/1 and feedback_exceeds_limit?/2
  # These can be tested with direct struct creation (no coordinator needed)
  # ============================================================================

  describe "feedback_size/1" do
    test "calculates character counts for decision feedback" do
      evals = [
        TestHelpers.build_evaluation(%{
          reasoning: "This looks risky",
          concerns: ["SQL injection possible"],
          recommendations: ["Use parameterized queries"]
        }),
        TestHelpers.build_evaluation(%{
          evaluator_id: "eval_2",
          perspective: :stability,
          reasoning: "Performance concern",
          concerns: ["N+1 query detected"],
          recommendations: ["Add eager loading", "Add index"]
        })
      ]

      decision = build_test_decision(
        primary_concerns: ["Security risk detected", "Performance issue"],
        evaluations: evals
      )

      result = Analytics.feedback_size(decision)

      assert is_map(result)
      assert result.primary_concerns_chars > 0
      assert result.reasoning_chars > 0
      assert result.recommendations_chars > 0
      assert result.all_concerns_chars > 0
      assert result.total_chars > 0
      assert result.estimated_tokens == div(result.total_chars, 4)
      assert result.evaluation_count == 2
    end

    test "handles empty feedback" do
      decision = build_test_decision(
        primary_concerns: [],
        evaluations: []
      )

      result = Analytics.feedback_size(decision)

      assert result.total_chars == 0
      assert result.estimated_tokens == 0
      assert result.evaluation_count == 0
    end

    test "handles single evaluation with all fields populated" do
      eval = TestHelpers.build_evaluation(%{
        reasoning: String.duplicate("word ", 100),
        concerns: ["concern1", "concern2", "concern3"],
        recommendations: ["rec1", "rec2"]
      })

      decision = build_test_decision(
        primary_concerns: ["main concern"],
        evaluations: [eval]
      )

      result = Analytics.feedback_size(decision)
      assert result.evaluation_count == 1
      assert result.primary_concerns_chars == String.length("main concern")
      expected_total =
        result.primary_concerns_chars + result.reasoning_chars +
          result.recommendations_chars + result.all_concerns_chars

      assert result.total_chars == expected_total
    end
  end

  describe "feedback_exceeds_limit?/2" do
    test "returns false for small feedback" do
      decision = build_test_decision(
        primary_concerns: ["Minor"],
        evaluations: [TestHelpers.build_evaluation(%{reasoning: "OK"})]
      )

      refute Analytics.feedback_exceeds_limit?(decision)
    end

    test "returns true for large feedback exceeding 4000 token default" do
      long_text = String.duplicate("a", 20_000)

      decision = build_test_decision(
        primary_concerns: [long_text],
        evaluations: []
      )

      assert Analytics.feedback_exceeds_limit?(decision)
    end

    test "respects custom max_tokens option" do
      eval = TestHelpers.build_evaluation(%{reasoning: String.duplicate("x", 100)})

      decision = build_test_decision(
        primary_concerns: ["Short"],
        evaluations: [eval]
      )

      # Very low limit should trigger
      assert Analytics.feedback_exceeds_limit?(decision, max_tokens: 1)
      # Very high limit should not trigger
      refute Analytics.feedback_exceeds_limit?(decision, max_tokens: 100_000)
    end
  end

  # ============================================================================
  # Functions requiring coordinator with proposals
  # ============================================================================

  describe "proposer_history/2" do
    setup do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator()
      %{coordinator: coord}
    end

    test "returns proposals with decisions for a proposer", %{coordinator: coord} do
      {:ok, id} = Coordinator.submit(
        %{proposer: "history_agent", change_type: :code_modification, description: "test"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      history = Analytics.proposer_history("history_agent", coordinator: coord)

      assert length(history) == 1
      [{proposal, decision}] = history
      assert proposal.proposer == "history_agent"
      assert decision != nil
      assert decision.proposal_id == id
    end

    test "returns empty list for unknown proposer", %{coordinator: coord} do
      history = Analytics.proposer_history("nonexistent", coordinator: coord)
      assert history == []
    end

    test "filters by since option", %{coordinator: coord} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, id} = Coordinator.submit(
        %{proposer: "since_agent", change_type: :code_modification, description: "old"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      # Filter for proposals after future time
      history = Analytics.proposer_history("since_agent", coordinator: coord, since: future)
      assert history == []
    end

    test "includes proposals when since is before creation time", %{coordinator: coord} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, id} = Coordinator.submit(
        %{proposer: "since_before_agent", change_type: :code_modification, description: "recent"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      history = Analytics.proposer_history("since_before_agent", coordinator: coord, since: past)
      assert length(history) == 1
    end

    test "respects limit option", %{coordinator: coord} do
      for i <- 1..3 do
        {:ok, id} = Coordinator.submit(
          %{proposer: "limit_agent", change_type: :code_modification, description: "p#{i}"},
          server: coord
        )
        {:ok, _} = TestHelpers.wait_for_decision(coord, id)
      end

      history = Analytics.proposer_history("limit_agent", coordinator: coord, limit: 2)
      assert length(history) == 2
    end

    test "returns nil decision for pending proposals" do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.SlowBackend,
        config: [evaluation_timeout_ms: 60_000]
      )

      {:ok, _id} = Coordinator.submit(
        %{proposer: "pending_agent", change_type: :code_modification, description: "slow"},
        server: coord
      )

      history = Analytics.proposer_history("pending_agent", coordinator: coord)
      assert length(history) == 1
      [{_proposal, decision}] = history
      assert decision == nil
    end
  end

  describe "revision_chains/2" do
    setup do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator()
      %{coordinator: coord}
    end

    test "detects explicit chains via parent_proposal_id", %{coordinator: coord} do
      {:ok, id1} = Coordinator.submit(
        %{proposer: "chain_agent", change_type: :code_modification, description: "v1"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id1)

      {:ok, id2} = Coordinator.submit(
        %{
          proposer: "chain_agent",
          change_type: :code_modification,
          description: "v2 after feedback",
          metadata: %{parent_proposal_id: id1}
        },
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id2)

      chains = Analytics.revision_chains("chain_agent", coordinator: coord)

      assert chains != []
      chain = hd(chains)
      assert length(chain) == 2
      chain_ids = Enum.map(chain, & &1.id)
      assert id1 in chain_ids
      assert id2 in chain_ids
    end

    test "detects implicit chains via time clustering", %{coordinator: coord} do
      {:ok, id1} = Coordinator.submit(
        %{proposer: "implicit_agent", change_type: :test_change, description: "test v1"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id1)

      {:ok, id2} = Coordinator.submit(
        %{proposer: "implicit_agent", change_type: :test_change, description: "test v2"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id2)

      chains = Analytics.revision_chains("implicit_agent", coordinator: coord)
      assert chains != []
    end

    test "returns empty for single proposals", %{coordinator: coord} do
      {:ok, id} = Coordinator.submit(
        %{proposer: "solo_agent", change_type: :code_modification, description: "solo"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      chains = Analytics.revision_chains("solo_agent", coordinator: coord)
      assert chains == []
    end

    test "handles string parent_proposal_id key", %{coordinator: coord} do
      {:ok, id1} = Coordinator.submit(
        %{proposer: "string_key_agent", change_type: :code_modification, description: "v1"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id1)

      {:ok, _id2} = Coordinator.submit(
        %{
          proposer: "string_key_agent",
          change_type: :code_modification,
          description: "v2",
          metadata: %{"parent_proposal_id" => id1}
        },
        server: coord
      )

      chains = Analytics.revision_chains("string_key_agent", coordinator: coord)
      assert chains != []
    end
  end

  describe "max_revision_depth/2" do
    setup do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator()
      %{coordinator: coord}
    end

    test "returns 0 when no chains exist", %{coordinator: coord} do
      {:ok, id} = Coordinator.submit(
        %{proposer: "depth_zero_agent", change_type: :code_modification, description: "solo"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      depth = Analytics.max_revision_depth("depth_zero_agent", coordinator: coord)
      assert depth == 0
    end

    test "returns chain length for chained proposals", %{coordinator: coord} do
      {:ok, id1} = Coordinator.submit(
        %{proposer: "depth_agent", change_type: :code_modification, description: "v1"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id1)

      {:ok, _id2} = Coordinator.submit(
        %{
          proposer: "depth_agent",
          change_type: :code_modification,
          description: "v2",
          metadata: %{parent_proposal_id: id1}
        },
        server: coord
      )

      depth = Analytics.max_revision_depth("depth_agent", coordinator: coord)
      assert depth >= 2
    end

    test "returns 0 for unknown proposer", %{coordinator: coord} do
      depth = Analytics.max_revision_depth("nobody", coordinator: coord)
      assert depth == 0
    end
  end

  describe "repeated_concerns/2" do
    setup do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      # Use rejecting backend so decisions have concerns
      {_pid, coord} = TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.AlwaysRejectBackend
      )
      %{coordinator: coord}
    end

    test "finds concerns repeated across proposals", %{coordinator: coord} do
      for i <- 1..3 do
        {:ok, id} = Coordinator.submit(
          %{proposer: "concern_agent", change_type: :code_modification, description: "attempt #{i}"},
          server: coord
        )
        {:ok, _} = TestHelpers.wait_for_decision(coord, id)
      end

      concerns = Analytics.repeated_concerns("concern_agent",
        coordinator: coord,
        min_occurrences: 2
      )

      # AlwaysRejectBackend uses concerns: ["Test concern"]
      assert concerns != []

      {concern, count, proposal_ids} = hd(concerns)
      assert is_binary(concern)
      assert count >= 2
      assert is_list(proposal_ids)
    end

    test "returns empty when no concerns repeat", %{coordinator: coord} do
      {:ok, id} = Coordinator.submit(
        %{proposer: "once_agent", change_type: :code_modification, description: "once"},
        server: coord
      )
      {:ok, _} = TestHelpers.wait_for_decision(coord, id)

      concerns = Analytics.repeated_concerns("once_agent",
        coordinator: coord,
        min_occurrences: 2
      )
      assert concerns == []
    end

    test "returns empty for unknown proposer", %{coordinator: coord} do
      concerns = Analytics.repeated_concerns("nobody", coordinator: coord)
      assert concerns == []
    end

    test "respects min_occurrences option", %{coordinator: coord} do
      for i <- 1..2 do
        {:ok, id} = Coordinator.submit(
          %{proposer: "min_occ_agent", change_type: :code_modification, description: "p#{i}"},
          server: coord
        )
        {:ok, _} = TestHelpers.wait_for_decision(coord, id)
      end

      # With high min_occurrences, nothing should match
      concerns = Analytics.repeated_concerns("min_occ_agent",
        coordinator: coord,
        min_occurrences: 100
      )
      assert concerns == []
    end
  end

  describe "proposer_stats/2" do
    setup do
      {_es, _es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator()
      %{coordinator: coord}
    end

    test "returns aggregate statistics for proposer with proposals", %{coordinator: coord} do
      for i <- 1..2 do
        {:ok, id} = Coordinator.submit(
          %{proposer: "stats_agent", change_type: :code_modification, description: "p#{i}"},
          server: coord
        )
        {:ok, _} = TestHelpers.wait_for_decision(coord, id)
      end

      stats = Analytics.proposer_stats("stats_agent", coordinator: coord)

      assert stats.proposer_id == "stats_agent"
      assert stats.total_proposals == 2
      assert is_map(stats.outcomes)
      assert Map.has_key?(stats.outcomes, :approved)
      assert Map.has_key?(stats.outcomes, :rejected)
      assert Map.has_key?(stats.outcomes, :deadlock)
      assert Map.has_key?(stats.outcomes, :pending)
      assert is_float(stats.approval_rate)
      assert is_integer(stats.revision_chains)
      assert is_integer(stats.max_revision_depth)
      assert is_integer(stats.repeated_concern_count)
      assert is_list(stats.top_repeated_concerns)
      assert is_integer(stats.avg_feedback_tokens)
      assert is_integer(stats.max_feedback_tokens)
    end

    test "handles proposer with no proposals", %{coordinator: coord} do
      stats = Analytics.proposer_stats("nobody", coordinator: coord)

      assert stats.total_proposals == 0
      assert stats.approval_rate == 0.0
      assert stats.avg_feedback_tokens == 0
      assert stats.max_feedback_tokens == 0
      assert stats.revision_chains == 0
    end
  end

  describe "proposer_events/2" do
    setup do
      {_es, es_name} = TestHelpers.start_test_event_store()
      {_pid, coord} = TestHelpers.start_test_coordinator()
      %{coordinator: coord, event_store: es_name}
    end

    test "returns events for a proposer", %{coordinator: coord, event_store: es} do
      {:ok, _id} = Coordinator.submit(
        %{proposer: "event_agent", change_type: :code_modification, description: "test"},
        server: coord
      )

      events = Analytics.proposer_events("event_agent", event_store: es)
      assert is_list(events)
    end

    test "returns empty for unknown proposer", %{event_store: es} do
      events = Analytics.proposer_events("nobody", event_store: es)
      assert events == []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_test_decision(opts) do
    now = DateTime.utc_now()

    %CouncilDecision{
      id: "dec_test_#{System.unique_integer([:positive])}",
      proposal_id: Keyword.get(opts, :proposal_id, "prop_test"),
      decision: Keyword.get(opts, :decision, :approved),
      required_quorum: 5,
      quorum_met: true,
      approve_count: Keyword.get(opts, :approve_count, 5),
      reject_count: Keyword.get(opts, :reject_count, 1),
      abstain_count: Keyword.get(opts, :abstain_count, 1),
      evaluations: Keyword.get(opts, :evaluations, []),
      evaluation_ids: [],
      primary_concerns: Keyword.get(opts, :primary_concerns, []),
      average_confidence: 0.85,
      average_risk: 0.3,
      average_benefit: 0.7,
      created_at: now,
      decided_at: now
    }
  end
end
