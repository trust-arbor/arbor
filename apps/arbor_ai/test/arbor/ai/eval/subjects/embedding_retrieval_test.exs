defmodule Arbor.AI.Eval.Subjects.EmbeddingRetrievalTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.Subjects.EmbeddingRetrieval

  setup do
    original = Application.get_env(:arbor_llm, :trusted_eval_endpoints)

    Application.put_env(:arbor_llm, :trusted_eval_endpoints, [
      "http://embedding.test",
      "http://ollama.test"
    ])

    path = temp_path("embedding-index")
    File.write!(path, Jason.encode!(index_fixture()))

    on_exit(fn ->
      File.rm(path)

      if is_nil(original),
        do: Application.delete_env(:arbor_llm, :trusted_eval_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_eval_endpoints, original)
    end)

    %{index_path: path}
  end

  test "ranks indexed actions and returns JSON-clean output", %{index_path: index_path} do
    parent = self()

    embed_fn = fn base_url, model, prompt, timeout ->
      send(parent, {:embed, base_url, model, prompt, timeout})
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

  test "rejects a query vector with different dimensions from the index", %{
    index_path: index_path
  } do
    assert EmbeddingRetrieval.run("read a file",
             index_path: index_path,
             model: "embed-model",
             embed_fn: fn _, _, _, _ -> {:ok, [1.0]} end
           ) ==
             {:error, {:invalid_embedding_response, {:vector_dimension_mismatch, 2, 1}}}
  end

  test "default Ollama embedding transport posts to /api/embeddings", %{
    index_path: index_path
  } do
    parent = self()

    install_req_adapter(fn request ->
      body = decode_request_body(request)
      send(parent, {:embedding_http_request, request.url.path, body})
      {request, Req.Response.new(status: 200, body: %{"embedding" => [1.0, 0.0]})}
    end)

    assert {:ok, result} =
             EmbeddingRetrieval.run("read a file",
               index_path: index_path,
               model: "embed-model",
               base_url: "http://ollama.test",
               timeout: 1_000
             )

    assert_receive {:embedding_http_request, "/api/embeddings", request_body}
    assert request_body == %{"model" => "embed-model", "prompt" => "read a file"}
    assert hd(result.retrieved).module == "Arbor.Actions.FileRead"
  end

  test "default Ollama embedding transport rejects a malformed 200 response", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      {request, Req.Response.new(status: 200, body: %{"embedding" => "not-a-vector"})}
    end)

    assert {:error, {:embedding_http_error, 200, %{body_excerpt: excerpt, truncated: true}}} =
             EmbeddingRetrieval.run("read a file",
               index_path: index_path,
               model: "embed-model",
               base_url: "http://ollama.test"
             )

    assert excerpt =~ "not-a-vector"
  end

  test "default Ollama embedding transport shapes HTTP error statuses", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      {request, Req.Response.new(status: 418, body: "embedding denied")}
    end)

    assert EmbeddingRetrieval.run("read a file",
             index_path: index_path,
             model: "embed-model",
             base_url: "http://ollama.test"
           ) ==
             {:error,
              {:embedding_http_error, 418, %{body_excerpt: "embedding denied", truncated: false}}}
  end

  test "security regression: /api/embeddings receipt halts at the byte ceiling", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      response = Req.Response.new(status: 200)

      request.into.(
        {:data, String.duplicate("x", 262_145)},
        {request, response}
      )
      |> elem(1)
    end)

    assert EmbeddingRetrieval.run("read a file",
             index_path: index_path,
             model: "embed-model",
             base_url: "http://ollama.test"
           ) == {:error, {:http_response_bytes_exceeded, 262_144}}
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

  defp install_req_adapter(adapter) do
    previous_options = Req.default_options()
    on_exit(fn -> Req.default_options(previous_options) end)
    Req.default_options(adapter: adapter)
  end

  defp decode_request_body(request) do
    request.body
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end
end
