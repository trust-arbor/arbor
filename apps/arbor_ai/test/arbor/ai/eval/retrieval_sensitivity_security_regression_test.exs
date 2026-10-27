defmodule Arbor.AI.Eval.RetrievalSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.AI.Eval.RetrievalSupport

  setup do
    previous = Application.fetch_env(:arbor_llm, :trusted_eval_endpoints)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :trusted_eval_endpoints, value)
        :error -> Application.delete_env(:arbor_llm, :trusted_eval_endpoints)
      end
    end)

    :ok
  end

  test "security regression: loopback eval transport cannot clear a cloud proxy model" do
    url = eval_endpoint("/api/chat")

    body = %{
      "model" => "fixture:cloud",
      "messages" => [%{"role" => "user", "content" => credential_text()}],
      "stream" => false
    }

    assert {:error, {:sensitivity_blocked, _}} =
             RetrievalSupport.post_json(url, body, 1_000, 1_024)

    refute_receive {:eval_model_effect, _, _}
  end

  test "security regression: an embedding URL does not invent a provider clearance" do
    url = eval_endpoint("/v1/embeddings")
    body = %{"model" => "fixture-local-model", "input" => [credential_text()]}

    assert {:error, {:sensitivity_blocked, _}} =
             RetrievalSupport.post_json(url, body, 1_000, 1_024)

    refute_receive {:eval_model_effect, _, _}
  end

  test "security regression: ordinary public eval still reaches the configured local endpoint" do
    url = eval_endpoint("/api/chat")

    body = %{
      "model" => "fixture-local-model",
      "messages" => [%{"role" => "user", "content" => "Ordinary planning notes"}],
      "stream" => false
    }

    assert {:ok, 200, %{"ok" => true}} =
             RetrievalSupport.post_json(url, body, 1_000, 1_024)

    assert_receive {:eval_model_effect, "/api/chat", ^body}
  end

  defp credential_text do
    "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"
  end

  defp eval_endpoint(path) do
    observer = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener, 2_000) do
          {:ok, socket} ->
            {:ok, request_body} = receive_body(socket, "")
            send(observer, {:eval_model_effect, path, Jason.decode!(request_body)})
            response_body = Jason.encode!(%{"ok" => true})

            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
              Integer.to_string(byte_size(response_body)),
              "\r\nconnection: close\r\n\r\n",
              response_body
            ])

            :gen_tcp.close(socket)

          {:error, _} ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:arbor_llm, :trusted_eval_endpoints, [origin])
    origin <> path
  end

  defp receive_body(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        length = String.to_integer(length)

        if byte_size(body) >= length do
          {:ok, binary_part(body, 0, length)}
        else
          receive_more(socket, bytes)
        end

      _ ->
        receive_more(socket, bytes)
    end
  end

  defp receive_more(socket, bytes) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, more} -> receive_body(socket, bytes <> more)
      error -> error
    end
  end
end
