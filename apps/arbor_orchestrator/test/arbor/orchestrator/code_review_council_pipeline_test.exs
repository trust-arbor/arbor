defmodule Arbor.Orchestrator.CodeReviewCouncilPipelineTest do
  use ExUnit.Case, async: true

  @moduletag :code_review_council
  @moduletag :fast

  @reviewers %{
    "correctness" => {"openai_oauth", "gpt-5.6-sol"},
    "security" => {"openai_oauth", "gpt-5.6-sol"},
    "regression_test_coverage" => {"ollama", "kimi-k2.7-code:cloud"},
    "edge_cases_error_handling" => {"ollama", "kimi-k2.7-code:cloud"},
    "simplicity_yagni_scope" => {"xai_oauth", "grok-4.5"},
    "readability_maintainability" => {"xai_oauth", "grok-4.5"},
    "contract_api_compat" => {"ollama", "glm-5.2:cloud"},
    "architecture_grain_fit" => {"ollama", "glm-5.2:cloud"},
    "performance_resource" => {"ollama", "minimax-m3:cloud"},
    "docs_naming" => {"ollama", "minimax-m3:cloud"}
  }

  defp load_graph do
    {:ok, %{source: dot_content}} = Arbor.Actions.reviewed_pipeline("code_review_council")
    assert {:ok, graph} = Arbor.Orchestrator.parse(dot_content)
    graph
  end

  describe "code-review-council.dot graph structure" do
    test "parses with the expected node count" do
      graph = load_graph()

      # start + evaluate + 10 reviewers + collect + decide + done
      assert map_size(graph.nodes) == 15
      assert graph.attrs["mode"] == "decision"
      assert graph.attrs["goal"] =~ "coding-agent branch"
    end

    test "fans out to all 10 configured review perspectives" do
      graph = load_graph()
      evaluate = graph.nodes["evaluate"]

      assert map_size(@reviewers) == 10
      assert evaluate.attrs["type"] == "parallel"
      assert evaluate.attrs["join_policy"] == "wait_all"
      assert evaluate.attrs["error_policy"] == "continue"
      assert evaluate.attrs["max_parallel"] == "10"
      assert evaluate.attrs["join_target"] == "collect"

      for {reviewer, {provider, model}} <- @reviewers do
        node = graph.nodes[reviewer]
        assert node, "Missing reviewer node #{reviewer}"
        assert node.attrs["type"] == "compute"
        assert node.attrs["purpose"] == "llm"
        assert node.attrs["simulate"] == "false"
        assert node.attrs["use_tools"] == "true"

        assert node.attrs["tools"] ==
                 "coding_review_tree_read,coding_review_tree_search,coding_submit_review_report"

        assert node.attrs["terminal_tools"] == "coding_submit_review_report"

        assert node.attrs["max_turns"] == "3"
        assert node.attrs["prompt_is_data"] == "true"
        assert node.attrs["llm_provider"] == provider
        assert node.attrs["llm_model"] == model
        assert node.attrs["prompt_context_key"] == "review.prompt"
        refute Map.has_key?(node.attrs, "max_tokens")
      end
    end

    test "reviewer prompts require terminal coding_submit_review_report submission" do
      graph = load_graph()

      for reviewer <- Map.keys(@reviewers) do
        prompt = graph.nodes[reviewer].attrs["system_prompt"]

        assert prompt =~
                 "call coding_submit_review_report exactly once with vote, finding_updates, and new_findings"

        assert prompt =~ "do not emit free-form JSON text or fenced JSON as the final answer"
        assert prompt =~ "existing same-owner ledger id"
        assert prompt =~ "state fixed, open, or architectural_blocker"
        assert prompt =~ "severity blocking, major, minor, or nit"
        assert prompt =~ "anchor has exactly path, side, and line"
        assert prompt =~ "side is new or old"
        assert prompt =~ "optional state only architectural_blocker"
        assert prompt =~ "Max 8 total entries across finding_updates and new_findings"
        assert prompt =~ "Review only the candidate intent and diff"

        assert prompt =~
                 "tree read/search tools are context, not permission to veto pre-existing issues"

        assert prompt =~ "On review cycle >= 2, verify your owned open ledger findings"
        assert prompt =~ "inspect only the explicit delta_ranges for new regressions"
        assert prompt =~ "Do not reject or submit new_findings for issues outside that delta"
        assert prompt =~ "supported blocking/architectural finding"
        assert prompt =~ "record major findings, but a major alone does not justify reject"
        assert prompt =~ "corroborated majors block through ledger aggregation"
        refute prompt =~ "materially supported major finding"
        assert prompt =~ "Minor/nit do not reject"
        assert prompt =~ "Approve when no blocking issue remains in this perspective"
        assert prompt =~ "Abstain when evidence is insufficient or you cannot meet this contract"
      end

      security_prompt = graph.nodes["security"].attrs["system_prompt"]
      assert security_prompt =~ "fail-open"
      assert security_prompt =~ "actual security veto"

      assert graph.nodes["regression_test_coverage"].attrs["system_prompt"] =~
               "Security bug fixes must include"

      assert graph.nodes["architecture_grain_fit"].attrs["system_prompt"] =~ "DOT graph"
    end

    test "collects reviews and calls the strict frozen-ledger decision action" do
      graph = load_graph()

      assert graph.nodes["collect"].attrs["type"] == "parallel.fan_in"

      decide = graph.nodes["decide"]
      assert decide.attrs["type"] == "exec"
      assert decide.attrs["target"] == "action"
      assert decide.attrs["action"] == "consensus_decide_review"

      assert decide.attrs["context_keys"] ==
               "parallel.results,review.review_cycle,review.finding_ledger,review.delta_ranges"

      refute Map.has_key?(decide.attrs, "param.quorum")
      refute Map.has_key?(decide.attrs, "param.mode")
      assert decide.attrs["output_prefix"] == "council"
    end

    test "edges connect start to fan-out, reviewers to collect, and collect to decide" do
      graph = load_graph()
      edge_pairs = graph.edges |> Enum.map(&{&1.from, &1.to}) |> MapSet.new()

      assert MapSet.member?(edge_pairs, {"start", "evaluate"})

      for reviewer <- Map.keys(@reviewers) do
        assert MapSet.member?(edge_pairs, {"evaluate", reviewer}),
               "Missing edge: evaluate -> #{reviewer}"

        assert MapSet.member?(edge_pairs, {reviewer, "collect"}),
               "Missing edge: #{reviewer} -> collect"
      end

      assert MapSet.member?(edge_pairs, {"collect", "decide"})
      assert MapSet.member?(edge_pairs, {"decide", "done"})
    end
  end
end
