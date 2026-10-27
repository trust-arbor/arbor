defmodule Arbor.LLM.SensitivityAdapterIdentitySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.{Client, Message, Request, Response}
  alias Arbor.LLM.OAuth.Responses

  @moduletag :fast
  @moduletag :integration

  defmodule CapturingAdapter do
    def complete(_request, opts) do
      observer = Process.whereis(Arbor.LLM.SensitivityAdapterIdentitySecurityRegressionTest)
      send(observer, {:custom_adapter_received, opts})
      {:ok, %Response{text: "accepted"}}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    keys = [:sensitivity_guarded_adapters, :trusted_oauth_response_endpoints]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})

    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, [
      Arbor.LLM.Adapter.ReqLLM,
      Arbor.LLM.Adapter.OAuthResponses,
      Arbor.LLM.Adapter.LmStudio
    ])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    :ok
  end

  test "security regression: a custom adapter cannot gain restricted clearance from a local provider name" do
    client = Client.new(adapters: %{"lm_studio" => CapturingAdapter})

    assert {:error, {:sensitivity_blocked, _reason}} =
             Client.complete(client, request(), sensitivity: :restricted)

    refute_receive {:custom_adapter_received, _opts}
  end

  test "security regression: registered effect owners receive the original floor after middleware removes labels" do
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, [CapturingAdapter])

    client =
      Client.new(
        adapters: %{"lm_studio" => CapturingAdapter},
        middleware: [
          fn current, next ->
            next.(%{current | messages: [Message.new(:user, "Ordinary prose")]})
          end
        ]
      )

    selected = %{
      request()
      | messages: [Message.new(:user, "Ordinary prose", %{sensitivity: :restricted})]
    }

    assert {:ok, %Response{text: "accepted"}} = Client.complete(client, selected)
    assert_receive {:custom_adapter_received, opts}
    assert Keyword.fetch!(opts, :sensitivity) == :restricted
  end

  test "security regression: public requests retain support for ordinary custom adapters" do
    client = Client.new(adapters: %{"lm_studio" => CapturingAdapter})
    assert {:ok, %Response{text: "accepted"}} = Client.complete(client, request())
    assert_receive {:custom_adapter_received, _opts}
  end

  test "security regression: raw OAuth transport preserves a restricted keyword floor" do
    {url, observer} = raw_response_fixture()
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])

    assert {:error, {:sensitivity_blocked, _reason}} =
             Responses.request_sse(
               url,
               [],
               %{"model" => "fixture-model", "input" => "Ordinary prose"},
               [sensitivity: :restricted, receive_timeout: 1_000],
               %{route: :openai_oauth, backend: :openai}
             )

    refute_receive {:raw_oauth_request, ^observer}, 100
  end

  test "security regression: raw OAuth transport refuses a malformed present keyword floor" do
    {url, observer} = raw_response_fixture()
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])

    assert {:error, {:sensitivity_blocked, _reason}} =
             Responses.request_sse(
               url,
               [],
               %{"model" => "fixture-model", "input" => "Ordinary prose"},
               [sensitivity: :invalid, receive_timeout: 1_000],
               %{route: :openai_oauth, backend: :openai}
             )

    refute_receive {:raw_oauth_request, ^observer}, 100
  end

  defp request do
    %Request{
      provider: "lm_studio",
      model: "fixture-model",
      messages: [Message.new(:user, "Ordinary prose")]
    }
  end

  defp raw_response_fixture do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    observer =
      spawn(fn ->
        case :gen_tcp.accept(listener, 5_000) do
          {:ok, socket} ->
            send(owner, {:raw_oauth_request, self()})
            :gen_tcp.recv(socket, 0, 1_000)
            body = "data: [DONE]\n\n"

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
                "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
            )

            :gen_tcp.close(socket)

          {:error, _reason} ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(observer), do: Process.exit(observer, :kill)
    end)

    {"http://127.0.0.1:#{port}/responses", observer}
  end
end
