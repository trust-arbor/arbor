defmodule Arbor.LLM.ExecutionProviderIdentityTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.LLM

  setup do
    previous =
      Map.new([:ollama, :lm_studio], &{&1, Application.fetch_env(:arbor_orchestrator, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        case value do
          {:ok, config} -> Application.put_env(:arbor_orchestrator, key, config)
          :error -> Application.delete_env(:arbor_orchestrator, key)
        end
      end)
    end)

    :ok
  end

  test "Ollama identity captures reported artifact rather than trusting a mutable alias" do
    digest = String.duplicate("a", 64)
    serve(:ollama, %{"models" => [%{"name" => "chat:latest", "digest" => digest}]})
    assert {:ok, identity} = LLM.execution_provider_identity("ollama", "chat")
    assert identity["artifact_digest"] == digest
    assert identity["artifact_state"] == "reported"
    assert_receive {:metadata_request, "GET /api/tags HTTP/1.1"}
  end

  test "missing Ollama artifact refuses instead of qualifying an alias" do
    serve(:ollama, %{"models" => [%{"name" => "chat", "digest" => nil}]})

    assert {:error, :model_serving_identity_unavailable} =
             LLM.execution_provider_identity("ollama", "chat")
  end

  test "LM Studio binds the exact loaded instance and does not invent a weight digest" do
    serve(:lm_studio, %{
      "models" => [
        %{
          "type" => "llm",
          "key" => "vendor/model",
          "selected_variant" => "vendor/model@8bit",
          "quantization" => %{"name" => "8bit"},
          "loaded_instances" => [%{"id" => "local-chat", "config" => %{"context_length" => 8192}}]
        }
      ]
    })

    assert {:ok, identity} = LLM.execution_provider_identity("lmstudio", "local-chat")
    assert identity["serving_metadata"]["selected_variant"] == "vendor/model@8bit"
    assert identity["serving_metadata"]["loaded_instance"]["config"]["context_length"] == 8192
    assert identity["artifact_state"] == "unreported"
    assert identity["artifact_digest"] == nil
    assert_receive {:metadata_request, "GET /api/v1/models HTTP/1.1"}
  end

  test "an unloaded or ambiguous local model is unavailable" do
    serve(:lm_studio, %{
      "models" => [%{"type" => "llm", "key" => "vendor/model", "loaded_instances" => []}]
    })

    assert {:error, :model_serving_identity_unavailable} =
             LLM.execution_provider_identity("lmstudio", "local-chat")
  end

  defp serve(provider, body) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    Application.put_env(:arbor_orchestrator, provider, base_url: "http://127.0.0.1:#{port}/v1")

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:metadata_request, hd(String.split(request, "\r\n"))})
        data = Jason.encode!(body)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
            Integer.to_string(byte_size(data)),
            "\r\nConnection: close\r\n\r\n",
            data
          ])

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
