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

    test "majority approve still surfaces security veto when security rejects" do
      results = [
        make_branch_result("security", "reject", concerns: ["path traversal"]),
        make_branch_result("correctness", "approve"),
        make_branch_result("tests", "approve")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Should we accept this low-risk diff?"},
                 %{}
               )

      assert result.decision == "approved"
      assert result.approve_count == 2
      assert result.reject_count == 1

      assert result.perspective_votes == %{
               "security" => "reject",
               "correctness" => "approve",
               "tests" => "approve"
             }

      assert result.security_veto
      assert result.vetoes == ["security"]
      assert result.primary_concerns == ["path traversal"]
    end

    test "preserves primary concerns as a JSON-clean list for review feedback" do
      concerns = ["cannot verify the related contract", "quoted \"path\" remains structured"]

      results = [
        make_branch_result("correctness", "abstain", concerns: concerns),
        make_branch_result("security", "approve")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Is the evidence sufficient?"},
                 %{}
               )

      assert result.primary_concerns == concerns
      assert {:ok, encoded} = Jason.encode(result)
      assert Jason.decode!(encoded)["primary_concerns"] == concerns
    end

    test "normalizes structured council concerns without crashing aggregation" do
      concern = %{
        "file" => "apps/arbor_actions/lib/arbor/actions/coding/review_tree.ex",
        "issue" => "Path parsing excludes a valid tracked filename"
      }

      results = [
        make_branch_result("edge_cases_error_handling", "reject", concerns: [concern]),
        make_branch_result("security", "approve")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "Does this change handle unusual Git paths?"},
                 %{}
               )

      assert [encoded_concern] = result.primary_concerns
      assert Jason.decode!(encoded_concern) == concern
      assert result.reject_count == 1
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
    test "symbolic majority excludes abstentions from the voting population" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "approve"),
        make_branch_result("d", "abstain"),
        make_branch_result("e", "abstain")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "majority"},
                 %{}
               )

      assert result.decision == "approved"
      assert result.quorum_met
      assert result.approve_count == 3
      assert result.abstain_count == 2
    end

    test "symbolic majority deadlocks on an active-vote tie despite an abstention" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "reject"),
        make_branch_result("d", "reject"),
        make_branch_result("e", "abstain")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "majority"},
                 %{}
               )

      assert result.decision == "deadlock"
      refute result.quorum_met
      assert result.approve_count == 2
      assert result.reject_count == 2
      assert result.abstain_count == 1
    end

    test "all abstentions remain a deadlock for symbolic quorum" do
      for quorum <- ["majority", "supermajority", "unanimous"] do
        results = [
          make_branch_result("a", "abstain"),
          make_branch_result("b", "abstain")
        ]

        assert {:ok, result} =
                 Consensus.Decide.run(
                   %{results: results, question: "test", quorum: quorum},
                   %{}
                 )

        assert result.decision == "deadlock"
        refute result.quorum_met
        assert result.abstain_count == 2
      end
    end

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

    test "numeric quorum remains an absolute threshold greater than active votes" do
      results = [
        make_branch_result("a", "approve"),
        make_branch_result("b", "approve"),
        make_branch_result("c", "abstain"),
        make_branch_result("d", "abstain")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "3"},
                 %{}
               )

      assert result.decision == "deadlock"
      refute result.quorum_met
      assert result.approve_count == 2
    end

    test "security rejection remains present in veto output with abstentions" do
      results = [
        make_branch_result("security", "reject"),
        make_branch_result("correctness", "approve"),
        make_branch_result("tests", "approve"),
        make_branch_result("docs", "abstain")
      ]

      assert {:ok, result} =
               Consensus.Decide.run(
                 %{results: results, question: "test", quorum: "majority"},
                 %{}
               )

      assert result.decision == "approved"
      assert result.security_veto
      assert result.vetoes == ["security"]
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
  # DecideReview — frozen review ledger
  # ============================================================================

  describe "DecideReview — strict ledger reduction" do
    @review_perspectives ["correctness", "security", "maintainability"]

    test "public parameter validation accepts checkpointed dynamic JSON" do
      params = %{
        results: [
          make_review_branch("correctness", review_report("approve"))
        ],
        review_cycle: "2",
        finding_ledger: review_ledger(),
        delta_ranges: %{"lib/example.ex" => [[4, 9]]}
      }

      assert {:ok, ^params} = Consensus.DecideReview.validate_params(params)

      for invalid <- [
            %{results: %{}},
            %{finding_ledger: []},
            %{delta_ranges: "lib/example.ex:4-9"}
          ] do
        assert {:error, %Jido.Action.Error.InvalidInputError{}} =
                 Consensus.DecideReview.validate_params(invalid)
      end
    end

    test "publishes an honest terminating schema for dynamic review JSON" do
      schema = Consensus.DecideReview.to_tool().parameters_schema

      assert schema.type == :object
      assert schema.additionalProperties == false
      assert schema.properties.results.type == :array
      assert schema.properties.results.items == %{type: :object}
      assert schema.properties.finding_ledger.type == :object
      assert schema.properties.delta_ranges.type == :object

      assert schema.properties.review_cycle.anyOf == [
               %{type: :integer},
               %{type: :string}
             ]

      refute Map.has_key?(schema.properties.results.items, :additionalProperties)
      refute Map.has_key?(schema.properties.finding_ledger, :additionalProperties)
      refute Map.has_key?(schema.properties.delta_ranges, :additionalProperties)
    end

    test "initial cycle accepts DOT input and returns JSON-clean ledger context" do
      results = [
        make_review_branch("correctness", review_report("approve")),
        make_review_branch("security", review_report("approve")),
        make_review_branch("maintainability", review_report("abstain"))
      ]

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   "parallel.results" => results,
                   "review_cycle" => "1",
                   "finding_ledger" => review_ledger()
                 },
                 %{}
               )

      assert result["decision"] == "approved"
      assert result["review_disposition"] == "accept"
      assert result["quorum_met"]
      assert result["review_cycle"] == 1

      assert result["perspective_votes"] == %{
               "correctness" => "approve",
               "security" => "approve",
               "maintainability" => "abstain"
             }

      assert result["finding_ledger"]["review_cycle"] == 1
      assert {:ok, _encoded} = Jason.encode(result)
    end

    test "applies a fixed finding on the exact next cycle" do
      finding = review_finding("must be fixed", "blocking", 10)

      assert {:ok, first} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("reject", new_findings: [finding])
                     )
                   ],
                   review_cycle: 1,
                   finding_ledger: review_ledger(),
                   delta_ranges: %{}
                 },
                 %{}
               )

      [stored] = first["findings"]

      assert {:ok, second} =
               Consensus.DecideReview.run(
                 %{
                   "parallel.results" => [
                     make_review_branch(
                       "correctness",
                       review_report("approve",
                         finding_updates: [%{"id" => stored["id"], "state" => "fixed"}]
                       )
                     ),
                     make_review_branch("security", review_report("approve")),
                     make_review_branch("maintainability", review_report("approve"))
                   ],
                   "review_cycle" => "2",
                   "finding_ledger" => first["finding_ledger"],
                   "delta_ranges" => %{}
                 },
                 %{}
               )

      assert second["decision"] == "approved"
      assert second["review_disposition"] == "accept"
      assert [fixed] = second["findings"]
      assert fixed["id"] == stored["id"]
      assert fixed["state"] == "fixed"
    end

    test "corroborated major findings block through the ledger" do
      finding = review_finding("shared major", "major", 20)

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("approve", new_findings: [finding])
                     ),
                     make_review_branch(
                       "security",
                       review_report("approve", new_findings: [finding])
                     )
                   ],
                   review_cycle: 1,
                   finding_ledger: review_ledger()
                 },
                 %{}
               )

      assert result["decision"] == "deadlock"
      assert result["review_disposition"] == "rework"
      assert result["blocking_ids"] |> length() == 2
      assert Enum.all?(result["blocking_reasons"], &(&1["reason"] == "corroborated_major"))
      refute result["human_required"]
    end

    test "independent major findings from distinct owners rework through the ledger" do
      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("approve",
                         new_findings: [review_finding("Missing blank rejection", "major", 12)]
                       )
                     ),
                     make_review_branch(
                       "security",
                       review_report("approve",
                         new_findings: [
                           review_finding("Whitespace-only returns ok empty", "major", 14)
                         ]
                       )
                     )
                   ],
                   review_cycle: 1,
                   finding_ledger: review_ledger()
                 },
                 %{}
               )

      assert result["decision"] == "deadlock"
      assert result["review_disposition"] == "rework"
      assert result["blocking_ids"] |> length() == 2

      assert Enum.all?(
               result["blocking_reasons"],
               &(&1["reason"] == "independent_major_quorum")
             )

      refute result["human_required"]
    end

    test "routes an out-of-delta new finding to the side channel" do
      assert {:ok, initial} =
               Consensus.DecideReview.run(
                 %{results: [], review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("approve",
                         new_findings: [review_finding("old code", "major", 20)]
                       )
                     )
                   ],
                   review_cycle: 2,
                   finding_ledger: initial["finding_ledger"],
                   delta_ranges: %{"lib/a.ex" => [[1, 5]]}
                 },
                 %{}
               )

      assert result["decision"] == "approved"
      assert result["findings"] == []
      assert [%{"reason" => "outside_delta", "state" => "out_of_scope"}] = result["out_of_scope"]
    end

    test "all abstentions route to human_review without consuming rework" do
      results =
        Enum.map(@review_perspectives, fn perspective ->
          make_review_branch(perspective, review_report("abstain"))
        end)

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert result["decision"] == "rejected"
      assert result["review_disposition"] == "human_review"
      assert result["human_required"]
      assert result["abstain_count"] == 3
      refute result["quorum_met"]
      assert result["blocking_reasons"] == [%{"id" => "council", "reason" => "all_abstain"}]
    end

    test "public perspective votes use severity-backed effective rejects" do
      results = [
        make_review_branch(
          "correctness",
          review_report("reject", new_findings: [review_finding("single major", "major", 20)])
        ),
        make_review_branch("security", review_report("approve")),
        make_review_branch("maintainability", review_report("approve"))
      ]

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert result["perspective_votes"]["correctness"] == "abstain"
      assert result["reject_count"] == 0
      assert result["abstain_count"] == 1
      assert result["review_disposition"] == "accept"
      assert result["finding_ledger"]["cycles"]["1"]["votes"]["correctness"] == "reject"
    end

    test "failed, malformed, and unknown reports become abstentions without prose vote inference" do
      results = [
        make_review_branch("correctness", review_report("approve")),
        make_review_branch("security", review_report("reject"), "fail"),
        make_review_branch("maintainability", "I approve this code"),
        make_review_branch("unknown", review_report("reject"))
      ]

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert result["perspective_votes"]["security"] == "abstain"
      assert result["perspective_votes"]["maintainability"] == "abstain"
      assert result["approve_count"] == 1
      assert result["abstain_count"] == 2
    end

    test "projects a security veto as rejected human review" do
      results = [
        make_review_branch("correctness", review_report("approve")),
        make_review_branch("security", review_report("reject"))
      ]

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert result["decision"] == "rejected"
      assert result["review_disposition"] == "human_review"
      assert result["security_veto"]
      assert result["human_required"]
      refute result["quorum_met"]
    end

    test "fails closed on duplicate valid perspective reports" do
      results = [
        make_review_branch("correctness", review_report("approve")),
        make_review_branch("correctness", review_report("reject"))
      ]

      assert {:error,
              %{
                "code" => "consensus_decide_review_failed",
                "reason" => "ambiguous_duplicate_perspective_report"
              }} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )
    end

    test "fails closed when a branch has conflicting exact perspective identities" do
      branch =
        make_review_branch("correctness", review_report("approve"))
        |> Map.put("perspective", "security")

      assert {:error,
              %{
                "code" => "consensus_decide_review_failed",
                "reason" => "ambiguous_branch_perspective"
              }} =
               Consensus.DecideReview.run(
                 %{results: [branch], review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )
    end

    test "accepts the exact production review.review_cycle dotted key from DOT params" do
      # ExecHandler may pass leaf names, but some nested/context maps keep the
      # production dotted key from context_keys="...,review.review_cycle,...".
      results =
        Enum.map(@review_perspectives, fn perspective ->
          make_review_branch(perspective, review_report("approve"))
        end)

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   "parallel.results" => results,
                   "review.review_cycle" => 1,
                   "review.finding_ledger" => review_ledger(),
                   "review.delta_ranges" => %{}
                 },
                 %{}
               )

      assert result["decision"] == "approved"
      assert result["review_cycle"] == 1
    end

    test "producer-to-consumer: CodeReviewRequest review.review_cycle leaf maps into DecideReview" do
      alias Arbor.Contracts.Consensus.CodeReviewRequest

      {:ok, request} =
        CodeReviewRequest.new(%{
          diff: "diff --git a/lib/a.ex b/lib/a.ex\n+def ok, do: :ok",
          files: ["lib/a.ex"],
          branch: "agent/review-loop",
          review_cycle: 1
        })

      context = CodeReviewRequest.to_context(request)
      # DOT context_keys entry emitted by the producer
      assert context["review.review_cycle"] == 1

      # ExecHandler leaf flatten of review.review_cycle → review_cycle param
      leaf = List.last(String.split("review.review_cycle", "."))
      assert leaf == "review_cycle"

      results =
        Enum.map(@review_perspectives, fn perspective ->
          make_review_branch(perspective, review_report("approve"))
        end)

      # Params as ExecHandler would build them from context_keys values
      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{
                   "results" => results,
                   leaf => context["review.review_cycle"],
                   "finding_ledger" => review_ledger(),
                   "delta_ranges" => %{}
                 },
                 %{}
               )

      assert result["review_cycle"] == 1
      assert result["decision"] == "approved"
    end

    test "prose and fenced JSON last_response remain abstentions (strict Jason.decode)" do
      # DecideReview intentionally exact-decodes JSON. Fenced markdown or prose
      # plus JSON must not be scraped or inferred into a vote.
      fenced = """
      Here is my review:

      ```json
      {"vote":"reject","finding_updates":[],"new_findings":[]}
      ```
      """

      results = [
        make_review_branch("correctness", review_report("approve")),
        make_review_branch("security", fenced),
        make_review_branch("maintainability", "I reject this change.")
      ]

      assert {:ok, result} =
               Consensus.DecideReview.run(
                 %{results: results, review_cycle: 1, finding_ledger: review_ledger()},
                 %{}
               )

      assert result["perspective_votes"]["security"] == "abstain"
      assert result["perspective_votes"]["maintainability"] == "abstain"
      assert result["approve_count"] == 1
      assert result["reject_count"] == 0
    end

    test "fails closed on invalid cycle, ledger, and delta ranges" do
      assert {:error, %{"reason" => "invalid_review_cycle"}} =
               Consensus.DecideReview.run(
                 %{results: [], review_cycle: "01", finding_ledger: review_ledger()},
                 %{}
               )

      assert {:error, %{"reason" => "invalid_finding_ledger"}} =
               Consensus.DecideReview.run(
                 %{results: [], review_cycle: 1, finding_ledger: %{"version" => "forged"}},
                 %{}
               )

      assert {:error, %{"reason" => "invalid_delta_ranges"}} =
               Consensus.DecideReview.run(
                 %{
                   results: [],
                   review_cycle: 1,
                   finding_ledger: review_ledger(),
                   delta_ranges: %{"lib/a.ex" => [[1, 1], [1, 2]]}
                 },
                 %{}
               )
    end

    test "does not change generic consensus text vote behavior" do
      results = [
        make_text_result("security", "I approve of this design."),
        make_text_result("stability", "I approve with reservations.")
      ]

      assert {:ok, %{decision: "approved"}} =
               Consensus.Decide.run(%{results: results, question: "generic behavior"}, %{})
    end

    test "mixed recheck reports drop foreign finding ids and keep complete same-owner fixes" do
      # Reproduces task_45506: two perspectives approve with all own findings fixed
      # but each also copies one foreign finding id. Pre-fix this rejected both
      # useful reports, left stale blockers, and routed rework → worker_turn_no_progress.
      assert {:ok, first} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("reject",
                         new_findings: [review_finding("contract issue", "blocking", 10)]
                       )
                     ),
                     make_review_branch(
                       "security",
                       review_report("reject",
                         new_findings: [review_finding("perf issue", "blocking", 20)]
                       )
                     ),
                     make_review_branch(
                       "maintainability",
                       review_report("reject",
                         new_findings: [review_finding("docs issue", "blocking", 30)]
                       )
                     )
                   ],
                   review_cycle: 1,
                   finding_ledger: review_ledger()
                 },
                 %{}
               )

      findings_by_owner =
        Map.new(first["findings"], fn finding -> {finding["owner"], finding} end)

      correctness_id = findings_by_owner["correctness"]["id"]
      security_id = findings_by_owner["security"]["id"]
      maintainability_id = findings_by_owner["maintainability"]["id"]

      assert {:ok, second} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("approve",
                         finding_updates: [
                           %{"id" => correctness_id, "state" => "fixed"},
                           # Foreign docs/maintainability id — projected away.
                           %{"id" => maintainability_id, "state" => "fixed"}
                         ]
                       )
                     ),
                     make_review_branch(
                       "security",
                       review_report("approve",
                         finding_updates: [
                           %{"id" => security_id, "state" => "fixed"},
                           # Foreign correctness id — projected away.
                           %{"id" => correctness_id, "state" => "fixed"}
                         ]
                       )
                     ),
                     make_review_branch(
                       "maintainability",
                       review_report("approve",
                         finding_updates: [
                           %{"id" => maintainability_id, "state" => "fixed"}
                         ]
                       )
                     )
                   ],
                   review_cycle: 2,
                   finding_ledger: first["finding_ledger"],
                   delta_ranges: %{}
                 },
                 %{}
               )

      assert second["decision"] == "approved"
      assert second["review_disposition"] == "accept"
      assert Enum.all?(second["findings"], &(&1["state"] == "fixed"))
      assert second["perspective_votes"]["correctness"] == "approve"
      assert second["perspective_votes"]["security"] == "approve"
      assert second["perspective_votes"]["maintainability"] == "approve"
    end

    test "incomplete same-owner recheck reports abstain; unconfirmed blockers go human_review" do
      assert {:ok, first} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("reject",
                         new_findings: [review_finding("must fix", "blocking", 10)]
                       )
                     ),
                     make_review_branch("security", review_report("approve")),
                     make_review_branch("maintainability", review_report("approve"))
                   ],
                   review_cycle: 1,
                   finding_ledger: review_ledger()
                 },
                 %{}
               )

      [stored] = first["findings"]

      # Incomplete report (omits owned active finding) becomes abstention.
      assert {:ok, incomplete} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch("correctness", review_report("approve")),
                     make_review_branch("security", review_report("approve")),
                     make_review_branch("maintainability", review_report("approve"))
                   ],
                   review_cycle: 2,
                   finding_ledger: first["finding_ledger"],
                   delta_ranges: %{}
                 },
                 %{}
               )

      assert incomplete["perspective_votes"]["correctness"] == "abstain"
      assert incomplete["findings"] |> hd() |> Map.get("state") == "open"
      assert incomplete["review_disposition"] == "human_review"
      assert incomplete["human_required"]

      assert incomplete["blocking_reasons"] == [
               %{"id" => stored["id"], "reason" => "unconfirmed_blocker"}
             ]

      # Explicit reconfirm of the blocker still routes rework.
      assert {:ok, reconfirmed} =
               Consensus.DecideReview.run(
                 %{
                   results: [
                     make_review_branch(
                       "correctness",
                       review_report("reject",
                         finding_updates: [%{"id" => stored["id"], "state" => "open"}]
                       )
                     ),
                     make_review_branch("security", review_report("approve")),
                     make_review_branch("maintainability", review_report("approve"))
                   ],
                   review_cycle: 2,
                   finding_ledger: first["finding_ledger"],
                   delta_ranges: %{}
                 },
                 %{}
               )

      assert reconfirmed["review_disposition"] == "rework"

      assert reconfirmed["blocking_reasons"] == [
               %{"id" => stored["id"], "reason" => "active_blocking"}
             ]

      refute reconfirmed["human_required"]
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
        Consensus.Decide,
        Consensus.DecideReview
      ]

      for mod <- modules do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} should be loaded"
        assert function_exported?(mod, :run, 2), "#{inspect(mod)} should export run/2"
      end
    end
  end

  defp make_review_branch(perspective, report, status \\ "success") do
    %{
      "id" => perspective,
      "status" => status,
      "context_updates" => %{
        "last_response" => if(is_binary(report), do: report, else: Jason.encode!(report))
      }
    }
  end

  defp review_ledger, do: %{"perspectives" => @review_perspectives}

  defp review_report(vote, opts \\ []) do
    Map.merge(%{"vote" => vote, "finding_updates" => [], "new_findings" => []}, Map.new(opts))
  end

  defp review_finding(title, severity, line) do
    %{
      "title" => title,
      "required_action" => "Address #{title}",
      "severity" => severity,
      "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => line}
    }
  end

  # ============================================================================
  # H5 security regression — unsafe String.to_atom in branch/perspective id
  # ============================================================================
  #
  # H5 (SECURITY_REVIEW 2026-02-16): branch IDs (perspectives) ultimately derive
  # from externally-sourced parallel-branch results. The fix replaced
  # `String.to_atom/1` with `safe_perspective_atom/1`
  # (`String.to_existing_atom` + rescue -> :adversarial), so an attacker-supplied
  # branch id can never mint a fresh atom (atom-exhaustion DoS).
  #
  # These tests drive the public Decide.run/2 action — which routes
  # results -> parse_vote_result -> sanitize_perspective -> safe_perspective_atom.
  # If safe_perspective_atom is reverted to String.to_atom, the unknown branch id
  # gets interned and `String.to_existing_atom/1` no longer raises -> RED.
  describe "H5 security regression — perspective atom not minted from untrusted branch id" do
    test "an unknown branch id does NOT create a new atom" do
      # Alphanumeric + underscore so it survives sanitize_perspective unchanged;
      # unique so it cannot already exist in the atom table.
      unknown_id = "h5_unknown_perspective_#{System.unique_integer([:positive])}"

      # Precondition: the atom must not already exist (otherwise the test proves nothing).
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_id) end

      results = [
        %{
          "id" => unknown_id,
          "context_updates" => %{"last_response" => "vote: approve, confidence 0.8"}
        }
      ]

      assert {:ok, _decision} = Consensus.Decide.run(%{results: results, quorum: "majority"}, %{})

      # The security invariant: the untrusted branch id was NOT interned as an atom.
      # With the unsafe String.to_atom this raise would NOT happen (atom now exists) -> failure.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_id) end
    end

    test "atom table does not grow by the untrusted branch id across the action" do
      unknown_id = "h5_atom_growth_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_id) end

      results = [
        %{
          "id" => unknown_id,
          "context_updates" => %{"last_response" => "vote: reject, confidence 0.5"}
        }
      ]

      assert {:ok, _} = Consensus.Decide.run(%{results: results, quorum: "majority"}, %{})

      # Even after a second run with the SAME untrusted id, it is still not an atom.
      assert {:ok, _} = Consensus.Decide.run(%{results: results, quorum: "majority"}, %{})
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_id) end
    end
  end
end
