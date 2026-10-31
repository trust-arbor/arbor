defmodule Arbor.LLM.SensitivityDispatchSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.{Client, Message, Request}
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Plugs.Dispatch

  @moduletag :fast
  @moduletag :integration

  defmodule SecretMessageRewrite do
    def call(%Arbor.LLM.Call{request: {model, messages, opts}} = call) do
      secret =
        ReqLLM.Context.user(
          "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"
        )

      %{call | request: {model, messages ++ [secret], opts}}
    end
  end

  alias Arbor.LLM.TestSupport.TransportContract

  setup do
    previous_client = :persistent_term.get({Client, :default_client}, nil)
    keys = [:pipeline]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    Enum.each(keys, &Application.delete_env(:arbor_llm, &1))

    TransportContract.setup(
      for model <- ["gpt-4o-mini", "text-embedding-3-small"],
          origin <- [nil, "https://api.openai.com"] do
        TransportContract.route("openai", model, :public, origin)
      end
    )

    Client.set_default_client(
      Client.new(adapters: %{"openai" => Adapter, "lm_studio" => Adapter, "ollama" => Adapter})
    )

    Req.Test.set_req_test_to_shared()
    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(bytes)
      send(observer, {:outbound_model_request, body})

      if String.ends_with?(conn.request_path, "/embeddings") do
        Req.Test.json(conn, %{
          "data" => [%{"index" => 0, "embedding" => [0.1, 0.2]}],
          "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
        })
      else
        Req.Test.json(conn, %{
          "id" => "sensitivity-fixture",
          "object" => "chat.completion",
          "created" => 0,
          "model" => "fixture-model",
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

    on_exit(fn ->
      if previous_client,
        do: :persistent_term.put({Client, :default_client}, previous_client),
        else: Client.clear_default_client()

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    :ok
  end

  test "security regression: direct generate refuses recorded restricted prose before cloud dispatch" do
    assert {:error, {:sensitivity_blocked, _}} = generate(sensitivity: :restricted)
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: a public caller label cannot suppress scanning the system prompt" do
    secret = "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"
    assert {:error, {:sensitivity_blocked, _}} = generate(system: secret, sensitivity: :public)
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: message metadata retains a restricted floor on ordinary prose" do
    messages = [
      Message.new(:user, "Ordinary synthetic prose", %{taint: %{sensitivity: :restricted}})
    ]

    assert {:error, {:sensitivity_blocked, _}} = generate(messages: messages)
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: invalid labels and unavailable policy deny before transport" do
    assert {:error, {:sensitivity_blocked, _}} = generate(sensitivity: :invalid)
    Application.put_env(:arbor_llm, :sensitivity_policy, nil)
    assert {:error, {:sensitivity_blocked, :policy_unavailable}} = generate()
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: replacing the configured pipeline cannot remove admission" do
    Application.put_env(:arbor_llm, :pipeline, [Dispatch])
    assert {:error, {:sensitivity_blocked, _}} = generate(sensitivity: :restricted)
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: restricted embedding batch is refused by the direct facade" do
    assert {:error, {:sensitivity_blocked, _}} =
             LLM.embed_batch("openai", "text-embedding-3-small", ["Ordinary synthetic prose"],
               sensitivity: :restricted,
               api_key: "fixture",
               req_http_options: http_options()
             )

    refute_receive {:outbound_model_request, _}
  end

  test "security regression: a plug cannot add sensitive messages after original input admission" do
    Application.put_env(:arbor_llm, :pipeline, [
      Arbor.LLM.Plugs.ResponseLimit,
      SecretMessageRewrite,
      Dispatch
    ])

    assert {:error, {:sensitivity_blocked, _}} = generate()
    refute_receive {:outbound_model_request, _}
  end

  test "security regression: all Client completion entry points refuse the same restricted message" do
    request = %Request{
      provider: "openai",
      model: "gpt-4o-mini",
      messages: [Message.new(:user, "Plain text")]
    }

    client = Client.new(adapters: %{"openai" => Adapter})
    opts = [sensitivity: :restricted, api_key: "fixture", req_http_options: http_options()]
    assert {:error, {:sensitivity_blocked, _}} = Client.complete(client, request, opts)

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete_single_attempt(client, request, opts)

    assert {:error, {:sensitivity_blocked, _}} = Client.stream(client, request, opts)

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete_streaming(client, request, fn _ -> :ok end, opts)

    assert {:error, {:sensitivity_blocked, _}} =
             Client.complete_streaming_single_attempt(client, request, fn _ -> :ok end, opts)

    refute_receive {:outbound_model_request, _}
  end

  test "explicit finite host contract admits the public completion and embedding fixtures" do
    assert {:ok, %{text: "Fixture reply"}} = generate()
    assert_receive {:outbound_model_request, completion}
    assert completion["model"] == "gpt-4o-mini"

    assert {:ok, _embedding} =
             LLM.embed_batch("openai", "text-embedding-3-small", ["Ordinary synthetic prose"],
               api_key: "fixture",
               req_http_options: http_options()
             )

    assert_receive {:outbound_model_request, embedding}
    assert embedding["model"] == "text-embedding-3-small"

    assert TransportContract.authorize_llm_sensitivity(%{
             provider: "unlisted-fixture",
             model: "gpt-4o-mini",
             sensitivity: :public,
             runtime: :arbor,
             base_url: nil
           }) == {:error, :destination_disallowed}
  end

  test "finite host identity binds its actual loaded implementation and declared routes" do
    assert {:ok, first} = TransportContract.llm_sensitivity_identity()

    assert first["implementation"] == [
             %{
               "module" => Atom.to_string(TransportContract),
               "md5" => Base.encode16(TransportContract.module_info(:md5), case: :lower)
             }
           ]

    assert :ok =
             TransportContract.allow([
               TransportContract.route("identity-control", "only-this-model", :public, nil)
             ])

    assert {:ok, second} = TransportContract.llm_sensitivity_identity()
    refute first["configuration_digest"] == second["configuration_digest"]
    assert first["implementation"] == second["implementation"]
  end

  defp generate(extra \\ []) do
    opts = [
      provider: "openai",
      model: "gpt-4o-mini",
      prompt: "Ordinary synthetic prose",
      client_opts: [api_key: "fixture", req_http_options: http_options()]
    ]

    opts = Keyword.merge(opts, extra)
    opts = if Keyword.has_key?(extra, :messages), do: Keyword.delete(opts, :prompt), else: opts
    LLM.generate(opts)
  end

  defp http_options, do: [plug: {Req.Test, __MODULE__}, retry: false, redirect: false]
end
