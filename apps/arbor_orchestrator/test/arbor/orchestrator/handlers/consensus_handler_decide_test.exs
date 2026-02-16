defmodule Arbor.Orchestrator.Handlers.ConsensusHandlerDecideTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ConsensusHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{"mode" => "decision"}}

  @moduletag :consensus_handler

  defp decide_node(attrs \\ %{}) do
    defaults = %{
      "type" => "consensus.decide",
      "quorum" => "majority",
      "mode" => "decision"
    }

    %Node{id: "decide", attrs: Map.merge(defaults, attrs)}
  end

  defp run_decide(context_values, node_attrs \\ %{}) do
    ConsensusHandler.execute(
      decide_node(node_attrs),
      Context.new(context_values),
      @graph,
      []
    )
  end

  defp make_branch_result(id, vote, opts \\ []) do
    reasoning = Keyword.get(opts, :reasoning, "Test reasoning for #{id}")
    confidence = Keyword.get(opts, :confidence, 0.8)
    concerns = Keyword.get(opts, :concerns, [])
    risk_score = Keyword.get(opts, :risk_score, 0.2)

    json =
      Jason.encode!(%{
        "vote" => vote,
        "reasoning" => reasoning,
        "confidence" => confidence,
        "concerns" => concerns,
        "risk_score" => risk_score
      })

    %{
      "id" => id,
      "status" => "success",
      "score" => 1.0,
      "context_updates" => %{
        "last_response" => json
      }
    }
  end

  defp make_text_result(id, text) do
    %{
      "id" => id,
      "status" => "success",
      "score" => 1.0,
      "context_updates" => %{
        "last_response" => text
      }
    }
  end

  describe "consensus.decide — empty results" do
    test "fails when no parallel.results in context" do
      outcome = run_decide(%{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no parallel.results"
    end

    test "fails when parallel.results is empty list" do
      outcome = run_decide(%{"parallel.results" => []})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no parallel.results"
    end
  end

  describe "consensus.decide — majority vote" do
    test "majority approve produces approved decision" do
      results = [
        make_branch_result("security", "approve"),
        make_branch_result("stability", "approve"),
        make_branch_result("brainstorming", "reject")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "Should we add caching?"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
      assert outcome.context_updates["council.approve_count"] == 2
      assert outcome.context_updates["council.reject_count"] == 1
      assert outcome.context_updates["council.abstain_count"] == 0
      assert outcome.context_updates["council.quorum_met"] == true
      assert outcome.context_updates["consensus.status"] == "decided"
    end

    test "majority reject produces rejected decision" do
      results = [
        make_branch_result("security", "reject"),
        make_branch_result("stability", "reject"),
        make_branch_result("brainstorming", "approve")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "Should we add Redis?"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "rejected"
      assert outcome.context_updates["council.reject_count"] == 2
      assert outcome.context_updates["council.approve_count"] == 1
    end

    test "no majority produces deadlock" do
      results = [
        make_branch_result("security", "approve"),
        make_branch_result("stability", "reject"),
        make_branch_result("brainstorming", "abstain"),
        make_branch_result("vision", "abstain")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "Contentious question"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "deadlock"
      assert outcome.context_updates["council.approve_count"] == 1
      assert outcome.context_updates["council.reject_count"] == 1
      assert outcome.context_updates["council.abstain_count"] == 2
    end
  end

  describe "consensus.decide — quorum types" do
    test "supermajority requires 2/3" do
      # 3 approve out of 4 = 75% >= 66.7%
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "approve"),
        make_branch_result("d", "reject")
      ]

      outcome =
        run_decide(
          %{"parallel.results" => results, "council.question" => "test"},
          %{"quorum" => "supermajority"}
        )

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
    end

    test "supermajority deadlocks when not met" do
      # 2 approve out of 4 = 50% < 66.7%
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "reject"),
        make_branch_result("d", "reject")
      ]

      outcome =
        run_decide(
          %{"parallel.results" => results, "council.question" => "test"},
          %{"quorum" => "supermajority"}
        )

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "deadlock"
    end

    test "unanimous requires all" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "approve")
      ]

      outcome =
        run_decide(
          %{"parallel.results" => results, "council.question" => "test"},
          %{"quorum" => "unanimous"}
        )

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
    end

    test "unanimous fails with one dissent" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "reject")
      ]

      outcome =
        run_decide(
          %{"parallel.results" => results, "council.question" => "test"},
          %{"quorum" => "unanimous"}
        )

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] != "approved"
    end

    test "numeric quorum string" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "reject"),
        make_branch_result("c", "reject")
      ]

      outcome =
        run_decide(
          %{"parallel.results" => results, "council.question" => "test"},
          %{"quorum" => "1"}
        )

      assert outcome.status == :success
      # 1 approve >= quorum of 1
      assert outcome.context_updates["council.decision"] == "approved"
    end
  end

  describe "consensus.decide — vote parsing" do
    test "parses JSON vote with all fields" do
      results = [
        make_branch_result("security", "approve",
          reasoning: "Solid design",
          confidence: 0.9,
          concerns: ["latency"],
          risk_score: 0.3
        ),
        make_branch_result("stability", "approve",
          reasoning: "OTP handles it",
          confidence: 0.85,
          concerns: [],
          risk_score: 0.1
        )
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
      # Average confidence should be around 0.875
      avg_conf = outcome.context_updates["council.average_confidence"]
      assert is_float(avg_conf)
      assert avg_conf > 0.8
    end

    test "falls back to text-based vote detection" do
      results = [
        make_text_result("security", "I approve of this design. It looks solid."),
        make_text_result("stability", "I would approve this change with minor reservations.")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
    end

    test "text with reject keyword" do
      results = [
        make_text_result("security", "I reject this proposal due to security concerns."),
        make_text_result("stability", "I also reject this approach.")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "rejected"
    end

    test "ambiguous text defaults to abstain" do
      results = [
        make_text_result("a", "This is an interesting proposal with pros and cons."),
        make_text_result("b", "I need more information before deciding."),
        make_text_result("c", "The trade-offs are complex.")
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      # All abstain → deadlock (no quorum for either approve or reject)
      assert outcome.context_updates["council.decision"] == "deadlock"
      assert outcome.context_updates["council.abstain_count"] == 3
    end

    test "extracts JSON from markdown fence" do
      json_in_markdown = """
      Here is my analysis:

      ```json
      {"vote": "approve", "reasoning": "Good design", "confidence": 0.9, "concerns": [], "risk_score": 0.1}
      ```

      Some additional thoughts.
      """

      results = [
        make_text_result("a", json_in_markdown),
        make_text_result("b", json_in_markdown)
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      assert outcome.context_updates["council.decision"] == "approved"
    end

    test "skips results with empty responses" do
      results = [
        make_branch_result("a", "approve"),
        %{
          "id" => "b",
          "status" => "success",
          "score" => 1.0,
          "context_updates" => %{"last_response" => ""}
        },
        %{"id" => "c", "status" => "fail", "score" => 0.0, "context_updates" => %{}}
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      # Only 1 valid evaluation, quorum = 1 (majority of 1)
      assert outcome.context_updates["council.approve_count"] == 1
    end
  end

  describe "consensus.decide — confidence and concerns" do
    test "tracks average confidence" do
      results = [
        make_branch_result("a", "approve", confidence: 0.9),
        make_branch_result("b", "approve", confidence: 0.7),
        make_branch_result("c", "approve", confidence: 0.8)
      ]

      outcome =
        run_decide(%{
          "parallel.results" => results,
          "council.question" => "test"
        })

      assert outcome.status == :success
      avg = outcome.context_updates["council.average_confidence"]
      assert_in_delta avg, 0.8, 0.01
    end
  end
end
