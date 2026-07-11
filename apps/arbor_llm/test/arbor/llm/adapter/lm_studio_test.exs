defmodule Arbor.LLM.Adapter.LmStudioTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Adapter.LmStudio
  alias Arbor.LLM.{Message, Request}

  setup do
    previous_options = Req.default_options()
    previous_url = Application.get_env(:arbor_llm, :lm_studio_base_url)

    on_exit(fn ->
      Req.default_options(previous_options)

      if is_nil(previous_url) do
        Application.delete_env(:arbor_llm, :lm_studio_base_url)
      else
        Application.put_env(:arbor_llm, :lm_studio_base_url, previous_url)
      end
    end)

    :ok
  end

  test "security regression: chunked oversized receipt halts before the full body" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        response = Req.Response.new(status: 200, headers: %{})

        {request, response} =
          Enum.reduce_while(1..10_000, {request, response}, fn index, acc ->
            send(parent, {:chunk, index})

            case request.into.({:data, String.duplicate("x", 600)}, acc) do
              {:cont, next} -> {:cont, next}
              {:halt, next} -> {:halt, next}
            end
          end)

        {request, response}
      end
    )

    request = %Request{
      provider: "lm_studio_owned",
      model: "model",
      messages: [%Message{role: :user, content: "hello"}]
    }

    assert LmStudio.complete(request, max_response_bytes: 1_024) ==
             {:error, {:response_bytes_exceeded, 1_024}}

    assert_receive {:chunk, 1}
    assert_receive {:chunk, 2}
    refute_receive {:chunk, 3}
  end

  test "bounded receipt preserves a valid LM Studio response" do
    Req.default_options(
      adapter: fn request ->
        body =
          Jason.encode!(%{
            "choices" => [
              %{"finish_reason" => "stop", "message" => %{"content" => "hello"}}
            ]
          })

        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: body
         )}
      end
    )

    request = %Request{
      provider: "lm_studio_owned",
      model: "model",
      messages: [%Message{role: :user, content: "hello"}]
    }

    assert {:ok, %{text: "hello", finish_reason: :stop}} = LmStudio.complete(request)
  end

  test "security regression: real HTTP chunked oversized body closes early" do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
              "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
          )

        sent = send_http_chunks(socket, parent, 1, 10_000)
        :gen_tcp.close(socket)
        sent
      end)

    on_exit(fn -> :gen_tcp.close(listener) end)
    Application.put_env(:arbor_llm, :lm_studio_base_url, "http://127.0.0.1:#{port}/v1")

    request = %Request{
      provider: "lm_studio_owned",
      model: "model",
      messages: [%Message{role: :user, content: "hello"}]
    }

    assert LmStudio.complete(request, max_response_bytes: 1_024) ==
             {:error, {:response_bytes_exceeded, 1_024}}

    assert {:ok, sent} = Task.yield(server, 2_000)
    assert sent < 10_000
    assert_receive {:http_chunk, 1}
  end

  test "security regression: malformed configured endpoints fail closed" do
    request = %Request{
      provider: "lm_studio_owned",
      model: "model",
      messages: [%Message{role: :user, content: "hello"}]
    }

    for endpoint <- [
          "ftp://localhost:1234/v1",
          "http://user:pass@localhost:1234/v1",
          "http://localhost:1234/v1?next=/evil",
          "http://localhost:1234/v1#fragment",
          "http://localhost:99999/v1",
          "http://localhost:abc/v1",
          "http://localhost:/v1",
          "http://[::1]x/v1",
          "http://localhost:80:90/v1",
          "http://bad host:1234/v1",
          "http://localhost:1234/other"
        ] do
      Application.put_env(:arbor_llm, :lm_studio_base_url, endpoint)
      assert {:error, {:invalid_lm_studio_endpoint, _reason}} = LmStudio.complete(request)
    end
  end

  defp send_http_chunks(_socket, _parent, index, maximum) when index > maximum,
    do: maximum

  defp send_http_chunks(socket, parent, index, maximum) do
    chunk = String.duplicate("x", 600)
    encoded = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"

    case :gen_tcp.send(socket, encoded) do
      :ok ->
        send(parent, {:http_chunk, index})
        Process.sleep(2)
        send_http_chunks(socket, parent, index + 1, maximum)

      {:error, _reason} ->
        index - 1
    end
  end
end
