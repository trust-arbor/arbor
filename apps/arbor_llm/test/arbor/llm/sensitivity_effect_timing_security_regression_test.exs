defmodule Arbor.LLM.SensitivityEffectTimingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.{Client, Message, Request, StreamEvent}
  alias Arbor.LLM.Plugs.{Dispatch, ResponseLimit}

  setup do
    keys = [:pipeline, :sensitivity_policy, :trusted_proxy_endpoints]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    Application.delete_env(:arbor_llm, :sensitivity_policy)
    Application.put_env(:arbor_llm, :pipeline, [ResponseLimit, Dispatch])
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    :ok
  end

  test "security regression: lazy stream rechecks policy before its first transport effect" do
    url = stream_endpoint()

    stream =
      Adapter.stream(request("lm_studio", "timing-fixture"),
        base_url: url,
        api_key: "fixture",
        receive_timeout: 1_000
      )

    refute_receive {:outbound_stream_request, _}, 20
    Application.put_env(:arbor_llm, :sensitivity_policy, nil)

    assert Enum.any?(Enum.to_list(stream), fn
             %StreamEvent{type: :error, data: %{reason: {:sensitivity_blocked, _}}} -> true
             _ -> false
           end)

    refute_receive {:outbound_stream_request, _}
  end

  test "security regression: ordinary lazy stream still reaches its configured transport" do
    url = stream_endpoint()

    stream =
      Adapter.stream(request("lm_studio", "timing-fixture"),
        base_url: url,
        api_key: "fixture",
        receive_timeout: 1_000
      )

    assert Enum.any?(Enum.to_list(stream), fn
             %StreamEvent{type: :delta, data: %{text: "Fixture reply"}} -> true
             _ -> false
           end)

    assert_receive {:outbound_stream_request, _}
  end

  test "security regression: transport retry rechecks policy after an admitted first attempt" do
    install_transport_retry(fn ->
      Application.put_env(:arbor_llm, :sensitivity_policy, nil)
    end)

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete(client(), request(), retry_opts())

    assert_receive {:outbound_retry_request, 1, _}
    refute_receive {:outbound_retry_request, 2, _}
  end

  test "security regression: transport retry scans a body changed after initial admission" do
    install_transport_retry(fn -> :ok end)
    observer = self()

    rewrite = fn request ->
      Req.Request.append_request_steps(request,
        sensitivity_fixture_retry_rewrite: fn request ->
          if Req.Request.get_private(request, :req_retry_count, 0) > 0 do
            secret = "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"
            payload = request.body |> IO.iodata_to_binary() |> Jason.decode!()

            message = %{"role" => "user", "content" => secret}
            payload = Map.update(payload, "messages", [message], &(&1 ++ [message]))
            send(observer, :retry_body_rewritten)
            %{request | body: Jason.encode!(payload)}
          else
            request
          end
        end
      )
    end

    opts = retry_opts(plugins: [rewrite])

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete(client(), request(), opts)

    assert_receive {:outbound_retry_request, 1, _}
    assert_receive :retry_body_rewritten
    refute_receive {:outbound_retry_request, 2, _}
  end

  test "security regression: unchanged transport retry still makes its second permitted attempt" do
    install_transport_retry(fn -> :ok end)

    assert {:ok, %{text: "Fixture reply"}} =
             Client.complete(client(), request(), retry_opts())

    assert_receive {:outbound_retry_request, 1, _}
    assert_receive {:outbound_retry_request, 2, _}
    refute_receive {:outbound_retry_request, 3, _}
  end

  test "security regression: transport retry decodes escaped credential text before dispatch" do
    install_transport_retry(fn -> :ok end)
    observer = self()

    rewrite = fn request ->
      Req.Request.append_request_steps(request,
        sensitivity_fixture_escaped_retry_rewrite: fn request ->
          if Req.Request.get_private(request, :req_retry_count, 0) > 0 do
            secret = "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"

            escaped =
              for <<byte <- secret>>, into: "" do
                "\\u" <> String.pad_leading(Integer.to_string(byte, 16), 4, "0")
              end

            payload = request.body |> IO.iodata_to_binary() |> Jason.decode!()
            message = %{"role" => "user", "content" => "escaped-credential-fixture"}
            payload = Map.update(payload, "messages", [message], &(&1 ++ [message]))

            body =
              payload
              |> Jason.encode!()
              |> String.replace("escaped-credential-fixture", escaped)

            send(observer, :retry_escaped_body_rewritten)
            %{request | body: body}
          else
            request
          end
        end
      )
    end

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete(client(), request(), retry_opts(plugins: [rewrite]))

    assert_receive {:outbound_retry_request, 1, _}
    assert_receive :retry_escaped_body_rewritten
    refute_receive {:outbound_retry_request, 2, _}
  end

  test "security regression: internal cloud retry binds the admitted scheme host and port" do
    observer = self()

    for changes <- [
          %{scheme: "http", port: 80},
          %{host: "unadmitted-effect.invalid"},
          %{port: 444}
        ] do
      install_transport_retry(fn -> :ok end)

      rewrite = fn request ->
        Req.Request.append_request_steps(request,
          sensitivity_fixture_retry_origin_rewrite: fn request ->
            if Req.Request.get_private(request, :req_retry_count, 0) > 0 do
              send(observer, {:retry_origin_rewritten, changes})
              %{request | url: struct!(request.url, changes)}
            else
              request
            end
          end
        )
      end

      opts = Keyword.put(retry_opts(plugins: [rewrite]), :sensitivity, :internal)

      assert {:error, {:sensitivity_blocked, _}} =
               Client.complete(client(), request(), opts)

      assert_receive {:outbound_retry_request, 1, _}
      assert_receive {:retry_origin_rewritten, ^changes}
      refute_receive {:outbound_retry_request, 2, _}
    end
  end

  test "security regression: internal cloud retry at the admitted origin remains permitted" do
    install_transport_retry(fn -> :ok end)
    opts = Keyword.put(retry_opts(), :sensitivity, :internal)

    assert {:ok, %{text: "Fixture reply"}} = Client.complete(client(), request(), opts)
    assert_receive {:outbound_retry_request, 1, _}
    assert_receive {:outbound_retry_request, 2, _}
  end

  defp client do
    Client.new(adapters: %{"openai" => Adapter, "lm_studio" => Adapter})
  end

  defp request(provider \\ "openai", model \\ "gpt-4o-mini") do
    %Request{
      provider: provider,
      model: model,
      messages: [Message.new(:user, "Ordinary synthetic prose")]
    }
  end

  defp retry_opts(extra_http_opts \\ []) do
    [
      api_key: "fixture",
      receive_timeout: 1_000,
      req_http_options: [plug: {Req.Test, __MODULE__}, max_retries: 1] ++ extra_http_opts
    ]
  end

  defp install_transport_retry(after_initial_effect) do
    observer = self()
    counter = :atomics.new(1, signed: false)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      attempt = :atomics.add_get(counter, 1, 1)
      send(observer, {:outbound_retry_request, attempt, Jason.decode!(bytes)})

      if attempt == 1 do
        after_initial_effect.()
        Req.Test.transport_error(conn, :closed)
      else
        Req.Test.json(conn, %{
          "id" => "sensitivity-timing-fixture",
          "object" => "chat.completion",
          "created" => 0,
          "model" => "gpt-4o-mini",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "Fixture reply"}]
            }
          ],
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "Fixture reply"}
            }
          ],
          "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 2, "total_tokens" => 4}
        })
      end
    end)
  end

  defp stream_endpoint do
    observer = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener, 2_000) do
          {:ok, socket} ->
            {:ok, bytes} = :gen_tcp.recv(socket, 0, 1_000)
            send(observer, {:outbound_stream_request, bytes})

            body =
              "data: " <>
                Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Fixture reply"}}]}) <>
                "\n\ndata: [DONE]\n\n"

            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
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

    url = "http://127.0.0.1:#{port}/v1"
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{"lm_studio" => [url]})
    url
  end
end
