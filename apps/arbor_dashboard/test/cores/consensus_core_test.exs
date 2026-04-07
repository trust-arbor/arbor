defmodule Arbor.Dashboard.Cores.ConsensusCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.ConsensusCore

  @moduletag :fast

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp sample_proposal do
    %{
      id: "prop_abc123def456",
      status: :pending,
      topic: "trust",
      mode: :ask,
      proposer: "agent_42",
      title: "Approve shell exec",
      description: "Allow `git status` for diagnostician",
      created_at: ~U[2026-04-07 10:00:00Z],
      metadata: %{resource_uri: "arbor://shell/exec/git"}
    }
  end

  defp sample_consultation do
    %{
      id: "cons_001",
      run_id: "run_001",
      sample_count: 5,
      status: :completed,
      dataset: "code_review",
      config: %{"question" => "Should we ship this refactor?"},
      created_at: ~U[2026-04-07 10:00:00Z],
      results: [
        %{
          perspective: "security",
          scores: %{"vote" => "approve", "confidence" => 0.92},
          metadata: %{
            "model" => "claude-sonnet",
            "cost" => 0.0234,
            "concerns" => ["check the migration path"],
            "recommendations" => ["add a feature flag"]
          }
        }
      ]
    }
  end

  # ── show_proposal/1 ──────────────────────────────────────────────────

  describe "show_proposal/1" do
    test "returns nil for nil input" do
      assert ConsensusCore.show_proposal(nil) == nil
    end

    test "shapes a proposal for display" do
      result = ConsensusCore.show_proposal(sample_proposal())

      assert result.id == "prop_abc123def456"
      assert result.status == :pending
      assert result.topic == "trust"
      assert result.subtitle == "trust | ask | agent_42"
      assert result.title == "Approve shell exec"
      assert result.metadata.resource_uri == "arbor://shell/exec/git"
      assert is_binary(result.created_at_relative)
    end
  end

  # ── show_decision/1 ──────────────────────────────────────────────────

  describe "show_decision/1" do
    test "returns nil for nil input" do
      assert ConsensusCore.show_decision(nil) == nil
    end

    test "shapes a decision with explicit fields" do
      decision = %{
        id: "dec_1",
        proposal_id: "prop_1",
        outcome: :approved,
        vote_count: 3,
        decided_at: ~U[2026-04-07 11:00:00Z],
        summary: "Council approved with caveats"
      }

      result = ConsensusCore.show_decision(decision)
      assert result.outcome == :approved
      assert result.vote_count == 3
      assert result.summary == "Council approved with caveats"
      assert is_binary(result.decided_at_relative)
    end

    test "falls back to alternate field names" do
      decision = %{proposal_id: "prop_1", decision: :rejected, created_at: nil}
      result = ConsensusCore.show_decision(decision)
      assert result.outcome == :rejected
      assert result.id == "prop_1"
    end
  end

  # ── show_consultation/1 + show_consultation_result/1 ─────────────────

  describe "show_consultation/1" do
    test "shapes a consultation with question and subtitle" do
      result = ConsensusCore.show_consultation(sample_consultation())

      assert result.id == "cons_001"
      assert result.question == "Should we ship this refactor?"
      assert result.subtitle == "5 perspectives | completed"
      assert result.perspective_count == 5
      assert is_list(result.results)
    end

    test "falls back to dataset when no question is configured" do
      consultation = %{id: "c1", config: %{}, dataset: "fallback_dataset", sample_count: 0}
      result = ConsensusCore.show_consultation(consultation)
      assert result.question == "fallback_dataset"
    end
  end

  describe "show_consultation_result/1" do
    test "extracts vote, confidence, model, cost, concerns, recommendations" do
      [result_data] = sample_consultation().results
      result = ConsensusCore.show_consultation_result(result_data)

      assert result.perspective == "security"
      assert result.vote == "approve"
      assert result.confidence == "92%"
      assert result.model == "claude-sonnet"
      assert result.cost == 0.0234
      assert result.concerns == ["check the migration path"]
      assert result.recommendations == ["add a feature flag"]
    end

    test "tolerates missing metadata" do
      result = ConsensusCore.show_consultation_result(%{perspective: "minimal"})
      assert result.vote == "unknown"
      assert result.confidence == "0%"
      assert result.model == ""
      assert result.cost == nil
      assert result.concerns == []
      assert result.recommendations == []
    end
  end

  # ── show_event/1 ─────────────────────────────────────────────────────

  describe "show_event/1" do
    test "formats event type and timestamp" do
      event = %{
        type: :proposal_submitted,
        timestamp: ~U[2026-04-07 10:00:00Z],
        actor: "agent_42",
        payload: %{some: "data"}
      }

      result = ConsensusCore.show_event(event)
      assert result.type == :proposal_submitted
      assert result.formatted_type == "proposal submitted"
      assert result.actor == "agent_42"
      assert is_binary(result.timestamp_relative)
    end

    test "tolerates missing fields with defaults" do
      result = ConsensusCore.show_event(%{})
      assert result.type == :unknown
      assert result.formatted_type == "unknown"
      assert result.payload == %{}
    end
  end

  # ── show_approval/1 ──────────────────────────────────────────────────

  describe "show_approval/1" do
    test "extracts resource URI from metadata" do
      result = ConsensusCore.show_approval(sample_proposal())

      assert result.id == "prop_abc123def456"
      assert result.id_short == "prop_abc123def45"
      assert result.resource == "arbor://shell/exec/git"
      assert result.proposer == "agent_42"
      assert is_binary(result.age)
    end

    test "falls back to description when no resource_uri" do
      proposal = %{
        id: "p1",
        description: "Some action",
        proposer: "a1",
        metadata: %{},
        created_at: nil
      }

      result = ConsensusCore.show_approval(proposal)
      assert result.resource == "Some action"
    end
  end

  # ── show_stats/1 ─────────────────────────────────────────────────────

  describe "show_stats/1" do
    test "passes through populated stats" do
      stats = %{
        total_proposals: 10,
        active_councils: 2,
        approved_count: 7,
        rejected_count: 1,
        consultation_count: 4
      }

      assert ConsensusCore.show_stats(stats) == stats
    end

    test "returns zero defaults for nil" do
      result = ConsensusCore.show_stats(nil)
      assert result.total_proposals == 0
      assert result.active_councils == 0
    end

    test "fills in missing keys with zeros" do
      result = ConsensusCore.show_stats(%{total_proposals: 5})
      assert result.total_proposals == 5
      assert result.approved_count == 0
    end
  end

  # ── Pure Helpers ─────────────────────────────────────────────────────

  describe "format_confidence/1" do
    test "handles floats as percentages" do
      assert ConsensusCore.format_confidence(0.92) == "92%"
      assert ConsensusCore.format_confidence(0.5) == "50%"
    end

    test "handles integers as already-percent" do
      assert ConsensusCore.format_confidence(75) == "75%"
    end

    test "defaults nil and other to 0%" do
      assert ConsensusCore.format_confidence(nil) == "0%"
      assert ConsensusCore.format_confidence("garbage") == "0%"
    end
  end

  describe "format_event_type/1" do
    test "atom snake_case becomes spaced lowercase" do
      assert ConsensusCore.format_event_type(:proposal_submitted) == "proposal submitted"
      assert ConsensusCore.format_event_type(:vote_cast) == "vote cast"
    end
  end

  describe "format_proposal_subtitle/1" do
    test "joins topic, mode, proposer with pipes" do
      result = ConsensusCore.format_proposal_subtitle(sample_proposal())
      assert result == "trust | ask | agent_42"
    end

    test "uses dashes for missing fields" do
      result = ConsensusCore.format_proposal_subtitle(%{})
      assert result == "— | — | —"
    end
  end

  describe "approval_resource/1" do
    test "prefers resource_uri from metadata" do
      proposal = %{metadata: %{resource_uri: "arbor://x"}, description: "desc"}
      assert ConsensusCore.approval_resource(proposal) == "arbor://x"
    end

    test "falls back to description" do
      proposal = %{metadata: %{}, description: "fallback"}
      assert ConsensusCore.approval_resource(proposal) == "fallback"
    end

    test "tolerates nil metadata" do
      proposal = %{metadata: nil, description: "fallback"}
      assert ConsensusCore.approval_resource(proposal) == "fallback"
    end
  end
end
