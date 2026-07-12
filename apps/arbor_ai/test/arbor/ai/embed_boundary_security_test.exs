defmodule Arbor.AI.EmbedBoundarySecurityTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.Client

  @moduletag :fast
  @bridge_client_key {Arbor.AI.UnifiedBridge, :client}

  setup do
    original_bridge_client = :persistent_term.get(@bridge_client_key, :missing)
    original_openai = Application.get_env(:arbor_ai, :openai)
    original_ollama = Application.get_env(:arbor_ai, :ollama)
    original_orchestrator_ollama = Application.get_env(:arbor_orchestrator, :ollama)
    original_trusted = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)

    :persistent_term.put(@bridge_client_key, Client.new())

    on_exit(fn ->
      restore_env(:arbor_ai, :openai, original_openai)
      restore_env(:arbor_ai, :ollama, original_ollama)
      restore_env(:arbor_orchestrator, :ollama, original_orchestrator_ollama)
      restore_env(:arbor_llm, :trusted_proxy_endpoints, original_trusted)

      case original_bridge_client do
        :missing -> :persistent_term.erase(@bridge_client_key)
        client -> :persistent_term.put(@bridge_client_key, client)
      end
    end)

    :ok
  end

  test "security regression: public OpenAI fallback rejects duplicate authoritative indices" do
    body = %{
      "data" => [
        %{"index" => 0, "embedding" => [1.0, 0.0]},
        %{"index" => 0, "embedding" => [0.0, 1.0]}
      ],
      "model" => "text-embedding-3-small",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }

    {base_url, server} = start_json_server(body)
    trust_openai(base_url)

    assert {:error, reason} =
             Arbor.AI.embed_batch(["first", "second"],
               provider: :openai,
               model: "text-embedding-3-small",
               api_key: "test-key",
               timeout_ms: 500
             )

    assert inspect(reason) =~ "duplicate_embedding_index"
    assert_receive {:embedding_request, ^server, "/v1/embeddings"}
  end

  test "security regression: public legacy embedding never contacts an untrusted endpoint" do
    body = %{
      "data" => [%{"index" => 0, "embedding" => [1.0]}],
      "model" => "test-embed",
      "usage" => %{}
    }

    {base_url, server} = start_json_server(body)
    Application.put_env(:arbor_ai, :openai, base_url: base_url)
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{})

    assert {:error, reason} =
             Arbor.AI.embed_batch(["secret"],
               provider: :openai,
               model: "test-embed",
               api_key: "test-key",
               timeout_ms: 200
             )

    assert inspect(reason) =~ "endpoint_origin_not_trusted"
    refute_receive {:embedding_request, ^server, _path}, 100
  end

  test "security regression: public Ollama fallback rejects ambiguous positional batches" do
    body = %{
      "embeddings" => [[1.0, 0.0], [0.0, 1.0]],
      "model" => "nomic-embed-text"
    }

    {base_url, server} = start_json_server(body)
    Application.put_env(:arbor_ai, :ollama, base_url: base_url)
    Application.put_env(:arbor_orchestrator, :ollama, base_url: base_url <> "/v1")

    assert {:error, reason} =
             Arbor.AI.embed_batch(["first", "second"],
               provider: :ollama,
               model: "nomic-embed-text",
               timeout_ms: 500
             )

    assert inspect(reason) =~ "indexed_embeddings_required_for_batch"
    assert_receive {:embedding_request, ^server, path}
    assert path in ["/api/embed", "/v1/embeddings"]
  end

  defp trust_openai(base_url) do
    Application.put_env(:arbor_ai, :openai, base_url: base_url)

    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "openai" => [base_url <> "/v1"]
    })
  end

  defp start_json_server(response_body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener),
             {:ok, request} <- recv_http_request(socket, "") do
          [request_line | _rest] = String.split(request, "\r\n")
          [_method, path, _version] = String.split(request_line, " ", parts: 3)
          send(parent, {:embedding_request, self(), path})

          encoded = Jason.encode!(response_body)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(encoded)}\r\nconnection: close\r\n\r\n#{encoded}"
            )

          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if Process.alive?(server) do
        Process.exit(server, :kill)
      end
    end)

    {"http://127.0.0.1:#{port}", server}
  end

  defp recv_http_request(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {_, _} ->
        {:ok, acc}

      :nomatch ->
        with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 1_000) do
          recv_http_request(socket, acc <> chunk)
        end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
