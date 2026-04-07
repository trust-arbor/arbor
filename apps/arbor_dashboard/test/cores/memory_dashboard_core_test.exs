defmodule Arbor.Dashboard.Cores.MemoryDashboardCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.MemoryDashboardCore

  @moduletag :fast

  # ── show_identity_tab/2 ──────────────────────────────────────────────

  describe "show_identity_tab/2" do
    test "returns has_data?: false when self_knowledge is nil" do
      result = MemoryDashboardCore.show_identity_tab(nil, [])
      refute result.has_data?
      assert result.traits == []
      assert result.values == []
    end

    test "extracts traits and values with capabilities" do
      sk = %{
        personality_traits: [
          %{trait: "curious", strength: 0.8},
          %{trait: "careful", strength: 0.6}
        ],
        values: [
          %{value: "helpfulness", importance: 0.9}
        ]
      }

      caps = ["arbor://shell/exec", "arbor://memory/read"]
      result = MemoryDashboardCore.show_identity_tab(sk, caps)

      assert result.has_data?
      assert {"curious", 0.8} in result.traits
      assert {"careful", 0.6} in result.traits
      assert {"helpfulness", 0.9} in result.values
      assert result.capabilities == caps
    end

    test "handles string-keyed self-knowledge" do
      sk = %{personality_traits: [%{"trait" => "kind", "strength" => 0.7}]}
      result = MemoryDashboardCore.show_identity_tab(sk, nil)
      assert {"kind", 0.7} in result.traits
      assert result.capabilities == []
    end
  end

  # ── show_goals_tab/1 ─────────────────────────────────────────────────

  describe "show_goals_tab/1" do
    test "returns empty list for nil or empty input" do
      assert MemoryDashboardCore.show_goals_tab(nil) == []
      assert MemoryDashboardCore.show_goals_tab([]) == []
    end

    test "shapes each goal with progress percentage and status color" do
      goals = [
        %{
          id: "g1",
          description: "Ship the refactor",
          status: :active,
          type: :achieve,
          priority: 80,
          progress: 0.5
        },
        %{
          id: "g2",
          description: "Tests stay green",
          status: :achieved,
          type: :maintain,
          priority: 100,
          progress: 1.0
        }
      ]

      result = MemoryDashboardCore.show_goals_tab(goals)

      [first, second] = result
      assert first.description == "Ship the refactor"
      assert first.status == :active
      assert first.status_color == :green
      assert first.progress_pct == 50
      assert first.priority == 80

      assert second.status == :achieved
      assert second.status_color == :blue
      assert second.progress_pct == 100
    end

    test "tolerates missing fields" do
      result = MemoryDashboardCore.show_goals_tab([%{}])
      [goal] = result
      assert goal.description == "—"
      assert goal.progress == 0
      assert goal.progress_pct == 0
      assert goal.deadline_label == nil
    end
  end

  # ── show_knowledge_tab/2 ─────────────────────────────────────────────

  describe "show_knowledge_tab/2" do
    test "shapes stats and near-threshold list" do
      stats = %{node_count: 100, edge_count: 250, active_set_size: 20, pending_count: 5}

      near = [
        %{type: :concept, content: "Erlang processes", relevance: 0.234},
        %{type: :fact, name: "BEAM is preemptive", relevance: 0.187}
      ]

      result = MemoryDashboardCore.show_knowledge_tab(stats, near)

      assert result.stats.node_count == 100
      assert result.stats.edge_count == 250
      assert result.stats.active_set_size == 20
      assert result.stats.pending_count == 5

      [first, second] = result.near_threshold
      assert first.type == :concept
      assert first.content == "Erlang processes"
      assert first.relevance_rounded == 0.234

      assert second.content == "BEAM is preemptive"
    end

    test "uses zero defaults when stats missing" do
      result = MemoryDashboardCore.show_knowledge_tab(nil, nil)
      assert result.stats.node_count == 0
      assert result.near_threshold == []
    end

    test "near-threshold node fallback content for missing fields" do
      result = MemoryDashboardCore.show_knowledge_tab(%{}, [%{type: :x, relevance: 0}])
      [node] = result.near_threshold
      assert node.content == "—"
    end
  end

  # ── show_preferences_tab/1 ───────────────────────────────────────────

  describe "show_preferences_tab/1" do
    test "returns nil when no preferences exist" do
      assert MemoryDashboardCore.show_preferences_tab(nil) == nil
      assert MemoryDashboardCore.show_preferences_tab(%{}) == nil
    end

    test "shapes prefs with stats and quotas" do
      prefs = %{
        decay_rate: 0.05,
        retrieval_threshold: 0.7,
        pinned_count: 3,
        adjustment_count: 12,
        type_quotas: %{episodic: 40, semantic: 60},
        context_preferences: %{verbosity: :high}
      }

      result = MemoryDashboardCore.show_preferences_tab(prefs)

      assert result.decay_rate == 0.05
      assert result.retrieval_threshold == 0.7
      assert result.pinned_count == 3
      assert result.adjustment_count == 12
      assert {:episodic, 40} in result.type_quotas
      assert {:verbosity, :high} in result.context_preferences
    end

    test "fills in defaults for missing fields" do
      result = MemoryDashboardCore.show_preferences_tab(%{decay_rate: 0.1})
      assert result.decay_rate == 0.1
      assert result.retrieval_threshold == "—"
      assert result.pinned_count == 0
      assert result.type_quotas == []
    end
  end

  # ── show_proposals_tab/2 ─────────────────────────────────────────────

  describe "show_proposals_tab/2" do
    test "shapes stats and proposal list with action button visibility" do
      proposals = [
        %{
          id: "p1",
          type: :insight,
          confidence: 0.85,
          status: :pending,
          content: "I noticed a pattern in error rates"
        },
        %{
          id: "p2",
          type: :recommendation,
          confidence: 0.6,
          status: :accepted,
          description: "Use a smaller model"
        }
      ]

      stats = %{pending: 1, accepted: 1, rejected: 0, deferred: 0}

      result = MemoryDashboardCore.show_proposals_tab(proposals, stats)

      assert result.stats == %{pending: 1, accepted: 1, rejected: 0, deferred: 0}

      [first, second] = result.proposals
      assert first.type == :insight
      assert first.confidence_pct == "85%"
      assert first.status_color == :yellow
      assert first.is_pending?
      assert first.content == "I noticed a pattern in error rates"

      assert second.confidence_pct == "60%"
      assert second.status_color == :green
      refute second.is_pending?
      # Falls back to description when content is nil
      assert second.content == "Use a smaller model"
    end

    test "tolerates nil stats and empty proposals" do
      result = MemoryDashboardCore.show_proposals_tab(nil, nil)
      assert result.stats.pending == 0
      assert result.proposals == []
    end

    test "treats string status 'pending' as pending too" do
      result = MemoryDashboardCore.show_proposals_tab([%{status: "pending"}], nil)
      [proposal] = result.proposals
      assert proposal.is_pending?
    end
  end

  # ── show_code_tab/1 ──────────────────────────────────────────────────

  describe "show_code_tab/1" do
    test "returns empty list for nil or empty input" do
      assert MemoryDashboardCore.show_code_tab(nil) == []
      assert MemoryDashboardCore.show_code_tab([]) == []
    end

    test "shapes each entry with truncated code" do
      entries = [
        %{
          id: "c1",
          purpose: "parse JSON",
          language: :elixir,
          code: String.duplicate("a", 1000)
        }
      ]

      result = MemoryDashboardCore.show_code_tab(entries)
      [entry] = result

      assert entry.purpose == "parse JSON"
      assert entry.language == :elixir
      assert String.length(entry.code) == 1000
      assert String.length(entry.code_truncated) <= 503
    end

    test "uses 'untitled' for missing purpose" do
      result = MemoryDashboardCore.show_code_tab([%{code: "x"}])
      assert hd(result).purpose == "untitled"
    end
  end

  # ── Pure Helpers ─────────────────────────────────────────────────────

  describe "goal_color/1" do
    test "maps known statuses" do
      assert MemoryDashboardCore.goal_color(:active) == :green
      assert MemoryDashboardCore.goal_color(:achieved) == :blue
      assert MemoryDashboardCore.goal_color(:abandoned) == :red
      assert MemoryDashboardCore.goal_color(:failed) == :red
      assert MemoryDashboardCore.goal_color(:unknown) == :gray
      assert MemoryDashboardCore.goal_color(nil) == :gray
    end
  end

  describe "proposal_status_color/1" do
    test "handles atom and string statuses" do
      assert MemoryDashboardCore.proposal_status_color(:pending) == :yellow
      assert MemoryDashboardCore.proposal_status_color("pending") == :yellow
      assert MemoryDashboardCore.proposal_status_color(:accepted) == :green
      assert MemoryDashboardCore.proposal_status_color("rejected") == :red
      assert MemoryDashboardCore.proposal_status_color(nil) == :gray
    end
  end

  describe "format_pct/1" do
    test "rounds to integer percentages" do
      assert MemoryDashboardCore.format_pct(0.85) == "85%"
      assert MemoryDashboardCore.format_pct(1.0) == "100%"
      assert MemoryDashboardCore.format_pct(0) == "0%"
    end

    test "handles nil" do
      assert MemoryDashboardCore.format_pct(nil) == "—"
    end
  end

  describe "format_deadline/1" do
    test "formats DateTime as YYYY-MM-DD" do
      assert MemoryDashboardCore.format_deadline(~U[2026-04-07 12:00:00Z]) == "2026-04-07"
    end

    test "handles nil" do
      assert MemoryDashboardCore.format_deadline(nil) == nil
    end
  end

  describe "tab_label/1" do
    test "maps known tabs to emoji + name" do
      assert MemoryDashboardCore.tab_label("working_memory") == "💭 Working Memory"
      assert MemoryDashboardCore.tab_label("identity") == "🪞 Identity"
      assert MemoryDashboardCore.tab_label("goals") == "🎯 Goals"
    end

    test "passes through unknown tabs" do
      assert MemoryDashboardCore.tab_label("custom") == "custom"
    end
  end
end
