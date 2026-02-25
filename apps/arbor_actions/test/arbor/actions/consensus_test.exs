defmodule Arbor.Actions.ConsensusTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Consensus

  @moduletag :fast

  # ============================================================================
  # Propose
  # ============================================================================

  describe "Propose — schema" do
    test "rejects missing description" do
      assert {:error, _} = Consensus.Propose.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} = Consensus.Propose.validate_params(%{description: "test proposal"})
    end

    test "accepts all optional params" do
      assert {:ok, _} =
               Consensus.Propose.validate_params(%{
                 description: "test proposal",
                 agent_id: "agent_1",
                 timeout: 30_000,
                 evaluators: "security,stability"
               })
    end

    test "action metadata" do
      assert Consensus.Propose.name() == "consensus_propose"
    end
  end

  # ============================================================================
  # Ask
  # ============================================================================

  describe "Ask — schema" do
    test "rejects missing question" do
      assert {:error, _} = Consensus.Ask.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} = Consensus.Ask.validate_params(%{question: "Should we add caching?"})
    end

    test "accepts all optional params" do
      assert {:ok, _} =
               Consensus.Ask.validate_params(%{
                 question: "Should we add caching?",
                 timeout: 60_000,
                 evaluators: "security"
               })
    end

    test "action metadata" do
      assert Consensus.Ask.name() == "consensus_ask"
    end
  end

  # ============================================================================
  # Await
  # ============================================================================

  describe "Await — schema" do
    test "rejects missing proposal_id" do
      assert {:error, _} = Consensus.Await.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} = Consensus.Await.validate_params(%{proposal_id: "proposal-123"})
    end

    test "action metadata" do
      assert Consensus.Await.name() == "consensus_await"
    end
  end

  # ============================================================================
  # Check
  # ============================================================================

  describe "Check — schema" do
    test "rejects missing proposal_id" do
      assert {:error, _} = Consensus.Check.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} = Consensus.Check.validate_params(%{proposal_id: "proposal-123"})
    end

    test "action metadata" do
      assert Consensus.Check.name() == "consensus_check"
    end
  end

  # ============================================================================
  # Decide — schema & metadata
  # ============================================================================

  describe "Decide — schema" do
    test "accepts empty params (results optional in schema, validated at runtime)" do
      assert {:ok, _} = Consensus.Decide.validate_params(%{})
    end

    test "accepts full params" do
      assert {:ok, _} =
               Consensus.Decide.validate_params(%{
                 results: [%{id: "a"}],
                 question: "test",
                 quorum: "majority",
                 mode: "decision"
               })
    end

    test "action metadata" do
      assert Consensus.Decide.name() == "consensus_decide"
    end
  end

  # ============================================================================
  # Decide — vote parsing
  # ============================================================================

  describe "Decide — vote parsing" do
    test "parses JSON vote" do
      json =
        ~s({"vote": "approve", "reasoning": "Good", "confidence": 0.9, "concerns": [], "risk_score": 0.1})

      {vote, reasoning, confidence, concerns, risk_score} = Consensus.Decide.parse_vote_data(json)
      assert vote == :approve
      assert reasoning == "Good"
      assert_in_delta confidence, 0.9, 0.01
      assert concerns == []
      assert_in_delta risk_score, 0.1, 0.01
    end

    test "parses JSON with reject vote" do
      json = ~s({"vote": "reject", "reasoning": "Bad design", "confidence": 0.7})
      {vote, reasoning, confidence, _, _} = Consensus.Decide.parse_vote_data(json)
      assert vote == :reject
      assert reasoning == "Bad design"
      assert_in_delta confidence, 0.7, 0.01
    end

    test "extracts JSON from markdown fence" do
      text = """
      Here is my analysis:

      ```json
      {"vote": "approve", "reasoning": "Solid", "confidence": 0.85}
      ```

      Additional thoughts.
      """

      assert {:ok, json} = Consensus.Decide.extract_json_from_text(text)
      assert json["vote"] == "approve"
    end

    test "text-based approve detection" do
      assert Consensus.Decide.detect_vote_from_text("I approve of this design.") == :approve
    end

    test "text-based reject detection" do
      assert Consensus.Decide.detect_vote_from_text("I reject this proposal.") == :reject
    end

    test "ambiguous text defaults to abstain" do
      assert Consensus.Decide.detect_vote_from_text("This has pros and cons.") == :abstain
    end

    test "text with both approve and reject defaults to abstain" do
      assert Consensus.Decide.detect_vote_from_text("I would approve but also reject parts.") ==
               :abstain
    end

    test "parse_vote handles string values" do
      assert Consensus.Decide.parse_vote("approve") == :approve
      assert Consensus.Decide.parse_vote("reject") == :reject
      assert Consensus.Decide.parse_vote("abstain") == :abstain
    end

    test "parse_vote with text falls through to detection" do
      assert Consensus.Decide.parse_vote("I approve this") == :approve
    end

    test "parse_confidence clamps to [0, 1]" do
      assert Consensus.Decide.parse_confidence(1.5) == 1.0
      assert Consensus.Decide.parse_confidence(-0.5) == 0.0
      assert Consensus.Decide.parse_confidence(0.7) == 0.7
      assert Consensus.Decide.parse_confidence("0.8") == 0.8
      assert Consensus.Decide.parse_confidence("invalid") == 0.5
      assert Consensus.Decide.parse_confidence(nil) == 0.5
    end
  end

  # ============================================================================
  # Decide — quorum calculation
  # ============================================================================

  describe "Decide — quorum" do
    test "majority" do
      assert Consensus.Decide.calculate_quorum("majority", 3) == 2
      assert Consensus.Decide.calculate_quorum("majority", 4) == 3
      assert Consensus.Decide.calculate_quorum("majority", 5) == 3
    end

    test "supermajority" do
      assert Consensus.Decide.calculate_quorum("supermajority", 3) == 2
      assert Consensus.Decide.calculate_quorum("supermajority", 4) == 3
      assert Consensus.Decide.calculate_quorum("supermajority", 6) == 4
    end

    test "unanimous" do
      assert Consensus.Decide.calculate_quorum("unanimous", 3) == 3
      assert Consensus.Decide.calculate_quorum("unanimous", 5) == 5
    end

    test "numeric string" do
      assert Consensus.Decide.calculate_quorum("2", 10) == 2
      assert Consensus.Decide.calculate_quorum("1", 10) == 1
    end

    test "invalid string defaults to 1" do
      assert Consensus.Decide.calculate_quorum("invalid", 10) == 1
    end
  end

  # ============================================================================
  # Decide — full run
  # ============================================================================

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

  describe "Decide — empty results" do
    test "returns error when no results" do
      assert {:error, msg} = Consensus.Decide.run(%{results: []}, %{})
      assert msg =~ "no results"
    end

    test "returns error when results key missing" do
      assert {:error, msg} = Consensus.Decide.run(%{}, %{})
      assert msg =~ "no results"
    end
  end

  describe "Decide — majority vote" do
    test "majority approve produces approved decision" do
      results = [
        make_branch_result("security", "approve"),
        make_branch_result("stability", "approve"),
        make_branch_result("brainstorming", "reject")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Should we add caching?"},
                 %{}
               )

      assert result.decision == "approved"
      assert result.approve_count == 2
      assert result.reject_count == 1
      assert result.abstain_count == 0
      assert result.quorum_met == true
      assert result.status == "decided"
    end

    test "majority reject produces rejected decision" do
      results = [
        make_branch_result("security", "reject"),
        make_branch_result("stability", "reject"),
        make_branch_result("brainstorming", "approve")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Should we add Redis?"},
                 %{}
               )

      assert result.decision == "rejected"
      assert result.reject_count == 2
      assert result.approve_count == 1
    end

    test "no majority produces deadlock" do
      results = [
        make_branch_result("security", "approve"),
        make_branch_result("stability", "reject"),
        make_branch_result("brainstorming", "abstain"),
        make_branch_result("vision", "abstain")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Contentious question"},
                 %{}
               )

      assert result.decision == "deadlock"
      assert result.approve_count == 1
      assert result.reject_count == 1
      assert result.abstain_count == 2
    end
  end

  describe "Decide — quorum types in run" do
    test "supermajority requires 2/3" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "approve"),
        make_branch_result("d", "reject")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "supermajority"},
                 %{}
               )

      assert result.decision == "approved"
    end

    test "supermajority deadlocks when not met" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "reject"),
        make_branch_result("d", "reject")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "supermajority"},
                 %{}
               )

      assert result.decision == "deadlock"
    end

    test "unanimous requires all" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "approve")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "unanimous"},
                 %{}
               )

      assert result.decision == "approved"
    end

    test "unanimous fails with one dissent" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "reject")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "unanimous"},
                 %{}
               )

      assert result.decision != "approved"
    end

    test "numeric quorum string" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "reject"),
        make_branch_result("c", "reject")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "1"},
                 %{}
               )

      assert result.decision == "approved"
    end
  end

  describe "Decide — text-based votes" do
    test "falls back to text-based vote detection" do
      results = [
        make_text_result("security", "I approve of this design. It looks solid."),
        make_text_result("stability", "I would approve this change with minor reservations.")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.decision == "approved"
    end

    test "text with reject keyword" do
      results = [
        make_text_result("security", "I reject this proposal due to security concerns."),
        make_text_result("stability", "I also reject this approach.")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.decision == "rejected"
    end

    test "ambiguous text defaults to abstain" do
      results = [
        make_text_result("a", "This is an interesting proposal with pros and cons."),
        make_text_result("b", "I need more information before deciding."),
        make_text_result("c", "The trade-offs are complex.")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.decision == "deadlock"
      assert result.abstain_count == 3
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

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.decision == "approved"
    end
  end

  describe "Decide — confidence tracking" do
    test "tracks average confidence" do
      results = [
        make_branch_result("a", "approve", confidence: 0.9),
        make_branch_result("b", "approve", confidence: 0.7),
        make_branch_result("c", "approve", confidence: 0.8)
      ]

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert_in_delta result.average_confidence, 0.8, 0.01
    end

    test "parses JSON with all fields" do
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

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.decision == "approved"
      assert result.average_confidence > 0.8
    end
  end

  describe "Decide — empty/failed branch handling" do
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

      assert {:ok, result} =
               Consensus.Decide.run(%{results: results, question: "test"}, %{})

      assert result.approve_count == 1
    end
  end

  describe "Decide — DOT pipeline context key format" do
    test "accepts full context key names from DOT pipelines" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve")
      ]

      # When called from DOT pipeline with context_keys, params have full key names
      assert {:ok, result} =
               Consensus.Decide.run(
                 %{
                   "parallel.results" => results,
                   "council.question" => "test via pipeline"
                 },
                 %{}
               )

      assert result.decision == "approved"
    end
  end

  # ============================================================================
  # Module structure
  # ============================================================================

  describe "module structure" do
    test "all modules compile and export run/2" do
      modules = [
        Consensus.Propose,
        Consensus.Ask,
        Consensus.Await,
        Consensus.Check,
        Consensus.Decide
      ]

      for mod <- modules do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} should be loaded"
        assert function_exported?(mod, :run, 2), "#{inspect(mod)} should export run/2"
      end
    end
  end
end
