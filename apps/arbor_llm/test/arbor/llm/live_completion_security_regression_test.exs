defmodule Arbor.LLM.LiveCompletionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.{Call, Client, Response}
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Plugs.{Dispatch, Record, Replay}

  @moduletag :fast
  @moduletag :integration
  @model "live-selector-fixture"

  defmodule OtherAdapter do
    def complete(_request, _opts) do
      send(Process.whereis(Elixir.Arbor.LLM.LiveCompletionSecurityRegressionTest), :other_adapter)
      {:ok, %Response{text: "substituted"}}
    end
  end

  defmodule OtherDispatch do
    use Arbor.LLM.Plug

    def call(%Call{} = call) do
      send(
        Process.whereis(Elixir.Arbor.LLM.LiveCompletionSecurityRegressionTest),
        :other_dispatch
      )

      %{call | result: {:error, :substituted_dispatch}}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous_client = :persistent_term.get({Client, :default_client}, nil)

    previous =
      Enum.map(
        [:pipeline, :rate_limit_backoff_dispatch_fn],
        &{&1, Application.fetch_env(:arbor_llm, &1)}
      )

    Application.delete_env(:arbor_llm, :pipeline)

    Client.set_default_client(
      Client.new(adapters: %{"lm_studio" => Adapter}, default_provider: "lm_studio")
    )

    Req.Test.set_req_test_to_shared()
    observer = self()
    mode = start_supervised!({Agent, fn -> :normal end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      send(observer, {:completion_http, self(), Jason.decode!(bytes)})
      current = Agent.get(mode, & &1)

      if current == :held do
        receive do
          :release -> :ok
        after
          10_000 -> raise "held test HTTP was not released"
        end
      end

      case current do
        :redirect ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://forbidden.invalid/redirected")
          |> Plug.Conn.send_resp(302, "redirect")

        :rate_limited ->
          conn
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"message" => "fixture limit"}})

        _ ->
          send(observer, :http_finished)

          choice = %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => ~s({"selected_ids":[]})}
          }

          choice =
            case current do
              :missing_finish ->
                Map.delete(choice, "finish_reason")

              :null_finish ->
                Map.put(choice, "finish_reason", nil)

              :invalid_finish ->
                Map.put(choice, "finish_reason", %{})

              :length_finish ->
                Map.put(choice, "finish_reason", "length")

              :wrapped ->
                put_in(
                  choice,
                  ["message", "content"],
                  ~S({"output":"{\"selected_ids\":[]}","selected_ids":["foreign"],"extra":true})
                )

              _ ->
                choice
            end

          Req.Test.json(conn, %{
            "id" => "fixture",
            "object" => "chat.completion",
            "created" => 0,
            "model" => @model,
            "choices" => [choice],
            "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
          })
      end
    end)

    on_exit(fn ->
      if previous_client,
        do: Client.set_default_client(previous_client),
        else: Client.clear_default_client()

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    %{mode: mode}
  end

  test "security regression: live completion ignores ambient adapter and retains real usage" do
    Client.set_default_client(
      Client.new(adapters: %{"lm_studio" => OtherAdapter}, default_provider: "lm_studio")
    )

    assert {:ok, response} = generate()
    assert response.text == ~s({"selected_ids":[]})
    assert response.usage.total_tokens == 12
    assert_receive {:completion_http, _, request}
    refute Map.has_key?(request, "max_tokens")
    refute Map.has_key?(request, "require_live_pipeline")
    refute Map.has_key?(request, "tools")
    refute_receive :other_adapter
  end

  test "live completion advertises a bounded closed JSON schema through the real provider" do
    format = selection_format()
    assert {:ok, response} = generate(provider_options: %{response_format: format})
    assert response.text == ~s({"selected_ids":[]})
    assert_receive {:completion_http, _, request}
    assert request["response_format"] == format
    refute Map.has_key?(request, "tools")
    refute Map.has_key?(request, "max_tokens")
  end

  test "security regression: constrained live schema cannot carry references or provider overrides" do
    format = selection_format()

    for invalid <- [
          Map.put(format, "extra", true),
          put_in(format, ["json_schema", "strict"], false),
          put_in(format, ["json_schema", "name"], String.duplicate("x", 65)),
          put_in(format, ["json_schema", "schema"], %{"$ref" => "https://invalid.test/schema"}),
          put_in(format, ["json_schema", "schema"], %{"$dynamicRef" => "#schema"}),
          put_in(format, ["json_schema", "schema", "properties", "selected_ids", "items"], %{
            "type" => "string",
            "format" => "uri"
          }),
          put_in(
            format,
            ["json_schema", "schema", "properties", "selected_ids", "items", "enum"],
            [String.duplicate("x", 16_385)]
          ),
          put_in(
            format,
            ["json_schema", "schema", "properties", "selected_ids", "items", "enum"],
            [String.duplicate("\"", 9000)]
          )
        ] do
      assert {:error, :live_completion_configuration_unsupported} =
               generate(provider_options: %{response_format: invalid})

      refute_receive {:completion_http, _, _}
    end

    assert {:error, :live_completion_configuration_unsupported} =
             generate(provider_options: %{response_format: format, tools: []})

    assert {:error, :live_completion_configuration_unsupported} =
             generate(
               provider_options: %{response_format: format},
               client_opts: [provider_options: []]
             )

    assert {:error, :live_completion_configuration_unsupported} =
             LLM.generate(
               options() ++ [provider_options: %{}, provider_options: %{response_format: format}]
             )

    refute_receive {:completion_http, _, _}
  end

  test "ordinary completion preserves the configured adapter" do
    client = Client.new(adapters: %{"lm_studio" => OtherAdapter})
    assert {:ok, %{text: "substituted"}} = generate(require_live_pipeline: nil, client: client)
    assert_receive :other_adapter
    refute_receive {:completion_http, _, _}
  end

  test "security regression: custom composition cannot claim live completion" do
    for pipeline <- [[Replay, Dispatch], [Dispatch, Record], [OtherDispatch], [], nil] do
      Application.put_env(:arbor_llm, :pipeline, pipeline)
      assert {:error, :live_completion_pipeline_unsupported} = generate()
      refute_receive {:completion_http, _, _}
      refute_receive :other_dispatch
    end
  end

  test "security regression: unsupported explicit options are rejected before dispatch" do
    for opts <- [
          [client: Client.new(adapters: %{"lm_studio" => OtherAdapter})],
          [tools: [%{name: "unavailable", input_schema: %{}}]],
          [tool_choice: "auto"],
          [provider_options: %{tools: [%{}]}],
          [eval_fixture_set: "unavailable"],
          [client_opts: [eval_fixture_set: "unavailable"]]
        ] do
      assert {:error, :live_completion_configuration_unsupported} = generate(opts)
      refute_receive {:completion_http, _, _}
      refute_receive :other_adapter
    end
  end

  test "security regression: invalid or delegated requirement cannot be ignored" do
    for marker <- [false, "true", %{}, []] do
      assert {:error, :invalid_live_completion_requirement} =
               generate(require_live_pipeline: marker)
    end

    assert {:error, :invalid_live_completion_requirement} =
             generate(client_opts: [require_live_pipeline: false])

    assert {:error, :live_completion_explicit_provider_required} = generate(provider: nil)
    assert {:error, :live_completion_provider_unsupported} = generate(provider: "acp")
    refute_receive {:completion_http, _, _}
  end

  test "security regression: live completion is not a streaming or tool-loop permission" do
    assert {:error, :live_completion_stream_unsupported} = LLM.stream(options())
    refute_receive {:completion_http, _, _}
  end

  test "live HTTP errors do not backfill, redirect or redispatch", ctx do
    Application.put_env(:arbor_llm, :rate_limit_backoff_dispatch_fn, &OtherDispatch.call/1)

    for mode <- [:redirect, :rate_limited] do
      Agent.update(ctx.mode, fn _ -> mode end)

      assert {:error, _} =
               generate(
                 client_opts: [
                   req_http_options: [plug: {Req.Test, __MODULE__}, redirect: true, retry: false]
                 ]
               )

      assert_receive {:completion_http, _, _}
      refute_receive {:completion_http, _, _}
      refute_receive :other_dispatch
    end
  end

  test "active call freezes stock composition and later call rejects changed config", ctx do
    Agent.update(ctx.mode, fn _ -> :held end)
    task = Task.async(fn -> generate() end)
    assert_receive {:completion_http, worker, _}, 5_000
    Application.put_env(:arbor_llm, :pipeline, [OtherDispatch])
    send(worker, :release)
    assert {:ok, %{text: ~s({"selected_ids":[]})}} = Task.await(task, 10_000)
    assert {:error, :live_completion_pipeline_unsupported} = generate()
    refute_receive :other_dispatch
  end

  test "security regression: live result needs an explicit completed upstream stop", ctx do
    for mode <- [:missing_finish, :null_finish, :invalid_finish, :length_finish] do
      Agent.update(ctx.mode, fn _ -> mode end)
      assert {:error, :invalid_live_completion_result} = generate()
      assert_receive {:completion_http, _, _}
    end
  end

  test "live completion preserves original assistant text for strict caller decoding", ctx do
    Agent.update(ctx.mode, fn _ -> :wrapped end)
    assert {:ok, response} = generate()

    assert response.text ==
             ~S({"output":"{\"selected_ids\":[]}","selected_ids":["foreign"],"extra":true})

    assert_receive {:completion_http, _, _}
  end

  test "ordinary completion preserves missing-finish compatibility", ctx do
    Agent.update(ctx.mode, fn _ -> :missing_finish end)
    assert {:ok, %{finish_reason: :stop}} = generate(require_live_pipeline: nil)
    assert_receive {:completion_http, _, _}
  end

  test "caller death reaps the actual held provider operation", ctx do
    Agent.update(ctx.mode, fn _ -> :held end)
    caller = spawn(fn -> generate() end)
    assert_receive {:completion_http, worker, _}, 5_000
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    send(worker, :release)
    refute_receive :http_finished
  end

  defp generate(overrides \\ []), do: LLM.generate(Keyword.merge(options(), overrides))

  defp selection_format do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "selection",
        "strict" => true,
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "selected_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => ["first", "second"]},
              "minItems" => 0,
              "maxItems" => 2
            }
          },
          "required" => ["selected_ids"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp options do
    [
      provider: "lm_studio",
      model: @model,
      prompt: "Synthetic query",
      require_live_pipeline: true,
      timeout_ms: 15_000,
      max_response_bytes: 65_536,
      client_opts: [
        req_http_options: [plug: {Req.Test, __MODULE__}, retry: false, redirect: false]
      ]
    ]
  end
end
