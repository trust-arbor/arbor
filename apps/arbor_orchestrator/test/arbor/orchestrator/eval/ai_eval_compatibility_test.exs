defmodule Arbor.Orchestrator.Eval.AIEvalCompatibilityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-orchestrator-ai-eval-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(path, Jason.encode!(index_fixture()))
    on_exit(fn -> File.rm(path) end)
    %{index_path: path}
  end

  test "retrieval subject wrappers preserve canonical results", %{index_path: index_path} do
    embed_fn = fn _, _, _, _ -> {:ok, [1.0, 0.0]} end

    router_fn = fn _, _, _, _, _ ->
      {:ok, Jason.encode!(%{"selected" => ["Arbor.Actions.Shell"]})}
    end

    cases = [
      {Arbor.Orchestrator.Eval.Subjects.EmbeddingRetrieval,
       Arbor.AI.Eval.Subjects.EmbeddingRetrieval,
       [index_path: index_path, model: "embed-model", embed_fn: embed_fn]},
      {Arbor.Orchestrator.Eval.Subjects.LLMRouter, Arbor.AI.Eval.Subjects.LLMRouter,
       [index_path: index_path, model: "router-model", router_fn: router_fn]},
      {Arbor.Orchestrator.Eval.Subjects.HybridRetrieval, Arbor.AI.Eval.Subjects.HybridRetrieval,
       [
         index_path: index_path,
         model: "router-model",
         embed_model: "embed-model",
         embed_fn: embed_fn,
         router_fn: router_fn
       ]}
    ]

    for {compatibility, canonical, opts} <- cases do
      assert {:ok, compatibility_result} = compatibility.run("run a command", opts)
      assert {:ok, canonical_result} = canonical.run("run a command", opts)

      assert Map.delete(compatibility_result, :duration_ms) ==
               Map.delete(canonical_result, :duration_ms)

      assert is_integer(compatibility_result.duration_ms)
      assert is_integer(canonical_result.duration_ms)
    end
  end

  test "grader wrappers preserve canonical results" do
    embedding_opts = [embed_fn: fn _, _, _, _ -> {:ok, [[1.0, 0.0], [0.8, 0.2]]} end]

    assert Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarity.grade(
             "actual",
             "expected",
             embedding_opts
           ) ==
             Arbor.AI.Eval.Graders.EmbeddingSimilarity.grade(
               "actual",
               "expected",
               embedding_opts
             )

    assert Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarity.cosine_similarity(
             [1.0, 0.0],
             [0.0, 1.0]
           ) ==
             Arbor.AI.Eval.Graders.EmbeddingSimilarity.cosine_similarity(
               [1.0, 0.0],
               [0.0, 1.0]
             )

    judge_response =
      Jason.encode!(%{
        "phase_coverage" => 1.0,
        "decision_fidelity" => 1.0,
        "loop_correctness" => 1.0,
        "error_handling" => 1.0,
        "handler_types" => 1.0,
        "prompt_relevance" => 1.0,
        "overall" => 1.0
      })

    intent_opts = [
      sample_input: "A workflow",
      judge_fn: fn _, _, _, _, _ -> {:ok, judge_response} end
    ]

    assert Arbor.Orchestrator.Eval.Graders.IntentConformance.grade(
             "digraph {}",
             nil,
             intent_opts
           ) ==
             Arbor.AI.Eval.Graders.IntentConformance.grade("digraph {}", nil, intent_opts)
  end

  test "compatibility subjects restore the index path omitted by the unchanged eval caller", %{
    index_path: index_path
  } do
    previous_path = Application.fetch_env(:arbor_orchestrator, :eval_retrieval_index_path)
    Application.put_env(:arbor_orchestrator, :eval_retrieval_index_path, index_path)

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:arbor_orchestrator, :eval_retrieval_index_path, path)
        :error -> Application.delete_env(:arbor_orchestrator, :eval_retrieval_index_path)
      end
    end)

    query_vector = [1.0, 0.0]
    embed_fn = fn _, _, _, _ -> {:ok, query_vector} end

    router_fn = fn _, _, _, _, _ ->
      {:ok, Jason.encode!(%{"selected" => ["Arbor.Actions.Shell"]})}
    end

    caller_opts = [
      provider: "ollama",
      domain: "preprocessor_tool_retrieval",
      timeout: 60_000,
      stream: false,
      domain_system_prompt: nil
    ]

    cases = [
      {Arbor.Orchestrator.Eval.Subjects.EmbeddingRetrieval,
       caller_opts ++ [model: "embed-model", embed_fn: embed_fn]},
      {Arbor.Orchestrator.Eval.Subjects.LLMRouter,
       caller_opts ++ [model: "router-model", router_fn: router_fn]},
      {Arbor.Orchestrator.Eval.Subjects.HybridRetrieval,
       caller_opts ++
         [
           model: "router-model",
           embed_model: "embed-model",
           embed_fn: embed_fn,
           router_fn: router_fn
         ]}
    ]

    for {subject, opts} <- cases do
      assert {:ok, result} = subject.run("manage an ACP session", opts)
      assert Jason.decode!(result.text) != []
      assert result.retrieved != []
    end
  end

  defp index_fixture do
    %{
      "actions" => [
        %{
          "module" => "Arbor.Actions.FileRead",
          "description" => "Read files from disk",
          "embeddings" => %{"embed-model" => [1.0, 0.0]}
        },
        %{
          "module" => "Arbor.Actions.Shell",
          "description" => "Run shell commands",
          "embeddings" => %{"embed-model" => [0.0, 1.0]}
        }
      ]
    }
  end
end
