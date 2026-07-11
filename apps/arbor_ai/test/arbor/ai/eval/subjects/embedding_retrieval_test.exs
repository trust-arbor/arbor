defmodule Arbor.AI.Eval.Subjects.EmbeddingRetrievalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.Eval.Subjects.EmbeddingRetrieval

  setup do
    path = temp_path("embedding-index")
    File.write!(path, Jason.encode!(index_fixture()))
    on_exit(fn -> File.rm(path) end)
    %{index_path: path}
  end

  test "ranks indexed actions and returns JSON-clean output", %{index_path: index_path} do
    embed_fn = fn base_url, model, prompt, timeout ->
      send(self(), {:embed, base_url, model, prompt, timeout})
      {:ok, [1.0, 0.0]}
    end

    assert {:ok, result} =
             EmbeddingRetrieval.run(%{"prompt" => "read a file"},
               index_path: index_path,
               model: "embed-model",
               top_k: 2,
               base_url: "http://embedding.test",
               timeout: 123,
               embed_fn: embed_fn
             )

    assert_receive {:embed, "http://embedding.test", "embed-model", "read a file", 123}
    assert result.text == ~s(["Arbor.Actions.FileRead","Arbor.Actions.Mixed"])

    assert [first, second] = result.retrieved
    assert first.module == "Arbor.Actions.FileRead"
    assert_in_delta first.score, 1.0, 0.001
    assert second.module == "Arbor.Actions.Mixed"
    assert result.model == "embed-model"
    assert result.provider == "ollama"
    assert is_integer(result.duration_ms) and result.duration_ms >= 0
    assert {:ok, _json} = Jason.encode(result)
  end

  test "requires an explicit index path" do
    assert EmbeddingRetrieval.run("read a file", model: "embed-model") ==
             {:error, {:missing_option, :index_path}}
  end

  test "returns shaped errors for malformed input and embedding responses", %{
    index_path: index_path
  } do
    opts = [
      index_path: index_path,
      model: "embed-model",
      embed_fn: fn _, _, _, _ -> {:ok, []} end
    ]

    assert EmbeddingRetrieval.run(%{"prompt" => 42}, opts) ==
             {:error, {:invalid_input, :prompt_required}}

    assert EmbeddingRetrieval.run("read a file", opts) ==
             {:error, {:invalid_embedding_response, :numeric_vector_required}}
  end

  test "shapes index and callback failures", %{index_path: index_path} do
    missing = temp_path("missing-index")

    assert EmbeddingRetrieval.run("read a file",
             index_path: missing,
             model: "embed-model"
           ) == {:error, {:index_read_failed, missing, :enoent}}

    assert EmbeddingRetrieval.run("read a file",
             index_path: index_path,
             model: "embed-model",
             embed_fn: fn _, _, _, _ -> raise "transport exploded" end
           ) ==
             {:error, {:embedding_callback_failed, {:exception, "transport exploded"}}}
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
