defmodule Arbor.Orchestrator.CodeReviewCouncilPipelineTest do
  use ExUnit.Case, async: true

  @moduletag :code_review_council
  @moduletag :fast

  @pipeline_path "apps/arbor_orchestrator/specs/pipelines/code-review-council.dot"

  @reviewers %{
    "correctness" => {"openai_oauth", "gpt-5.5"},
    "security" => {"openai_oauth", "gpt-5.5"},
    "regression_test_coverage" => {"ollama", "kimi-k2.7-code:cloud"},
    "edge_cases_error_handling" => {"ollama", "kimi-k2.7-code:cloud"},
    "simplicity_yagni_scope" => {"xai_oauth", "grok-4.3"},
    "readability_maintainability" => {"xai_oauth", "grok-4.3"},
    "contract_api_compat" => {"ollama", "glm-5.2:cloud"},
    "architecture_grain_fit" => {"ollama", "glm-5.2:cloud"},
    "performance_resource" => {"ollama", "minimax-m3:cloud"},
    "docs_naming" => {"ollama", "minimax-m3:cloud"}
  }

  defp load_graph do
    path =
      [@pipeline_path, "../arbor_orchestrator/specs/pipelines/code-review-council.dot"]
      |> Enum.find(@pipeline_path, &File.exists?/1)

    dot_content = File.read!(path)
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
        assert node.attrs["use_tools"] == "false"
        assert node.attrs["llm_provider"] == provider
        assert node.attrs["llm_model"] == model
        assert node.attrs["prompt_context_key"] == "review.prompt"
        refute Map.has_key?(node.attrs, "max_tokens")
      end
    end

    test "reviewer prompts require consensus-compatible JSON votes" do
      graph = load_graph()

      for reviewer <- Map.keys(@reviewers) do
        prompt = graph.nodes[reviewer].attrs["system_prompt"]

        assert prompt =~ "vote"
        assert prompt =~ "reasoning"
        assert prompt =~ "confidence"
        assert prompt =~ "concerns"
        assert prompt =~ "risk_score"
        assert prompt =~ "Return only a JSON object"
      end

      assert graph.nodes["security"].attrs["system_prompt"] =~ "fail-open"

      assert graph.nodes["regression_test_coverage"].attrs["system_prompt"] =~
               "Security bug fixes must include"

      assert graph.nodes["architecture_grain_fit"].attrs["system_prompt"] =~ "DOT graph"
    end

    test "collects reviews and calls consensus.decide in decision mode" do
      graph = load_graph()

      assert graph.nodes["collect"].attrs["type"] == "parallel.fan_in"

      decide = graph.nodes["decide"]
      assert decide.attrs["type"] == "exec"
      assert decide.attrs["target"] == "action"
      assert decide.attrs["action"] == "consensus.decide"
      assert decide.attrs["param.quorum"] == "majority"
      assert decide.attrs["param.mode"] == "decision"
      assert decide.attrs["context_keys"] == "parallel.results,council.question"
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
