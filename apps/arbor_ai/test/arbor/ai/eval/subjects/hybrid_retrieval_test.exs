defmodule Arbor.AI.Eval.Subjects.HybridRetrievalTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.Subjects.HybridRetrieval

  setup do
    original = Application.get_env(:arbor_llm, :trusted_eval_endpoints)
    Application.put_env(:arbor_llm, :trusted_eval_endpoints, ["http://ollama.test"])

    path = temp_path("hybrid-index")
    File.write!(path, Jason.encode!(index_fixture()))

    on_exit(fn ->
      File.rm(path)

      if is_nil(original),
        do: Application.delete_env(:arbor_llm, :trusted_eval_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_eval_endpoints, original)
    end)

    %{index_path: path}
  end

  test "reranks embedding candidates, backfills, and returns JSON-clean output", %{
    index_path: index_path
  } do
    parent = self()

    embed_fn = fn _base_url, "embed-model", "read then run", _timeout ->
      {:ok, [1.0, 0.0]}
    end

    router_fn = fn _base_url, "router-model", system_prompt, "read then run", _timeout ->
      send(parent, {:rerank_prompt, system_prompt})

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

  test "security regression: embedding and rerank share one end-to-end deadline", %{
    index_path: index_path
  } do
    parent = self()

    embed_fn = fn _, _, _, _ ->
      send(parent, :hybrid_embedding_started)
      Process.sleep(35)
      {:ok, [1.0, 0.0]}
    end

    router_fn = fn _, _, _, _, _ ->
      send(parent, :hybrid_rerank_started)
      Process.sleep(35)
      {:ok, ~s({"selected":["Arbor.Actions.FileRead"]})}
    end

    started = System.monotonic_time(:millisecond)

    assert HybridRetrieval.run("read then run",
             index_path: index_path,
             model: "router-model",
             embed_model: "embed-model",
             timeout: 50,
             embed_fn: embed_fn,
             router_fn: router_fn
           ) == {:error, {:hybrid_deadline_exceeded, 50}}

    assert_receive :hybrid_embedding_started
    assert_receive :hybrid_rerank_started
    assert System.monotonic_time(:millisecond) - started < 150
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

  test "default Ollama hybrid transport exercises embeddings and chat endpoints", %{
    index_path: index_path
  } do
    parent = self()

    install_req_adapter(fn request ->
      body = decode_request_body(request)
      send(parent, {:hybrid_http_request, request.url.path, body})

      response_body =
        case request.url.path do
          "/api/embeddings" ->
            %{"embedding" => [1.0, 0.0]}

          "/api/chat" ->
            %{"message" => %{"content" => ~s({"selected":["Arbor.Actions.Shell"]})}}
        end

      {request, Req.Response.new(status: 200, body: response_body)}
    end)

    assert {:ok, result} =
             HybridRetrieval.run("read then run",
               index_path: index_path,
               model: "router-model",
               embed_model: "embed-model",
               base_url: "http://ollama.test",
               top_k: 2,
               timeout: 1_000
             )

    assert_receive {:hybrid_http_request, "/api/embeddings", embedding_body}
    assert embedding_body == %{"model" => "embed-model", "prompt" => "read then run"}
    assert_receive {:hybrid_http_request, "/api/chat", chat_body}
    assert chat_body["model"] == "router-model"
    assert hd(result.retrieved) == %{module: "Arbor.Actions.Shell", score: nil, source: :llm}
  end

  test "default Ollama hybrid transport rejects malformed embedding responses", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      case request.url.path do
        "/api/embeddings" ->
          {request, Req.Response.new(status: 200, body: %{"embedding" => "invalid"})}

        "/api/chat" ->
          flunk("chat endpoint should not run after malformed embedding response")
      end
    end)

    assert {:error,
            {:recall_failed,
             {:embedding_http_error, 200, %{body_excerpt: excerpt, truncated: true}}}} =
             HybridRetrieval.run("read then run",
               index_path: index_path,
               model: "router-model",
               embed_model: "embed-model",
               base_url: "http://ollama.test"
             )

    assert excerpt =~ "invalid"
  end

  test "default Ollama hybrid transport rejects malformed chat responses", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      response_body =
        case request.url.path do
          "/api/embeddings" -> %{"embedding" => [1.0, 0.0]}
          "/api/chat" -> %{"message" => %{"content" => []}}
        end

      {request, Req.Response.new(status: 200, body: response_body)}
    end)

    assert {:error,
            {:rerank_failed, {:router_http_error, 200, %{body_excerpt: excerpt, truncated: true}}}} =
             HybridRetrieval.run("read then run",
               index_path: index_path,
               model: "router-model",
               embed_model: "embed-model",
               base_url: "http://ollama.test"
             )

    assert excerpt =~ "message"
  end

  test "default Ollama hybrid transport shapes HTTP error statuses", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      {request, Req.Response.new(status: 418, body: "hybrid denied")}
    end)

    assert HybridRetrieval.run("read then run",
             index_path: index_path,
             model: "router-model",
             embed_model: "embed-model",
             base_url: "http://ollama.test"
           ) ==
             {:error,
              {:recall_failed,
               {:embedding_http_error, 418, %{body_excerpt: "hybrid denied", truncated: false}}}}
  end

  test "default Ollama hybrid chat transport shapes HTTP error statuses", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      case request.url.path do
        "/api/embeddings" ->
          {request, Req.Response.new(status: 200, body: %{"embedding" => [1.0, 0.0]})}

        "/api/chat" ->
          {request, Req.Response.new(status: 418, body: "rerank denied")}
      end
    end)

    assert HybridRetrieval.run("read then run",
             index_path: index_path,
             model: "router-model",
             embed_model: "embed-model",
             base_url: "http://ollama.test"
           ) ==
             {:error,
              {:rerank_failed,
               {:router_http_error, 418, %{body_excerpt: "rerank denied", truncated: false}}}}
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
