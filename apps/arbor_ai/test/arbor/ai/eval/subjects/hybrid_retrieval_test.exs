defmodule Arbor.AI.Eval.Subjects.HybridRetrievalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.Eval.Subjects.HybridRetrieval

  setup do
    path = temp_path("hybrid-index")
    File.write!(path, Jason.encode!(index_fixture()))
    on_exit(fn -> File.rm(path) end)
    %{index_path: path}
  end

  test "reranks embedding candidates, backfills, and returns JSON-clean output", %{
    index_path: index_path
  } do
    embed_fn = fn _base_url, "embed-model", "read then run", _timeout ->
      {:ok, [1.0, 0.0]}
    end

    router_fn = fn _base_url, "router-model", system_prompt, "read then run", _timeout ->
      send(self(), {:rerank_prompt, system_prompt})

      {:ok,
       Jason.encode!(%{
         "selected" => ["Arbor.Actions.Shell", "Untrusted.Dynamic.Module"]
       })}
    end

    assert {:ok, result} =
             HybridRetrieval.run(%{"prompt" => "read then run"},
               index_path: index_path,
               model: "router-model",
               embed_model: "embed-model",
               candidate_k: 3,
               top_k: 2,
               embed_fn: embed_fn,
               router_fn: router_fn
             )

    assert_receive {:rerank_prompt, system_prompt}
    assert system_prompt =~ "Arbor.Actions.FileRead"
    assert system_prompt =~ "Arbor.Actions.Shell"

    assert [llm_pick, backfill] = result.retrieved
    assert llm_pick == %{module: "Arbor.Actions.Shell", score: nil, source: :llm}
    assert backfill.module == "Arbor.Actions.FileRead"
    assert backfill.source == :embed
    assert_in_delta backfill.score, 1.0, 0.001
    assert result.text == ~s(["Arbor.Actions.Shell","Arbor.Actions.FileRead"])
    assert result.model == "router-model"
    assert is_integer(result.duration_ms) and result.duration_ms >= 0
    assert {:ok, _json} = Jason.encode(result)
  end

  test "requires an explicit index path" do
    assert HybridRetrieval.run("read then run", model: "router-model") ==
             {:error, {:missing_option, :index_path}}
  end

  test "returns shaped errors for malformed input and recall failure", %{
    index_path: index_path
  } do
    opts = [
      index_path: index_path,
      model: "router-model",
      embed_model: "embed-model",
      embed_fn: fn _, _, _, _ -> {:error, :offline} end,
      router_fn: fn _, _, _, _, _ -> {:ok, ~s({"selected": []})} end
    ]

    assert HybridRetrieval.run(%{prompt: "wrong key"}, opts) ==
             {:error, {:invalid_input, :prompt_required}}

    assert HybridRetrieval.run("read then run", opts) ==
             {:error, {:recall_failed, :offline}}
  end

  test "returns shaped rerank errors", %{index_path: index_path} do
    assert HybridRetrieval.run("read then run",
             index_path: index_path,
             model: "router-model",
             embed_model: "embed-model",
             embed_fn: fn _, _, _, _ -> {:ok, [1.0, 0.0]} end,
             router_fn: fn _, _, _, _, _ -> {:error, :offline} end
           ) == {:error, {:rerank_failed, :offline}}
  end

  test "rejects malformed reranker JSON instead of silently backfilling", %{
    index_path: index_path
  } do
    assert HybridRetrieval.run("read then run",
             index_path: index_path,
             model: "router-model",
             embed_model: "embed-model",
             embed_fn: fn _, _, _, _ -> {:ok, [1.0, 0.0]} end,
             router_fn: fn _, _, _, _, _ -> {:ok, "not-json"} end
           ) ==
             {:error, {:rerank_failed, {:invalid_router_response, :malformed_json}}}
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
        },
        %{
          "module" => "Arbor.Actions.Mixed",
          "description" => "Read files and inspect commands",
          "embeddings" => %{"embed-model" => [0.8, 0.2]}
        }
      ]
    }
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor-ai-#{label}-#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end
end
